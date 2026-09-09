#!/bin/bash
# Retention for date-stamped MySQL backup prefixes. Bucket, prefix, retention policy and delete mode
# are all required: the correct delete mode is a property of the (bucket, prefix) pair's lifecycle
# rules, not of the bucket, and the retention policy differs per prefix, so neither can be inferred.

ALLOWED_BUCKETS="bondlink-data bondlink-data-east bondlink-data-ohio bondlink-data-east-ohio"

S3_BUCKET=
S3_PREFIX=
MODE=
RETAIN=
KEEP_DAYS=
MAX_STALE_DAYS=
DRYRUN=1

# Absolute by default: the Kestra SSH session's PATH does not include it. Overridable only so the
# test suite can put a stub in front; nothing in production sets this.
AWS_BIN="${AWS_BIN:-/usr/local/bin/aws}"

usage() {
  cat <<'USAGE'
Usage: clean_database_backups.sh --bucket <bucket> --prefix <prefix> --retain <policy>
                                 --mode <marker|version> [--live]
       --retain last-days additionally requires --keep-days and --max-stale-days

  --bucket   one of: bondlink-data bondlink-data-east bondlink-data-ohio bondlink-data-east-ohio
  --prefix   key prefix holding date-stamped backups, no leading or trailing slash
             (e.g. backups/mysql/bondlink-us-east-1)
  --retain   banded  GFS bands: every entry to 366 days, Sundays only for the year before that,
                     first-of-month only back to 20 years. Retention is a date threshold.
             last-days  keep every run belonging to the N most recent distinct dates and delete
                        the rest. Retention is a rank among siblings, so it needs --keep-days and
                        --max-stale-days.
  --keep-days       last-days only: how many of the most recent distinct dates to keep. Every run
                    on a kept date is kept, so an ad-hoc re-run cannot collapse coverage to fewer
                    dates. Deletes nothing if fewer than N distinct parseable dates exist.
  --max-stale-days  last-days only: refuse to delete anything if the newest parseable entry is
                    older than this. A stalled backup job otherwise leaves only stale copies, and
                    the deletion is not reversible.
  --mode     marker   delete the current object; a lifecycle rule reaps the version and the marker.
                      Requires the prefix to be covered by an enabled rule carrying BOTH
                      NoncurrentVersionExpiration and Expiration.ExpiredObjectDeleteMarker;
                      the script verifies this and refuses otherwise.
             version  delete every version and delete marker permanently. Irreversible, and not
                      replicated to a destination bucket. For prefixes with no reaping rule, where
                      a plain delete would leave the bytes billable forever.
  --live     actually delete. Without it the script only reports what it would do.
USAGE
}

needValue() { [ $# -ge 2 ] || { echo "missing value for $1" >&2; usage >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --bucket) needValue "$@"; S3_BUCKET="$2"; shift 2 ;;
    --prefix) needValue "$@"; S3_PREFIX="$2"; shift 2 ;;
    --mode) needValue "$@"; MODE="$2"; shift 2 ;;
    --retain) needValue "$@"; RETAIN="$2"; shift 2 ;;
    --keep-days) needValue "$@"; KEEP_DAYS="$2"; shift 2 ;;
    --max-stale-days) needValue "$@"; MAX_STALE_DAYS="$2"; shift 2 ;;
    --live) DRYRUN=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log() { echo -e "[$(date +"%Y-%m-%dT%H:%M:%S")] $1"; }

for required in S3_BUCKET S3_PREFIX MODE RETAIN; do
  if [ -z "${!required}" ]; then
    echo "error: --${required#S3_} is required" | tr '[:upper:]' '[:lower:]' >&2
    usage >&2
    exit 2
  fi
done

bucketAllowed=1
for allowed in $ALLOWED_BUCKETS; do
  [ "$S3_BUCKET" = "$allowed" ] && bucketAllowed=0
done
if [ "$bucketAllowed" -ne 0 ]; then
  echo "error: --bucket ${S3_BUCKET} is not one of: ${ALLOWED_BUCKETS}" >&2
  exit 2
