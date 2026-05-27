-- bq_etep_box_3_dictionary -- data dictionary entries used downstream.
-- Independent of any source tables; built from inline STRUCT arrays.
-- The canonical script has a long commented-out tail enumerating every
-- variable; this file keeps only the live UNNEST blocks. Extend the
-- arrays in place as more variables get documented.

CREATE OR REPLACE TABLE `mdi-governance.etep.bq_etep_box_3_dictionary`
OPTIONS(
  description="Data dictionary for specified bq_table_id and gcp_data_id."
) AS

-- DECENNIAL CENSUS VARIABLES
SELECT
  variable_name,
  data_type,
  description,
  codes,
  'decennial_census'        AS bq_table_id,
  'decennial_census_source' AS gcp_data_id
FROM UNNEST([
  STRUCT(
    'simulant_id' AS variable_name,
    'STRING'      AS data_type,
    'Unique identifier of each individual...' AS description,
    ''            AS codes
  ),
  STRUCT('household_id', 'STRING',  'Unique identifier of each household...', ''),
  STRUCT('age',          'INTEGER', 'Age of simulated person...',             '')
])

UNION ALL

-- SOCIAL SECURITY / TAX VARIABLES
SELECT
  variable_name,
  data_type,
  description,
  codes,
  'taxes_w2_and_1099' AS bq_table_id,
  'w2_1099_source'    AS gcp_data_id
FROM UNNEST([
  STRUCT(
    'income' AS variable_name,
    'FLOAT64' AS data_type,
    'Simulated annual income from employer...' AS description,
    '' AS codes
  ),
  STRUCT('employer_id', 'STRING', 'Unique identifier for the company...', '')
]);
