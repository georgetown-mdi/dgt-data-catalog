-- bq_etep_box_6 -- 12,000-row random subsample of bq_etep_box_3
-- filtered to the same birth-year window as bq_etep_box_4.

CREATE OR REPLACE TABLE `mdi-governance.etep.bq_etep_box_6` AS
SELECT *
FROM `mdi-governance.etep.bq_etep_box_3`
WHERE EXTRACT(YEAR FROM date_of_birth) BETWEEN 2011 AND 2016
ORDER BY RAND()
LIMIT 12000;
