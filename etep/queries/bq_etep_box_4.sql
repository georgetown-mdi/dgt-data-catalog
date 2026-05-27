-- bq_etep_box_4 -- filters bq_etep_box_3 down to school-age cohort.
-- Birth-year window 2011-2016 matches the canonical etep_box_4 query.

CREATE OR REPLACE TABLE `mdi-governance.etep.bq_etep_box_4` AS
SELECT *
FROM `mdi-governance.etep.bq_etep_box_3`
WHERE EXTRACT(YEAR FROM date_of_birth) BETWEEN 2011 AND 2016;