fi

case "$MODE" in
  marker|version) ;;
  *) echo "error: --mode must be marker or version" >&2; exit 2 ;;
esac

case "$RETAIN" in
  banded)
    if [ -n "$KEEP_DAYS" ] || [ -n "$MAX_STALE_DAYS" ]; then
      echo "error: --keep-days and --max-stale-days apply to --retain last-days only" >&2; exit 2
    fi ;;
  last-days)
    for n in KEEP_DAYS MAX_STALE_DAYS; do
      case "${!n}" in
        ''|*[!0-9]*) echo "error: --retain last-days requires --${n//_/-} as a positive integer" | tr '[:upper:]' '[:lower:]' >&2; exit 2 ;;
      esac
      if [ "${!n}" -lt 1 ]; then
        echo "error: --${n//_/-} must be at least 1" | tr '[:upper:]' '[:lower:]' >&2; exit 2
      fi
    done ;;
  *) echo "error: --retain must be banded or last-days" >&2; exit 2 ;;
esac

case "$S3_PREFIX" in
  /*|*/) echo "error: --prefix must not start or end with /" >&2; exit 2 ;;
esac

TOP_LEVEL="s3://${S3_BUCKET}/${S3_PREFIX}"

START_DAILY=$(date +'%Y-%m-%d')
START_WEEKLY=$(date -d "${START_DAILY} - 366 days" +'%Y-%m-%d')
END_WEEKLY=$(date -d "${START_WEEKLY} - 1 years" +'%Y-%m-%d')
# END_WEEKLY itself, not +1 day: the monthly test is `< START_MONTHLY`, so a +1 made the monthly
# band include END_WEEKLY and overlap the weekly one. A Sunday there was declined by the weekly
# rule and then deleted by the monthly rule for not being the 1st.
START_MONTHLY="${END_WEEKLY}"
END_MONTHLY=$(date -d "now - 20 years" +'%Y-%m-%d')

# %u, not %A: the day *name* is locale-dependent, so a non-English LC_TIME on the runner would
# never match and every date in the weekly band would be deleted, Sundays included.
MATCH_DOW=7
# Save-guard: nothing dated after this is ever deleted, so it is the daily band's far edge.
STOP_DATE="${START_WEEKLY}"
declare -a weekly
declare -a monthly

