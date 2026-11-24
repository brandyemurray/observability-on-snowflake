-- =============================================================================
-- 07_ai_sre.sql: service catalog and the AI SRE incident summary
--
-- SUMMARIZE_INCIDENT gathers the evidence for one incident (golden signals
-- minute by minute, the most common error logs, the slowest operations, the
-- SLO and the service catalog), hands it to a Cortex model with strict
-- instructions to use only that evidence, and saves the answer on the incident.
--
-- It runs with the CALLER's rights, so the model sees exactly what the caller
-- may see. Called from the ops app, that's masked log text: the AI never
-- receives guest PII, even by accident.
-- =============================================================================
USE ROLE OBS_ADMIN;
USE WAREHOUSE OBS_QUERY_WH;
USE SCHEMA SKI_OBS.OPS;

-- What each service does and depends on. In a real company this comes from the
-- service catalog or CMDB; the AI needs it to reason about cause, not just symptoms.
CREATE OR REPLACE TABLE SERVICE_CATALOG (
  SERVICE_NAME  STRING,
  OWNER_TEAM    STRING,
  PURPOSE       STRING,
  CALLS         STRING,
  NOTES         STRING
);
INSERT INTO SERVICE_CATALOG VALUES
  ('lift-tickets',  'Guest Commerce', 'Sells lift tickets to guests (2 replicas)',
   'payments (2.0 s timeout), notifications (1.0 s timeout, failure is non-fatal)', 'Guest-facing'),
  ('rentals',       'Guest Commerce', 'Reserves skis, snowboards, boots and helmets',
   'payments (2.0 s timeout), notifications (1.0 s timeout, failure is non-fatal)',
   'Guest-facing. HTTP 409 means sold out and is not an error'),
  ('payments',      'Payments',       'Charges guest cards through the external provider alpine-pay (1 replica)',
   'alpine-pay through a pool of 8 connections; waits up to 2.5 s for a free connection',
   'Normal provider latency is about 120 ms'),
  ('notifications', 'Guest Commerce', 'Sends confirmation emails through snowmail',
   'snowmail', 'Not on the checkout critical path');

-- Pipeline health for people who may not read RAW: the view runs with its
-- owner's rights, so analysts see counts and freshness, never raw payloads.
CREATE OR REPLACE VIEW PIPELINE_FRESHNESS
  COMMENT = 'Seconds since each signal last landed, and batches loaded in the last hour'
AS
SELECT 'Traces' AS SIGNAL, DATEDIFF(second, MAX(LOADED_AT), CURRENT_TIMESTAMP()) AS AGE_SECONDS,
       COUNT_IF(LOADED_AT >= DATEADD(hour, -1, CURRENT_TIMESTAMP())) AS BATCHES_LAST_HOUR
  FROM SKI_OBS.RAW.OTLP_TRACES
UNION ALL
SELECT 'Metrics', DATEDIFF(second, MAX(LOADED_AT), CURRENT_TIMESTAMP()),
       COUNT_IF(LOADED_AT >= DATEADD(hour, -1, CURRENT_TIMESTAMP()))
  FROM SKI_OBS.RAW.OTLP_METRICS
UNION ALL
SELECT 'Logs', DATEDIFF(second, MAX(LOADED_AT), CURRENT_TIMESTAMP()),
       COUNT_IF(LOADED_AT >= DATEADD(hour, -1, CURRENT_TIMESTAMP()))
  FROM SKI_OBS.RAW.OTLP_LOGS;

CREATE OR REPLACE PROCEDURE SUMMARIZE_INCIDENT(P_INCIDENT_ID NUMBER, P_MODEL STRING DEFAULT 'claude-3-5-sonnet')
  RETURNS STRING
  LANGUAGE SQL
  COMMENT = 'Writes an evidence-based AI summary for one incident and saves it on INCIDENTS'
  EXECUTE AS CALLER
AS
$$
DECLARE
  w_start    TIMESTAMP_NTZ;
  w_end      TIMESTAMP_NTZ;
  evidence   STRING;
  prompt     STRING;
  answer     STRING;
  used_model STRING;
