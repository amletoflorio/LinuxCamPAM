#include "constants.hpp"
#include "ipc_protocol.hpp"
#include "pam_config.hpp"

#include <array>
#include <cstring>
#include <memory>
#include <pwd.h>
#include <security/pam_ext.h>
#include <security/pam_modules.h>
#include <string>
#include <sys/socket.h>
#include <sys/un.h>
#include <syslog.h>
#include <unistd.h>

// For keyring unlock (pam_sm_open_session)
#include <cerrno>
#include <cstdio>
#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>
#include <vector>

namespace {
constexpr size_t BUFFER_SIZE = 128;
constexpr int TIMEOUT_SEC = 5;

struct SocketDescriptor {
  int fd = -1;
  explicit SocketDescriptor(int f) : fd(f) {}
  ~SocketDescriptor() {
    if (fd >= 0) {
      close(fd);
    }
  }
  SocketDescriptor(const SocketDescriptor &) = delete;
  SocketDescriptor &operator=(const SocketDescriptor &) = delete;
  SocketDescriptor(SocketDescriptor &&other) noexcept : fd(other.fd) {
    other.fd = -1;
  }
  SocketDescriptor &operator=(SocketDescriptor &&other) noexcept {
    if (this != &other) {
      if (fd >= 0) {
        close(fd);
      }
      fd = other.fd;
      other.fd = -1;
    }
    return *this;
  }
  [[nodiscard]] int get() const { return fd; }
  [[nodiscard]] bool isValid() const { return fd >= 0; }
};

struct SyslogManager {
  SyslogManager() {
    openlog("LinuxCamPAM", LOG_PID | LOG_NDELAY, LOG_AUTHPRIV);
  }
  ~SyslogManager() { closelog(); }
  SyslogManager(const SyslogManager &) = delete;
  SyslogManager &operator=(const SyslogManager &) = delete;
  SyslogManager(SyslogManager &&) = delete;
  SyslogManager &operator=(SyslogManager &&) = delete;
};

// RAII handles openlog/closelog automatically
// NOLINTNEXTLINE(cppcoreguidelines-avoid-non-const-global-variables)
static SyslogManager syslog_manager;

// Default path to the gnome-keyring-unlock helper.
// Override per-service in pam.d: keyring_unlock_script=/path/to/script
constexpr const char *DEFAULT_KEYRING_UNLOCK_SCRIPT =
    "/usr/local/bin/gnome-keyring-unlock";

struct SocketDescriptor {
  int fd = -1;
  explicit SocketDescriptor(int f) : fd(f) {}
  ~SocketDescriptor() {
    if (fd >= 0) { close(fd); }
  }
  SocketDescriptor(const SocketDescriptor &) = delete;
  SocketDescriptor &operator=(const SocketDescriptor &) = delete;
  SocketDescriptor(SocketDescriptor &&other) noexcept : fd(other.fd) { other.fd = -1; }
  SocketDescriptor &operator=(SocketDescriptor &&other) noexcept {
    if (this != &other) {
      if (fd >= 0) { close(fd); }
      fd = other.fd;
      other.fd = -1;
    }
    return *this;
  }
  [[nodiscard]] int get() const { return fd; }
  [[nodiscard]] bool isValid() const { return fd >= 0; }
};

struct SyslogManager {
  SyslogManager() { openlog("LinuxCamPAM", LOG_PID | LOG_NDELAY, LOG_AUTHPRIV); }
  ~SyslogManager() { closelog(); }
  SyslogManager(const SyslogManager &) = delete;
  SyslogManager &operator=(const SyslogManager &) = delete;
  SyslogManager(SyslogManager &&) = delete;
  SyslogManager &operator=(SyslogManager &&) = delete;
};

// NOLINTNEXTLINE(cppcoreguidelines-avoid-non-const-global-variables)
static SyslogManager syslog_manager;

// ---------------------------------------------------------------------------
// PAM argument helpers
// ---------------------------------------------------------------------------
std::string get_pam_arg(int argc, const char **argv, const char *key) {
  std::string prefix = std::string(key) + "=";
  for (int i = 0; i < argc; ++i) {
    if (argv[i] && std::string(argv[i]).substr(0, prefix.size()) == prefix) {
      return std::string(argv[i]).substr(prefix.size());
    }
  }
  return {};
}

bool has_pam_flag(int argc, const char **argv, const char *flag) {
  for (int i = 0; i < argc; ++i) {
    if (argv[i] && std::string(argv[i]) == flag) { return true; }
  }
  return false;
}

// ---------------------------------------------------------------------------
// Keyring unlock (best-effort, never blocks login on failure)
//
// Two modes:
//   - Normal mode: reads PAM_AUTHTOK and pipes it to the helper on stdin.
//   - TPM mode  : calls the helper with /dev/null on stdin; the script
//                 retrieves the password from the TPM itself.
//
// Helper expected on disk: unlock.py from
//   https://codeberg.org/umglurf/gnome-keyring-unlock
// or a TPM wrapper such as unlockKeyring.sh from
//   https://gist.github.com/kizzard/166470fefe8fa64d2aa65e0235115318
// ---------------------------------------------------------------------------
void try_unlock_keyring(pam_handle_t *pamh, const char *script, bool tpm_mode) {
  if (access(script, X_OK) != 0) {
    syslog(LOG_INFO,
           "Keyring unlock script not found/not executable: %s (skipping)", script);
    return;
  }

  const char *authtok = nullptr;
  if (!tpm_mode) {
    int ret = pam_get_item(pamh, PAM_AUTHTOK,
                           reinterpret_cast<const void **>(&authtok));
    if (ret != PAM_SUCCESS || authtok == nullptr) {
      syslog(LOG_INFO,
             "No PAM_AUTHTOK for keyring unlock. "
             "Use tpm_mode or stack with pam_unix.");
      return;
    }
  }

  int pipefd[2] = {-1, -1};
  if (!tpm_mode && pipe(pipefd) == -1) {
    syslog(LOG_ERR, "Keyring unlock: pipe() failed: %m");
    return;
  }

  pid_t pid = fork();
  if (pid == -1) {
    syslog(LOG_ERR, "Keyring unlock: fork() failed: %m");
    if (!tpm_mode) { close(pipefd[0]); close(pipefd[1]); }
    return;
  }

  if (pid == 0) {
    // ---- Child ----
    if (!tpm_mode) {
      close(pipefd[1]);
      if (dup2(pipefd[0], STDIN_FILENO) == -1) { _exit(1); }
      close(pipefd[0]);
    } else {
      int dn = open("/dev/null", O_RDONLY);
      if (dn != -1) { dup2(dn, STDIN_FILENO); close(dn); }
    }
    int dn_w = open("/dev/null", O_WRONLY);
    if (dn_w != -1) { dup2(dn_w, STDOUT_FILENO); dup2(dn_w, STDERR_FILENO); close(dn_w); }
    for (int fd = 3; fd < 256; ++fd) { close(fd); }
    execl(script, script, nullptr);
    _exit(127);
  }

  // ---- Parent ----
  if (!tpm_mode) {
    close(pipefd[0]);
    size_t pw_len = strlen(authtok);
    size_t written = 0;
    while (written < pw_len) {
      ssize_t n = write(pipefd[1], authtok + written, pw_len - written);
      if (n <= 0) { break; }
      written += static_cast<size_t>(n);
    }
    { ssize_t _ignored = write(pipefd[1], "\n", 1); (void)_ignored; }
    close(pipefd[1]);
  }

  // Wait with timeout
  constexpr int KEYRING_TIMEOUT_S = 10;
  for (int waited = 0; waited < KEYRING_TIMEOUT_S; ++waited) {
    int status = 0;
    pid_t r = waitpid(pid, &status, WNOHANG);
    if (r == pid) {
      if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        syslog(LOG_INFO, "Keyring unlock succeeded");
      } else if (WIFEXITED(status)) {
        syslog(LOG_NOTICE, "Keyring unlock exited with code %d", WEXITSTATUS(status));
      } else {
        syslog(LOG_NOTICE, "Keyring unlock terminated abnormally");
      }
      return;
    } else if (r == -1) {
      syslog(LOG_ERR, "Keyring unlock: waitpid error: %m");
      return;
    }
    sleep(1);
  }
  syslog(LOG_WARNING, "Keyring unlock timed out — killing helper");
  kill(pid, SIGTERM);
  sleep(1);
  kill(pid, SIGKILL);
  waitpid(pid, nullptr, 0);
}

} // namespace

