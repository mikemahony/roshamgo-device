#!/bin/bash
set -euo pipefail

GITHUB_RAW="https://raw.githubusercontent.com/mikemahony/roshamgo-device/main/deploy"
INSTALL_DIR="/home/roshambo"

echo "=== RoShamGo Pi Setup ==="

# Install dependencies first (need curl for downloads)
echo "Installing runtime libraries..."
sudo apt-get update
sudo apt-get install -y libdrm2 libgbm1 libegl1 libgles2 curl jq netcat-openbsd \
    xserver-xorg xinit x11-xserver-utils

# Download scripts from GitHub to /tmp first, then move into place
echo "Downloading scripts from GitHub..."
curl -sfL -o /tmp/roshamgo-startup.sh "${GITHUB_RAW}/roshamgo-startup.sh" || { echo "ERROR: Failed to download roshamgo-startup.sh"; exit 1; }
curl -sfL -o /tmp/roshamgo.service "${GITHUB_RAW}/roshamgo.service" || { echo "ERROR: Failed to download roshamgo.service"; exit 1; }

sudo mkdir -p ${INSTALL_DIR}
sudo mv /tmp/roshamgo-startup.sh ${INSTALL_DIR}/roshamgo-startup.sh
sudo chmod +x ${INSTALL_DIR}/roshamgo-startup.sh
id roshambo &>/dev/null && sudo chown roshambo:roshambo ${INSTALL_DIR}/roshamgo-startup.sh
echo "  Installed roshamgo-startup.sh"

sudo mv /tmp/roshamgo.service /etc/systemd/system/roshamgo.service
echo "  Installed roshamgo.service"

# Boot to multi-user (no desktop)
echo "Setting default target to multi-user..."
sudo systemctl set-default multi-user.target

# Ensure DRM driver is enabled
if ! grep -q "dtoverlay=vc4-kms-v3d" /boot/firmware/config.txt; then
    echo "Enabling vc4-kms-v3d overlay..."
    echo "dtoverlay=vc4-kms-v3d" | sudo tee -a /boot/firmware/config.txt
fi

# Enable PWM overlay for LED (GPIO 18)
if ! grep -q "dtoverlay=pwm,pin=18,func=2" /boot/firmware/config.txt; then
    echo "Enabling PWM overlay on pin 18..."
    echo "dtoverlay=pwm,pin=18,func=2" | sudo tee -a /boot/firmware/config.txt
fi

# Enable systemd service
echo "Enabling systemd service..."
sudo systemctl daemon-reload
sudo systemctl enable roshamgo

# Ensure network-online.target works
echo "Enabling network wait service..."
sudo systemctl enable NetworkManager-wait-online.service 2>/dev/null || \
sudo systemctl enable systemd-networkd-wait-online.service 2>/dev/null || \
echo "Warning: Could not enable network wait service."

echo ""
echo "=== Setup complete! Reboot to apply changes ==="
echo "After reboot, the app will auto-update from GitHub and start."
echo "Check logs: journalctl -u roshamgo -f"
echo "Restart remotely: curl -d 'restart' http://<pi-ip>:3000/"
