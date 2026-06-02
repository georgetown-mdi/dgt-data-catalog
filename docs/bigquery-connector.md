# BigQuery connector

How DGT-next's `dgt-bigquery` service is wired up, what works against the
current `mdi-governance` service account, and what needs additional IAM to
unlock the rest.

## Wiring

```
host                                 ingestion container
secrets/gcp-sa.json   ──── ro ───►   /opt/secrets/gcp-sa.json
openmetadata/                ──►     /opt/airflow/openmetadata/
  bigquery_ingestion.yaml              (metadata ingest)
  bigquery_profiler.yaml               (metadata profile)
  bigquery_classification.yaml         (metadata classify)
  bigquery_lineage.yaml                (metadata ingest — gated on IAM)
airflow/dags/
  dgt_bigquery_ingestion.py
  dgt_bigquery_profiler.py
  dgt_bigquery_classification.py
```

`secrets/` is `.gitignore`d (everything except a `.gitkeep`). The credential
JSON is mounted read-only on a fixed path; the YAMLs reference it via
`credentials.gcpConfig.path`.

## YAML schema gotcha

The published OM 1.12.x docs show `credentials.gcpConfig.credentialsPath`.
**That's wrong** — the actual Pydantic schema (`GcpCredentialsPath`) uses:

```yaml
credentials:
  gcpConfig:
    type: gcp_credential_path
    path: /opt/secrets/gcp-sa.json
    projectId:
      - mdi-governance
```

The discriminator value is `gcp_credential_path` (not `service_account`),
the field is `path` (not `credentialsPath`), and `projectId` accepts either
a single string or a list. Verified by reading
`metadata.generated.schema.security.credentials.gcpCredentials` inside the
ingestion image. The OM docs site is out of sync with the code.

## Permissions: what the SA has now

The `mdi-governance` SA in this repo
(`svc-dgt-datacatalog-prod@mdi-governance.iam.gserviceaccount.com`) has roughly
BigQuery Data Viewer scope. Mandatory connection-test steps all pass:

```
CheckAccess         passed
GetSchemas          passed
GetTables           passed
GetViews            passed
GetColumnMetadata   passed
GetTableComments    passed
```

Optional steps fail — and OM logs *exactly* the missing permission:

```
GetTags         403 - Cloud Data Catalog API has not been used in project
                      mdi-governance ... Enable it by visiting <link>
GetQueries      403 - Access Denied: Table mdi-governance:region-us
                      .INFORMATION_SCHEMA.JOBS_BY_PROJECT
```

Because they're optional, the metadata ingestion workflow still runs to
completion — 13 tables in the `etep` dataset land successfully.

## What works on the current SA

| Workflow | Status | Notes |
|----------|--------|-------|
| `bq-ingest` (metadata) | ✓ 100% | 13 tables ingested. |
| `bq-profile` (column stats) | ✓ 100% | Column + DML profile metrics both persist. |
| `bq-classify` (sample data + PII tags) | ✓ 100% | Sampler + Auto Classification both 0 errors. Real PII detected: `ny_w2_extract.ssn` → `PII.Sensitive`, `first_name`/`last_name` → `PII.Sensitive`, `mailing_address_state` / `date_of_birth` → `PII.NonSensitive`. |
| `bq-lineage` (table-to-table from JOBS) | ✓ 100% | Auto-extracts CTAS / INSERT / MERGE / CALL lineage from `INFORMATION_SCHEMA.JOBS_BY_PROJECT`. 30-day lookback. |

## Required IAM on the SA (already granted on `mdi-governance`)

```bash
SA=svc-dgt-datacatalog-prod@mdi-governance.iam.gserviceaccount.com

gcloud projects add-iam-policy-binding mdi-governance \
    --member="serviceAccount:$SA" --role="roles/bigquery.dataViewer"
gcloud projects add-iam-policy-binding mdi-governance \
    --member="serviceAccount:$SA" --role="roles/bigquery.jobUser"
gcloud projects add-iam-policy-binding mdi-governance \
    --member="serviceAccount:$SA" --role="roles/bigquery.metadataViewer"
gcloud projects add-iam-policy-binding mdi-governance \
    --member="serviceAccount:$SA" --role="roles/bigquery.resourceAdmin"
gcloud projects add-iam-policy-binding mdi-governance \
    --member="serviceAccount:$SA" --role="roles/storage.objectViewer"
gcloud projects add-iam-policy-binding mdi-governance \
    --member="serviceAccount:$SA" --role="roles/storage.bucketViewer"
```

