#!/usr/bin/env bash
set -e

myq() {
  sudo mariadb -e "$1"
}

IS_CLUSTER_MEMBER=$(myq "show status like 'wsrep_cluster_size'" | tail -1 | awk '{ print $NF }')
IS_REPLICA=
REPLICA_CHECK=$(myq "show slave status")
if test -z "${REPLICA_CHECK}"; then
  IS_REPLICA=0
else
  IS_REPLICA=1
fi

function desync {
  if [ $IS_CLUSTER_MEMBER -gt 0 ]; then
    myq "SET GLOBAL wsrep_desync = ON;"
    myq "SET GLOBAL wsrep_on = OFF;"
  elif [ $IS_REPLICA -eq 1 ]; then
    myq "stop slave"
  else
    echo "Neither a cluster member or a replica, nothing to desync"
  fi
}

function resync {
  if [ $IS_CLUSTER_MEMBER -gt 0 ]; then
    myq  "SET GLOBAL wsrep_on = ON;"
    myq "SET GLOBAL wsrep_desync = OFF;"
  elif [ $IS_REPLICA -eq 1 ]; then
    myq "start slave"
  else
    echo "Neither a cluster member or a replica, nothing to resync"
  fi
}

declare -i CORES=0
F_DATE=$(date '+%Y-%m-%d_%H-%M-%S')
CORES=$(cat /proc/cpuinfo | grep processor | wc -l | awk '{ print $NF/2 }' )
TMP=$(sudo mktemp -d '/tmp/devbackup.XXXXXXXXXX')
sudo chmod -R 777 ${TMP}
CWD=$(pwd)
trap resync EXIT
desync

# $TMP is chmod 777, so this redirect succeeds as bldeploy.
# shellcheck disable=SC2024
sudo mariadb-dump \
  --databases BondLink \
  --no-create-db \
  --no-data \
  --routines \
  --skip-triggers \
  > ${TMP}/BondLink_schema.sql

# $TMP is chmod 777, so this redirect succeeds as bldeploy.
# shellcheck disable=SC2024
sudo mariadb-dump \
  --databases BondLink \
  --single-transaction \
  --no-create-db \
  --no-create-info \
  --skip-triggers \
  --ignore-table=BondLink.IssuerPaymentTokens \
  --ignore-table=BondLink.ActivityNotifications \
  --ignore-table=BondLink.ActivityNotifications1Y \
  > ${TMP}/BondLink_data.sql

# $TMP is chmod 777, so this redirect succeeds as bldeploy.
# shellcheck disable=SC2024
sudo mariadb-dump \
  --databases BondLink \
  --no-create-db \
  --no-create-info \
  --no-data \
  --triggers \
  > ${TMP}/BondLink_triggers.sql

resync
cd ${TMP}
# shellcheck disable=SC2089
sq="'"
# shellcheck disable=SC2090
printf '
#!/usr/bin/env bash

set -exo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

# Recreate database so tables that exist in dev but not yet prod are removed
sudo mariadb -e "SET foreign_key_checks = 0; DROP DATABASE IF EXISTS BondLink;"
sudo mariadb -e "CREATE DATABASE BondLink;"

load_db_file() {
  # Remove definer declarations and sandbox mode comment to prevent errors in dev
  sed -E '$sq's/DEFINER=[^ |\*]*//g'$sq' "$1" \
  | sed -E '$sq's@^/\*M?!999999\\\\- enable the sandbox mode \*/@@g'$sq' \
  | sudo mariadb BondLink
}

load_db_file "$SCRIPT_DIR/BondLink_schema.sql"
load_db_file "$SCRIPT_DIR/BondLink_data.sql"
load_db_file "$SCRIPT_DIR/BondLink_triggers.sql"

# Update all custom domains and prep `/etc/hosts` for viewing them locally
sudo mariadb -e "UPDATE Banks SET custom_domain = REGEXP_REPLACE(custom_domain, '$sq'\.(gov|com|co|info|org|net|edu|us|bs)$'$sq', '$sq'.local'$sq') WHERE custom_domain IS NOT NULL;" BondLink
sudo mariadb -e "UPDATE Issuers SET custom_domain = REGEXP_REPLACE(custom_domain, '$sq'\.(gov|com|co|info|org|net|edu|us|bs)$'$sq', '$sq'.local'$sq') WHERE custom_domain != '$sq$sq';" BondLink

all_domains="$(mktemp)"
trap '$sq'rm -f "$all_domains"'$sq' EXIT

