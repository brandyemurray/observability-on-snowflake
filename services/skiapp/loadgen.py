"""Load generator: simulated guests buying lift tickets and renting gear.

It runs at a steady rate (requests per second) that can be changed at runtime:

    POST /rate {"rps": 30}     # powder day
    POST /rate {"rps": 4}      # a quiet Tuesday

All guest data is fake. Card numbers are standard test numbers.
"""
from __future__ import annotations

import asyncio
import os
import random
import time
from collections import Counter

import httpx
from fastapi import FastAPI
from pydantic import BaseModel

LIFT_TICKETS_URL = os.getenv("LIFT_TICKETS_URL", "http://lift-tickets:8000")
RENTALS_URL = os.getenv("RENTALS_URL", "http://rentals:8000")

state = {"rps": float(os.getenv("RPS", "4"))}
results: Counter = Counter()

FIRST = ["Avery", "Jordan", "Riley", "Casey", "Morgan", "Quinn", "Harper", "Rowan", "Sage", "Emerson",
         "Dakota", "Reese", "Skyler", "Finley", "Parker", "Hayden", "Logan", "Blake", "Tatum", "Kendall"]
LAST = ["Lindqvist", "Okafor", "Moreno", "Nakamura", "Becker", "Haddad", "Novak", "Silva", "Kowalski",
        "Brennan", "Sato", "Dubois", "Patel", "Larsen", "Romero", "Fischer", "Ivanova", "Walsh"]
DOMAINS = ["example.com", "mail.example.org", "inbox.example.net"]
TEST_CARDS = ["4111-1111-1111-1111", "5555-5555-5555-4444", "3782-822463-10005", "6011-1111-1111-1117"]
TICKETS = ["day_pass"] * 6 + ["half_day"] * 2 + ["child_day"] * 2 + ["multi_day_3"]
GEAR = ["skis"] * 5 + ["snowboard"] * 3 + ["helmet"] * 2 + ["boots"] * 2


def guest() -> dict:
    first, last = random.choice(FIRST), random.choice(LAST)
    return {
        "guest_name": f"{first} {last}",
        "guest_email": f"{first}.{last}{random.randint(1, 99)}@{random.choice(DOMAINS)}".lower(),
        "card_number": random.choice(TEST_CARDS),
    }


async def one_request(client: httpx.AsyncClient) -> None:
    g = guest()
    try:
        if random.random() < 0.7:
            r = await client.post(f"{LIFT_TICKETS_URL}/tickets", timeout=10, json={
                **g, "product": random.choice(TICKETS), "quantity": random.choice([1, 1, 1, 2, 2, 4])})
        else:
            r = await client.post(f"{RENTALS_URL}/rentals", timeout=10, json={
                "guest_email": g["guest_email"], "card_number": g["card_number"],
                "gear": random.choice(GEAR), "days": random.choice([1, 1, 2, 3])})
        results[r.status_code] += 1
    except httpx.HTTPError:
        results["connection_error"] += 1


async def run() -> None:
    async with httpx.AsyncClient() as client:
        last_report = time.monotonic()
        while True:
            rps = max(state["rps"], 0.1)
            # Poisson arrivals look like real traffic, not a metronome.
            await asyncio.sleep(random.expovariate(rps))
            asyncio.create_task(one_request(client))
            if time.monotonic() - last_report > 30:
                print(f"rps={state['rps']} results={dict(results)}", flush=True)
                results.clear()
                last_report = time.monotonic()


app = FastAPI(title="loadgen")


class Rate(BaseModel):
    rps: float


@app.on_event("startup")
async def start() -> None:
    asyncio.create_task(run())


@app.post("/rate")
async def set_rate(rate: Rate):
    state["rps"] = rate.rps
    print(f"Rate changed to {rate.rps} requests per second", flush=True)
    return state


@app.get("/rate")
async def get_rate():
    return {**state, "last_30s": dict(results)}
