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
| `bq-profile` (column stats) | ~ partial | Column profiles persist (verified — `dmv` got 19 profile rows). The "DML statistics" sub-step that reads `INFORMATION_SCHEMA.JOBS` errors per-table; the workflow continues. |
| `bq-classify` (sample data + PII tags) | ✓ 100% | Sampler + Auto Classification both 0 errors. Real PII detected: `ny_w2_extract.ssn` → `PII.Sensitive`, `first_name`/`last_name` → `PII.Sensitive`, `mailing_address_state` / `date_of_birth` → `PII.NonSensitive`. |

## What does NOT work on the current SA

| Feature | Required IAM | Current state |
|---------|--------------|---------------|
| **Query-log lineage** (table-to-table from JOBS) | `bigquery.jobs.list` *and* `roles/bigquery.resourceViewer` (or membership of a role granting `SELECT` on the project's `INFORMATION_SCHEMA.JOBS_BY_PROJECT` view) | 403 on `region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT`. The `bigquery-lineage` source unconditionally queries this table, so the entire lineage workflow exits non-zero — even with `processQueryLineage: false`, which only suppresses *parsing* the result, not the *fetch*. |
| **BigQuery policy tags** (Data Catalog tags carried into OM) | `roles/datacatalog.viewer` *and* the Data Catalog API enabled on the project | 403 `SERVICE_DISABLED`. Optional; the workflow logs a warning and continues. |
| **Profile DML statistics** (insert/update/delete row counts) | Same as query-log lineage (reads `INFORMATION_SCHEMA.JOBS`) | Per-table errors during `bq-profile`. Column profiles still persist correctly; only the DML metric is missing. |

## Minimum IAM grant to unlock the full feature set

Have a project owner run, against `mdi-governance`:

```bash
SA=svc-dgt-datacatalog-prod@mdi-governance.iam.gserviceaccount.com

# Already needed for the basics — confirm it's there
gcloud projects add-iam-policy-binding mdi-governance \
    --member="serviceAccount:$SA" --role="roles/bigquery.dataViewer"

# To unlock query-log lineage and DML profiler statistics
gcloud projects add-iam-policy-binding mdi-governance \
    --member="serviceAccount:$SA" --role="roles/bigquery.jobUser"
gcloud projects add-iam-policy-binding mdi-governance \
    --member="serviceAccount:$SA" --role="roles/bigquery.resourceViewer"

# Optional — to surface BigQuery policy tags inside OM
gcloud services enable datacatalog.googleapis.com --project=mdi-governance
gcloud projects add-iam-policy-binding mdi-governance \
    --member="serviceAccount:$SA" --role="roles/datacatalog.viewer"
```

`roles/bigquery.user` is a superset that includes `jobUser` if you'd rather
collapse the grants.

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

## After IAM is granted

1. Drop a fresh credential JSON in `secrets/gcp-sa.json` if a new key was
   issued, then `chmod 644` (the container user is not the host user; 600
   triggers Permission denied).
2. Flip `bigquery_lineage.yaml` to `processQueryLineage: true` and add a
   `make bq-lineage` target (mirror of the CLUE one).
3. Re-run `make bq-workflows && make bq-lineage`.

## File reference

- `secrets/gcp-sa.json` — credential, gitignored.
- `openmetadata/bigquery_ingestion.yaml` — metadata workflow.
- `openmetadata/bigquery_profiler.yaml` — profiler workflow.
- `openmetadata/bigquery_classification.yaml` — Auto Classification workflow.
- `openmetadata/bigquery_lineage.yaml` — lineage workflow (currently skipped; see above).
- `openmetadata/gcs_storage_ingestion.yaml` — GCS bucket ingestion.
- `scripts/link_bq_to_gcs.py` — emits Container → Table lineage edges.
- `scripts/link_bq_to_gcs.sh` — host wrapper around the python script.
- `airflow/dags/dgt_bigquery_ingestion.py` — Airflow DAG, paused on creation.
- `airflow/dags/dgt_bigquery_profiler.py`
- `airflow/dags/dgt_bigquery_classification.py`
- `airflow/dags/dgt_gcs_ingestion.py` — chains GCS ingestion + the link step.
- `docker-compose.override.yml` — adds `./secrets:/opt/secrets:ro` and `./scripts:/opt/dgt/scripts:ro`.
