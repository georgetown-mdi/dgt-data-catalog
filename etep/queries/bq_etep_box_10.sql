-- bq_etep_box_10 -- inner join of bq_etep_box_9 (W2 records) with
-- bq_etep_box_7 (the school-cohort overlap of box_5/box_6) on
-- simulant_id, taking all box_9 columns plus the synthetic school
-- columns from box_7.

CREATE OR REPLACE TABLE `mdi-governance.etep.bq_etep_box_10` AS
SELECT
  b9.*,
  b7.LEA_ID,
  b7.LOCAL_SCHOOL_ID,
  b7.SCHOOL_YEAR,
  b7.SIS_ID,
  b7.FIRST_NINTH_GRADE_YEAR,
  b7.EL_INDICATOR,
  b7.FARMS,
  b7.HOMELESS_INDICATOR,
  b7.RESIDENCY,
  b7.MILITARY_FAMILY,
  b7._504_ACCOMMODATION,
  b7.DUAL_ENROLLMENT_INDICATOR,
  b7.IHE_ENROLLMENT_1,
  b7.ENROLL_GRADE_LEVEL,
  b7.NATIV_LANG
FROM       `mdi-governance.etep.bq_etep_box_9` b9
INNER JOIN `mdi-governance.etep.bq_etep_box_7` b7
  ON b9.simulant_id = b7.simulant_id;
