# DGT-next — operator entrypoint
#
# All commands compose the upstream OpenMetadata stack with our overlay.
# Edit OM_VERSION in .env to roll versions, then `make fetch-compose && make up`.

SHELL := /bin/bash
COMPOSE_FILES := -f compose/openmetadata.upstream.yml -f docker-compose.override.yml
# --project-directory pins relative paths to the repo root regardless of which
# compose file lists them first. Without it, docker resolves them against the
# directory of the first -f file (compose/), which breaks the bind mounts.
DC := docker compose $(COMPOSE_FILES) --project-directory . --env-file .env

# Load .env if present so $(OM_VERSION) etc. work in shell rules below.
ifneq (,$(wildcard ./.env))
include .env
export
endif

OM_VERSION ?= 1.12.6
GOV_DB_NAME ?= governance_catalog
GOV_DB_USER ?= governance_admin

.PHONY: help env up down restart logs ps fetch-compose seed-clue load-clue \
        psql-gov psql-om jwt ingest profile lineage classify workflows \
        bq-ingest bq-profile bq-classify bq-workflows \
        gcs-ingest link-bq-gcs gcs-workflows \
        airflow-dags clean clean-all

help: ## Show this help.
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

env: ## Initialize .env from .env.example if missing.
	@test -f .env || (cp .env.example .env && echo "Created .env — review and edit if needed.")

up: env ## Start the full stack (OM + governance Postgres) in the background.
	$(DC) up -d
	@echo "OpenMetadata UI:  http://localhost:8585  (admin@open-metadata.org / admin)"
	@echo "Airflow UI:       http://localhost:8080  (admin / admin)"
	@echo "Governance PG:    localhost:$${GOV_DB_HOST_PORT:-5433}  (db=$(GOV_DB_NAME), user=$(GOV_DB_USER))"

down: ## Stop the stack (preserves volumes).
	$(DC) down

restart: ## Restart all services.
	$(DC) restart

logs: ## Tail logs from all services.
	$(DC) logs -f --tail=100

ps: ## Show service status.
	$(DC) ps

fetch-compose: ## Re-vendor compose/openmetadata.upstream.yml at the version pinned in .env.
	@echo "Fetching OpenMetadata $(OM_VERSION) compose..."
	curl -fSL "https://github.com/open-metadata/OpenMetadata/releases/download/$(OM_VERSION)-release/docker-compose-postgres.yml" \
		-o compose/openmetadata.upstream.yml
	@echo "Vendored compose/openmetadata.upstream.yml at $(OM_VERSION)."

load-clue: ## Load the CLUE subset into governance_pg under the `clue` schema.
	./scripts/load_clue.sh

jwt: ## Fetch the ingestion-bot JWT from OM and write it into .env. Run once after `make up`.
	./scripts/fetch_jwt.sh
	$(DC) up -d --no-deps ingestion

ingest: ## Run the metadata ingestion workflow (DCAT + gov + clue schemas).
	$(DC) exec ingestion metadata ingest -c /opt/airflow/openmetadata/governance_ingestion.yaml

profile: ## Run the profiler workflow on the clue schema (column stats + sample data).
	$(DC) exec ingestion metadata profile -c /opt/airflow/openmetadata/clue_profiler.yaml

lineage: ## Run the lineage workflow (view + query log parsing) on the clue schema.
	$(DC) exec ingestion metadata ingest -c /opt/airflow/openmetadata/clue_lineage.yaml

classify: ## Run Auto Classification (sample data + PII tagging) on the clue schema.
	$(DC) exec ingestion metadata classify -c /opt/airflow/openmetadata/clue_classification.yaml

workflows: ingest profile lineage classify ## Run ingest → profile → lineage → classify in sequence.
	@echo "All workflows complete. Browse http://localhost:8585 → Explore → dgt-governance."

bq-ingest: ## Ingest BigQuery (mdi-governance.etep) metadata into OM.
	$(DC) exec ingestion metadata ingest -c /opt/airflow/openmetadata/bigquery_ingestion.yaml

bq-profile: ## Profile BigQuery tables (column stats; some metric queries need bigquery.jobs.list).
	$(DC) exec ingestion metadata profile -c /opt/airflow/openmetadata/bigquery_profiler.yaml

bq-classify: ## Auto Classification + sample data on BigQuery (PII tagging).
	$(DC) exec ingestion metadata classify -c /opt/airflow/openmetadata/bigquery_classification.yaml

bq-workflows: bq-ingest bq-profile bq-classify ## Full BigQuery chain. Lineage is intentionally skipped (see docs/bigquery-connector.md for IAM).
	@echo "BigQuery workflows complete. Browse http://localhost:8585 → Explore → dgt-bigquery."

gcs-ingest: ## Ingest the GCS etep bucket as an OM Storage Service container.
	$(DC) exec ingestion metadata ingest -c /opt/airflow/openmetadata/gcs_storage_ingestion.yaml

link-bq-gcs: ## Wire BigQuery EXTERNAL → GCS container lineage (idempotent).
	./scripts/link_bq_to_gcs.sh

gcs-workflows: gcs-ingest link-bq-gcs ## Ingest GCS, then bridge BQ→GCS lineage.
	@echo "GCS lineage wired. Browse http://localhost:8585 → Explore → dgt-bigquery → any etep_box_* table → Lineage."

airflow-dags: ## List the DAGs Airflow has registered (helpful when validating new DAG files).
	$(DC) exec ingestion airflow dags list

psql-gov: ## Open psql against the governance Postgres.
	$(DC) exec governance_pg psql -U $(GOV_DB_USER) -d $(GOV_DB_NAME)

psql-om: ## Open psql against OpenMetadata's internal Postgres (read-only inspection).
	$(DC) exec postgresql psql -U postgres -d openmetadata_db

clean: ## Stop & remove containers (preserves docker-volume/ on disk).
	$(DC) down

clean-all: ## Nuke everything including volumes. Destructive.
	$(DC) down -v
	rm -rf docker-volume/
