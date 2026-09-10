#!/usr/bin/env bash
REGION=
PREFIX=
BUCKET=
DAYS="30"
FORCE=0
function usage {
  echo "Usage: $0 -r region -b bucket -p prefix -d [number of days] -f (force, don't prompt)"
}
while getopts r:b:p:d:f OPT; do

  case "$OPT" in
    r)
      REGION="${OPTARG}" ;;
    p)
      PREFIX="${OPTARG}" ;;
    b)
      BUCKET="${OPTARG}" ;;
    d)
      DAYS="${OPTARG}"
      ;;
    f)
      FORCE=1
      ;;
    ?)
      usage "$@" && exit 2 ;;
  esac
done;
END_DAILY=$(date -d "now - ${DAYS} days" +'%Y-%m-%d')
VERSIONQ="?LastModified < '${END_DAILY}'"

echo "Deleting contents matching ${REGION} ${BUCKET}/${PREFIX}/ filtering on ${VERSIONQ}"
answer=
if [ $FORCE -eq 0 ]; then
  echo "Apply these changes [Y/n]"
  read answer
fi

if [[ "$answer" != "${answer#[Yy]}" || $FORCE -eq 1 ]] ;then
  echo "Running query, deleting in batches"
#set -x
  /usr/local/bin/aws s3api list-object-versions \
      --region "$REGION" \
      --bucket "$BUCKET" \
      --prefix "${PREFIX}/" \
      --query  "Versions[${VERSIONQ}].[Key,VersionId]" \
      --no-cli-pager \
      --output text |
  awk '{ acc = acc "{Key=" $1 ",VersionId=" $2 "}," }
       NR % 500 == 0 {print "Objects=[" acc "],Quiet=False"; acc="" }
       END { print "Objects=[" acc "],Quiet=False" }' |
  awk '{gsub(/{Key=None,VersionId=},/, "");}1' |
  while read batch; do
  if [ "$batch" = "Objects=[],Quiet=False" ]; then
      echo "Nothing to delete"
    else
      /usr/local/bin/aws s3api delete-objects --bucket "$BUCKET" --delete "$batch" --output text --no-cli-pager
    fi
  done
else
  echo "Not applying query"
fi
