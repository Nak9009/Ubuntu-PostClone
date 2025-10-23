#!/bin/bash
set -e

############################
# CONFIG
############################
NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"
NETWORK_FLAG="/etc/.network-configured"
DISK="/dev/sda"
PART_NUM=3  # sda3
LV_PATH=$(findmnt -n -o SOURCE /)
VG_NAME=$(lvs --noheadings -o vg_name "$LV_PATH" | xargs)

############################
# 1️⃣ Resize sda3 partition (no cloud-guest-utils)
############################
echo "🔹 Resizing partition $DISK$PART_NUM..."
sudo parted $DISK resizepart $PART_NUM 100% <<< "Yes"
echo "✅ Partition resized."

############################
# 2️⃣ Resize PV, LV, filesystem
############################
echo "🔹 Resizing LVM physical volume..."
sudo pvresize "${DISK}${PART_NUM}"
sudo pvdisplay

echo "🔹 Extending logical volume..."
sudo lvextend -l +100%FREE "$LV_PATH"
sudo lvdisplay

echo "🔹 Resizing filesystem..."
FS_TYPE=$(df -T / | tail -1 | awk '{print $2}')
if [[ "$FS_TYPE" == "xfs" ]]; then
    sudo xfs_growfs /
else
    sudo resize2fs "$LV_PATH"
fi
echo "✅ LVM and filesystem resized."

############################
# 3️⃣ Update MOTD
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
# 4️⃣ Prompt network (first clone only)
############################
if [[ ! -f "$NETWORK_FLAG" ]]; then
    echo "⚡ First clone detected. Enter network configuration:"

    read -p "Enter IP (e.g., 192.168.1.101/24): " NEW_IP
    read -p "Enter Gateway (e.g., 192.168.1.1): " GATEWAY
    read -p "Enter hostname: " NEW_HOSTNAME

    MAIN_IFACE=$(ls /sys/class/net | grep -v lo | head -1)
    cp "$NETPLAN_FILE" "$NETPLAN_FILE.bak.$(date +%F-%T)"

    # Extract existing nameservers
    NAMESERVERS=$(grep -Po '(?<=addresses: \[).*(?=\])' "$NETPLAN_FILE")

    # Write updated netplan
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

    netplan apply
    hostnamectl set-hostname "$NEW_HOSTNAME"

    touch "$NETWORK_FLAG"
    echo "✅ Network configured with IP $NEW_IP and hostname $NEW_HOSTNAME"
else
    echo "ℹ️ Network already configured. Skipping."
fi

############################
# 5️⃣ Disable systemd service (one-time)
############################
SYSTEMD_SERVICE="post-clone-setup.service"
if systemctl is-enabled "$SYSTEMD_SERVICE" >/dev/null 2>&1; then
    systemctl disable "$SYSTEMD_SERVICE"
    echo "✅ Systemd service disabled."
fi

echo "🎉 Post-clone setup complete!"
