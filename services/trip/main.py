"""trip service — trip lifecycle, fare orchestration, event publish.

GET  /healthz              -> {"status": "ok"}
POST /trips/start          -> start a trip for a rider (auth required)
POST /trips/{trip_id}/end  -> end a trip, price it via `pricing`, publish completion (auth required)
GET  /trips/{trip_id}      -> fetch a trip record (auth required; riders may only fetch their own)
GET  /trips                -> list trips (auth required; riders see only their own)

Auth: HS256 JWTs issued by `rider` (`Authorization: Bearer <token>`). trip only verifies tokens.
"""

import logging
import math
import os
import time
import uuid
from contextlib import asynccontextmanager
from contextvars import ContextVar
from datetime import datetime, timezone

import asyncpg
import httpx
import jwt
import redis.asyncio as redis
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from pydantic import BaseModel, Field
from pythonjsonlogger import jsonlogger

SERVICE = "trip"
LOG_FILE = os.environ.get("LOG_FILE", "/var/log/veloshare/app.log")

# Correlation id for the in-flight request. Forwarded to rider/pricing via the
# X-Request-ID header so one user transaction is traceable across services.
request_id_ctx: ContextVar[str] = ContextVar("request_id", default="-")


def _trace_headers() -> dict[str, str]:
    return {"X-Request-ID": request_id_ctx.get()}


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

    Supplied by the trip-db and veloshare-auth Secrets (see env/*.env.template).
    """
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"{name} is required but not set")
    return value


DB_HOST = os.environ.get("DB_HOST", "postgres")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "veloshare")
DB_USER = os.environ.get("DB_USER", "trip")
DB_PASSWORD = require_env("DB_PASSWORD")
DB_SCHEMA = os.environ.get("DB_SCHEMA", "trips")

PRICING_URL = os.environ.get("PRICING_URL", "http://pricing.veloshare.svc.cluster.local")
RIDER_URL = os.environ.get("RIDER_URL", "http://rider.veloshare.svc.cluster.local")

REDIS_HOST = os.environ.get("REDIS_HOST", "redis")
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))

ACTIVE_TTL_SECONDS = int(os.environ.get("ACTIVE_TTL_SECONDS", "7200"))

ACTIVE_KEY_FMT = "trip:active:{rider_id}"
COMPLETED_STREAM = "trip.completed"

JWT_SECRET = require_env("JWT_SECRET")
JWT_ALGORITHM = "HS256"


def decode_token(token: str) -> dict:
    try:
        return jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
    except jwt.PyJWTError as exc:
        raise HTTPException(status_code=401, detail="not authenticated") from exc


async def current_identity(authorization: str = Header(None)) -> dict:
    """Verify the bearer token and return {"role", "rider_id", "email"}."""
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="not authenticated")

    token = authorization.split(" ", 1)[1].strip()
    claims = decode_token(token)

    role = claims.get("role")
    sub = claims.get("sub")
    if role not in ("rider", "admin") or sub is None:
        raise HTTPException(status_code=401, detail="not authenticated")

    rider_id: int | None = None
    if role == "rider":
        try:
            rider_id = int(sub)
        except (TypeError, ValueError):
            raise HTTPException(status_code=401, detail="not authenticated")

    return {"role": role, "rider_id": rider_id, "email": claims.get("email")}


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.db = await asyncpg.create_pool(
        host=DB_HOST,
        port=DB_PORT,
        database=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        server_settings={"search_path": DB_SCHEMA},
    )
    app.state.redis = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)
    app.state.http = httpx.AsyncClient(timeout=5.0)
    try:
        yield
    finally:
        await app.state.http.aclose()
        await app.state.redis.aclose()
        await app.state.db.close()


app = FastAPI(title="trip", lifespan=lifespan)


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


class StartTripRequest(BaseModel):
    rider_id: int | None = None
    station_id: int
    tier: str


class StartTripResponse(BaseModel):
    trip_id: int
    status: str


class EndTripRequest(BaseModel):
    end_station_id: int
    surge: float = Field(default=1.0, ge=0)


class EndTripResponse(BaseModel):
    trip_id: int
    status: str
    fare_cents: int
    minutes: int


class TripRecord(BaseModel):
    id: int
    rider_id: int
    start_station: int
    end_station: int | None = None
    tier: str
    started_at: datetime
    ended_at: datetime | None = None
    fare_cents: int | None = None
    status: str


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.post("/trips/start", response_model=StartTripResponse, status_code=201)
async def start_trip(req: StartTripRequest, identity: dict = Depends(current_identity)):
    if identity["role"] == "rider":
        rider_id = identity["rider_id"]
    else:  # admin
        if req.rider_id is None:
            raise HTTPException(status_code=422, detail="rider_id required for admin")
        rider_id = req.rider_id

    r = app.state.redis
    active_key = ACTIVE_KEY_FMT.format(rider_id=rider_id)

    if await r.exists(active_key):
        raise HTTPException(status_code=409, detail="rider already has an active trip")

    try:
        resp = await app.state.http.get(
            f"{RIDER_URL}/riders/{rider_id}", headers=_trace_headers()
        )
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"rider service unavailable: {exc}") from exc

    if resp.status_code == 404:
        raise HTTPException(status_code=422, detail="rider does not exist")
    if resp.status_code >= 400:
        raise HTTPException(status_code=502, detail="rider service error")

    async with app.state.db.acquire() as conn:
        row = await conn.fetchrow(
            """
            INSERT INTO trips (rider_id, start_station, tier, started_at, status)
            VALUES ($1, $2, $3, now(), 'active')
            RETURNING id
            """,
            rider_id,
            req.station_id,
            req.tier,
        )
    trip_id = row["id"]

    await r.set(active_key, trip_id, ex=ACTIVE_TTL_SECONDS)

    log.info(
        "trip_started",
        extra={
            "event": "trip_started",
            "service": SERVICE,
            "request_id": request_id_ctx.get(),
            "trip_id": trip_id,
            "rider_id": rider_id,
            "station_id": req.station_id,
        },
    )
    return StartTripResponse(trip_id=trip_id, status="active")


@app.post("/trips/{trip_id}/end", response_model=EndTripResponse)
async def end_trip(trip_id: int, req: EndTripRequest, identity: dict = Depends(current_identity)):
    async with app.state.db.acquire() as conn:
        trip = await conn.fetchrow(
            "SELECT * FROM trips WHERE id = $1 AND status = 'active'",
            trip_id,
        )
        if trip is None:
            raise HTTPException(status_code=404, detail="active trip not found")

        if identity["role"] == "rider" and trip["rider_id"] != identity["rider_id"]:
            raise HTTPException(status_code=403, detail="not your trip")

        started_at = trip["started_at"]
        now = datetime.now(timezone.utc)
        minutes = math.ceil((now - started_at).total_seconds() / 60)

        try:
            resp = await app.state.http.post(
                f"{PRICING_URL}/fare",
                json={"minutes": minutes, "tier": trip["tier"], "surge": req.surge},
                headers=_trace_headers(),
            )
        except httpx.HTTPError as exc:
            raise HTTPException(
                status_code=502, detail=f"pricing service unavailable: {exc}"
            ) from exc

        if resp.status_code >= 400:
            raise HTTPException(status_code=502, detail="pricing service error")

        fare_cents = resp.json()["cents"]

        await conn.execute(
            """
            UPDATE trips
            SET ended_at = $2, end_station = $3, fare_cents = $4, status = 'completed'
            WHERE id = $1
            """,
            trip_id,
            now,
            req.end_station_id,
            fare_cents,
        )

    r = app.state.redis
    await r.delete(ACTIVE_KEY_FMT.format(rider_id=trip["rider_id"]))
    await r.xadd(
        COMPLETED_STREAM,
        {
            "trip_id": trip_id,
            "rider_id": trip["rider_id"],
            "fare_cents": fare_cents,
            "minutes": minutes,
        },
    )

    log.info(
        "trip_completed",
        extra={
            "event": "trip_completed",
            "service": SERVICE,
            "request_id": request_id_ctx.get(),
            "trip_id": trip_id,
            "rider_id": trip["rider_id"],
            "fare_cents": fare_cents,
            "minutes": minutes,
        },
    )
    return EndTripResponse(
        trip_id=trip_id, status="completed", fare_cents=fare_cents, minutes=minutes
    )


@app.get("/trips/{trip_id}", response_model=TripRecord)
async def get_trip(trip_id: int, identity: dict = Depends(current_identity)):
    async with app.state.db.acquire() as conn:
        row = await conn.fetchrow("SELECT * FROM trips WHERE id = $1", trip_id)
    if row is None:
        raise HTTPException(status_code=404, detail="trip not found")
    if identity["role"] == "rider" and row["rider_id"] != identity["rider_id"]:
        raise HTTPException(status_code=403, detail="not your trip")
    return TripRecord(**dict(row))


@app.get("/trips", response_model=list[TripRecord])
async def list_trips(limit: int = 50, identity: dict = Depends(current_identity)):
    async with app.state.db.acquire() as conn:
        if identity["role"] == "rider":
            rows = await conn.fetch(
                "SELECT * FROM trips WHERE rider_id = $1 ORDER BY id DESC LIMIT $2",
                identity["rider_id"],
                limit,
            )
        else:  # admin
            rows = await conn.fetch(
                "SELECT * FROM trips ORDER BY id DESC LIMIT $1", limit
            )
    return [TripRecord(**dict(row)) for row in rows]
