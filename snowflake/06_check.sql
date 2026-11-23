-- =============================================================================
-- 06_check.sql: is telemetry arriving? Run after the lab has been up a few minutes.
-- =============================================================================
USE ROLE OBS_ADMIN;
USE WAREHOUSE OBS_QUERY_WH;
USE SCHEMA SKI_OBS.OTEL;

-- 1. Rows landing in RAW, and how fresh they are.
SELECT 'traces' AS SIGNAL, COUNT(*) AS EXPORT_REQUESTS, MAX(LOADED_AT) AS LAST_LOADED FROM SKI_OBS.RAW.OTLP_TRACES
UNION ALL SELECT 'metrics', COUNT(*), MAX(LOADED_AT) FROM SKI_OBS.RAW.OTLP_METRICS
UNION ALL SELECT 'logs',    COUNT(*), MAX(LOADED_AT) FROM SKI_OBS.RAW.OTLP_LOGS;

-- 2. Spans per service, with Kubernetes context attached by the Collector.
SELECT SERVICE_NAME, DEPLOYMENT, COUNT(*) AS SPANS, COUNT(DISTINCT TRACE_ID) AS TRACES,
       COUNT_IF(STATUS = 'ERROR') AS ERROR_SPANS
FROM SPANS GROUP BY 1, 2 ORDER BY 1;

-- 3. Redaction check: no raw emails or card numbers should appear anywhere.
SELECT COUNT_IF(REGEXP_LIKE(BODY, '.*[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+[.][A-Za-z]{2,}.*')) AS EMAILS_IN_LOGS,
       COUNT_IF(REGEXP_LIKE(BODY, '.*([0-9][ -]?){12,18}[0-9].*'))                     AS CARD_NUMBERS_IN_LOGS,
       COUNT(*)                                                                         AS LOG_RECORDS
FROM LOGS;
SELECT BODY FROM LOGS WHERE BODY ILIKE 'Charging card%' LIMIT 5;
SELECT GUEST_HASH, ATTRIBUTES:"payment.card_number"::STRING AS CARD FROM SPANS
WHERE ATTRIBUTES:"payment.card_number" IS NOT NULL LIMIT 5;

-- 4. Golden signals for the last 15 minutes.
SELECT * FROM SKI_OBS.OPS.GOLDEN_SIGNALS
WHERE MINUTE >= DATEADD(minute, -15, SYSDATE())
ORDER BY SERVICE_NAME, MINUTE DESC;

-- 5. SLO state and incidents.
SELECT * FROM SKI_OBS.OPS.SLO_STATUS ORDER BY SERVICE_NAME;
SELECT * FROM SKI_OBS.OPS.INCIDENTS ORDER BY OPENED_AT DESC;
SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME, SQL_ERROR_MESSAGE
FROM TABLE(SKI_OBS.INFORMATION_SCHEMA.ALERT_HISTORY(SCHEDULED_TIME_RANGE_START => DATEADD(hour, -1, CURRENT_TIMESTAMP())))
ORDER BY SCHEDULED_TIME DESC LIMIT 10;

-- 6. Masking: the same query as an analyst (masked) and as an SRE (full text).
USE ROLE OBS_ANALYST;
USE SECONDARY ROLES NONE;
SELECT SERVICE_NAME, SEVERITY, BODY FROM SKI_OBS.OTEL.LOGS WHERE SEVERITY = 'ERROR' LIMIT 5;
USE ROLE OBS_SRE;
SELECT SERVICE_NAME, SEVERITY, BODY FROM SKI_OBS.OTEL.LOGS WHERE SEVERITY = 'ERROR' LIMIT 5;
USE ROLE OBS_ADMIN;
USE SECONDARY ROLES ALL;
