-- =============================================================================
-- 00_setup.sql: roles, warehouses, cost guardrails, database and service user
-- Run as ACCOUNTADMIN. Safe to re-run.
-- =============================================================================
USE ROLE ACCOUNTADMIN;

-- Roles, from least to most privileged. Each inherits the one before it.
--   OBS_ANALYST : reads telemetry and golden signals; log text is masked
--   OBS_SRE     : sees full log text, works incidents
--   OBS_ADMIN   : owns every object in SKI_OBS
--   OBS_INGEST  : only for the loader service: write to RAW, nothing else
CREATE ROLE IF NOT EXISTS OBS_ANALYST COMMENT = 'Read telemetry and golden signals (masked log text)';
CREATE ROLE IF NOT EXISTS OBS_SRE     COMMENT = 'Full telemetry access and incident response';
CREATE ROLE IF NOT EXISTS OBS_ADMIN   COMMENT = 'Owns the SKI_OBS observability database';
CREATE ROLE IF NOT EXISTS OBS_INGEST  COMMENT = 'Loader service: stage files and COPY into RAW only';

GRANT ROLE OBS_ANALYST TO ROLE OBS_SRE;
GRANT ROLE OBS_SRE     TO ROLE OBS_ADMIN;
GRANT ROLE OBS_ADMIN   TO ROLE SYSADMIN;
GRANT ROLE OBS_INGEST  TO ROLE OBS_ADMIN;

-- Separate warehouses so ingest cost and query cost show up separately.
CREATE WAREHOUSE IF NOT EXISTS OBS_INGEST_WH
  WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Telemetry loading (COPY) and the alert';
CREATE WAREHOUSE IF NOT EXISTS OBS_QUERY_WH
  WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Dashboards, investigations and the ops app';

-- Cost guardrail: notify at 75%, suspend both warehouses at 100% of 20 credits a month.
CREATE RESOURCE MONITOR IF NOT EXISTS OBS_MONITOR
  WITH CREDIT_QUOTA = 20 FREQUENCY = MONTHLY START_TIMESTAMP = IMMEDIATELY
  TRIGGERS ON 75 PERCENT DO NOTIFY
           ON 100 PERCENT DO SUSPEND;
ALTER WAREHOUSE OBS_INGEST_WH SET RESOURCE_MONITOR = OBS_MONITOR;
ALTER WAREHOUSE OBS_QUERY_WH  SET RESOURCE_MONITOR = OBS_MONITOR;

GRANT USAGE, OPERATE ON WAREHOUSE OBS_INGEST_WH TO ROLE OBS_INGEST;
GRANT USAGE, OPERATE ON WAREHOUSE OBS_INGEST_WH TO ROLE OBS_ADMIN;
GRANT USAGE ON WAREHOUSE OBS_QUERY_WH TO ROLE OBS_ANALYST;
GRANT OPERATE ON WAREHOUSE OBS_QUERY_WH TO ROLE OBS_ADMIN;

-- OBS_ADMIN builds everything from here on.
GRANT CREATE DATABASE ON ACCOUNT TO ROLE OBS_ADMIN;
GRANT EXECUTE ALERT ON ACCOUNT TO ROLE OBS_ADMIN;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE OBS_ADMIN;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE OBS_ADMIN;   -- for the AI incident summary (day 2)

-- The loader's service user: key-pair only, no password, can't log in to Snowsight.
CREATE USER IF NOT EXISTS OBS_LOADER_SVC
  TYPE = SERVICE
  DEFAULT_ROLE = OBS_INGEST
  DEFAULT_WAREHOUSE = OBS_INGEST_WH
  COMMENT = 'Summit Peak OpenTelemetry loader';
GRANT ROLE OBS_INGEST TO USER OBS_LOADER_SVC;

-- Paste the line that `make keys` prints, for example:
-- ALTER USER OBS_LOADER_SVC SET RSA_PUBLIC_KEY = 'MIIBIjANBgkq...';

-- Let you (the human) use every role while you build and test.
SET me = CURRENT_USER();
GRANT ROLE OBS_ADMIN TO USER IDENTIFIER($me);

USE ROLE OBS_ADMIN;
CREATE DATABASE IF NOT EXISTS SKI_OBS COMMENT = 'Summit Peak Resort observability data';
CREATE SCHEMA IF NOT EXISTS SKI_OBS.RAW  COMMENT = 'OTLP export requests, exactly as received';
CREATE SCHEMA IF NOT EXISTS SKI_OBS.OTEL COMMENT = 'Spans, logs and metric points, one row each';
CREATE SCHEMA IF NOT EXISTS SKI_OBS.OPS  COMMENT = 'Golden signals, SLOs, alerts and incidents';
