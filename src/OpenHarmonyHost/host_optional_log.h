// hilog degradation shim.
//
// libhilog_ndk.z.so is NOT part of the guaranteed system library set on every HarmonyOS
// image (a reduced image was observed without it), so the host must not carry it in
// DT_NEEDED. Instead OH_LOG_Print is resolved with dlopen/dlsym at first use:
//   - when the symbol resolves, every OH_LOG_* macro keeps its exact hilog behavior;
//   - when it does not, the message is written to stderr with the {public}/{private}
//     privacy markers stripped so the output stays readable.
// The pointer is cached (pthread_once in host_optional.c), never re-resolved per call.
//
// Include this header AFTER the OpenHarmony NDK headers of the translation unit: it
// deliberately redefines the OH_LOG_Print name for the call sites below it.

#ifndef OHOS_HOST_OPTIONAL_LOG_H
#define OHOS_HOST_OPTIONAL_LOG_H

#include <hilog/log.h>

#ifdef __cplusplus
extern "C" {
#endif

// Loads every optional library/symbol table once (see host_optional.c). Safe from any
// thread; the wrappers below call it before touching a pointer.
void ohos_host_optional_ensure(void);

// Resolved hilog entry point; NULL when libhilog_ndk.z.so is absent or stripped.
extern int (*g_ohos_host_optional_log_print)(LogType type, LogLevel level, unsigned int domain,
                                             const char *tag, const char *fmt, ...);

// stderr fallback used when g_ohos_host_optional_log_print is NULL. Exposed for tests.
int ohos_host_optional_log_print_fallback(LogType type, LogLevel level, unsigned int domain,
                                          const char *tag, const char *fmt, ...);

#ifdef __cplusplus
}
#endif

// OH_LOG_INFO/WARN/ERROR/... expand to OH_LOG_Print(...), so this single redirect sends
// every hilog call through the resolved pointer (or the fallback) without touching the
// call sites. The target is a real variadic function, so __VA_ARGS__ is forwarded
// verbatim and the available-library behavior is unchanged.
#define OH_LOG_Print(type, level, domain, tag, ...)                                        \
    (ohos_host_optional_ensure(),                                                          \
     g_ohos_host_optional_log_print != NULL                                                \
         ? g_ohos_host_optional_log_print((type), (level), (domain), (tag), __VA_ARGS__)   \
         : ohos_host_optional_log_print_fallback((type), (level), (domain), (tag),         \
                                                 __VA_ARGS__))

#endif  // OHOS_HOST_OPTIONAL_LOG_H
