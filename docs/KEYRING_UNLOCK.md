# Keyring Unlock Integration for LinuxCamPAM

Integrate automatic GNOME Keyring unlock into LinuxCamPAM so that face
authentication at the login screen (GDM/SDDM/LightDM) also unlocks the
keyring — no password prompt after face login.

Two modes are available:

| Mode | How it works | Best for |
|------|-------------|----------|
| **TPM mode** *(recommended)* | Password is encrypted in the TPM. Helper decrypts it and unlocks keyring. | Face / fingerprint login (no password typed) |
| **Password mode** | Reuses the password already cached by `pam_unix` in `PAM_AUTHTOK`. | Mixed setups where users sometimes type a password |

---

## 1. Build and Install LinuxCamPAM

The keyring unlock is built into `pam_linuxcampam.so` via `pam_sm_open_session`,
which PAM calls automatically after a successful login. You must build from
source to get this feature.

```bash
# Install build dependencies
sudo apt install build-essential cmake libpam0g-dev

# From the project root:
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc) pam_linuxcampam
cd ..
```

> **Note for GCC 15 users:** the source already includes a fix for the
> `-Werror=unused-result` error on `write()`. If you see a different build
> error, check `CHANGELOG.md` for known issues.

Then install the freshly built module:

```bash
sudo install -m 644 build/pam_linuxcampam.so \
    /usr/lib/x86_64-linux-gnu/security/pam_linuxcampam.so
```

Verify that the installed module contains the keyring support:

```bash
strings /usr/lib/x86_64-linux-gnu/security/pam_linuxcampam.so | grep tpm_mode
# Expected output: tpm_mode
```

If the string does not appear, the wrong (old) `.so` is still in place —
check that the path above matches what PAM actually loads on your distro:

```bash
find /usr /lib /lib64 -name "pam_linuxcampam.so" 2>/dev/null
```

---

## 2. Install the gnome-keyring-unlock Helper

```bash
git clone https://codeberg.org/umglurf/gnome-keyring-unlock.git ~/gnome-keyring-unlock
chmod +x ~/gnome-keyring-unlock/unlock.py

# Install the required Python dependency
sudo apt install python3-secretstorage 2>/dev/null || \
    pip3 install secretstorage --break-system-packages
```

---

## 3a. TPM Mode Setup (Recommended)

### Add yourself to the `tss` group

```bash
sudo usermod -aG tss $USER
# Log out and back in, then verify:
groups
```

### Install tpm2-tools

```bash
sudo apt install tpm2-tools
```

### Create the TPM keys and encrypt your login password

```bash
mkdir -p ~/.tpm && chmod 700 ~/.tpm && cd ~/.tpm

# Create a temporary primary context to generate the AES key
tpm2_createprimary -Q -c primary.ctx

# Persist the primary key as a permanent TPM handle (avoids recreating it
# at every boot, which would add ~2 seconds to the unlock time)
tpm2_evictcontrol -c primary.ctx -o 0x81000001
# Note the handle printed (e.g. 0x81000001) — you may need it later

# Verify the persistent handle was created
tpm2_getcap handles-persistent

# Create an AES-128 encryption key under the persistent primary
tpm2_create -Q -C 0x81000001 -Gaes128 -u key.pub -r key.priv

# Load the key to verify it works
tpm2_load -Q -C 0x81000001 -u key.pub -r key.priv -c key.ctx

# Encrypt your login password
read -s -p "Enter your login password: " password
tpm2_encryptdecrypt -Q -c key.ctx -o password.enc <<< "$password"
unset password

# Set restrictive permissions
chmod 600 password.enc key.pub key.priv
```

> **Finding the correct persistent handle:** if you already have handles in
> the TPM (check with `tpm2_getcap handles-persistent`), use the one that
> was just created. You can verify which handle works with your keys by
> running:
> ```bash
> tpm2_load -Q -C 0x81000001 -u key.pub -r key.priv -c key.ctx && echo OK
> ```
> Replace `0x81000001` with the handle shown by `tpm2_evictcontrol`.

### Update the handle in unlockKeyring.sh

Open the script and set `TPM_PRIMARY_HANDLE` to the handle you just created:

```bash
sudo nano /usr/local/bin/unlockKeyring.sh
# Set: TPM_PRIMARY_HANDLE="0x81000001"   ← replace with your actual handle
```

### Install the unlock script

```bash
sudo cp scripts/unlockKeyring.sh /usr/local/bin/unlockKeyring.sh
sudo chmod +x /usr/local/bin/unlockKeyring.sh
```

> **Paths used by the script** (override with env vars if needed):
> - `~/.tpm/` — TPM key files
> - `~/gnome-keyring-unlock/unlock.py` — keyring unlock helper
>
> ```bash
> export LINUXCAMPAM_TPM_DIR=/custom/path/.tpm
> export LINUXCAMPAM_UNLOCK_PY=/custom/path/unlock.py
> ```

---

