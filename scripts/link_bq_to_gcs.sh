#!/usr/bin/env bash
# Host wrapper for scripts/link_bq_to_gcs.py — runs the Python script
# inside the OpenMetadata ingestion container so the GCP SDK and SA
# credentials are co-located.
#
# Idempotent. Prereqs: `make up`, `make jwt`, `make bq-ingest`,
# `make gcs-ingest`.

set -euo pipefail
cd "$(dirname "$0")/.."

OM_JWT=$(grep ^OM_JWT_TOKEN= .env | cut -d= -f2-)
if [ -z "$OM_JWT" ]; then
    echo "OM_JWT_TOKEN not set in .env — run 'make jwt' first." >&2
    exit 1
fi

# /opt/dgt/scripts is mounted by the overlay. Pass OM_JWT_TOKEN through;
# everything else uses the script's defaults.
exec docker exec -e OM_JWT_TOKEN="$OM_JWT" openmetadata_ingestion \
    python3 /opt/dgt/scripts/link_bq_to_gcs.py
