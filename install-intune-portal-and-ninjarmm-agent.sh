#!/bin/bash
# =============================================================================
# Microsoft Intune Portal + NinjaOne RMM Agent - Silent Install Script
# Deployment Method : Microsoft Intune (Linux Script Push)
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Variables
# --------------------------------------------------------------------------- #
LOG_FILE="/var/log/intune_ninjarmm_install.log"

MICROSOFT_KEYRING="/usr/share/keyrings/microsoft.gpg"
MICROSOFT_LIST="/etc/apt/sources.list.d/microsoft-prod.list"
INTUNE_PACKAGE="intune-portal"
LAUNCH_INTUNE_PORTAL="${LAUNCH_INTUNE_PORTAL:-false}"

NINJA_DOWNLOAD_URL="https://eu.ninjarmm.com/agent/installer/e2c28cbe-7d2d-4047-a260-138d7a2791e4/12.0.6844/NinjaOne-Agent-Tryzens-TryzensLandingZone-Auto-x86-64.deb"
NINJA_DEB_FILENAME="NinjaOne-Agent-Tryzens-TryzensLandingZone-Auto-x86-64.deb"
NINJA_TMP_DIR="/tmp/ninjarmm_install"
NINJA_SERVICE_NAME="ninjarmm-agent.service"
NINJA_INSTALL_DIR="/opt/NinjaRMMAgent/programfiles"

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

fail() {
    log "ERROR: $*"
    exit 1
}

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

cleanup_ninja_tmp() {
    if [[ -n "${NINJA_TMP_DIR:-}" && "$NINJA_TMP_DIR" == /tmp/ninjarmm_install* ]]; then
        rm -rf "$NINJA_TMP_DIR"
    fi
}

# --------------------------------------------------------------------------- #
# Pre-flight checks
# --------------------------------------------------------------------------- #
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Script must be run as root."
    exit 1
fi

touch "$LOG_FILE"
chmod 0644 "$LOG_FILE"

log "=== Intune Portal and NinjaOne RMM Agent Installation Started ==="

if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
    fail "This script is intended for Ubuntu amd64 devices."
fi

export DEBIAN_FRONTEND=noninteractive

# --------------------------------------------------------------------------- #
# Common dependencies
# --------------------------------------------------------------------------- #
log "Updating apt package index..."
apt-get update >> "$LOG_FILE" 2>&1

log "Installing required dependencies..."
apt-get install -y ca-certificates curl gpg lsb-release wget >> "$LOG_FILE" 2>&1

# --------------------------------------------------------------------------- #
# Install Microsoft Intune Portal
# --------------------------------------------------------------------------- #
install_intune_portal() {
    log "--- Intune Portal installation started ---"

    if package_installed "$INTUNE_PACKAGE"; then
        log "Intune Portal is already installed. Skipping package installation."
    else
        local ubuntu_release
        local ubuntu_codename
        local tmp_key

        ubuntu_release="$(lsb_release -rs)"
        ubuntu_codename="$(lsb_release -cs)"
        tmp_key="$(mktemp)"

        log "Adding Microsoft package signing key..."
        curl -fsSL "https://packages.microsoft.com/keys/microsoft.asc" -o "$tmp_key" >> "$LOG_FILE" 2>&1
        gpg --dearmor --yes -o "$MICROSOFT_KEYRING" "$tmp_key" >> "$LOG_FILE" 2>&1
        rm -f "$tmp_key"

        log "Adding Microsoft package repository for Ubuntu ${ubuntu_release} (${ubuntu_codename})..."
        echo "deb [arch=amd64 signed-by=${MICROSOFT_KEYRING}] https://packages.microsoft.com/ubuntu/${ubuntu_release}/prod ${ubuntu_codename} main" > "$MICROSOFT_LIST"

        log "Refreshing apt package index after adding Microsoft repository..."
        apt-get update >> "$LOG_FILE" 2>&1

        log "Installing Intune Portal package..."
        apt-get install -y "$INTUNE_PACKAGE" >> "$LOG_FILE" 2>&1
    fi

    if ! package_installed "$INTUNE_PACKAGE"; then
        fail "Intune Portal package did not install successfully."
    fi

    if [[ "${LAUNCH_INTUNE_PORTAL,,}" == "true" ]]; then
        log "Launching Intune Portal because LAUNCH_INTUNE_PORTAL=true."
        nohup intune-portal >/dev/null 2>&1 &
    else
        log "Skipping Intune Portal launch for unattended deployment."
    fi

    log "--- Intune Portal installation completed ---"
}

