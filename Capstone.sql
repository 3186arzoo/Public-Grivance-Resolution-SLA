USE ROLE ACCOUNTADMIN;
CREATE WAREHOUSE IF NOT EXISTS CAPSTONE_WH WAREHOUSE_SIZE='XSMALL' AUTO_SUSPEND=60 AUTO_RESUME=TRUE;
USE WAREHOUSE CAPSTONE_WH;
CREATE DATABASE IF NOT EXISTS CAPSTONE;
CREATE SCHEMA IF NOT EXISTS CAPSTONE.GRIEVANCE;
USE SCHEMA CAPSTONE.GRIEVANCE;
CREATE OR REPLACE FILE FORMAT CSV_FF
  TYPE = CSV
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  EMPTY_FIELD_AS_NULL = TRUE
  NULL_IF = ('', 'NULL')
  TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS';
  CREATE OR REPLACE STAGE GRIEVANCE_STAGE FILE_FORMAT = CSV_FF;
  LIST @GRIEVANCE_STAGE;
  CREATE OR REPLACE TABLE SILVER_COMPLAINT (
  complaint_id      STRING,
  ward_id           STRING,
  category          STRING,
  status            STRING,
  raised_ts         TIMESTAMP_NTZ,
  closed_ts         TIMESTAMP_NTZ,
  closure_known     BOOLEAN,
  resolution_hours  FLOAT,
  sla_breach        BOOLEAN
);
CREATE OR REPLACE TABLE GOLD_COMPLAINT_WEEK (
  week_start               DATE,
  ward_id                  STRING,
  zone                     STRING,
  category                 STRING,
  raised                   NUMBER,
  closed                   NUMBER,
  open_at_week_end         NUMBER,
  median_resolution_hours  FLOAT,
  p90_resolution_hours     FLOAT,
  breached                 NUMBER,
  breach_rate              FLOAT
);
COPY INTO SILVER_COMPLAINT FROM @GRIEVANCE_STAGE/silver_complaint.csv
  VALIDATION_MODE = RETURN_ERRORS;
  COPY INTO GOLD_COMPLAINT_WEEK FROM @GRIEVANCE_STAGE/gold_grievance_weekly.csv
  VALIDATION_MODE = RETURN_ERRORS;
  COPY INTO SILVER_COMPLAINT FROM @GRIEVANCE_STAGE/silver_complaint.csv
  ON_ERROR = ABORT_STATEMENT;
  CREATE OR REPLACE FILE FORMAT CSV_HDR
  TYPE = CSV SKIP_HEADER = 0
  FIELD_OPTIONALLY_ENCLOSED_BY = '"';
  SELECT $1,$2,$3,$4,$5,$6,$7,$8,$9,$10
FROM @GRIEVANCE_STAGE/silver_complaint.csv (FILE_FORMAT => 'CSV_HDR')
LIMIT 5;
CREATE OR REPLACE TABLE SILVER_COMPLAINT (
  complaint_id      STRING,
  ward_id           STRING,
  zone              STRING,
  category          STRING,
  status            STRING,
  raised_ts         TIMESTAMP_NTZ,
  closed_ts         TIMESTAMP_NTZ,
  closure_known     BOOLEAN,
  resolution_hours  FLOAT,
  sla_breach        BOOLEAN
);
COPY INTO SILVER_COMPLAINT FROM @GRIEVANCE_STAGE/silver_complaint.csv
  ON_ERROR = ABORT_STATEMENT;
  ALTER FILE FORMAT CSV_FF SET TIMESTAMP_FORMAT = 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"';
  COPY INTO SILVER_COMPLAINT FROM @GRIEVANCE_STAGE/silver_complaint.csv
  ON_ERROR = ABORT_STATEMENT;
  COPY INTO GOLD_COMPLAINT_WEEK FROM @GRIEVANCE_STAGE/gold_grievance_weekly.csv
  ON_ERROR = ABORT_STATEMENT;
  COPY INTO SILVER_COMPLAINT FROM @GRIEVANCE_STAGE/silver_complaint.csv
  ON_ERROR = ABORT_STATEMENT;
  COPY INTO GOLD_COMPLAINT_WEEK FROM @GRIEVANCE_STAGE/gold_grievance_weekly.csv
  ON_ERROR = ABORT_STATEMENT;
  SELECT 'silver' t, COUNT(*) n FROM SILVER_COMPLAINT      -- expect 58,400
