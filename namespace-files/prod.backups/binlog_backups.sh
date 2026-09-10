#!/usr/bin/env bash
CURRENT=$(sudo mariadb -e "show master status" | grep -v File | cut -f 1)
sudo /usr/local/bin/aws s3 sync /var/log/mysql/ "s3://bondlink-data-east/backups/mysql/binlogs/$(hostname)/" --exclude="*" --include="*bin*" --exclude="*index*" --exclude="${CURRENT}" --only-show-errors
