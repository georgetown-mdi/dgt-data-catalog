"""
DGT — BigQuery profiler DAG

Computes column statistics on the etep dataset. Requires bigquery.tables.getData
on the SA (already covered by Data Viewer) — billing for the profile queries
is on mdi-governance unless billingProjectId is set in the YAML.

Run after dgt_bigquery_ingestion.
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
    dag_id="dgt_bigquery_profiler",
    description="Profile BigQuery (mdi-governance.etep) tables",
    default_args=DEFAULT_ARGS,
    schedule="30 7 * * *",
    start_date=datetime(2026, 1, 1),
    catchup=False,
    is_paused_upon_creation=True,
    tags=["dgt", "openmetadata", "profiler", "bigquery"],
) as dag:

    profile_bigquery = BashOperator(
        task_id="profile_bigquery",
        bash_command=(
            "metadata profile "
            "-c /opt/airflow/openmetadata/bigquery_profiler.yaml"
        ),
    )
