# SQL guidelines for OpenMetadata lineage

Audience: anyone writing or reviewing SQL that should appear as a lineage edge
in the OpenMetadata UI — ETL authors, data stewards, schema reviewers.

OM's lineage worker uses `sqllineage` + `sqlfluff` under the hood. It can only
show what those parsers understand. The patterns below are what we have
**verified** on OpenMetadata 1.12.6 against Postgres in this repo.

---

## TL;DR

1. Use `INSERT INTO target (col_list) SELECT (col_list) FROM source`. Always with explicit column lists.
2. Use `CREATE VIEW` freely — view chains are parsed directly from DDL and need no extra config.
3. Avoid `SELECT INTO target FROM source` — the parser sometimes treats it as opaque.
4. Stored procedures are fine, but each transform inside the body must be its own explicit DML statement (the procedure body itself is **not** parsed for Postgres in 1.12.6).
5. After any new load, re-run the lineage workflow within the configured `queryLogDuration` window (default 7 days).

---

## How OM extracts Postgres lineage

Three independent sources, run together by `metadata ingest -c clue_lineage.yaml`:

| # | Source | Triggered by | Reliability |
|---|--------|--------------|-------------|
| 1 | View definitions (`pg_views`) | `processViewLineage: true` | Always works |
| 2 | Query log (`pg_stat_statements`) | `processQueryLineage: true` | Works *if* the extension is properly installed AND the query was issued within `queryLogDuration` days |
| 3 | Stored-procedure body parsing | `processStoredProcedureLineage: true` | **Not supported for Postgres in 1.12.6** — silently skipped |

If you want a table to have an upstream edge, the statement that populates it
must be parseable by source #1 or #2.

---

## Patterns that produce lineage

### Views — always

```sql
CREATE VIEW clue.vw_label_cases AS
SELECT
    s.id,
    s.case_number,
    ct.subtype AS category
FROM clue.source_data s
LEFT JOIN clue.case_types ct ON s.case_type = ct.case_type;
```

Result: `vw_label_cases` ← `source_data` AND `vw_label_cases` ← `case_types`,
column-level. No extension or activity required — OM reads the view DDL
straight out of the catalog.

Chained views (`v3 ← v2 ← v1 ← table`) work to arbitrary depth.

### `INSERT INTO target (cols) SELECT (cols) FROM source` — preferred for materializing

```sql
INSERT INTO clue.cases (
    row_id, case_number, caption, name, birth_date, role,
    court, case_type, file_date, case_status, court_system,
    create_date, update_date, court_location, versions, category
)
SELECT
    row_id, case_number, caption, name, birth_date, role,
    court, case_type, file_date, case_status, court_system,
    create_date, update_date, court_location, versions, category
FROM clue.vw_all_cases;
```

This is the **most reliable** pattern for materialized targets. Column-level
lineage renders correctly because both column lists are explicit.

### `INSERT INTO target SELECT FROM source JOIN ...`

Joins, subqueries, unions, CTEs — all fine. Every referenced source becomes an
upstream edge.

```sql
INSERT INTO clue.defendants (row_id, name, city, state, ...)
SELECT d.row_id, d.name, d.city, d.state, ...
FROM clue.vw_all_defendants d
INNER JOIN clue.cases c ON c.row_id = d.row_id;
```

Result: `defendants` has two upstream edges — `vw_all_defendants` AND `cases`.
The FK-enforcing JOIN is honest; OM correctly reports both sources.

### CTAS — `CREATE TABLE AS SELECT`

```sql
CREATE TABLE clue.cases_archive AS
SELECT * FROM clue.cases WHERE file_date < '2020-01-01';
```

Works at table level. For column-level lineage, prefer the
`CREATE TABLE ... ; INSERT INTO ... SELECT (cols) ...` pattern.

### CTEs (`WITH`)

```sql
WITH recent AS (
    SELECT * FROM clue.source_data WHERE filing_date > '2024-01-01'
)
INSERT INTO clue.cases_recent (row_id, case_number, ...)
SELECT id, case_number, ... FROM recent;
```

CTEs unwind fine — OM follows the chain back to `source_data`.

### `UPDATE ... FROM ...`

```sql
UPDATE clue.cases c
SET category = ct.subtype
FROM clue.case_types ct
WHERE c.case_type = ct.case_type;
```

Adds upstream edge `cases ← case_types`. Table-level only.

### `MERGE INTO ...` (Postgres 15+)

```sql
MERGE INTO clue.cases c
USING clue.cases_staging s ON c.row_id = s.row_id
WHEN MATCHED THEN UPDATE SET ...
WHEN NOT MATCHED THEN INSERT ...;
```

Recognized; produces `cases ← cases_staging`.

