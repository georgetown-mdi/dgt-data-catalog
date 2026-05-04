#!/usr/bin/env bash
# Fetch the ingestion-bot JWT from the running OpenMetadata server and
# upsert it into .env as OM_JWT_TOKEN. Run once after `make up`.
#
# This replaces the v1 dance of manually copying the token from the OM UI.

set -euo pipefail

cd "$(dirname "$0")/.."

OM_URL=${OM_URL:-http://localhost:8585}
OM_ADMIN_EMAIL=${OM_ADMIN_EMAIL:-admin@open-metadata.org}
OM_ADMIN_PASSWORD=${OM_ADMIN_PASSWORD:-admin}

echo "==> Logging in as $OM_ADMIN_EMAIL"
ADMIN_TOKEN=$(curl -fsS -X POST "$OM_URL/api/v1/users/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$OM_ADMIN_EMAIL\",\"password\":\"$(printf '%s' "$OM_ADMIN_PASSWORD" | base64 -w0)\"}" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['accessToken'])")

echo "==> Looking up ingestion-bot user id"
BOT_USER_ID=$(curl -fsS -H "Authorization: Bearer $ADMIN_TOKEN" \
  "$OM_URL/api/v1/bots/name/ingestion-bot" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['botUser']['id'])")

echo "==> Fetching bot JWT"
JWT=$(curl -fsS -H "Authorization: Bearer $ADMIN_TOKEN" \
  "$OM_URL/api/v1/users/auth-mechanism/$BOT_USER_ID" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['config']['JWTToken'])")

echo "==> Writing OM_JWT_TOKEN to .env"
if grep -q '^OM_JWT_TOKEN=' .env 2>/dev/null; then
  # Replace in place. Use a delimiter that won't clash with JWT chars.
  python3 -c "
import re, pathlib
p = pathlib.Path('.env')
text = p.read_text()
text = re.sub(r'^OM_JWT_TOKEN=.*$', 'OM_JWT_TOKEN=$JWT', text, flags=re.M)
p.write_text(text)
"
else
  printf '\n# Auto-fetched by scripts/fetch_jwt.sh\nOM_JWT_TOKEN=%s\n' "$JWT" >> .env
fi

echo "OK — OM_JWT_TOKEN updated in .env (token starts ${JWT:0:24}...)"
echo "Restart the ingestion container so it picks up the new env: docker compose restart ingestion"
