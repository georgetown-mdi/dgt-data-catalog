"""
DGT — CLUE auto-classification DAG

Calls `metadata classify -c /opt/airflow/openmetadata/clue_classification.yaml`
which:
  1. Stores sample rows for every CLUE table (Sample Data tab in OM UI).
  2. Runs OpenMetadata's Auto Classification engine — NER + regex on the
     stored samples — and tags columns with PII / sensitive classifications
     (e.g., PII.Sensitive, PII.NonSensitive).

Reference:
  https://docs.open-metadata.org/how-to-guides/data-governance/classification/auto

Run order: dgt_clue_ingestion -> dgt_clue_profiler -> dgt_clue_classification.
The profiler is *not* a hard prerequisite for classification (Auto
Classification reads its own samples), but in practice you want both.
"""

from datetime import datetime, timedelta

from airflow import DAG
from airflow.providers.standard.operators.bash import BashOperator

DEFAULT_ARGS = {
    "owner": "dgt-governance",
    "depends_on_past": False,
    "email_on_failure": False,
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

with DAG(
    dag_id="dgt_clue_classification",
    description="Auto-classify CLUE columns (PII tagging) and store samples",
    default_args=DEFAULT_ARGS,
    schedule="45 6 * * *",
    start_date=datetime(2026, 1, 1),
    catchup=False,
    is_paused_upon_creation=True,
    tags=["dgt", "openmetadata", "classification", "governance"],
) as dag:

    classify_clue = BashOperator(
        task_id="classify_clue",
        bash_command=(
            "metadata classify "
            "-c /opt/airflow/openmetadata/clue_classification.yaml"
        ),
    )
