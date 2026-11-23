"""Snowflake loader: receives OTLP/JSON from the Collector and micro-batches it into Snowflake.

The Collector sends traces, metrics and logs here with its standard otlphttp
exporter. This service:

1. accepts each OTLP export request and appends it, unchanged, to an in-memory batch;
2. every FLUSH_SECONDS writes each batch to a newline-delimited JSON file;
3. PUTs the file to an internal stage and runs COPY INTO the matching RAW table.

Files stay on local disk until the PUT succeeds, and COPY's load history
prevents duplicates, so a Snowflake outage delays data but doesn't lose it.
Without Snowflake settings it runs in local mode and keeps the files in
SPOOL_DIR, which is handy for testing the Collector on its own.

Production note: at higher volume, Snowpipe Streaming replaces PUT + COPY and
removes the need for a running warehouse. See docs/adr/0003-ingestion-path.md.
"""
from __future__ import annotations

import gzip
import json
import logging
import os
import threading
import time
import uuid
from pathlib import Path

from fastapi import FastAPI, Request, Response

SIGNALS = ("traces", "metrics", "logs")
FLUSH_SECONDS = int(os.getenv("FLUSH_SECONDS", "30"))
SPOOL_DIR = Path(os.getenv("SPOOL_DIR", "/data/spool"))
DATABASE = os.getenv("SNOWFLAKE_DATABASE", "SKI_OBS")
STAGE = f"{DATABASE}.RAW.OTLP_LANDING"

logging.basicConfig(level=logging.INFO, format="%(asctime)s loader %(levelname)s %(message)s")
log = logging.getLogger("loader")

app = FastAPI(title="snowflake-loader")
buffers: dict[str, list[str]] = {s: [] for s in SIGNALS}
lock = threading.Lock()
stats = {s: {"requests": 0, "files_loaded": 0, "rows_loaded": 0} for s in SIGNALS}
stats["last_error"] = None


def snowflake_enabled() -> bool:
    return bool(os.getenv("SNOWFLAKE_ACCOUNT"))


_conn = None


def connection():
    """Open (or reuse) a key-pair-authenticated connection as the loader service user."""
    global _conn
    if _conn is not None and not _conn.is_closed():
        return _conn
    import snowflake.connector  # imported lazily so local mode needs no Snowflake package

    _conn = snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.getenv("SNOWFLAKE_USER", "OBS_LOADER_SVC"),
        private_key_file=os.getenv("SNOWFLAKE_PRIVATE_KEY_PATH", "/secrets/loader_key.p8"),
        role=os.getenv("SNOWFLAKE_ROLE", "OBS_INGEST"),
        warehouse=os.getenv("SNOWFLAKE_WAREHOUSE", "OBS_INGEST_WH"),
        database=DATABASE,
        schema="RAW",
        application="summit-peak-otel-loader",
        client_session_keep_alive=True,
    )
    return _conn


@app.post("/v1/{signal}")
async def receive(signal: str, request: Request):
    if signal not in SIGNALS:
        return Response(status_code=404)
    body = await request.body()
    if request.headers.get("content-encoding") == "gzip":
        body = gzip.decompress(body)
    # Re-serialize compactly so each export request is exactly one line.
    line = json.dumps(json.loads(body), separators=(",", ":"))
    with lock:
        buffers[signal].append(line)
        stats[signal]["requests"] += 1
    # An empty object is a valid OTLP "full success" response.
    return Response(content="{}", media_type="application/json")


def write_spool_files() -> None:
    """Move whatever is buffered into one file per signal."""
    with lock:
        batches = {s: buffers[s] for s in SIGNALS if buffers[s]}
        for s in batches:
            buffers[s] = []
    for signal, lines in batches.items():
        folder = SPOOL_DIR / signal
        folder.mkdir(parents=True, exist_ok=True)
        name = f"{signal}-{time.strftime('%Y%m%dT%H%M%S')}-{uuid.uuid4().hex[:8]}.json"
        (folder / name).write_text("\n".join(lines) + "\n")


def load_to_snowflake() -> None:
    """PUT every spooled file, then COPY each signal's stage folder into its RAW table."""
    cur = connection().cursor()
    try:
        for signal in SIGNALS:
            files = sorted((SPOOL_DIR / signal).glob("*.json")) if (SPOOL_DIR / signal).exists() else []
            for f in files:
                cur.execute(f"PUT 'file://{f}' @{STAGE}/{signal}/ AUTO_COMPRESS=TRUE OVERWRITE=FALSE")
                f.unlink()
            if not files:
                continue
            cur.execute(
                f"""COPY INTO {DATABASE}.RAW.OTLP_{signal.upper()} (PAYLOAD, FILE_NAME)
                    FROM (SELECT $1, METADATA$FILENAME FROM @{STAGE}/{signal}/)
                    FILE_FORMAT = (TYPE = JSON)
                    PURGE = TRUE"""
            )
            for row in cur.fetchall():
                # COPY returns one row per file: (file, status, rows_parsed, rows_loaded, ...)
                if len(row) > 3 and row[1] == "LOADED":
                    stats[signal]["files_loaded"] += 1
                    stats[signal]["rows_loaded"] += int(row[3])
            log.info("Loaded %d %s file(s) into RAW.OTLP_%s", len(files), signal, signal.upper())
    finally:
        cur.close()


def flusher() -> None:
    while True:
        time.sleep(FLUSH_SECONDS)
        try:
            write_spool_files()
            if snowflake_enabled():
                load_to_snowflake()
            stats["last_error"] = None
        except Exception as exc:  # keep the files and try again next cycle
            global _conn
            _conn = None
            stats["last_error"] = f"{type(exc).__name__}: {exc}"
            log.exception("Load failed; spooled files are kept and will be retried")


@app.on_event("startup")
def start() -> None:
    SPOOL_DIR.mkdir(parents=True, exist_ok=True)
    mode = "Snowflake" if snowflake_enabled() else "local files only"
    log.info("Loader started: flushing every %ss to %s", FLUSH_SECONDS, mode)
    threading.Thread(target=flusher, daemon=True).start()


@app.get("/healthz")
def healthz():
    return {"ok": True, "mode": "snowflake" if snowflake_enabled() else "local", **stats}
