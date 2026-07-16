"""pricing service — stateless fare calculation.

GET  /healthz -> {"status": "ok"}
POST /fare    -> {"cents": <int>}
"""

import json
import logging
import os
import time
import uuid
from contextvars import ContextVar

from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel, Field
from pythonjsonlogger import jsonlogger

SERVICE = "pricing"
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

UNLOCK_FEE_CENTS: int = int(os.environ.get("PRICING_UNLOCK_FEE_CENTS", "100"))
TIER_RATES: dict[str, int] = json.loads(
    os.environ.get(
        "PRICING_TIER_RATES",
        '{"standard": 15, "member": 8, "day_pass": 5}',
    )
)

app = FastAPI(title="pricing")


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


class FareRequest(BaseModel):
    minutes: int = Field(ge=0)
    tier: str
    surge: float = Field(ge=0)


class FareResponse(BaseModel):
    cents: int


class TierInfo(BaseModel):
    tier: str
    per_minute_cents: int


class TiersResponse(BaseModel):
    unlock_fee_cents: int
    tiers: list[TierInfo]


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/tiers", response_model=TiersResponse)
async def tiers():
    return TiersResponse(
        unlock_fee_cents=UNLOCK_FEE_CENTS,
        tiers=[
            TierInfo(tier=name, per_minute_cents=rate)
            for name, rate in sorted(TIER_RATES.items())
        ],
    )


@app.post("/fare", response_model=FareResponse)
async def fare(req: FareRequest):
    if req.tier not in TIER_RATES:
        raise HTTPException(status_code=422, detail=f"unknown tier: {req.tier}")

    per_minute_cents = TIER_RATES[req.tier]
    cents = round(UNLOCK_FEE_CENTS + req.minutes * per_minute_cents * req.surge)
    log.info(
        "fare_computed",
        extra={
            "event": "fare_computed",
            "service": SERVICE,
            "request_id": request_id_ctx.get(),
            "minutes": req.minutes,
            "tier": req.tier,
            "surge": req.surge,
            "cents": cents,
        },
    )
    return FareResponse(cents=cents)
