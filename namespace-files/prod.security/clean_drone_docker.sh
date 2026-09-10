#!/usr/bin/env bash
set -e

mapfile -t appImages < <(sudo docker images | grep '/bondlink' | awk '{print $3}')
sudo docker rmi "${appImages[@]}" || echo 'No application images to remove'
cleanImg() {
  for img in $(
    sudo docker images --filter "reference=668874212870.dkr.ecr.us-east-1.amazonaws.com/$1:build-*" \
      | awk '{ print $1":"$2 }' \
      | tail -n +2
  ); do
    sudo docker rmi "$img" || echo "Failed to remove $img"
  done
}
cleanImg 'basex'
cleanImg 'drone-build-java-17'
cleanImg 'drone-cache'
cleanImg 'drone-ecr-auth'
mapfile -t danglingImages < <(sudo docker images -f 'dangling=true' -q)
sudo docker rmi "${danglingImages[@]}" || echo 'No dangling images to remove'
sudo docker system prune --volumes --force
sudo docker network prune --force
sudo docker volume prune --all --force
