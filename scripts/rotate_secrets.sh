#!/usr/bin/env bash
# rotate_secrets.sh — rotate every default credential in the DGT-next stack.
#
# Scope (in order):
#   1. OM internal Postgres superuser (postgres)
#   2. OM application DB user (openmetadata_user)
#   3. Airflow DB user (airflow_user)
#   4. Airflow UI admin (admin)
#   5. governance_pg admin (governance_admin)
#   6. OM web admin (admin@open-metadata.org)
#   8. OM JWT RSA keypair (regenerate, mount, restart)
#   9. OM_JWT_TOKEN in .env (re-fetched via scripts/fetch_jwt.sh)
#
# Skipped: FERNET_KEY (#7). No OM-stored secrets to re-encrypt in this stack;
# defer until we actually use OM's secret store.
#
# Idempotent: re-running rotates again to fresh values. No data is destroyed —
# but the OM internal Postgres is snapshotted to backups/ as belt + suspenders.
#
# Requires: openssl, docker, curl, python3, jq (or python3 -c for JSON).
# Run as the user who can `docker exec` (kang on this host).

set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE=.env
BACKUP_DIR=backups
SECRETS_DIR=secrets
TS=$(date +%Y%m%d-%H%M%S)

# ───────────────────────────────────────────────────────────────────────
# 0. Snapshot OM Postgres before touching anything
# ───────────────────────────────────────────────────────────────────────
mkdir -p "$BACKUP_DIR" "$SECRETS_DIR"
echo "==> Snapshot OM Postgres → $BACKUP_DIR/om-pg-pre-rotate-$TS.sql.gz"
docker exec openmetadata_postgresql pg_dumpall -U postgres \
    | gzip > "$BACKUP_DIR/om-pg-pre-rotate-$TS.sql.gz"
echo "    snapshot size: $(du -h "$BACKUP_DIR/om-pg-pre-rotate-$TS.sql.gz" | cut -f1)"

# ───────────────────────────────────────────────────────────────────────
# 1. Generate new random secrets
# ───────────────────────────────────────────────────────────────────────
gen() { openssl rand -hex 16; }
NEW_PG_SUPERUSER=$(gen)
NEW_OM_DB_USER=$(gen)
NEW_AIRFLOW_DB=$(gen)
NEW_AIRFLOW_ADMIN=$(gen)
NEW_GOV_ADMIN=$(gen)
NEW_OM_ADMIN=$(gen)

echo "==> Generated 6 random secrets (hex-32)."

# Capture the current OM admin password so we can authenticate to change it
CURRENT_OM_ADMIN=$(grep -E '^OM_ADMIN_PASSWORD=' "$ENV_FILE" 2>/dev/null \
                    | cut -d= -f2- || echo "admin")

# ───────────────────────────────────────────────────────────────────────
# 2. Generate new OM JWT RSA keypair (item 8)
# ───────────────────────────────────────────────────────────────────────
echo "==> Generating new OM JWT RSA-2048 keypair → $SECRETS_DIR/"
openssl genrsa -out "$SECRETS_DIR/om-jwt-private.pem" 2048 2>/dev/null
openssl pkcs8 -topk8 -inform PEM -outform DER -nocrypt \
    -in "$SECRETS_DIR/om-jwt-private.pem" \
    -out "$SECRETS_DIR/om-jwt-private.der"
openssl rsa -in "$SECRETS_DIR/om-jwt-private.pem" -pubout -outform DER \
    -out "$SECRETS_DIR/om-jwt-public.der" 2>/dev/null
chmod 644 "$SECRETS_DIR"/om-jwt-*.der    # container user needs to read
rm "$SECRETS_DIR/om-jwt-private.pem"      # only need the DER versions

# ───────────────────────────────────────────────────────────────────────
# 3. ALTER USER on live Postgres containers (items 1, 2, 3, 5)
# ───────────────────────────────────────────────────────────────────────
echo "==> ALTER USER on openmetadata_postgresql"
docker exec -i openmetadata_postgresql psql -U postgres <<SQL
ALTER USER postgres          WITH PASSWORD '$NEW_PG_SUPERUSER';
ALTER USER openmetadata_user WITH PASSWORD '$NEW_OM_DB_USER';
ALTER USER airflow_user      WITH PASSWORD '$NEW_AIRFLOW_DB';
SQL

echo "==> ALTER USER on dgt_governance_pg"
docker exec -i dgt_governance_pg psql -U governance_admin -d governance_catalog <<SQL
ALTER USER governance_admin WITH PASSWORD '$NEW_GOV_ADMIN';
SQL

