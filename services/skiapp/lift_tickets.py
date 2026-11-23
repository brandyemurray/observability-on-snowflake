"""Lift tickets service: sells day passes, then charges and notifies the guest."""
from __future__ import annotations

import os

import httpx
from fastapi import FastAPI, HTTPException
from opentelemetry import metrics, trace
from pydantic import BaseModel

from skiapp.telemetry import setup

app = FastAPI(title="lift-tickets")
log = setup(app, "lift-tickets")
meter = metrics.get_meter("lift-tickets")

PAYMENTS_URL = os.getenv("PAYMENTS_URL", "http://payments:8000")
NOTIFICATIONS_URL = os.getenv("NOTIFICATIONS_URL", "http://notifications:8000")
PAYMENTS_TIMEOUT_S = float(os.getenv("PAYMENTS_TIMEOUT_S", "2.0"))

PRICES = {"day_pass": 189.0, "half_day": 139.0, "child_day": 99.0, "multi_day_3": 519.0}

tickets_sold = meter.create_counter("tickets.sold", unit="{ticket}", description="Lift tickets sold")
client = httpx.AsyncClient()


class TicketOrder(BaseModel):
    guest_name: str
    guest_email: str
    card_number: str
    product: str
    quantity: int = 1


@app.post("/tickets")
async def buy_tickets(order: TicketOrder):
    span = trace.get_current_span()
    span.set_attribute("ticket.product", order.product)
    span.set_attribute("ticket.quantity", order.quantity)
    span.set_attribute("guest.email", order.guest_email)

    if order.product not in PRICES:
        raise HTTPException(status_code=400, detail=f"unknown product {order.product}")
    amount = PRICES[order.product] * order.quantity

    try:
        resp = await client.post(
            f"{PAYMENTS_URL}/charge",
            json={"guest_email": order.guest_email, "card_number": order.card_number,
                  "amount": amount, "description": f"{order.quantity} x {order.product}"},
            timeout=PAYMENTS_TIMEOUT_S,
        )
    except httpx.TimeoutException:
        log.error("Checkout failed: payments did not answer within %.1fs", PAYMENTS_TIMEOUT_S)
        raise HTTPException(status_code=504, detail="payments timeout")
    if resp.status_code != 200:
        log.error("Checkout failed: payments returned %s", resp.status_code)
        raise HTTPException(status_code=502, detail="payment failed")

    tickets_sold.add(order.quantity, {"ticket.product": order.product})

    # A missed confirmation email should never fail the sale.
    try:
        await client.post(f"{NOTIFICATIONS_URL}/send", timeout=1.0,
                          json={"guest_email": order.guest_email, "template": "ticket_confirmation"})
    except httpx.HTTPError:
        log.warning("Confirmation email not sent for order; continuing")

    log.info("Sold %d %s for $%.2f", order.quantity, order.product, amount)
    return {"status": "confirmed", "amount": amount, "charge_id": resp.json()["charge_id"]}


@app.get("/healthz")
async def healthz():
    return {"ok": True}
