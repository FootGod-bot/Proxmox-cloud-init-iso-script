#!/bin/bash

# Make sure cloud-init template folder exists
mkdir -p /var/lib/vz/template/cloud-init

# Download script to home directory
cd ~/
curl -L -o new_vm.sh https://raw.githubusercontent.com/FootGod-bot/Proxmox-cloud-init-iso-script/refs/heads/main/new_vm.sh

# Check if download succeeded
if [ $? -eq 0 ]; then
    echo "Install complete!"
else
    echo "Download failed!"
fi