# marker mode leaves the superseded version and the delete marker behind for lifecycle to reap.
# Without both rules the bytes stay billable forever and the delete makes the bucket cost more.
assertReapingLifecycle() {
  local cfg reaps
  cfg=$("${AWS_BIN}" s3api get-bucket-lifecycle-configuration --bucket "${S3_BUCKET}" --output json 2>/dev/null) || {
    log "Refusing --mode marker: ${S3_BUCKET} has no lifecycle configuration, so deleted versions would never expire"
    exit 1
  }
  reaps=$(jq -r --arg p "${S3_PREFIX}" '
    [ .Rules[]
      | select(.Status == "Enabled")
      | . as $r
      | select((($r.Filter.And // {}) | keys - ["Prefix"] | length) == 0)
      | (($r.Filter.Prefix // $r.Filter.And.Prefix // $r.Prefix // "")) as $rp
      | select($p | startswith($rp))
    ] as $matched
    | (($matched | map(select(.NoncurrentVersionExpiration != null)) | length) > 0)
      and (($matched | map(select(.Expiration.ExpiredObjectDeleteMarker == true)) | length) > 0)
  ' <<< "${cfg}")
  if [ "${reaps}" != "true" ]; then
    log "Refusing --mode marker: no enabled lifecycle rule on ${S3_BUCKET} covers ${S3_PREFIX} with both NoncurrentVersionExpiration and ExpiredObjectDeleteMarker"
    log "Use --mode version for this prefix, or add the lifecycle rules first"
    exit 1
  fi
  log "Lifecycle check: ${S3_PREFIX} is covered by a reaping rule, marker mode is safe"
}

weekly=("${START_WEEKLY}" "${END_WEEKLY}")
monthly=("${START_MONTHLY}" "${END_MONTHLY}")
log "Target ${TOP_LEVEL} retain=${RETAIN} mode=${MODE}"
if [ "${RETAIN}" = "banded" ]; then
  log "Daily ${START_DAILY} ${START_WEEKLY}"
  log "Weekly ${weekly[*]}"
  log "Monthly ${monthly[*]}"
else
  log "Keeping every run on the ${KEEP_DAYS} most recent dates; refusing if the newest is over ${MAX_STALE_DAYS} day(s) old"
fi

SLEEP_TIME=1
set -e

if [ "${MODE}" = "marker" ]; then
  assertReapingLifecycle
fi

if [ "${DRYRUN}" -eq 0 ]; then
  log "This script is running in live mode (${MODE}), sleeping ${SLEEP_TIME} seconds if you want to change your mind"
  sleep $SLEEP_TIME
  log "Waking up, you've been warned"
else
  log "Running in dryrun mode -- pass --live to delete"
fi

# Two key shapes carry a timestamp, each matched by its own anchored pattern:
#   date directory  2026-09-08_07-38-35/           (and the same stem as a flat .sql.* file)
#   dated dump      20260908060004_IpreoHoldings.sql.zst
# A key matching neither yields the empty string and is never a delete candidate -- widening either
# pattern to cover a stray shape would put siblings such as final-db02-snapshot/ and mysql.<rand>/
# in scope. Both the band test and the last-days ranking read this one recogniser, so they can never
# disagree about which keys are backups.
keyToStampS() {
  if [[ "$1" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2}) ]]; then
    printf '%s%s%s%s%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
      "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}"
  # Underscores are legal in a schema name, so the name segment has to admit them -- the producer
  # writes {stamp}_{database}.sql.zst for whatever INFORMATION_SCHEMA.SCHEMATA returns.
  elif [[ "$1" =~ ^([0-9]{14})_[A-Za-z][A-Za-z0-9_]*\. ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
  return 0
}

keyToDateS() {
  local stamp
  stamp=$(keyToStampS "$1")
  if [ -n "${stamp}" ]; then
    printf '%s-%s-%s\n' "${stamp:0:4}" "${stamp:4:2}" "${stamp:6:2}"
  fi
  return 0
}

# Permanently removes every version and delete marker under one key prefix. Paginates the listing,
# batches at the delete-objects limit of 1000, and fails on .Errors -- the API returns 0 on a
# partial failure, so an unchecked call reports success while leaving objects behind.
deleteAllVersions() {
  local keyPrefix="$1" token page ids chunk payload res errCount total=0
  token=
  while :; do
    if [ -n "${token}" ]; then
      page=$("${AWS_BIN}" s3api list-object-versions --bucket "${S3_BUCKET}" --prefix "${keyPrefix}" \
        --max-items 1000 --starting-token "${token}" --output json)
    else
      page=$("${AWS_BIN}" s3api list-object-versions --bucket "${S3_BUCKET}" --prefix "${keyPrefix}" \
        --max-items 1000 --output json)
    fi
    ids=$(jq -c '[ (.Versions // [])[], (.DeleteMarkers // [])[] | {Key, VersionId} ]' <<< "${page}")
    local count
    count=$(jq 'length' <<< "${ids}")
    total=$((total + count))
    if [ "${count}" -gt 0 ]; then
      while read -r chunk; do
        payload=$(jq -c '{Objects: ., Quiet: true}' <<< "${chunk}")
        res=$("${AWS_BIN}" s3api delete-objects --bucket "${S3_BUCKET}" --delete "${payload}" --output json)
        errCount=$(jq '(.Errors // []) | length' <<< "${res}")
        if [ "${errCount}" -gt 0 ]; then
          log "delete-objects reported ${errCount} error(s) under ${keyPrefix}:"
          jq -r '(.Errors // [])[] | "  \(.Key) \(.VersionId) \(.Code) \(.Message)"' <<< "${res}"
          exit 1
        fi
      done < <(jq -c 'range(0; length; 1000) as $i | .[$i:$i+1000]' <<< "${ids}")
    fi
    token=$(jq -r '.NextToken // empty' <<< "${page}")
    [ -z "${token}" ] && break
  done
  log "  removed ${total} version(s)/marker(s) under ${keyPrefix}"
}

# Counts what version mode would remove, without removing it.
countAllVersions() {
  local keyPrefix="$1" token page objects bytes total=0 totalBytes=0
  token=
  while :; do
    if [ -n "${token}" ]; then
      page=$("${AWS_BIN}" s3api list-object-versions --bucket "${S3_BUCKET}" --prefix "${keyPrefix}" \
        --max-items 1000 --starting-token "${token}" --output json)
    else
      page=$("${AWS_BIN}" s3api list-object-versions --bucket "${S3_BUCKET}" --prefix "${keyPrefix}" \
        --max-items 1000 --output json)
    fi
    objects=$(jq '((.Versions // []) | length) + ((.DeleteMarkers // []) | length)' <<< "${page}")
    bytes=$(jq '[(.Versions // [])[].Size] | add // 0' <<< "${page}")
    total=$((total + objects))
    totalBytes=$((totalBytes + bytes))
    token=$(jq -r '.NextToken // empty' <<< "${page}")
    [ -z "${token}" ] && break
  done
  log "  would remove ${total} version(s)/marker(s), ${totalBytes} bytes under ${keyPrefix}"
}

maybeDeleteBackup() {
  local checkType=$1; shift;
  local deleteKeys=("$@")
  if [ "${#deleteKeys[@]}" -eq 0 ]; then
    log "No keys to delete DRYRUN: ${DRYRUN}, StopDate: ${STOP_DATE} checkType: ${checkType}"
  else
    local totalKeys="${#deleteKeys[@]}"
    log "CheckType: ${checkType}. Total Keys: ${totalKeys}"
    for i in "${!deleteKeys[@]}"; do
      item="${deleteKeys[$i]}"
      asDateS=$(keyToDateS "${item}")
      if [[ "${item}" == */ ]]; then
        recursive="--recursive "
      else
        recursive=
      fi
      if [ "${RETAIN}" = "banded" ] && [[ "${asDateS}" > "$STOP_DATE" ]]; then
        log "*** Saving *** StopDate: $STOP_DATE - ${TOP_LEVEL}/$item"
        continue
      fi
      if [ "${MODE}" = "version" ]; then
        log "*** ${checkType} - $i/$totalKeys *** permanent version delete under ${TOP_LEVEL}/$item"
        if [ "${DRYRUN}" -eq 1 ]; then
          countAllVersions "${S3_PREFIX}/${item}"
        else
          deleteAllVersions "${S3_PREFIX}/${item}"
        fi
      else
        log "*** ${checkType} - $i/$totalKeys *** aws s3 rm ${recursive}${TOP_LEVEL}/$item"
        if [ "${DRYRUN}" -eq 0 ]; then
          # ${recursive} unquoted on purpose: empty must contribute no argument. The key is quoted.
          "${AWS_BIN}" s3 rm ${recursive}"${TOP_LEVEL}/${item}" --only-show-errors
        fi
      fi
    done;
  fi
}

declare -a deleteMonthlyDates
declare -a deleteWeeklyDates
declare -a saveDates
declare -a afterStop
declare -a unrecognised
declare -a rankable
# Materialised before the loop: piping the listing straight into `for` swallows a failed
# aws call as an empty result, and an empty result means "nothing to keep".
if ! listing=$("${AWS_BIN}" s3 ls "${TOP_LEVEL}/"); then
  log "Refusing to continue: listing ${TOP_LEVEL}/ failed"
  exit 1
fi
for s3Key in $(awk '{ print $NF }' <<< "${listing}"); do
  asStampS=$(keyToStampS "${s3Key}")
  if [ -z "${asStampS}" ]; then
    unrecognised+=("${s3Key}")
    continue
  fi
  rankable+=("${asStampS}	${s3Key}")
  asDateS="${asStampS:0:4}-${asStampS:4:2}-${asStampS:6:2}"
  if [ "${RETAIN}" != "banded" ]; then
    continue
  fi
  if [[ ! -z "${STOP_DATE}" &&  "${asDateS}" > "${STOP_DATE}" ]]; then
    afterStop+=("$s3Key")
  # >= on the far edge so the weekly band owns END_WEEKLY outright; the monthly band starts below it.
  elif [[ "${asDateS}" < "${weekly[0]}"  && ! "${asDateS}" < "${weekly[1]}" && "$(date -d "${asDateS}" +'%u')" != "$MATCH_DOW" ]]; then
    deleteWeeklyDates+=("${s3Key}")
  elif [[ "${asDateS}" < "${monthly[0]}"  && "${asDateS}" >  "${monthly[1]}" && "$(date -d "${asDateS}" +'%d')" != "01" ]]; then
    deleteMonthlyDates+=("${s3Key}")
  else
    saveDates+=("${s3Key}")
  fi
done

log "Key stats"
log "Parseable entries: ${#rankable[@]}"
log "Unrecognised (never deleted): ${#unrecognised[@]}"
for u in "${unrecognised[@]+"${unrecognised[@]}"}"; do log "  skipped, no date in key: ${u}"; done

if [ "${RETAIN}" = "banded" ]; then
  log "Past Stop Date: ${#afterStop[@]}"
  log "Kept by band: ${#saveDates[@]}"
  log "Weekly Deletes: ${#deleteWeeklyDates[@]}"
  log "Monthly Deletes: ${#deleteMonthlyDates[@]}"
  maybeDeleteBackup monthly "${deleteMonthlyDates[@]+"${deleteMonthlyDates[@]}"}"
  maybeDeleteBackup weekly "${deleteWeeklyDates[@]+"${deleteWeeklyDates[@]}"}"
  exit 0
fi

# last-days. Group on the date parsed out of the key rather than on the raw key, so a key-shape
# change cannot silently reorder the series, and an unrecognised key can never displace a real
# backup from the kept set -- it is not in `rankable` at all. Every run on a kept date is kept, so
# an ad-hoc re-run adds a run to a date rather than pushing an older date out.
declare -a keepDates
while read -r d; do
  keepDates+=("${d}")
done < <(printf '%s\n' "${rankable[@]}" | cut -c1-8 | sort -ru | head -n "${KEEP_DAYS}")

if [ "${#keepDates[@]}" -lt "${KEEP_DAYS}" ]; then
  log "Only ${#keepDates[@]} distinct parseable date(s), fewer than --keep-days ${KEEP_DAYS}; deleting nothing"
  exit 0
fi

newestStamp=$(printf '%s\n' "${rankable[@]}" | sort -r | head -1 | cut -f1)
newestDate="${newestStamp:0:4}-${newestStamp:4:2}-${newestStamp:6:2}"
staleBefore=$(date -d "${START_DAILY} - ${MAX_STALE_DAYS} days" +'%Y-%m-%d')
if [[ "${newestDate}" < "${staleBefore}" ]]; then
  log "Refusing: newest entry is ${newestDate}, older than the ${MAX_STALE_DAYS}-day staleness limit (${staleBefore})"
  log "The backup job has probably stopped; deleting the remainder would leave only stale copies"
  exit 1
fi

isKeptDate() {
  local d
  for d in "${keepDates[@]}"; do
    if [ "${d}" = "$1" ]; then
      return 0
    fi
  done
  return 1
}

declare -a deleteRanked
while IFS=$'\t' read -r stamp key; do
  if isKeptDate "${stamp:0:8}"; then
    log "Keeping ${stamp:0:4}-${stamp:4:2}-${stamp:6:2}: ${key}"
  else
    deleteRanked+=("${key}")
  fi
done < <(printf '%s\n' "${rankable[@]}" | sort -r)

log "Newest: ${newestDate}. Keeping ${KEEP_DAYS} date(s), deleting ${#deleteRanked[@]} entr(ies)"
maybeDeleteBackup "last-${KEEP_DAYS}-days" "${deleteRanked[@]+"${deleteRanked[@]}"}"
exit 0
