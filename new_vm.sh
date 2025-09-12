#!/bin/bash

# Folder with images
IMG_FOLDER="/var/lib/vz/template/iso"

echo "Available images in $IMG_FOLDER:"
mapfile -t IMG_LIST < <(ls "$IMG_FOLDER")
for i in "${!IMG_LIST[@]}"; do
    echo "$((i+1)): ${IMG_LIST[$i]}"
done
echo

# Ask for image file
read -p "Enter the number of the image you want to use: " IMG_NUM
if ! [[ "$IMG_NUM" =~ ^[0-9]+$ ]] || [ "$IMG_NUM" -lt 1 ] || [ "$IMG_NUM" -gt "${#IMG_LIST[@]}" ]; then
    echo "Invalid selection. Exiting."
    exit 1
fi
IMG_FILE="${IMG_LIST[$((IMG_NUM-1))]}"
IMG_PATH="$IMG_FOLDER/$IMG_FILE"

# Ask for VMID
read -p "Enter the VMID of the VM you want to attach this image to: " VMID

# List block storage options
echo
echo "Available block storage:"
mapfile -t STORAGE_LIST < <(pvesm status | awk '$2=="lvm" || $2=="lvmthin" || $2=="zfs" {print $1" "$2}')
for i in "${!STORAGE_LIST[@]}"; do
    NAME=$(echo "${STORAGE_LIST[$i]}" | awk '{print $1}')
    TYPE=$(echo "${STORAGE_LIST[$i]}" | awk '{print $2}')
    echo "$((i+1)): $NAME ($TYPE)"
done
echo

read -p "Enter the number of the storage to import to: " STORAGE_NUM
if ! [[ "$STORAGE_NUM" =~ ^[0-9]+$ ]] || [ "$STORAGE_NUM" -lt 1 ] || [ "$STORAGE_NUM" -gt "${#STORAGE_LIST[@]}" ]; then
    echo "Invalid selection. Exiting."
    exit 1
fi
STORAGE=$(echo "${STORAGE_LIST[$((STORAGE_NUM-1))]}" | awk '{print $1}')

# Import disk
echo "Importing disk..."
qm importdisk "$VMID" "$IMG_PATH" "$STORAGE"
if [ $? -ne 0 ]; then
    echo "Import failed. Exiting."
    exit 1
fi

# Attach disk as SCSI VirtIO
echo "Attaching disk..."
qm set "$VMID" --scsihw virtio-scsi-pci --scsi0 "${STORAGE}:vm-${VMID}-disk-0"

# Ask for disk resize
read -p "Enter new disk size (example: 20G or 20): " RAW_DISK_SIZE
DISK_SIZE=$(echo "$RAW_DISK_SIZE" | sed -E 's/([0-9]+)([gG])?/\1G/')
echo "Resizing disk to $DISK_SIZE..."
qm resize "$VMID" scsi0 "$DISK_SIZE"

# Add Cloud-Init drive if not already present
if ! qm config "$VMID" | grep -q ide2; then
    echo "Adding Cloud-Init drive..."
    qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
fi

qm set "$VMID" --boot c --bootdisk scsi0

# Auto Cloud-Init settings
echo
echo "Cloud-Init configuration (leave blank for defaults)"
read -p "Username [default: user]: " CI_USER
read -p "Password [default: pass]: " CI_PASS
read -p "IP address (blank for DHCP): " CI_IP
read -p "CIDR (default 24 if IP given): " CI_CIDR

CI_USER=${CI_USER:-user}
CI_PASS=${CI_PASS:-pass}

if [ -z "$CI_IP" ]; then
    qm set "$VMID" --ipconfig0 "ip=dhcp"
else
    CI_CIDR=${CI_CIDR:-24}
    qm set "$VMID" --ipconfig0 "ip=${CI_IP}/${CI_CIDR}"
fi

qm set "$VMID" --ciuser "$CI_USER" --cipassword "$CI_PASS"

echo "Done! Disk resized to $DISK_SIZE and Cloud-Init configured."
echo "You can now boot the VM."
