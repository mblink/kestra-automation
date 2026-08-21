#!/usr/bin/env bash

set -eo pipefail

dryRun=0
if [ "$1" = '--dry-run' ]; then
  dryRun=1
fi

log() {
  echo -e "[$(date +"%Y-%m-%dT%H:%M:%S")] $1"
}

regions=(us-east-1 us-east-2)
declare -a allRepos
declare -a appRepos
declare -a droneRepos
allRepos=$(aws ecr describe-repositories \
            --query "repositories[?starts_with(repositoryName, 'drone-') || starts_with(repositoryName, 'bondlink-')].repositoryName" --output text)
for repo in $allRepos; do
  if [[ "$repo" == drone-* ]]; then
    droneRepos+=("$repo")
  else
    appRepos+=("$repo")
  fi
done

branches=(
  RC
  develop
  ai-builds
)

prefixWithSpaces() {
  while read -r s; do
    echo "$s" | sed -e 's/^/  /g'
  done
}

deleteInBatches() {
  echo "$3"
  region="$1"
  repo="$2"
  images="$3"

  # Chunk images into groups of 100, the AWS API only allows deleting 100 images at a time.
  # nwise isn't a jq builtin -- it's the chunking recipe from jq's manual, defined inline here.
  for batch in $(
    jq -c '
      def nwise($n):
        if length <= $n then .
        else .[0:$n], (.[$n:] | nwise($n))
        end;

      nwise(100) | select(length > 0)
    ' <<< "$images"
  ); do
    log "Deleting images in repo $repo:\n$(echo "$batch" | jq -c '.[]' | prefixWithSpaces)"

    if [ "$dryRun" = 0 ]; then
      res="$(
        /usr/local/bin/aws ecr batch-delete-image \
          --region "$region" \
          --repository-name "$repo" \
          --image-ids "$batch"
      )"

      # The command above returns an exit code of 0 even when there were errors
      # so we need to check the response's failures key
      failures="$(jq '.failures | select(length | . > 0)' <<< "$res")"

      if [ ! -z "$failures" ]; then
        log "Failed to delete images:\n$(echo "$failures" | prefixWithSpaces)"
      fi
    fi
  done
}

imagesToKeep() {
  repo="$1"
  branch="$2"

  # Keep the last 20 RC images, the last 3 for other branches
  if [ "$branch" = 'RC' ]; then
    if [ "$repo" = 'bondlink-drone-monitor' ]; then
      echo 3
    else
      echo 20
    fi
  else
    echo 3
  fi
}

deleteUntaggedImages() {
  repos=("$@")

  for repo in "${repos[@]}"; do
    log "***************** Checking untagged images in ECR repo $repo in region $region"

    # Delete all images that don't have tags
    untaggedImageDigests="$(
      /usr/local/bin/aws ecr describe-images \
        --region "$region" \
        --repository-name "$repo" \
        --filter 'tagStatus=UNTAGGED' \
        --output json \
        | jq -c '.imageDetails | map({ "imageDigest": .imageDigest })'
    )"

    deleteInBatches "$region" "$repo" "$untaggedImageDigests"
  done
}

deleteBranchImages() {
  repos=("$@")

  for repo in "${repos[@]}"; do
    log "***************** Checking feature branch images in ECR repo $repo in region $region"

    allImages="$(
      /usr/local/bin/aws ecr describe-images \
        --region "$region" \
        --repository-name "$repo" \
        --output json \
        | jq -c '.imageDetails'
    )"

    for branch in "${branches[@]}"; do
      # Keep the last N images for the given branch, where N is dictated by imagesToKeep
      imagesToDelete="$(
        jq -c '
          # Filter images to only those that match our tagging pattern
          map(select((.imageTags // []) | map(select(test("^[0-9]{14}_'$branch'_[A-Za-z0-9]+$"))) | any))
            # Sort images by their most recent tag
            | sort_by(.imageTags | sort | .[-1])
            # Drop the last N images
            | .[:-'$(imagesToKeep "$repo" "$branch")']
            # Map to just the image tags and flatten the array
            | map(.imageTags)
            | flatten
            # Filter out null values
            | map(select(.))
            # Construct the shape that the AWS API wants
            | map({ "imageTag": . })
        ' <<< "$allImages"
      )"

      deleteInBatches "$region" "$repo" "$imagesToDelete"
    done
  done
}

deleteAllButLatestImage() {
  repos=("$@")

  for repo in "${repos[@]}"; do
    log "***************** Check non-latest images in ECR repo $repo in region $region"

    allImages="$(
      /usr/local/bin/aws ecr describe-images \
        --region "$region" \
        --repository-name "$repo" \
        --output json \
        | jq -c '.imageDetails'
    )"

    imagesToDelete="$(
      jq -c '
        # Filter out images with latest tag
        map(select((.imageTags // []) | map(select(. | IN("latest", "latest-arm64"))) | any | not))
          # Map to just the image tags and flatten the array
          | map(.imageTags)
          | flatten
          # Filter out null values
          | map(select(.))
          # Construct the shape that the AWS API wants
          | map({ "imageTag": . })
      ' <<< "$allImages"
    )"

    deleteInBatches "$region" "$repo" "$imagesToDelete"
  done
}

for region in "${regions[@]}"; do
  deleteUntaggedImages "${appRepos[@]}"
  deleteBranchImages "${appRepos[@]}"

  deleteUntaggedImages "${droneRepos[@]}"
  deleteAllButLatestImage "${droneRepos[@]}"
done
