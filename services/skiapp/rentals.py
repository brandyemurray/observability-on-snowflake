"""Rentals service: reserves skis, snowboards and helmets, then charges the guest."""
from __future__ import annotations

import os
import random

import httpx
from fastapi import FastAPI, HTTPException
from opentelemetry import metrics, trace
from pydantic import BaseModel

from skiapp.telemetry import setup

app = FastAPI(title="rentals")
log = setup(app, "rentals")
tracer = trace.get_tracer("rentals")
meter = metrics.get_meter("rentals")

PAYMENTS_URL = os.getenv("PAYMENTS_URL", "http://payments:8000")
NOTIFICATIONS_URL = os.getenv("NOTIFICATIONS_URL", "http://notifications:8000")
PAYMENTS_TIMEOUT_S = float(os.getenv("PAYMENTS_TIMEOUT_S", "2.0"))

DAILY_RATE = {"skis": 65.0, "snowboard": 60.0, "helmet": 15.0, "boots": 25.0}

rentals_booked = meter.create_counter("rentals.booked", unit="{rental}", description="Rentals reserved")
client = httpx.AsyncClient()


class RentalOrder(BaseModel):
    guest_email: str
    card_number: str
    gear: str
    days: int = 1


@app.post("/rentals")
async def reserve(order: RentalOrder):
    span = trace.get_current_span()
    span.set_attribute("rental.gear", order.gear)
    span.set_attribute("rental.days", order.days)
    span.set_attribute("guest.email", order.guest_email)

    if order.gear not in DAILY_RATE:
        raise HTTPException(status_code=400, detail=f"unknown gear {order.gear}")

    with tracer.start_as_current_span("inventory.check") as inv:
        in_stock = random.random() > 0.03
        inv.set_attribute("rental.in_stock", in_stock)
    if not in_stock:
        # Sold out is a normal business outcome, not a system error.
        log.info("No %s left in the guest's size", order.gear)
        raise HTTPException(status_code=409, detail="sold out")

    amount = DAILY_RATE[order.gear] * order.days
    try:
        resp = await client.post(
            f"{PAYMENTS_URL}/charge",
            json={"guest_email": order.guest_email, "card_number": order.card_number,
                  "amount": amount, "description": f"{order.gear} rental, {order.days} day(s)"},
            timeout=PAYMENTS_TIMEOUT_S,
        )
    except httpx.TimeoutException:
        log.error("Rental checkout failed: payments did not answer within %.1fs", PAYMENTS_TIMEOUT_S)
        raise HTTPException(status_code=504, detail="payments timeout")
    if resp.status_code != 200:
        log.error("Rental checkout failed: payments returned %s", resp.status_code)
        raise HTTPException(status_code=502, detail="payment failed")

    rentals_booked.add(1, {"rental.gear": order.gear})
    try:
        await client.post(f"{NOTIFICATIONS_URL}/send", timeout=1.0,
                          json={"guest_email": order.guest_email, "template": "rental_confirmation"})
    except httpx.HTTPError:
        log.warning("Rental confirmation not sent; continuing")

    log.info("Reserved %s for %d day(s), $%.2f", order.gear, order.days, amount)
    return {"status": "reserved", "amount": amount}


@app.get("/healthz")
async def healthz():
    return {"ok": True}
