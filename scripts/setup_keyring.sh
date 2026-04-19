#!/bin/bash
# =============================================================================
# setup_keyring.sh — Automatic GNOME Keyring unlock setup for LinuxCamPAM
#
# This script automates all steps to configure TPM-backed keyring unlock:
#   1. Checks/installs tpm2-tools
#   2. Adds user to tss group (if needed)
#   3. Clones gnome-keyring-unlock helper
#   4. Creates TPM primary key + AES encryption key
#   5. Encrypts the login password
#   6. Installs unlockKeyring.sh
#   7. Configures the correct PAM file (GDM / SDDM / LightDM)
#
# Usage:
#   sudo ./scripts/setup_keyring.sh          # Interactive (recommended)
#   sudo ./scripts/setup_keyring.sh --skip-password-prompt   # For automation
#
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[Keyring]${NC} $*"; }
ok()      { echo -e "${GREEN}[Keyring] ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}[Keyring] ⚠${NC} $*"; }
error()   { echo -e "${RED}[Keyring] ✗${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${NC}"; }

# ── Must NOT run as root (TPM files go in user's home) ────────────────────────
if [ "$(id -u)" -eq 0 ]; then
    # Re-exec as the real user if called via sudo
    if [ -n "${SUDO_USER:-}" ]; then
        exec sudo -u "$SUDO_USER" bash "$0" "$@"
    else
        error "Do not run as root. Run as your normal user (sudo will be invoked when needed)."
        exit 1
    fi
fi

REAL_USER="$(id -un)"
REAL_HOME="$(eval echo "~$REAL_USER")"
TPM_DIR="${REAL_HOME}/.tpm"
UNLOCK_SCRIPT_DEST="/usr/local/bin/unlockKeyring.sh"
GNOME_KEYRING_UNLOCK_DIR="${REAL_HOME}/gnome-keyring-unlock"

# Locate unlockKeyring.sh relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_UNLOCK_SCRIPT="${SCRIPT_DIR}/unlockKeyring.sh"

# ── Helper: check if TPM is available ─────────────────────────────────────────
check_tpm() {
    if [ -e /dev/tpm0 ] || [ -e /dev/tpmrm0 ]; then
        return 0
    fi
    return 1
}

# ── Helper: detect login manager PAM file ─────────────────────────────────────
detect_pam_file() {
    for f in gdm-password gdm3 sddm lightdm; do
        if [ -f "/etc/pam.d/$f" ]; then
            echo "/etc/pam.d/$f"
            return 0
        fi
    done
    # Fallback: common-session
    echo "/etc/pam.d/common-session"
}

# ── Helper: check if PAM line already present ─────────────────────────────────
pam_line_present() {
    local pam_file="$1"
    grep -q "pam_linuxcampam.so.*tpm_mode" "$pam_file" 2>/dev/null
}

# =============================================================================
section "LinuxCamPAM — GNOME Keyring Unlock Setup"
echo ""
echo "  This wizard will configure automatic keyring unlock via TPM."
echo "  Your login password will be stored encrypted inside the TPM chip."
echo "  It can only be decrypted by this specific hardware."
echo ""

# ── Step 1: Check TPM ─────────────────────────────────────────────────────────
section "Step 1/7 — TPM Check"

if ! check_tpm; then
    error "No TPM chip found (/dev/tpm0 or /dev/tpmrm0 missing)."
    echo ""
    echo "  TPM mode requires a Trusted Platform Module (TPM 2.0)."
    echo "  Most modern laptops and desktops have one — check your BIOS settings."
    echo ""
    read -rp "  Continue anyway? The setup will fail later if TPM is unavailable. [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { info "Setup cancelled."; exit 0; }
else
    ok "TPM detected ($(ls /dev/tpm* 2>/dev/null | tr '\n' ' '))"
fi

# ── Step 2: Install tpm2-tools ────────────────────────────────────────────────
section "Step 2/7 — tpm2-tools"

if command -v tpm2_createprimary &>/dev/null; then
    ok "tpm2-tools already installed ($(command -v tpm2_createprimary))"
else
    info "Installing tpm2-tools..."
    sudo apt-get update -qq
    sudo apt-get install -y tpm2-tools
    ok "tpm2-tools installed"
fi

# ── Step 3: tss group ─────────────────────────────────────────────────────────
section "Step 3/7 — tss Group"

if groups "$REAL_USER" | grep -qw tss; then
    ok "User '$REAL_USER' is already in the tss group"
else
    info "Adding '$REAL_USER' to the tss group..."
    sudo usermod -aG tss "$REAL_USER"
    warn "Group membership updated. A logout/login is normally needed."
    warn "We'll use 'sg tss' to run TPM commands in this session without re-login."
fi

# ── Step 4: gnome-keyring-unlock helper ───────────────────────────────────────
section "Step 4/7 — gnome-keyring-unlock Helper"

