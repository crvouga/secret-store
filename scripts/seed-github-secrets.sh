#!/usr/bin/env bash
set -euo pipefail

FLY_APP="secret-store-chrisvouga"
SKIP_FLY=false
SKIP_BAO=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
ENV_SECRETS_FILE="${REPO_ROOT}/.env.secrets"
INIT_OUTPUT_FILE="${REPO_ROOT}/init-output.json"

NEON_CMD=()
declare -a SECRET_SOURCES=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Fetch deploy pipeline secrets from authenticated CLIs and seed GitHub Actions
(and Fly) secrets. No manual entry required when logged in to each provider.

Options:
  --skip-fly   Only set GitHub secrets (skip fly secrets set)
  --skip-bao   Do not fetch or set BAO_TOKEN
  -h, --help   Show this help

Log in first:
  gh auth login
  fly auth login
  neonctl auth       # npm i -g neonctl  (or: npx neonctl auth)

Cloudflare requires a dashboard API token (Wrangler OAuth does not work):
  Create at https://dash.cloudflare.com/profile/api-tokens (Zone:DNS:Edit for chrisvouga.dev)
  export CLOUDFLARE_API_TOKEN='...'  or add to .env / .env.secrets

Optional overrides (env vars, ${ENV_FILE}, or ${ENV_SECRETS_FILE}):
  NEON_PROJECT_ID, FLY_API_TOKEN, CF_API_TOKEN, CLOUDFLARE_API_TOKEN,
  DB_CONNECTION_URI, BAO_TOKEN

Required GitHub secrets: FLY_API_TOKEN, CF_API_TOKEN, DB_CONNECTION_URI
Optional GitHub secret:  BAO_TOKEN (from init-output.json after init.sh)
EOF
}

record_source() {
  SECRET_SOURCES+=("$1")
}

require_cmd() {
  local cmd="$1"
  local install_hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: ${cmd} is required. ${install_hint}" >&2
    exit 1
  fi
}

resolve_neon_cmd() {
  if [ "${#NEON_CMD[@]}" -gt 0 ]; then
    return 0
  fi

  if command -v neon >/dev/null 2>&1; then
    NEON_CMD=(neon)
  elif command -v neonctl >/dev/null 2>&1; then
    NEON_CMD=(neonctl)
  elif command -v npx >/dev/null 2>&1; then
    echo "==> neonctl not installed globally; using npx neonctl"
    NEON_CMD=(npx --yes neonctl)
  else
    echo "ERROR: neon CLI not found. Install: npm i -g neonctl" >&2
    echo "       Or ensure npm/npx is available and run: npx neonctl auth" >&2
    exit 1
  fi
}

run_neon() {
  resolve_neon_cmd
  "${NEON_CMD[@]}" "$@"
}

resolve_neon_project_id() {
  if [ -n "${NEON_PROJECT_ID:-}" ]; then
    echo "$NEON_PROJECT_ID"
    return 0
  fi

  local projects_json project_count project_id
  projects_json="$(run_neon projects list --output json)"
  project_count="$(echo "$projects_json" | jq -r 'if type == "array" then length elif .projects then (.projects | length) else 0 end')"
  if [ "$project_count" -eq 1 ]; then
    project_id="$(echo "$projects_json" | jq -r 'if type == "array" then .[0].id else .projects[0].id end')"
    echo "$project_id"
    return 0
  fi

  if [ "$project_count" -gt 1 ]; then
    echo "ERROR: Multiple Neon projects found. Run 'neonctl set-context' or set NEON_PROJECT_ID." >&2
    exit 1
  fi

  echo "ERROR: No Neon projects found. Create a project in Neon or set NEON_PROJECT_ID." >&2
  exit 1
}

fetch_fly_api_token() {
  if [ -n "${FLY_API_TOKEN:-}" ]; then
    record_source "FLY_API_TOKEN (environment override)"
    return 0
  fi

  require_cmd flyctl "Install: https://fly.io/docs/hands-on/install-flyctl/"
  if ! flyctl auth whoami >/dev/null 2>&1; then
    echo "ERROR: flyctl is not authenticated. Run: fly auth login" >&2
    exit 1
  fi

  require_cmd jq "Install jq: https://jqlang.github.io/jq/"

  echo "==> Fetching FLY_API_TOKEN from fly tokens create deploy"
  local token_json
  token_json="$(flyctl tokens create deploy -a "$FLY_APP" --json 2>/dev/null || true)"
  FLY_API_TOKEN="$(echo "$token_json" | jq -r '.token // empty' 2>/dev/null || true)"

  if [ -n "$FLY_API_TOKEN" ]; then
    record_source "FLY_API_TOKEN (fly tokens create deploy)"
    return 0
  fi

  echo "==> Fly app '${FLY_APP}' not found; using fly session token (create the app for a scoped deploy token)"
  FLY_API_TOKEN="$(flyctl auth token 2>/dev/null || true)"
  if [ -z "$FLY_API_TOKEN" ]; then
    echo "ERROR: Could not obtain Fly API token. Run: fly auth login" >&2
    exit 1
  fi
  record_source "FLY_API_TOKEN (fly session token)"
}