UNION ALL SELECT 'gold', COUNT(*) FROM GOLD_COMPLAINT_WEEK;  -- expect 8,320
SELECT COUNT(*) FROM SILVER_COMPLAINT
WHERE status='CLOSED' AND closure_known = FALSE;         -- expect 1,200
SELECT COUNT(*) FROM SILVER_COMPLAINT
WHERE status='OPEN' AND closure_known = FALSE;           -- expect 0
SELECT COUNT(*) FROM SILVER_COMPLAINT WHERE resolution_hours < 0;  -- expect 0
ALTER SESSION SET WEEK_START = 1;
CREATE OR REPLACE TABLE BACKLOG_CHECK AS
WITH sp AS (SELECT DATEADD(week, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1,
    DATE '2024-12-30') AS w FROM TABLE(GENERATOR(ROWCOUNT => 26))),
k AS (SELECT DISTINCT ward_id, category FROM SILVER_COMPLAINT),
ev AS (
  SELECT DATE_TRUNC('week', raised_ts)::DATE w, ward_id, category, COUNT(*) r, 0 c
    FROM SILVER_COMPLAINT GROUP BY 1, 2, 3
  UNION ALL
  SELECT DATE_TRUNC('week', closed_ts)::DATE, ward_id, category, 0, COUNT(*)
    FROM SILVER_COMPLAINT WHERE closure_known GROUP BY 1, 2, 3)
SELECT sp.w, k.ward_id, k.category,
  COALESCE(SUM(ev.r), 0) AS raised, COALESCE(SUM(ev.c), 0) AS closed,
  SUM(COALESCE(SUM(ev.r), 0) - COALESCE(SUM(ev.c), 0))
    OVER (PARTITION BY k.ward_id, k.category ORDER BY sp.w
          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS open_at_week_end
FROM sp CROSS JOIN k
LEFT JOIN ev ON ev.w = sp.w AND ev.ward_id = k.ward_id AND ev.category = k.category
GROUP BY sp.w, k.ward_id, k.category;
SELECT COUNT(*) FROM BACKLOG_CHECK;   -- expect 8,320
SELECT (SELECT SUM(open_at_week_end) FROM BACKLOG_CHECK WHERE w = '2025-06-23') AS backlog_last_week,
       (SELECT COUNT(*) - COUNT_IF(closure_known) FROM SILVER_COMPLAINT) AS silver_expected;
-- the two numbers must be identical
SELECT week_start, ward_id, category, raised, closed, open_at_week_end FROM GOLD_COMPLAINT_WEEK
MINUS
SELECT w, ward_id, category, raised, closed, open_at_week_end FROM BACKLOG_CHECK;
-- expect 0 rows
SELECT category, MEDIAN(resolution_hours) AS median_hours
FROM SILVER_COMPLAINT
WHERE status='CLOSED' AND closure_known
GROUP BY category ORDER BY median_hours;
SELECT category, ward_id, MEDIAN(resolution_hours) AS median_hours
FROM SILVER_COMPLAINT
WHERE status='CLOSED' AND closure_known
GROUP BY category, ward_id ORDER BY category, median_hours DESC;
SELECT ward_id, MEDIAN(resolution_hours) AS median_hours
FROM SILVER_COMPLAINT
WHERE status='CLOSED' AND closure_known
GROUP BY ward_id ORDER BY median_hours DESC LIMIT 10;
SELECT ward_id, category, COUNT(*) AS complaints,
       COUNT_IF(sla_breach) AS breached,
       ROUND(COUNT_IF(sla_breach) / COUNT(*), 4) AS breach_rate
FROM SILVER_COMPLAINT
WHERE sla_breach IS NOT NULL
GROUP BY ward_id, category ORDER BY breach_rate DESC;
SELECT week_start, SUM(open_at_week_end) AS open_complaints
FROM GOLD_COMPLAINT_WEEK
GROUP BY week_start ORDER BY week_start;
-- last week's backlog must equal Silver rows minus closure_known=true rows
SELECT (SELECT SUM(open_at_week_end) FROM GOLD_COMPLAINT_WEEK WHERE week_start = '2025-06-23') AS backlog_last_week,
       (SELECT COUNT(*) - COUNT_IF(closure_known) FROM SILVER_COMPLAINT) AS silver_expected;