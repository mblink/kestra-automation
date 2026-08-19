#!/usr/bin/env bash

FOLDER=$(date +'%Y-%m' -d "yesterday")
FILE_MATCH=$(date +'%Y%m%d' -d "yesterday")

cd /var/log/
for f in $(find . -maxdepth 1 -name "*${FILE_MATCH}*.gz" | sed s':./::'); do
  sudo /usr/local/bin/aws s3 cp ${f} s3://bondlink-data-east/syslogs/${HOSTNAME}/${FOLDER}/${f} --only-show-errors
done
