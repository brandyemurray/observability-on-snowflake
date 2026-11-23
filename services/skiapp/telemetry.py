"""OpenTelemetry setup shared by every Summit Peak service.

Each service calls ``setup(app, "service-name")`` once at startup. That wires up
traces, metrics and logs, all exported over OTLP/HTTP to the OpenTelemetry
Collector. The Collector, not the app, decides where telemetry goes next
(Snowflake, Jaeger, or both), so the app never needs a vendor SDK.
"""
from __future__ import annotations

import logging
import os

from opentelemetry import metrics, trace
from opentelemetry._logs import set_logger_provider
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

VERSION = os.getenv("SERVICE_VERSION", "1.4.2")


def setup(app, service_name: str) -> logging.Logger:
    """Configure OpenTelemetry for one service and return its logger.

    The OTLP endpoint comes from the standard OTEL_EXPORTER_OTLP_ENDPOINT
    variable (for example http://otel-collector:4318), so the same image runs
    in Kubernetes, in Docker, or on a laptop.
    """
    resource = Resource.create(
        {
            "service.name": service_name,
            "service.namespace": "summit-peak",
            "service.version": VERSION,
            "deployment.environment.name": os.getenv("DEPLOY_ENV", "lab"),
        }
    )

    # Traces: every request becomes a span; the Collector does the sampling,
    # so the app sends everything and sampling decisions stay in one place.
    tracer_provider = TracerProvider(resource=resource)
    tracer_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(tracer_provider)

    # Metrics: HTTP server metrics from the FastAPI instrumentation plus any
    # business metrics the service records, exported every 15 seconds.
    reader = PeriodicExportingMetricReader(OTLPMetricExporter(), export_interval_millis=15_000)
    metrics.set_meter_provider(MeterProvider(resource=resource, metric_readers=[reader]))

    # Logs: standard Python logging, shipped over OTLP with the trace ID and
    # span ID attached, so a log line links straight to its trace.
    logger_provider = LoggerProvider(resource=resource)
    logger_provider.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter()))
    set_logger_provider(logger_provider)

    logger = logging.getLogger(service_name)
    logger.setLevel(logging.INFO)
    logger.addHandler(LoggingHandler(level=logging.INFO, logger_provider=logger_provider))
    console = logging.StreamHandler()
    console.setFormatter(logging.Formatter("%(asctime)s %(name)s %(levelname)s %(message)s"))
    logger.addHandler(console)
    logger.propagate = False

    # Skip the ASGI "receive"/"send" child spans: they add volume, not insight.
    FastAPIInstrumentor.instrument_app(app, excluded_urls="healthz,admin/.*", exclude_spans=["receive", "send"])
    HTTPXClientInstrumentor().instrument()
    return logger
