#!/usr/bin/env bash
set -euo pipefail

BAO_ADDR="${BAO_ADDR:-https://secret-store.chrisvouga.dev}"
INIT_OUTPUT="${INIT_OUTPUT:-init-output.json}"
KEY_SHARES=5
KEY_THRESHOLD=3

if [ -z "${DB_CONNECTION_URI:-}" ]; then
  echo "ERROR: DB_CONNECTION_URI is required" >&2
  exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "ERROR: psql is required (install PostgreSQL client)" >&2
  exit 1
fi

if ! command -v bao >/dev/null 2>&1; then
  echo "ERROR: bao CLI is required (https://openbao.org/docs/install/)" >&2
  exit 1
fi

export BAO_ADDR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Running database migrations..."
"${SCRIPT_DIR}/migrate.sh"

echo "==> Waiting for OpenBao to become reachable at ${BAO_ADDR}..."
for i in $(seq 1 60); do
  if curl -sf "${BAO_ADDR}/v1/sys/health" >/dev/null 2>&1; then
    echo "OpenBao is reachable."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "ERROR: OpenBao did not become reachable within 5 minutes" >&2
    exit 1
  fi
  sleep 5
done

echo "==> Checking initialization status..."
INIT_STATUS="$(curl -sf "${BAO_ADDR}/v1/sys/init")"
if echo "$INIT_STATUS" | jq -e '.initialized == true' >/dev/null; then
  echo "OpenBao is already initialized. Skipping init."
  echo "If sealed, unseal manually with: bao operator unseal"
  exit 0
fi

echo "==> Initializing OpenBao (5 key shares, threshold 3)..."
INIT_JSON="$(bao operator init -key-shares="${KEY_SHARES}" -key-threshold="${KEY_THRESHOLD}" -format=json)"

printf '%s\n' "$INIT_JSON" > "$INIT_OUTPUT"
chmod 600 "$INIT_OUTPUT"

echo ""
echo "================================================================================"
echo "WARNING: SAVE THESE CREDENTIALS OFFLINE IMMEDIATELY"
echo "WARNING: Losing unseal keys or root token means losing ALL secrets permanently"
echo "================================================================================"
echo ""
echo "Init output saved to: ${INIT_OUTPUT}"
echo ""
echo "Unseal keys:"
printf '%s\n' "$INIT_JSON" | jq -r '.unseal_keys_b64[]' | nl -v 1 -w 2 -s '. '
echo ""
echo "Root token:"
printf '%s\n' "$INIT_JSON" | jq -r '.root_token'
echo ""
echo "================================================================================"

echo "==> Unsealing OpenBao with 3 of 5 keys..."
for i in 1 2 3; do
  KEY="$(printf '%s\n' "$INIT_JSON" | jq -r ".unseal_keys_b64[$((i - 1))]")"
  bao operator unseal "$KEY"
done

echo ""
echo "==> OpenBao is initialized and unsealed."
echo ""
echo "Root token (save this securely):"
printf '%s\n' "$INIT_JSON" | jq -r '.root_token'
echo ""
echo "Next steps:"
echo "  1. Store unseal keys and root token in a password manager or offline backup"
echo "  2. Add BAO_TOKEN to GitHub repository secrets for CI smoke tests"
echo "  3. Run: BAO_TOKEN=<root-token> ./scripts/smoke-test.sh"
