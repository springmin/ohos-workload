// OpenSSL trust-store policy for the native host.
//
// The HAP payload carries a small trust.json next to trust-ca.pem. The host applies it before
// hostfxr/coreclr starts so OpenSSL and the managed X509 root-store provider see the same
// environment:
//
//   system : SSL_CERT_FILE unset, SSL_CERT_DIR=<system dir>
//   app    : SSL_CERT_FILE=<ca file>, SSL_CERT_DIR="" (no system fallback)
//   both   : SSL_CERT_FILE=<ca file>, SSL_CERT_DIR=<system dir>
//
// The helper is pure POSIX C so it can be unit-tested on the development host. Path validity is
// checked here rather than in the caller; a missing system directory is not fatal (the platform
// may expose its own default store), while an app-only request without a readable CA file is an
// error and leaves the process trust environment unchanged.
#ifndef OHOS_HOST_TRUST_H
#define OHOS_HOST_TRUST_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OHOS_HOST_TRUST_MODE_SYSTEM "system"
#define OHOS_HOST_TRUST_MODE_APP "app"
#define OHOS_HOST_TRUST_MODE_BOTH "both"
// security_certificate_manager installs its 125 preloaded OpenSSL-hashed CAs into
// /system/etc/security/certificates (config/BUILD.gn relative_install_dir
// "security/certificates"). /etc/ssl/certs is not part of that part and is only a
// compatibility fallback for images that ship a curl/ca-certificates bundle there.
#define OHOS_HOST_TRUST_DEFAULT_SYSTEM_DIR "/system/etc/security/certificates"
#define OHOS_HOST_TRUST_FALLBACK_SYSTEM_DIR "/etc/ssl/certs"
#define OHOS_HOST_TRUST_STATUS_MAX 512

// Applies the requested trust policy to this process.
//
// mode          "system", "app", "both" (NULL/empty means leave the environment unchanged)
// ca_file       PEM bundle for app/both; ignored for system
// system_ca_dir system certificate directory; NULL/empty or the default path uses
//               /system/etc/security/certificates, falling back to /etc/ssl/certs when the
//               system part is absent
// status_line   receives one human-readable status line (always NUL-terminated when size > 0)
//
// Returns 0 when the policy was applied or intentionally left unchanged, -1 for an invalid
// mode/path or a failed setenv/unsetenv. The host logs the status line but never fails a launch
// solely because trust configuration is unavailable.
int OhosHostApplyTrustPolicy(const char* mode, const char* ca_file, const char* system_ca_dir,
                             char* status_line, size_t status_size);

#ifdef __cplusplus
}
#endif

#endif  // OHOS_HOST_TRUST_H
