#!/bin/bash
set -e

# Basic Bunny directory structure
mkdir -p /bunny/mnt
mkdir -p /bunny/storage
mkdir -p /bunny/bin

# Install dependencies for current Debian/Raspberry Pi OS
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y \
    isc-dhcp-server \
    python3 \
    python3-rpyc \
    gcc \
    dosfstools \
    rsync

# Build helper binaries used by rspiducky
cd /bunny/src/rspiducky

gcc usleep.c -o /bunny/bin/usleep
chmod 755 /bunny/bin/usleep

gcc hid-gadget-test.c -o /bunny/bin/keyboardtype
chmod 755 /bunny/bin/keyboardtype

chmod +x duckpi.sh

# Create mass-storage backing file if it does not already exist
if [ ! -f /bunny/storage/system.img ]; then
    dd if=/dev/zero of=/bunny/storage/system.img bs=1M count=128
    mkfs.fat /bunny/storage/system.img
    fatlabel /bunny/storage/system.img BUNNY
fi

# Mount the storage image if not already mounted
mkdir -p /bunny/mnt
if ! mountpoint -q /bunny/mnt; then
    mount -o loop /bunny/storage/system.img /bunny/mnt
fi

mkdir -p /bunny/mnt/loot

# Sync payloads if the helper exists
if [ -x /bunny/bin/SYNC_PAYLOADS ]; then
    /bunny/bin/SYNC_PAYLOADS || true
fi

# Clean up marker file quietly
rm -f /bunny/mnt/target_finished

# Ensure gadget-related boot config is present.
# This assumes a Pi OS style layout and a known-good image.
if [ -f /boot/firmware/config.txt ]; then
    BOOT_CONFIG="/boot/firmware/config.txt"
else
    BOOT_CONFIG="/boot/config.txt"
fi

if [ -f /boot/firmware/cmdline.txt ]; then
    CMDLINE_FILE="/boot/firmware/cmdline.txt"
else
    CMDLINE_FILE="/boot/cmdline.txt"
fi

# Remove conflicting OTG host mode if present
sed -i '/^otg_mode=1$/d' "$BOOT_CONFIG"

# Ensure dwc2 overlay exists
if grep -q '^dtoverlay=dwc2' "$BOOT_CONFIG"; then
    sed -i 's/^dtoverlay=dwc2.*/dtoverlay=dwc2/' "$BOOT_CONFIG"
else
    echo 'dtoverlay=dwc2' >> "$BOOT_CONFIG"
fi

# Ensure boot-time gadget module loading exists on the single cmdline line
if ! grep -q 'modules-load=dwc2,g_ether' "$CMDLINE_FILE"; then
    sed -i '1 s#$# modules-load=dwc2,g_ether#' "$CMDLINE_FILE"
fi

# Keep libcomposite listed for later ConfigFS-based gadget use
grep -q -F 'libcomposite' /etc/modules || echo 'libcomposite' >> /etc/modules

# DHCP configuration for Bunny USB networking
touch /etc/dhcp/dhcpd.conf
if ! grep -q "172.16.64.0" /etc/dhcp/dhcpd.conf; then
    cat >> /etc/dhcp/dhcpd.conf <<'EOF'

authoritative;

subnet 172.16.64.0 netmask 255.255.255.0 {
  range 172.16.64.10 172.16.64.12;
  option subnet-mask 255.255.255.0;
  option routers 172.16.64.1;
  option domain-name-servers 172.16.64.1;
}
EOF
fi

# Bind dhcpd to usb0 once that interface exists
if [ -f /etc/default/isc-dhcp-server ]; then
    sed -i 's/^INTERFACESv4=.*/INTERFACESv4="usb0"/' /etc/default/isc-dhcp-server
    grep -q '^INTERFACESv4=' /etc/default/isc-dhcp-server || echo 'INTERFACESv4="usb0"' >> /etc/default/isc-dhcp-server
fi

# Enable launcher service
ln -sf /bunny/etc/systemd/system/bunny-launcher.service /etc/systemd/system/bunny-launcher.service
systemctl daemon-reload
systemctl enable bunny-launcher.service

# Make Bunny commands easy to access
ln -sf /bunny/bin/ATTACKMODE /usr/bin/ATTACKMODE
ln -sf /bunny/bin/LED /usr/bin/LED
ln -sf /bunny/bin/QUACK /usr/bin/QUACK
ln -sf /bunny/bin/SYNC_PAYLOADS /usr/bin/SYNC_PAYLOADS
ln -sf /bunny/bin/WAIT_TARGET /usr/bin/WAIT_TARGET

# Only try to configure/start DHCP if usb0 actually exists
if ip link show usb0 >/dev/null 2>&1; then
    ip addr add 172.16.64.1/24 dev usb0 2>/dev/null || true
    ip link set usb0 up || true
    systemctl restart isc-dhcp-server || true
else
    echo "usb0 not present yet; skipping DHCP start."
    echo "Reboot into a known-good gadget-capable image, then rerun ATTACKMODE."
fi

echo
echo "Setup complete."
echo
echo "If this is a fresh image, reboot now so boot config changes take effect:"
echo "  sudo reboot"
echo
echo "After reboot, verify gadget mode with:"
echo "  ls /sys/class/udc"
echo "  ip link show"
echo
echo "If usb0 exists, bring up DHCP with:"
echo "  sudo ip addr add 172.16.64.1/24 dev usb0 2>/dev/null || true"
echo "  sudo ip link set usb0 up"
echo "  sudo systemctl restart isc-dhcp-server"
