"""
DGT — CLUE profiler DAG

Calls `metadata profile -c /opt/airflow/openmetadata/clue_profiler.yaml`
which computes column statistics (rowCount, distinct, min/max, histograms)
on the CLUE schema. Run after dgt_clue_ingestion has registered the tables.

Sample data and PII tagging are *not* handled here; that's the
dgt_clue_classification DAG.
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
    dag_id="dgt_clue_profiler",
    description="Profile CLUE tables (column stats, distributions)",
    default_args=DEFAULT_ARGS,
    schedule="30 6 * * *",
    start_date=datetime(2026, 1, 1),
    catchup=False,
    is_paused_upon_creation=True,
    tags=["dgt", "openmetadata", "profiler"],
) as dag:

    profile_clue = BashOperator(
        task_id="profile_clue",
        bash_command=(
            "metadata profile "
            "-c /opt/airflow/openmetadata/clue_profiler.yaml"
        ),
    )
