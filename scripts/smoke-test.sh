#!/usr/bin/env bash
set -euo pipefail

BAO_ADDR="${BAO_ADDR:-https://secret-store.chrisvouga.dev}"
SECRET_PATH="smoke-test/ping"
MOUNT_PATH="smoke-test"

if [ -z "${BAO_TOKEN:-}" ]; then
  echo "ERROR: BAO_TOKEN is required" >&2
  exit 1
fi

if ! command -v bao >/dev/null 2>&1; then
  echo "ERROR: bao CLI is required (https://openbao.org/docs/install/)" >&2
  exit 1
fi

export BAO_ADDR
export BAO_TOKEN

echo "==> Checking health at ${BAO_ADDR}/v1/sys/health..."
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "${BAO_ADDR}/v1/sys/health")"
if [ "$HTTP_CODE" != "200" ]; then
  echo "ERROR: Expected HTTP 200 from health check, got ${HTTP_CODE}" >&2
  echo "OpenBao may be sealed or uninitialized. Unseal before running smoke tests." >&2
  exit 1
fi
echo "Health check passed (HTTP 200)."

echo "==> Verifying authentication..."
if ! bao token lookup >/dev/null 2>&1; then
  echo "ERROR: BAO_TOKEN is invalid or expired" >&2
  exit 1
fi

echo "==> Ensuring KV v2 engine at ${MOUNT_PATH}/..."
if ! bao secrets list -format=json | jq -e --arg path "${MOUNT_PATH}/" 'has($path)' >/dev/null; then
  bao secrets enable -path="${MOUNT_PATH}" kv-v2
else
  echo "KV v2 already enabled at ${MOUNT_PATH}/"
fi

echo "==> Writing test secret..."
bao kv put "${SECRET_PATH}" value=pong

echo "==> Reading test secret back..."
VALUE="$(bao kv get -field=value "${SECRET_PATH}")"
if [ "$VALUE" != "pong" ]; then
  echo "ERROR: Expected value 'pong', got '${VALUE}'" >&2
  exit 1
fi

echo "==> Deleting test secret..."
bao kv metadata delete "${SECRET_PATH}"

echo "✓ smoke test passed"