fetch_cf_api_token() {
  if [ -n "${CF_API_TOKEN:-}" ]; then
    CF_API_TOKEN="$(printf '%s' "$CF_API_TOKEN" | tr -d '\n\r')"
    record_source "CF_API_TOKEN (environment override)"
    return 0
  fi

  if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
    CF_API_TOKEN="$(printf '%s' "$CLOUDFLARE_API_TOKEN" | tr -d '\n\r')"
    record_source "CF_API_TOKEN (CLOUDFLARE_API_TOKEN)"
    return 0
  fi

  echo "ERROR: Cloudflare API token required for DNS provisioning in CI." >&2
  echo "" >&2
  echo "Wrangler OAuth tokens cannot be used with the Cloudflare REST API." >&2
  echo "Create a token at: https://dash.cloudflare.com/profile/api-tokens" >&2
  echo "  Template: Edit zone DNS" >&2
  echo "  Zone: chrisvouga.dev" >&2
  echo "" >&2
  echo "Then either:" >&2
  echo "  export CLOUDFLARE_API_TOKEN='...' && ./scripts/seed-github-secrets.sh" >&2
  echo "  or add CLOUDFLARE_API_TOKEN=... to .env or .env.secrets" >&2
  exit 1
}

load_env_file() {
  local file="$1"
  if [ -f "$file" ]; then
    echo "==> Loading $(basename "$file")"
    set -a
    # shellcheck source=/dev/null
    source "$file"
    set +a
  fi
}

verify_cf_api_token() {
  local response http_code
  response="$(curl -sS -w "\n__HTTP_CODE__:%{http_code}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    "https://api.cloudflare.com/client/v4/user/tokens/verify")"
  http_code="${response##*__HTTP_CODE__:}"
  response="${response%__HTTP_CODE__:*}"

  if [ "$http_code" != "200" ]; then
    echo "ERROR: Cloudflare token verification failed (HTTP ${http_code})" >&2
    echo "$response" | jq . >&2 2>/dev/null || echo "$response" >&2
    exit 1
  fi

  if ! echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
    echo "ERROR: Cloudflare token is invalid or lacks required permissions" >&2
    echo "$response" | jq . >&2
    exit 1
  fi

  echo "==> Cloudflare API token verified"
}

fetch_db_connection_uri() {
  if [ -n "${DB_CONNECTION_URI:-}" ]; then
    record_source "DB_CONNECTION_URI (environment override)"
    return 0
  fi

  resolve_neon_cmd
  if ! run_neon me >/dev/null 2>&1; then
    echo "ERROR: Neon CLI is not authenticated. Run: neonctl auth" >&2
    echo "       (or: npx neonctl auth)" >&2
    exit 1
  fi

  local project_id
  if [ -n "${NEON_PROJECT_ID:-}" ]; then
    project_id="$NEON_PROJECT_ID"
    echo "==> Fetching DB_CONNECTION_URI from neon connection-string (NEON_PROJECT_ID)"
  elif DB_CONNECTION_URI="$(run_neon connection-string --endpoint-type read_write 2>/dev/null || true)" \
    && [ -n "$DB_CONNECTION_URI" ]; then
    echo "==> Fetching DB_CONNECTION_URI from neon connection-string (CLI context)"
    record_source "DB_CONNECTION_URI (neon connection-string, CLI context)"
    return 0
  else
    project_id="$(resolve_neon_project_id)"
    echo "==> Fetching DB_CONNECTION_URI from neon connection-string (project ${project_id})"
  fi

  DB_CONNECTION_URI="$(run_neon connection-string --project-id "$project_id" --endpoint-type read_write)"
  record_source "DB_CONNECTION_URI (neon connection-string)"
}

