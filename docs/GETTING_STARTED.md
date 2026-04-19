# Getting Started with LinuxCamPAM

This is the only guide you need to go from zero to a fully working face login
with automatic keyring unlock. Follow the steps in order.

---

## What You Will End Up With

- Face authentication at the login screen (GDM, SDDM, or LightDM)
- Face authentication for `sudo` in the terminal
- Automatic GNOME Keyring unlock on face login — no password popup

---

## Step 1 — Install LinuxCamPAM

### Option A: Install from a `.deb` package (easiest)

If you downloaded a release `.deb` file:

```bash
sudo apt install ./linuxcampam_*.deb
```

`apt` handles all dependencies automatically. Skip to **Step 2**.

### Option B: Build from source

```bash
# 1. Install build tools
./scripts/install_deps.sh

# 2. Build static OpenCV (takes 15–20 minutes, only needed once)
./scripts/build_opencv.sh

# 3. Build and install everything
./scripts/install.sh
```

`install.sh` will:
- Compile and install the binaries and PAM module
- Back up your existing PAM configuration
- Auto-detect your cameras and write `/etc/linuxcampam/config.ini`
- Download the AI models (YuNet + SFace)
- Ask if you want to set up automatic keyring unlock (you can skip and do it later)

> **GCC 15 note:** if the build fails with `-Werror=unused-result` on
> `write()`, the source already includes the fix. Make sure you are building
> from this version of the repository.

---

## Step 2 — Enroll Your Face

```bash
linuxcampam add $USER
```

Follow the on-screen instructions. You will be asked to look at the camera
from a few angles. Good lighting helps.

Test that recognition works:

```bash
linuxcampam test
# Expected: HW_OK | AUTH_SUCCESS
```

If you get `AUTH_FAIL: No face detected`, try `linuxcampam debug on` and
check `journalctl -u linuxcampam -f` for details.

---

## Step 3 — Start the Service

```bash
sudo systemctl enable --now linuxcampam
```

At this point face login for `sudo` already works. Try it:

```bash
sudo echo "face auth works"
```

---

## Step 4 — Automatic Keyring Unlock (Optional but Recommended)

Without this step, you will see a password popup asking to unlock the GNOME
Keyring every time you log in with your face. This step eliminates that popup.

Run the setup wizard:

```bash
linuxcampam-setup-keyring
```

The wizard will:
1. Check that a TPM chip is available on your machine
2. Install `tpm2-tools` if missing
3. Add your user to the `tss` group
4. Clone the `gnome-keyring-unlock` helper
5. Create a TPM encryption key and encrypt your login password inside the TPM
6. Create a **persistent TPM handle** so the unlock runs in under 1 second
7. Install `unlockKeyring.sh` to `/usr/local/bin/`
8. Add the required line to your login manager's PAM file

> **No TPM?** If your machine does not have a TPM chip, the wizard will tell
> you and you can skip this step. The keyring popup will continue to appear
> after face login, but everything else works fine.

### Verify keyring unlock is working

Log out and log back in using face authentication, then run:

```bash
journalctl -t linuxcampam-keyring --since "3 minutes ago"
```

A successful run looks like this:

```
12:21:05 Socket ready at attempt 1
12:21:05 Starting tpm2_load
12:21:06 Starting tpm2_encryptdecrypt
12:21:06 Starting unlock.py
12:21:06 Keyring unlock completed successfully
```

The entire unlock completes in under 1 second and no password popup appears.

---

## If Something Goes Wrong

### Face login not working

```bash
# Check the service is running
sudo systemctl status linuxcampam

# Check logs
journalctl -u linuxcampam -f

# Run a diagnostic
linuxcampam test
```

### Keyring popup still appears after face login

Check the unlock log:

```bash
journalctl -t linuxcampam-keyring --since "5 minutes ago"
```

| Message in log | Fix |
|----------------|-----|
| *(no entries at all)* | The installed `.so` is the old version without keyring support. Rebuild from source with `./scripts/install.sh` and verify with `strings /usr/lib/*/security/pam_linuxcampam.so \| grep tpm_mode` |
| `TPM key files not found` | Re-run `linuxcampam-setup-keyring` |
| `tpm2_load failed` | The TPM persistent handle in `unlockKeyring.sh` is wrong. Run `tpm2_getcap handles-persistent` and update `TPM_PRIMARY_HANDLE` in `/usr/local/bin/unlockKeyring.sh` |
| `Keyring unlock completed successfully` but popup still appears | Your login password stored in the TPM is stale. Re-run `linuxcampam-setup-keyring` and choose to overwrite the password |

### If you change your login password

The encrypted password stored in the TPM becomes stale. Update it:

```bash
linuxcampam-setup-keyring
```

Choose to overwrite the existing password when asked.

---

## Uninstall

```bash
# Remove PAM line
sudo nano /etc/pam.d/gdm-password   # remove the pam_linuxcampam.so line

# Remove TPM keys and encrypted password
rm -rf ~/.tpm

# Remove binaries
sudo rm -f /usr/local/bin/linuxcampam \
           /usr/local/bin/linuxcampamd \
           /usr/local/bin/unlockKeyring.sh \
           /usr/local/bin/linuxcampam-setup-keyring
sudo rm -f /usr/lib/*/security/pam_linuxcampam.so

# Stop and disable service
sudo systemctl disable --now linuxcampam
```

---

## Further Reading

These documents are available if you need more detail on specific topics:

| Document | Contents |
|----------|----------|
| `docs/CONFIGURATION.md` | All `config.ini` options, camera policies, IR setup |
| `docs/KEYRING_UNLOCK.md` | Full technical details of the keyring unlock mechanism |
| `docs/SECURITY_ASSESSMENT.md` | Threat model and security analysis |
| `docs/ARCHITECTURE.md` | Internal design for contributors |
| `docs/DEBUGGING.md` | Advanced debugging techniques |
