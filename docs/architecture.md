# DGT-next architecture

## Goals
1. **Stand the demo up reliably in one command**, with no manual JWT shuffling.
2. **Pin & roll OpenMetadata versions cleanly** — bump one variable, no merge conflicts against upstream.
3. **Decouple the governance schema** from OpenMetadata's internal metadata store.
4. **Get real lineage + profiling working** on at least one sample source (Postgres + BigQuery).
5. **DCAT 3 alignment** for the governance catalog, kept minimal until policy stakeholders refine it.

## Stack

```
┌─────────────────────────────────────────────────────────────────┐
│ docker-compose (compose/openmetadata.upstream.yml + override)   │
│                                                                 │
│  ┌────────────────────────────┐    ┌──────────────────────────┐ │
│  │ OpenMetadata (upstream)    │    │ DGT additions (overlay)  │ │
│  │  - postgresql (OM internal)│    │  - governance_pg         │ │
│  │  - elasticsearch           │    │    (DCAT schema + CLUE)  │ │
│  │  - openmetadata-server     │◄──►│                          │ │
│  │  - ingestion (Airflow)     │    │                          │ │
│  └────────────────────────────┘    └──────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

- **OpenMetadata 1.12.6** (pinned in `.env`). Image and compose come from the upstream release artifact, unmodified.
- **Two Postgres instances**, deliberately:
  - `openmetadata_postgresql` (host port `5432`) — OM's own metadata + Airflow DB. **Don't touch.**
  - `dgt_governance_pg` (host port `5433`) — the DCAT-aligned governance catalog and any user data sources we want OM to ingest.
- **Bundled Airflow** for ingestion DAGs.
- **Elasticsearch** for OM's search index.

## Why this fixes v1's pain points

| v1 pain point                                       | v1 cause                                                                     | DGT-next fix                                                                                    |
| --------------------------------------------------- | ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Hard to roll OM versions                            | `docker-compose.yml` was a hand-edited fork; bumping image tag drifted       | Upstream compose is vendored verbatim; overlay only adds; bump `OM_VERSION` + `make fetch-compose` |
| Manual JWT token regeneration on every demo         | YAML configs had embedded tokens, mounted into ingestion container          | Use the OM **UI workflow builder** — JWTs are server-managed, never written to disk             |
| Profiler refused to work                            | Same — stale tokens, brittle config mounts                                  | Same fix: workflows configured in the UI                                                         |
| Single Postgres mixed governance + OM internals     | One container with init scripts creating 3 databases                         | Two containers; governance schema can be evolved without risk to OM's metadata                  |
| Lineage missing for stored-procedure ETL            | OM's lineage parses `pg_stat_statements`; CALL bodies aren't in the log     | Two paths going forward: (1) write ETL as plain `INSERT INTO ... SELECT` queries that hit `pg_stat_statements`; (2) emit lineage explicitly via OM's Python SDK from an Airflow task. We'll validate (1) by rewriting CLUE. |

## Versioning model

```
.env                              ← pin OM_VERSION here
└── compose/openmetadata.upstream.yml   (re-fetched by `make fetch-compose`)
    + docker-compose.override.yml       (our additions, version-agnostic)