`roles/bigquery.resourceAdmin` is what specifically grants
`bigquery.jobs.listAll` — the permission that lets the lineage worker
read `INFORMATION_SCHEMA.JOBS_BY_PROJECT`. Without it, the lineage
workflow exits 1 with a 75% partial — confirmed empirically before
the grant landed (see git history for `bigquery_lineage.yaml`).

### Optional — to surface BigQuery policy tags inside OM

Not enabled in this project; OM logs a non-blocking warning during the
metadata workflow's connection test:

```bash
gcloud services enable datacatalog.googleapis.com --project=mdi-governance
gcloud projects add-iam-policy-binding mdi-governance \
    --member="serviceAccount:$SA" --role="roles/datacatalog.viewer"
```

Skippable. We use OM's own Auto Classification engine for PII tagging,
which doesn't need Data Catalog.

## GCS bridge — getting upstream lineage on EXTERNAL tables without IAM changes

The 8 `etep_box_*` tables in the `etep` dataset are `EXTERNAL`: each one
federates to a glob of CSV files under `gs://etep/dataflow_v1/`. OM's
BigQuery connector does not auto-create lineage from external table source
URIs, so without intervention these tables show no upstream — even though
the upstream is plainly stated in `external_data_configuration.source_uris`.

DGT-next plugs that gap with a deliberate two-step bridge:

1. **`make gcs-ingest`** — registers the `etep` GCS bucket as an OM
   Storage Service (`dgt-gcs`) using `openmetadata/gcs_storage_ingestion.yaml`.
   The connector type is `gcs`; auth re-uses the same SA mounted at
   `/opt/secrets/gcp-sa.json`. Required IAM is roughly
   `roles/storage.objectViewer` on the bucket — which the SA already has,
   so this works out of the box. The result is one `Container` entity:
   `dgt-gcs.etep`.

2. **`make link-bq-gcs`** — runs `scripts/link_bq_to_gcs.py` (via the
   `link_bq_to_gcs.sh` host wrapper or the `dgt_gcs_ingestion` DAG). The
   script lists every `EXTERNAL` table in `mdi-governance.etep` via the
   BigQuery client, then `PUT`s an `/api/v1/lineage` edge from the GCS
   container to each table. Idempotent — re-runs are safe.

After both steps, opening any `etep_box_*` table in the OM UI and clicking
the Lineage tab shows the GCS container as its upstream. The same
`bash scripts/link_bq_to_gcs.sh` pattern generalizes to any other dataset
with EXTERNAL tables — bump `BQ_PROJECT` / `BQ_DATASET` / `GCS_BUCKET` env
vars, point at a different bucket, re-run.

The `dgt_gcs_ingestion` Airflow DAG sequences both steps as a chained DAG
(`ingest_gcs >> link_bq_to_gcs`), paused on creation. Re-running the DAG
keeps lineage fresh as new EXTERNAL tables are added.

### Caveats

- **Container fidelity is per-bucket, not per-file.** A single
  `dgt-gcs.etep` container represents the whole bucket. If you need
  per-file lineage (e.g., `etep_box_3.csv` vs `etep_box_3_dictionary.csv`),
  drop an `openmetadata.json` manifest in the bucket per OM's storage
  manifest spec — child containers per directory will materialize on the
  next ingest.
- **Native (non-EXTERNAL) tables aren't touched.** The script intentionally
  only links tables with `table_type == 'EXTERNAL'`, so it can't fabricate
  lineage on `dmv`, `dol_wages`, etc. Real lineage on those still requires
  the IAM grant + an actual transform query.
