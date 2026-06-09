#!/usr/bin/env bash
# firewall_rules.sh — lock down the GCE VM's public surface to just the
# Caddy reverse-proxy ports.
#
# Run this AFTER rotate_secrets.sh + bringing up Caddy. Replace the two
# placeholders with your actual values:
#   <VPC>           — the VPC network name
#   <ALLOWLIST>     — comma-separated CIDRs of the IPs that should reach us
#
# Existing allow rules for the old ports (5432/5433/8080/8585/9200/9300)
# should be deleted manually after these new rules are confirmed working.

set -euo pipefail

VPC="<VPC>"
ALLOWLIST="<ALLOWLIST>"      # e.g. "1.2.3.4/32,5.6.7.8/29"
INSTANCE_TAG="dgt-next"      # whatever VM tag you've been using

# Allow the Caddy ports from the allowlist only.
gcloud compute firewall-rules create dgt-caddy-allow \
    --network="$VPC" \
    --direction=INGRESS --action=ALLOW \
    --rules=tcp:8443,tcp:8444 \
    --source-ranges="$ALLOWLIST" \
    --target-tags="$INSTANCE_TAG" \
    --priority=1000

# Deny the previously-exposed internal ports from anywhere external.
# Higher-priority deny wins over any leftover allow.
gcloud compute firewall-rules create dgt-internal-deny \
    --network="$VPC" \
    --direction=INGRESS --action=DENY \
    --rules=tcp:5432,tcp:5433,tcp:8080,tcp:8585,tcp:8586,tcp:9200,tcp:9300 \
    --source-ranges=0.0.0.0/0 \
    --target-tags="$INSTANCE_TAG" \
    --priority=900

echo "Rules created. Verify with:"
echo "  gcloud compute firewall-rules list --filter='name~dgt-'"
echo ""
echo "Once you confirm http(s)://<vm-ip>:8443 works and the old ports are"
echo "blocked from external, delete any old per-port allow rules:"
echo "  gcloud compute firewall-rules list --filter='allowed.ports:(5432 OR 5433 OR 8080 OR 8585 OR 9200)'"