## 3b. Password Mode Setup (Alternative)

No TPM required. Works when the user typed a password that `pam_unix` cached
as `PAM_AUTHTOK` (e.g. fallback password login, or after face auth + password
fallback).

```bash
sudo ln -s ~/gnome-keyring-unlock/unlock.py /usr/local/bin/gnome-keyring-unlock
sudo chmod +x /usr/local/bin/gnome-keyring-unlock
```

---

## 4. Configure PAM

Edit the PAM service file for your login manager. Add the `session` line
**after** the existing `session` block.

### GDM (Ubuntu / Pop!_OS) — `/etc/pam.d/gdm-password`

```
# --- existing lines above ---
@include common-auth
@include common-account
@include common-session-noninteractive

# GNOME Keyring unlock via LinuxCamPAM (TPM mode):
session optional pam_linuxcampam.so tpm_mode keyring_unlock_script=/usr/local/bin/unlockKeyring.sh

# OR password mode (no TPM):
# session optional pam_linuxcampam.so keyring_unlock_script=/usr/local/bin/gnome-keyring-unlock
```

### SDDM — `/etc/pam.d/sddm`

Add after `session include common-session`:

```
session optional pam_linuxcampam.so tpm_mode keyring_unlock_script=/usr/local/bin/unlockKeyring.sh
```

### LightDM — `/etc/pam.d/lightdm`

```
session optional pam_linuxcampam.so tpm_mode keyring_unlock_script=/usr/local/bin/unlockKeyring.sh
```

> **Why `optional`?** If keyring unlock fails for any reason (TPM unavailable,
> wrong password, etc.), login still succeeds. The keyring unlock is a
> convenience, not a security gate.

---

## 5. Verify

Log out and log back in via face authentication. Check:

```bash
# Unlock script log (most useful — shows each step with timestamps)
journalctl -t linuxcampam-keyring --since "5 minutes ago"

# PAM module log
sudo journalctl -t LinuxCamPAM --since "5 minutes ago" | grep -i keyring

# Confirm keyring is unlocked (should return no password prompt)
secret-tool lookup test test 2>&1 | head -5
```

A successful run looks like:

```
12:21:05 Socket ready at attempt 1
12:21:05 Starting tpm2_load
12:21:06 Starting tpm2_encryptdecrypt
12:21:06 Starting unlock.py
12:21:06 Keyring unlock completed successfully
```

The entire unlock should complete in **under 1 second** when using a
persistent TPM handle.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `journalctl -t linuxcampam-keyring` shows nothing | Wrong `.so` installed (old version without `pam_sm_open_session`) | Rebuild from source and reinstall — see step 1 |
| `Keyring unlock exited with code 127` | `tpm2-tools` not in PATH during PAM execution | Verify `PATH=` line is present at top of `unlockKeyring.sh` |
| `TPM key files not found in /.tpm` | `PAM_USER` not set, user detection fell back to wrong account | Check that `loginctl` returns your username and not `gdm-greeter` |
| `tpm2_load failed` | Wrong persistent handle in `TPM_PRIMARY_HANDLE` | Run `tpm2_load -Q -C 0xXXXXXXXX -u ~/.tpm/key.pub -r ~/.tpm/key.priv -c /tmp/test.ctx` for each handle listed by `tpm2_getcap handles-persistent` until one succeeds |
| `control request from bad uid: 0` | `unlock.py` running as root instead of user | Verify `runuser -u "$TARGET_USER"` line is present in script |
| `Keyring unlock completed successfully` but popup still appears | Unlock completes after GNOME shows the prompt (timing) | Ensure you are using the persistent handle (no `tpm2_createprimary` step) so unlock finishes in <1s |
| Wrong password stored in TPM | Password changed after setup | Re-encrypt: `tpm2_encryptdecrypt -Q -c ~/.tpm/key.ctx -o ~/.tpm/password.enc <<< "newpassword"` |
| Keyring socket timeout | `gnome-keyring-daemon` not starting | Check `pgrep gnome-keyring-daemon` and `systemctl --user status gnome-keyring-daemon` |

---

## Security Notes

- The encrypted password file (`~/.tpm/password.enc`) is useless without the
  specific TPM chip on this exact machine. Even if copied, it cannot be
  decrypted elsewhere.
- `pam_sm_open_session` always returns `PAM_SUCCESS` regardless of whether
  keyring unlock succeeded. A broken unlock helper will never lock you out.
- The plaintext password exists in memory only for the duration of the
  `tpm2_encryptdecrypt | runuser` pipeline and is immediately unset.
- This integration does not store any password in plaintext on disk.
- If you change your login password, re-encrypt it in the TPM:
  ```bash
  cd ~/.tpm
  tpm2_load -Q -C 0x81000001 -u key.pub -r key.priv -c key.ctx
  read -s -p "New login password: " password
  tpm2_encryptdecrypt -Q -c key.ctx -o password.enc <<< "$password"
  unset password
  ```
