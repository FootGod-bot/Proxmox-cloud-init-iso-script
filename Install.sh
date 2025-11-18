#!/bin/bash

# Make sure cloud-init template folder exists
apt update
apt install -y jq
mkdir -p /var/lib/vz/template/cloud-init

# Download script to home directory
bash <(wget -qO- https://raw.githubusercontent.com/FootGod-bot/Proxmox-cloud-init-iso-script/refs/heads/main/new_vm.sh)
