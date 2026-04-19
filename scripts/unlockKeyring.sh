#!/bin/bash
# SPDX-FileCopyrightText: 2022 Håvard Moen / adapted for LinuxCamPAM
# SPDX-License-Identifier: GPL-3.0-or-later
#
# unlockKeyring.sh — TPM-backed GNOME Keyring unlock
#
# This script is called by pam_linuxcampam's pam_sm_open_session when
# tpm_mode is active. It:
#   1. Detects the real login user (PAM_USER, loginctl, or getent fallback)
#   2. Waits for the GNOME Keyring socket to become available (max 8s)
#   3. Loads the AES key using a persistent TPM primary handle (fast path,
#      no tpm2_createprimary required at boot)
#   4. Decrypts the encrypted password
#   5. Runs unlock.py as the target user (not root) to satisfy the
#      gnome-keyring-daemon uid check
#
# Fixes over the original version:
#   - Explicit PATH so tpm2-tools binaries are found in the PAM environment
#   - User detection via PAM_USER / loginctl / getent (filters gdm-greeter
#     and other system accounts)
#   - HOME resolved from getent passwd (reliable when running as root via PAM)
#   - Socket-based timing: waits for /run/user/UID/keyring/control instead of
#     polling for the daemon PID, staying within the 10s PAM timeout
#   - D-Bus resolved from the systemd user socket (/run/user/UID/bus)
#   - unlock.py executed via runuser to avoid "control request from bad uid"
#   - Persistent TPM primary handle (TPM_PRIMARY_HANDLE) replaces the slow
#     tpm2_createprimary call, cutting unlock time from ~4s to under 1s
#
# One-time setup:
#   sudo apt install tpm2-tools python3-secretstorage
#   sudo usermod -aG tss $USER   # log out and back in after this
#   git clone https://codeberg.org/umglurf/gnome-keyring-unlock.git ~/gnome-keyring-unlock
#   chmod +x ~/gnome-keyring-unlock/unlock.py
#
#   mkdir -p ~/.tpm && chmod 700 ~/.tpm && cd ~/.tpm
#   tpm2_createprimary -Q -c primary.ctx
#   tpm2_evictcontrol -c primary.ctx -o 0x81000001   # note the handle printed
#   tpm2_create -Q -C 0x81000001 -Gaes128 -u key.pub -r key.priv
#   tpm2_load  -Q -C 0x81000001 -u key.pub -r key.priv -c key.ctx
#   read -s -p "Enter login password: " password
#   tpm2_encryptdecrypt -Q -c key.ctx -o password.enc <<< "$password"
#   unset password
#   chmod 600 password.enc key.pub key.priv
#
#   # Update TPM_PRIMARY_HANDLE below to match the handle from tpm2_evictcontrol
#   sudo cp scripts/unlockKeyring.sh /usr/local/bin/unlockKeyring.sh
#   sudo chmod +x /usr/local/bin/unlockKeyring.sh
#
# PAM configuration (e.g. /etc/pam.d/gdm-password):
#   session optional pam_linuxcampam.so tpm_mode keyring_unlock_script=/usr/local/bin/unlockKeyring.sh

# Explicit PATH: tpm2-tools may not be in the PAM environment PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ---------------------------------------------------------------------------
# Persistent TPM primary handle created during setup with tpm2_evictcontrol.
# Using a persistent handle avoids running tpm2_createprimary at every boot,
# which saves ~2 seconds. Update this value if your handle differs.
# ---------------------------------------------------------------------------
TPM_PRIMARY_HANDLE="0x81000001"