BEGIN
  -- The window: 15 minutes before the incident opened, to when it resolved (or now).
  SELECT DATEADD(minute, -15, OPENED_AT), COALESCE(RESOLVED_AT, SYSDATE())
    INTO :w_start, :w_end
    FROM SKI_OBS.OPS.INCIDENTS WHERE INCIDENT_ID = :P_INCIDENT_ID;

  SELECT TO_JSON(OBJECT_CONSTRUCT(
    'incident',
      (SELECT OBJECT_DELETE(OBJECT_CONSTRUCT(*), 'AI_SUMMARY', 'AI_SUMMARY_MODEL', 'AI_SUMMARY_AT')
         FROM SKI_OBS.OPS.INCIDENTS WHERE INCIDENT_ID = :P_INCIDENT_ID),
    'open_incidents_at_the_same_time',
      (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('id', INCIDENT_ID, 'service', SERVICE_NAME, 'opened_utc', OPENED_AT,
                                         'resolved_utc', RESOLVED_AT, 'peak_error_rate', PEAK_ERROR_RATE))
         FROM SKI_OBS.OPS.INCIDENTS
        WHERE INCIDENT_ID <> :P_INCIDENT_ID
          AND OPENED_AT <= :w_end AND COALESCE(RESOLVED_AT, SYSDATE()) >= :w_start),
    'golden_signals_by_minute_utc',
      (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('service', SERVICE_NAME, 'minute', MINUTE, 'requests', REQUESTS,
                                         'errors', ERRORS, 'error_rate', ERROR_RATE, 'p95_ms', P95_MS,
                                         'peak_active_requests', PEAK_ACTIVE_REQUESTS,
                                         'peak_provider_demand', PEAK_PROVIDER_DEMAND))
                WITHIN GROUP (ORDER BY MINUTE, SERVICE_NAME)
         FROM SKI_OBS.OPS.GOLDEN_SIGNALS
        WHERE MINUTE BETWEEN :w_start AND :w_end),
    'most_common_error_and_warning_logs',
      (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('service', SERVICE_NAME, 'severity', SEVERITY, 'message', MESSAGE,
                                         'count', N, 'first_utc', FIRST_SEEN, 'last_utc', LAST_SEEN))
                WITHIN GROUP (ORDER BY N DESC)
         FROM (SELECT SERVICE_NAME, SEVERITY,
                      -- group messages that differ only by numbers or amounts
                      REGEXP_REPLACE(BODY, '[0-9]+([.][0-9]+)?', 'N') AS MESSAGE,
                      COUNT(*) AS N, MIN(LOG_TIME) AS FIRST_SEEN, MAX(LOG_TIME) AS LAST_SEEN
                 FROM SKI_OBS.OTEL.LOGS
                WHERE LOG_TIME BETWEEN :w_start AND :w_end AND SEVERITY_NUMBER >= 13
                GROUP BY 1, 2, 3
                ORDER BY N DESC
                LIMIT 15)),
    'slowest_operations_from_sampled_traces',
      (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('service', SERVICE_NAME, 'operation', SPAN_NAME, 'spans', N,
                                         'error_spans', ERRS, 'p95_ms', P95, 'max_ms', MX))
                WITHIN GROUP (ORDER BY P95 DESC)
         FROM (SELECT SERVICE_NAME, SPAN_NAME, COUNT(*) AS N, COUNT_IF(STATUS = 'ERROR') AS ERRS,
                      ROUND(APPROX_PERCENTILE(DURATION_MS, 0.95), 1) AS P95, ROUND(MAX(DURATION_MS), 1) AS MX
                 FROM SKI_OBS.OTEL.SPANS
                WHERE START_TIME BETWEEN :w_start AND :w_end
                GROUP BY 1, 2
                ORDER BY P95 DESC
                LIMIT 12)),
    'slos', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*)) FROM SKI_OBS.OPS.SLOS),
    'service_catalog', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*)) FROM SKI_OBS.OPS.SERVICE_CATALOG)
  )) INTO :evidence;

  prompt := 'You are a senior site reliability engineer writing the first summary of a production incident '
    || 'for the on-call team and their manager. Use ONLY the evidence in the JSON below. '
    || 'Every number you state must appear in the evidence or be simple arithmetic on it. '
    || 'If the evidence does not support a conclusion, say what is missing instead of guessing. '
    || 'Notes on the evidence: times are UTC; request, error and latency numbers come from 100% of traffic; '
    || 'the "slowest operations" come from sampled traces, which keep every failed or slow trace, so use them '
    || 'to find where time is spent, not to count errors. Log text may be masked.'
    || '\n\nWrite in plain English, in markdown, with exactly these sections:\n'
    || '### What happened\nTwo or three sentences a manager can read.\n'
    || '### Impact\nWho was affected, how many requests failed, and for how long.\n'
    || '### Likely cause\nThe most likely cause, the evidence for it, and your confidence (high, medium or low).\n'
    || '### Timeline (UTC)\nThree to six bullet points.\n'
    || '### Next steps\nImmediate actions, then follow-ups that would prevent a repeat.\n'
    || '### What the data cannot tell us\nOne to three bullet points.\n'
    || '\nEvidence:\n' || evidence;

  BEGIN
    SELECT SNOWFLAKE.CORTEX.COMPLETE(:P_MODEL, :prompt) INTO :answer;
    used_model := P_MODEL;
  EXCEPTION
    WHEN OTHER THEN
      -- The preferred model isn't available in every region; fall back to one that is.
      SELECT SNOWFLAKE.CORTEX.COMPLETE('llama3.1-70b', :prompt) INTO :answer;
      used_model := 'llama3.1-70b';
  END;

  UPDATE SKI_OBS.OPS.INCIDENTS
     SET AI_SUMMARY = :answer, AI_SUMMARY_MODEL = :used_model, AI_SUMMARY_AT = SYSDATE()
   WHERE INCIDENT_ID = :P_INCIDENT_ID;

  RETURN answer;
