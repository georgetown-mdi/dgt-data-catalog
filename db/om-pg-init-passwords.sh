#!/usr/bin/env bash
# om-pg-init-passwords.sh — sets passwords for roles the OM postgres image
# creates during its own initialisation.
#
# Why this file exists:
#   The OM postgres image creates the `airflow` role via its own init scripts,
#   but does not set a password.  pg_hba.conf requires scram-sha-256 for all
#   TCP/IP connections, so the ingestion container (which connects to
#   `postgresql:5432` over the Docker network) fails to authenticate.
#   Setting the password here fixes that without touching pg_hba.conf.
#
# Named 99_ so it runs after the OM image's own init scripts (which typically
# use 00_–10_ prefixes).  Docker runs files in /docker-entrypoint-initdb.d/
# in alphabetical order on first boot only (when PGDATA is empty).

set -euo pipefail

AIRFLOW_PG_PASSWORD="${AIRFLOW_DB_PASSWORD:-airflow_pass}"

psql -U "$POSTGRES_USER" -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'airflow') THEN
    ALTER ROLE airflow WITH PASSWORD '$AIRFLOW_PG_PASSWORD';
  END IF;
END\$\$;
SQL
