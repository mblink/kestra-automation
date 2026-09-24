#!/usr/bin/env bash
OPERATION=$1; shift

set -eo pipefail

privateDsnByTagName() {
  local tagName="$1"
  local dnsNames
  dnsNames="$(/usr/local/bin/aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$tagName" "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].NetworkInterfaces[].PrivateIpAddresses[].PrivateDnsName" \
    --output text)"
  local count
  count=$(wc -w <<< "$dnsNames")
  if [ "$count" -ne 1 ]; then
    echo "Expected exactly 1 running host tagged Name=$tagName, found $count: $dnsNames" >&2
    return 1
  fi
  echo "$dnsNames"
}

$OPERATION "$@"