```

The override only adds new services and mounts; it never replaces or modifies upstream services. If a future OM version changes service names or networks, the override is small enough that the diff is obvious.

## Lineage strategy

OpenMetadata extracts Postgres lineage from three sources:

1. **View definitions.** OM parses `CREATE VIEW ... AS SELECT ...` directly. Works regardless of `pg_stat_statements`. This carries the 26 CLUE views.
2. **Query log** (`pg_stat_statements`). OM reads recent statements, parses each, and emits edges. Critical config: `shared_preload_libraries = pg_stat_statements`, `pg_stat_statements.track = all` (so nested statements from inside procedures are captured), and `CREATE EXTENSION pg_stat_statements;` *inside the database* (we install this in `governance/init/00_dcat_schema.sql`).
3. **Stored procedure body parsing.** *Not yet supported by OM 1.12.6 for Postgres* — the lineage worker logs `Processing Procedure Lineage not supported for Postgres` and skips. Tracked upstream; expected to land in a later release.

### What this means in practice

The CLUE ETL was rewritten as a stored procedure (`clue.run_etl()`) plus explicit `INSERT INTO target (col_list) SELECT (col_list) FROM source` statements. Even though OM can't parse the procedure body itself, with `track=all` the inner INSERTs land in `pg_stat_statements` *as separate entries*, so the query-log parser sees them and emits the lineage edges.

Net result on the CLUE schema after re-running `lineage`:

| Table | upstream edges | downstream edges | source of edges |
| ----- | -------------- | ---------------- | --------------- |
| `case_types`        | 0 | 1 | (loaded via COPY — no upstream) |
| `source_data`       | 1 | 2 | the WITH/INSERT load pattern + downstream views |
| `cases`             | 1 | 2 | `INSERT INTO clue.cases (...) SELECT ... FROM clue.vw_all_cases` |
| `defendants`        | 2 | 0 | `vw_all_defendants` + FK join with `clue.cases` |
| `plaintiffs`        | 2 | 0 | same pattern |
| `vw_*` (26 views)   | 1+ | 1+ | view definition parsing |

For practical guidance on what SQL produces lineage and what doesn't, see
[`lineage-sql-guidelines.md`](lineage-sql-guidelines.md) — that's the
developer-facing companion to this section.

### What did *not* work

- **`SELECT INTO clue.final_*`** (v1's pattern). OM's query parser sometimes treats this as opaque; the v1 backup at `clue/sql/10_transforms.v1-views.sql.bak` is preserved for reference. Use `INSERT INTO ... SELECT ...` instead.
- **`CALL clue.run_etl()` alone, with no inner INSERTs visible.** Without `track=all` the procedure body is invisible to OM. With `track=all`, every nested INSERT becomes a separate `pg_stat_statements` row that the lineage parser handles.
- **Procedure-body lineage on Postgres in 1.12.6.** Won't help us in this version; revisit on the next OM upgrade.

## Future GCP migration

The user has named **Cloud Run** as the eventual target. Honest assessment:
- **Cloud Run is a poor host for OpenMetadata server.** It's a long-running, stateful JVM with WebSocket usage and on-disk caches. Cloud Run's request-scoped lifecycle, 60-min request limit, and ephemeral filesystem don't fit. Cloud Run also can't host Elasticsearch.
- **Reasonable GCP target:** GKE Autopilot for the OM stack (there's an upstream Helm chart) + Cloud SQL for Postgres + Cloud Memorystore (or self-hosted ES on GKE) for search. Cloud Run *can* host stateless adjacents — e.g., a future governance API or webhook receiver.
- **What we already do to ease that move:** OM internals stay vanilla (Helm-portable), and the governance Postgres is a single isolated service (one env-var swap to point at Cloud SQL).

## DCAT 3 alignment

`governance/init/00_dcat_schema.sql` instantiates the core DCAT 3 classes:

- `dcat.catalog`, `dcat.resource` (Dataset / DataService / DatasetSeries discriminator), `dcat.distribution`, `dcat.agent`, `dcat.concept`.
- Governance overlay (`gov.governance_role`, `gov.permissible_use`, `gov.security_marking`, …) sits on top, modeled after the **DGT Policy Draft v0.3** (RACI matrix + permissible use).
- Two consumption views (`dcat.vw_catalog_dataset`, `gov.vw_resource_governance`) flatten the model for OM ingestion. These are the "user-facing" surface; OM ingests both the views and the underlying tables.

The schema is intentionally a starter sketch — the policy team will refine entities, add controlled vocabularies, and tighten constraints in subsequent iterations.

## Things still TBD

- **BigQuery Database Service** wiring + service-account JSON loading (target: re-use `mdi-governance-8aaf6ac0af80.json` from v1; mount via secret rather than baking into image).
- **OM workflow scheduling** — workflows currently run on-demand via `make ingest|profile|lineage`. Wrapping them in an Airflow DAG that fires on a cron is a one-file follow-up.
- **Audit / decision-log API** — placeholder schema present, no API yet.
- **OM upgrade watch** — when stored-procedure lineage lands for Postgres, the explicit `INSERT INTO ... SELECT` pattern in `clue.run_etl()` becomes optional belt-and-suspenders.
