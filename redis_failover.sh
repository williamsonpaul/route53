#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") --auth <password> [--sentinel-master <name>] [--sentinel-port <port>] [--redis-port <port>] [--timeout <seconds>]"
  echo ""
  echo "  --auth             Redis/Sentinel password (required)"
  echo "  --sentinel-master  Sentinel master name (default: mymaster)"
  echo "  --sentinel-port    Sentinel port (default: 26379)"
  echo "  --redis-port       Redis port (default: 6379)"
  echo "  --timeout          Max seconds to wait for election (default: 60)"
  exit 1
}

AUTH="${AUTH:-}"
SENTINEL_MASTER="${SENTINEL_MASTER:-mymaster}"
SENTINEL_PORT="${SENTINEL_PORT:-26379}"
REDIS_PORT="${REDIS_PORT:-6379}"
TIMEOUT="${TIMEOUT:-60}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auth)            AUTH="$2";            shift 2 ;;
    --sentinel-master) SENTINEL_MASTER="$2"; shift 2 ;;
    --sentinel-port)   SENTINEL_PORT="$2";   shift 2 ;;
    --redis-port)      REDIS_PORT="$2";      shift 2 ;;
    --timeout)         TIMEOUT="$2";         shift 2 ;;
    *)                 echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -z "${AUTH}" ]] && echo "ERROR: --auth is required" >&2 && usage

redis_cmd()    { redis-cli -p "${REDIS_PORT}"    -a "${AUTH}" --no-auth-warning "$@"; }
sentinel_cmd() { redis-cli -p "${SENTINEL_PORT}" -a "${AUTH}" --no-auth-warning "$@"; }

# Check if this instance is the Redis master
ROLE=$(redis_cmd ROLE | head -1)
echo "Current Redis role: ${ROLE}"

if [[ "${ROLE}" != "master" ]]; then
  echo "This node is not the master, no failover needed."
  exit 0
fi

INSTANCE_IP=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" | \
  xargs -I{} curl -s -H "X-aws-ec2-metadata-token: {}" \
  "http://169.254.169.254/latest/meta-data/local-ipv4")

echo "This node (${INSTANCE_IP}) is the master — initiating Sentinel failover for '${SENTINEL_MASTER}'..."

sentinel_cmd SENTINEL failover "${SENTINEL_MASTER}"

# Wait for a new master to be elected
echo "Waiting for election to complete (timeout: ${TIMEOUT}s)..."
ELAPSED=0
INTERVAL=2

until [[ "${ELAPSED}" -ge "${TIMEOUT}" ]]; do
  NEW_MASTER=$(sentinel_cmd SENTINEL get-master-addr-by-name "${SENTINEL_MASTER}" | head -1)
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
