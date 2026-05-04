-- PostgreSQL-compatible version of CLUE Maryland ingestion script
-- This script transforms Maryland court case data and categorizes cases
-- Prerequisites: Run setup_postgres.sql first and load the CSV data
--
-- IMPORTANT: This version uses VIEWS instead of CTEs to enable
-- OpenMetadata lineage tracking. Each transformation step is a view
-- that can be tracked in the lineage graph.

-- ============================================================
-- SETUP: Set search path to clue schema
-- ============================================================

SET search_path TO clue, public;

-- ============================================================
-- SETUP: Functions for safe parsing (in public schema for permissions)
-- ============================================================

-- Function to safely parse dates (will return NULL on error)
CREATE OR REPLACE FUNCTION public.safe_to_date(date_str TEXT, format TEXT)
RETURNS DATE AS $$
BEGIN
    IF date_str IS NULL OR date_str = '' OR date_str = 'NA' THEN
        RETURN NULL;
    END IF;
    RETURN TO_DATE(date_str, format);
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Function to safely parse JSON
CREATE OR REPLACE FUNCTION public.safe_json(text_str TEXT)
RETURNS JSONB AS $$
BEGIN
    IF text_str IS NULL OR text_str = '' OR text_str = 'NA' THEN
        RETURN NULL;
    END IF;
    RETURN text_str::jsonb;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================
-- DROP existing views and tables (in reverse dependency order)
-- ============================================================

DROP TABLE IF EXISTS clue.final_cases CASCADE;
DROP TABLE IF EXISTS clue.final_defendants CASCADE;
DROP TABLE IF EXISTS clue.final_plaintiffs CASCADE;

DROP VIEW IF EXISTS clue.vw_all_cases CASCADE;
DROP VIEW IF EXISTS clue.vw_all_defendants CASCADE;
DROP VIEW IF EXISTS clue.vw_all_plaintiffs CASCADE;

-- Branch A views
DROP VIEW IF EXISTS clue.vw_label_cases CASCADE;
DROP VIEW IF EXISTS clue.vw_limit_by_subtype CASCADE;
DROP VIEW IF EXISTS clue.vw_real_nulls CASCADE;
DROP VIEW IF EXISTS clue.vw_drop_extras CASCADE;
DROP VIEW IF EXISTS clue.vw_case_table CASCADE;
DROP VIEW IF EXISTS clue.vw_defendant_json CASCADE;
DROP VIEW IF EXISTS clue.vw_defendant_array CASCADE;
DROP VIEW IF EXISTS clue.vw_unpack_defendant_json CASCADE;
DROP VIEW IF EXISTS clue.vw_plaintiff_json CASCADE;
DROP VIEW IF EXISTS clue.vw_plaintiff_array CASCADE;
DROP VIEW IF EXISTS clue.vw_unpack_plaintiff_json CASCADE;

-- Branch B views
DROP VIEW IF EXISTS clue.vw_save_off_the_non_civil CASCADE;
DROP VIEW IF EXISTS clue.vw_fix_the_nulls_here_too CASCADE;

-- Branch B1 views
DROP VIEW IF EXISTS clue.vw_catch_the_remaining_civil_cases CASCADE;
DROP VIEW IF EXISTS clue.vw_extra_case CASCADE;
DROP VIEW IF EXISTS clue.vw_extra_defendant_json CASCADE;
DROP VIEW IF EXISTS clue.vw_extra_defendant_array CASCADE;
DROP VIEW IF EXISTS clue.vw_unpack_extra_defendants CASCADE;
DROP VIEW IF EXISTS clue.vw_extra_plaintiff_json CASCADE;
DROP VIEW IF EXISTS clue.vw_extra_plaintiff_array CASCADE;
DROP VIEW IF EXISTS clue.vw_unpack_extra_plaintiffs CASCADE;

-- Branch B2 views
DROP VIEW IF EXISTS clue.vw_remaining_civil_cases_2 CASCADE;
DROP VIEW IF EXISTS clue.vw_extra_case_2 CASCADE;

-- ============================================================
-- STEP 1: Label cases - Join source_data with case_types lookup
-- ============================================================

