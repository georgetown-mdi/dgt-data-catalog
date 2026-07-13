#!/usr/bin/env bash
# om-pg-init-passwords.sh — provision the Airflow database and role on first
# postgres boot so the ingestion container can authenticate over TCP.
#
# Why this file exists:
#   The OM ingestion container connects to `postgresql:5432` via TCP to run
#   `airflow db migrate`. pg_hba.conf requires scram-sha-256 for all TCP
#   connections, but the Airflow role is provisioned without a password by the
#   OM bootstrap process (which runs after these init scripts). By creating the
#   role and database here — with the correct password — the ingestion
#   container finds them already present and skips its own CREATE ROLE step,
#   so authentication works immediately.
#
# Named 99_ to run after the OM image's own init scripts.
# Docker executes /docker-entrypoint-initdb.d/ scripts on first boot only.

set -euo pipefail

AIRFLOW_PG_PASSWORD="${AIRFLOW_DB_PASSWORD:-airflow_pass}"

psql -U "$POSTGRES_USER" -v ON_ERROR_STOP=1 <<SQL
-- Create the role with a password so TCP auth works immediately.
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'airflow') THEN
    CREATE ROLE airflow WITH LOGIN PASSWORD '$AIRFLOW_PG_PASSWORD';
  ELSE
    ALTER ROLE airflow WITH PASSWORD '$AIRFLOW_PG_PASSWORD';
  END IF;
END\$\$;

-- Create the database if it doesn't exist yet.
SELECT 'CREATE DATABASE airflow_db OWNER airflow'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'airflow_db')\gexec

GRANT ALL PRIVILEGES ON DATABASE airflow_db TO airflow;
SQL

# Grant CREATE on public schema inside airflow_db so airflow db migrate can
# create tables. PG 15+ removed the implicit PUBLIC grant on this schema.
psql -U "$POSTGRES_USER" -d airflow_db -v ON_ERROR_STOP=1 <<SQL
GRANT ALL ON SCHEMA public TO airflow;
SQL
