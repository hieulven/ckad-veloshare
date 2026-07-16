"""station service — station & dock inventory.

GET    /healthz                    -> {"status": "ok"}
POST   /stations                   -> create a station
GET    /stations/{id}              -> fetch a station (404 if missing)
GET    /stations                   -> list stations
DELETE /stations/{id}              -> delete a station (404 if missing)
PATCH  /stations/{id}/docks        -> update docks_available (404 if missing)
"""

import logging
import os
import time
import uuid
from contextlib import asynccontextmanager
from contextvars import ContextVar

import asyncpg
from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel, Field
from pythonjsonlogger import jsonlogger

SERVICE = "station"
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

    Supplied by the station-db Secret (see env/station.env.template).
    """
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"{name} is required but not set")
    return value


DB_HOST = os.environ.get("DB_HOST", "postgres")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "veloshare")
DB_USER = os.environ.get("DB_USER", "station")
DB_PASSWORD = require_env("DB_PASSWORD")
DB_SCHEMA = os.environ.get("DB_SCHEMA", "stations")


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
    try:
        yield
    finally:
        await app.state.pool.close()


app = FastAPI(title="station", lifespan=lifespan)


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


class StationIn(BaseModel):
    name: str
    capacity: int = Field(ge=0)


class Station(BaseModel):
    id: int
    name: str
    capacity: int
    docks_available: int


class DocksUpdate(BaseModel):
    docks_available: int = Field(ge=0)


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.post("/stations", response_model=Station, status_code=201)
async def create_station(req: StationIn):
    async with app.state.pool.acquire() as conn:
        row = await conn.fetchrow(
            """
            INSERT INTO stations (name, capacity, docks_available)
            VALUES ($1, $2, $2)
            RETURNING id, name, capacity, docks_available
            """,
            req.name,
            req.capacity,
        )
    log.info(
        "station_created",
        extra={
            "event": "station_created",
            "service": SERVICE,
            "request_id": request_id_ctx.get(),
            "station_id": row["id"],
            "capacity": row["capacity"],
        },
    )
    return Station(**dict(row))


@app.get("/stations/{station_id}", response_model=Station)
async def get_station(station_id: int):
    async with app.state.pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id, name, capacity, docks_available FROM stations WHERE id = $1",
            station_id,
        )
    if row is None:
        raise HTTPException(status_code=404, detail="station not found")
    return Station(**dict(row))


@app.get("/stations", response_model=list[Station])
async def list_stations():
    async with app.state.pool.acquire() as conn:
        rows = await conn.fetch(
            "SELECT id, name, capacity, docks_available FROM stations ORDER BY id"
        )
    return [Station(**dict(row)) for row in rows]


@app.delete("/stations/{station_id}", status_code=204)
async def delete_station(station_id: int):
    async with app.state.pool.acquire() as conn:
        result = await conn.execute("DELETE FROM stations WHERE id = $1", station_id)
    if result == "DELETE 0":
        raise HTTPException(status_code=404, detail="station not found")
    return None


@app.patch("/stations/{station_id}/docks", response_model=Station)
async def update_docks(station_id: int, req: DocksUpdate):
    async with app.state.pool.acquire() as conn:
        row = await conn.fetchrow(
            """
            UPDATE stations SET docks_available = $2
            WHERE id = $1
            RETURNING id, name, capacity, docks_available
            """,
            station_id,
            req.docks_available,
        )
    if row is None:
        raise HTTPException(status_code=404, detail="station not found")
    log.info(
        "docks_updated",
        extra={
            "event": "docks_updated",
            "service": SERVICE,
            "request_id": request_id_ctx.get(),
            "station_id": row["id"],
            "docks_available": row["docks_available"],
        },
    )
    return Station(**dict(row))