CREATE VIEW clue.vw_label_cases AS
SELECT
    t0.id AS id,
    t0.case_number AS case_number,
    t0.caption AS caption,
    t0.name AS name,
    t0.dob AS dob,
    t0.party_type AS party_type,
    t0.court AS court,
    t0.court_id AS court_id,
    t0.case_type AS case_type,
    t0.filing_date AS filing_date,
    t0.status AS status,
    t0.court_system AS court_system,
    t0.checksum AS checksum,
    t0.misc AS misc,
    t0.last_scrape AS last_scrape,
    t0.not_found_at AS not_found_at,
    t0.created_at AS created_at,
    t0.updated_at AS updated_at,
    t0.tracking_number AS tracking_number,
    t0.case_type_code AS case_type_code,
    t0.location AS location,
    t0.defendant AS defendant,
    t0.plaintiff AS plaintiff,
    t0.error AS error,
    t0.versions AS versions,
    t0.parser AS parser,
    t0.cjis AS cjis,
    t0.sentence_length AS sentence_length,
    t1.subtype as subtype
FROM
    clue.source_data AS t0
    LEFT JOIN clue.case_types t1 ON t0.case_type = t1.case_type;

-- ============================================================
-- BRANCH A: Civil cases with known subtypes
-- ============================================================

-- STEP 2: Limit by subtype - Filter to civil case subtypes
CREATE VIEW clue.vw_limit_by_subtype AS
SELECT
    t0.id AS id,
    t0.case_number AS case_number,
    t0.caption AS caption,
    t0.name AS name,
    t0.dob AS dob,
    t0.party_type AS party_type,
    t0.court AS court,
    t0.court_id AS court_id,
    t0.case_type AS case_type,
    t0.filing_date AS filing_date,
    t0.status AS status,
    t0.court_system AS court_system,
    t0.checksum AS checksum,
    t0.misc AS misc,
    t0.last_scrape AS last_scrape,
    t0.not_found_at AS not_found_at,
    t0.created_at AS created_at,
    t0.updated_at AS updated_at,
    t0.tracking_number AS tracking_number,
    t0.case_type_code AS case_type_code,
    t0.location AS location,
    t0.defendant AS defendant,
    t0.plaintiff AS plaintiff,
    t0.error AS error,
    t0.versions AS versions,
    t0.parser AS parser,
    t0.cjis AS cjis,
    t0.sentence_length AS sentence_length,
    CASE
      WHEN t0.subtype IN ('PE, PD', 'PD, PE') THEN 'UNDETERMINED'
      WHEN t0.subtype = 'D' THEN 'DEBT'
      WHEN t0.subtype = 'E' THEN 'EVICTION'
      WHEN t0.subtype = 'PD' THEN 'POSSIBLE DEBT'
      WHEN t0.subtype = 'PE' THEN 'POSSIBLE EVICTION'
      WHEN t0.subtype IS NULL THEN 'NO INFORMATION'
    ELSE NULL END AS clear_type
FROM
    clue.vw_label_cases AS t0
WHERE
    (t0.subtype = 'D')
    OR (t0.subtype = 'E')
    OR (t0.subtype = 'PE')
    OR (t0.subtype = 'PD')
    OR (t0.subtype = 'PE, PD')
    OR (t0.subtype = 'PD, PE');

