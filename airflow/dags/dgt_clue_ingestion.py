"""
DGT — CLUE metadata ingestion DAG

Calls `metadata ingest -c /opt/airflow/openmetadata/governance_ingestion.yaml`
which registers the dgt-governance Postgres service in OpenMetadata and ingests
table/view metadata for the dcat, gov, and clue schemas.

This DAG is paused by default. Trigger manually from the Airflow UI, or
unpause and the schedule below takes over.
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
    dag_id="dgt_clue_ingestion",
    description="Ingest dcat / gov / clue schemas into OpenMetadata",
    default_args=DEFAULT_ARGS,
    schedule="0 6 * * *",     # 06:00 UTC daily; ignored while DAG is paused
    start_date=datetime(2026, 1, 1),
    catchup=False,
    is_paused_upon_creation=True,
    tags=["dgt", "openmetadata", "metadata"],
) as dag:

    ingest_metadata = BashOperator(
        task_id="ingest_metadata",
        bash_command=(
            "metadata ingest "
            "-c /opt/airflow/openmetadata/governance_ingestion.yaml"
        ),
    )
