#!/usr/bin/env bash
set -e

/usr/local/bin/aws s3 sync /var/log/suricata/ "s3://bondlink-data-east/suricata-logs/$(hostname)/" --exclude="*" --include="*.gz" --only-show-errors