-- STEP 3: Real nulls - Replace 'NA' strings with actual NULLs
CREATE VIEW clue.vw_real_nulls AS
SELECT
    t0.id AS id,
    CASE WHEN t0.case_number = 'NA' THEN NULL ELSE t0.case_number END AS case_number,
    CASE WHEN t0.caption = 'NA' THEN NULL ELSE t0.caption END AS caption,
    CASE WHEN t0.name = 'NA' THEN NULL ELSE t0.name END AS name,
    CASE WHEN t0.dob = 'NA' THEN NULL ELSE t0.dob END AS dob,
    CASE WHEN t0.party_type = 'NA' THEN NULL ELSE t0.party_type END AS party_type,
    CASE WHEN t0.court = 'NA' THEN NULL ELSE t0.court END AS court,
    CASE WHEN t0.court_id = 'NA' THEN NULL ELSE t0.court_id END AS court_id,
    CASE WHEN t0.case_type = 'NA' THEN NULL ELSE t0.case_type END AS case_type,
    CASE WHEN t0.filing_date = 'NA' THEN NULL ELSE t0.filing_date END AS filing_date,
    CASE WHEN t0.status = 'NA' THEN NULL ELSE t0.status END AS status,
    CASE WHEN t0.court_system = 'NA' THEN NULL ELSE t0.court_system END AS court_system,
    CASE WHEN t0.checksum = 'NA' THEN NULL ELSE t0.checksum END AS checksum,
    CASE WHEN t0.misc = 'NA' THEN NULL ELSE t0.misc END AS misc,
    CASE WHEN t0.last_scrape = 'NA' THEN NULL ELSE t0.last_scrape END AS last_scrape,
    CASE WHEN t0.not_found_at = 'NA' THEN NULL ELSE t0.not_found_at END AS not_found_at,
    t0.created_at AS created_at,
    t0.updated_at AS updated_at,
    CASE WHEN t0.tracking_number = 'NA' THEN NULL ELSE t0.tracking_number END AS tracking_number,
    CASE WHEN t0.case_type_code = 'NA' THEN NULL ELSE t0.case_type_code END AS case_type_code,
    CASE WHEN t0.location = 'NA' THEN NULL ELSE t0.location END AS location,
    CASE WHEN t0.defendant = 'NA' THEN NULL ELSE t0.defendant END AS defendant,
    CASE WHEN t0.plaintiff = 'NA' THEN NULL ELSE t0.plaintiff END AS plaintiff,
    t0.error AS error,
    CASE WHEN t0.versions = 'NA' THEN NULL ELSE t0.versions END AS versions,
    CASE WHEN t0.parser = 'NA' THEN NULL ELSE t0.parser END AS parser,
    CASE WHEN t0.cjis = 'NA' THEN NULL ELSE t0.cjis END AS cjis,
    CASE WHEN t0.sentence_length = 'NA' THEN NULL ELSE t0.sentence_length END AS sentence_length,
    CASE WHEN t0.clear_type = 'NA' THEN NULL ELSE t0.clear_type END AS clear_type
FROM
    clue.vw_limit_by_subtype AS t0;

-- STEP 4: Drop extras - Filter out criminal, family, traffic, probate cases
CREATE VIEW clue.vw_drop_extras AS
SELECT
    t0.id AS id,
    t0.case_number AS case_number,
    t0.caption AS caption,
    t0.name AS name,
    t0.dob AS dob,
    t0.party_type AS party_type,
    t0.court AS court,
    t0.court_id AS court_id,
    t0.case_type AS case_type,
    t0.filing_date AS filing_date,
    t0.status AS status,
    t0.court_system AS court_system,
    t0.checksum AS checksum,
    t0.misc AS misc,
    t0.last_scrape AS last_scrape,
    t0.not_found_at AS not_found_at,
    t0.created_at AS created_at,
    t0.updated_at AS updated_at,
    t0.tracking_number AS tracking_number,
    t0.case_type_code AS case_type_code,
    t0.location AS location,
    t0.defendant AS defendant,
    t0.plaintiff AS plaintiff,
    t0.error AS error,
    t0.versions AS versions,
    t0.parser AS parser,
    t0.cjis AS cjis,
    t0.sentence_length AS sentence_length,
    t0.clear_type AS clear_type
FROM
    clue.vw_real_nulls AS t0
WHERE
    (UPPER(court_system) NOT LIKE '%CRIMINAL%' OR court_system IS NULL) AND
    (UPPER(court_system) NOT LIKE '%FAMILY%' OR court_system IS NULL) AND
    (UPPER(court_system) NOT LIKE '%TRAFFIC%' OR court_system IS NULL) AND
    (UPPER(court_system) NOT LIKE '%PROBATE%' OR court_system IS NULL) AND
    cjis IS NULL;

-- ============================================================
-- BRANCH A1a: Case table extraction
-- ============================================================

