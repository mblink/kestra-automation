#!/usr/bin/env bash

if [ -z "$(sudo getfacl -p /var/cache/salt/minion/roots/mtime_map | grep user:salt:rw)" ]; then
  sudo setfacl -m u:salt:rw -R /var/cache/salt/minion/roots/mtime_map
fi
