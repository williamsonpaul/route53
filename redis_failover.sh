#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") --redis-auth <password> --sentinel-auth <password> [--sentinel-port <port>] [--redis-port <port>] [--timeout <seconds>]"
  echo ""
  echo "  --redis-auth     Redis password (required)"
  echo "  --sentinel-auth  Sentinel password (required)"
  echo "  --sentinel-port  Sentinel port (default: 26379)"
  echo "  --redis-port     Redis port (default: 6379)"
  echo "  --timeout        Max seconds to wait for election (default: 60)"
  exit 1
}

REDIS_AUTH="${REDIS_AUTH:-}"
SENTINEL_AUTH="${SENTINEL_AUTH:-}"
SENTINEL_PORT="${SENTINEL_PORT:-26379}"
REDIS_PORT="${REDIS_PORT:-6379}"
TIMEOUT="${TIMEOUT:-60}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --redis-auth)    REDIS_AUTH="$2";    shift 2 ;;
    --sentinel-auth) SENTINEL_AUTH="$2"; shift 2 ;;
    --sentinel-port) SENTINEL_PORT="$2"; shift 2 ;;
    --redis-port)    REDIS_PORT="$2";    shift 2 ;;
    --timeout)       TIMEOUT="$2";       shift 2 ;;
    *)               echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -z "${REDIS_AUTH}" ]]    && echo "ERROR: --redis-auth is required" >&2 && usage
[[ -z "${SENTINEL_AUTH}" ]] && echo "ERROR: --sentinel-auth is required" >&2 && usage

redis_cmd()        { redis-cli -p "${REDIS_PORT}"    -a "${REDIS_AUTH}"    --no-auth-warning "$@"; }
sentinel_cmd()     { redis-cli -p "${SENTINEL_PORT}" -a "${SENTINEL_AUTH}" --no-auth-warning "$@"; }
sentinel_cmd_raw() { redis-cli -p "${SENTINEL_PORT}" -a "${SENTINEL_AUTH}" --no-auth-warning --raw "$@"; }

# Check if this instance is the Redis master
ROLE=$(redis_cmd ROLE | head -1)
echo "Current Redis role: ${ROLE}"

if [[ "${ROLE}" != "master" ]]; then
  echo "This node is not the master, no failover needed."
  exit 0
fi

# Fetch instance IP via IMDSv2
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_IP=$(curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" "http://169.254.169.254/latest/meta-data/local-ipv4" | tr -d '[:space:]')

# Discover which Sentinel master name this node is serving
# --raw outputs plain key/value lines; awk picks the value after each "name" key
SENTINEL_MASTER=""
while IFS= read -r name; do
  MASTER_IP=$(sentinel_cmd_raw SENTINEL get-master-addr-by-name "${name}" | head -1 | tr -d '[:space:]')
  if [[ "${MASTER_IP}" == "${INSTANCE_IP}" ]]; then
    SENTINEL_MASTER="${name}"
    break
  fi
done < <(sentinel_cmd_raw SENTINEL masters | awk '/^name$/{getline; print}')

if [[ -z "${SENTINEL_MASTER}" ]]; then
  echo "ERROR: Could not find a Sentinel master served by this node (${INSTANCE_IP})" >&2
  exit 1
fi

echo "This node (${INSTANCE_IP}) is master for '${SENTINEL_MASTER}' — initiating failover..."

sentinel_cmd SENTINEL failover "${SENTINEL_MASTER}"

# Wait for a new master to be elected
echo "Waiting for election to complete (timeout: ${TIMEOUT}s)..."
ELAPSED=0
INTERVAL=2

until [[ "${ELAPSED}" -ge "${TIMEOUT}" ]]; do
  NEW_MASTER=$(sentinel_cmd_raw SENTINEL get-master-addr-by-name "${SENTINEL_MASTER}" | head -1 | tr -d '[:space:]')
  if [[ -n "${NEW_MASTER}" && "${NEW_MASTER}" != "${INSTANCE_IP}" ]]; then
    echo "Election complete. New master: ${NEW_MASTER}"
    exit 0
  fi
  sleep "${INTERVAL}"
  ELAPSED=$(( ELAPSED + INTERVAL ))
  echo "  Waiting for new master... (${ELAPSED}s elapsed)"
done

echo "ERROR: Timed out after ${TIMEOUT}s waiting for new master to be elected" >&2
exit 1
