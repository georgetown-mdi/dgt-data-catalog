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
- `airflow/dags/dgt_bigquery_ingestion.py` — Airflow DAG, paused on creation.
- `airflow/dags/dgt_bigquery_profiler.py`
- `airflow/dags/dgt_bigquery_classification.py`
- `docker-compose.override.yml` — adds the `./secrets:/opt/secrets:ro` mount.
