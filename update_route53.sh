#!/usr/bin/env bash
set -euo pipefail

# Configuration
APP_NAME="${APP_NAME:-myapp}"
DOMAIN_SUFFIX="${DOMAIN_SUFFIX:-development.mydomain}"
TTL="${TTL:-60}"

# IMDSv2: get token
IMDS_TOKEN=$(curl -s -X PUT \
  "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# Fetch instance metadata
INSTANCE_IP=$(curl -s \
  -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
  "http://169.254.169.254/latest/meta-data/local-ipv4")

AZ=$(curl -s \
  -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
  "http://169.254.169.254/latest/meta-data/placement/availability-zone")

# Map AZ suffix (a=0, b=1, c=2, d=3, ...) to index
AZ_SUFFIX="${AZ: -1}"
AZ_INDEX=$(python3 -c "import string; print(string.ascii_lowercase.index('${AZ_SUFFIX}'))")

FQDN="${APP_NAME}-${AZ_INDEX}.${DOMAIN_SUFFIX}"

# Look up hosted zone ID by searching for the best-match zone for DOMAIN_SUFFIX
# Route 53 zone names are stored with a trailing dot
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='${DOMAIN_SUFFIX}.'].Id" \
  --output text | sed 's|/hostedzone/||')

if [[ -z "${HOSTED_ZONE_ID}" ]]; then
  echo "ERROR: No hosted zone found for '${DOMAIN_SUFFIX}'" >&2
  exit 1
fi

echo "AZ:         ${AZ}"
echo "AZ index:   ${AZ_INDEX}"
echo "IP:         ${INSTANCE_IP}"
echo "Hosted zone: ${HOSTED_ZONE_ID}"
echo "FQDN:        ${FQDN}"

# Build Route 53 change batch
CHANGE_BATCH=$(cat <<EOF
{
  "Comment": "Upsert A record for ${FQDN}",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${FQDN}",
        "Type": "A",
        "TTL": ${TTL},
        "ResourceRecords": [
          { "Value": "${INSTANCE_IP}" }
        ]
      }
    }
  ]
}
EOF
)

aws route53 change-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --change-batch "${CHANGE_BATCH}"

echo "Route 53 record updated: ${FQDN} -> ${INSTANCE_IP}"

# Wait for the record to be resolvable, timeout after 10 minutes
echo "Waiting for DNS record to propagate..."
TIMEOUT=600
INTERVAL=15
ELAPSED=0

until [[ "$(dig +short "${FQDN}")" == "${INSTANCE_IP}" ]]; do
  if [[ ${ELAPSED} -ge ${TIMEOUT} ]]; then
    echo "ERROR: Timed out after ${TIMEOUT}s waiting for ${FQDN} to resolve to ${INSTANCE_IP}" >&2
    exit 1
  fi
  echo "  ${FQDN} not yet resolving to ${INSTANCE_IP}, retrying in ${INTERVAL}s (${ELAPSED}s elapsed)..."
  sleep "${INTERVAL}"
  ELAPSED=$(( ELAPSED + INTERVAL ))
done

echo "DNS confirmed: ${FQDN} -> ${INSTANCE_IP}"
