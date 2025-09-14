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
# FUNCTIONS
# -----------------------------

cleanup_on_exit() {
    echo "Cleaning up temporary files..."
    for tmp in "$ISO_FOLDER"/*/*.tmp; do
        [[ -f "$tmp" ]] && rm -f "$tmp"
    done
    exit 1
}
trap cleanup_on_exit INT

list_custom_isos() {
    local start=$1
    local i=$start
    CUSTOM_JSONS=()
    for json in "$ISO_FOLDER"/*.json; do
        [[ -f "$json" ]] || continue
        name=$(jq -r '.name' "$json")
        echo "$i: $name (custom)"
        CUSTOM_JSONS+=("$json")
        ((i++))
    done
    return $i
}

# -----------------------------
# HANDLE -ADD / -REMOVE
# -----------------------------

if [[ "$1" == "-add" ]]; then
    DOWNLOAD_URL="$2"
    if [[ -z "$DOWNLOAD_URL" ]]; then
        echo "Usage: $0 -add <url>"
        exit 1
    fi
    read -p "Enter ISO name: " ISO_NAME
    ISO_DIR="$ISO_FOLDER/$ISO_NAME"
    mkdir -p "$ISO_DIR"
    JSON_FILE="$ISO_FOLDER/$ISO_NAME.json"
    cat > "$JSON_FILE" <<EOF
{
  "name": "$ISO_NAME",
  "url": "$DOWNLOAD_URL"
}
EOF
    echo "ISO '$ISO_NAME' added successfully."
    exit 0
elif [[ "$1" == "-remove" ]]; then
    echo "Available custom ISOs:"
    CUSTOM_JSONS=()
    i=1
    for json in "$ISO_FOLDER"/*.json; do
        [[ -f "$json" ]] || continue
        name=$(jq -r '.name' "$json")
        echo "$i: $name (custom)"
        CUSTOM_JSONS+=("$json")
        ((i++))
    done
    if [[ ${#CUSTOM_JSONS[@]} -eq 0 ]]; then
        echo "No custom ISOs found."
        exit 0
    fi
    read -p "Enter the number of the custom ISO to remove: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#CUSTOM_JSONS[@]} )); then
        echo "Invalid selection."
        exit 1
    fi
    JSON_FILE="${CUSTOM_JSONS[$((choice-1))]}"
    ISO_NAME=$(jq -r '.name' "$JSON_FILE")
    ISO_DIR="$ISO_FOLDER/$ISO_NAME"
    echo "Removing custom ISO '$ISO_NAME'..."
    rm -rf "$JSON_FILE" "$ISO_DIR"
    echo "Removed successfully."
    exit 0
fi

# -----------------------------
# BUILD ISO SELECTION LIST
# -----------------------------

echo "Available ISOs:"
INDEX=1
declare -A ISO_MAP
for name in "${!BUILTIN_ISOS[@]}"; do
    echo "$INDEX: $name (built-in)"
    ISO_MAP[$INDEX]="$name|builtin"
    ((INDEX++))
done
CUSTOM_JSONS=()
list_custom_isos "$INDEX"
for idx in "${!CUSTOM_JSONS[@]}"; do
    ISO_MAP[$((INDEX+idx))]="${CUSTOM_JSONS[$idx]}|custom"
done

read -p "Enter the number of the ISO to use: " ISO_NUM
ENTRY="${ISO_MAP[$ISO_NUM]}"
if [[ -z "$ENTRY" ]]; then
    echo "Invalid selection. Exiting."
    exit 1
fi

ISO_URL=""
ISO_NAME=""
TYPE=$(echo "$ENTRY" | cut -d"|" -f2)
if [[ "$TYPE" == "builtin" ]]; then
    ISO_NAME=$(echo "$ENTRY" | cut -d"|" -f1)
    ISO_URL="${BUILTIN_ISOS[$ISO_NAME]}"
    echo "Selected built-in ISO: $ISO_NAME"
elif [[ "$TYPE" == "custom" ]]; then
    JSON_FILE=$(echo "$ENTRY" | cut -d"|" -f1)
    ISO_NAME=$(jq -r '.name' "$JSON_FILE")
    ISO_URL=$(jq -r '.url' "$JSON_FILE")
    echo "Selected custom ISO: $ISO_NAME"
else
    echo "Invalid selection type. Exiting."
    exit 1
fi

# -----------------------------
# DOWNLOAD OR REUSE ISO
# -----------------------------

ISO_DIR="$ISO_FOLDER/$ISO_NAME"
mkdir -p "$ISO_DIR"
ISO_FILE="$ISO_DIR/${ISO_NAME}.qcow2"

if [[ ! -f "$ISO_FILE" ]]; then
    echo "Downloading ISO for '$ISO_NAME'..."
    wget -O "$ISO_FILE" "$ISO_URL"
    if [[ $? -ne 0 ]]; then
        echo "Download failed. Exiting."
        rm -f "$ISO_FILE"
        exit 1
    fi
else
    echo "Using cached ISO: $ISO_FILE"
fi

# -----------------------------
# VM IMPORT + CLOUD-INIT
# -----------------------------

echo
read -p "Enter the VMID of the VM you want to attach this image to: " VMID
if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
    echo "Invalid VMID. Exiting."
    exit 1
fi

# List storage options
echo "Available block storage:"
mapfile -t STORAGE_LIST < <(pvesm status | awk '$2=="lvm" || $2=="lvmthin" || $2=="zfs" {print $1}')
if [ "${#STORAGE_LIST[@]}" -eq 0 ]; then
    echo "No supported storage found. Exiting."
    exit 1
fi
for i in "${!STORAGE_LIST[@]}"; do
    echo "$((i+1)): ${STORAGE_LIST[$i]}"
done
read -p "Enter the number of the storage to import to: " STORAGE_NUM
STORAGE="${STORAGE_LIST[$((STORAGE_NUM-1))]}"

# Import disk
echo "Importing disk..."
qm importdisk "$VMID" "$ISO_FILE" "$STORAGE"

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
# DONE
# -----------------------------

echo "----------------------------------------"
echo "Done! VM $VMID is ready."
echo "- Disk: $DISK_SIZE"
echo "- Cloud-Init: username=$CI_USER, password=********, IP=${CI_IP:-dhcp}"
echo "You can now boot the VM in Proxmox."
