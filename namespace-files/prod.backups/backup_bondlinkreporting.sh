#!/usr/bin/env bash
set -e

output=$(sudo salt proddbanalytics mariadb_backup.single_backup BondLinkReporting --out=json)
echo "$output" | jq -e '.[] | select(.success == true)'
