# DGT-next

A reset of the Data Governance Transformation (DGT) demo. Builds on lessons from the prior attempt in `/data/DGT`.

**Goals**
- Intuitive metadata visualization via the OpenMetadata UI.
- Connectors to a local Postgres governance catalog and to BigQuery.
- Working ingestion: schemas, lineage, profiling, sample data.
- A DCAT 3-aligned governance schema (mockup MVP, evolved with policy stakeholders later).

**Non-goals (for the MVP)**
- SSO / OAuth (designed to be flexible; basic auth for now).
- Cloud Run deployment (OM is stateful and unfit for Cloud Run; see `docs/architecture.md`).
- Production-grade secrets handling.

---

## Quick start

```bash
cp .env.example .env       # then optionally edit
make up                    # brings the entire stack up
```

Wait ~2-3 minutes on first start (image pulls + OM migration). Then:

| Service        | URL                       | Credentials                                |
| -------------- | ------------------------- | ------------------------------------------ |
| OpenMetadata   | http://localhost:8585     | `admin@open-metadata.org` / `admin`        |
| Airflow        | http://localhost:8080     | `admin` / `admin`                          |
| Governance PG  | `localhost:5433`          | `governance_admin` / `governance_admin`    |

Load the CLUE sample data:
```bash
make load-clue
```

## Run the metadata workflows

DGT-next ships **declarative YAML workflows** under `openmetadata/` — equivalent to
the legacy v1 `clue_ingestion.yaml` / `clue_profiler.yaml` / `clue_lineage.yaml`,
but with two key fixes:

1. **No hard-coded JWTs.** Every YAML uses `${OM_JWT_TOKEN}` and friends; the
   token is fetched from OM's API and written to `.env` automatically by
   `scripts/fetch_jwt.sh`. No more manual click-and-paste.
2. **Env vars piped through the ingestion container** so the same files work
   from `make` *and* from any future Airflow DAG that runs them.

```bash
make jwt        # one-time after `make up` — pulls ingestion-bot JWT into .env
make ingest     # registers the dgt-governance Postgres service + ingests dcat / gov / clue schemas
make profile    # runs profiler (column stats + sample data) on clue.*
make lineage    # extracts view + query-log lineage on clue.*
make workflows  # runs ingest → profile → lineage in sequence
```

> Don't have `make`? The Makefile is a thin wrapper. The raw equivalents are:
> ```bash
> ./scripts/fetch_jwt.sh
> docker compose -f compose/openmetadata.upstream.yml -f docker-compose.override.yml --project-directory . --env-file .env up -d --no-deps ingestion
> docker compose -f compose/openmetadata.upstream.yml -f docker-compose.override.yml --project-directory . --env-file .env exec ingestion metadata ingest   -c /opt/airflow/openmetadata/governance_ingestion.yaml
> docker compose -f compose/openmetadata.upstream.yml -f docker-compose.override.yml --project-directory . --env-file .env exec ingestion metadata profile  -c /opt/airflow/openmetadata/clue_profiler.yaml
> docker compose -f compose/openmetadata.upstream.yml -f docker-compose.override.yml --project-directory . --env-file .env exec ingestion metadata ingest   -c /opt/airflow/openmetadata/clue_lineage.yaml
> ```

Workflow YAMLs live in [`openmetadata/`](openmetadata/) and are mounted
read-only into the ingestion container. To add another connector (e.g.
BigQuery), drop a YAML in that dir and add a `make` target — no rebuild
needed.

### Manual UI fallback (click path)

If you'd rather configure things in the OM UI:
1. Browse to http://localhost:8585 → **Settings → Services → Databases → Add new service**.
2. Pick **Postgres**.
3. Connection details:
   - Host & port: `governance_pg:5432` (internal docker name — not the host-mapped 5433)
   - Username: `governance_admin`  •  Password: `governance_admin`  •  Database: `governance_catalog`
4. Hit **Test Connection** then **Save**.
5. On the new service page, click **Add Ingestion** and pick the workflow type
   (Metadata / Profiler / Lineage / Usage). Schedule or run on demand.

The YAML and UI paths are interchangeable — both call the same OM REST API.

## Architecture in one paragraph

`compose/openmetadata.upstream.yml` is OpenMetadata's official compose file, **vendored verbatim** at the version pinned in `.env` (`OM_VERSION`). We never edit it. `docker-compose.override.yml` adds a separate `governance_pg` Postgres for the DCAT-aligned governance catalog, isolated from OM's internal metadata DB. To roll OM versions: bump `OM_VERSION`, run `make fetch-compose`, `make down && make up`.

The CLUE dataset (a small Maryland court-records subset under `clue/`) is loaded on demand via `make load-clue`. CLUE is *not* part of the DCAT governance schema — it's a sample source dataset that OM ingests, and that we will eventually rewrite to validate the new stack's lineage extraction.

See [`docs/architecture.md`](docs/architecture.md) for the full picture and what this fixes from v1. Authoring SQL that needs to show up in the lineage graph? Read [`docs/lineage-sql-guidelines.md`](docs/lineage-sql-guidelines.md) first.

## Repo layout

```
.
├── compose/openmetadata.upstream.yml   # vendored OM compose (never edited)
├── docker-compose.override.yml         # our additions (governance_pg + ingestion mounts)
├── governance/init/                    # DCAT 3 schema + seed (auto-runs on init)
├── clue/                               # CLUE sample data + v1 SQL (loaded on demand)
├── openmetadata/                       # OM workflow YAMLs (env-var-templated)
│   ├── governance_ingestion.yaml       # metadata ingestion: dcat + gov + clue
│   ├── clue_profiler.yaml              # column profiles + sample data
│   └── clue_lineage.yaml               # view + query-log lineage
├── scripts/
│   ├── load_clue.sh                    # CLUE loader (run via `make load-clue`)
│   └── fetch_jwt.sh                    # auto-pulls ingestion-bot JWT into .env
├── docs/
│   ├── architecture.md                 # what we built and why
│   └── lineage-sql-guidelines.md       # how to write SQL that produces lineage
├── Makefile                            # operator entrypoint (`make help`)
└── .env.example
```

## Why the previous attempt fell over

Documented in `docs/architecture.md`. tl;dr: forked OM compose, manual JWT shuffling, single Postgres for everything, lineage strategy that fights the OM connector. We fix all four.
