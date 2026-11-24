# ADR 0003: Micro-batch into Snowflake through a loader service

**Status:** Accepted for the lab; revisit for production

## Context
The Collector needs to deliver OTLP to Snowflake. Options: a custom exporter, Snowpipe Streaming, or files loaded with PUT and COPY.

## Decision
- The Collector's standard `otlphttp` exporter sends OTLP/JSON to a small loader service.
- The loader keeps each export request unchanged, writes a file every 30 seconds per signal, PUTs it to an internal stage and runs `COPY INTO` the RAW table (one VARIANT column).
- Files stay on local disk until the PUT succeeds, and COPY's load history prevents duplicates.

## Consequences
- Simple to inspect and debug: every batch is a file you can open.
- About 30–60 seconds from event to query, which is fine for minute-level golden signals.
- A warehouse runs while data flows. At production volume, **Snowpipe Streaming** replaces PUT and COPY: lower latency, serverless, and no warehouse kept awake by ingestion.
- The lab spool is an `emptyDir`; production needs a persistent volume.
