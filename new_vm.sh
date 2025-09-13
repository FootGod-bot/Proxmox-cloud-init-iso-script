#!/bin/bash

# -----------------------------
# CONFIGURATION
# -----------------------------

ISO_FOLDER="/var/lib/vz/template/cloud-init"
mkdir -p "$ISO_FOLDER"

# Built-in defaults (cannot be removed)
declare -A BUILTIN_ISOS
BUILTIN_ISOS["Ubuntu 24.04 Cloud"]="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
BUILTIN_ISOS["Debian 12 Cloud"]="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"

# Default cloud-init credentials
DEFAULT_USER="user"
DEFAULT_PASS="pass"

# -----------------------------
# PARSE FLAGS
# -----------------------------
ACTION=""
DOWNLOAD_URL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -add)
            ACTION="add"
            DOWNLOAD_URL="$2"
            shift 2
            ;;
        -rm)
            ACTION="rm"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# -----------------------------
# HANDLE ADD
# -----------------------------
if [[ "$ACTION" == "add" ]]; then
    if [[ -z "$DOWNLOAD_URL" ]]; then
        read -p "Enter download URL: " DOWNLOAD_URL
    fi
    read -p "Enter ISO name: " ISO_NAME
    JSON_FILE="$ISO_FOLDER/$ISO_NAME.json"

    cat > "$JSON_FILE" <<EOF
{
  "name": "$ISO_NAME",
  "url": "$DOWNLOAD_URL"
}
EOF

    echo "ISO '$ISO_NAME' added successfully."
    exit 0
fi

# -----------------------------
# HANDLE REMOVE
# -----------------------------
if [[ "$ACTION" == "rm" ]]; then
    mapfile -t USER_JSONS < <(ls "$ISO_FOLDER"/*.json 2>/dev/null)
    if [ "${#USER_JSONS[@]}" -eq 0 ]; then
        echo "No user-added ISOs to remove."
        exit 0
    fi
    echo "Available user-added ISOs to remove:"
    for i in "${!USER_JSONS[@]}"; do
        ISO_NAME=$(jq -r .name "${USER_JSONS[$i]}")
        echo "$((i+1)): $ISO_NAME"
    done
    read -p "Enter the number to remove: " REMOVE_NUM
    FILE_TO_REMOVE="${USER_JSONS[$((REMOVE_NUM-1))]}"
    rm -f "$FILE_TO_REMOVE"
    echo "ISO removed successfully."
    exit 0
fi

# -----------------------------
# BUILD ISO SELECTION LIST
# -----------------------------
echo "Available ISOs:"
INDEX=1
declare -A ISO_MAP
declare -A URL_MAP

# Built-ins
for iso_name in "${!BUILTIN_ISOS[@]}"; do
    echo "$INDEX: $iso_name (built-in)"
    ISO_MAP[$INDEX]="$iso_name"
    URL_MAP[$INDEX]="${BUILTIN_ISOS[$iso_name]}"
    ((INDEX++))
done

# User-added
mapfile -t USER_JSONS < <(ls "$ISO_FOLDER"/*.json 2>/dev/null)
for json_file in "${USER_JSONS[@]}"; do
    ISO_NAME=$(jq -r .name "$json_file")
    ISO_URL=$(jq -r .url "$json_file")
    echo "$INDEX: $ISO_NAME (custom)"
    ISO_MAP[$INDEX]="$ISO_NAME"
    URL_MAP[$INDEX]="$ISO_URL"
    ((INDEX++))
done

# -----------------------------
# SELECT ISO
# -----------------------------
read -p "Enter the number of the ISO to use: " ISO_NUM
ISO_NAME="${ISO_MAP[$ISO_NUM]}"
ISO_URL="${URL_MAP[$ISO_NUM]}"

if [[ -z "$ISO_NAME" || -z "$ISO_URL" ]]; then
    echo "Invalid selection. Exiting."
    exit 1
fi

# -----------------------------
# DOWNLOAD ISO TEMPORARILY
# -----------------------------
TMP_ISO=$(mktemp)
echo "Downloading ISO '$ISO_NAME'..."
wget -O "$TMP_ISO" "$ISO_URL"
if [[ $? -ne 0 ]]; then
    echo "Download failed. Exiting."
    exit 1
fi

# -----------------------------
# VM IMPORT + CLOUD-INIT
# -----------------------------
echo
read -p "Enter the VMID of the VM you want to attach this image to: " VMID
if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
    echo "Invalid VMID. Exiting."
    rm -f "$TMP_ISO"
    exit 1
fi

# List storage options
echo "Available block storage:"
mapfile -t STORAGE_LIST < <(pvesm status | awk '$2=="lvm" || $2=="lvmthin" || $2=="zfs" {print $1}')
if [ "${#STORAGE_LIST[@]}" -eq 0 ]; then
    echo "No supported storage found. Exiting."
    rm -f "$TMP_ISO"
    exit 1
fi
for i in "${!STORAGE_LIST[@]}"; do
    echo "$((i+1)): ${STORAGE_LIST[$i]}"
done
read -p "Enter the number of the storage to import to: " STORAGE_NUM
STORAGE="${STORAGE_LIST[$((STORAGE_NUM-1))]}"

# Import disk
echo "Importing disk..."
qm importdisk "$VMID" "$TMP_ISO" "$STORAGE"

# Attach disk
qm set "$VMID" --scsihw virtio-scsi-pci --scsi0 "${STORAGE}:vm-${VMID}-disk-0"

# Disk resize
read -p "Enter new disk size (example 20G): " RAW_DISK_SIZE
DISK_SIZE=$(echo "$RAW_DISK_SIZE" | sed -E 's/([0-9]+)([gG])?/\1G/')
qm resize "$VMID" scsi0 "$DISK_SIZE"

# Cloud-init drive
if ! qm config "$VMID" | grep -q cloudinit; then
    qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
fi
qm set "$VMID" --boot c --bootdisk scsi0

# Cloud-init settings
CI_USER="$DEFAULT_USER"
CI_PASS="$DEFAULT_PASS"
read -p "Username [default: $CI_USER]: " INPUT_USER
CI_USER=${INPUT_USER:-$CI_USER}
while true; do
    read -s -p "Password [default: $CI_PASS]: " INPUT_PASS
    echo
    read -s -p "Confirm password: " INPUT_PASS2
    echo
    INPUT_PASS=${INPUT_PASS:-$CI_PASS}
    INPUT_PASS2=${INPUT_PASS2:-$INPUT_PASS}
    if [[ "$INPUT_PASS" == "$INPUT_PASS2" ]]; then
        CI_PASS="$INPUT_PASS"
        break
    else
        echo "Passwords do not match, try again."
    fi
done

read -p "IP address (leave blank for DHCP): " CI_IP
read -p "CIDR (default 24 if IP given): " CI_CIDR
CI_CIDR=${CI_CIDR:-24}
if [[ -z "$CI_IP" ]]; then
    qm set "$VMID" --ipconfig0 "ip=dhcp"
else
    qm set "$VMID" --ipconfig0 "ip=${CI_IP}/${CI_CIDR}"
fi

qm set "$VMID" --ciuser "$CI_USER" --cipassword "$CI_PASS"

# -----------------------------
# CLEAN UP
# -----------------------------
rm -f "$TMP_ISO"
echo "Temporary ISO removed."

echo "----------------------------------------"
echo "Done! VM $VMID is ready."
echo "- Disk: $DISK_SIZE"
echo "- Cloud-Init: username=$CI_USER, password=********, IP=${CI_IP:-dhcp}"
echo "You can now boot the VM in Proxmox."
