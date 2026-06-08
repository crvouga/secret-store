#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OWNER="crvouga"
LIMIT=1000
NO_CLONE=false
KEEP_CLONES=false
CLONE_ROOT=""
SEARCH_HIT_FILE=""

TOTAL=0
MIGRATED=0
NOT_MIGRATED=0
SKIPPED=0

declare -a RESULT_LINES=()
declare -a EXCLUDE_PATH_PATTERNS=(
  'synced/test-files/*'
  '*/test-files/*'
  'test-files/*'
  '*/testdata/*'
  'testdata/*'
  '*/test_data/*'
  'test_data/*'
  '*/fixtures/*'
  'fixtures/*'
)

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Check every GitHub repo owned by a user for remaining Doppler references.

A repo is considered migrated when a case-insensitive search for "doppler"
returns zero matches (see ${REPO_ROOT}/docs/migrate-from-doppler.prompt.md).

Detection uses a hybrid approach:
  1. GitHub code search (optional hint; may false-positive on substrings like "dopplerhq")
  2. Shallow clone + git grep with word-boundary matching (authoritative)

Options:
  --owner NAME     GitHub user or org (default: crvouga)
  --limit N        Max repos to list (default: 1000)
  --no-clone       Search-only mode (faster, less reliable)
  --keep-clones    Keep temporary clone directory for inspection
  --exclude-path GLOB
                   Ignore grep hits under this path (repeatable; fnmatch-style)
  -h, --help       Show this help

Test data paths are ignored by default (e.g. synced/test-files/, testdata/).

Prerequisites:
  gh (authenticated: gh auth login)
  jq, git, grep

Examples:
  ./scripts/check-doppler-migration.sh
  ./scripts/check-doppler-migration.sh --owner crvouga --no-clone
  ./scripts/check-doppler-migration.sh --keep-clones
EOF
}

require_cmd() {
  local cmd="$1"
  local install_hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: ${cmd} is required. ${install_hint}" >&2
    exit 1
  fi
}

# shellcheck disable=SC2329
cleanup() {
  if [ -n "$CLONE_ROOT" ] && [ -d "$CLONE_ROOT" ] && [ "$KEEP_CLONES" = false ]; then
    rm -rf "$CLONE_ROOT"
  fi
  if [ -n "$SEARCH_HIT_FILE" ] && [ -f "$SEARCH_HIT_FILE" ]; then
    rm -f "$SEARCH_HIT_FILE"
  fi
}

sanitize_repo_dir() {
  local name="$1"
  printf '%s' "$name" | tr '/' '_'
}

build_search_hits() {
  local search_json
  local hit_count

  SEARCH_HIT_FILE="$(mktemp)"

  echo "==> Running GitHub code search for 'doppler' (owner: ${OWNER})..."
  if ! search_json="$(gh search code doppler --owner "$OWNER" --json repository -L "$LIMIT" 2>/dev/null)"; then
    echo "WARNING: GitHub code search failed; continuing with clone+grep only" >&2
    return 0
  fi

  if [ -z "$search_json" ] || [ "$search_json" = "[]" ]; then
    echo "    No code search hits"
    return 0
  fi

  echo "$search_json" | jq -r '.[].repository | .nameWithOwner // .full_name // empty' | sort -u > "$SEARCH_HIT_FILE"
  hit_count="$(wc -l < "$SEARCH_HIT_FILE" | tr -d ' ')"
  echo "    Found ${hit_count} repo(s) with code search hits"
}

repo_has_search_hit() {
  local repo="$1"
  grep -Fxq "$repo" "$SEARCH_HIT_FILE" 2>/dev/null
}

clone_repo() {
  local repo="$1"
  local dest="$2"
  local branch="${3:-}"

  if [ -n "$branch" ]; then
    git clone --depth 1 --single-branch --branch "$branch" \
      "https://github.com/${repo}.git" "$dest" >/dev/null 2>&1
  else
    git clone --depth 1 --single-branch \
      "https://github.com/${repo}.git" "$dest" >/dev/null 2>&1
  fi
}

# Match "doppler" as a whole token (avoids false positives like "dopplerhq").
DOPPLER_GREP_PATTERN='(^|[^[:alnum:]_])doppler([^[:alnum:]_]|$)'

is_excluded_path() {
  local path="$1"
  local pattern

  for pattern in "${EXCLUDE_PATH_PATTERNS[@]}"; do
    case "$path" in
      $pattern) return 0 ;;
    esac
  done

  return 1
}

grep_doppler_files() {
  local clone_dir="$1"
  local path

  while IFS= read -r path; do
    if [ -n "$path" ] && ! is_excluded_path "$path"; then
      printf '%s\n' "$path"
    fi
  done < <(git -C "$clone_dir" grep -ril -i -E "$DOPPLER_GREP_PATTERN" 2>/dev/null || true)
}

record_result() {
  local line="$1"
  RESULT_LINES+=("$line")
  echo "$line"
}

