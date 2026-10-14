// Host status file helpers (DEVICE-ROUND-57 follow-up); see host_status.h for the contract.
//
// This file is pure C so the off-device unit test (host_status_test.c) exercises the exact
// shipped append/format code: the flatten/cap rules, the missing-directory semantics and the
// mode-line shape.
#include "host_status.h"

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

// Same join shape as the host's private path_join: a '/' is always inserted. Returns 0 on
// success, -1 when the result does not fit (dst is left truncated but never overrun).
static int JoinPath(char* dst, size_t dst_size, const char* dir, const char* file) {
    int written = snprintf(dst, dst_size, "%s/%s", dir, file);
    return written > 0 && (size_t)written < dst_size ? 0 : -1;
}

int OhosHostStatusAppendLine(const char* dir, const char* message) {
    if (dir == NULL || dir[0] == '\0' || message == NULL) {
        return 0;
    }
    char path[4096];
    if (JoinPath(path, sizeof(path), dir, "dotnet-status.txt") != 0) {
        return 0;
    }
    char flat[OHOS_HOST_STATUS_LINE_MAX + 4];
    size_t length = strlen(message);
    size_t keep = length < OHOS_HOST_STATUS_LINE_MAX ? length : OHOS_HOST_STATUS_LINE_MAX;
    for (size_t i = 0; i < keep; i++) {
        unsigned char c = (unsigned char)message[i];
        flat[i] = (c < 0x20 || c == 0x7f) ? ' ' : (char)c;
    }
    if (length > keep) {
        flat[keep++] = '.';
        flat[keep++] = '.';
        flat[keep++] = '.';
    }
    flat[keep] = '\0';
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) {
        return 0;
    }
    ssize_t wrote = write(fd, flat, keep);
    ssize_t newline = wrote == (ssize_t)keep ? write(fd, "\n", 1) : (ssize_t)-1;
    close(fd);
    return wrote == (ssize_t)keep && newline == 1;
}

int OhosHostStatusFormatModeLine(char* out, size_t out_size, const char* caller,
                                 const char* interp, const char* interp_source,
                                 const char* runtime_mode, const char* mode_source,
                                 const char* xwe, const char* xwe_source,
                                 const char* r2r, const char* wbcopy) {
    if (out == NULL || out_size == 0) {
        return 0;
    }
    out[0] = '\0';
    if (caller == NULL || interp == NULL || interp_source == NULL || runtime_mode == NULL ||
        mode_source == NULL || xwe == NULL || xwe_source == NULL || r2r == NULL ||
        wbcopy == NULL) {
        return 0;
    }
    int written = snprintf(out, out_size,
                           "OHOS_HOST mode caller=%s interp=%s source=%s runtime-mode=%s "
                           "source=%s xwe=%s source=%s r2r=%s wbcopy=%s",
                           caller, interp, interp_source, runtime_mode, mode_source, xwe,
                           xwe_source, r2r, wbcopy);
    if (written <= 0 || (size_t)written >= out_size) {
        out[0] = '\0';
        return 0;
    }
    return 1;
}
