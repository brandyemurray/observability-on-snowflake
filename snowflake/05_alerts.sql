-- =============================================================================
-- 05_alerts.sql: open and resolve incidents automatically from the SLOs
--
-- A Snowflake alert checks SLO_STATUS every minute. When a service breaches its
-- error-rate objective it opens an incident; when the service is healthy again
-- it resolves it. The alert only runs its action when something changes.
--
-- Cost: an alert that runs every minute keeps its warehouse awake. It shares
-- OBS_INGEST_WH, which is already running while the lab sends data. Suspend it
-- when the lab is off:  ALTER ALERT SKI_OBS.OPS.SLO_WATCH SUSPEND;
-- =============================================================================
USE ROLE OBS_ADMIN;
USE WAREHOUSE OBS_QUERY_WH;
USE SCHEMA SKI_OBS.OPS;

CREATE TABLE IF NOT EXISTS INCIDENTS (
  INCIDENT_ID         NUMBER AUTOINCREMENT START 1001 INCREMENT 1,
  SERVICE_NAME        STRING,
  STATUS              STRING        COMMENT 'OPEN or RESOLVED',
  OPENED_AT           TIMESTAMP_NTZ COMMENT 'UTC',
  RESOLVED_AT         TIMESTAMP_NTZ COMMENT 'UTC',
  TRIGGER_RULE        STRING,
  ERROR_RATE_AT_OPEN  FLOAT,
  REQUESTS_AT_OPEN    NUMBER,
  PEAK_ERROR_RATE     FLOAT,
  AI_SUMMARY          STRING        COMMENT 'Filled in by the AI SRE summary (day 2)',
  AI_SUMMARY_MODEL    STRING,
  AI_SUMMARY_AT       TIMESTAMP_NTZ
);

CREATE OR REPLACE PROCEDURE EVALUATE_SLOS()
  RETURNS STRING
  LANGUAGE SQL
  COMMENT = 'Open incidents for breaching services, track their peak, resolve healthy ones'
AS
$$
DECLARE
  opened INT DEFAULT 0;
  resolved INT DEFAULT 0;
BEGIN
  INSERT INTO INCIDENTS (SERVICE_NAME, STATUS, OPENED_AT, TRIGGER_RULE,
                         ERROR_RATE_AT_OPEN, REQUESTS_AT_OPEN, PEAK_ERROR_RATE)
  SELECT s.SERVICE_NAME, 'OPEN', SYSDATE(),
         'Error rate ' || TO_VARCHAR(ROUND(s.ERROR_RATE * 100, 1)) || '% over '
           || s.WINDOW_MINUTES || ' min (objective ' || TO_VARCHAR(s.MAX_ERROR_RATE * 100) || '%)',
         s.ERROR_RATE, s.REQUESTS, s.ERROR_RATE
  FROM SLO_STATUS s
  WHERE s.STATE = 'BREACHING'
    AND NOT EXISTS (SELECT 1 FROM INCIDENTS i
                    WHERE i.SERVICE_NAME = s.SERVICE_NAME AND i.STATUS = 'OPEN');
  opened := SQLROWCOUNT;

  UPDATE INCIDENTS i
     SET PEAK_ERROR_RATE = GREATEST(COALESCE(i.PEAK_ERROR_RATE, 0), s.ERROR_RATE)
    FROM SLO_STATUS s
   WHERE i.SERVICE_NAME = s.SERVICE_NAME AND i.STATUS = 'OPEN' AND s.ERROR_RATE IS NOT NULL;

  UPDATE INCIDENTS i
     SET STATUS = 'RESOLVED', RESOLVED_AT = SYSDATE()
    FROM SLO_STATUS s
   WHERE i.SERVICE_NAME = s.SERVICE_NAME
     AND i.STATUS = 'OPEN'
     AND s.STATE = 'HEALTHY'
     AND i.OPENED_AT < DATEADD(minute, -s.WINDOW_MINUTES, SYSDATE());
  resolved := SQLROWCOUNT;

  RETURN 'opened ' || opened || ', resolved ' || resolved;
END;
$$;

-- Something needs doing when a service is breaching with no open incident,
-- or an open incident's service has been healthy for a full window.
CREATE OR REPLACE VIEW SLO_ACTIONS_NEEDED AS
SELECT s.SERVICE_NAME, s.STATE
FROM SLO_STATUS s
LEFT JOIN INCIDENTS i ON i.SERVICE_NAME = s.SERVICE_NAME AND i.STATUS = 'OPEN'
WHERE (s.STATE = 'BREACHING' AND i.INCIDENT_ID IS NULL)
   OR (s.STATE = 'HEALTHY' AND i.INCIDENT_ID IS NOT NULL
       AND i.OPENED_AT < DATEADD(minute, -s.WINDOW_MINUTES, SYSDATE()))
   OR (s.STATE = 'BREACHING' AND s.ERROR_RATE > i.PEAK_ERROR_RATE);

CREATE OR REPLACE ALERT SLO_WATCH
  WAREHOUSE = OBS_INGEST_WH
  SCHEDULE = '1 MINUTE'
  COMMENT = 'Opens and resolves incidents from SLO_STATUS'
  IF (EXISTS (SELECT 1 FROM SKI_OBS.OPS.SLO_ACTIONS_NEEDED))
  THEN CALL SKI_OBS.OPS.EVALUATE_SLOS();

ALTER ALERT SLO_WATCH RESUME;

GRANT SELECT ON TABLE INCIDENTS TO ROLE OBS_ANALYST;
GRANT UPDATE ON TABLE INCIDENTS TO ROLE OBS_SRE;
GRANT SELECT ON VIEW SLO_ACTIONS_NEEDED TO ROLE OBS_ANALYST;
