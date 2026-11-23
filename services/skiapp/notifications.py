"""Notifications service: sends confirmation emails (simulated)."""
from __future__ import annotations

import asyncio
import random

from fastapi import FastAPI, HTTPException
from opentelemetry import trace
from pydantic import BaseModel

from skiapp.telemetry import setup

app = FastAPI(title="notifications")
log = setup(app, "notifications")
tracer = trace.get_tracer("notifications")


class Message(BaseModel):
    guest_email: str
    template: str


@app.post("/send")
async def send(msg: Message):
    trace.get_current_span().set_attribute("notification.template", msg.template)
    with tracer.start_as_current_span("email.send", kind=trace.SpanKind.CLIENT) as span:
        span.set_attribute("peer.service", "snowmail")
        await asyncio.sleep(random.uniform(0.02, 0.07))
        if random.random() < 0.004:
            log.error("Email provider rejected message for %s", msg.guest_email)
            raise HTTPException(status_code=500, detail="email provider error")
    log.info("Sent %s to %s", msg.template, msg.guest_email)
    return {"sent": True}


@app.get("/healthz")
async def healthz():
    return {"ok": True}
