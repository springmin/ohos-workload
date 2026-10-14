// Host status file helpers (DEVICE-ROUND-57 follow-up).
//
// The device image does not route the host's stdout/stderr to hilog (libhilog_ndk is absent),
// so every host diagnostic that must leave the app sandbox goes through
// <filesDir>/dotnet-status.txt: the ArkTS shell reads the file in-process (it is 0600 in the
// ability's files dir, unreadable for the hdc shell) and mirrors its tail to hilog. The W10
// helper has always appended the jitfort/globalization/probe lines there; this module adds the
// launch mode decision (interp= / runtime-mode= / xwe= with their sources and the interp=3
// r2r/wbcopy switches) so a device round can read the host's route even when hilog misses the
// host's own lines (measured on HAD-W32: only the status-file mirror carries them).
//
// Pure C (POSIX file API only, no NAPI and no OpenHarmony headers), so the formatting and the
// append semantics compile and run off-device; scripts/selftest-host-status.sh drives
// host_status_test.c and the mutation red control.
#ifndef OHOS_HOST_STATUS_H
#define OHOS_HOST_STATUS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// One status line is capped at this many characters with a trailing "..."; the managed side
// (OpenHarmonyApp.FlattenCallbackMessage) uses the same cap.
#define OHOS_HOST_STATUS_LINE_MAX 600

// Appends one flattened, capped status line to <dir>/dotnet-status.txt (0600, create+append).
// Control characters become spaces, the line is capped at OHOS_HOST_STATUS_LINE_MAX with a
// trailing "...", one newline terminates it. Returns 1 when the line was written, 0 for a
// NULL/empty dir or message, an unjoinable path, an unwritable file or a short write; never
// fails the caller (best effort by design).
int OhosHostStatusAppendLine(const char* dir, const char* message);

// Formats the one-line runtime mode decision (no prefix; the caller appends it):
//
//   OHOS_HOST mode caller=<c> interp=<v> source=<default|file|manifest>
//                  runtime-mode=<jit|aot|interp> source=<default|file|manifest>
//                  xwe=<0|1> source=<file|default> r2r=<default|off> wbcopy=<default|off>
//
// The interp=/runtime-mode=/xwe= token shapes mirror the host's hilog lines so the existing
// scripts/tester-run.sh exec-mem readers match a mirrored line; r2r/wbcopy state the interp=3
// switches (ReadyToRun and the mutable GC write-barrier copy both off). Returns 1 when the
// line fits, 0 for NULL arguments or truncation (out is reset to "" in that case).
int OhosHostStatusFormatModeLine(char* out, size_t out_size, const char* caller,
                                 const char* interp, const char* interp_source,
                                 const char* runtime_mode, const char* mode_source,
                                 const char* xwe, const char* xwe_source,
                                 const char* r2r, const char* wbcopy);

#ifdef __cplusplus
}
#endif

#endif  // OHOS_HOST_STATUS_H
