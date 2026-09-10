#!/usr/bin/env bash

set -eo pipefail

dryRun=0
if [ "$1" = '--dry-run' ]; then
  dryRun=1
fi

log() {
  echo -e "[$(date +"%Y-%m-%dT%H:%M:%S")] $1"
}

startYear=2021
startMonth=8

function computeStartYearMonth() {
  # Ensure the start month has a leading zero if it's only one digit
  echo "$startYear-$(jq -r '"0\(.)"[-2:]' <<< "$startMonth")"
}

startYearMonth="$(computeStartYearMonth)"

endYearMonth="$(
  jq -r '
    # Get current unix timestamp
    now
    # Convert it to array of elements, i.e. year, month, day, etc.
    | gmtime
    # Set the third array element (day) to 1 (the first day of the month)
    | .[2] = 1
    # Subtract 3 from the second array element (month) to get three months ago
    # It does not matter that this could result in a negative number, jq handles it gracefully
    | .[1] -= 3
    # Convert the array back to a unix timestamp
    | mktime
    # Print the year and month of the timestamp
    | strftime("%Y-%m")
  ' <<< '{}'
)"

yearMonthsToDelete=()

while [ "$startYearMonth" != "$endYearMonth" ]; do
  yearMonthsToDelete+=("$startYearMonth")

  if [ "$startMonth" = 12 ]; then
    startYear=$((startYear + 1))
    startMonth=1
  else
    startMonth=$((startMonth + 1))
  fi

  startYearMonth="$(computeStartYearMonth)"
done

s3Bucket='bondlink-data-east'
s3Prefix='backups/basex'
keyRx='^'$s3Prefix'/IceGsm-(?<ym>[0-9]{4}-[0-9]{2})-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}\\.(zip|tar\\.br|tar\\.zst)$'

keysByYearMonth="$(
  /usr/local/bin/aws s3api list-objects-v2 --bucket "$s3Bucket" --prefix "$s3Prefix" \
    | jq -c '
      .Contents
      | map(.Key)
      | map(select(test("'$keyRx'")))
      # Reduce keys into an object keyed by `$year-$month`
      | reduce .[] as $x ({}; ($x | sub("'$keyRx'"; "\(.ym)")) as $ym | .[$ym] = ((.[$ym] // []) + [$x]))
    '
)"

for yearMonth in "${yearMonthsToDelete[@]}"; do
  backupsToDelete="$(
    jq '
      # Get backups from the given year/month
      .["'$yearMonth'"]
      # Sort them so the latest appear at the end
      | sort
      # Drop the last one (we keep the most recent backup from the year/month)
      | .[0:-1]
    ' <<< "$keysByYearMonth"
  )"

  if [ "$backupsToDelete" != '[]' ]; then
    log "*************** Deleting BaseX backups from $yearMonth -- $backupsToDelete"

    apiJson="$(jq '{ "Objects": (. | map({ "Key": . })) }' <<< "$backupsToDelete")"

    if [ "$dryRun" = 0 ]; then
      res="$(/usr/local/bin/aws s3api delete-objects --bucket "$s3Bucket" --delete "$apiJson")"

      # The command above returns an exit code of 0 even when there were errors
      # so we need to check the response's errors key
      errors="$(jq '.Errors | select(length | . > 0)' <<< "$res")"

      if [ ! -z "$errors" ]; then
        log "Failed to delete backups:\n$(echo "$errors")"
        exit 1
      fi
    fi
  fi
done
