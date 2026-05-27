-- bq_etep_box_3 -- BigQuery-native materialization of the etep_box_3 query.
--
-- Source-of-truth canonical query lives in the Dataform repo at
--   Test/BigQuery_DC_ETEP_test/pseudopeople_scripts/etep_box_3.sql
-- This file is the bq_ variant: same Step-1 CTAS, destination renamed
-- to bq_etep_box_3, and the Step-2..4 GCS-export + external-table dance
-- is dropped. We want a real BQ table here, not a CSV-backed EXTERNAL.
--
-- Joins decennial_census with social_security for DC residents in 2030
-- where the SS event is a creation. Verified upstream tables present
-- on 2026-05-14.

CREATE OR REPLACE TABLE `mdi-governance.etep.bq_etep_box_3` AS
SELECT
  dc.*,
  ss.first_name          AS ss_first_name,
  ss.middle_name         AS ss_middle_name,
  ss.last_name           AS ss_last_name,
  ss.date_of_birth       AS ss_date_of_birth,
  ss.copy_date_of_birth  AS ss_copy_date_of_birth,
  ss.ssn                 AS ss_ssn,
  ss.sex                 AS ss_sex,
  ss.race_ethnicity      AS ss_race_ethnicity,
  ss.event_type          AS ss_event_type,
  ss.event_date          AS ss_event_date,
  ss.random_seed         AS ss_random_seed
FROM
  `mdi-governance.pseudopeople.decennial_census` dc
INNER JOIN
  `mdi-governance.pseudopeople.social_security`  ss
  ON dc.simulant_id = ss.simulant_id
WHERE
  dc.year = 2030
  AND dc.state = 'DC'
  AND ss.event_type = 'creation';
