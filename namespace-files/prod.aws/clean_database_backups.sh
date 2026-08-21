#!/bin/bash
START_DAILY=$(date +'%Y-%m-%d')
START_WEEKLY=$(date -d "${START_DAILY} - 366 days" +'%Y-%m-%d')
END_WEEKLY=$(date -d "${START_WEEKLY} - 1 years" +'%Y-%m-%d')
START_MONTHLY=$(date -d "${END_WEEKLY} + 1 day" +'%Y-%m-%d')
END_MONTHLY=$(date -d "now - 20 years" +'%Y-%m-%d')
TO_DATE_REGEX="s:([0-9]{4})-([0-9]{2})-([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})/?:\1-\2-\3:"


# bondlink-us-east-2 only has keys starting in 2-20-2024, a year from then, assuming nothing changes is when that key will need to be considered.
# syncing them to a single namespace seems stupid.
TOP_LEVEL="s3://bondlink-data/backups/mysql/bondlink-us-west-2"
MATCH_DAY="Sunday"
STOP_DATE="${END_WEEKLY}"
declare -a weekly
declare -a monthly

log() { echo -e "[$(date +"%Y-%m-%dT%H:%M:%S")] $1"; }

weekly=("${START_WEEKLY}" "${END_WEEKLY}")
monthly=("${START_MONTHLY}" "${END_MONTHLY}")
log "Weekly ${weekly[*]}"
log "Monthly ${monthly[*]}"

SLEEP_TIME=1
set -e

if [ "$1" != "--dryrun" ]; then
  log "This script is running in live mode, sleeping ${SLEEP_TIME} seconds if you want to change your mind"
  sleep $SLEEP_TIME
  log "Waking up, you've been warned"
  DRYRUN=0
else
  log "Running in dryrun mode"
  DRYRUN=1
fi

keyToDateS() { echo "$1" | sed 's:\.sql.*$::' |  sed -E "${TO_DATE_REGEX}"; }

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
      if [[ "${item}" =~ "sql" ]]; then
        recursive=
      else
        recursive="--recursive "
      fi
      if [[ $DRYRUN -eq 1 || "${asDateS}" > "$STOP_DATE" ]]; then
        # log "*** Saving *** DryRun: $DRYRUN StopDate: $STOP_DATE - aws s3 rm ${recursive}s3://bondlink-data/mysql/backups/$item";
        continue
      else
        log "*** Deleting ${checkType} - $i/$totalKeys *** aws s3 rm ${recursive}s3://bondlink-data/backups/mysql/bondlink-us-west-2/$item"
        /usr/local/bin/aws s3 rm ${recursive}s3://bondlink-data/backups/mysql/bondlink-us-west-2/$item --only-show-errors
      fi
    done;
  fi
}

declare -a deleteMonthlyDates
declare -a deleteWeeklyDates
declare -a saveDates
declare -a afterStop
for s3Key in $(/usr/local/bin/aws s3 ls "${TOP_LEVEL}/" | grep "20" | awk '{ print $NF }'); do
  asDateS=$(keyToDateS "${s3Key}")
  if [[ ! -z "${STOP_DATE}" &&  "${asDateS}" > "${STOP_DATE}" ]]; then
    afterStop+=("$s3Key")
  elif [[ "${asDateS}" < "${weekly[0]}"  && "${asDateS}" > "${weekly[1]}" && "$(date -d "${asDateS}" +'%A')" != "$MATCH_DAY" ]]; then
    deleteWeeklyDates+=("${s3Key}")
  elif [[ "${asDateS}" < "${monthly[0]}"  && "${asDateS}" >  "${monthly[1]}" && "$(date -d ${asDateS} +'%d')" != "01" ]]; then
    deleteMonthlyDates+=("${s3Key}")
  else
    saveDates+=("${s3Key}")
  fi
done
log "Key stats"
log "Past Stop Date: ${#afterStop[@]}"
log "Weekly Deletes: ${#deleteWeeklyDates[@]}"
log "Monthly Deletes: ${#deleteMonthlyDates[@]}"
maybeDeleteBackup monthly "${deleteMonthlyDates[@]}"
maybeDeleteBackup weekly "${deleteWeeklyDates[@]}"
exit 0;
