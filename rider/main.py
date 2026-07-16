"""rider service — rider CRUD and tier lookup.

GET    /healthz          -> {"status": "ok"}
POST   /riders           -> create a rider
GET    /riders           -> list riders
GET    /riders/{id}      -> fetch a rider
DELETE /riders/{id}      -> delete a rider
GET    /riders/{id}/tier -> {"tier": <str>}
POST   /auth/login       -> {"access_token", "token_type", "role", "rider_id", "expires_in"}
GET    /auth/me          -> current identity
"""

import hashlib
import hmac
import logging
import os
import time
import uuid
from contextlib import asynccontextmanager
from contextvars import ContextVar
from datetime import datetime, timedelta, timezone

import asyncpg
import jwt
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from pydantic import BaseModel
from pythonjsonlogger import jsonlogger

SERVICE = "rider"
LOG_FILE = os.environ.get("LOG_FILE", "/var/log/veloshare/app.log")

# Correlation id for the in-flight request. Callers propagate it via the
# X-Request-ID header, so one user transaction is traceable across services.
request_id_ctx: ContextVar[str] = ContextVar("request_id", default="-")


def _setup_logging() -> logging.Logger:
    """JSON logs to stdout, and best-effort to LOG_FILE for the Fluent Bit sidecar."""
    logger = logging.getLogger(SERVICE)
    logger.setLevel(logging.INFO)
    logger.propagate = False
    fmt = jsonlogger.JsonFormatter("%(asctime)s %(levelname)s %(name)s %(message)s")
    stream = logging.StreamHandler()
    stream.setFormatter(fmt)
    logger.addHandler(stream)
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        file_handler = logging.FileHandler(LOG_FILE)
        file_handler.setFormatter(fmt)
        logger.addHandler(file_handler)
    except OSError:
        # Shared log volume not mounted (logging disabled) — stdout only.
        pass
    return logger


log = _setup_logging()


def require_env(name: str) -> str:
    """Secrets get no default: fail fast rather than fall back to a value in git.

    Supplied by the rider-db and veloshare-auth Secrets (see env/*.env.template).
    """
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"{name} is required but not set")
    return value


DB_HOST = os.environ.get("DB_HOST", "postgres")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "veloshare")
DB_USER = os.environ.get("DB_USER", "rider")
DB_PASSWORD = require_env("DB_PASSWORD")
DB_SCHEMA = os.environ.get("DB_SCHEMA", "riders")

JWT_SECRET = require_env("JWT_SECRET")
JWT_TTL_SECONDS = int(os.environ.get("JWT_TTL_SECONDS", "3600"))
JWT_ALGORITHM = "HS256"
ADMIN_EMAIL = require_env("ADMIN_EMAIL")
ADMIN_PASSWORD = require_env("ADMIN_PASSWORD")


class RiderIn(BaseModel):
    name: str
    email: str
    tier: str
    password: str | None = None


class Rider(BaseModel):
    id: int
    name: str
    email: str
    tier: str


class LoginIn(BaseModel):
    email: str
    password: str


class LoginOut(BaseModel):
    access_token: str
    token_type: str = "bearer"
    role: str
    rider_id: int | None
    expires_in: int


def hash_password(password: str) -> str:
    salt = os.urandom(16)
    digest = hashlib.scrypt(
        password.encode("utf-8"), salt=salt, n=16384, r=8, p=1, dklen=32
    )
    return f"scrypt${salt.hex()}${digest.hex()}"


def verify_password(password: str, stored: str | None) -> bool:
    if not stored:
        return False
    try:
        scheme, salt_hex, hash_hex = stored.split("$")
    except ValueError:
        return False
    if scheme != "scrypt":
        return False
    try:
        salt = bytes.fromhex(salt_hex)
        expected = bytes.fromhex(hash_hex)
    except ValueError:
        return False
    digest = hashlib.scrypt(
        password.encode("utf-8"), salt=salt, n=16384, r=8, p=1, dklen=32
    )
    return hmac.compare_digest(digest, expected)


def make_token(sub: str, role: str, email: str) -> tuple[str, int]:
    now = datetime.now(timezone.utc)
    expires_in = JWT_TTL_SECONDS
    payload = {
        "sub": sub,
        "role": role,
        "email": email,
        "iat": now,
        "exp": now + timedelta(seconds=expires_in),
    }
    token = jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)
    return token, expires_in


def decode_token(token: str) -> dict:
    try:
        return jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
    except jwt.PyJWTError:
        raise HTTPException(status_code=401, detail="invalid or expired token")


async def current_identity(authorization: str = Header(None)) -> dict:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    token = authorization.removeprefix("Bearer ").strip()
    claims = decode_token(token)
    role = claims.get("role")
    sub = claims.get("sub")
    rider_id = int(sub) if role == "rider" and sub is not None else None
    return {"role": role, "rider_id": rider_id, "email": claims.get("email")}


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.pool = await asyncpg.create_pool(
        host=DB_HOST,
        port=DB_PORT,
        database=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        server_settings={"search_path": DB_SCHEMA},
    )
    yield
    await app.state.pool.close()


