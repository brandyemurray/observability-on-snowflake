-- =============================================================================
-- 03_golden_signals.sql: traffic, errors, latency and saturation per service per minute
--
-- Traffic, errors and latency come from the Collector's spanmetrics connector,
-- which counts 100% of requests BEFORE tail sampling. Computing them from the
-- sampled SPANS view would overstate errors, because sampling keeps every
-- failed trace but only 10% of healthy ones (ADR 0004).
-- =============================================================================
USE ROLE OBS_ADMIN;
USE WAREHOUSE OBS_QUERY_WH;
USE SCHEMA SKI_OBS.OPS;

-- Requests and errors at each service's front door (server spans).
CREATE OR REPLACE VIEW TRAFFIC_ERRORS
  COMMENT = 'Requests and errors per service, endpoint and minute, from unsampled span metrics'
AS
SELECT
  SERVICE_NAME,
  ATTRIBUTES:"span.name"::STRING                          AS ENDPOINT,
  DATE_TRUNC('minute', POINT_TIME)                        AS MINUTE,
  SUM(METRIC_VALUE)                                       AS REQUESTS,
  SUM(IFF(ATTRIBUTES:"status.code"::STRING = 'STATUS_CODE_ERROR', METRIC_VALUE, 0)) AS ERRORS
FROM SKI_OBS.OTEL.METRIC_POINTS
WHERE METRIC_NAME = 'traces.span.metrics.calls'
  AND TEMPORALITY = 'DELTA'
  AND ATTRIBUTES:"span.kind"::STRING = 'SPAN_KIND_SERVER'
GROUP BY 1, 2, 3;

-- p50 / p95 / p99 latency, estimated from histogram buckets with linear interpolation.
CREATE OR REPLACE VIEW LATENCY
  COMMENT = 'Server latency percentiles per service and minute, interpolated from histogram buckets'
AS
WITH buckets AS (
  SELECT
    h.SERVICE_NAME,
    DATE_TRUNC('minute', h.POINT_TIME)                     AS MINUTE,
    b.index                                                AS BUCKET,
    SUM(b.value::NUMBER)                                   AS N,
    MAX(h.EXPLICIT_BOUNDS[b.index]::FLOAT)                 AS UPPER_MS,
    MAX(h.EXPLICIT_BOUNDS[b.index - 1]::FLOAT)             AS LOWER_MS
  FROM SKI_OBS.OTEL.HISTOGRAM_POINTS h,
       LATERAL FLATTEN(h.BUCKET_COUNTS) b
  WHERE h.METRIC_NAME = 'traces.span.metrics.duration'
    AND h.ATTRIBUTES:"span.kind"::STRING = 'SPAN_KIND_SERVER'
  GROUP BY 1, 2, 3
),
running AS (
  SELECT *,
    SUM(N) OVER (PARTITION BY SERVICE_NAME, MINUTE ORDER BY BUCKET) AS CUM_N,
    SUM(N) OVER (PARTITION BY SERVICE_NAME, MINUTE)                 AS TOTAL_N
  FROM buckets
),
pcts AS (
  SELECT r.*, p.PCT
  FROM running r, (SELECT 0.50 AS PCT UNION ALL SELECT 0.95 UNION ALL SELECT 0.99) p
  WHERE r.N > 0
    AND r.CUM_N >= p.PCT * r.TOTAL_N
    AND r.CUM_N - r.N < p.PCT * r.TOTAL_N      -- the bucket where the percentile falls
)
SELECT
  SERVICE_NAME,
  MINUTE,
  MAX(TOTAL_N) AS SAMPLES,
  -- The overflow bucket has no upper bound; report its lower bound instead.
  MAX(IFF(PCT = 0.50, COALESCE(LOWER_MS, 0) + (COALESCE(UPPER_MS, LOWER_MS) - COALESCE(LOWER_MS, 0))
                      * (PCT * TOTAL_N - (CUM_N - N)) / N, NULL)) AS P50_MS,
  MAX(IFF(PCT = 0.95, COALESCE(LOWER_MS, 0) + (COALESCE(UPPER_MS, LOWER_MS) - COALESCE(LOWER_MS, 0))
                      * (PCT * TOTAL_N - (CUM_N - N)) / N, NULL)) AS P95_MS,
  MAX(IFF(PCT = 0.99, COALESCE(LOWER_MS, 0) + (COALESCE(UPPER_MS, LOWER_MS) - COALESCE(LOWER_MS, 0))
                      * (PCT * TOTAL_N - (CUM_N - N)) / N, NULL)) AS P99_MS
FROM pcts
GROUP BY 1, 2;

-- Saturation: the most requests in flight at once during the minute.
CREATE OR REPLACE VIEW SATURATION
  COMMENT = 'Peak in-flight requests per service and minute; for payments, peak provider pool demand'
