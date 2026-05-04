"""
DGT — BigQuery metadata ingestion DAG

Calls `metadata ingest -c /opt/airflow/openmetadata/bigquery_ingestion.yaml`
which registers the dgt-bigquery service in OpenMetadata and ingests table /
view metadata for the mdi-governance.etep dataset.

Auth: the service-account JSON at /opt/secrets/gcp-sa.json (mounted via
the overlay). Required IAM minimum is roughly the BigQuery Data Viewer
role; see docs/architecture.md for the exact permission breakdown and
the optional roles needed for lineage and policy tags.
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
    dag_id="dgt_bigquery_ingestion",
    description="Ingest BigQuery (mdi-governance.etep) into OpenMetadata",
    default_args=DEFAULT_ARGS,
    schedule="0 7 * * *",
    start_date=datetime(2026, 1, 1),
    catchup=False,
    is_paused_upon_creation=True,
    tags=["dgt", "openmetadata", "metadata", "bigquery"],
) as dag:

    ingest_metadata = BashOperator(
        task_id="ingest_metadata",
        bash_command=(
            "metadata ingest "
            "-c /opt/airflow/openmetadata/bigquery_ingestion.yaml"
        ),
    )