CREATE VIEW clue.vw_case_table AS
SELECT
    DISTINCT t0.id::BIGINT AS row_id,
    t0.case_number AS case_number,
    t0.caption AS caption,
    t0.name AS name,
    t0.dob AS birth_date,
    t0.party_type AS role,
    t0.court AS court,
    t0.case_type AS case_type,
    public.safe_to_date(t0.filing_date, 'YYYY-MM-DD') AS file_date,
    t0.status AS case_status,
    t0.court_system AS court_system,
    t0.created_at AS create_date,
    t0.updated_at AS update_date,
    t0.location AS court_location,
    t0.versions AS versions,
    t0.clear_type AS category
FROM
    clue.vw_drop_extras AS t0;

-- ============================================================
-- BRANCH A1b: Defendant extraction from JSON
-- ============================================================

CREATE VIEW clue.vw_defendant_json AS
SELECT
    t0.id::BIGINT AS row_id,
    public.safe_json(t0.defendant) AS defendant
FROM clue.vw_drop_extras AS t0
WHERE t0.defendant IS NOT NULL AND t0.defendant != 'NA';

CREATE VIEW clue.vw_defendant_array AS
SELECT
    row_id,
    elem.value AS defendant
FROM clue.vw_defendant_json,
LATERAL (
    SELECT jsonb_array_elements(defendant) AS value
    WHERE jsonb_typeof(defendant) = 'array'
    UNION ALL
    SELECT defendant AS value
    WHERE jsonb_typeof(defendant) != 'array'
) AS elem
WHERE defendant IS NOT NULL;

CREATE VIEW clue.vw_unpack_defendant_json AS
SELECT
    row_id,
    defendant->>'Name' AS name,
    defendant->>'City' AS city,
    defendant->>'State' AS state,
    defendant->>'Zip Code' AS zip,
    defendant->>'Address' AS address,
    defendant->>'Address1' AS address_ln1,
    defendant->>'Amount' AS address_ln2,
    defendant->>'Party No.' AS party_num,
    defendant->>'Party Type' AS role,
    defendant->>'Business or Organization Name' AS org_name,
    public.safe_to_date(defendant->>'Removal Date', 'MM/DD/YYYY') AS removal_date
FROM clue.vw_defendant_array;

-- ============================================================
-- BRANCH A1c: Plaintiff extraction from JSON
-- ============================================================

CREATE VIEW clue.vw_plaintiff_json AS
SELECT
    t0.id::BIGINT AS row_id,
    public.safe_json(t0.plaintiff) AS plaintiff
FROM clue.vw_drop_extras AS t0
WHERE t0.plaintiff IS NOT NULL AND t0.plaintiff != 'NA';

CREATE VIEW clue.vw_plaintiff_array AS
SELECT
    row_id,
    elem.value AS plaintiff
FROM clue.vw_plaintiff_json,
LATERAL (
    SELECT jsonb_array_elements(plaintiff) AS value
    WHERE jsonb_typeof(plaintiff) = 'array'
    UNION ALL
    SELECT plaintiff AS value
    WHERE jsonb_typeof(plaintiff) != 'array'
) AS elem
WHERE plaintiff IS NOT NULL;

CREATE VIEW clue.vw_unpack_plaintiff_json AS
SELECT
    row_id,
    plaintiff->>'Name' AS name,
    plaintiff->>'City' AS city,
    plaintiff->>'State' AS state,
    plaintiff->>'Zip Code' AS zip,
    plaintiff->>'Address' AS address,
    plaintiff->>'Address1' AS address_ln1,
    plaintiff->>'Amount' AS address_ln2,
    plaintiff->>'Party No.' AS party_num,
    plaintiff->>'Party Type' AS role,
    plaintiff->>'Business or Organization Name' AS org_name,
    public.safe_to_date(plaintiff->>'Removal Date', 'MM/DD/YYYY') AS removal_date
FROM clue.vw_plaintiff_array;

-- ============================================================
-- BRANCH B: Non-civil cases (cases without known civil subtypes)
-- ============================================================

