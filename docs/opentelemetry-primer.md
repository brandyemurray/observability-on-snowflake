# OpenTelemetry primer

Short notes on the ideas this lab is built on, each tied to where it shows up in the repo.

## The three signals

| Signal | What it answers | In this lab |
|---|---|---|
| **Traces** | What happened to *this* request, step by step, across services? | A ticket purchase is one trace: lift-tickets → payments → provider, plus the email from notifications. Each step is a **span** with a start, an end, a status and attributes. |
| **Metrics** | How is the system doing *overall*, over time? | Request counts, latency histograms, provider connections in use. Cheap to store, good for dashboards and alerts. |
| **Logs** | What did the code say at that moment? | Python `logging`, shipped over OTLP with the trace ID attached, so a log line links straight to its trace. |

The point of OpenTelemetry is that all three share one context (trace ID, span ID) and one description of where they came from (the **resource**: service name, version, pod, node).

## The pieces

- **API and SDK.** The app uses the API to create spans and record metrics; the SDK batches them and sends them out. Auto-instrumentation (FastAPI and httpx here) creates the request spans for you. See [services/skiapp/telemetry.py](../services/skiapp/telemetry.py).
- **OTLP.** The wire protocol, over gRPC (port 4317) or HTTP (4318), as protobuf or JSON. Because every vendor accepts it, the app never needs a vendor SDK.
- **Collector.** A separate process that receives, processes and exports telemetry. Its config has four parts:
  - **receivers**: where data comes in (`otlp`)
  - **processors**: what happens to it (`memory_limiter`, `k8sattributes`, `transform`, `tail_sampling`, `batch`)
  - **exporters**: where it goes (`otlphttp` to the Snowflake loader, `otlp` to Jaeger)
  - **connectors**: an exporter for one pipeline that is a receiver for another (`spanmetrics` turns spans into metrics)
- **Semantic conventions.** Standard attribute names (`service.name`, `http.route`, `k8s.pod.name`), so tools can understand data from any app.

## Collector deployment patterns

- **Agent** (DaemonSet, one per node): collects from local pods and the node itself (host metrics, container logs). Cheap hop, close to the source.
- **Gateway** (Deployment, shared): central processing such as sampling, redaction and routing to backends.
- Most production setups use both: agents forward to a gateway tier. This lab uses a single gateway to stay small.

## Sampling

- **Head sampling** decides when a trace starts (for example, keep 10%). Cheap, but it can't know whether the request will fail.
- **Tail sampling** waits until the trace is finished (10 seconds here), then decides. It can keep every error and every slow request. The cost: all spans of a trace must reach the same Collector, and the Collector holds traces in memory while it waits.
- **The trap:** after sampling, the stored traces are no longer a fair sample. Errors are over-represented on purpose. That's why this lab computes request and error rates from span metrics *before* sampling.

## Golden signals, RED and USE

- **Four golden signals** (from Google's SRE book): latency, traffic, errors, saturation. See `SKI_OBS.OPS.GOLDEN_SIGNALS`.
- **RED** for request-driven services: rate, errors, duration.
- **USE** for resources: utilization, saturation, errors. The provider connection pool is the resource that saturates in this lab: `payments.provider.inflight` climbs far past the pool size of 8 during the incident.

## SLIs, SLOs and error budgets

- **SLI:** the measurement (share of checkout requests that succeed).
- **SLO:** the target (98% succeed over a window). Stored as data in `SKI_OBS.OPS.SLOS`, so it can change without code.
- **Error budget:** the 2% you're allowed to fail. Burning it fast is what should wake someone up, not one bad minute.

## Cardinality

Every unique combination of metric attributes is a separate time series. `service.name` × `http.route` × `status.code` is fine. Adding `guest.email` or a request ID to a metric creates one series per guest and can explode cost. Keep high-cardinality detail on spans and logs, not metrics.

## Kubernetes in two minutes

- **Pod:** one or more containers that run together. **Deployment:** keeps N copies of a pod running and replaces them on change. **Service:** a stable name and address for a set of pods. **Namespace:** a folder for resources (`summit-peak` for the app, `observability` for the pipeline).
- The Collector's `k8sattributes` processor sees which pod sent the data (by its IP), asks the Kubernetes API about that pod, and adds its name, deployment, namespace and node. That's why the Collector needs a ServiceAccount with read access to pods.

## Migrating off an incumbent vendor

1. **Instrument with OpenTelemetry**, not the vendor's agent, so the code never changes again.
2. **Put a Collector in the middle** and keep sending to the current vendor.
3. **Dual-ship** to the new platform (this lab sends traces to both Snowflake and Jaeger).
4. **Compare** the two side by side: same request counts, same error rates, the alerts fire at the same time.
5. **Cut over** dashboards, alerts and runbooks one team at a time, then turn the old exporter off. Rollback is a config change.