log() { logger -t linuxcampam-keyring "$(date +%H:%M:%S.%3N) $*" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Determine the real login user.
# PAM_USER is set by pam_linuxcampam when invoking this script. If absent
# (e.g. manual test), fall back to loginctl and finally getent passwd.
# ---------------------------------------------------------------------------
TARGET_USER="${PAM_USER:-}"
if [ -z "$TARGET_USER" ]; then
    TARGET_USER=$(loginctl list-sessions --no-legend 2>/dev/null \
        | awk '{print $3}' \
        | grep -vE '^(root|gdm|gdm-greeter|nobody)$' \
        | head -1 || true)
fi
if [ -z "$TARGET_USER" ]; then
    # Last resort: first human account (UID 1000–65533)
    TARGET_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' | head -1 || true)
fi
if [ -z "$TARGET_USER" ]; then
    log "Cannot determine target user — skipping"
    exit 0
fi

log "Target user: $TARGET_USER"

# Resolve HOME from the system database (reliable when running as root via PAM)
HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
TPM_DIR="${LINUXCAMPAM_TPM_DIR:-${HOME}/.tpm}"
UNLOCK_PY="${LINUXCAMPAM_UNLOCK_PY:-${HOME}/gnome-keyring-unlock/unlock.py}"
_UID=$(id -u "$TARGET_USER" 2>/dev/null || echo "1000")
export XDG_RUNTIME_DIR="/run/user/${_UID}"

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if [[ ! -f "${TPM_DIR}/key.pub" ]] || [[ ! -f "${TPM_DIR}/key.priv" ]] || [[ ! -f "${TPM_DIR}/password.enc" ]]; then
    log "TPM key files not found in ${TPM_DIR} — skipping"
    exit 0
fi

if [[ ! -x "${UNLOCK_PY}" ]]; then
    log "gnome-keyring-unlock not found at ${UNLOCK_PY} — skipping"
    exit 0
fi

# ---------------------------------------------------------------------------
# Wait for the GNOME Keyring socket (max 8s, well under the 10s PAM timeout).
# Polling the socket is more reliable than polling the daemon PID.
# ---------------------------------------------------------------------------
KEYRING_SOCKET="/run/user/${_UID}/keyring/control"
for i in $(seq 1 8); do
    [ -S "$KEYRING_SOCKET" ] && { log "Socket ready at attempt $i"; break; }
    sleep 1
done

if [ ! -S "$KEYRING_SOCKET" ]; then
    log "Keyring socket not available after 8s — skipping"
    exit 0
fi

# ---------------------------------------------------------------------------
# Resolve D-Bus session address from the systemd user socket.
# This is always available after session start without needing /proc.
# ---------------------------------------------------------------------------
DBUS_SOCKET="/run/user/${_UID}/bus"
if [ -S "$DBUS_SOCKET" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${DBUS_SOCKET}"
else
    # Fallback: read from the daemon process environment
    KEYRING_PID=$(pgrep -u "$TARGET_USER" gnome-keyring-daemon 2>/dev/null | head -1 || true)
    if [ -n "$KEYRING_PID" ]; then
        _DBUS=$(cat /proc/$KEYRING_PID/environ 2>/dev/null \
            | tr '\0' '\n' \
            | grep '^DBUS_SESSION_BUS_ADDRESS=' \
            | head -1 || true)
        [ -n "$_DBUS" ] && export "$_DBUS"
    fi
fi

# ---------------------------------------------------------------------------
# Load the AES key using the persistent primary handle.
# No tpm2_createprimary needed — the persistent handle survives reboots.
# ---------------------------------------------------------------------------
log "Starting tpm2_load"
tpm2_load -Q \
    -C "$TPM_PRIMARY_HANDLE" \
    -u "${TPM_DIR}/key.pub" \
    -r "${TPM_DIR}/key.priv" \
    -c "${TPM_DIR}/key.ctx" 2>/dev/null || {
    log "tpm2_load failed — check TPM_PRIMARY_HANDLE (current: $TPM_PRIMARY_HANDLE)"
    log "Run: tpm2_getcap handles-persistent"
    exit 0
}

# ---------------------------------------------------------------------------
# Decrypt the password and unlock the keyring.
#
# unlock.py must run as the target user: gnome-keyring-daemon rejects
# connections whose uid does not match the keyring owner (uid=0 → rejected).
# We decrypt as root (TPM access), then pipe to unlock.py via runuser.
# ---------------------------------------------------------------------------
log "Starting tpm2_encryptdecrypt"
DECRYPTED=$(tpm2_encryptdecrypt -Qd \
    -c "${TPM_DIR}/key.ctx" \
    "${TPM_DIR}/password.enc" 2>/dev/null) || {
    log "tpm2_encryptdecrypt failed"
    exit 0
}

log "Starting unlock.py"
echo -n "$DECRYPTED" | runuser -u "$TARGET_USER" -- \
    env DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        "$UNLOCK_PY"

unset DECRYPTED
log "Keyring unlock completed successfully"
