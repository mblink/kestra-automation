#!/usr/bin/env bash
# Daily. Uploads yesterday's dateext-stamped rotations; logrotate keeps owning
# retention, so nothing is removed here.
set -euo pipefail

FOLDER=$(date +'%Y-%m' -d "yesterday")
FILE_MATCH=$(date +'%Y%m%d' -d "yesterday")

bucket="bondlink-data-east"
host=$(hostname)

cd /var/log/ || exit 1

# No -maxdepth: nginx/, salt/ and suricata/ rotate below this directory, and a
# depth-1 search reached none of them.
mapfile -t files < <(
  find . \( -name "*${FILE_MATCH}*.gz" -o -name "*${FILE_MATCH}*.zst" \) | sed 's:^\./::'
)

if [ "${#files[@]}" -eq 0 ]; then
  echo "No files found for ${FILE_MATCH}"
  exit 0
fi

uploaded=0 failed=0
for f in "${files[@]}"; do
  # suricata keeps its own flat prefix, the one its backups have always used and
  # the one the staging suricata flow writes.
  case "$f" in
    suricata/*) key="suricata-logs/${host}/${f##*/}" ;;
    *)          key="syslogs/${host}/${FOLDER}/${f}" ;;
  esac
  if /usr/local/bin/aws s3 cp "$f" "s3://${bucket}/${key}" --only-show-errors; then
    uploaded=$((uploaded + 1))
  else
    printf '  UPLOAD FAILED %s\n' "$f" >&2
    failed=$((failed + 1))
  fi
done

printf '%s: found=%d uploaded=%d failed=%d\n' "$host" "${#files[@]}" "$uploaded" "$failed"
[ "$failed" -eq 0 ]