// ---------------------------------------------------------------------------
// Standard PAM entry points
// ---------------------------------------------------------------------------

// NOLINTBEGIN(bugprone-easily-swappable-parameters)
PAM_EXTERN int pam_sm_setcred([[maybe_unused]] pam_handle_t *pamh,
                              [[maybe_unused]] int flags,
                              [[maybe_unused]] int argc,
                              [[maybe_unused]] const char **argv) {
  // NOLINTEND(bugprone-easily-swappable-parameters)
  return PAM_SUCCESS;
}

// NOLINTBEGIN(bugprone-easily-swappable-parameters)
PAM_EXTERN int pam_sm_acct_mgmt([[maybe_unused]] pam_handle_t *pamh,
                                [[maybe_unused]] int flags,
                                [[maybe_unused]] int argc,
                                [[maybe_unused]] const char **argv) {
  // NOLINTEND(bugprone-easily-swappable-parameters)
  return PAM_SUCCESS;
}

// NOLINTBEGIN(bugprone-easily-swappable-parameters)
PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh,
                                   [[maybe_unused]] int flags,
                                   [[maybe_unused]] int argc,
                                   [[maybe_unused]] const char **argv)
// NOLINTEND(bugprone-easily-swappable-parameters)
{
  try {
    const char *user = nullptr;
    int retval = pam_get_user(pamh, &user, NULL);
    if (retval != PAM_SUCCESS) {
      return retval;
    }

    struct passwd *pwd = getpwnam(user);
    if (pwd) {
      PamConfig config = load_pam_config(linuxcampam::CONFIG_PATH);

      // If min_uid is 0, the check is disabled.
      // Otherwise, skip authentication for any user with UID < min_uid.
      if (config.min_uid > 0 && pwd->pw_uid < config.min_uid) {
        syslog(LOG_INFO, "Skipping auth for system user: %s (UID %d < %d)",
               user, pwd->pw_uid, config.min_uid);
        return PAM_IGNORE;
      }
    } else {
      // User doesn't exist locally (or NSS failed).
      // Since we can't verify the UID, we have to assume they aren't allowed.
      syslog(LOG_WARNING, "User not found in system database: %s", user);
      return PAM_USER_UNKNOWN;
    }
    // Create a socket to the authentication service
    if (flags & PAM_SILENT) {
      // If Silent, just debug log the version.
      syslog(LOG_DEBUG, "pam_linuxcampam version %s", LINUXCAMPAM_VERSION);
    } else {
      // Otherwise, log the version.
      syslog(LOG_INFO, "pam_linuxcampam version %s", LINUXCAMPAM_VERSION);
    }

    SocketDescriptor sock(socket(AF_UNIX, SOCK_STREAM, 0));
    if (!sock.isValid()) {
      syslog(LOG_ERR, "Failed to create socket: %m");
      return PAM_AUTHINFO_UNAVAIL;
    }

    struct sockaddr_un addr = {};
    addr.sun_family = AF_UNIX;
    // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-array-to-pointer-decay)
    (void)std::snprintf(addr.sun_path, sizeof(addr.sun_path), "%s",
                        linuxcampam::SOCKET_PATH);

    // Set timeout (exceeds detection timeout of 3s)
    // to avoid aborting while the camera is still looking.
    struct timeval tv = {};
    tv.tv_sec = TIMEOUT_SEC;
    tv.tv_usec = 0;
    // NOLINTBEGIN(cppcoreguidelines-pro-type-reinterpret-cast)
    setsockopt(sock.get(), SOL_SOCKET, SO_RCVTIMEO,
               reinterpret_cast<const char *>(&tv), sizeof tv);
    setsockopt(sock.get(), SOL_SOCKET, SO_SNDTIMEO,
               reinterpret_cast<const char *>(&tv), sizeof tv);
    // NOLINTEND(cppcoreguidelines-pro-type-reinterpret-cast)

    // NOLINTBEGIN(cppcoreguidelines-pro-type-reinterpret-cast)
    if (connect(sock.get(), reinterpret_cast<struct sockaddr *>(&addr),
                sizeof(addr)) == -1) {
      // NOLINTEND(cppcoreguidelines-pro-type-reinterpret-cast)
      syslog(LOG_INFO, "Could not connect to linuxcampamd socket - service may "
                       "not be running");
      return PAM_AUTHINFO_UNAVAIL;
    }

    // Use protocol to serialize request
    linuxcampam::protocol::Request req{
        linuxcampam::protocol::Command::AUTH_REQUEST, {user}};
    std::string reqStr = req.serialize();

    if (send(sock.get(), reqStr.c_str(), reqStr.length(), 0) < 0) {
      syslog(LOG_ERR, "Failed to send auth request: %m");
      return PAM_AUTHINFO_UNAVAIL;
    }

    std::array<char, BUFFER_SIZE> buffer = {};
    ssize_t valread = read(sock.get(), buffer.data(), buffer.size() - 1);

    if (valread > 0) {
      std::string resp(buffer.data());
      if (resp.find("AUTH_SUCCESS") != std::string::npos) {
        // Display Welcome Message
        struct pam_message msg = {};
        const struct pam_message *msgp = nullptr;
        struct pam_response *resp_pam = nullptr;

        std::string welcome_msg =
            "LinuxCamPAM: Welcome, " + std::string(user) + "!";

        // PAM standard requires a mutable char* for messages.
        // We create a writable copy here to ensure strict API compliance.
        std::vector<char> msg_buf(welcome_msg.begin(), welcome_msg.end());
        msg_buf.push_back('\0');
        char *msg_cstr = msg_buf.data();

        msg.msg_style = PAM_TEXT_INFO;
        msg.msg = msg_cstr;
        msgp = &msg;

        const struct pam_conv *conv = nullptr;
        // NOLINTBEGIN(cppcoreguidelines-pro-type-reinterpret-cast)
        int ret = pam_get_item(pamh, PAM_CONV,
                               reinterpret_cast<const void **>(&conv));
        // NOLINTEND(cppcoreguidelines-pro-type-reinterpret-cast)
        if (ret == PAM_SUCCESS && conv != NULL) {
          // Best effort message, ignore return code
          conv->conv(1, &msgp, &resp_pam, conv->appdata_ptr);
          if (resp_pam) {
            std::unique_ptr<struct pam_response, decltype(&free)> resp_ptr(
                resp_pam, free);
          }
        }

        syslog(LOG_INFO, "Authentication successful for user: %s", user);
        return PAM_SUCCESS;
      } else {
        syslog(LOG_NOTICE, "Authentication failed for user: %s (Response: %s)",
               user, resp.c_str());
      }
    } else {
      syslog(LOG_ERR, "Failed to read response from service");
    }
  } catch (const std::exception &e) {
    syslog(LOG_ERR, "LinuxCamPAM: Exception during authentication: %s",
           e.what());
    return PAM_AUTHINFO_UNAVAIL;
  } catch (...) {
    syslog(LOG_ERR, "LinuxCamPAM: Unknown exception during authentication");
    return PAM_AUTHINFO_UNAVAIL;
  }
  return PAM_AUTH_ERR;
}

