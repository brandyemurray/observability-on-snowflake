-- =============================================================================
-- 02_models.sql: turn OTLP payloads into one row per span, log record and metric point
--
-- OTLP nests everything: request > resource > scope > span (or log, or metric).
-- Attributes arrive as lists of {key, value: {stringValue | intValue | ...}}.
-- OTEL.ATTRS() converts that list into a normal object, so a column reads as
-- ATTRIBUTES:"http.route" instead of a nested search.
--
-- Timestamps are UTC (TIMESTAMP_NTZ). Compare them to SYSDATE(), not CURRENT_TIMESTAMP().
-- =============================================================================
USE ROLE OBS_ADMIN;
USE WAREHOUSE OBS_QUERY_WH;
USE SCHEMA SKI_OBS.OTEL;

CREATE OR REPLACE FUNCTION ATTRS(ATTRIBUTE_LIST VARIANT)
  RETURNS OBJECT
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.11'
  HANDLER = 'to_object'
  COMMENT = 'OTLP attribute list -> object keyed by attribute name'
AS
$$
def _value(v):
    if not v:
        return None
    if "stringValue" in v:
        return v["stringValue"]
    if "intValue" in v:
        return int(v["intValue"])
    if "doubleValue" in v:
        return float(v["doubleValue"])
    if "boolValue" in v:
        return bool(v["boolValue"])
    if "arrayValue" in v:
        return [_value(x) for x in v["arrayValue"].get("values", [])]
    if "kvlistValue" in v:
        return {x["key"]: _value(x.get("value")) for x in v["kvlistValue"].get("values", [])}
    return None

def to_object(attribute_list):
    # A missing list arrives as SQL NULL or JSON null (sqlNullWrapper): treat both as empty.
    if not isinstance(attribute_list, list):
        return {}
    return {a["key"]: _value(a.get("value")) for a in attribute_list if isinstance(a, dict) and "key" in a}
$$;

-- -----------------------------------------------------------------------------
-- SPANS: one row per span (only sampled traces reach Snowflake; see ADR 0004)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW SPANS
  COMMENT = 'One row per span, from sampled traces'
AS
SELECT
  ATTRS(rs.value:resource:attributes)                         AS RESOURCE_ATTRS,
  RESOURCE_ATTRS:"service.name"::STRING                             AS SERVICE_NAME,
  RESOURCE_ATTRS:"k8s.deployment.name"::STRING                      AS DEPLOYMENT,
  RESOURCE_ATTRS:"k8s.pod.name"::STRING                             AS POD_NAME,
  s.value:traceId::STRING                                     AS TRACE_ID,
  s.value:spanId::STRING                                      AS SPAN_ID,
  NULLIF(s.value:parentSpanId::STRING, '')                    AS PARENT_SPAN_ID,
  s.value:name::STRING                                        AS SPAN_NAME,
  DECODE(s.value:kind::INT, 1, 'INTERNAL', 2, 'SERVER', 3, 'CLIENT',
                            4, 'PRODUCER', 5, 'CONSUMER', 'UNSPECIFIED') AS SPAN_KIND,
  TO_TIMESTAMP_NTZ(s.value:startTimeUnixNano::NUMBER(38, 0), 9) AS START_TIME,
  TO_TIMESTAMP_NTZ(s.value:endTimeUnixNano::NUMBER(38, 0), 9)   AS END_TIME,
  (s.value:endTimeUnixNano::NUMBER(38, 0)
     - s.value:startTimeUnixNano::NUMBER(38, 0)) / 1e6        AS DURATION_MS,
  DECODE(s.value:status:code::INT, 1, 'OK', 2, 'ERROR', 'UNSET') AS STATUS,
  s.value:status:message::STRING                              AS STATUS_MESSAGE,
  ATTRS(s.value:attributes)                                   AS ATTRIBUTES,
  COALESCE(ATTRIBUTES:"http.response.status_code", ATTRIBUTES:"http.status_code")::INT AS HTTP_STATUS,
  COALESCE(ATTRIBUTES:"http.route", ATTRIBUTES:"http.target")::STRING                 AS ROUTE,
  ATTRIBUTES:"peer.service"::STRING                           AS PEER_SERVICE,
  ATTRIBUTES:"guest.email"::STRING                            AS GUEST_HASH,
  t.LOADED_AT
FROM SKI_OBS.RAW.OTLP_TRACES t,
     LATERAL FLATTEN(t.PAYLOAD:resourceSpans) rs,
     LATERAL FLATTEN(rs.value:scopeSpans)     ss,
     LATERAL FLATTEN(ss.value:spans)          s;

-- -----------------------------------------------------------------------------
-- LOGS: one row per log record, linked to its trace
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW LOGS
  COMMENT = 'One row per log record; BODY is masked for roles below OBS_SRE'
