#!/usr/bin/env bash
# Load the CLUE Allegany subset into the governance Postgres under schema `clue`.
# Idempotent: re-running drops + re-creates the clue schema.

set -euo pipefail

cd "$(dirname "$0")/.."

DB_USER=$(grep -E '^GOV_DB_USER=' .env 2>/dev/null | cut -d= -f2- || true)
DB_NAME=$(grep -E '^GOV_DB_NAME=' .env 2>/dev/null | cut -d= -f2- || true)
: "${DB_USER:=governance_admin}"
: "${DB_NAME:=governance_catalog}"

CONTAINER=dgt_governance_pg
PSQL=(docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME")

echo "==> Resetting clue schema"
"${PSQL[@]}" -c "DROP SCHEMA IF EXISTS clue CASCADE; CREATE SCHEMA clue;"

echo "==> 00_setup.sql (table DDL)"
"${PSQL[@]}" -f /opt/clue/sql/00_setup.sql

echo "==> 05_helpers.sql (functions)"
"${PSQL[@]}" -f /opt/clue/sql/05_helpers.sql

echo "==> Staging cleaned case_types.csv to /tmp inside container"
# CSV has a second header row partway through (two appended datasets); take the first block only.
awk 'NR==1 {print; next} /^case_count,/ {exit} {print}' clue/data/case_types.csv \
  | docker exec -i "$CONTAINER" sh -c 'cat > /tmp/case_types.clean.csv'

echo "==> Loading case_types"
"${PSQL[@]}" -c "\\COPY clue.case_types (case_count, case_type, subtype, notes, col5, col6, col7) FROM '/tmp/case_types.clean.csv' WITH (FORMAT csv, HEADER true, NULL 'NA');"

echo "==> Recording file_load_metadata, then loading source_data"
"${PSQL[@]}" <<'SQL'
WITH ins AS (
  INSERT INTO clue.file_load_metadata (file_name, file_path, file_size_bytes, load_status)
  VALUES ('allegany_subset.csv', '/opt/clue/data/allegany_subset.csv',
          pg_read_binary_file('/opt/clue/data/allegany_subset.csv') IS NOT NULL :: int * 0, 'started')
  RETURNING load_id
)
SELECT load_id FROM ins;
SQL

"${PSQL[@]}" -c "\\COPY clue.source_data (row_num, id, case_number, caption, name, dob, party_type, court, court_id, case_type, filing_date, status, court_system, checksum, misc, last_scrape, not_found_at, created_at, updated_at, tracking_number, case_type_code, location, defendant, plaintiff, error, versions, parser, cjis, sentence_length) FROM '/opt/clue/data/allegany_subset.csv' WITH (FORMAT csv, HEADER true, NULL 'NA', ENCODING 'UTF8');"

"${PSQL[@]}" <<'SQL'
UPDATE clue.source_data SET load_id = (SELECT MAX(load_id) FROM clue.file_load_metadata)
WHERE load_id IS NULL;

UPDATE clue.file_load_metadata SET
    rows_loaded = (SELECT COUNT(*) FROM clue.source_data),
    load_completed_at = CURRENT_TIMESTAMP,
    load_status = 'completed'
WHERE load_id = (SELECT MAX(load_id) FROM clue.file_load_metadata);
SQL

echo "==> 10_transforms.sql (views + clue.run_etl procedure + initial CALL)"
"${PSQL[@]}" -f /opt/clue/sql/10_transforms.sql

echo "==> Summary"
"${PSQL[@]}" -c "
SELECT 'source_data'::text  AS tbl, COUNT(*) FROM clue.source_data
UNION ALL SELECT 'case_types',     COUNT(*) FROM clue.case_types
UNION ALL SELECT 'cases',          COUNT(*) FROM clue.cases
UNION ALL SELECT 'defendants',     COUNT(*) FROM clue.defendants
UNION ALL SELECT 'plaintiffs',     COUNT(*) FROM clue.plaintiffs;
SELECT viewname FROM pg_views WHERE schemaname = 'clue' ORDER BY viewname;
SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'clue' ORDER BY proname;"

echo "OK — CLUE subset loaded into $DB_NAME.clue (re-run ETL anytime via: CALL clue.run_etl())"