---

## Patterns that DO NOT produce lineage — avoid

### `SELECT INTO target FROM source`

```sql
-- DO NOT USE — v1 used this and final_* had no lineage
SELECT * INTO clue.final_cases FROM clue.vw_all_cases;
```

OM's Postgres parser treats this inconsistently. Sometimes it produces an edge,
sometimes it doesn't — and the failure mode is silent. Always replace with a
two-step pattern:

```sql
CREATE TABLE clue.final_cases (LIKE clue.vw_all_cases);
INSERT INTO clue.final_cases SELECT * FROM clue.vw_all_cases;
```

### `COPY` from a file

```sql
\COPY clue.source_data FROM '/data/allegany.csv' WITH (FORMAT csv, ...);
```

The file isn't an OpenMetadata entity, so no upstream edge can be drawn. The
loaded table will have *zero* upstream edges. This is correct behavior — to
represent file ingestion in lineage you'd need to model the file as a
`Container` entity (out of scope for the MVP).

### `CALL stored_proc()` alone

```sql
CALL clue.run_etl();
```

If `pg_stat_statements.track` is **not** `all`, only the `CALL` line is logged
and OM can't tell what tables it touched. With `track=all` (our default), the
inner statements *are* logged separately and OM picks them up — see "Stored
procedures done right" below.

### Dynamic / generated SQL

```sql
EXECUTE format('INSERT INTO %I.cases SELECT * FROM %I.source', schema, schema);
```

Opaque to the parser. Lineage will not appear. If you must use dynamic SQL,
emit lineage manually via OM's Python SDK in an Airflow task.

### Triggers

```sql
CREATE TRIGGER tr_audit AFTER INSERT ON cases
FOR EACH ROW EXECUTE FUNCTION audit.log_change();
```