- **The bridge is one-way.** The lineage edge is `Container → Table`.
  OM's UI walks both directions, so you'll see "this BQ table comes from
  the etep bucket" and "this etep bucket feeds these BQ tables".

## Lineage idempotency gotcha — manually-posted edges block workflow refresh

OpenMetadata's lineage upsert is keyed on `(fromEntityId, toEntityId)`.
If you `PUT /api/v1/lineage` for an edge that already exists, OM
**does not** overwrite the existing `lineageDetails`. Two consequences
worth knowing:

1. **A manually-posted bare edge is sticky.** If you bridge an edge by
   POSTing only `{fromEntity, toEntity}` (as the now-retired
   `link_bq_native_lineage.py` did), OM stores the edge with empty
   `lineageDetails`. When the standard lineage workflow later runs and
   tries to re-emit the same edge with full `sqlQuery` and `columnsLineage`,
   the new payload is ignored — the empty record wins.

2. **Deleting the stale edge and re-running the workflow doesn't fix
   it either.** OM caches processed queries by hash; once a CTAS has been
   ingested for a given run, subsequent runs of the same workflow won't
   re-process it. The deleted edge stays gone until the cache window
   rolls or the query re-runs in BigQuery.

The reliable repair when you find a stale bare edge:

```bash
# 1. Recover the SQL for the missing edge from BigQuery directly
SQL=$(bq query --use_legacy_sql=false --format=prettyjson "
  SELECT query FROM \`mdi-governance.region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT\`
  WHERE destination_table.table_id = 'bq_etep_box_4'
    AND statement_type = 'CREATE_TABLE_AS_SELECT'
  ORDER BY creation_time DESC LIMIT 1
" | python3 -c "import json,sys;print(json.dumps(json.load(sys.stdin)[0]['query']))")

# 2. PUT the edge again, this time including lineageDetails
curl -X PUT http://localhost:8585/api/v1/lineage \
    -H "Authorization: Bearer $OM_JWT_TOKEN" -H "Content-Type: application/json" \
    -d "{\"edge\": {\"fromEntity\": {\"id\": \"<from-uuid>\", \"type\": \"table\"},
                    \"toEntity\":   {\"id\": \"<to-uuid>\",   \"type\": \"table\"},
                    \"lineageDetails\": {\"source\": \"QueryLineage\", \"sqlQuery\": $SQL}}}"
```

We hit this exactly once, with the `bq_etep_box_3 → bq_etep_box_4` edge that
the bridge script created on 2026-05-26 before the IAM grant landed. The
workflow on 2026-05-29 emitted that edge again with full details, but the
manual record blocked the refresh. The PUT above patched it.

**Practical rule:** if you're ever manually bridging lineage as a stopgap,
include `lineageDetails.sqlQuery` from the start — even if you have to fetch
the SQL by another path. Don't post bare edges thinking the workflow will
fill them in later. It won't.

## File reference

- `secrets/gcp-sa.json` — credential, gitignored.
- `openmetadata/bigquery_ingestion.yaml` — metadata workflow.
- `openmetadata/bigquery_profiler.yaml` — profiler workflow.
- `openmetadata/bigquery_classification.yaml` — Auto Classification workflow.
- `openmetadata/bigquery_lineage.yaml` — lineage workflow (active; 30-day lookback).
- `openmetadata/gcs_storage_ingestion.yaml` — GCS bucket ingestion.
- `scripts/link_bq_to_gcs.py` — emits Container → Table lineage edges for EXTERNAL tables that the BigQuery connector doesn't link itself.
- `scripts/link_bq_to_gcs.sh` — host wrapper around the python script.
- `airflow/dags/dgt_bigquery_ingestion.py` — Airflow DAG, paused on creation.
- `airflow/dags/dgt_bigquery_profiler.py`
- `airflow/dags/dgt_bigquery_classification.py`
- `airflow/dags/dgt_gcs_ingestion.py` — chains GCS ingestion + the link step.
- `docker-compose.override.yml` — adds `./secrets:/opt/secrets:ro` and `./scripts:/opt/dgt/scripts:ro`.
