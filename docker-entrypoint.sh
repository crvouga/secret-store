#!/bin/sh
set -eu
set -o pipefail

if [ -z "${DB_CONNECTION_URI:-}" ]; then
  echo "ERROR: DB_CONNECTION_URI is required" >&2
  exit 1
fi

append_search_path() {
  uri="$1"
  search_path_opt="-csearch_path%3Dsecret_store"

  case "$uri" in
    *[\?\&]options=*)
      printf '%s' "$uri" | sed "s/\\(options=[^&]*\\)/\\1%20${search_path_opt}/"
      ;;
    *\?*)
      printf '%s&options=%s' "$uri" "$search_path_opt"
      ;;
    *)
      printf '%s?options=%s' "$uri" "$search_path_opt"
      ;;
  esac
}

export BAO_PG_CONNECTION_URL="$(append_search_path "$DB_CONNECTION_URI")"

if [ -n "${FLY_APP_NAME:-}" ]; then
  export BAO_API_ADDR="https://${FLY_APP_NAME}.fly.dev"
fi

exec bao server -config=/etc/openbao/openbao.hcl
