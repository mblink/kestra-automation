#!/usr/bin/env bash

FOLDER=$(date +'%Y-%m' -d "yesterday")
FILE_MATCH=$(date +'%Y%m%d' -d "yesterday")

cd /var/log/
if [ -z "$(find . -maxdepth 1 -name "*${FILE_MATCH}*.gz" | sed s':./::')" ]; then
  echo "No files found for ${FILE_MATCH}"
  exit 0
fi
for f in $(find . -maxdepth 1 -name "*${FILE_MATCH}*.gz" | sed s':./::'); do
  sudo /usr/local/bin/aws s3 cp ${f} s3://bondlink-data-east/syslogs/${HOSTNAME}/${FOLDER}/${f} --only-show-errors
done
