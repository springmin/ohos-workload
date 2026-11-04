// OpenSSL trust-store policy for the native host. See host_trust.h for the contract.
#define _POSIX_C_SOURCE 200809L

#include "host_trust.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void SetStatus(char* status_line, size_t status_size, const char* format, ...) {
    if (status_line == NULL || status_size == 0) {
        return;
    }
    va_list args;
    va_start(args, format);
    vsnprintf(status_line, status_size, format, args);
    va_end(args);
}

static int IsReadableFile(const char* path) {
    if (path == NULL || path[0] == '\0') {
        return 0;
    }
    struct stat info;
    if (stat(path, &info) != 0 || !S_ISREG(info.st_mode)) {
        return 0;
    }
    return access(path, R_OK) == 0;
}

static int IsDirectory(const char* path) {
    if (path == NULL || path[0] == '\0') {
        return 0;
    }
    struct stat info;
    return stat(path, &info) == 0 && S_ISDIR(info.st_mode);
}

static int SetEnv(const char* name, const char* value, char* status_line, size_t status_size,
                  const char* mode) {
    if (setenv(name, value, 1) != 0) {
        SetStatus(status_line, status_size, "trust: mode=%s error=setenv-%s-errno-%d", mode, name,
                  errno);
        return -1;
    }
    return 0;
}

static int UnsetEnv(const char* name, char* status_line, size_t status_size, const char* mode) {
    if (unsetenv(name) != 0) {
        SetStatus(status_line, status_size, "trust: mode=%s error=unsetenv-%s-errno-%d", mode,
                  name, errno);
        return -1;
    }
    return 0;
}

int OhosHostApplyTrustPolicy(const char* mode, const char* ca_file, const char* system_ca_dir,
                             char* status_line, size_t status_size) {
    if (status_line != NULL && status_size > 0) {
        status_line[0] = '\0';
    }

    if (mode == NULL || mode[0] == '\0') {
        SetStatus(status_line, status_size, "trust: unchanged");
        return 0;
    }

    const char* system_dir =
        (system_ca_dir != NULL && system_ca_dir[0] != '\0') ? system_ca_dir
                                                            : OHOS_HOST_TRUST_DEFAULT_SYSTEM_DIR;
    int have_system = IsDirectory(system_dir);
    int have_ca = IsReadableFile(ca_file);

    if (strcmp(mode, OHOS_HOST_TRUST_MODE_SYSTEM) == 0) {
        if (UnsetEnv("SSL_CERT_FILE", status_line, status_size, mode) != 0) {
            return -1;
        }
        if (have_system) {
            if (SetEnv("SSL_CERT_DIR", system_dir, status_line, status_size, mode) != 0) {
                return -1;
            }
        } else if (UnsetEnv("SSL_CERT_DIR", status_line, status_size, mode) != 0) {
            return -1;
        }
        SetStatus(status_line, status_size, "trust: mode=system dir=%s app=0 system=%d", system_dir,
                  have_system);
        return 0;
    }

    if (strcmp(mode, OHOS_HOST_TRUST_MODE_APP) == 0) {
        if (!have_ca) {
            SetStatus(status_line, status_size, "trust: mode=app error=missing-ca ca=%s",
                      ca_file != NULL ? ca_file : "");
            return -1;
        }
        if (SetEnv("SSL_CERT_FILE", ca_file, status_line, status_size, mode) != 0) {
            return -1;
        }
        if (SetEnv("SSL_CERT_DIR", "", status_line, status_size, mode) != 0) {
            return -1;
        }
        SetStatus(status_line, status_size, "trust: mode=app ca=%s app=1 system=0", ca_file);
        return 0;
    }

    if (strcmp(mode, OHOS_HOST_TRUST_MODE_BOTH) == 0) {
        if (have_ca) {
            if (SetEnv("SSL_CERT_FILE", ca_file, status_line, status_size, mode) != 0) {
                return -1;
            }
        } else if (UnsetEnv("SSL_CERT_FILE", status_line, status_size, mode) != 0) {
            return -1;
        }

        if (have_system) {
            if (SetEnv("SSL_CERT_DIR", system_dir, status_line, status_size, mode) != 0) {
                return -1;
            }
        } else if (have_ca) {
            // App-only fallback: no system directory, but the app CA is usable. The empty
            // value keeps the platform/default directory from being re-added.
            if (SetEnv("SSL_CERT_DIR", "", status_line, status_size, mode) != 0) {
                return -1;
            }
        } else if (UnsetEnv("SSL_CERT_DIR", status_line, status_size, mode) != 0) {
            return -1;
        }

        SetStatus(status_line, status_size,
                  "trust: mode=both ca=%s dir=%s app=%d system=%d",
                  have_ca ? ca_file : "", system_dir, have_ca, have_system);
        return 0;
    }

    SetStatus(status_line, status_size, "trust: mode=%s error=invalid-mode", mode);
    return -1;
}
