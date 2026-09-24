#!/usr/bin/env bash
# Emit one line per actionable CI event for a PR's Woodpecker build, then exit when it is terminal.
# Written for the Monitor tool: each stdout line becomes a notification, and exiting ends the watch.
set -uo pipefail

HOST="https://woodpecker.bondlink.org"
KEYCHAIN_SERVICE="woodpecker.bondlink.org"

usage() {
  cat >&2 <<'EOF'
usage: watch-pr-build.sh <pr-number> [--sha <commit>] [--interval <s>] [--wait <s>] [--idle <s>]

  <pr-number>  GitHub PR number (required).
  --sha        watch only the pipeline built from this commit; pass $(git rev-parse HEAD) after
               pushing a fix, or the previous failed pipeline is reported again.
  --interval   seconds between polls (default 30).
  --wait       seconds to tolerate no pipeline at all, or one stuck in `created` (default 600).
  --idle       seconds to tolerate a queued or running pipeline with no state change (default 2400;
               a build can legitimately sit queued for several minutes behind another one).

Exit: 0 passed, skipped or canceled; 1 failed or declined; 2 nothing ran (no pipeline, stalled,
queued out, no progress, blocked) or bad usage.
EOF
}

pr=""; want_sha=""; interval=30; wait_for=600; idle_limit=2400
while [ $# -gt 0 ]; do
  case "$1" in
    --sha) want_sha="${2:-}"; shift 2 || exit 2 ;;
    --interval) interval="${2:-}"; shift 2 || exit 2 ;;
    --wait) wait_for="${2:-}"; shift 2 || exit 2 ;;
    --idle) idle_limit="${2:-}"; shift 2 || exit 2 ;;
    -h|--help) usage; exit 2 ;;
    -*) echo "unknown flag: $1" >&2; usage; exit 2 ;;
    *) if [ -n "$pr" ]; then usage; exit 2; fi; pr="$1"; shift ;;
  esac
done
case "$pr" in ''|*[!0-9]*) usage; exit 2 ;; esac
for n in "$interval" "$wait_for" "$idle_limit"; do
  case "$n" in ''|*[!0-9]*) usage; exit 2 ;; esac
done

for c in curl jq git security; do
  command -v "$c" >/dev/null || { echo "missing required command: $c" >&2; exit 2; }
done

token=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null) || {
  echo "no Woodpecker token in the keychain (service $KEYCHAIN_SERVICE) — see the woodpecker skill" >&2
  exit 2
}

api() { printf 'Authorization: Bearer %s' "$token" | curl -sS --max-time 30 -H @- "$HOST/api/$1"; }

remote=$(git config --get remote.origin.url) || { echo "no origin remote" >&2; exit 2; }
full_name=$(printf '%s\n' "$remote" | sed -E 's#^(git@[^:]+:|ssh://[^/]+/|https?://[^/]+/)##; s#\.git$##')
repo_id=$(api "repos/lookup/$full_name" | jq -r '.id // empty')
[ -n "$repo_id" ] || { echo "Woodpecker does not know $full_name" >&2; exit 2; }
ui="$HOST/repos/$repo_id/pipeline"

reported="|"                          # keys already emitted, wrapped in | for an exact match
once() {                              # once <key> <line…> — emit a line the first time only
  local key="$1"; shift
  case "$reported" in *"|$key|"*) return 0 ;; esac
  reported="$reported$key|"
  echo "$*"
}

now() { date +%s; }
started=$(now); last_change=$started; fingerprint=""; grace_used=0

while :; do
  list=$(api "repos/$repo_id/pipelines?event=pull_request&ref=refs/pull/$pr/merge&perPage=10")
  if [ -n "$want_sha" ]; then
    num=$(printf '%s' "$list" | jq -r --arg s "$want_sha" '[.[]? | select(.commit | startswith($s))][0].number // empty' 2>/dev/null)
  else
    num=$(printf '%s' "$list" | jq -r '.[0].number // empty' 2>/dev/null)
  fi

  if [ -z "$num" ]; then
    if [ $(( $(now) - started )) -ge "$wait_for" ]; then
      echo "NO PIPELINE for PR $pr${want_sha:+ at ${want_sha:0:9}} after ${wait_for}s — the webhook or the config compile failed; GitHub shows no status either, so check the server log"
      exit 2
    fi
    sleep "$interval"; continue
  fi

  detail=$(api "repos/$repo_id/pipelines/$num")
  status=$(printf '%s' "$detail" | jq -r '.status // empty' 2>/dev/null)
  [ -n "$status" ] || { sleep "$interval"; continue; }
  once "seen-$num" "WATCHING pipeline $num [$status] for PR $pr — $ui/$num"

  fp="$num:$status:$(printf '%s' "$detail" | jq -r '[.workflows[]?.children[]? | "\(.name):\(.state)"] | join(",")' 2>/dev/null)"
  if [ "$fp" != "$fingerprint" ]; then fingerprint="$fp"; last_change=$(now); fi
  idle=$(( $(now) - last_change ))

  while IFS= read -r e; do
    [ -n "$e" ] && once "err-$num-$e" "CONFIG ERROR pipeline $num: $e"
  done <<< "$(printf '%s' "$detail" | jq -r '.errors[]? | "\(.type): \(.message)"' 2>/dev/null)"

  while IFS='|' read -r name state code id; do
    [ -n "$name" ] || continue
    once "step-$num-$name" "STEP FAILED $name [$state exit=$code] pipeline $num — log: repos/$repo_id/logs/$num/$id"
  done <<< "$(printf '%s' "$detail" | jq -r '.workflows[]?.children[]? | select(.state=="failure" or .state=="error" or .state=="killed") | "\(.name)|\(.state)|\(.exit_code)|\(.id)"' 2>/dev/null)"

  case "$status" in
    success)
      echo "BUILD PASSED pipeline $num — $ui/$num"; exit 0 ;;
    skipped)
      echo "BUILD SKIPPED pipeline $num — no step ran"; exit 0 ;;
    failure|error|declined)
      echo "BUILD $(printf '%s' "$status" | tr '[:lower:]' '[:upper:]') pipeline $num — $ui/$num"
      printf '%s' "$detail" | jq -r '.workflows[]?.children[]? | select(.state!="success" and .state!="skipped" and .state!="pending") | "  \(.name) [\(.state)] step id \(.id)"'
      exit 1 ;;
    killed|canceled|cancelled)
      if [ -z "$want_sha" ] && [ "$grace_used" -eq 0 ]; then
        grace_used=1; sleep "$interval"; continue    # one more poll: a new push supersedes the old pipeline
      fi
      echo "BUILD CANCELED pipeline $num — superseded by a newer push, or canceled by hand"
      exit 0 ;;
    blocked)
      echo "BUILD BLOCKED pipeline $num — waiting on manual approval in Woodpecker"; exit 2 ;;
    created)
      if [ "$idle" -ge "$wait_for" ]; then
        echo "STALLED pipeline $num [created] ${idle}s with no workflow — the DAG compiler panic leaves a pipeline exactly like this; see the woodpecker skill"
        exit 2
      fi ;;
    pending)
      if [ "$idle" -ge "$idle_limit" ]; then
        echo "QUEUED pipeline $num [pending] ${idle}s with no state change — check for a connected agent (queue/info worker_count) before assuming a slow build"
        exit 2
      fi ;;
    running)
      if [ "$idle" -ge "$idle_limit" ]; then
        echo "NO PROGRESS pipeline $num [running] ${idle}s with no step state change — usually a dead or duplicate agent, not a slow step; see the woodpecker skill"
        exit 2
      fi ;;
  esac
  sleep "$interval"
done
