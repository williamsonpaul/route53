#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") --app-prefix <prefix> --app-suffix <suffix> --domain <suffix> --proxy <url> [--ttl <seconds>] [--dry-run]"
  echo ""
  echo "  --app-prefix  First part of app name (e.g. my-app)"
  echo "  --app-suffix  Last part of app name (e.g. service)"
  echo "  --domain      Domain suffix (e.g. development.mydomain)"
  echo "  --proxy       HTTPS proxy URL (e.g. http://proxy.example.com:8080)"
  echo "  --ttl         DNS TTL in seconds (default: 15)"
  echo "  --dry-run     Print what would be done without making changes"
  echo ""
  echo "  Creates: my-app-0.service.development.mydomain -> <instance IP>"
  exit 1
}

# Defaults (can be overridden by env vars or flags)
APP_PREFIX="${APP_PREFIX:-}"
APP_SUFFIX="${APP_SUFFIX:-}"
DOMAIN_SUFFIX="${DOMAIN_SUFFIX:-}"
PROXY="${PROXY:-}"
TTL="${TTL:-15}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-prefix) APP_PREFIX="$2";    shift 2 ;;
    --app-suffix) APP_SUFFIX="$2";    shift 2 ;;
    --domain)     DOMAIN_SUFFIX="$2"; shift 2 ;;
    --proxy)      PROXY="$2";         shift 2 ;;
    --ttl)        TTL="$2";           shift 2 ;;
    --dry-run)    DRY_RUN=true;       shift ;;
    *)            echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -z "${APP_PREFIX}" ]]    && echo "ERROR: --app-prefix is required" >&2 && usage
[[ -z "${APP_SUFFIX}" ]]    && echo "ERROR: --app-suffix is required" >&2 && usage
[[ -z "${DOMAIN_SUFFIX}" ]] && echo "ERROR: --domain is required" >&2 && usage
[[ -z "${PROXY}" ]]         && echo "ERROR: --proxy is required" >&2 && usage

export HTTPS_PROXY="${PROXY}"

if [[ "${DRY_RUN}" == true ]]; then
  echo "*** DRY RUN — no changes will be made ***"
fi

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

# Map AZ suffix (a=0, b=1, c=2) to index
AZ_SUFFIX="${AZ: -1}"
case "${AZ_SUFFIX}" in
  a) AZ_INDEX=0 ;;
  b) AZ_INDEX=1 ;;
  c) AZ_INDEX=2 ;;
  *) echo "ERROR: Unexpected AZ suffix '${AZ_SUFFIX}' in AZ '${AZ}'" >&2; exit 1 ;;
esac

FQDN="${APP_PREFIX}-${AZ_INDEX}.${APP_SUFFIX}.${DOMAIN_SUFFIX}"

# Look up hosted zone ID by searching for the best-match zone for DOMAIN_SUFFIX
# Route 53 zone names are stored with a trailing dot
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='${DOMAIN_SUFFIX}.'].Id" \
  --output text | sed 's|/hostedzone/||')

if [[ -z "${HOSTED_ZONE_ID}" ]]; then
  echo "ERROR: No hosted zone found for '${DOMAIN_SUFFIX}'" >&2
  exit 1
fi

echo "AZ:          ${AZ}"
echo "AZ index:    ${AZ_INDEX}"
echo "IP:          ${INSTANCE_IP}"
echo "Hosted zone: ${HOSTED_ZONE_ID}"
echo "FQDN:        ${FQDN}"

# Check if record already exists with the correct IP
echo "Checking for existing record at ${FQDN}..."
EXISTING_RECORD=$(aws route53 list-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --query "ResourceRecordSets[?Name=='${FQDN}.' && Type=='A'] | [0]" \
  --output json)

EXISTING_IP=$(echo "${EXISTING_RECORD}" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['ResourceRecords'][0]['Value'] if r else '')" 2>/dev/null || true)

# Upsert the new record for this instance
UPSERT_BATCH=$(cat <<EOF
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

if [[ "${EXISTING_IP}" == "${INSTANCE_IP}" ]]; then
  echo "Record ${FQDN} -> ${INSTANCE_IP} already exists, skipping upsert."
elif [[ "${DRY_RUN}" == true ]]; then
  echo ""
  echo "Would run:"
  echo "  aws route53 change-resource-record-sets \\"
  echo "    --hosted-zone-id ${HOSTED_ZONE_ID} \\"
  echo "    --change-batch '${UPSERT_BATCH}'"
  echo ""
  echo "*** DRY RUN complete — no changes made ***"
  exit 0
else
  aws route53 change-resource-record-sets \
    --hosted-zone-id "${HOSTED_ZONE_ID}" \
    --change-batch "${UPSERT_BATCH}"
  echo "Route 53 record updated: ${FQDN} -> ${INSTANCE_IP}"
fi

# Check the DNS has propagated
echo "Checking the DNS has propagated..."
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