app = FastAPI(title="rider", lifespan=lifespan)


@app.middleware("http")
async def log_requests(request: Request, call_next):
    request_id = request.headers.get("x-request-id") or uuid.uuid4().hex
    request_id_ctx.set(request_id)
    start = time.perf_counter()
    response = await call_next(request)
    duration_ms = round((time.perf_counter() - start) * 1000, 1)
    log.info(
        "request",
        extra={
            "event": "request",
            "service": SERVICE,
            "request_id": request_id,
            "method": request.method,
            "path": request.url.path,
            "status": response.status_code,
            "duration_ms": duration_ms,
        },
    )
    response.headers["x-request-id"] = request_id
    return response


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.post("/riders", response_model=Rider, status_code=201)
async def create_rider(rider: RiderIn):
    password_hash = hash_password(rider.password) if rider.password else None
    async with app.state.pool.acquire() as conn:
        row = await conn.fetchrow(
            """
            INSERT INTO riders (name, email, tier, password_hash)
            VALUES ($1, $2, $3, $4)
            RETURNING id, name, email, tier
            """,
            rider.name,
            rider.email,
            rider.tier,
            password_hash,
        )
    log.info(
        "rider_created",
        extra={
            "event": "rider_created",
            "service": SERVICE,
            "request_id": request_id_ctx.get(),
            "rider_id": row["id"],
            "tier": row["tier"],
        },
    )
    return Rider(**dict(row))


@app.get("/riders", response_model=list[Rider])
async def list_riders():
    async with app.state.pool.acquire() as conn:
        rows = await conn.fetch("SELECT id, name, email, tier FROM riders ORDER BY id")
    return [Rider(**dict(row)) for row in rows]


@app.get("/riders/{rider_id}", response_model=Rider)
async def get_rider(rider_id: int):
    async with app.state.pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id, name, email, tier FROM riders WHERE id = $1", rider_id
        )
    if row is None:
        raise HTTPException(status_code=404, detail="rider not found")
    return Rider(**dict(row))


@app.delete("/riders/{rider_id}", status_code=204)
async def delete_rider(rider_id: int):
    async with app.state.pool.acquire() as conn:
        result = await conn.execute("DELETE FROM riders WHERE id = $1", rider_id)
    if result == "DELETE 0":
        raise HTTPException(status_code=404, detail="rider not found")


@app.get("/riders/{rider_id}/tier")
async def get_rider_tier(rider_id: int):
    async with app.state.pool.acquire() as conn:
        tier = await conn.fetchval("SELECT tier FROM riders WHERE id = $1", rider_id)
    if tier is None:
        raise HTTPException(status_code=404, detail="rider not found")
    return {"tier": tier}


@app.post("/auth/login", response_model=LoginOut)
async def login(credentials: LoginIn):
    if credentials.email == ADMIN_EMAIL and hmac.compare_digest(
        credentials.password, ADMIN_PASSWORD
    ):
        token, expires_in = make_token(sub="admin", role="admin", email=ADMIN_EMAIL)
        log.info(
            "login",
            extra={
                "event": "login",
                "service": SERVICE,
                "request_id": request_id_ctx.get(),
                "role": "admin",
                "outcome": "success",
                "email": credentials.email,
            },
        )
        return LoginOut(
            access_token=token,
            role="admin",
            rider_id=None,
            expires_in=expires_in,
        )

    async with app.state.pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id, email, tier, password_hash FROM riders WHERE email = $1",
            credentials.email,
        )

    if row is None or not verify_password(credentials.password, row["password_hash"]):
        log.info(
            "login",
            extra={
                "event": "login",
                "service": SERVICE,
                "request_id": request_id_ctx.get(),
                "role": "rider",
                "outcome": "failure",
                "email": credentials.email,
            },
        )
        raise HTTPException(status_code=401, detail="invalid credentials")

    token, expires_in = make_token(sub=str(row["id"]), role="rider", email=row["email"])
    log.info(
        "login",
        extra={
            "event": "login",
            "service": SERVICE,
            "request_id": request_id_ctx.get(),
            "role": "rider",
            "outcome": "success",
            "email": credentials.email,
        },
    )
    return LoginOut(
        access_token=token,
        role="rider",
        rider_id=row["id"],
        expires_in=expires_in,
    )


@app.get("/auth/me")
async def auth_me(identity: dict = Depends(current_identity)):
    if identity["role"] == "admin":
        return {"role": "admin", "email": ADMIN_EMAIL, "rider_id": None}

    rider_id = identity["rider_id"]
    async with app.state.pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id, name, email, tier FROM riders WHERE id = $1", rider_id
        )
    if row is None:
        raise HTTPException(status_code=404, detail="rider not found")
    return {
        "role": "rider",
        "rider_id": row["id"],
        "name": row["name"],
        "email": row["email"],
        "tier": row["tier"],
    }
