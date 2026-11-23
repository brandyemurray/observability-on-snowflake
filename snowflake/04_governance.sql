-- =============================================================================
-- 04_governance.sql: a second layer of PII protection, and read access by role
--
-- The Collector already redacts emails and card numbers (layer 1). This masking
-- policy is layer 2: if a new service starts logging something the Collector
-- rules don't cover yet (a phone number, say), analysts still don't see it.
-- SREs see the full text because they need it during an incident.
--
-- Masking is evaluated for the role running the query, even through a view.
-- Test every dashboard as the least-privileged role that will use it.
-- =============================================================================
USE ROLE OBS_ADMIN;
USE WAREHOUSE OBS_QUERY_WH;
USE SCHEMA SKI_OBS.OTEL;

CREATE MASKING POLICY IF NOT EXISTS MASK_LOG_BODY AS (BODY STRING) RETURNS STRING ->
  CASE
    WHEN IS_ROLE_IN_SESSION('OBS_SRE') THEN BODY
    ELSE REGEXP_REPLACE(
           REGEXP_REPLACE(
             REGEXP_REPLACE(BODY,
               '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+([.][A-Za-z0-9-]+)+', '<email masked>'),
             '[0-9]{3}[-. ][0-9]{3}[-. ][0-9]{4}', '<phone masked>'),
           '([0-9][ -]?){12,18}[0-9]', '<number masked>')
  END
  COMMENT = 'Full log text for OBS_SRE and above; PII patterns masked for everyone else';

-- FORCE swaps in the policy even if the column already has one (safe to re-run).
ALTER VIEW LOGS MODIFY COLUMN BODY SET MASKING POLICY MASK_LOG_BODY FORCE;

-- Read access. Analysts get the modeled views and ops views, never RAW.
GRANT USAGE ON DATABASE SKI_OBS TO ROLE OBS_ANALYST;
GRANT USAGE ON SCHEMA SKI_OBS.OTEL TO ROLE OBS_ANALYST;
GRANT USAGE ON SCHEMA SKI_OBS.OPS  TO ROLE OBS_ANALYST;
GRANT SELECT ON ALL VIEWS IN SCHEMA SKI_OBS.OTEL TO ROLE OBS_ANALYST;
GRANT SELECT ON ALL VIEWS IN SCHEMA SKI_OBS.OPS  TO ROLE OBS_ANALYST;
GRANT SELECT ON ALL TABLES IN SCHEMA SKI_OBS.OPS TO ROLE OBS_ANALYST;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA SKI_OBS.OPS  TO ROLE OBS_ANALYST;
GRANT SELECT ON FUTURE TABLES IN SCHEMA SKI_OBS.OPS TO ROLE OBS_ANALYST;

-- SREs can also read RAW (for deep dives) and update incidents.
GRANT USAGE ON SCHEMA SKI_OBS.RAW TO ROLE OBS_SRE;
GRANT SELECT ON ALL TABLES IN SCHEMA SKI_OBS.RAW TO ROLE OBS_SRE;
