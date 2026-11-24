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

CREATE OR REPLACE PROCEDURE SUMMARIZE_INCIDENT(P_INCIDENT_ID NUMBER, P_MODEL STRING DEFAULT 'claude-sonnet-4-5')
  RETURNS STRING
  LANGUAGE SQL
  COMMENT = 'Writes an evidence-based AI summary for one incident and saves it on INCIDENTS'
  EXECUTE AS CALLER
AS
$$
DECLARE
  opened     TIMESTAMP_NTZ;
  w_start    TIMESTAMP_NTZ;
  w_end      TIMESTAMP_NTZ;
  evidence   STRING;
  prompt     STRING;
  answer     STRING;
  used_model STRING;
BEGIN
  -- The window: 15 minutes before the incident opened, to when it resolved (or now).
  opened  := (SELECT OPENED_AT FROM SKI_OBS.OPS.INCIDENTS WHERE INCIDENT_ID = :P_INCIDENT_ID);
  w_start := DATEADD(minute, -15, opened);
  w_end   := (SELECT COALESCE(RESOLVED_AT, SYSDATE()) FROM SKI_OBS.OPS.INCIDENTS WHERE INCIDENT_ID = :P_INCIDENT_ID);

  -- All times handed to the model are Mountain time, so its timeline matches the app.
  evidence := (SELECT TO_JSON(OBJECT_CONSTRUCT(
    'incident',
      (SELECT OBJECT_CONSTRUCT('id', INCIDENT_ID, 'service', SERVICE_NAME, 'status', STATUS,
                               'opened', CONVERT_TIMEZONE('UTC', 'America/Denver', OPENED_AT)::TIMESTAMP_NTZ,
                               'resolved', CONVERT_TIMEZONE('UTC', 'America/Denver', RESOLVED_AT)::TIMESTAMP_NTZ,
                               'trigger_rule', TRIGGER_RULE, 'peak_error_rate', PEAK_ERROR_RATE)
         FROM SKI_OBS.OPS.INCIDENTS WHERE INCIDENT_ID = :P_INCIDENT_ID),
    'other_incidents_open_at_the_same_time',
      (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('id', INCIDENT_ID, 'service', SERVICE_NAME,
                                         'opened', CONVERT_TIMEZONE('UTC', 'America/Denver', OPENED_AT)::TIMESTAMP_NTZ,
                                         'resolved', CONVERT_TIMEZONE('UTC', 'America/Denver', RESOLVED_AT)::TIMESTAMP_NTZ,
                                         'peak_error_rate', PEAK_ERROR_RATE))
         FROM SKI_OBS.OPS.INCIDENTS
        WHERE INCIDENT_ID <> :P_INCIDENT_ID
          AND OPENED_AT <= :w_end AND COALESCE(RESOLVED_AT, SYSDATE()) >= :w_start),
    -- Pre-computed comparisons, so the model reads facts instead of doing arithmetic on long arrays.
    'key_facts_by_service',
      (SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*)) FROM (
         SELECT g.SERVICE_NAME,
                CONVERT_TIMEZONE('UTC', 'America/Denver',
                  MIN(IFF(g.ERROR_RATE > s.MAX_ERROR_RATE AND g.REQUESTS >= 5, g.MINUTE, NULL)))::TIMESTAMP_NTZ
                                                                         AS FIRST_MINUTE_OVER_OBJECTIVE,
                CONVERT_TIMEZONE('UTC', 'America/Denver', MAX(g.MINUTE))::TIMESTAMP_NTZ AS LAST_MINUTE_WITH_ANY_TRAFFIC,
                ROUND(AVG(IFF(g.MINUTE < DATEADD(minute, -3, :opened), g.REQUESTS, NULL)))  AS REQUESTS_PER_MIN_BEFORE,
                MAX(g.REQUESTS)                                                             AS PEAK_REQUESTS_PER_MIN,
                ROUND(100 * AVG(IFF(g.MINUTE < DATEADD(minute, -3, :opened), g.ERROR_RATE, NULL)), 2) AS ERROR_PCT_BEFORE,
                ROUND(100 * MAX(g.ERROR_RATE), 1)                                           AS PEAK_ERROR_PCT,
                SUM(IFF(g.MINUTE >= DATEADD(minute, -3, :opened), g.ERRORS, 0))             AS FAILED_REQUESTS_SINCE_ONSET,
                SUM(IFF(g.MINUTE >= DATEADD(minute, -3, :opened), g.REQUESTS, 0))           AS TOTAL_REQUESTS_SINCE_ONSET,
                ROUND(AVG(IFF(g.MINUTE < DATEADD(minute, -3, :opened), g.P95_MS, NULL)))    AS P95_MS_BEFORE,
                ROUND(MAX(g.P95_MS))                                                        AS PEAK_P95_MS,
                ROUND(AVG(IFF(g.MINUTE < DATEADD(minute, -3, :opened), g.PEAK_PROVIDER_DEMAND, NULL)), 1)
                                                                                            AS PROVIDER_DEMAND_BEFORE,
                MAX(g.PEAK_PROVIDER_DEMAND)                                                 AS PEAK_PROVIDER_DEMAND
           FROM SKI_OBS.OPS.GOLDEN_SIGNALS g
           LEFT JOIN SKI_OBS.OPS.SLOS s ON s.SERVICE_NAME = g.SERVICE_NAME
          WHERE g.MINUTE BETWEEN :w_start AND :w_end
          GROUP BY g.SERVICE_NAME)),
    'golden_signals_by_minute',
      (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('service', SERVICE_NAME,
                                         'minute', CONVERT_TIMEZONE('UTC', 'America/Denver', MINUTE)::TIMESTAMP_NTZ,
                                         'requests', REQUESTS, 'errors', ERRORS, 'error_rate', ERROR_RATE,
                                         'p95_ms', P95_MS, 'peak_provider_demand', PEAK_PROVIDER_DEMAND))
                WITHIN GROUP (ORDER BY MINUTE, SERVICE_NAME)
         FROM SKI_OBS.OPS.GOLDEN_SIGNALS
        WHERE MINUTE BETWEEN :w_start AND :w_end),
    'most_common_error_and_warning_logs',
      (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('service', SERVICE_NAME, 'severity', SEVERITY, 'message', MESSAGE,
                                         'count', N, 'first_seen', FIRST_SEEN, 'last_seen', LAST_SEEN))
                WITHIN GROUP (ORDER BY N DESC)
         FROM (SELECT SERVICE_NAME, SEVERITY,
                      -- group messages that differ only by numbers or amounts
                      REGEXP_REPLACE(BODY, '[0-9]+([.][0-9]+)?', 'N') AS MESSAGE,
                      COUNT(*) AS N,
                      CONVERT_TIMEZONE('UTC', 'America/Denver', MIN(LOG_TIME))::TIMESTAMP_NTZ AS FIRST_SEEN,
                      CONVERT_TIMEZONE('UTC', 'America/Denver', MAX(LOG_TIME))::TIMESTAMP_NTZ AS LAST_SEEN
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
  )));

  prompt := 'You are a senior site reliability engineer writing the first summary of a production incident '
    || 'for the on-call team and their manager. Use ONLY the evidence in the JSON below. '
    || 'Every number you state must appear in the evidence or be simple arithmetic on it; prefer the numbers '
    || 'in key_facts_by_service. If the evidence does not support a conclusion, say what is missing instead of guessing.'
    || '\n\nHow to read the evidence:\n'
    || '- All times are Mountain time. Request, error and latency numbers come from 100% of traffic.\n'
    || '- "slowest_operations_from_sampled_traces" comes from sampled traces, which keep every failed or slow '
    || 'trace, so use it to see where time is spent, not to count errors.\n'
    || '- Compare each service before and during the incident: traffic, error rate, p95 latency and saturation.\n'
    || '- Check saturation against the capacity described in the service catalog.\n'
    || '- A service that is upstream or downstream of a failure can look healthy or go quiet without being broken; '
    || 'check LAST_MINUTE_WITH_ANY_TRAFFIC and the call relationships in the service catalog before blaming it.\n'
    || '- Distinguish the trigger (what changed) from the mechanism (why it failed) when the evidence shows both.\n'
    || '- Log text may be masked.\n'
    || '\nWrite in plain English, in markdown, with exactly these sections:\n'
    || '### What happened\nTwo or three sentences a manager can read.\n'
    || '### Impact\nWho was affected, how many requests failed, and for how long.\n'
    || '### Likely cause\nThe most likely cause, the evidence for it, and your confidence (high, medium or low).\n'
    || '### Timeline (Mountain time)\nThree to six bullet points.\n'
    || '### Next steps\nImmediate actions, then follow-ups that would prevent a repeat. Be specific to this system.\n'
    || '### What the data cannot tell us\nOne to three bullet points.\n'
    || '\nEvidence:\n' || evidence;

  -- Try the requested model, then fall back to models available in more regions.
  BEGIN
    answer := AI_COMPLETE(P_MODEL, prompt);
    used_model := P_MODEL;
  EXCEPTION
    WHEN OTHER THEN
      BEGIN
        answer := AI_COMPLETE('claude-3-7-sonnet', prompt);
        used_model := 'claude-3-7-sonnet';
      EXCEPTION
        WHEN OTHER THEN
          answer := AI_COMPLETE('llama3.3-70b', prompt);
          used_model := 'llama3.3-70b';
      END;
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
