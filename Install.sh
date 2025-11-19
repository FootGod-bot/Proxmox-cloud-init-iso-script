#!/bin/bash

apt update
apt install -y jq
mkdir -p /var/lib/vz/template/cloud-init

# write the command into vm.sh
echo 'bash <(wget -qO- https://raw.githubusercontent.com/FootGod-bot/Proxmox-cloud-init-iso-script/refs/heads/main/new_vm.sh)' > ~/vm.sh
chmod +x ~/vm.sh

echo "Run ./vm.sh to add a cloud init vm"
echo "Running script"
./vm.sh
