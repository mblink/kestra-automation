#!/usr/bin/env bash
# Read-only Kestra API client, for debugging production executions from a workstation.
#
# This OSS deployment has no RBAC: `--api-token` is Enterprise-only, and HTTP basic auth is a
# single admin account (salt's pillar['kestra']['admin_username'/'admin_password'], the same
# credential salt/kestra/bin/sync-flows.sh.jinja2 uses). There is therefore no read-only
# credential to hand out, so read-only is enforced here instead: this script only ever issues
# GET, and refuses the curl flags that would let a caller smuggle in a request body.
#
# The credential is piped to curl via `--config -` so it never lands on disk and never appears
# in the process table (a `curl --user` argument would be world-readable in `ps`).
#
# Usage: bin/kestra-api.sh <path> [key==value | curl-args]...
#   bin/kestra-api.sh /executions/search namespace==prod.aws flowId==clean-production-db-backups
#   bin/kestra-api.sh /logs/<executionId>/download
#
# `key==value` arguments become URL-encoded query parameters; anything else goes to curl as-is.
set -euo pipefail

KESTRA_HOST="${KESTRA_HOST:-https://kestra.prod.bondlink.org}"
KESTRA_TENANT="${KESTRA_TENANT:-main}"
# Overridable so a different checkout location, or a non-salt credential source, still works.
KESTRA_PILLAR="${KESTRA_PILLAR:-/Volumes/Sources/salt/pillar/prod/kestra/locked.sls}"

if [ $# -lt 1 ]; then
  sed -n '13,17p' "$0" >&2
  exit 2
fi

path="$1"
shift

case "$path" in
  /*) ;;
  *) echo "error: path must start with / (e.g. /executions/search)" >&2; exit 2 ;;
esac

if [ ! -r "$KESTRA_PILLAR" ]; then
  echo "error: cannot read the Kestra credential at ${KESTRA_PILLAR}" >&2
  echo "       set KESTRA_PILLAR, or check out the salt repo alongside this one" >&2
  exit 2
fi

args=()
for arg in "$@"; do
  case "$arg" in
    # Reject the flags that would turn this into a write client. Kestra mutates state with
    # POST/PUT/DELETE, each of which needs one of these to be expressed through curl.
    -X|--request|-d|--data|--data-*|-F|--form|-T|--upload-file)
      echo "error: ${arg} would make this a write request; this client is GET-only" >&2
      exit 2 ;;
    *==*) args+=(--data-urlencode "${arg%%==*}=${arg#*==}") ;;
    *) args+=("$arg") ;;
  esac
done

awk '/admin_username:/{u=$2} /admin_password:/{p=$2} END{
  if (u == "" || p == "") {
    print "error: no admin_username/admin_password in pillar" > "/dev/stderr"
    exit 1
  }
  printf "user = \"%s:%s\"\n", u, p
}' "$KESTRA_PILLAR" \
  | curl -sS --config - --max-time 60 --get \
      "${KESTRA_HOST}/api/v1/${KESTRA_TENANT}${path}" "${args[@]}"