CREATE VIEW clue.vw_save_off_the_non_civil AS
SELECT
    t0.id AS id,
    t0.case_number AS case_number,
    t0.caption AS caption,
    t0.name AS name,
    t0.dob AS dob,
    t0.party_type AS party_type,
    t0.court AS court,
    t0.court_id AS court_id,
    t0.case_type AS case_type,
    t0.filing_date AS filing_date,
    t0.status AS status,
    t0.court_system AS court_system,
    t0.checksum AS checksum,
    t0.misc AS misc,
    t0.last_scrape AS last_scrape,
    t0.not_found_at AS not_found_at,
    t0.created_at AS created_at,
    t0.updated_at AS updated_at,
    t0.tracking_number AS tracking_number,
    t0.case_type_code AS case_type_code,
    t0.location AS location,
    t0.defendant AS defendant,
    t0.plaintiff AS plaintiff,
    t0.error AS error,
    t0.versions AS versions,
    t0.parser AS parser,
    t0.cjis AS cjis,
    t0.sentence_length AS sentence_length,
    CASE
      WHEN t0.subtype IN ('PE, PD', 'PD, PE') THEN 'UNDETERMINED'
      WHEN t0.subtype = 'D' THEN 'DEBT'
      WHEN t0.subtype = 'E' THEN 'EVICTION'
      WHEN t0.subtype = 'PD' THEN 'POSSIBLE DEBT'
      WHEN t0.subtype = 'PE' THEN 'POSSIBLE EVICTION'
      WHEN t0.subtype = 'X' THEN 'OTHER CIVIL'
    ELSE 'NO INFORMATION' END AS clear_type
FROM
    clue.vw_label_cases AS t0
WHERE
    ((t0.subtype != 'D')
    AND (t0.subtype != 'E')
    AND (t0.subtype != 'PE')
    AND (t0.subtype != 'PD')
    AND (t0.subtype != 'PE, PD')
    AND (t0.subtype != 'PD, PE'))
    OR t0.subtype IS NULL;

CREATE VIEW clue.vw_fix_the_nulls_here_too AS
SELECT
    t0.id AS id,
    CASE WHEN t0.case_number = 'NA' THEN NULL ELSE t0.case_number END AS case_number,
    CASE WHEN t0.caption = 'NA' THEN NULL ELSE t0.caption END AS caption,
    CASE WHEN t0.name = 'NA' THEN NULL ELSE t0.name END AS name,
    CASE WHEN t0.dob = 'NA' THEN NULL ELSE t0.dob END AS dob,
    CASE WHEN t0.party_type = 'NA' THEN NULL ELSE t0.party_type END AS party_type,
    CASE WHEN t0.court = 'NA' THEN NULL ELSE t0.court END AS court,
    CASE WHEN t0.court_id = 'NA' THEN NULL ELSE t0.court_id END AS court_id,
    CASE WHEN t0.case_type = 'NA' THEN NULL ELSE t0.case_type END AS case_type,
    CASE WHEN t0.filing_date = 'NA' THEN NULL ELSE t0.filing_date END AS filing_date,
    CASE WHEN t0.status = 'NA' THEN NULL ELSE t0.status END AS status,
    CASE WHEN t0.court_system = 'NA' THEN NULL ELSE t0.court_system END AS court_system,
    CASE WHEN t0.checksum = 'NA' THEN NULL ELSE t0.checksum END AS checksum,
    CASE WHEN t0.misc = 'NA' THEN NULL ELSE t0.misc END AS misc,
    CASE WHEN t0.last_scrape = 'NA' THEN NULL ELSE t0.last_scrape END AS last_scrape,
    CASE WHEN t0.not_found_at = 'NA' THEN NULL ELSE t0.not_found_at END AS not_found_at,
    t0.created_at AS created_at,
    t0.updated_at AS updated_at,
    CASE WHEN t0.tracking_number = 'NA' THEN NULL ELSE t0.tracking_number END AS tracking_number,
    CASE WHEN t0.case_type_code = 'NA' THEN NULL ELSE t0.case_type_code END AS case_type_code,
    CASE WHEN t0.location = 'NA' THEN NULL ELSE t0.location END AS location,
    CASE WHEN t0.defendant = 'NA' THEN NULL ELSE t0.defendant END AS defendant,
    CASE WHEN t0.plaintiff = 'NA' THEN NULL ELSE t0.plaintiff END AS plaintiff,
    t0.error AS error,
    CASE WHEN t0.versions = 'NA' THEN NULL ELSE t0.versions END AS versions,
    CASE WHEN t0.parser = 'NA' THEN NULL ELSE t0.parser END AS parser,
    CASE WHEN t0.cjis = 'NA' THEN NULL ELSE t0.cjis END AS cjis,
    CASE WHEN t0.sentence_length = 'NA' THEN NULL ELSE t0.sentence_length END AS sentence_length,
    CASE WHEN t0.clear_type = 'NA' THEN NULL ELSE t0.clear_type END AS clear_type