# --------------------------------------------------------------------------- #
# Install NinjaOne RMM Agent
# --------------------------------------------------------------------------- #
ninja_binary_present() {
    [[ -d "$NINJA_INSTALL_DIR" ]] && find "$NINJA_INSTALL_DIR" -maxdepth 1 -name "ninjarmm-linagent*" -print -quit | grep -q .
}

start_ninja_service() {
    log "Enabling and starting ${NINJA_SERVICE_NAME}..."
    systemctl enable "$NINJA_SERVICE_NAME" >> "$LOG_FILE" 2>&1 || return 1
    systemctl start "$NINJA_SERVICE_NAME" >> "$LOG_FILE" 2>&1 || return 1

    sleep 5

    local service_status
    service_status="$(systemctl is-active "$NINJA_SERVICE_NAME" 2>/dev/null || true)"
    log "NinjaOne service status: ${service_status}"

    [[ "$service_status" == "active" ]]
}

install_ninja_agent() {
    log "--- NinjaOne RMM Agent installation started ---"

    for cmd in dpkg systemctl wget; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            fail "Required command '${cmd}' not found."
        fi
    done

    if systemctl is-active --quiet "$NINJA_SERVICE_NAME" 2>/dev/null; then
        log "NinjaOne RMM Agent is already installed and active. Skipping installation."
        return 0
    fi

    if ninja_binary_present; then
        log "NinjaOne RMM Agent files already exist. Attempting to start service."
        if start_ninja_service; then
            log "NinjaOne RMM Agent started successfully."
            return 0
        fi
        log "Existing NinjaOne RMM Agent did not start. Continuing with package installation."
    fi

    trap cleanup_ninja_tmp EXIT

    log "Creating temporary directory: ${NINJA_TMP_DIR}"
    cleanup_ninja_tmp
    mkdir -p "$NINJA_TMP_DIR"

    log "Downloading NinjaOne RMM Agent package..."
    wget --quiet \
        --timeout=120 \
        --tries=3 \
        -O "${NINJA_TMP_DIR}/${NINJA_DEB_FILENAME}" \
        "$NINJA_DOWNLOAD_URL" >> "$LOG_FILE" 2>&1

    if [[ ! -f "${NINJA_TMP_DIR}/${NINJA_DEB_FILENAME}" ]]; then
        fail "Download failed. Package not found at ${NINJA_TMP_DIR}/${NINJA_DEB_FILENAME}"
    fi

    log "Installing NinjaOne package with dpkg..."
    if ! dpkg -i "${NINJA_TMP_DIR}/${NINJA_DEB_FILENAME}" >> "$LOG_FILE" 2>&1; then
        log "dpkg reported an installation issue. Resolving dependencies with apt-get install -f..."
        apt-get install -f -y >> "$LOG_FILE" 2>&1
    else
        log "Resolving any remaining package dependencies..."
        apt-get install -f -y >> "$LOG_FILE" 2>&1
    fi

    log "Verifying NinjaOne install directory: ${NINJA_INSTALL_DIR}"
    if [[ ! -d "$NINJA_INSTALL_DIR" ]]; then
        fail "NinjaOne install directory not found at ${NINJA_INSTALL_DIR}"
    fi

    if ! ninja_binary_present; then
        fail "ninjarmm-linagent binary not found in ${NINJA_INSTALL_DIR}"
    fi

    log "NinjaOne install directory contents:"
    ls "$NINJA_INSTALL_DIR" | tee -a "$LOG_FILE"

    if ! start_ninja_service; then
        systemctl status "$NINJA_SERVICE_NAME" >> "$LOG_FILE" 2>&1 || true
        fail "${NINJA_SERVICE_NAME} did not start successfully."
    fi

    cleanup_ninja_tmp
    trap - EXIT

    log "--- NinjaOne RMM Agent installation completed ---"
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
install_intune_portal
install_ninja_agent

log "=== Intune Portal and NinjaOne RMM Agent Installation Completed Successfully ==="
exit 0
