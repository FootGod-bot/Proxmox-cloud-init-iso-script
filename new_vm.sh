# -----------------------------
# Parse optional flags
# -----------------------------
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
        *)
            shift
            ;;
    esac
done

DEFAULT_USER=${DEFAULT_USER:-user}
DEFAULT_PASS=${DEFAULT_PASS:-pass}

# -----------------------------
# Cloud-Init settings
# -----------------------------
echo
echo "Cloud-Init configuration (leave blank for defaults)"

# Only prompt if no flag provided
if [ -z "$DEFAULT_USER" ]; then
    read -p "Username [default: user]: " CI_USER
    CI_USER=${CI_USER:-user}
else
    CI_USER="$DEFAULT_USER"
    echo "Using preset username: $CI_USER"
fi

if [ -z "$DEFAULT_PASS" ]; then
    while true; do
        read -s -p "Password [default: pass]: " CI_PASS
        echo
        read -s -p "Confirm password: " CI_PASS2
        echo
        CI_PASS=${CI_PASS:-pass}
        CI_PASS2=${CI_PASS2:-$CI_PASS}
        if [ "$CI_PASS" == "$CI_PASS2" ]; then
            break
        else
            echo "Passwords do not match, try again."
        fi
    done
else
    CI_PASS="$DEFAULT_PASS"
    echo "Using preset password."
fi

read -p "IP address (blank for DHCP): " CI_IP
read -p "CIDR (default 24 if IP given): " CI_CIDR

if [ -z "$CI_IP" ]; then
    qm set "$VMID" --ipconfig0 "ip=dhcp"
else
    CI_CIDR=${CI_CIDR:-24}
    qm set "$VMID" --ipconfig0 "ip=${CI_IP}/${CI_CIDR}"
fi

qm set "$VMID" --ciuser "$CI_USER" --cipassword "$CI_PASS"