if [ -x "${GNOME_KEYRING_UNLOCK_DIR}/unlock.py" ]; then
    ok "gnome-keyring-unlock already present at ${GNOME_KEYRING_UNLOCK_DIR}"
else
    if command -v git &>/dev/null; then
        info "Cloning gnome-keyring-unlock..."
        git clone https://codeberg.org/umglurf/gnome-keyring-unlock.git \
            "${GNOME_KEYRING_UNLOCK_DIR}" 2>&1 | sed 's/^/  /'
        chmod +x "${GNOME_KEYRING_UNLOCK_DIR}/unlock.py"
        ok "Cloned to ${GNOME_KEYRING_UNLOCK_DIR}"
    else
        warn "git not found — installing..."
        sudo apt-get install -y git
        git clone https://codeberg.org/umglurf/gnome-keyring-unlock.git \
            "${GNOME_KEYRING_UNLOCK_DIR}" 2>&1 | sed 's/^/  /'
        chmod +x "${GNOME_KEYRING_UNLOCK_DIR}/unlock.py"
        ok "Cloned to ${GNOME_KEYRING_UNLOCK_DIR}"
    fi
fi

# Check python3-secretstorage dependency for unlock.py
if ! python3 -c "import secretstorage" &>/dev/null; then
    info "Installing python3-secretstorage (required by unlock.py)..."
    sudo apt-get install -y python3-secretstorage 2>/dev/null || \
        pip3 install secretstorage --break-system-packages 2>/dev/null || \
        warn "Could not install secretstorage automatically. Install it manually: pip3 install secretstorage"
fi

# ── Step 5: TPM key creation + password encryption ───────────────────────────
section "Step 5/7 — TPM Key + Encrypted Password"

mkdir -p "${TPM_DIR}"
chmod 700 "${TPM_DIR}"

# Wrap TPM commands with sg tss if user just got added to group
TPM_RUNNER=""
if ! groups "$REAL_USER" | grep -qw tss; then
    TPM_RUNNER="sg tss -c"
fi

run_tpm() {
    if [ -n "$TPM_RUNNER" ]; then
        sg tss -c "$*"
    else
        eval "$@"
    fi
}

# Create primary key context
info "Creating TPM primary key context..."
run_tpm "tpm2_createprimary -Q -c '${TPM_DIR}/primary.ctx'"
ok "Primary key context created"

# Persist the primary key as a permanent TPM handle.
# This avoids recreating the primary context at every boot (which takes ~2s)
# and reduces total keyring unlock time to under 1 second.
TPM_HANDLE="0x81000001"
info "Persisting primary key as handle ${TPM_HANDLE}..."
# Remove existing handle at that slot if present, then persist
run_tpm "tpm2_evictcontrol -c '${TPM_DIR}/primary.ctx' -o ${TPM_HANDLE}" 2>/dev/null || {
    # Handle may already be occupied — evict it first, then re-persist
    run_tpm "tpm2_evictcontrol -c ${TPM_HANDLE}" 2>/dev/null || true
    run_tpm "tpm2_evictcontrol -c '${TPM_DIR}/primary.ctx' -o ${TPM_HANDLE}"
}
ok "Primary key persisted as ${TPM_HANDLE}"

# Save the handle so unlockKeyring.sh can be updated automatically
echo "${TPM_HANDLE}" > "${TPM_DIR}/primary.handle"

# Create AES key under the persistent handle
if [ ! -f "${TPM_DIR}/key.pub" ] || [ ! -f "${TPM_DIR}/key.priv" ]; then
    info "Creating AES-128 encryption key..."
    run_tpm "tpm2_create -Q -C ${TPM_HANDLE} -G aes -u '${TPM_DIR}/key.pub' -r '${TPM_DIR}/key.priv'"
    ok "AES key created"
else
    ok "key.pub / key.priv already exist — skipping key generation"
fi

# Load key using the persistent handle
info "Loading AES key into TPM..."
run_tpm "tpm2_load -Q -C ${TPM_HANDLE} -u '${TPM_DIR}/key.pub' -r '${TPM_DIR}/key.priv' -c '${TPM_DIR}/key.ctx'"
ok "Key loaded"

# Encrypt password
if [ -f "${TPM_DIR}/password.enc" ]; then
    echo ""
    warn "An encrypted password already exists at ${TPM_DIR}/password.enc"
    read -rp "  Overwrite it with a new password? [y/N] " overwrite
    [[ "$overwrite" =~ ^[Yy]$ ]] || { info "Keeping existing password.enc — skipping."; }
fi