FROM
    clue.vw_save_off_the_non_civil AS t0;

-- ============================================================
-- BRANCH B1: Catch remaining civil cases (court_system contains CIVIL)
-- ============================================================

CREATE VIEW clue.vw_catch_the_remaining_civil_cases AS
SELECT
    t0.id AS id,
    t0.case_number AS case_number,
    t0.caption AS caption,
    t0.name AS name,
    t0.dob AS dob,
    t0.party_type AS party_type,
    t0.court AS court,
    t0.court_id AS court_id,
    t0.case_type AS case_type,
    t0.filing_date AS filing_date,
    t0.status AS status,
    t0.court_system AS court_system,
    t0.checksum AS checksum,
    t0.misc AS misc,
    t0.last_scrape AS last_scrape,
    t0.not_found_at AS not_found_at,
    t0.created_at AS created_at,
    t0.updated_at AS updated_at,
    t0.tracking_number AS tracking_number,
    t0.case_type_code AS case_type_code,
    t0.location AS location,
    t0.defendant AS defendant,
    t0.plaintiff AS plaintiff,
    t0.error AS error,
    t0.versions AS versions,
    t0.parser AS parser,
    t0.cjis AS cjis,
    t0.sentence_length AS sentence_length,
    t0.clear_type AS clear_type
FROM
    clue.vw_fix_the_nulls_here_too AS t0
WHERE court_system LIKE '%CIVIL%';

-- BRANCH B1a: Extra cases
CREATE VIEW clue.vw_extra_case AS
SELECT
    DISTINCT t0.id::BIGINT AS row_id,
    t0.case_number AS case_number,
    t0.caption AS caption,
    t0.name AS name,
    t0.dob AS birth_date,
    t0.party_type AS role,
    t0.court AS court,
    t0.case_type AS case_type,
    public.safe_to_date(t0.filing_date, 'YYYY-MM-DD') AS file_date,
    t0.status AS case_status,
    t0.court_system AS court_system,
    t0.created_at AS create_date,
    t0.updated_at AS update_date,
    t0.location AS court_location,
    t0.versions AS versions,
    t0.clear_type AS category
FROM
    clue.vw_catch_the_remaining_civil_cases AS t0;

-- BRANCH B1b: Extra defendants
CREATE VIEW clue.vw_extra_defendant_json AS
SELECT
    t0.id::BIGINT AS row_id,
    public.safe_json(t0.defendant) AS defendant
FROM clue.vw_catch_the_remaining_civil_cases AS t0
WHERE t0.defendant IS NOT NULL AND t0.defendant != 'NA';

CREATE VIEW clue.vw_extra_defendant_array AS
SELECT
    row_id,
    elem.value AS defendant
FROM clue.vw_extra_defendant_json,
LATERAL (
    SELECT jsonb_array_elements(defendant) AS value
    WHERE jsonb_typeof(defendant) = 'array'
    UNION ALL
    SELECT defendant AS value
    WHERE jsonb_typeof(defendant) != 'array'
) AS elem
WHERE defendant IS NOT NULL;

CREATE VIEW clue.vw_unpack_extra_defendants AS
SELECT
    row_id,
    defendant->>'Name' AS name,
    defendant->>'City' AS city,
    defendant->>'State' AS state,
    defendant->>'Zip Code' AS zip,
    defendant->>'Address' AS address,
    defendant->>'Address1' AS address_ln1,
    defendant->>'Amount' AS address_ln2,
    defendant->>'Party No.' AS party_num,
    defendant->>'Party Type' AS role,
    defendant->>'Business or Organization Name' AS org_name,
    public.safe_to_date(defendant->>'Removal Date', 'MM/DD/YYYY') AS removal_date
FROM clue.vw_extra_defendant_array;