AS
SELECT
  ATTRS(rl.value:resource:attributes)                         AS RESOURCE_ATTRS,
  RESOURCE_ATTRS:"service.name"::STRING                             AS SERVICE_NAME,
  RESOURCE_ATTRS:"k8s.pod.name"::STRING                             AS POD_NAME,
  TO_TIMESTAMP_NTZ(COALESCE(NULLIF(lr.value:timeUnixNano::NUMBER(38, 0), 0),
                            lr.value:observedTimeUnixNano::NUMBER(38, 0)), 9) AS LOG_TIME,
  lr.value:severityText::STRING                               AS SEVERITY,
  lr.value:severityNumber::INT                                AS SEVERITY_NUMBER,
  lr.value:body:stringValue::STRING                           AS BODY,
  NULLIF(lr.value:traceId::STRING, '')                        AS TRACE_ID,
  NULLIF(lr.value:spanId::STRING, '')                         AS SPAN_ID,
  ATTRS(lr.value:attributes)                                  AS ATTRIBUTES,
  t.LOADED_AT
FROM SKI_OBS.RAW.OTLP_LOGS t,
     LATERAL FLATTEN(t.PAYLOAD:resourceLogs) rl,
     LATERAL FLATTEN(rl.value:scopeLogs)     sl,
     LATERAL FLATTEN(sl.value:logRecords)    lr;

-- -----------------------------------------------------------------------------
-- METRIC_POINTS: sums (counters) and gauges, one row per data point
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW METRIC_POINTS
  COMMENT = 'Sum and gauge data points. TEMPORALITY: DELTA = change since last point; CUMULATIVE = running total'
AS
SELECT
  ATTRS(rm.value:resource:attributes)                         AS RESOURCE_ATTRS,
  RESOURCE_ATTRS:"service.name"::STRING                             AS SERVICE_NAME,
  RESOURCE_ATTRS:"k8s.pod.name"::STRING                             AS POD_NAME,
  m.value:name::STRING                                        AS METRIC_NAME,
  m.value:unit::STRING                                        AS UNIT,
  IFF(m.value:sum IS NOT NULL, 'SUM', 'GAUGE')                AS METRIC_TYPE,
  DECODE(m.value:sum:aggregationTemporality::INT, 1, 'DELTA', 2, 'CUMULATIVE', NULL) AS TEMPORALITY,
  m.value:sum:isMonotonic::BOOLEAN                            AS IS_MONOTONIC,
  TO_TIMESTAMP_NTZ(dp.value:timeUnixNano::NUMBER(38, 0), 9)   AS POINT_TIME,
  COALESCE(dp.value:asDouble::FLOAT, dp.value:asInt::FLOAT)   AS METRIC_VALUE,
  ATTRS(dp.value:attributes)                                  AS ATTRIBUTES,
  t.LOADED_AT
FROM SKI_OBS.RAW.OTLP_METRICS t,
     LATERAL FLATTEN(t.PAYLOAD:resourceMetrics) rm,
     LATERAL FLATTEN(rm.value:scopeMetrics)     sm,
     LATERAL FLATTEN(sm.value:metrics)          m,
     LATERAL FLATTEN(COALESCE(m.value:sum:dataPoints, m.value:gauge:dataPoints)) dp;

-- -----------------------------------------------------------------------------
-- HISTOGRAM_POINTS: latency distributions, one row per data point
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW HISTOGRAM_POINTS
  COMMENT = 'Histogram data points with bucket counts and bucket upper bounds'
AS
SELECT
  ATTRS(rm.value:resource:attributes)                         AS RESOURCE_ATTRS,
  RESOURCE_ATTRS:"service.name"::STRING                             AS SERVICE_NAME,
  m.value:name::STRING                                        AS METRIC_NAME,
  m.value:unit::STRING                                        AS UNIT,
  DECODE(m.value:histogram:aggregationTemporality::INT, 1, 'DELTA', 2, 'CUMULATIVE', NULL) AS TEMPORALITY,
  TO_TIMESTAMP_NTZ(dp.value:timeUnixNano::NUMBER(38, 0), 9)   AS POINT_TIME,
  dp.value:count::NUMBER                                      AS POINT_COUNT,
  dp.value:sum::FLOAT                                         AS POINT_SUM,
  dp.value:bucketCounts                                       AS BUCKET_COUNTS,
  dp.value:explicitBounds                                     AS EXPLICIT_BOUNDS,
  ATTRS(dp.value:attributes)                                  AS ATTRIBUTES,
  t.LOADED_AT
FROM SKI_OBS.RAW.OTLP_METRICS t,
     LATERAL FLATTEN(t.PAYLOAD:resourceMetrics) rm,
     LATERAL FLATTEN(rm.value:scopeMetrics)     sm,
     LATERAL FLATTEN(sm.value:metrics)          m,
     LATERAL FLATTEN(m.value:histogram:dataPoints) dp;
