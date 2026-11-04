// Off-device unit tests for the host OpenSSL trust-store policy.
// Pure POSIX C: no NAPI, no OpenHarmony headers, no SDK and no device.
// Run through scripts/selftest-host-trust.sh.
#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "host_trust.h"

static int g_checks;
static int g_failures;

static void Check(int ok, const char* label) {
    g_checks++;
    if (ok) {
        printf("[PASS] %s\n", label);
    } else {
        g_failures++;
        printf("[FAIL] %s\n", label);
    }
}

static int EnvIs(const char* name, const char* expected) {
    const char* value = getenv(name);
    if (expected == NULL) {
        return value == NULL;
    }
    return value != NULL && strcmp(value, expected) == 0;
}

static void ResetEnv(void) {
    unsetenv("SSL_CERT_FILE");
    unsetenv("SSL_CERT_DIR");
}

static void WriteFile(const char* path, const char* text) {
    FILE* file = fopen(path, "wb");
    if (file == NULL) {
        perror(path);
        exit(1);
    }
    fputs(text, file);
    fclose(file);
}

int main(void) {
    const char* base = getenv("TMPDIR");
    if (base == NULL || base[0] == '\0') {
        base = "/tmp";
    }
    char dir[4096];
    snprintf(dir, sizeof(dir), "%s/host-trust-test.XXXXXX", base);
    if (mkdtemp(dir) == NULL) {
        printf("[FAIL] setup: cannot create a temp dir under %s\n", base);
        printf("host-trust: 1 checks, 1 failure(s)\n");
        return 1;
    }

    char ca_file[4200];
    char system_dir[4200];
    char missing_dir[4200];
    snprintf(ca_file, sizeof(ca_file), "%s/ca.pem", dir);
    snprintf(system_dir, sizeof(system_dir), "%s/system-certs", dir);
    snprintf(missing_dir, sizeof(missing_dir), "%s/missing-certs", dir);
    WriteFile(ca_file, "-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----\n");
    mkdir(system_dir, 0700);

    char status[OHOS_HOST_TRUST_STATUS_MAX];

    ResetEnv();
    Check(OhosHostApplyTrustPolicy(NULL, ca_file, system_dir, status, sizeof(status)) == 0 &&
              strstr(status, "unchanged") != NULL,
          "NULL mode leaves the environment unchanged");
    Check(EnvIs("SSL_CERT_FILE", NULL) && EnvIs("SSL_CERT_DIR", NULL),
          "NULL mode does not create trust variables");

    ResetEnv();
    setenv("SSL_CERT_FILE", "/stale/ca.pem", 1);
    Check(OhosHostApplyTrustPolicy(OHOS_HOST_TRUST_MODE_SYSTEM, ca_file, system_dir, status,
                                   sizeof(status)) == 0,
          "system mode applies");
    Check(EnvIs("SSL_CERT_FILE", NULL), "system mode removes SSL_CERT_FILE");
    Check(EnvIs("SSL_CERT_DIR", system_dir), "system mode points SSL_CERT_DIR at the system store");
    Check(strstr(status, "app=0") != NULL && strstr(status, "system=1") != NULL,
          "system status reports app=0 system=1");

    ResetEnv();
    Check(OhosHostApplyTrustPolicy(OHOS_HOST_TRUST_MODE_APP, ca_file, system_dir, status,
                                   sizeof(status)) == 0,
          "app mode applies");
    Check(EnvIs("SSL_CERT_FILE", ca_file), "app mode points SSL_CERT_FILE at the bundle");
    Check(EnvIs("SSL_CERT_DIR", ""), "app mode suppresses the system certificate directory");
    Check(strstr(status, "app=1") != NULL && strstr(status, "system=0") != NULL,
          "app status reports app=1 system=0");

    ResetEnv();
    Check(OhosHostApplyTrustPolicy(OHOS_HOST_TRUST_MODE_APP, "/definitely/missing/ca.pem", system_dir,
                                   status, sizeof(status)) == -1,
          "app mode without a readable bundle fails");
    Check(EnvIs("SSL_CERT_FILE", NULL) && EnvIs("SSL_CERT_DIR", NULL),
          "failed app mode leaves both variables unchanged");
    Check(strstr(status, "missing-ca") != NULL, "failed app mode names the missing CA");

    ResetEnv();
    Check(OhosHostApplyTrustPolicy(OHOS_HOST_TRUST_MODE_BOTH, ca_file, system_dir, status,
                                   sizeof(status)) == 0,
          "both mode applies");
    Check(EnvIs("SSL_CERT_FILE", ca_file) && EnvIs("SSL_CERT_DIR", system_dir),
          "both mode sets the app file and the system directory");
    Check(strstr(status, "app=1") != NULL && strstr(status, "system=1") != NULL,
          "both status reports app=1 system=1");

    ResetEnv();
    Check(OhosHostApplyTrustPolicy(OHOS_HOST_TRUST_MODE_BOTH, ca_file, missing_dir, status,
                                   sizeof(status)) == 0,
          "both mode with a missing system directory falls back to app-only");
    Check(EnvIs("SSL_CERT_FILE", ca_file) && EnvIs("SSL_CERT_DIR", ""),
          "the app-only fallback suppresses the default directory");
    Check(strstr(status, "system=0") != NULL, "fallback status reports system=0");

    ResetEnv();
    Check(OhosHostApplyTrustPolicy(OHOS_HOST_TRUST_MODE_BOTH, "", system_dir, status,
                                   sizeof(status)) == 0,
          "both mode without an app bundle applies system-only");
    Check(EnvIs("SSL_CERT_FILE", NULL) && EnvIs("SSL_CERT_DIR", system_dir),
          "system-only fallback keeps the system directory");

    ResetEnv();
    Check(OhosHostApplyTrustPolicy("invalid", ca_file, system_dir, status, sizeof(status)) == -1,
          "an unknown mode is rejected");
    Check(EnvIs("SSL_CERT_FILE", NULL) && EnvIs("SSL_CERT_DIR", NULL),
          "an unknown mode leaves both variables unchanged");
    Check(strstr(status, "invalid-mode") != NULL, "the unknown-mode status names the failure");

    ResetEnv();
    Check(OhosHostApplyTrustPolicy(OHOS_HOST_TRUST_MODE_SYSTEM, ca_file, missing_dir, status,
                                   sizeof(status)) == 0,
          "system mode without a system directory is not fatal");
    Check(EnvIs("SSL_CERT_FILE", NULL) && EnvIs("SSL_CERT_DIR", NULL),
          "missing system directory leaves both variables unset");

    printf("host-trust: %d checks, %d failure(s)\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
