#!/usr/bin/env bash

set -eo pipefail

dryRun=0
if [ "$1" = '--dry-run' ]; then
  dryRun=1
fi

cpus="$(nproc --all)"
parallelJobs=$((cpus / 2))

declare -A buckets
buckets=(["bondlink-corporate"]="production" ["bondlink-corporate-dev"]="staging")

tenDaysAgoEpochMillis="$(jq -r '((now - (10 * 24 * 60 * 60)) * 1000) | floor' <<< '{}')"

log() {
  echo -e "[$(date +"%Y-%m-%dT%H:%M:%S")] $1"
}

maybeDeleteBuild() {
  s3Prefix="$1"
  key="$2"
  progress="$3"

  epochMillis="$(echo "$key" | sed -E 's/^preview-([0-9]+)$/\1/')"
  s3Uri="$s3Prefix/$key"

  # Delete the build if it occurred more than 10 days ago
  if [ "$epochMillis" -lt "$tenDaysAgoEpochMillis" ]; then
    log "Deleting build $progress -- $s3Uri"
    if [ "$dryRun" = 0 ]; then
      /usr/local/bin/aws s3 rm --recursive --only-show-errors "$s3Uri"
    fi
  else
    log "Preserving build $progress -- $s3Uri"
  fi
}

for bucket in "${!buckets[@]}"; do
  env="${buckets[$bucket]}"
  s3Prefix="s3://$bucket/corp/$env"

  log "***************** Checking corp preview builds in $s3Prefix"

  # List all matching keys and read them into an array
  readarray -t keys <<< $(
    /usr/local/bin/aws s3 ls "$s3Prefix/" \
      | grep -E '\s+preview-[0-9]+/' \
      | awk '{print $2}' \
      | sed -E 's@/$@@'
  )

  keyCount=${#keys[@]}

  # Keep track of the number of currently running jobs
  # https://stackoverflow.com/a/53870978/2163024
  numJobs="\j"

  for idx in ${!keys[@]}; do
    # If the number of jobs currently running is >= the number we want to run in parallel, wait until one finishes
    # @P tells bash to expand numJobs, see the stack overflow link above
    while (( ${numJobs@P} >= parallelJobs )); do
      wait -n
    done

    maybeDeleteBuild "$s3Prefix" "${keys[$idx]}" "$((idx + 1)) / $keyCount" &
  done

  # Wait for all jobs to finish
  wait
done
