#!/usr/bin/env bash
# Removes one execution's saved tofu plans: /tmp/tofu-plans/run-<execution id>. Run from a flow's
# finally: block, so it fires on success, failure and kill. Takes the id, not a path, so a bad
# argument can't reach drift-check's /tmp/tofu-plans/<env>/ plans or anything else.
set -euo pipefail

execution_id=${1:?usage: tofu_plan_cleanup.sh <kestra execution id>}
if [[ ! $execution_id =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "refusing: '$execution_id' is not a Kestra execution id" >&2
  exit 1
fi

plan_dir=/tmp/tofu-plans/run-$execution_id
if [[ -d $plan_dir ]]; then
  find "$plan_dir" -type f -print
  rm -rf -- "$plan_dir"
  echo "removed $plan_dir"
else
  echo "no plans at $plan_dir"
fi