The function body is invisible to OM. Audit / change-capture flows need to be
documented out-of-band (e.g., via OM's "Manual Lineage" UI or the SDK).

### Truncated queries

`pg_stat_statements` truncates very long queries. In our compose we set
`track_activity_query_size=4096` (default is 1024). If your INSERT runs to
multiple kilobytes (e.g., 50+ explicit columns or long literal CTEs), check
`SELECT length(query) FROM pg_stat_statements WHERE ...` to confirm the
statement isn't clipped. If it is, raise the setting or split the query.

---

## Column-level vs table-level

OpenMetadata renders **two** kinds of lineage:

- **Table-level** edges (the line connecting two boxes in the lineage graph).
- **Column-level** edges (when you click a column and see which upstream
  columns flow into it).

Rules of thumb:

| Pattern | Table-level | Column-level |
|---------|-------------|--------------|
| `INSERT INTO t (a,b) SELECT a,b FROM s` | yes | yes |
| `INSERT INTO t SELECT * FROM s`         | yes | partial — only if both schemas match exactly |
| `CREATE VIEW v AS SELECT a,b FROM s`    | yes | yes |
| `CREATE VIEW v AS SELECT * FROM s`      | yes | partial |
| `CREATE TABLE t AS SELECT a,b FROM s`   | yes | yes |
| `UPDATE t SET col = s.col FROM s ...`   | yes | no (limitation of the parser) |
| `MERGE INTO t USING s ...`              | yes | no |

**Always prefer explicit column lists** if column-level lineage matters to your
stakeholders.

---

## Stored procedures done right

Even though OM 1.12.6 doesn't parse procedure bodies for Postgres, procedures
are still useful — they package an ETL into a single named, callable unit. The
trick is to make sure every transformation inside the procedure is a separate,
explicit DML statement so that `pg_stat_statements` (with `track=all`) records
each one.

```sql
-- Good: each step is its own logged statement
CREATE OR REPLACE PROCEDURE clue.run_etl() LANGUAGE plpgsql AS $$
BEGIN
    TRUNCATE TABLE clue.cases CASCADE;

    INSERT INTO clue.cases (row_id, case_number, ...)
    SELECT row_id, case_number, ...
    FROM clue.vw_all_cases;

    INSERT INTO clue.defendants (row_id, name, ...)
    SELECT d.row_id, d.name, ...
    FROM clue.vw_all_defendants d
    INNER JOIN clue.cases c ON c.row_id = d.row_id;

    INSERT INTO clue.plaintiffs (row_id, name, ...)
    SELECT p.row_id, p.name, ...
    FROM clue.vw_all_plaintiffs p
    INNER JOIN clue.cases c ON c.row_id = p.row_id;
END;
$$;
```

```sql
-- Bad: the parser can't see anything inside this loop
CREATE OR REPLACE PROCEDURE clue.run_etl_dynamic() LANGUAGE plpgsql AS $$
DECLARE
    t text;
BEGIN
    FOR t IN SELECT name FROM clue.targets LOOP
        EXECUTE format('INSERT INTO %I SELECT * FROM source', t);
    END LOOP;
END;
$$;
```

If you must do dynamic things, drop them in their own non-lineage-bearing
"plumbing" procedure and keep the lineage-bearing transformations in static
SQL.

---

## Operational requirements (one-time setup)

These need to be true *before* lineage extraction will find anything. Most are
already configured in DGT-next; documenting here so you know what to check
when adding a new database.

### Postgres-side

| Setting | Where | Why |
|---------|-------|-----|
| `shared_preload_libraries=pg_stat_statements` | `command:` in compose, OR `postgresql.conf` | Loads the extension's library — required before `CREATE EXTENSION` works |
| `pg_stat_statements.track=all` | same | Records nested statements (the inner INSERTs of stored procedures) |
| `track_activity_query_size=4096` (or larger) | same | Prevents long DML from being truncated in the query text column |
| `CREATE EXTENSION pg_stat_statements;` | run inside each database | The extension must be **created in the database**, not just preloaded — this is the easiest step to forget |

### OpenMetadata-side

In your `*_lineage.yaml`:

```yaml
sourceConfig:
  config:
    type: DatabaseLineage
    queryLogDuration: 7         # days of pg_stat_statements history to scan
    parsingTimeoutLimit: 300    # seconds per query
    resultLimit: 1000           # max queries to process
    processQueryLineage: true
    processViewLineage: true
    processStoredProcedureLineage: true   # no-op for Postgres in 1.12.6
```

Bump `queryLogDuration` if your last load was >7 days ago. Bump `resultLimit`
if you have many ETL statements per refresh.

---

## Pre-merge checklist for new SQL

Use this when reviewing a PR that adds or changes ETL:

- [ ] Does every materialized destination have an explicit `INSERT INTO target (cols) SELECT (cols) FROM source ...` (or `CREATE VIEW`)? **No `SELECT INTO`.**
- [ ] Are column lists explicit on **both** sides of the INSERT?
- [ ] If wrapped in a stored procedure: is each transform a separate statement (no dynamic `EXECUTE`, no loops)?
- [ ] Does the source table / view exist as an OM entity? (If it's a CSV / external file, no upstream lineage will appear — that's expected.)
- [ ] Is the new schema covered by the `schemaFilterPattern` in the relevant `*_ingestion.yaml` and `*_lineage.yaml`?
- [ ] After the load runs, will `pg_stat_statements` still hold the queries when the lineage workflow next runs? (Within `queryLogDuration` days.)

---

## Debugging missing lineage

When a table has no upstream edge in the OM UI:

1. **Confirm the table is ingested.** Open the table in OM. If it's missing entirely, fix the metadata workflow's `schemaFilterPattern`, not the lineage workflow.

2. **Check `pg_stat_statements`** for the query:
   ```sql
   SELECT LEFT(query, 200), calls
   FROM pg_stat_statements
   WHERE query ILIKE '%your_target_table%'
   ORDER BY calls DESC LIMIT 5;
   ```
   - **Not there?** The query rolled out of the buffer (`pg_stat_statements.max` defaults to 5000) or never ran. Re-run the load and immediately re-run the lineage workflow.
   - **There but truncated?** Raise `track_activity_query_size`.
   - **There but uses `SELECT INTO` / dynamic SQL?** Rewrite per the patterns above.

3. **Re-run the lineage workflow** and check its log for warnings:
   ```bash
   make lineage 2>&1 | grep -iE "warn|fail|skip"
   ```

4. **Confirm the parser didn't time out** — if `parsingTimeoutLimit: 300` is too low for an enormous DDL, raise it.

5. **Last resort:** add a manual lineage edge via the OM REST API or UI (Lineage tab → "Add Edge"). Use this when the source isn't a relational table (files, Kafka topics, external services). Don't use it as a substitute for fixing parseable SQL.

---

## When to escalate to manual lineage

Some flows simply cannot be parsed. In those cases, emit lineage edges
explicitly via OM's Python SDK in the same Airflow task that runs the
transformation. This adds a maintenance burden — the edge is hand-written and
goes stale if the transformation changes — so reserve it for:

- File-to-table ingestion (CSV / Parquet → table) where the file source is
  modeled as an OM Container.
- Spark / Beam jobs whose SQL isn't visible to Postgres.
- Cross-system flows (Postgres → Kafka → BigQuery) where no single SQL parser
  sees the whole chain.
- Stored procedures with dynamic SQL that we can't refactor away.

Anything that *can* be expressed as parseable SQL should be expressed as
parseable SQL — the catalog stays fresh automatically that way.
