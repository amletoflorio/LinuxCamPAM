#!/bin/bash
set -e

# Build
echo "Building..."
mkdir -p build
cd build
cmake ..
make -j$(nproc)

# Install Binaries
echo "Installing Binaries..."
# Stop service to release lock
if command -v systemctl &> /dev/null && [ -d /run/systemd/system ]; then
    sudo systemctl stop linuxcampam || true
fi
sudo cp --remove-destination linuxcampamd /usr/local/bin/
sudo cp --remove-destination linuxcampam /usr/local/bin/
sudo cp --remove-destination ../scripts/detect_opencl.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/detect_opencl.sh

# Install PAM Module

# Detect Multiarch path (e.g., x86_64-linux-gnu, i386-linux-gnu, aarch64-linux-gnu)
if command -v dpkg-architecture &> /dev/null; then
    LIB_ARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
else
    LIB_ARCH=$(uname -m)-linux-gnu
fi

echo "Detected Architecture Path: $LIB_ARCH"
sudo cp --remove-destination pam_linuxcampam.so /lib/$LIB_ARCH/security/pam_linuxcampam.so

# Install PAM Profile (Safe Method)
echo "Installing PAM Profile..."
sudo mkdir -p /usr/share/pam-configs
sudo cp ../config/linuxcampam_pam_profile /usr/share/pam-configs/linuxcampam

# Update PAM (Automatic Backup & Activate)
echo "Backing up & Updating PAM..."
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
for file in common-auth common-account common-password common-session; do
    if [ -f "/etc/pam.d/$file" ]; then
        sudo cp "/etc/pam.d/$file" "/etc/pam.d/$file.$TIMESTAMP.bak"
    fi
done

# Non-interactive update via profile
sudo pam-auth-update --package --enable linuxcampam

# Config & Models
echo "Setting up Config & Models..."
sudo mkdir -p /etc/linuxcampam/users
sudo mkdir -p /usr/share/linuxcampam/models
sudo mkdir -p /var/log/linuxcampam

if [ -f /etc/linuxcampam/config.ini ]; then
    echo "Backing up existing config..."
    sudo cp /etc/linuxcampam/config.ini /etc/linuxcampam/config.ini.bak
fi
sudo cp ../config/config.ini /etc/linuxcampam/

# Run Smart Config Setup
echo "Detecting cameras and updating config..."
sudo ../scripts/setup_config.sh

# Download Models (from Hugging Face)
MODEL_DIR="/usr/share/linuxcampam/models"
sudo mkdir -p "$MODEL_DIR"
YUNET_URL="https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx"
SFACE_URL="https://huggingface.co/opencv/face_recognition_sface/resolve/main/face_recognition_sface_2021dec.onnx"

if [ ! -f "$MODEL_DIR/face_detection_yunet_2023mar.onnx" ]; then
    sudo wget -O "$MODEL_DIR/face_detection_yunet_2023mar.onnx" "$YUNET_URL"
fi

if [ ! -f "$MODEL_DIR/face_recognition_sface_2021dec.onnx" ]; then
    sudo wget -O "$MODEL_DIR/face_recognition_sface_2021dec.onnx" "$SFACE_URL"
fi

# Service
echo "Installing Service..."
if [ -d /run/systemd/system ]; then
    sudo cp ../scripts/linuxcampam.service /etc/systemd/system/
    sudo systemctl daemon-reload
    # sudo systemctl enable --now linuxcampam.service
    echo "Done! Run 'sudo systemctl start linuxcampam' to start."
else
    echo "Non-systemd init detected. Please install init script manually."
    echo "Service binary installed to /usr/local/bin/linuxcampamd"
fi

# Install unlockKeyring.sh
echo "Installing unlockKeyring.sh..."
sudo cp ../scripts/unlockKeyring.sh /usr/local/bin/unlockKeyring.sh
sudo chmod +x /usr/local/bin/unlockKeyring.sh

# Install setup_keyring.sh as a standalone command
sudo cp ../scripts/setup_keyring.sh /usr/local/bin/linuxcampam-setup-keyring
sudo chmod +x /usr/local/bin/linuxcampam-setup-keyring

# ── GNOME Keyring Unlock Wizard ──────────────────────────────────────────────
echo ""
echo "====================================================================="
echo " GNOME Keyring Auto-Unlock (Optional)"
echo "====================================================================="
echo ""
echo " LinuxCamPAM can automatically unlock your GNOME Keyring on face login"
echo " using a TPM-encrypted password — no password prompt after face auth."
echo ""

# Only offer interactively
if [ -t 0 ]; then
    read -p " Would you like to set this up now? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        # Drop sudo, run as the real user
        REAL_USER="${SUDO_USER:-$USER}"
        sudo -u "$REAL_USER" bash /usr/local/bin/linuxcampam-setup-keyring
    else
        echo " Skipped. You can set it up later by running:"
        echo "   linuxcampam-setup-keyring"
        echo ""
    fi
else
    echo " Non-interactive mode. Run 'linuxcampam-setup-keyring' later to configure keyring unlock."
    echo ""
fi
