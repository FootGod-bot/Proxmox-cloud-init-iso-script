#!/bin/bash

# -----------------------------
# Proxmox VM ISO Import + Cloud-Init Setup
# -----------------------------

# -----------------------------
# Parse optional flags
# -----------------------------
ISO_FOLDER="/var/lib/vz/template/cloud-init"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            DEFAULT_USER="$2"
            shift 2
            ;;
        --pass)
            DEFAULT_PASS="$2"
            shift 2
            ;;
        --folder)
            ISO_FOLDER="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# -----------------------------
# Folder with images
# -----------------------------
IMG_FOLDER="$ISO_FOLDER"

# List available ISOs
echo "Available images in $IMG_FOLDER:"
mapfile -t IMG_LIST < <(ls "$IMG_FOLDER" 2>/dev/null)
if [ "${#IMG_LIST[@]}" -eq 0 ]; then
    echo "No ISOs found in $IMG_FOLDER. Exiting."
    exit 1
fi
for i in "${!IMG_LIST[@]}"; do
    echo "$((i+1)): ${IMG_LIST[$i]}"
done
echo

# Select ISO
read -p "Enter the number of the image you want to use: " IMG_NUM
if ! [[ "$IMG_NUM" =~ ^[0-9]+$ ]] || [ "$IMG_NUM" -lt 1 ] || [ "$IMG_NUM" -gt "${#IMG_LIST[@]}" ]; then
    echo "Invalid selection. Exiting."
    exit 1
fi
IMG_FILE="${IMG_LIST[$((IMG_NUM-1))]}"
IMG_PATH="$IMG_FOLDER/$IMG_FILE"

# Ask for VMID
read -p "Enter the VMID of the VM you want to attach this image to: " VMID
if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
    echo "Invalid VMID. Exiting."
    exit 1
fi

# List block storage options
echo
echo "Available block storage:"
mapfile -t STORAGE_LIST < <(pvesm status | awk '$2=="lvm" || $2=="lvmthin" || $2=="zfs" {print $1" "$2}')
if [ "${#STORAGE_LIST[@]}" -eq 0 ]; then
    echo "No supported storage found. Exiting."
    exit 1
fi
for i in "${!STORAGE_LIST[@]}"; do
    NAME=$(echo "${STORAGE_LIST[$i]}" | awk '{print $1}')
    TYPE=$(echo "${STORAGE_LIST[$i]}" | awk '{print $2}')
    echo "$((i+1)): $NAME ($TYPE)"
done
echo

# Select storage
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

# Detect imported disk name automatically
DISK_NAME=$(qm config "$VMID" | awk '/unused/ {print $1}' | head -n1)
if [ -z "$DISK_NAME" ]; then
    echo "Could not detect imported disk. Exiting."
    exit 1
fi

# Attach disk as SCSI VirtIO
echo "Attaching disk $DISK_NAME..."
qm set "$VMID" --scsihw virtio-scsi-pci --scsi0 "${STORAGE}:vm-${VMID}-disk-0"
if [ $? -ne 0 ]; then
    echo "Failed to attach disk. Exiting."
    exit 1
fi

# Ask for disk resize
read -p "Enter new disk size (example: 20G or 20): " RAW_DISK_SIZE
DISK_SIZE=$(echo "$RAW_DISK_SIZE" | sed -E 's/([0-9]+)([gG])?/\1G/')
echo "Resizing disk to $DISK_SIZE..."
qm resize "$VMID" scsi0 "$DISK_SIZE"
if [ $? -ne 0 ]; then
    echo "Disk resize failed. Exiting."
    exit 1
fi

# Add Cloud-Init drive if missing
if ! qm config "$VMID" | grep -q cloudinit; then
    echo "Creating Cloud-Init disk..."
    qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
    if [ $? -ne 0 ]; then
        echo "Failed to create Cloud-Init disk. Exiting."
        exit 1
    fi
fi

qm set "$VMID" --boot c --bootdisk scsi0

# -----------------------------
# Cloud-Init interactive settings (pre-fill from flags)
# -----------------------------
echo
echo "Cloud-Init configuration (leave blank for defaults)"

# Username
read -p "Username [default: ${DEFAULT_USER:-user}]: " CI_USER
CI_USER=${CI_USER:-${DEFAULT_USER:-user}}

# Password with confirmation
while true; do
    read -s -p "Password [default: ${DEFAULT_PASS:-pass}]: " CI_PASS
    echo
    read -s -p "Confirm password: " CI_PASS2
    echo
    CI_PASS=${CI_PASS:-${DEFAULT_PASS:-pass}}
    CI_PASS2=${CI_PASS2:-$CI_PASS}
    if [ "$CI_PASS" == "$CI_PASS2" ]; then
        break
    else
        echo "Passwords do not match, try again."
    fi
done

# IP and CIDR
read -p "IP address (blank for DHCP): " CI_IP
read -p "CIDR (default 24 if IP given): " CI_CIDR

if [ -z "$CI_IP" ]; then
    qm set "$VMID" --ipconfig0 "ip=dhcp"
else
    CI_CIDR=${CI_CIDR:-24}
    qm set "$VMID" --ipconfig0 "ip=${CI_IP}/${CI_CIDR}"
fi

# Apply Cloud-Init credentials
qm set "$VMID" --ciuser "$CI_USER" --cipassword "$CI_PASS"

echo "----------------------------------------"
echo "Done! VM $VMID is ready."
echo "- Disk: $DISK_SIZE"
echo "- Cloud-Init: username=$CI_USER, password=********, IP=${CI_IP:-dhcp}"
echo "You can now boot the VM in Proxmox."
