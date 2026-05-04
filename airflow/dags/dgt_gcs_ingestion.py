"""
DGT — GCS storage ingestion DAG

Two tasks, run in sequence:
  1. ingest_gcs        — `metadata ingest -c gcs_storage_ingestion.yaml`,
                          registers the dgt-gcs storage service and creates
                          a Container entity per bucket listed in
                          bucketNames (currently just `etep`).
  2. link_bq_to_gcs    — runs scripts/link_bq_to_gcs.sh, which reads each
                          BQ EXTERNAL table's source URIs and upserts a
                          lineage edge to the corresponding GCS container.

Why two tasks: OM 1.12.6's BigQuery connector doesn't auto-create lineage
from EXTERNAL table source URIs, so the link step is a deliberate bridge
between the two ingested services.

Auth: same SA at /opt/secrets/gcp-sa.json. Storage bucket needs at least
storage.buckets.get + storage.objects.list (Object Viewer).
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
    dag_id="dgt_gcs_ingestion",
    description="Ingest GCS bucket(s) and wire BigQuery EXTERNAL → GCS lineage",
    default_args=DEFAULT_ARGS,
    schedule="15 7 * * *",
    start_date=datetime(2026, 1, 1),
    catchup=False,
    is_paused_upon_creation=True,
    tags=["dgt", "openmetadata", "metadata", "gcs", "lineage"],
) as dag:

    ingest_gcs = BashOperator(
        task_id="ingest_gcs",
        bash_command=(
            "metadata ingest "
            "-c /opt/airflow/openmetadata/gcs_storage_ingestion.yaml"
        ),
    )

    # Direct python3 invocation avoids two issues with running the .sh
    # wrapper here: (a) Jinja in Airflow's BashOperator template-loads any
    # bash_command ending in .sh, emitting TemplateNotFound, and (b) the
    # wrapper uses `docker exec` which doesn't work from inside the
    # container itself. The python script is identical logic; the wrapper
    # is only for host-side invocation.
    link_bq_to_gcs = BashOperator(
        task_id="link_bq_to_gcs",
        bash_command="python3 /opt/dgt/scripts/link_bq_to_gcs.py ",  # trailing space stops Jinja rendering as a file path
    )

    ingest_gcs >> link_bq_to_gcs
