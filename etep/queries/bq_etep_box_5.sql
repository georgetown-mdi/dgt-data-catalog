-- bq_etep_box_5 -- adds synthetic school-enrollment columns to bq_etep_box_4.
--
-- All synthetic columns are FARM_FINGERPRINT-seeded so the same simulant_id
-- always yields the same value (reproducible across re-runs). RAND() is
-- used in a couple places for additional variance per-run on numeric cols.
--
-- Column-name note: the canonical etep_box_5.sql defines the column as
-- `504_ACCOMMODATION` (digit-leading, backticks required). Downstream
-- canonical etep_box_10.sql references it as `_504_ACCOMMODATION` because
-- BigQuery's CSV-import auto-fixer prepends `_` to digit-leading names.
-- Since the bq_ pipeline skips the CSV roundtrip, we use the post-fixer
-- name directly so bq_etep_box_10 reads it without any rename.

CREATE OR REPLACE TABLE `mdi-governance.etep.bq_etep_box_5` AS
SELECT
  *,

  -- LEA_ID: 50% '01', 50% random between 02-69
  CASE
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 100)) < 50 THEN '01'
    ELSE LPAD(CAST(2 + CAST(ABS(MOD(FARM_FINGERPRINT(simulant_id) + CAST(RAND() * 1000 AS INT64), 68)) AS INT64) AS STRING), 2, '0')
  END AS LEA_ID,

  -- LOCAL_SCHOOL_ID: random 3-digit numeric ID
  CAST(100 + CAST(RAND() * 900 AS INT64) AS STRING) AS LOCAL_SCHOOL_ID,

  -- SCHOOL_YEAR: fixed at 2030
  2030 AS SCHOOL_YEAR,

  -- SIS_ID: sequential starting from 100
  ROW_NUMBER() OVER (ORDER BY simulant_id) + 99 AS SIS_ID,

  -- FIRST_NINTH_GRADE_YEAR: dob year + 14
  EXTRACT(YEAR FROM date_of_birth) + 14 AS FIRST_NINTH_GRADE_YEAR,

  -- EL_INDICATOR: 10% YES, correlated with Latino
  CASE
    WHEN race_ethnicity = 'Latino' AND ABS(MOD(FARM_FINGERPRINT(simulant_id), 100)) < 10 THEN 'YES'
    ELSE 'NO'
  END AS EL_INDICATOR,

  -- FARMS: 10% F, 10% R, 40% C, rest NULL
  CASE
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 100)) < 10 THEN 'F'
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 100)) < 20 THEN 'R'
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 100)) < 60 THEN 'C'
    ELSE NULL
  END AS FARMS,

  -- HOMELESS_INDICATOR: 8% YES
  CASE
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 100)) < 8 THEN 'YES'
    ELSE 'NO'
  END AS HOMELESS_INDICATOR,

  -- RESIDENCY: 97% R, 3% N
  CASE
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 100)) < 97 THEN 'R'
    ELSE 'N'
  END AS RESIDENCY,

  -- MILITARY_FAMILY: 5% YES
  CASE
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 100)) < 5 THEN 'YES'
    ELSE 'NO'
  END AS MILITARY_FAMILY,

  -- _504_ACCOMMODATION: 15% YES (see column-name note above)
  CASE
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 100)) < 15 THEN 'YES'
    ELSE 'NO'
  END AS _504_ACCOMMODATION,

  -- DUAL_ENROLLMENT_INDICATOR: 5% YES
  CASE
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 100)) < 5 THEN 'YES'
    ELSE 'NO'
  END AS DUAL_ENROLLMENT_INDICATOR,

  -- IHE_ENROLLMENT_1: institution code for dual-enrolled rows
  CASE
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 100)) < 5 THEN
      CASE
        -- household_id (not simulant_id) for independent distribution from the gating
        WHEN MOD(ABS(FARM_FINGERPRINT(household_id) + 1), 100) < 60 THEN '208900'  -- 60% PGCC
        WHEN MOD(ABS(FARM_FINGERPRINT(household_id) + 1), 100) < 80 THEN '691100'  -- 20% MC
        ELSE '372700'                                                              -- 20% NVCC
      END
    ELSE NULL
  END AS IHE_ENROLLMENT_1,

  -- ENROLL_GRADE_LEVEL: 09/10/11/12 + alt codes
  CASE
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 7)) = 0 THEN '09'
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 7)) = 1 THEN '10'
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 7)) = 2 THEN '11'
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 7)) = 3 THEN '12'
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 7)) = 4 THEN 'AW'
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 7)) = 5 THEN 'AB'
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 7)) = 6 THEN 'AS'
    ELSE 'AG'
  END AS ENROLL_GRADE_LEVEL,

  -- NATIV_LANG: weighted distribution
  CASE
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 1000)) < 880 THEN 'English'
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 1000)) < 970 THEN 'Spanish'
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 1000)) < 985 THEN 'Amharic'
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 1000)) < 991 THEN 'French'
    WHEN ABS(MOD(FARM_FINGERPRINT(simulant_id), 1000)) < 998 THEN 'Chinese'
    ELSE 'Arabic'
  END AS NATIV_LANG

FROM
  `mdi-governance.etep.bq_etep_box_4`;
