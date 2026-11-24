# ADR 0004: Compute golden signals before tail sampling

**Status:** Accepted

## Context
Storing every trace is expensive. Tail sampling keeps every failed and slow trace and 10% of the rest, which is exactly what an engineer wants when debugging. But the stored traces are no longer a fair sample: errors are over-represented on purpose.

## Decision
- The Collector's `spanmetrics` connector turns 100% of spans into request count and duration metrics, before the `tail_sampling` processor.
- Golden signals, SLOs and alerts in Snowflake read those metrics, never the sampled spans.
- Sampled spans are used for investigation: waterfalls, slow operations, linked logs.

## Consequences
- Accurate error rates at a fraction of the trace storage. On a normal day, counting from kept traces would have reported 1.91% errors for lift tickets instead of the true 0.2%.
- Tail sampling needs every span of a trace on one Collector. One replica is fine for the lab; at scale, a load-balancing exporter tier routes spans by trace ID.
- Span metric cardinality must stay low: service, endpoint, kind and status only.