-- BRANCH B1c: Extra plaintiffs
CREATE VIEW clue.vw_extra_plaintiff_json AS
SELECT
    t0.id::BIGINT AS row_id,
    public.safe_json(t0.plaintiff) AS plaintiff
FROM clue.vw_catch_the_remaining_civil_cases AS t0
WHERE t0.plaintiff IS NOT NULL AND t0.plaintiff != 'NA';

CREATE VIEW clue.vw_extra_plaintiff_array AS
SELECT
    row_id,
    elem.value AS plaintiff
FROM clue.vw_extra_plaintiff_json,
LATERAL (
    SELECT jsonb_array_elements(plaintiff) AS value
    WHERE jsonb_typeof(plaintiff) = 'array'
    UNION ALL
    SELECT plaintiff AS value
    WHERE jsonb_typeof(plaintiff) != 'array'
) AS elem
WHERE plaintiff IS NOT NULL;

CREATE VIEW clue.vw_unpack_extra_plaintiffs AS
SELECT
    row_id,
    plaintiff->>'Name' AS name,
    plaintiff->>'City' AS city,
    plaintiff->>'State' AS state,
    plaintiff->>'Zip Code' AS zip,
    plaintiff->>'Address' AS address,
    plaintiff->>'Address1' AS address_ln1,
    plaintiff->>'Amount' AS address_ln2,
    plaintiff->>'Party No.' AS party_num,
    plaintiff->>'Party Type' AS role,
    plaintiff->>'Business or Organization Name' AS org_name,
    public.safe_to_date(plaintiff->>'Removal Date', 'MM/DD/YYYY') AS removal_date
FROM clue.vw_extra_plaintiff_array;

-- ============================================================
-- BRANCH B2: Remaining civil cases (case-insensitive CIVIL match)
-- ============================================================

CREATE VIEW clue.vw_remaining_civil_cases_2 AS
SELECT
    t0.id AS id,
    t0.case_number AS case_number,
    t0.caption AS caption,
    t0.name AS name,
    t0.dob AS dob,
    t0.party_type AS party_type,
    t0.court AS court,
    t0.court_id AS court_id,
    t0.case_type AS case_type,
    t0.filing_date AS filing_date,
    t0.status AS status,
    t0.court_system AS court_system,
    t0.checksum AS checksum,
    t0.misc AS misc,
    t0.last_scrape AS last_scrape,
    t0.not_found_at AS not_found_at,
    t0.created_at AS created_at,
    t0.updated_at AS updated_at,
    t0.tracking_number AS tracking_number,
    t0.case_type_code AS case_type_code,
    t0.location AS location,
    t0.defendant AS defendant,
    t0.plaintiff AS plaintiff,
    t0.error AS error,
    t0.versions AS versions,
    t0.parser AS parser,
    t0.cjis AS cjis,
    t0.sentence_length AS sentence_length,
    t0.clear_type AS clear_type
FROM
    clue.vw_fix_the_nulls_here_too AS t0
WHERE
    court_system NOT LIKE '%CIVIL%' AND
    UPPER(court_system) LIKE '%CIVIL%';

-- BRANCH B2a: Extra cases 2
CREATE VIEW clue.vw_extra_case_2 AS
SELECT
    DISTINCT t0.id::BIGINT AS row_id,
    t0.case_number AS case_number,
    t0.caption AS caption,
    t0.name AS name,
    t0.dob AS birth_date,
    t0.party_type AS role,
    t0.court AS court,
    t0.case_type AS case_type,
    public.safe_to_date(t0.filing_date, 'YYYY-MM-DD') AS file_date,
    t0.status AS case_status,
    t0.court_system AS court_system,
    t0.created_at AS create_date,
    t0.updated_at AS update_date,
    t0.location AS court_location,
    t0.versions AS versions,
    t0.clear_type AS category
FROM
    clue.vw_remaining_civil_cases_2 AS t0;

-- ============================================================
-- COMBINED VIEWS: Union all branches
-- ============================================================

-- Combine all case data
CREATE VIEW clue.vw_all_cases AS
SELECT * FROM clue.vw_case_table
UNION ALL
SELECT * FROM clue.vw_extra_case
UNION ALL
SELECT * FROM clue.vw_extra_case_2;

