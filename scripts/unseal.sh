#!/usr/bin/env bash
# Auto-unseal OpenBao after deploy using keys stored in crvouga.kv.
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://secret-store.chrisvouga.dev}"
UNSEAL_THRESHOLD="${UNSEAL_THRESHOLD:-3}"
UNSEAL_KEYS_ROW="${UNSEAL_KEYS_ROW:-secret-store/unseal-keys}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../cli/lib/vault-auth.sh
source "${REPO_ROOT}/cli/lib/vault-auth.sh"

if [ -z "${DB_CONNECTION_URI:-}" ]; then
  echo "ERROR: DB_CONNECTION_URI is required" >&2
  exit 1
fi

require_cmd psql "Install PostgreSQL client"
require_cmd curl "Install curl"
require_cmd jq "Install jq: https://jqlang.github.io/jq/"

if ! resolve_vault_bin; then
  echo "ERROR: vault CLI is required (https://openbao.org/docs/install/)" >&2
  exit 1
fi

export VAULT_ADDR

# OpenBao returns 503 on /sys/health when sealed; treat sealed/uninit as reachable.
HEALTH_URL="${VAULT_ADDR}/v1/sys/health?standbyok=true&sealedcode=200&uninitcode=200"

echo "==> Waiting for OpenBao at ${VAULT_ADDR}..."
for i in $(seq 1 60); do
  if curl -sf "${HEALTH_URL}" >/dev/null 2>&1; then
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "ERROR: OpenBao did not become reachable within 5 minutes" >&2
    exit 1
  fi
  sleep 5
done

SEALED="$(curl -sf "${VAULT_ADDR}/v1/sys/seal-status" | jq -r '.sealed // true')"
if [ "$SEALED" = "false" ]; then
  echo "==> OpenBao is already unsealed."
  exit 0
fi

echo "==> OpenBao is sealed. Fetching unseal keys from crvouga.kv..."
KEYS_JSON="$(psql "$DB_CONNECTION_URI" -t -A -q --no-psqlrc \
  -c "SELECT v::text FROM crvouga.kv WHERE k = '${UNSEAL_KEYS_ROW}'" \
  | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

if [ -z "$KEYS_JSON" ]; then
  echo "ERROR: No unseal keys found at crvouga.kv (k='${UNSEAL_KEYS_ROW}')" >&2
  echo "       Populate crvouga.kv with keys_base64, unseal_keys_b64, or key_1..key_N in v." >&2
  exit 1
fi

if ! echo "$KEYS_JSON" | jq -e . >/dev/null 2>&1; then
  echo "ERROR: Unseal keys at crvouga.kv (k='${UNSEAL_KEYS_ROW}') are not valid JSON" >&2
  exit 1
fi

extract_unseal_key() {
  local keys_json="$1"
  local index="$2"
  local idx=$((index - 1))
  local key

  key="$(echo "$keys_json" | jq -r --arg n "$index" '.["key_" + $n] // empty')"
  if [ -n "$key" ]; then
    printf '%s' "$key"
    return 0
  fi

  key="$(echo "$keys_json" | jq -r --argjson idx "$idx" '.unseal_keys_b64[$idx] // empty')"
  if [ -n "$key" ]; then
    printf '%s' "$key"
    return 0
  fi

  key="$(echo "$keys_json" | jq -r --argjson idx "$idx" '.keys_base64[$idx] // empty')"
  if [ -n "$key" ]; then
    printf '%s' "$key"
    return 0
  fi

  key="$(echo "$keys_json" | jq -r --argjson idx "$idx" '.keys[$idx] // empty')"
  if [ -n "$key" ]; then
    printf '%s' "$key"
    return 0
  fi

  return 1
}

echo "==> Applying ${UNSEAL_THRESHOLD} unseal key(s)..."
for i in $(seq 1 "$UNSEAL_THRESHOLD"); do
  KEY="$(extract_unseal_key "$KEYS_JSON" "$i" | tr -d '\n\r' || true)"
  if [ -z "$KEY" ]; then
    echo "ERROR: unseal key ${i} missing from crvouga.kv (UNSEAL_THRESHOLD=${UNSEAL_THRESHOLD})" >&2
    echo "       Expected keys_base64[], unseal_keys_b64[], or key_${i} in v." >&2
    exit 1
  fi
  echo "    Unseal key ${i}/${UNSEAL_THRESHOLD}..."
  vault_cmd operator unseal "$KEY" >/dev/null || true
done

SEALED="$(curl -sf "${VAULT_ADDR}/v1/sys/seal-status" | jq -r '.sealed // true')"
if [ "$SEALED" != "false" ]; then
  echo "ERROR: OpenBao is still sealed after applying ${UNSEAL_THRESHOLD} key(s)" >&2
  exit 1
fi

echo "==> OpenBao unsealed successfully."
