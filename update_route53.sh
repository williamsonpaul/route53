#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") --app-prefix <prefix> --app-suffix <suffix> --domain <suffix> --proxy <url> [--ttl <the record should not be updated seconds>]"
  echo ""
  echo "  --app-prefix  First part of app name (e.g. my-app)"
  echo "  --app-suffix  Last part of app name (e.g. service)"
  echo "  --domain      Domain suffix (e.g. development.mydomain)"
  echo "  --proxy       HTTPS proxy URL (e.g. http://proxy.example.com:8080)"
  echo "  --ttl         DNS TTL in seconds (default: 15)"
  exit 1
}

APP_PREFIX="${APP_PREFIX:-}" APP_SUFFIX="${APP_SUFFIX:-}" DOMAIN_SUFFIX="${DOMAIN_SUFFIX:-}"
PROXY="${PROXY:-}" TTL="${TTL:-15}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-prefix) APP_PREFIX="$2";    shift 2 ;;
    --app-suffix) APP_SUFFIX="$2";    shift 2 ;;
    --domain)     DOMAIN_SUFFIX="$2"; shift 2 ;;
    --proxy)      PROXY="$2";         shift 2 ;;
    --ttl)        TTL="$2";           shift 2 ;;
    *)            echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -z "${APP_PREFIX}" ]]    && echo "ERROR: --app-prefix is required" >&2 && usage
[[ -z "${APP_SUFFIX}" ]]    && echo "ERROR: --app-suffix is required" >&2 && usage
[[ -z "${DOMAIN_SUFFIX}" ]] && echo "ERROR: --domain is required" >&2 && usage
[[ -z "${PROXY}" ]]         && echo "ERROR: --proxy is required" >&2 && usage

export HTTPS_PROXY="${PROXY}"

# Fetch instance metadata via IMDSv2
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_IP=$(curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" "http://169.254.169.254/latest/meta-data/local-ipv4" | tr -d '[:space:]')
AZ=$(curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" "http://169.254.169.254/latest/meta-data/placement/availability-zone")
AZ_ID=$(curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" "http://169.254.169.254/latest/meta-data/placement/availability-zone-id")

case "${AZ_ID##*-az}" in
  1) AZ_INDEX=0 ;; 2) AZ_INDEX=1 ;; 3) AZ_INDEX=2 ;;
  *) echo "ERROR: Unexpected AZ ID '${AZ_ID}'" >&2; exit 1 ;;
esac

FQDN="${APP_PREFIX}-${AZ_INDEX}.${APP_SUFFIX}.${DOMAIN_SUFFIX}"

HOSTED_ZONE_ID=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='${DOMAIN_SUFFIX}.'].Id" \
  --output text | sed 's|/hostedzone/||')
[[ -z "${HOSTED_ZONE_ID}" ]] && echo "ERROR: No hosted zone found for '${DOMAIN_SUFFIX}'" >&2 && exit 1

echo "AZ: ${AZ} | AZ ID: ${AZ_ID} (index: ${AZ_INDEX}) | IP: ${INSTANCE_IP} | Zone: ${HOSTED_ZONE_ID} | FQDN: ${FQDN}"

EXISTING_IP=$(aws route53 list-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --query "ResourceRecordSets[?Name=='${FQDN}.' && Type=='A'].ResourceRecords[0].Value | [0]" \
  --output json | tr -d '"')
[[ "${EXISTING_IP}" == "null" ]] && EXISTING_IP=""

if [[ "${EXISTING_IP}" == "${INSTANCE_IP}" ]]; then
  echo "Record already correct, skipping upsert."
else
  TMPFILE=$(mktemp)
  trap "rm -f ${TMPFILE}" EXIT
  cat > "${TMPFILE}" <<EOF
{
  "Comment": "Upsert A record for ${FQDN}",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${FQDN}",
      "Type": "A",
      "TTL": ${TTL},
      "ResourceRecords": [{ "Value": "${INSTANCE_IP}" }]
    }
  }]
}
EOF
  CHANGE_INFO=$(aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" --change-batch "file://${TMPFILE}")
  echo "Record updated: ${FQDN} -> ${INSTANCE_IP}"
  echo "${CHANGE_INFO}"
fi

echo "Checking the DNS has propagated..."
ELAPSED=0
until [[ "$(dig +short "${FQDN}")" == "${INSTANCE_IP}" ]]; do
  [[ ${ELAPSED} -ge 600 ]] && echo "ERROR: Timed out waiting for ${FQDN} to resolve to ${INSTANCE_IP}" >&2 && exit 1
  echo "  Not yet resolved, retrying in 15s (${ELAPSED}s elapsed)..."
  sleep 15; ELAPSED=$(( ELAPSED + 15 ))
done
echo "DNS confirmed: ${FQDN} -> ${INSTANCE_IP}"
