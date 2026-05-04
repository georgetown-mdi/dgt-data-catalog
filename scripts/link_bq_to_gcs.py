#!/usr/bin/env python3
"""Wire OpenMetadata lineage edges from BigQuery EXTERNAL tables to the
GCS Container they federate to.

Runs in two contexts:

  * Inside the OpenMetadata ingestion container — paths default to
    /opt/secrets/gcp-sa.json, http://openmetadata-server:8585, and
    OM_JWT_TOKEN is read from the environment.
  * On the host (via scripts/link_bq_to_gcs.sh, which `docker exec`s
    this script inside the container) — same defaults work.

Idempotent: PUT /api/v1/lineage upserts.
"""

import json
import os
import sys
from urllib import request
from urllib.error import HTTPError

from google.cloud import bigquery
from google.oauth2 import service_account

OM_URL          = os.environ.get("OM_URL", "http://openmetadata-server:8585")
OM_JWT          = os.environ.get("OM_JWT_TOKEN", "")
SA_PATH         = os.environ.get("GCP_SA_PATH", "/opt/secrets/gcp-sa.json")
BQ_PROJECT      = os.environ.get("BQ_PROJECT", "mdi-governance")
BQ_DATASET      = os.environ.get("BQ_DATASET", "etep")
BQ_SERVICE_NAME = os.environ.get("BQ_SERVICE_NAME", "dgt-bigquery")
GCS_SERVICE     = os.environ.get("GCS_SERVICE", "dgt-gcs")
GCS_BUCKET      = os.environ.get("GCS_BUCKET", "etep")

if not OM_JWT:
    print("OM_JWT_TOKEN not set — run `make jwt` and re-source the env.", file=sys.stderr)
    sys.exit(1)


def om_get(path):
    req = request.Request(f"{OM_URL}{path}", headers={"Authorization": f"Bearer {OM_JWT}"})
    with request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def om_put_lineage(from_id, from_type, to_id, to_type):
    body = json.dumps({
        "edge": {
            "fromEntity": {"id": from_id, "type": from_type},
            "toEntity":   {"id": to_id,   "type": to_type},
        }
    }).encode()
    req = request.Request(
        f"{OM_URL}/api/v1/lineage",
        data=body, method="PUT",
        headers={
            "Authorization": f"Bearer {OM_JWT}",
            "Content-Type":  "application/json",
        },
    )
    try:
        with request.urlopen(req, timeout=30) as r:
            return r.status
    except HTTPError as e:
        raise RuntimeError(f"PUT /api/v1/lineage failed: {e.code} {e.read().decode()[:200]}")


# 1. Resolve the GCS Container's id (destination side of every edge).
gcs_fqn = f"{GCS_SERVICE}.{GCS_BUCKET}"
gcs = om_get(f"/api/v1/containers/name/{gcs_fqn}")
print(f"GCS container {gcs_fqn}  id={gcs['id']}")

# 2. List EXTERNAL tables in the BigQuery dataset using the SA.
creds = service_account.Credentials.from_service_account_file(
    SA_PATH, scopes=["https://www.googleapis.com/auth/cloud-platform"],
)
bq = bigquery.Client(project=BQ_PROJECT, credentials=creds)

externals = []
for t in bq.list_tables(f"{BQ_PROJECT}.{BQ_DATASET}"):
    ti = bq.get_table(t.reference)
    if ti.table_type == "EXTERNAL":
        externals.append(ti.table_id)
print(f"External tables ({len(externals)}): {externals}")

# 3. Upsert one lineage edge per external table.
for tbl in externals:
    bq_fqn = f"{BQ_SERVICE_NAME}.{BQ_PROJECT}.{BQ_DATASET}.{tbl}"
    bq_t = om_get(f"/api/v1/tables/name/{bq_fqn}")
    om_put_lineage(gcs["id"], "container", bq_t["id"], "table")
    print(f"  link  {gcs_fqn:25s}  ->  {tbl}")

print(f"OK — {len(externals)} edges upserted under {gcs_fqn}.")