END;
$$;

-- -----------------------------------------------------------------------------
-- The Streamlit ops app's role: analyst-level reads (masked log text), plus
-- Cortex and permission to save AI summaries on incidents.
-- -----------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;
CREATE ROLE IF NOT EXISTS OBS_APP_OWNER COMMENT = 'Owns the Summit Peak ops app; masked log text';
GRANT ROLE OBS_ANALYST TO ROLE OBS_APP_OWNER;
GRANT ROLE OBS_APP_OWNER TO ROLE OBS_ADMIN;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE OBS_APP_OWNER;
SET me = '"' || CURRENT_USER() || '"';   -- quoted, so mixed-case user names work too
GRANT ROLE OBS_APP_OWNER TO USER IDENTIFIER($me);

USE ROLE OBS_ADMIN;
GRANT SELECT ON TABLE SKI_OBS.OPS.SERVICE_CATALOG TO ROLE OBS_ANALYST;
GRANT SELECT ON VIEW SKI_OBS.OPS.PIPELINE_FRESHNESS TO ROLE OBS_ANALYST;
GRANT UPDATE ON TABLE SKI_OBS.OPS.INCIDENTS TO ROLE OBS_APP_OWNER;
GRANT USAGE ON PROCEDURE SKI_OBS.OPS.SUMMARIZE_INCIDENT(NUMBER, STRING) TO ROLE OBS_APP_OWNER;
GRANT USAGE ON PROCEDURE SKI_OBS.OPS.SUMMARIZE_INCIDENT(NUMBER, STRING) TO ROLE OBS_SRE;

CREATE SCHEMA IF NOT EXISTS SKI_OBS.APP COMMENT = 'Streamlit apps';
GRANT USAGE ON SCHEMA SKI_OBS.APP TO ROLE OBS_APP_OWNER;
GRANT CREATE STREAMLIT, CREATE STAGE ON SCHEMA SKI_OBS.APP TO ROLE OBS_APP_OWNER;

-- Try it once an incident exists: find the newest ID, then summarize it.
-- SELECT INCIDENT_ID, SERVICE_NAME, STATUS, OPENED_AT FROM SKI_OBS.OPS.INCIDENTS ORDER BY OPENED_AT DESC;
-- CALL SKI_OBS.OPS.SUMMARIZE_INCIDENT(1001);
