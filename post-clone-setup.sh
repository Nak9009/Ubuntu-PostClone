#!/bin/bash
set -e

NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"
NETWORK_FLAG="/etc/.network-configured"

############################
# 1️⃣ Auto-Resize LVM Root (automatic)
############################
ROOT_DEV=$(findmnt -n -o SOURCE /)

if [[ "$ROOT_DEV" == /dev/mapper/* ]]; then
    LV_PATH="$ROOT_DEV"
    VG_NAME=$(lvs --noheadings -o vg_name "$LV_PATH" | xargs)
    PART=$(pvs --noheadings -o pv_name --select vg_name=$VG_NAME | xargs)
    DISK=$(lsblk -no pkname "$PART" | head -1)
    DISK="/dev/$DISK"

    echo "Resizing LVM..."
    if ! command -v growpart >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y cloud-guest-utils
    fi
    PART_NO=$(lsblk -no partno $PART)
    growpart "$DISK" "$PART_NO" || true
    pvresize "$PART"
    lvextend -l +100%FREE "$LV_PATH" -r
    echo "✅ LVM resized."
fi

############################
# 2️⃣ Update MOTD
############################
TOTAL_DISK=$(df -h / | tail -1 | awk '{print $2}')
USED_DISK=$(df -h / | tail -1 | awk '{print $3}')
AVAIL_DISK=$(df -h / | tail -1 | awk '{print $4}')

INFO_FILE="/etc/update-motd.d/10-disk-info"

cat <<EOF > "$INFO_FILE"
#!/bin/bash
echo ""
echo "==============================="
echo " 🧠 System Info"
echo "==============================="
echo " Disk total : $TOTAL_DISK"
echo " Disk used  : $USED_DISK"
echo " Disk free  : $AVAIL_DISK"
echo "==============================="
echo ""
EOF

chmod +x "$INFO_FILE"
echo "✅ MOTD updated."

############################
# 3️⃣ Prompt Network Config (first clone only)
############################
if [[ ! -f "$NETWORK_FLAG" ]]; then
    echo "⚡ First clone detected. Please enter network configuration:"

    read -p "Enter IP (e.g., 192.168.1.101/24): " NEW_IP
    read -p "Enter Gateway (e.g., 192.168.1.1): " GATEWAY
    read -p "Enter hostname: " NEW_HOSTNAME

    # Detect main interface
    MAIN_IFACE=$(ls /sys/class/net | grep -v lo | head -1)

    # Backup original netplan
    cp "$NETPLAN_FILE" "$NETPLAN_FILE.bak.$(date +%F-%T)"

    # Extract existing nameservers from YAML
    NAMESERVERS=$(grep -Po '(?<=addresses: \[).*(?=\])' "$NETPLAN_FILE")

    # Write new netplan with updated IP/gateway but same nameservers
    cat <<EOF > "$NETPLAN_FILE"
network:
  version: 2
  renderer: networkd
  ethernets:
    $MAIN_IFACE:
      dhcp4: no
      addresses:
        - $NEW_IP
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [$NAMESERVERS]
EOF

    # Apply network and hostname
    netplan apply
    hostnamectl set-hostname "$NEW_HOSTNAME"

    # Mark network as configured
    touch "$NETWORK_FLAG"

    echo "✅ Network configured and hostname set to $NEW_HOSTNAME"
else
    echo "ℹ️ Network already configured. Skipping."
fi

############################
# 4️⃣ Disable service (one-time run)
############################
SYSTEMD_SERVICE="post-clone-setup.service"
if systemctl is-enabled "$SYSTEMD_SERVICE" >/dev/null 2>&1; then
    systemctl disable "$SYSTEMD_SERVICE"
    echo "✅ Systemd service disabled."
fi

echo "🎉 Post-clone setup complete!"
