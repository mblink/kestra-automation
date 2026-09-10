#!/usr/bin/env bash
set -e
dockerImages='multi-node-wazuh.master-1 multi-node-wazuh.worker-1'
DISCONNECTED=$(for container in ${dockerImages}; do
  sudo -u bldeploy ssh prodops02 "sudo docker exec $container /var/ossec/bin/agent_control -ln | grep ID | awk '{ print \$4 }' | sed s/,//g"
done)

TRY_CONNECT=
checkInstanceState() {
  /usr/local/bin/aws ec2 describe-instances --filter "Name=tag:Name,Values=$1" --query "Reservations[*].Instances[*].State" | jq '.[][].Name' | sed 's/"//g'
}
if [ ! -z "${DISCONNECTED}" ]; then
  for server in ${DISCONNECTED}; do
    iState=$(checkInstanceState $server)
    if [[ "$iState" = "running" && "${server}" != "prodsalt" ]]; then
      TRY_CONNECT="${TRY_CONNECT}$server "
    fi
  done;
  echo "TryConnect ${TRY_CONNECT}"
  if [ ! -z "${TRY_CONNECT}" ]; then

    SALT_DIS=$(echo "${TRY_CONNECT}" | sed 's/ /,/g' | sed 's/,$//')
    echo "Disconnected agents: ${SALT_DIS}"
    sudo salt -L "${SALT_DIS}" cmd.run "service wazuh-agent restart"
  else
    echo "Instances were in a hibernated state"
    exit 0
  fi
fi;