fetch_bao_token() {
  if [ "$SKIP_BAO" = true ]; then
    return 0
  fi

  if [ -n "${BAO_TOKEN:-}" ]; then
    record_source "BAO_TOKEN (environment override)"
    return 0
  fi

  if [ ! -f "$INIT_OUTPUT_FILE" ]; then
    return 0
  fi

  require_cmd jq "Install jq: https://jqlang.github.io/jq/"
  echo "==> Fetching BAO_TOKEN from init-output.json"
  BAO_TOKEN="$(jq -r '.root_token // empty' "$INIT_OUTPUT_FILE")"
  if [ -n "$BAO_TOKEN" ] && [ "$BAO_TOKEN" != "null" ]; then
    record_source "BAO_TOKEN (init-output.json)"
  else
    BAO_TOKEN=""
  fi
}

assert_non_empty() {
  local name="$1"
  local value="$2"
  if [ -z "$value" ]; then
    echo "ERROR: ${name} is empty after fetch" >&2
    exit 1
  fi
}

fly_app_exists() {
  require_cmd jq "Install jq: https://jqlang.github.io/jq/"
  flyctl apps list --json 2>/dev/null \
    | jq -e --arg app "$FLY_APP" '.[] | select(.Name == $app)' >/dev/null 2>&1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-fly) SKIP_FLY=true ;;
    --skip-bao) SKIP_BAO=true ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

require_cmd gh "Install: https://cli.github.com/"
if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh is not authenticated. Run: gh auth login" >&2
  exit 1
fi

GITHUB_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
if [ -z "$GITHUB_REPO" ]; then
  echo "ERROR: Could not detect GitHub repo. Run from a linked git repository." >&2
  exit 1
fi

load_env_file "$ENV_FILE"
load_env_file "$ENV_SECRETS_FILE"

echo "==> GitHub repository: ${GITHUB_REPO}"
echo "==> Fly app: ${FLY_APP}"
echo ""

fetch_fly_api_token
fetch_cf_api_token
verify_cf_api_token
fetch_db_connection_uri
fetch_bao_token

assert_non_empty FLY_API_TOKEN "$FLY_API_TOKEN"
assert_non_empty CF_API_TOKEN "$CF_API_TOKEN"
assert_non_empty DB_CONNECTION_URI "$DB_CONNECTION_URI"

echo ""
echo "==> Setting GitHub Actions secrets..."
gh secret set FLY_API_TOKEN --body "$FLY_API_TOKEN" --repo "$GITHUB_REPO"
gh secret set CF_API_TOKEN --body "$CF_API_TOKEN" --repo "$GITHUB_REPO"
gh secret set DB_CONNECTION_URI --body "$DB_CONNECTION_URI" --repo "$GITHUB_REPO"

GITHUB_SET=(FLY_API_TOKEN CF_API_TOKEN DB_CONNECTION_URI)

if [ -n "${BAO_TOKEN:-}" ]; then
  gh secret set BAO_TOKEN --body "$BAO_TOKEN" --repo "$GITHUB_REPO"
  GITHUB_SET+=(BAO_TOKEN)
fi

FLY_SET=()
FLY_APP_MISSING=false
if [ "$SKIP_FLY" = false ]; then
  if ! command -v flyctl >/dev/null 2>&1; then
    echo "WARNING: flyctl not found — skipping Fly secrets" >&2
  elif ! fly_app_exists; then
    FLY_APP_MISSING=true
    echo "WARNING: Fly app '${FLY_APP}' does not exist — skipping Fly secrets" >&2
    echo "         Create it with: fly apps create ${FLY_APP}" >&2
    echo "         Then re-run: ./scripts/seed-github-secrets.sh" >&2
  else
    echo "==> Setting Fly secrets..."
    flyctl secrets set DB_CONNECTION_URI="$DB_CONNECTION_URI" --app "$FLY_APP"
    FLY_SET+=(DB_CONNECTION_URI)
    record_source "Fly DB_CONNECTION_URI (same as GitHub)"
  fi
else
  echo "==> Skipping Fly secrets (--skip-fly)"
fi

echo ""
echo "================================================================================"
echo "Secrets seeded successfully (values not shown)"
echo "================================================================================"
echo ""
echo "Sources:"
for entry in "${SECRET_SOURCES[@]}"; do
  echo "  - ${entry}"
done
echo ""
echo "GitHub Actions secrets (${GITHUB_REPO}):"
for name in "${GITHUB_SET[@]}"; do
  echo "  - ${name}"
done
echo ""
if [ "${#FLY_SET[@]}" -gt 0 ]; then
  echo "Fly secrets (${FLY_APP}):"
  for name in "${FLY_SET[@]}"; do
    echo "  - ${name}"
  done
else
  echo "Fly secrets: (none set)"
fi
echo ""
if [ -z "${BAO_TOKEN:-}" ]; then
  echo "Note: BAO_TOKEN was not set. Smoke tests will skip until you run init.sh"
  echo "      and re-run: ./scripts/seed-github-secrets.sh"
fi