AS
SELECT
  SERVICE_NAME,
  DATE_TRUNC('minute', POINT_TIME) AS MINUTE,
  MAX(IFF(METRIC_NAME = 'http.server.active_requests', METRIC_VALUE, NULL))  AS PEAK_ACTIVE_REQUESTS,
  MAX(IFF(METRIC_NAME = 'payments.provider.inflight', METRIC_VALUE, NULL))   AS PEAK_PROVIDER_DEMAND
FROM SKI_OBS.OTEL.METRIC_POINTS
WHERE METRIC_NAME IN ('http.server.active_requests', 'payments.provider.inflight')
GROUP BY 1, 2;

-- The four golden signals together, one row per service per minute.
CREATE OR REPLACE VIEW GOLDEN_SIGNALS
  COMMENT = 'Traffic, errors, latency and saturation per service and minute (UTC)'
AS
WITH te AS (
  SELECT SERVICE_NAME, MINUTE, SUM(REQUESTS) AS REQUESTS, SUM(ERRORS) AS ERRORS
  FROM TRAFFIC_ERRORS GROUP BY 1, 2
)
SELECT
  te.SERVICE_NAME,
  te.MINUTE,
  te.REQUESTS,
  te.ERRORS,
  ROUND(te.ERRORS / NULLIF(te.REQUESTS, 0), 4)   AS ERROR_RATE,
  ROUND(l.P50_MS, 1)                             AS P50_MS,
  ROUND(l.P95_MS, 1)                             AS P95_MS,
  ROUND(l.P99_MS, 1)                             AS P99_MS,
  s.PEAK_ACTIVE_REQUESTS,
  s.PEAK_PROVIDER_DEMAND
FROM te
LEFT JOIN LATENCY    l ON l.SERVICE_NAME = te.SERVICE_NAME AND l.MINUTE = te.MINUTE
LEFT JOIN SATURATION s ON s.SERVICE_NAME = te.SERVICE_NAME AND s.MINUTE = te.MINUTE;

-- Service-level objectives, kept as data so they can change without code.
CREATE TABLE IF NOT EXISTS SLOS (
  SERVICE_NAME       STRING,
  MAX_ERROR_RATE     FLOAT   COMMENT 'Open an incident above this rate over the window',
  RECOVERY_RATE      FLOAT   COMMENT 'Resolve the incident once the rate is back below this',
  MAX_P95_MS         FLOAT   COMMENT 'Latency objective, shown on the dashboard',
  WINDOW_MINUTES     INT,
  MIN_REQUESTS       INT     COMMENT 'Ignore windows with too little traffic to judge'
);
MERGE INTO SLOS t USING (
  SELECT * FROM VALUES
    ('lift-tickets',  0.02, 0.005, 800, 5, 30),
    ('rentals',       0.02, 0.005, 800, 5, 15),
    ('payments',      0.02, 0.005, 500, 5, 30),
    ('notifications', 0.05, 0.010, 200, 5, 30)
  AS v(SERVICE_NAME, MAX_ERROR_RATE, RECOVERY_RATE, MAX_P95_MS, WINDOW_MINUTES, MIN_REQUESTS)
) s ON t.SERVICE_NAME = s.SERVICE_NAME
WHEN NOT MATCHED THEN INSERT VALUES (s.SERVICE_NAME, s.MAX_ERROR_RATE, s.RECOVERY_RATE, s.MAX_P95_MS, s.WINDOW_MINUTES, s.MIN_REQUESTS);

-- Each service's error rate over its SLO window, and whether it is breaching.
CREATE OR REPLACE VIEW SLO_STATUS
  COMMENT = 'Current SLO window per service: BREACHING, HEALTHY or LOW_TRAFFIC'
AS
SELECT
  o.SERVICE_NAME,
  o.WINDOW_MINUTES,
  COALESCE(SUM(g.REQUESTS), 0)                          AS REQUESTS,
  COALESCE(SUM(g.ERRORS), 0)                            AS ERRORS,
  SUM(g.ERRORS) / NULLIF(SUM(g.REQUESTS), 0)            AS ERROR_RATE,
  MAX(g.P95_MS)                                         AS WORST_P95_MS,
  o.MAX_ERROR_RATE,
  o.RECOVERY_RATE,
  CASE
    WHEN COALESCE(SUM(g.REQUESTS), 0) < o.MIN_REQUESTS                   THEN 'LOW_TRAFFIC'
    WHEN SUM(g.ERRORS) / NULLIF(SUM(g.REQUESTS), 0) > o.MAX_ERROR_RATE   THEN 'BREACHING'
    WHEN SUM(g.ERRORS) / NULLIF(SUM(g.REQUESTS), 0) < o.RECOVERY_RATE    THEN 'HEALTHY'
    ELSE 'DEGRADED'
  END                                                   AS STATE
FROM SLOS o
LEFT JOIN GOLDEN_SIGNALS g
  ON g.SERVICE_NAME = o.SERVICE_NAME
 AND g.MINUTE >= DATEADD(minute, -o.WINDOW_MINUTES, SYSDATE())
GROUP BY o.SERVICE_NAME, o.WINDOW_MINUTES, o.MAX_ERROR_RATE, o.RECOVERY_RATE, o.MIN_REQUESTS;
