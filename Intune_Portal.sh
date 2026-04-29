#!/usr/bin/env bash

set -euo pipefail

echo "================================="
echo "Installing Intune Portal (Linux)"
echo "================================="

# Step 1 - Install required dependencies
echo "[Step 1] Updating system and installing dependencies..."
apt update
apt install -y curl gpg lsb-release ca-certificates

# Step 2 - Add Microsoft package repository
echo "[Step 2] Adding Microsoft package repository..."

MICROSOFT_KEYRING="/usr/share/keyrings/microsoft.gpg"
MICROSOFT_LIST="/etc/apt/sources.list.d/microsoft-prod.list"

curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
    gpg --dearmor | tee "$MICROSOFT_KEYRING" > /dev/null

DISTRO_VERSION="$(lsb_release -rs)"
DISTRO_CODENAME="$(lsb_release -cs)"

echo "deb [arch=amd64 signed-by=$MICROSOFT_KEYRING] https://packages.microsoft.com/ubuntu/${DISTRO_VERSION}/prod ${DISTRO_CODENAME} main" | \
    tee "$MICROSOFT_LIST" > /dev/null

# Step 3 - Install the Intune app for Linux
echo "[Step 3] Installing Intune Portal..."
apt update
apt install -y intune-portal

# Step 4 - Launch the application
echo "[Step 4] Launching Intune Portal..."
if command -v intune-portal >/dev/null 2>&1; then
    intune-portal &
else
    echo "Intune Portal installed, but command not found in PATH."
fi

echo "==================================================="
echo "Intune Portal installation completed successfully."
echo "==================================================="
