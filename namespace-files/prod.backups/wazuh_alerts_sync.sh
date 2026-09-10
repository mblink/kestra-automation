#!/usr/bin/env bash
set -e

# The manager runs in Docker, so /var/ossec/logs exists only inside the container. Ask
# docker where the named volume lives rather than hardcoding a path under
# /var/lib/docker/volumes, which is a compose-project-name away from being wrong.
alerts="$(sudo docker volume inspect multi-node_master-wazuh-logs | jq -r '.[0].Mountpoint')/alerts"
# sudo test, not [ -d ]: /var/lib/docker is drwx--x--- root:root, so bldeploy cannot
# traverse it and a bare test reports the directory missing.
sudo test -d "$alerts" || { echo "no alerts directory at $alerts" >&2; exit 1; }
sudo /usr/local/bin/aws s3 sync "$alerts" s3://bondlink-data-east/ossec-logs/prod/ --only-show-errors
