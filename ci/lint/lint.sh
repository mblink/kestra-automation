#!/usr/bin/env bash
# Lint orchestrator for CI and local use, modeled on /src/salt/ci/lint/lint.sh's
# shape (mode dispatch, a file-list resolver + xargs runner, a `fails` counter).
# Scoped down to what this repo actually has: no Salt state here, so there's no
# .sls/Jinja/salt-lint/yamllint/mypy -- just the repo's own Python
# (namespace-files/shared/*.py, tests/**/*.py) and the bash scripts flows
# `read()`/execute via ssh.Command (namespace-files/**/*.sh).
#
# ALL linters are BLOCKING. The mode arg only selects WHICH linters run:
#   all   -> ruff + shellcheck (default)
#   py    -> only ruff
#   shell -> only shellcheck
#
# Exit status is the number of checks that reported problems.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2

MODE="${1:-all}"
fails=0
hr() { printf '\n=== %s ===\n' "$1"; }

# File lists come from `git ls-files` (tracked files only), matched by
# extension. A resolver failure or empty list is FATAL, never a skip: both
# ruff and shellcheck exit 0 when handed no files, so an empty list would
# silently turn a blocking gate into a no-op.
lint_file_list() {
  local pattern="$1" out="$2"
  if ! git ls-files -z -- "$pattern" > "$out"; then
    echo "error: git ls-files failed to resolve '$pattern' targets -- gate NOT run" >&2
    return 1
  fi
  if [ ! -s "$out" ]; then
    echo "error: zero '$pattern' targets resolved -- refusing to pass a gate that checked nothing" >&2
    return 1
  fi
}

run_linted() {
  local pattern="$1"; shift
  local tf rc=0
  tf="$(mktemp)"
  if lint_file_list "$pattern" "$tf"; then
    xargs -0 "$@" < "$tf" || rc=1
  else
    rc=1
  fi
  rm -f "$tf"
  return "$rc"
}

run_py() {
  hr "ruff (Python)"
  if ! command -v ruff >/dev/null 2>&1; then
    echo "ruff not installed -- it is required (pip install -r requirements-test.txt)" >&2
    exit 2
  fi
  run_linted '*.py' ruff check || fails=$((fails + 1))
}

run_shell() {
  hr "shellcheck (shell scripts)"
  if ! command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck not installed -- it is required (baked into the CI image)" >&2
    exit 2
  fi
  # -f gcc keeps output to path:line:col: severity: message [SCxxxx].
  run_linted '*.sh' shellcheck --severity=warning -f gcc || fails=$((fails + 1))
}

case "$MODE" in
  all) run_py; run_shell ;;
  py) run_py ;;
  shell) run_shell ;;
  *) echo "usage: lint.sh [all|py|shell]"; exit 2 ;;
esac

printf '\n=== lint(%s) summary: %d check(s) reported problems ===\n' "$MODE" "$fails"
exit "$fails"
