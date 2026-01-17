#!/bin/bash

# -----------------------------
# CONFIGURATION
# -----------------------------

ISO_FOLDER="/var/lib/vz/template/cloud-init"
mkdir -p "$ISO_FOLDER"

declare -A BUILTIN_ISOS
BUILTIN_ISOS["Ubuntu 24.04 Cloud"]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
BUILTIN_ISOS["Debian 12 Cloud"]="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"

DEFAULT_USER="root"
DEFAULT_PASS="pass"

# -----------------------------
# FUNCTIONS
# -----------------------------

cleanup_on_exit() {
    for tmp in "$ISO_FOLDER"/*/*.tmp; do
        [[ -f "$tmp" ]] && rm -f "$tmp"
    done
    exit 1
}
trap cleanup_on_exit INT

list_custom_isos() {
    local start_index=$1
    local i=$start_index
    CUSTOM_JSONS=()
    for json in "$ISO_FOLDER"/*.json; do
        [[ -f "$json" ]] || continue
        name=$(jq -r '.name' "$json")
        echo "$i: $name (custom)"
        CUSTOM_JSONS+=("$json")
        ((i++))
    done
    echo "$i: Create new custom ISO"
    CREATE_NEW_INDEX=$i
}

# -----------------------------
# INPUT COLLECTION
# -----------------------------

echo "Available ISOs:"
INDEX=1
declare -A ISO_MAP
for name in "${!BUILTIN_ISOS[@]}"; do
    echo "$INDEX: $name (built-in)"
    ISO_MAP[$INDEX]="$name|builtin"
    ((INDEX++))
done

list_custom_isos "$INDEX"
for idx in "${!CUSTOM_JSONS[@]}"; do
    ISO_MAP[$((INDEX+idx))]="${CUSTOM_JSONS[$idx]}|custom"
done

read -p "Enter the number of the ISO to use: " ISO_NUM

# Handle custom ISO creation
if [[ "$ISO_NUM" -eq "$CREATE_NEW_INDEX" ]]; then
    read -p "Enter ISO name: " ISO_NAME
    [[ -z "$ISO_NAME" ]] && { echo "Name cannot be empty."; exit 1; }
    read -p "Enter ISO URL: " ISO_URL
    [[ -z "$ISO_URL" ]] && { echo "URL cannot be empty."; exit 1; }
    ISO_DIR="$ISO_FOLDER/$ISO_NAME"
    mkdir -p "$ISO_DIR"
    JSON_FILE="$ISO_FOLDER/$ISO_NAME.json"
    cat > "$JSON_FILE" <<EOF
{
  "name": "$ISO_NAME",
  "url": "$ISO_URL"
}
EOF
else
    ENTRY="${ISO_MAP[$ISO_NUM]}"
    [[ -z "$ENTRY" ]] && { echo "Invalid selection."; exit 1; }
    TYPE=$(echo "$ENTRY" | cut -d"|" -f2)
    if [[ "$TYPE" == "builtin" ]]; then
        ISO_NAME=$(echo "$ENTRY" | cut -d"|" -f1)
        ISO_URL="${BUILTIN_ISOS[$ISO_NAME]}"
    elif [[ "$TYPE" == "custom" ]]; then
        JSON_FILE=$(echo "$ENTRY" | cut -d"|" -f1)
        ISO_NAME=$(jq -r '.name' "$JSON_FILE")
        ISO_URL=$(jq -r '.url' "$JSON_FILE")
    else
        echo "Invalid selection type."; exit 1
    fi
fi

read -p "Enter VMID: " VMID
[[ ! "$VMID" =~ ^[0-9]+$ ]] && { echo "Invalid VMID."; exit 1; }

echo "Available block storage:"
mapfile -t STORAGE_LIST < <(pvesm status | awk '$2=="lvm" || $2=="lvmthin" || $2=="zfs" {print $1}')
[[ "${#STORAGE_LIST[@]}" -eq 0 ]] && { echo "No supported storage found."; exit 1; }
for i in "${!STORAGE_LIST[@]}"; do echo "$((i+1)): ${STORAGE_LIST[$i]}"; done
read -p "Enter the number of the storage to import to: " STORAGE_NUM
STORAGE="${STORAGE_LIST[$((STORAGE_NUM-1))]}"

read -p "Enter disk size (example 20G): " RAW_DISK_SIZE
DISK_SIZE=$(echo "$RAW_DISK_SIZE" | sed -E 's/([0-9]+)([gG])?/\1G/')

read -p "Username [default: $DEFAULT_USER]: " CI_USER
CI_USER=${CI_USER:-$DEFAULT_USER}

read -s -p "Password [default: $DEFAULT_PASS]: " INPUT_PASS
echo
read -s -p "Confirm password: " INPUT_PASS2
echo
if [[ -z "$INPUT_PASS" ]]; then
    CI_PASS="$DEFAULT_PASS"
elif [[ "$INPUT_PASS" == "$INPUT_PASS2" ]]; then
    CI_PASS="$INPUT_PASS"
else
    echo "Passwords do not match, using default."
    CI_PASS="$DEFAULT_PASS"
fi

read -p "IP address (leave blank for DHCP): " CI_IP
if [[ -n "$CI_IP" ]]; then
    read -p "CIDR (default 24): " CI_CIDR
    CI_CIDR=${CI_CIDR:-24}
    HOST_GW=$(ip route | awk '/default/ {print $3; exit}')
fi


UPDATE_PACKAGES=${UPDATE_PACKAGES:-n}

ISO_DIR="$ISO_FOLDER/$ISO_NAME"
mkdir -p "$ISO_DIR"
ISO_FILE="$ISO_DIR/${ISO_NAME}.qcow2"

# -----------------------------
# STEP-BY-STEP AUTOMATED PROCESS
# -----------------------------

echo "Starting VM setup..."

# 1. Download ISO
echo "Downloading ISO..."
wget -O "$ISO_FILE" "$ISO_URL"

# 2. Import disk
echo "Importing disk..."
qm importdisk "$VMID" "$ISO_FILE" "$STORAGE"

# 3. Attach disk
echo "Attaching disk..."
qm set "$VMID" --scsihw virtio-scsi-pci --scsi0 "${STORAGE}:vm-${VMID}-disk-0"

# 4. Resize disk
echo "Resizing disk..."
qm resize "$VMID" scsi0 "$DISK_SIZE"

# 5. Cloud-init drive
if ! qm config "$VMID" | grep -q cloudinit; then
    qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
fi
qm set "$VMID" --boot c --bootdisk scsi0
qm set "$VMID" --ciuser "$CI_USER" --cipassword "$CI_PASS"
if [[ -n "$CI_IP" ]]; then
    qm set "$VMID" --ipconfig0 "ip=${CI_IP}/${CI_CIDR},gw=${HOST_GW}"
else
    qm set "$VMID" --ipconfig0 "ip=dhcp"
fi

# 6. Optional package update flag (stored for first boot scripts)
if [[ "$UPDATE_PACKAGES" =~ ^[yY]$ ]]; then
    echo "Package update requested for first boot." > "$ISO_FOLDER/$ISO_NAME-update-flag.txt"
fi

# 7. Cleanup ISO
rm -f "$ISO_FILE"

echo "----------------------------------------"
echo "VM $VMID setup complete."
echo "- Disk: $DISK_SIZE"
echo "- Cloud-Init: username=$CI_USER, password=********, IP=${CI_IP:-dhcp}"
echo "- Package update on first boot: $([[ "$UPDATE_PACKAGES" =~ ^[yY]$ ]] && echo yes || echo no)"
echo "You can now boot the VM in Proxmox."
