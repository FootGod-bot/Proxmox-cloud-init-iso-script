#!/bin/bash

# ===============================
# Config
# ===============================
ISO_FOLDER="/var/lib/vz/template/cloud-init"
mkdir -p "$ISO_FOLDER"

# Built-in ISOs (hardcoded)
declare -A BUILTIN_ISOS
BUILTIN_ISOS["Ubuntu 24.04 Cloud"]="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
BUILTIN_ISOS["Debian 12 Cloud"]="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"

# ===============================
# Helpers
# ===============================
list_custom_isos() {
    local i=1
    CUSTOM_JSONS=()
    for json in "$ISO_FOLDER"/*.json; do
        [[ -f "$json" ]] || continue
        name=$(jq -r '.name' "$json")
        echo "$i: $name (custom)"
        CUSTOM_JSONS+=("$json")
        ((i++))
    done
}

# ===============================
# Handle -add
# ===============================
if [[ "$1" == "-add" ]]; then
    ISO_URL="$2"
    if [[ -z "$ISO_URL" ]]; then
        echo "Usage: $0 -add <url>"
        exit 1
    fi

    read -p "Enter ISO name: " ISO_NAME
    JSON_FILE="$ISO_FOLDER/$ISO_NAME.json"
    ISO_DIR="$ISO_FOLDER/$ISO_NAME"
    mkdir -p "$ISO_DIR"

    # Save JSON config
    cat > "$JSON_FILE" <<EOF
{
  "name": "$ISO_NAME",
  "url": "$ISO_URL",
  "path": "$ISO_DIR/${ISO_NAME}_tmp.iso"
}
EOF

    echo "ISO '$ISO_NAME' added successfully."
    exit 0
fi

# ===============================
# Handle -remove
# ===============================
if [[ "$1" == "-remove" ]]; then
    echo "Available custom ISOs:"
    list_custom_isos

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

# ===============================
# Default menu (VM creation)
# ===============================
echo "Available ISOs:"
i=1
for name in "${!BUILTIN_ISOS[@]}"; do
    echo "$i: $name (built-in)"
    ((i++))
done

list_custom_isos

read -p "Enter the number of the ISO to use: " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    echo "Invalid selection. Exiting."
    exit 1
fi

# Decide if selection is built-in or custom
total=$(( ${#BUILTIN_ISOS[@]} + ${#CUSTOM_JSONS[@]} ))
if (( choice < 1 || choice > total )); then
    echo "Invalid selection. Exiting."
    exit 1
fi

if (( choice <= ${#BUILTIN_ISOS[@]} )); then
    # Built-in ISO
    name=$(printf "%s\n" "${!BUILTIN_ISOS[@]}" | sed -n "${choice}p")
    url="${BUILTIN_ISOS[$name]}"
    echo "Selected built-in ISO: $name"
    echo "URL: $url"
else
    # Custom ISO
    idx=$((choice - ${#BUILTIN_ISOS[@]} - 1))
    JSON_FILE="${CUSTOM_JSONS[$((choice - ${#BUILTIN_ISOS[@]} - 1))]}"
    if [[ ! -f "$JSON_FILE" ]]; then
        echo "Config file missing for user-added ISO. Exiting."
        exit 1
    fi
    name=$(jq -r '.name' "$JSON_FILE")
    url=$(jq -r '.url' "$JSON_FILE")
    path=$(jq -r '.path' "$JSON_FILE")
    echo "Selected custom ISO: $name"
    echo "URL: $url"
    echo "Temp path: $path"
fi