// ---------------------------------------------------------------------------
// pam_sm_open_session — unlock the GNOME Keyring right after login
// ---------------------------------------------------------------------------
//
// Add to /etc/pam.d/gdm-password (or common-session) AFTER the auth block:
//
//   # TPM mode (recommended for face/fingerprint login — no password needed):
//   session optional pam_linuxcampam.so tpm_mode keyring_unlock_script=/usr/local/bin/unlockKeyring.sh
//
//   # Password mode (works when pam_unix already cached PAM_AUTHTOK):
//   session optional pam_linuxcampam.so keyring_unlock_script=/usr/local/bin/gnome-keyring-unlock
//
// NOLINTBEGIN(bugprone-easily-swappable-parameters)
PAM_EXTERN int pam_sm_open_session(pam_handle_t *pamh,
                                   [[maybe_unused]] int flags,
                                   int argc, const char **argv)
// NOLINTEND(bugprone-easily-swappable-parameters)
{
  std::string script = get_pam_arg(argc, argv, "keyring_unlock_script");
  if (script.empty()) { script = DEFAULT_KEYRING_UNLOCK_SCRIPT; }

  bool tpm_mode = has_pam_flag(argc, argv, "tpm_mode");

  syslog(LOG_DEBUG,
         "LinuxCamPAM open_session: keyring unlock (script=%s, tpm_mode=%s)",
         script.c_str(), tpm_mode ? "yes" : "no");

  try_unlock_keyring(pamh, script.c_str(), tpm_mode);

  // Always succeed: keyring unlock is best-effort.
  return PAM_SUCCESS;
}

// NOLINTBEGIN(bugprone-easily-swappable-parameters)
PAM_EXTERN int pam_sm_close_session([[maybe_unused]] pam_handle_t *pamh,
                                    [[maybe_unused]] int flags,
                                    [[maybe_unused]] int argc,
                                    [[maybe_unused]] const char **argv) {
  return PAM_SUCCESS;
}
// NOLINTEND(bugprone-easily-swappable-parameters)
