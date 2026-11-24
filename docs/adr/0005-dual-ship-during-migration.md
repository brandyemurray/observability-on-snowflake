# ADR 0005: Dual-ship traces during the migration

**Status:** Accepted

## Context
Moving observability to a new platform is risky if the first test is the cutover. Teams need to see the same incident in both tools before they trust the new one.

## Decision
- The Collector exports traces to Snowflake and to the incumbent tool at the same time. In the lab, Jaeger stands in for the incumbent (in a real migration this is, for example, the Datadog exporter).
- Each team's dashboards, alerts and runbooks move one at a time, and are compared side by side before the old ones are turned off.
- Rollback is removing an exporter from the Collector config.

## Consequences
- Temporarily higher cost while both receive data.
- A clear exit criterion per team: same request counts, same error rates, alerts firing at the same time, on-call comfortable with the new runbook.
- See `docs/migration-plan.md` for the phases.
