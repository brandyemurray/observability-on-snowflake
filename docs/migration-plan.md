# Migration plan: incumbent vendor to OpenTelemetry and Snowflake

A phased plan with an exit check at each phase. Rollback at every step is a Collector config change.

| Phase | What happens | Exit check |
|---|---|---|
| **0. Discovery** (1–2 weeks) | Inventory services, dashboards, alerts, data volumes and retention needs. Agree on SLOs for the top user journeys. Identify PII in telemetry. | Signed-off SLO list; PII rules written. |
| **1. Instrument** (2–4 weeks) | Replace vendor agents with OpenTelemetry SDKs, one service at a time. Deploy Collectors (agent and gateway). Keep exporting to the incumbent only. | No change visible in the incumbent tool. |
| **2. Dual-ship** (2–4 weeks) | Add the Snowflake exporter. Build golden signals, SLOs and alerts in Snowflake. | For each service: request counts within 1%, same error rates, alerts fire within a minute of each other. |
| **3. Cut over by team** (4–8 weeks) | Move each team's dashboards, alerts and runbooks. Run one game day per team (like the powder-day drill). | Team signs off; on-call has handled at least one real or simulated incident in the new tool. |
| **4. Decommission** | Remove the incumbent exporter; cancel the contract at renewal. | Cost report shows the savings; no team relies on the old tool. |

**Risks to watch:** cardinality growth in metrics (cost), Collector capacity during peaks, alert noise during dual-running, and teams that rely on vendor-specific features (synthetics, RUM) that need their own replacements.
