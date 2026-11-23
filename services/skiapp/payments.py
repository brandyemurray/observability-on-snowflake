"""Payments service: charges a guest's card through an outside payment provider.

The provider is simulated. It has a small connection pool, like most real
payment gateways, and its latency can be raised at runtime to simulate a
degraded provider. Under normal load the pool is plenty. On a powder day with a
slow provider, requests queue for a connection, then time out. That is the
incident this lab is built to catch.
"""
from __future__ import annotations

import asyncio
import os
import random
import time

from fastapi import FastAPI, HTTPException
from opentelemetry import metrics, trace
from pydantic import BaseModel

from skiapp.telemetry import setup

app = FastAPI(title="payments")
log = setup(app, "payments")
tracer = trace.get_tracer("payments")
meter = metrics.get_meter("payments")

POOL_SIZE = int(os.getenv("PROVIDER_POOL_SIZE", "8"))
PROVIDER_TIMEOUT_S = float(os.getenv("PROVIDER_TIMEOUT_S", "2.5"))

# Mutable runtime settings, changed through /admin/provider during the lab.
provider = {"latency_ms": 120.0, "error_rate": 0.002}
pool = asyncio.Semaphore(POOL_SIZE)

inflight = meter.create_up_down_counter(
    "payments.provider.inflight", unit="{request}",
    description="Charges currently waiting for or holding a provider connection",
)
provider_duration = meter.create_histogram(
    "payments.provider.duration", unit="ms", description="Time spent calling the payment provider",
)
charged = meter.create_counter("payments.charged", unit="USD", description="Dollars charged")


class Charge(BaseModel):
    guest_email: str
    card_number: str
    amount: float
    description: str


class ProviderSettings(BaseModel):
    latency_ms: float | None = None
    error_rate: float | None = None


async def call_provider(charge: Charge) -> str:
    """Wait for a pooled provider connection, then make the (simulated) call."""
    with tracer.start_as_current_span("provider.pool.wait") as wait_span:
        started = time.perf_counter()
        await asyncio.wait_for(pool.acquire(), timeout=PROVIDER_TIMEOUT_S)
        wait_span.set_attribute("pool.wait_ms", round((time.perf_counter() - started) * 1000, 1))
    try:
        with tracer.start_as_current_span("provider.charge", kind=trace.SpanKind.CLIENT) as span:
            span.set_attribute("peer.service", "alpine-pay")
            span.set_attribute("payment.amount", charge.amount)
            latency_s = max(0.02, random.gauss(provider["latency_ms"], provider["latency_ms"] * 0.2)) / 1000
            call_started = time.perf_counter()
            await asyncio.sleep(latency_s)
            provider_duration.record((time.perf_counter() - call_started) * 1000)
            if random.random() < provider["error_rate"]:
                raise RuntimeError("alpine-pay returned 503")
            return f"ch_{random.getrandbits(48):012x}"
    finally:
        pool.release()


@app.post("/charge")
async def charge(req: Charge):
    span = trace.get_current_span()
    # These attributes include guest PII on purpose. The Collector hashes the
    # email and masks the card number before anything leaves the cluster.
    span.set_attribute("guest.email", req.guest_email)
    span.set_attribute("payment.card_number", req.card_number)
    span.set_attribute("payment.amount", req.amount)

    # Deliberately unsafe log line: shows the Collector's redaction at work.
    log.info("Charging card %s for %s: $%.2f %s", req.card_number, req.guest_email, req.amount, req.description)

    inflight.add(1)
    try:
        charge_id = await call_provider(req)
    except asyncio.TimeoutError:
        log.error("Payment provider timed out after %.1fs (pool size %d) for %s",
                  PROVIDER_TIMEOUT_S, POOL_SIZE, req.guest_email)
        raise HTTPException(status_code=504, detail="payment provider timeout")
    except RuntimeError as exc:
        log.error("Payment provider error: %s", exc)
        raise HTTPException(status_code=502, detail=str(exc))
    finally:
        inflight.add(-1)

    charged.add(req.amount)
    log.info("Charge %s approved: $%.2f", charge_id, req.amount)
    return {"charge_id": charge_id, "status": "approved"}


@app.post("/admin/provider")
async def set_provider(settings: ProviderSettings):
    """Change the simulated provider's latency or error rate at runtime."""
    if settings.latency_ms is not None:
        provider["latency_ms"] = settings.latency_ms
    if settings.error_rate is not None:
        provider["error_rate"] = settings.error_rate
    log.warning("Provider settings changed: %s", provider)
    return provider


@app.get("/healthz")
async def healthz():
    return {"ok": True}