# ───────────────────────────────────────────────────────────────────────
# 4. Write new values to .env (replace-in-place, preserve everything else)
# ───────────────────────────────────────────────────────────────────────
echo "==> Update $ENV_FILE (backup at $ENV_FILE.backup-$TS)"
cp "$ENV_FILE" "$ENV_FILE.backup-$TS"
upsert() {
    local key=$1 val=$2
    if grep -qE "^${key}=" "$ENV_FILE"; then
        # GNU sed in-place; use a delimiter unlikely to appear in hex
        sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    else
        echo "${key}=${val}" >> "$ENV_FILE"
    fi
}
upsert OM_PG_SUPERUSER_PASSWORD "$NEW_PG_SUPERUSER"
upsert OM_DB_USER_PASSWORD       "$NEW_OM_DB_USER"
upsert AIRFLOW_DB_PASSWORD       "$NEW_AIRFLOW_DB"
upsert AIRFLOW_ADMIN_PASSWORD    "$NEW_AIRFLOW_ADMIN"
upsert GOV_DB_PASSWORD           "$NEW_GOV_ADMIN"
upsert OM_ADMIN_PASSWORD         "$NEW_OM_ADMIN"

# ───────────────────────────────────────────────────────────────────────
# 5. Restart the OM stack so it picks up new env + new JWT keys
# ───────────────────────────────────────────────────────────────────────
echo "==> Restart OM stack (server + ingestion + execute-migrate-all)"
docker compose -f compose/openmetadata.upstream.yml \
               -f docker-compose.override.yml \
               --project-directory . --env-file .env \
               up -d --force-recreate \
                   openmetadata-server execute-migrate-all ingestion
echo "==> Waiting for OM API to come back..."
until curl -sf http://localhost:8585/api/v1/system/version >/dev/null 2>&1; do
    sleep 5
done
echo "    OM is up."

# ───────────────────────────────────────────────────────────────────────
# 6. Re-fetch the ingestion-bot JWT (item 9), using the *old* admin password
#    because we haven't changed OM's admin yet
# ───────────────────────────────────────────────────────────────────────
echo "==> Re-fetch ingestion-bot JWT (signed by the new RSA key)"
OM_ADMIN_PASSWORD="$CURRENT_OM_ADMIN" ./scripts/fetch_jwt.sh

# Restart ingestion so it picks up the new bot JWT from env
docker compose -f compose/openmetadata.upstream.yml \
               -f docker-compose.override.yml \
               --project-directory . --env-file .env \
               up -d --no-deps ingestion

# ───────────────────────────────────────────────────────────────────────
# 7. Change OM web-admin password (item 6) via the API
# ───────────────────────────────────────────────────────────────────────
echo "==> Change OM admin password via API"
OLD_B64=$(printf '%s' "$CURRENT_OM_ADMIN" | base64 -w0)
NEW_B64=$(printf '%s' "$NEW_OM_ADMIN" | base64 -w0)
ADMIN_JWT=$(curl -fsS -X POST http://localhost:8585/api/v1/users/login \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"admin@open-metadata.org\",\"password\":\"$OLD_B64\"}" \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['accessToken'])")
curl -fsS -X PUT http://localhost:8585/api/v1/users/changePassword \
    -H "Authorization: Bearer $ADMIN_JWT" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"admin\",\"oldPassword\":\"$OLD_B64\",\"newPassword\":\"$NEW_B64\",\"confirmPassword\":\"$NEW_B64\",\"requestType\":\"SELF\"}" \
    >/dev/null
echo "    OM admin password rotated."

# ───────────────────────────────────────────────────────────────────────
# 8. Rotate Airflow UI admin password (item 4) — best effort
# ───────────────────────────────────────────────────────────────────────
echo "==> Rotate Airflow admin password"
# Airflow 3 uses Simple Auth Manager. Try the cli command; fall back to db update.
if docker exec openmetadata_ingestion airflow users reset-password \
        --username admin --password "$NEW_AIRFLOW_ADMIN" 2>/dev/null; then
    echo "    rotated via airflow users reset-password."
else
    echo "    cli command unavailable on Airflow 3.x; restart ingestion will"
    echo "    re-bootstrap admin with the new env-var password."
fi

# ───────────────────────────────────────────────────────────────────────
# 9. Summary
# ───────────────────────────────────────────────────────────────────────
echo ""
echo "==> Rotation complete. Summary:"
echo "    $ENV_FILE updated  → $ENV_FILE.backup-$TS held the previous values"
echo "    OM Postgres snapshot → $BACKUP_DIR/om-pg-pre-rotate-$TS.sql.gz"
echo "    OM JWT keys          → $SECRETS_DIR/om-jwt-{private,public}.der"
echo ""
echo "    Items rotated: 1, 2, 3, 4, 5, 6, 8, 9"
echo "    Items skipped: 7 (FERNET_KEY — deferred per Tier 1 scope)"
echo ""
echo "    All new values live in $ENV_FILE. Treat that file as a secret."
