# Automatic Keyring Unlock — User Guide

This guide explains **what** the automatic keyring unlock feature does,
**where data is stored**, and **whether it is safe** to enable.

---

## What problem does it solve?

When you log in using face recognition, Linux does not receive your login
password. As a result, the **GNOME Keyring** — which protects passwords saved
in Firefox, Chrome, email clients, VPNs, Wi-Fi networks, etc. — remains locked.

This causes a password prompt to appear immediately after login, even though
you just authenticated with your face. It is inconvenient and partially defeats
the purpose of biometric authentication.

**This feature solves the problem:** after a successful face login, the keyring
unlocks automatically — no extra prompt required.

---

## How it works (plain English)

```
Face login
    │
    ▼
LinuxCamPAM recognises your face ✓
    │
    ▼
TPM chip decrypts your password (this hardware only)
    │
    ▼
Plaintext password is piped to the GNOME Keyring daemon
    │
    ▼
Keyring unlocked ✓  ←  no password prompt
```

The key component is the **TPM (Trusted Platform Module)**: a dedicated security
chip present on the motherboard of most modern PCs (2016 onwards). It is the
same chip Windows uses for BitLocker and many enterprise password managers rely on.

---

## Where is data stored?

All files are stored in your home directory inside a hidden folder:

| File | Path | Contents |
|------|------|----------|
| TPM public key | `~/.tpm/key.pub` | Public portion of the AES key (not a password) |
| TPM private key | `~/.tpm/key.priv` | Private portion — **unusable without the TPM chip** |
| Encrypted password | `~/.tpm/password.enc` | Your password, AES-128 encrypted |
| Primary context | `~/.tpm/primary.ctx` | Ephemeral TPM context, recreated on every boot |

> **Note:** the unlock script (`/usr/local/bin/unlockKeyring.sh`) is installed
> in a system directory and contains no personal data whatsoever.

---

## Is it safe?

### ✅ Yes, for these reasons:

**1. Your password is never stored in plaintext**
The `password.enc` file contains only AES-128 ciphertext. Without the specific
TPM chip on this exact machine, it is computationally infeasible to recover the
password from it. Even if someone copied the file, they could not use it.

**2. The TPM binds the key to the hardware**
The AES key is generated inside the TPM and cannot be exported. It only works
on this specific machine. If the disk is removed and put into a different
computer, decryption fails and the login proceeds normally (keyring stays locked,
as before).

**3. Failures are silent and never block login**
If anything goes wrong (TPM unavailable, script not found, wrong password, etc.),
the login continues normally. At worst, the keyring will remain locked and the
old password prompt will reappear. You will never be locked out of your system.

**4. Files have restrictive permissions**
`~/.tpm/` is set to `700` (owner access only).
`password.enc`, `key.pub`, and `key.priv` are set to `600`.

---

## What this feature does NOT do

- ❌ Does not write your password to any plaintext file
- ❌ Does not transmit any data over the network
- ❌ Does not share data with other users or processes
- ❌ Does not alter normal password-based login behaviour
- ❌ Does not require an internet connection to operate

---

## How the unlock is triggered

The mechanism integrates into the PAM (Pluggable Authentication Modules) stack,
which is the standard Linux framework for managing authentication. A single line
is added to the configuration file of your login manager (e.g. GDM):

```
session optional  pam_linuxcampam.so  tpm_mode  keyring_unlock_script=/usr/local/bin/unlockKeyring.sh
```

The `optional` keyword is critical: it means that even if this module fails
completely, login proceeds without interruption.

---

## What if I change my login password?

If you change your login password, the `password.enc` file becomes stale and
keyring unlock will fail silently (login remains fully functional).

To update the encrypted password in the TPM, simply re-run:

```bash
linuxcampam-setup-keyring
```

The wizard will ask whether to overwrite the existing encrypted password.

---

## How to disable this feature

To disable it temporarily or permanently, remove (or comment out) the line
added to `/etc/pam.d/gdm-password` (or the file for your login manager):

```bash
sudo nano /etc/pam.d/gdm-password
# Comment out or remove the line containing: pam_linuxcampam.so tpm_mode
```

To also remove the TPM key files:

```bash
rm -rf ~/.tpm
```

---

## Requirements

| Requirement | Details |
|-------------|---------|
| TPM 2.0 | Present on most PCs since 2016. Check with `ls /dev/tpm*` |
| tpm2-tools | Installed automatically by the wizard |
| python3-secretstorage | Required by `unlock.py`. Installed automatically |
| gnome-keyring | Already present on Ubuntu/GNOME. Required for unlocking |

---

## Frequently asked questions

**Q: The wizard asks for my password. Is it safe to type it?**
Yes. The password is read directly in the terminal using `read -s` (not echoed),
immediately encrypted inside the TPM, and then cleared from memory with
`unset password`. It is never written to disk in plaintext at any point.

**Q: Can I use this without a TPM chip?**
No. TPM mode requires the physical chip. If you do not have a TPM, you can use
"password mode" instead (less secure): see `docs/KEYRING_UNLOCK.md` for details.

**Q: Does this work with SDDM or LightDM as well?**
Yes. The wizard automatically detects the installed login manager and configures
the correct PAM file.

**Q: What happens if the TPM breaks or is reset (e.g. after a BIOS update)?**
Automatic unlock will stop working. Login will continue normally, but the keyring
will remain locked until you re-run `linuxcampam-setup-keyring` to generate new
TPM keys.

**Q: Does this affect sudo or lock screen authentication?**
No. The PAM line is only added to the login manager file (e.g. `gdm-password`),
not to `sudo` or the screensaver. Those continue to use their existing
authentication methods unchanged.
