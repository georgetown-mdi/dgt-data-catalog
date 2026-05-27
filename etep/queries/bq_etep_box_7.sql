-- bq_etep_box_7 -- inner join of bq_etep_box_5 with bq_etep_box_6 on
-- simulant_id, keeping all columns from box_5. Effectively
-- "rows of box_5 that also survived the 12K random subsample in box_6".

CREATE OR REPLACE TABLE `mdi-governance.etep.bq_etep_box_7` AS
SELECT b5.*
FROM       `mdi-governance.etep.bq_etep_box_5` b5
INNER JOIN `mdi-governance.etep.bq_etep_box_6` b6
  ON b5.simulant_id = b6.simulant_id;