-- Combine all defendant data
CREATE VIEW clue.vw_all_defendants AS
SELECT * FROM clue.vw_unpack_defendant_json
UNION ALL
SELECT * FROM clue.vw_unpack_extra_defendants;

-- Combine all plaintiff data
CREATE VIEW clue.vw_all_plaintiffs AS
SELECT * FROM clue.vw_unpack_plaintiff_json
UNION ALL
SELECT * FROM clue.vw_unpack_extra_plaintiffs;

-- ============================================================
-- ETL PROCEDURE: populates clue.cases / defendants / plaintiffs
-- ============================================================
--
-- Why a stored procedure instead of `SELECT INTO clue.final_*`?
--
-- OpenMetadata extracts table-to-table lineage from three places:
--   1. CREATE VIEW definitions  (already covered by the 26 views above)
--   2. pg_stat_statements query log  (needs explicit INSERT INTO ... SELECT)
--   3. Stored procedure bodies  (parsed via OM's SQL parser)
--
-- v1 used `SELECT INTO clue.final_*`, which OM's query parser sometimes
-- treats as opaque, leaving final_* tables with no upstream edge. By
-- wrapping explicit `INSERT INTO target (col_list) SELECT (col_list) FROM
-- source` statements in a procedure, we get column-level lineage from
-- *both* the procedure-body parser AND the query log (since
-- `pg_stat_statements.track=all` records nested statements too).

CREATE OR REPLACE PROCEDURE clue.run_etl()
LANGUAGE plpgsql
AS $proc$
BEGIN
    -- Refresh destinations atomically. CASCADE clears defendants/plaintiffs
    -- via their FK to cases.row_id.
    TRUNCATE TABLE clue.cases CASCADE;

    -- Cases: union of three disjoint branches (drop_extras / extra_case / extra_case_2)
    INSERT INTO clue.cases (
        row_id, case_number, caption, name, birth_date, role,
        court, case_type, file_date, case_status, court_system,
        create_date, update_date, court_location, versions, category
    )
    SELECT
        row_id, case_number, caption, name, birth_date, role,
        court, case_type, file_date, case_status, court_system,
        create_date, update_date, court_location, versions, category
    FROM clue.vw_all_cases;

    -- Defendants: JSON-unpacked, joined back to populated cases for FK safety.
    INSERT INTO clue.defendants (
        row_id, name, city, state, zip, address, address_ln1, address_ln2,
        party_num, role, org_name, removal_date
    )
    SELECT
        d.row_id, d.name, d.city, d.state, d.zip, d.address, d.address_ln1, d.address_ln2,
        d.party_num, d.role, d.org_name, d.removal_date
    FROM clue.vw_all_defendants d
    INNER JOIN clue.cases c ON c.row_id = d.row_id;

    -- Plaintiffs: same pattern.
    INSERT INTO clue.plaintiffs (
        row_id, name, city, state, zip, address, address_ln1, address_ln2,
        party_num, role, org_name, removal_date
    )
    SELECT
        p.row_id, p.name, p.city, p.state, p.zip, p.address, p.address_ln1, p.address_ln2,
        p.party_num, p.role, p.org_name, p.removal_date
    FROM clue.vw_all_plaintiffs p
    INNER JOIN clue.cases c ON c.row_id = p.row_id;
END;
$proc$;

COMMENT ON PROCEDURE clue.run_etl() IS
'Materializes the CLUE final tables from the view chain. Run after each refresh of clue.source_data. Lineage edges expected: clue.cases <- vw_all_cases; clue.defendants <- vw_all_defendants + clue.cases; clue.plaintiffs <- vw_all_plaintiffs + clue.cases.';

-- Run the procedure once to populate the destinations on first install.
CALL clue.run_etl();

-- ============================================================
-- SUMMARY STATISTICS
-- ============================================================

SELECT
    'cases'::text AS table_name, COUNT(*) AS row_count, COUNT(DISTINCT row_id) AS unique_rows
FROM clue.cases
UNION ALL
SELECT 'defendants', COUNT(*), COUNT(DISTINCT row_id) FROM clue.defendants
UNION ALL
SELECT 'plaintiffs', COUNT(*), COUNT(DISTINCT row_id) FROM clue.plaintiffs;