if [ ! -f "${TPM_DIR}/password.enc" ] || [[ "${overwrite:-n}" =~ ^[Yy]$ ]]; then
    echo ""
    echo "  Enter your login password to encrypt it in the TPM."
    echo "  (It will NOT be shown or stored in plaintext anywhere)"
    echo ""
    read -rs -p "  Login password: " LOGIN_PASSWORD
    echo ""

    # Encrypt
    run_tpm "echo -n '${LOGIN_PASSWORD}' | tpm2_encryptdecrypt -Q -c '${TPM_DIR}/key.ctx' -o '${TPM_DIR}/password.enc'"
    unset LOGIN_PASSWORD

    # Verify round-trip
    DECRYPTED=$(run_tpm "tpm2_encryptdecrypt -Q -d -c '${TPM_DIR}/key.ctx' '${TPM_DIR}/password.enc'" 2>/dev/null || echo "FAIL")
    if [ "$DECRYPTED" = "FAIL" ]; then
        warn "Could not verify decryption — continuing anyway."
    else
        ok "Password encrypted and verified successfully"
    fi
fi

# Set restrictive permissions
chmod 600 "${TPM_DIR}/password.enc" "${TPM_DIR}/key.pub" "${TPM_DIR}/key.priv"
chmod 700 "${TPM_DIR}"
ok "Permissions set on ~/.tpm/"

# ── Step 6: Install unlockKeyring.sh ──────────────────────────────────────────
section "Step 6/7 — Install unlockKeyring.sh"

if [ -f "$LOCAL_UNLOCK_SCRIPT" ]; then
    sudo cp "$LOCAL_UNLOCK_SCRIPT" "$UNLOCK_SCRIPT_DEST"
    sudo chmod +x "$UNLOCK_SCRIPT_DEST"
    ok "Installed ${UNLOCK_SCRIPT_DEST}"
else
    warn "Local unlockKeyring.sh not found at ${LOCAL_UNLOCK_SCRIPT}"
    info "Attempting to use already-installed version at ${UNLOCK_SCRIPT_DEST}..."
    if [ ! -x "$UNLOCK_SCRIPT_DEST" ]; then
        error "unlockKeyring.sh not found. Please re-run install.sh first."
        exit 1
    fi
fi

# Patch the persistent TPM handle into the installed script so it matches
# the handle created in Step 5 (avoids the slow tpm2_createprimary at boot)
if [ -f "${TPM_DIR}/primary.handle" ]; then
    SAVED_HANDLE=$(cat "${TPM_DIR}/primary.handle")
    sudo sed -i "s|TPM_PRIMARY_HANDLE=.*|TPM_PRIMARY_HANDLE=\"${SAVED_HANDLE}\"|" "$UNLOCK_SCRIPT_DEST"
    ok "TPM_PRIMARY_HANDLE set to ${SAVED_HANDLE} in ${UNLOCK_SCRIPT_DEST}"
fi

# ── Step 7: Configure PAM ─────────────────────────────────────────────────────
section "Step 7/7 — PAM Configuration"

PAM_FILE=$(detect_pam_file)
info "Detected login manager PAM file: ${PAM_FILE}"

PAM_LINE="session optional        pam_linuxcampam.so tpm_mode keyring_unlock_script=${UNLOCK_SCRIPT_DEST}"

if pam_line_present "$PAM_FILE"; then
    ok "PAM already configured in ${PAM_FILE} — skipping"
else
    # Backup
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    sudo cp "$PAM_FILE" "${PAM_FILE}.${TIMESTAMP}.bak"
    info "Backup saved: ${PAM_FILE}.${TIMESTAMP}.bak"

    # Insert after pam_gnome_keyring.so line if present, else append before @include common-password
    if grep -q "pam_gnome_keyring.so" "$PAM_FILE"; then
        sudo sed -i "/pam_gnome_keyring.so/a ${PAM_LINE}" "$PAM_FILE"
        ok "PAM line inserted after pam_gnome_keyring.so"
    elif grep -q "@include common-password" "$PAM_FILE"; then
        sudo sed -i "/@include common-password/i ${PAM_LINE}" "$PAM_FILE"
        ok "PAM line inserted before @include common-password"
    else
        echo "$PAM_LINE" | sudo tee -a "$PAM_FILE" > /dev/null
        ok "PAM line appended to ${PAM_FILE}"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}━━━ Setup Complete! ━━━${NC}"
echo ""
echo "  TPM key files:     ${TPM_DIR}/"
echo "  Unlock script:     ${UNLOCK_SCRIPT_DEST}"
echo "  PAM configured:    ${PAM_FILE}"
echo ""
echo -e "  ${BOLD}Next step:${NC} Log out and log back in via face authentication."
echo "  The keyring will unlock automatically — no password prompt."
echo ""
echo "  To verify after login:"
echo "    journalctl -t linuxcampam-keyring --since '5 minutes ago'"
echo ""
echo "  To redo the password encryption only:"
echo "    ${BASH_SOURCE[0]} --redo-password"
echo ""

echo "  For details on security and how it works:"
echo "    cat /usr/share/doc/linuxcampam/KEYRING_USER_GUIDE.md"
echo ""
