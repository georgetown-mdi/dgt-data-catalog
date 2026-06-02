#!/usr/bin/env python3
"""Apply column-level descriptions from the etep_box_*_dictionary tables to
the corresponding bq_etep_box_* tables in BigQuery.

This is a one-shot operation. The stewards' dictionary tables already hold
authoritative documentation per column (variable_name → description, plus
optional codes enumeration); BigQuery's ALTER COLUMN ... SET OPTIONS lets
us attach those as native column descriptions. Once attached, OpenMetadata's
next bq-ingest picks them up automatically (no manual entry in the OM UI).

Scope:
  - For each etep_box_N_dictionary in {3,4,5,6,7,9,10}, update
    mdi-governance.etep.bq_etep_box_N's columns.
  - etep_box_6b_dictionary is skipped because there is no bq_etep_box_6b
    (only the EXTERNAL etep_box_6b).
  - Table-level descriptions are left untouched — at least bq_etep_box_3
    already has a curated description in OM that we don't want to overwrite.

Run mode:
  python3 scripts/apply_etep_descriptions.py            # dry-run, prints SQL
  python3 scripts/apply_etep_descriptions.py --apply    # actually runs

Auth: uses your gcloud user creds. `roles/bigquery.dataEditor` on the
project is required (bigquery.tables.update). The SA does NOT have it;
the user kl1099@georgetown.edu does.
"""

import argparse
import json
import subprocess
import sys
from typing import List

PROJECT = "mdi-governance"
DATASET = "etep"
BOXES   = ["3", "4", "5", "6", "7", "9", "10"]   # which etep_box_N to process


def bq_query(sql: str, format_: str = "json") -> str:
    """Run a bq CLI query and return stdout. Errors are fatal."""
    cmd = [
        "bq", "query", "--use_legacy_sql=false",
        f"--format={format_}", "--quiet", "--max_rows=1000", sql,
    ]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if res.returncode != 0:
        sys.exit(f"bq query failed:\n  SQL: {sql[:200]}\n  stderr: {res.stderr.strip()}")
    return res.stdout


def fetch_dictionary(box: str) -> List[dict]:
    """Return [{variable_name, description, codes}, ...] for non-empty descriptions only."""
    sql = (
        f"SELECT variable_name, description, codes "
        f"FROM `{PROJECT}.{DATASET}.etep_box_{box}_dictionary` "
        f"WHERE description IS NOT NULL AND description != ''"
    )
    return json.loads(bq_query(sql))


def fetch_table_columns(table: str) -> set:
    """Return the set of column names actually present in PROJECT.DATASET.table."""
    sql = (
        f"SELECT column_name "
        f"FROM `{PROJECT}.{DATASET}.INFORMATION_SCHEMA.COLUMNS` "
        f"WHERE table_name = '{table}'"
    )
    return {row["column_name"] for row in json.loads(bq_query(sql))}


def compose_description(description: str, codes: str) -> str:
    """Glue description and codes together when both are present."""
    if codes:
        return f"{description}  (codes: {codes})"
    return description


def build_alter_sql(box: str) -> tuple:
    """Return (sql_or_None, matched_count, skipped_count) for one box.

    sql is a single ALTER TABLE with multiple ALTER COLUMN clauses, or None
    if there's nothing to apply.
    """
    table = f"bq_etep_box_{box}"
    rows  = fetch_dictionary(box)
    cols  = fetch_table_columns(table)

    matched_clauses: List[str] = []
    skipped: List[str] = []
    for r in rows:
        v = r["variable_name"]
        if v not in cols:
            skipped.append(v)
            continue
        desc = compose_description(r["description"], r.get("codes") or "")
        # json.dumps produces a string literal BigQuery accepts: double-quoted,
        # backslash-escaped quotes/newlines/specials.
        matched_clauses.append(
            f"  ALTER COLUMN `{v}` SET OPTIONS(description={json.dumps(desc)})"
        )

    if not matched_clauses:
        return None, 0, len(skipped)

    sql = (
        f"ALTER TABLE `{PROJECT}.{DATASET}.{table}`\n"
        + ",\n".join(matched_clauses)
        + ";"
    )
    return sql, len(matched_clauses), len(skipped)


def run_alter(sql: str) -> None:
    """Execute the ALTER. Fails loudly if BQ rejects it."""
    cmd = [
        "bq", "query", "--use_legacy_sql=false",
        "--quiet", "--max_rows=0", sql,
    ]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if res.returncode != 0:
        sys.exit(f"ALTER failed:\n  stderr: {res.stderr.strip()}\n  sql preview: {sql[:300]}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--apply", action="store_true",
        help="actually run the ALTER statements; default is dry-run",
    )
    args = parser.parse_args()

    total_applied = 0
    total_skipped = 0
    for box in BOXES:
        print(f"\n=== etep_box_{box}_dictionary → bq_etep_box_{box} ===")
        sql, n_match, n_skip = build_alter_sql(box)
        total_applied += n_match
        total_skipped += n_skip

        if sql is None:
            print(f"  nothing to apply (0 matched, {n_skip} skipped)")
            continue

        print(f"  {n_match} column(s) to update, {n_skip} skipped (not in target table)")
        if not args.apply:
            print("  --- SQL (dry-run; pass --apply to execute) ---")
            for line in sql.splitlines()[:6]:
                print(f"    {line}")
            if len(sql.splitlines()) > 6:
                print(f"    ... ({len(sql.splitlines()) - 6} more lines)")
        else:
            run_alter(sql)
            print(f"  applied.")

    mode = "applied" if args.apply else "would apply (dry-run)"
    print(f"\n{mode} {total_applied} description(s) across {len(BOXES)} table(s); "
          f"skipped {total_skipped} (variable_name not in the table).")
    if not args.apply:
        print("Re-run with --apply to commit. Then `make bq-ingest` so OM picks up the new descriptions.")


if __name__ == "__main__":
    main()