check_repo() {
  local repo="$1"
  local default_branch="$2"
  local is_archived="$3"
  local is_fork="$4"
  local tags=""

  TOTAL=$((TOTAL + 1))

  if [ "$is_archived" = "true" ]; then
    tags="${tags} archived"
  fi
  if [ "$is_fork" = "true" ]; then
    tags="${tags} fork"
  fi
  tags="${tags# }"
  if [ -n "$tags" ]; then
    tags=" (${tags})"
  fi

  local search_hit=false
  if repo_has_search_hit "$repo"; then
    search_hit=true
  fi

  if [ "$NO_CLONE" = true ]; then
    if [ "$search_hit" = true ]; then
      NOT_MIGRATED=$((NOT_MIGRATED + 1))
      record_result "NOT MIGRATED  ${repo}${tags}  [code search hit; unverified — re-run without --no-clone]"
    else
      MIGRATED=$((MIGRATED + 1))
      record_result "MIGRATED      ${repo}${tags}  [no code search hit; clone skipped]"
    fi
    return 0
  fi

  local clone_dir
  clone_dir="${CLONE_ROOT}/$(sanitize_repo_dir "$repo")"
  rm -rf "$clone_dir"

  if ! clone_repo "$repo" "$clone_dir" "$default_branch"; then
    if [ -n "$default_branch" ] && clone_repo "$repo" "$clone_dir" ""; then
      :
    else
      NOT_MIGRATED=$((NOT_MIGRATED + 1))
      record_result "NOT MIGRATED  ${repo}${tags}  [clone failed — could not verify]"
      return 0
    fi
  fi

  local matches
  matches="$(grep_doppler_files "$clone_dir")"
  if [ -n "$matches" ]; then
    NOT_MIGRATED=$((NOT_MIGRATED + 1))
    local file_list
    file_list="$(echo "$matches" | tr '\n' ', ' | sed 's/, $//')"
    record_result "NOT MIGRATED  ${repo}${tags}  [grep hit: ${file_list}]"
    return 0
  fi

  MIGRATED=$((MIGRATED + 1))
  if [ "$search_hit" = true ]; then
    record_result "MIGRATED      ${repo}${tags}  [confirmed via clone+grep; code search false positive]"
  else
    record_result "MIGRATED      ${repo}${tags}  [confirmed via clone+grep]"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --owner)
      if [ $# -lt 2 ]; then
        echo "ERROR: --owner requires a name argument" >&2
        exit 1
      fi
      OWNER="$2"
      shift 2
      ;;
    --limit)
      if [ $# -lt 2 ]; then
        echo "ERROR: --limit requires a number argument" >&2
        exit 1
      fi
      LIMIT="$2"
      shift 2
      ;;
    --no-clone)
      NO_CLONE=true
      shift
      ;;
    --keep-clones)
      KEEP_CLONES=true
      shift
      ;;
    --exclude-path)
      if [ $# -lt 2 ]; then
        echo "ERROR: --exclude-path requires a glob argument" >&2
        exit 1
      fi
      EXCLUDE_PATH_PATTERNS+=("$2")
      shift 2
      ;;
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
done

require_cmd gh "Install: https://cli.github.com/"
require_cmd jq "Install jq: https://jqlang.github.io/jq/"
require_cmd git "Install git: https://git-scm.com/"
require_cmd grep "Install grep"

if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh is not authenticated. Run: gh auth login" >&2
  exit 1
fi

trap cleanup EXIT

echo "==> Checking Doppler migration for repos owned by: ${OWNER}"
if [ "$NO_CLONE" = true ]; then
  echo "==> Mode: search-only (--no-clone; repos without search hits marked MIGRATED without confirmation)"
else
  echo "==> Mode: hybrid (shallow clone + word-boundary grep; code search is hint only)"
fi
echo ""

build_search_hits

if [ "$NO_CLONE" = false ]; then
  CLONE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/doppler-migration-check.XXXXXX")"
  echo "==> Clone workspace: ${CLONE_ROOT}"
fi
echo ""

echo "==> Enumerating repos..."
repos_json="$(gh repo list "$OWNER" --limit "$LIMIT" \
  --json nameWithOwner,defaultBranchRef,isArchived,isFork,isEmpty,url)"

repo_count="$(echo "$repos_json" | jq 'length')"
if [ "$repo_count" -eq 0 ]; then
  echo "ERROR: No repos found for owner '${OWNER}'" >&2
  exit 1
fi

echo "Found ${repo_count} repo(s)"
echo ""
echo "==> Checking each repo..."
echo ""

while IFS=$'\t' read -r repo default_branch is_archived is_fork is_empty; do
  if [ "$is_empty" = "true" ]; then
    SKIPPED=$((SKIPPED + 1))
    record_result "SKIPPED       ${repo}  [empty repository]"
    continue
  fi

  check_repo "$repo" "$default_branch" "$is_archived" "$is_fork"
done < <(echo "$repos_json" | jq -r '.[] | [
  .nameWithOwner,
  (.defaultBranchRef.name // ""),
  (.isArchived | tostring),
  (.isFork | tostring),
  (.isEmpty | tostring)
] | @tsv')

echo ""
echo "================================================================================"
echo "Doppler migration check complete"
echo "================================================================================"
echo ""
echo "Owner:            ${OWNER}"
echo "Total repos:      ${TOTAL}"
echo "Migrated:         ${MIGRATED}"
echo "Not migrated:     ${NOT_MIGRATED}"
echo "Skipped (empty):  ${SKIPPED}"
if [ "$NO_CLONE" = true ]; then
  echo ""
  echo "Note: --no-clone was used. Repos without code search hits were not confirmed"
  echo "      via clone+grep and may still contain Doppler references."
fi
if [ "$KEEP_CLONES" = true ] && [ -n "$CLONE_ROOT" ] && [ -d "$CLONE_ROOT" ]; then
  echo ""
  echo "Clone workspace kept at: ${CLONE_ROOT}"
fi
echo ""

if [ "$NOT_MIGRATED" -gt 0 ]; then
  echo "Result: FAIL — ${NOT_MIGRATED} repo(s) still reference Doppler"
  exit 1
fi

echo "Result: PASS — all checked repos are migrated off Doppler"
exit 0
