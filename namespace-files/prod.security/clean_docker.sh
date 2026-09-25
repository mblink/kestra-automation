#!/usr/bin/env bash
# Mirrors salt's salt/docker/bin/clean-docker.sh. Every reclaim is age-scoped because the target runs live builds.

set -eo pipefail

if ! sudo docker info > /dev/null 2>&1; then
  echo 'Docker is not running'
  exit 0
fi

PRUNE_AGE_HOURS=6
PRUNE_CUTOFF_EPOCH=$(( $(date +%s) - PRUNE_AGE_HOURS * 3600 ))

# `docker images` appends a zone abbreviation `date -d` rejects; keeping three fields drops it and leaves RFC3339 intact.
createdEpoch() {
  date -d "$(printf '%s' "$1" | awk '{print $1, $2, $3}')" +%s 2>/dev/null || echo 0
}

olderThanCutoff() {
  [ "$(createdEpoch "$1")" -le "$PRUNE_CUTOFF_EPOCH" ]
}

# cleanImg <reference-glob> <keep>: removes images older than the cutoff, sparing the <keep> newest image IDs per repository.
cleanImg() {
  local ref=$1 keep=$2

  sudo docker images \
    --filter "reference=668874212870.dkr.ecr.us-east-1.amazonaws.com/$ref" \
    --format '{{.Repository}}	{{.ID}}	{{.Repository}}:{{.Tag}}	{{.CreatedAt}}' |
  while IFS=$'\t' read -r repo id img created; do
    [ -n "$img" ] || continue
    created_epoch=$(createdEpoch "$created")
    printf '%s\t%s\t%s\t%s\n' "$repo" "$created_epoch" "$id" "$img"
  done |
  sort -t"$(printf '\t')" -k1,1 -k2,2nr |
  # split("", rank), not delete rank: /usr/bin/awk on the agents is mawk.
  awk -F'\t' -v keep="$keep" '
    $1 != repo { repo = $1; split("", rank); n = 0 }
    !($3 in rank) { n++; rank[$3] = n }
    rank[$3] > keep { print }
  ' |
  while IFS=$'\t' read -r _ created_epoch _ img; do
    if [ "$created_epoch" -gt "$PRUNE_CUTOFF_EPOCH" ]; then
      echo "Skipping $img (newer than ${PRUNE_AGE_HOURS}h -- may belong to a running build)"
      continue
    fi
    sudo docker rmi -f "$img" || echo "Failed to remove $img"
  done
}

# Not `docker image prune --filter until=`: on the containerd image store that filter matches nothing.
cleanDangling() {
  sudo docker image ls --all --filter dangling=true \
    --format '{{.ID}}	{{.CreatedAt}}' |
  while IFS=$'\t' read -r id created; do
    [ -n "$id" ] || continue
    if olderThanCutoff "$created"; then
      sudo docker rmi -f "$id" || echo "Failed to remove dangling image $id"
    fi
  done
}

# Woodpecker workspace volumes are named (wp_*), so `volume prune` without --all never reclaims them.
cleanPipelineVolumes() {
  sudo docker volume ls --quiet --filter 'name=^wp_' |
  while read -r vol; do
    [ -n "$vol" ] || continue
    if [ -n "$(sudo docker ps --all --quiet --filter "volume=$vol")" ]; then
      echo "Skipping volume $vol (a container is still attached)"
      continue
    fi
    if olderThanCutoff "$(sudo docker volume inspect "$vol" --format '{{.CreatedAt}}')"; then
      sudo docker volume rm "$vol" || echo "Failed to remove volume $vol"
    else
      echo "Skipping volume $vol (newer than ${PRUNE_AGE_HOURS}h -- may belong to a running build)"
    fi
  done
}

cleanImg 'bondlink*' 3
cleanImg '*:build-*' 1

PRUNE_AGE="until=${PRUNE_AGE_HOURS}h"

cleanDangling

sudo docker container prune --force --filter "$PRUNE_AGE"
sudo docker network prune --force --filter "$PRUNE_AGE"
sudo docker system prune --force --filter "$PRUNE_AGE"

# Never --all and never `system prune --volumes`: volume prune has no `until` filter, so those delete a between-steps build's named volumes.
sudo docker volume prune --force

cleanPipelineVolumes
