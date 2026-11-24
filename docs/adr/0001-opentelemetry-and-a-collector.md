# ADR 0001: Instrument with OpenTelemetry and route everything through a Collector

**Status:** Accepted

## Context
Summit Peak's services need traces, metrics and logs. The resort also wants the option to change observability vendors without touching application code, and to evaluate Snowflake as the telemetry store while the current tool keeps running.

## Decision
- Instrument every service with the OpenTelemetry SDK (auto-instrumentation for FastAPI and httpx, plus a few business metrics).
- Services export OTLP to an OpenTelemetry Collector and know nothing about any backend.
- All routing, enrichment, redaction and sampling happens in the Collector configuration.

## Consequences
- Changing or adding a backend is a Collector config change, not a code release.
- One place to enforce data rules (ADR 0002) and sampling (ADR 0004).
- The Collector becomes critical infrastructure: it needs memory limits, health checks and, at scale, more than one replica.
