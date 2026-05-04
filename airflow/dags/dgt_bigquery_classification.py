"""
DGT — BigQuery auto-classification DAG

Stores sample rows and runs OM's Auto Classification engine on the etep
dataset, tagging columns as PII.Sensitive / PII.NonSensitive based on
NER + regex over the samples.

Reference:
  https://docs.open-metadata.org/how-to-guides/data-governance/classification/auto

Auth: service-account JSON at /opt/secrets/gcp-sa.json. Storing samples
needs bigquery.tables.getData (Data Viewer covers this); BigQuery policy
tags are *not* pulled by this DAG — that needs the Data Catalog API
enabled and roles/datacatalog.viewer on the SA, which the current SA
does not have.
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
    dag_id="dgt_bigquery_classification",
    description="Auto-classify BigQuery (mdi-governance.etep) columns + store samples",
    default_args=DEFAULT_ARGS,
    schedule="45 7 * * *",
    start_date=datetime(2026, 1, 1),
    catchup=False,
    is_paused_upon_creation=True,
    tags=["dgt", "openmetadata", "classification", "governance", "bigquery"],
) as dag:

    classify_bigquery = BashOperator(
        task_id="classify_bigquery",
        bash_command=(
            "metadata classify "
            "-c /opt/airflow/openmetadata/bigquery_classification.yaml"
        ),
    )