sudo mariadb -B -N -e '$sq'
SELECT DISTINCT host
FROM (
  # All bank custom domain hosts, potentially with `www.`
  (
    SELECT DISTINCT custom_domain COLLATE utf8mb4_unicode_ci AS custom_domain, CONCAT("127.0.0.1 ", REGEXP_REPLACE(custom_domain COLLATE utf8mb4_unicode_ci, "^https?://", "")) AS host
    FROM Banks
    WHERE custom_domain IS NOT NULL
    ORDER BY custom_domain ASC
  )
  UNION ALL
  # All bank custom domain hosts, without `www.`
  (
    SELECT DISTINCT custom_domain COLLATE utf8mb4_unicode_ci, CONCAT("127.0.0.1 ", REGEXP_REPLACE(custom_domain COLLATE utf8mb4_unicode_ci, "^https?://www\.", "")) AS host
    FROM Banks
    WHERE custom_domain IS NOT NULL
    ORDER BY custom_domain ASC
  )
  UNION ALL
  # All issuer custom domain hosts, potentially with `www.`
  (
    SELECT DISTINCT custom_domain, CONCAT("127.0.0.1 ", REGEXP_REPLACE(custom_domain, "^https?://", "")) AS host
    FROM Issuers
    WHERE custom_domain != ""
    ORDER BY custom_domain ASC
  )
  UNION ALL
  # All issuer custom domain hosts, without `www.`
  (
    SELECT DISTINCT custom_domain, CONCAT("127.0.0.1 ", REGEXP_REPLACE(custom_domain, "^https?://www\.", "")) AS host
    FROM Issuers
    WHERE custom_domain != ""
    ORDER BY custom_domain ASC
  )
) AS hosts
ORDER BY custom_domain, host
'$sq' BondLink > "$all_domains"

blcd="BondLink custom domains -- DO NOT REMOVE THIS COMMENT"
lead="### BEGIN $blcd"
leadrx="^$lead$"
tail="### END $blcd"
tailrx="^$tail$"

set +x

hosts="$(cat /etc/hosts)"

# The hosts file contains the begin line but not the end line
if grep -q "$leadrx" <<< "$hosts"; then
  if ! grep -q "$tailrx" <<< "$hosts"; then
    hosts="$(sed -E "s/$leadrx//g" <<< "$hosts")"
  fi
fi

# The hosts file contains the end line but not the begin line
if grep -q "$tailrx" <<< "$hosts"; then
  if ! grep -q "$leadrx" <<< "$hosts"; then
    hosts="$(sed -E "s/$tailrx//g" <<< "$hosts")"
  fi
fi

# The hosts file contains both the begin and end lines
if grep -q "$leadrx" <<< "$hosts"; then
  if grep -q "$tailrx" <<< "$hosts"; then
    hosts="$(sed -e "/$leadrx/,/$tailrx/{ /$leadrx/{p; r $all_domains" -e " }; /$tailrx/p; d;}" <<< "$hosts")"
  fi
fi

# The hosts file contains neither the begin nor end line
if ! grep -q "$leadrx" <<< "$hosts"; then
  if ! grep -q "$tailrx" <<< "$hosts"; then
    hosts="$hosts\\n\\n$lead\\n$(cat "$all_domains")\\n$tail"
  fi
fi

# Backup the existing hosts file, then overwrite it
sudo mv /etc/hosts /etc/hosts.bak
printf "$hosts" | sudo tee /etc/hosts > /dev/null

#clear the redis of all databases
redis-cli -h localhost FLUSHALL;

' | sudo tee BondLink_restore.sh > /dev/null

BUCKET="bondlink-data-east"
PREFIX="backups/mysql/us-east-1/devbackups"
tar cf bondlink_dev_backup_${F_DATE}.tar BondLink_schema.sql BondLink_data.sql BondLink_triggers.sql BondLink_restore.sh
/usr/bin/zstd -14 --no-progress -T${CORES} bondlink_dev_backup_${F_DATE}.tar
sudo /usr/local/bin/aws s3 cp bondlink_dev_backup_${F_DATE}.tar.zst s3://${BUCKET}/${PREFIX}/bondlink_dev_backup_${F_DATE}.tar.zst --only-show-errors
echo s3://${BUCKET}/${PREFIX}/bondlink_dev_backup_${F_DATE}.tar.zst
cd $CWD
sudo rm -rf ${TMP}
exit 0;
