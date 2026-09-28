#!/usr/bin/env bash
OPERATION=$1; shift

set -eo pipefail

privateDnsByTagName() {
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


environmentKestraWorker() {
  local environment="$1"
  local kestraWorkers
  kestraWorkers="$(/usr/local/bin/aws ec2 describe-instances \
    --filters "Name=tag:NodeType,Values=kestra-worker" "Name=tag:Environment,Values=$environment" "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].NetworkInterfaces[].PrivateIpAddresses[].PrivateDnsName" \
    --output text)"
  local count
  count=$(wc -w <<< "$kestraWorkers")
  if [ "$count" -eq 0 ]; then
    echo "No running kestra-worker found in environment=$environment" >&2
    return 1
  elif [ "$count" -gt 1 ]; then
    kestraWorkers=$(cut -d' ' -f1 <<< "$kestraWorkers")
  fi
  echo "$kestraWorkers"
}

$OPERATION "$@"
