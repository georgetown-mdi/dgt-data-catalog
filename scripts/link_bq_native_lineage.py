#!/usr/bin/env python3
"""Bridge GCP Data Lineage edges into OpenMetadata for the etep.bq_* tables.

Stopgap for the IAM gap that blocks the standard `bq-lineage` workflow.
Once the service account gets `bigquery.jobs.listAll` (via
`roles/bigquery.resourceAdmin`), this script becomes redundant — the
upstream OM YAML pipeline emits the same edges automatically. Delete this
file then.

How it works:
  1. List every table OM knows about under the etep dataset whose name
     starts with bq_  (matches the user's bq_etep_box_* convention).
  2. For each, call the GCP Data Lineage API as the *user* — not the SA —
     because the SA doesn't have `datalineage` read perms either, but
     the logged-in gcloud user (kl1099@georgetown.edu) does.
  3. Translate each returned upstream BigQuery FQN to OM's FQN.
  4. PUT /api/v1/lineage to upsert a Container/Table edge in OM.

Auth split:
  - Data Lineage read: `gcloud auth print-access-token` (your user account)
  - OM write:          OM_JWT_TOKEN from .env (the ingestion bot)

Idempotent: PUT upserts. Re-run any time new CTAS work lands.
Edges where the upstream is NOT ingested in OM (e.g., pseudopeople.* —
not in the BQ ingestion's schemaFilterPattern) are reported and skipped.
"""

import json
import os
import subprocess
import sys
from urllib import request
from urllib.error import HTTPError

OM_URL       = os.environ.get("OM_URL", "http://localhost:8585")
PROJECT_ID   = os.environ.get("BQ_PROJECT", "mdi-governance")
GCP_LOCATION = os.environ.get("GCP_LOCATION", "us")
BQ_SERVICE   = os.environ.get("BQ_SERVICE", "dgt-bigquery")
BQ_DATABASE  = os.environ.get("BQ_DATABASE", "mdi-governance")
BQ_SCHEMA    = os.environ.get("BQ_SCHEMA", "etep")
BQ_PREFIX    = os.environ.get("BQ_PREFIX", "bq_")


def env_var(name: str) -> str:
    """Read a key from .env in the repo root."""
    path = os.path.join(os.path.dirname(__file__), "..", ".env")
    with open(path) as f:
        for line in f:
            if line.startswith(f"{name}="):
                return line.strip().split("=", 1)[1]
    raise RuntimeError(f"{name} not in .env")


def user_access_token() -> str:
    """The logged-in gcloud user's OAuth token. Short-lived (~1 hour)."""
    try:
        return subprocess.check_output(
            ["gcloud", "auth", "print-access-token"], text=True
        ).strip()
    except subprocess.CalledProcessError:
        sys.exit("ERROR: `gcloud auth print-access-token` failed. Run `gcloud auth login` first.")


OM_JWT     = env_var("OM_JWT_TOKEN")
USER_TOKEN = user_access_token()


def om_get(path: str) -> dict | None:
    req = request.Request(
        f"{OM_URL}{path}", headers={"Authorization": f"Bearer {OM_JWT}"}
    )
    try:
        with request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())
    except HTTPError as e:
        if e.code == 404:
            return None
        raise


def om_put_lineage(from_id: str, to_id: str) -> None:
    body = json.dumps({
        "edge": {
            "fromEntity": {"id": from_id, "type": "table"},
            "toEntity":   {"id": to_id,   "type": "table"},
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
    with request.urlopen(req, timeout=30) as r:
        if r.status >= 300:
            raise RuntimeError(f"PUT /api/v1/lineage returned {r.status}")


def dataplex_upstream(bq_fqn: str) -> list[str]:
    """Return upstream BigQuery FQNs (in 'bigquery:project.dataset.table' form)
    for the given target FQN."""
    body = json.dumps({
        "target":   {"fullyQualifiedName": f"bigquery:{bq_fqn}"},
        "pageSize": 50,
    }).encode()
    req = request.Request(
        f"https://datalineage.googleapis.com/v1/projects/{PROJECT_ID}/locations/{GCP_LOCATION}:searchLinks",
        data=body, method="POST",
        headers={
            "Authorization": f"Bearer {USER_TOKEN}",
            "Content-Type":  "application/json",
        },
    )
    with request.urlopen(req, timeout=30) as r:
        data = json.loads(r.read())
    return [link["source"]["fullyQualifiedName"] for link in data.get("links", [])]


def dataplex_to_om_fqn(dataplex_fqn: str) -> str | None:
    """bigquery:mdi-governance.etep.X -> dgt-bigquery.mdi-governance.etep.X.
    Returns None for non-BigQuery sources (Data Lineage also tracks GCS,
    Spanner, etc.)."""
    if not dataplex_fqn.startswith("bigquery:"):
        return None
    return f"{BQ_SERVICE}.{dataplex_fqn[len('bigquery:'):]}"


def main() -> None:
    # 1. Find target tables in OM matching the etep.bq_* convention.
    tables = om_get(
        f"/api/v1/tables?service={BQ_SERVICE}&limit=500&fields=fullyQualifiedName"
    )
    target_prefix = f"{BQ_SERVICE}.{BQ_DATABASE}.{BQ_SCHEMA}.{BQ_PREFIX}"
    targets = [
        t for t in tables.get("data", [])
        if t["fullyQualifiedName"].startswith(target_prefix)
    ]
    print(f"Found {len(targets)} target table(s) matching {target_prefix}*")
    if not targets:
        print("Nothing to do — re-run `make bq-ingest` after materializing bq_etep_box_* tables.")
        return

    n_edges  = 0
    n_skip   = 0
    n_targets_with_edges = 0

    # 2. For each target, fetch upstream from Data Lineage and post to OM.
    for t in targets:
        target_om_fqn = t["fullyQualifiedName"]
        target_bq_fqn = target_om_fqn[len(f"{BQ_SERVICE}."):]  # strip the service prefix
        upstreams = dataplex_upstream(target_bq_fqn)
        print(f"\n  {target_bq_fqn}  ({len(upstreams)} upstream link(s) from Data Lineage)")
        if not upstreams:
            continue
        n_targets_with_edges += 1

        for src_dataplex_fqn in upstreams:
            src_om_fqn = dataplex_to_om_fqn(src_dataplex_fqn)
            if not src_om_fqn:
                print(f"    skip  {src_dataplex_fqn}  (not BigQuery)")
                n_skip += 1
                continue

            src_entity = om_get(f"/api/v1/tables/name/{src_om_fqn}")
            if not src_entity:
                print(f"    skip  {src_om_fqn}  (not ingested in OM)")
                n_skip += 1
                continue

            om_put_lineage(src_entity["id"], t["id"])
            print(f"    edge  {src_om_fqn}  ->  {target_bq_fqn}")
            n_edges += 1

    print(f"\nDone. {n_edges} edge(s) upserted, {n_skip} skipped, "
          f"{n_targets_with_edges}/{len(targets)} target(s) had upstream lineage.")
    if n_skip:
        print("Skipped sources are usually in datasets OM doesn't ingest "
              "(e.g., pseudopeople). To include them, broaden "
              "openmetadata/bigquery_ingestion.yaml's schemaFilterPattern.")


if __name__ == "__main__":
    main()
