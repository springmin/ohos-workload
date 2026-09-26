// Runtime resolution of the optional OpenHarmony system libraries (see host_optional.h).
//
// Every group is resolved once, on first use, through dlopen/dlsym:
//   - dlopen candidates are the public sonames of the reduced-system-image libraries;
//   - RTLD_DEFAULT is tried as well, so a symbol provided by an already-loaded library
//     (or by a device that keeps the library but not its DT_NEEDED entry) still resolves;
//   - a failed dlopen/dlsym leaves the pointer NULL and disables only that feature.
// The resolved pointers are cached for the process lifetime; no dlsym per frame and no
// dlclose (the handle must stay valid for the cached pointers).

#include "host_optional.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

OhosHostOptionalApis g_ohos_host_optional;
int (*g_ohos_host_optional_log_print)(LogType, LogLevel, unsigned int, const char *, const char *,
                                      ...) = NULL;

static pthread_once_t g_ohos_host_optional_once = PTHREAD_ONCE_INIT;

// Groups need at most two sonames (image_source + pixelmap).
#define OHOS_HOST_OPTIONAL_MAX_HANDLES 2

typedef struct {
    const char *const *sonames;
    size_t soname_count;
    void *handles[OHOS_HOST_OPTIONAL_MAX_HANDLES];
    size_t handle_count;
} OhosHostOptionalLibSet;

static void OhosHostOptionalOpen(OhosHostOptionalLibSet *libs) {
    for (size_t i = 0; i < libs->soname_count && libs->handle_count < OHOS_HOST_OPTIONAL_MAX_HANDLES;
         i++) {
        void *handle = dlopen(libs->sonames[i], RTLD_LAZY | RTLD_LOCAL);
        if (handle != NULL) {
            libs->handles[libs->handle_count++] = handle;
        }
    }
}

static void *OhosHostOptionalResolve(const OhosHostOptionalLibSet *libs, const char *name) {
    for (size_t i = 0; i < libs->handle_count; i++) {
        void *symbol = dlsym(libs->handles[i], name);
        if (symbol != NULL) {
            return symbol;
        }
    }
    // No candidate handle (library absent or not dlopen-able): an already-loaded library
    // may still provide the symbol (e.g. libace_ndk.z.so is a required dependency).
    return dlsym(RTLD_DEFAULT, name);
}

// Assigns one resolved symbol and records a miss. The C-style cast from void* is the
// POSIX dlsym contract; the pointer field supplies the exact function type.
#define OHOS_HOST_OPTIONAL_RESOLVE(group, field, name)                                          \
    do {                                                                                        \
        g_ohos_host_optional.group.field =                                                      \
            (__typeof__(g_ohos_host_optional.group.field))OhosHostOptionalResolve(&libs, name);  \
        if (g_ohos_host_optional.group.field == NULL) {                                         \
            missing = true;                                                                     \
        }                                                                                       \
    } while (0)

static void OhosHostOptionalAppendMissing(char *buffer, size_t size, size_t *used,
                                          const char *name) {
    if (*used >= size) {
        return;
    }
    int written = snprintf(buffer + *used, size - *used, "%s%s", *used == 0 ? "" : " ", name);
    if (written <= 0) {
        return;
    }
    size_t length = (size_t)written;
    *used += length < size - *used ? length : size - *used - 1;
}

static void OhosHostOptionalLoad(void) {
    char missing_names[192];
    size_t missing_used = 0;
    bool missing;

    // IME text input. libace_ndk.z.so is a required dependency, but reduced images were
    // observed without its API 12+ entry points, so it is resolved like any optional group.
    {
        static const char *const sonames[] = {"libace_ndk.z.so"};
        OhosHostOptionalLibSet libs = {sonames, 1, {NULL, NULL}, 0};
        OhosHostOptionalOpen(&libs);
        missing = false;
        OHOS_HOST_OPTIONAL_RESOLVE(ime, TextEditorProxy_Create, "OH_TextEditorProxy_Create");
        OHOS_HOST_OPTIONAL_RESOLVE(ime, TextEditorProxy_SetInsertTextFunc,
                                   "OH_TextEditorProxy_SetInsertTextFunc");
        OHOS_HOST_OPTIONAL_RESOLVE(ime, TextEditorProxy_SetDeleteForwardFunc,
                                   "OH_TextEditorProxy_SetDeleteForwardFunc");
        OHOS_HOST_OPTIONAL_RESOLVE(ime, TextEditorProxy_SetDeleteBackwardFunc,
                                   "OH_TextEditorProxy_SetDeleteBackwardFunc");
        OHOS_HOST_OPTIONAL_RESOLVE(ime, TextEditorProxy_SetGetTextConfigFunc,
                                   "OH_TextEditorProxy_SetGetTextConfigFunc");
        OHOS_HOST_OPTIONAL_RESOLVE(ime, AttachOptions_Create, "OH_AttachOptions_Create");
        OHOS_HOST_OPTIONAL_RESOLVE(ime, AttachOptions_Destroy, "OH_AttachOptions_Destroy");
        OHOS_HOST_OPTIONAL_RESOLVE(ime, InputMethodController_Attach,
                                   "OH_InputMethodController_Attach");
        OHOS_HOST_OPTIONAL_RESOLVE(ime, InputMethodController_Detach,
                                   "OH_InputMethodController_Detach");
        OHOS_HOST_OPTIONAL_RESOLVE(ime, TextEditorProxy_Destroy,
                                   "OH_TextEditorProxy_Destroy");
        OHOS_HOST_OPTIONAL_RESOLVE(ime, InputMethodProxy_ShowKeyboard,
                                   "OH_InputMethodProxy_ShowKeyboard");
        OHOS_HOST_OPTIONAL_RESOLVE(ime, InputMethodProxy_HideKeyboard,
                                   "OH_InputMethodProxy_HideKeyboard");
        g_ohos_host_optional.ime.available = !missing;
        if (missing) {
            OhosHostOptionalAppendMissing(missing_names, sizeof(missing_names), &missing_used,
                                          "ime");
        }
    }

    // Buffer presentation for the XComponent surface.
    {
        static const char *const sonames[] = {"libnative_window.so"};
        OhosHostOptionalLibSet libs = {sonames, 1, {NULL, NULL}, 0};
        OhosHostOptionalOpen(&libs);
        missing = false;
        OHOS_HOST_OPTIONAL_RESOLVE(native_window, HandleOpt,
                                   "OH_NativeWindow_NativeWindowHandleOpt");
        OHOS_HOST_OPTIONAL_RESOLVE(native_window, RequestBuffer,
                                   "OH_NativeWindow_NativeWindowRequestBuffer");
        OHOS_HOST_OPTIONAL_RESOLVE(native_window, FlushBuffer,
                                   "OH_NativeWindow_NativeWindowFlushBuffer");
        OHOS_HOST_OPTIONAL_RESOLVE(native_window, GetBufferHandleFromNative,
                                   "OH_NativeWindow_GetBufferHandleFromNative");
        g_ohos_host_optional.native_window.available = !missing;
        if (missing) {
            OhosHostOptionalAppendMissing(missing_names, sizeof(missing_names), &missing_used,
                                          "native-window");
        }
    }

    // Vibration.
    {
        static const char *const sonames[] = {"libohvibrator.z.so"};
        OhosHostOptionalLibSet libs = {sonames, 1, {NULL, NULL}, 0};
        OhosHostOptionalOpen(&libs);
        missing = false;
        OHOS_HOST_OPTIONAL_RESOLVE(vibrator, PlayVibration, "OH_Vibrator_PlayVibration");
        g_ohos_host_optional.vibrator.available = !missing;
        if (missing) {
            OhosHostOptionalAppendMissing(missing_names, sizeof(missing_names), &missing_used,
                                          "vibrator");
        }
    }

    // Sensors.
    {
        static const char *const sonames[] = {"libohsensor.so"};
        OhosHostOptionalLibSet libs = {sonames, 1, {NULL, NULL}, 0};
        OhosHostOptionalOpen(&libs);
        missing = false;
        OHOS_HOST_OPTIONAL_RESOLVE(sensor, CreateInfos, "OH_Sensor_CreateInfos");
        OHOS_HOST_OPTIONAL_RESOLVE(sensor, GetInfos, "OH_Sensor_GetInfos");
        OHOS_HOST_OPTIONAL_RESOLVE(sensor, DestroyInfos, "OH_Sensor_DestroyInfos");
        OHOS_HOST_OPTIONAL_RESOLVE(sensor, InfoGetType, "OH_SensorInfo_GetType");
        OHOS_HOST_OPTIONAL_RESOLVE(sensor, CreateSubscriptionId,
                                   "OH_Sensor_CreateSubscriptionId");
        OHOS_HOST_OPTIONAL_RESOLVE(sensor, SubscriptionIdSetType,
                                   "OH_SensorSubscriptionId_SetType");
        OHOS_HOST_OPTIONAL_RESOLVE(sensor, DestroySubscriptionId,
                                   "OH_Sensor_DestroySubscriptionId");
        OHOS_HOST_OPTIONAL_RESOLVE(sensor, CreateSubscriptionAttribute,
                                   "OH_Sensor_CreateSubscriptionAttribute");
        OHOS_HOST_OPTIONAL_RESOLVE(sensor, SubscriptionAttributeSetSamplingInterval,
                                   "OH_SensorSubscriptionAttribute_SetSamplingInterval");
        OHOS_HOST_OPTIONAL_RESOLVE(sensor, DestroySubscriptionAttribute,
                                   "OH_Sensor_DestroySubscriptionAttribute");
        OHOS_HOST_OPTIONAL_RESOLVE(sensor, CreateSubscriber, "OH_Sensor_CreateSubscriber");
        OHOS_HOST_OPTIONAL_RESOLVE(sensor, SubscriberSetCallback,
                                   "OH_SensorSubscriber_SetCallback");
        OHOS_HOST_OPTIONAL_RESOLVE(sensor, DestroySubscriber, "OH_Sensor_DestroySubscriber");
        OHOS_HOST_OPTIONAL_RESOLVE(sensor, Subscribe, "OH_Sensor_Subscribe");
        OHOS_HOST_OPTIONAL_RESOLVE(sensor, Unsubscribe, "OH_Sensor_Unsubscribe");
        OHOS_HOST_OPTIONAL_RESOLVE(sensor, EventGetType, "OH_SensorEvent_GetType");
        OHOS_HOST_OPTIONAL_RESOLVE(sensor, EventGetData, "OH_SensorEvent_GetData");
        OHOS_HOST_OPTIONAL_RESOLVE(sensor, EventGetTimestamp, "OH_SensorEvent_GetTimestamp");
        g_ohos_host_optional.sensor.available = !missing;
        if (missing) {
            OhosHostOptionalAppendMissing(missing_names, sizeof(missing_names), &missing_used,
                                          "sensor");
        }
    }

    // Location.
    {
        static const char *const sonames[] = {"liblocation_ndk.so"};
        OhosHostOptionalLibSet libs = {sonames, 1, {NULL, NULL}, 0};
        OhosHostOptionalOpen(&libs);
        missing = false;
        OHOS_HOST_OPTIONAL_RESOLVE(location, CreateRequestConfig,
                                   "OH_Location_CreateRequestConfig");
        OHOS_HOST_OPTIONAL_RESOLVE(location, DestroyRequestConfig,
                                   "OH_Location_DestroyRequestConfig");
        OHOS_HOST_OPTIONAL_RESOLVE(location, RequestConfigSetCallback,
                                   "OH_LocationRequestConfig_SetCallback");
        OHOS_HOST_OPTIONAL_RESOLVE(location, StartLocating, "OH_Location_StartLocating");
        OHOS_HOST_OPTIONAL_RESOLVE(location, StopLocating, "OH_Location_StopLocating");
        OHOS_HOST_OPTIONAL_RESOLVE(location, InfoGetBasicInfo,
                                   "OH_LocationInfo_GetBasicInfo");
        g_ohos_host_optional.location.available = !missing;
        if (missing) {
            OhosHostOptionalAppendMissing(missing_names, sizeof(missing_names), &missing_used,
                                          "location");
        }
    }

    // Default-network capabilities.
    {
        static const char *const sonames[] = {"libnet_connection.so"};
        OhosHostOptionalLibSet libs = {sonames, 1, {NULL, NULL}, 0};
        OhosHostOptionalOpen(&libs);
        missing = false;
        OHOS_HOST_OPTIONAL_RESOLVE(net_conn, HasDefaultNet, "OH_NetConn_HasDefaultNet");
        OHOS_HOST_OPTIONAL_RESOLVE(net_conn, GetDefaultNet, "OH_NetConn_GetDefaultNet");
        OHOS_HOST_OPTIONAL_RESOLVE(net_conn, GetNetCapabilities,
                                   "OH_NetConn_GetNetCapabilities");
        g_ohos_host_optional.net_conn.available = !missing;
        if (missing) {
            OhosHostOptionalAppendMissing(missing_names, sizeof(missing_names), &missing_used,
                                          "net-conn");
        }
    }

    // Self permission check.
    {
        static const char *const sonames[] = {"libability_access_control.so"};
        OhosHostOptionalLibSet libs = {sonames, 1, {NULL, NULL}, 0};
        OhosHostOptionalOpen(&libs);
        missing = false;
        OHOS_HOST_OPTIONAL_RESOLVE(ability_access, CheckSelfPermission,
                                   "OH_AT_CheckSelfPermission");
        g_ohos_host_optional.ability_access.available = !missing;
        if (missing) {
            OhosHostOptionalAppendMissing(missing_names, sizeof(missing_names), &missing_used,
                                          "ability-access");
        }
    }

    // ImageSource + Pixelmap.
    {
        static const char *const sonames[] = {"libimage_source.so", "libpixelmap.so"};
        OhosHostOptionalLibSet libs = {sonames, 2, {NULL, NULL}, 0};
        OhosHostOptionalOpen(&libs);
        missing = false;
        OHOS_HOST_OPTIONAL_RESOLVE(image, ImageSourceCreateFromData,
                                   "OH_ImageSourceNative_CreateFromData");
        OHOS_HOST_OPTIONAL_RESOLVE(image, ImageSourceCreatePixelmap,
                                   "OH_ImageSourceNative_CreatePixelmap");
        OHOS_HOST_OPTIONAL_RESOLVE(image, ImageSourceRelease, "OH_ImageSourceNative_Release");
        OHOS_HOST_OPTIONAL_RESOLVE(image, PixelmapNativeGetImageInfo,
                                   "OH_PixelmapNative_GetImageInfo");
        OHOS_HOST_OPTIONAL_RESOLVE(image, PixelmapNativeRelease, "OH_PixelmapNative_Release");
        OHOS_HOST_OPTIONAL_RESOLVE(image, PixelmapImageInfoCreate,
                                   "OH_PixelmapImageInfo_Create");
        OHOS_HOST_OPTIONAL_RESOLVE(image, PixelmapImageInfoGetWidth,
                                   "OH_PixelmapImageInfo_GetWidth");
        OHOS_HOST_OPTIONAL_RESOLVE(image, PixelmapImageInfoGetHeight,
                                   "OH_PixelmapImageInfo_GetHeight");
        OHOS_HOST_OPTIONAL_RESOLVE(image, PixelmapImageInfoRelease,
                                   "OH_PixelmapImageInfo_Release");
        g_ohos_host_optional.image.available = !missing;
        if (missing) {
            OhosHostOptionalAppendMissing(missing_names, sizeof(missing_names), &missing_used,
                                          "image");
        }
    }

    // hilog: resolved last so the single diagnostic line below reports it as well.
    {
        static const char *const sonames[] = {"libhilog_ndk.z.so"};
        OhosHostOptionalLibSet libs = {sonames, 1, {NULL, NULL}, 0};
        OhosHostOptionalOpen(&libs);
        g_ohos_host_optional_log_print =
            (__typeof__(g_ohos_host_optional_log_print))OhosHostOptionalResolve(
                &libs, "OH_LOG_Print");
        if (g_ohos_host_optional_log_print == NULL) {
            OhosHostOptionalAppendMissing(missing_names, sizeof(missing_names), &missing_used,
                                          "hilog->stderr");
        }
    }

    if (missing_used != 0) {
        // One line per process start; stderr is the only channel guaranteed to survive a
        // missing hilog. The features keep their safe fallbacks (see host_optional.h).
        fprintf(stderr,
                "[openharmony-host] optional system libraries unavailable: %s "
                "(features disabled, host keeps running)\n",
                missing_names);
    }
}

void ohos_host_optional_ensure(void) {
    pthread_once(&g_ohos_host_optional_once, OhosHostOptionalLoad);
}

// ---------------------------------------------------------------------------
// stderr fallback for OH_LOG_Print. hilog format strings carry {public}/{private}
// privacy markers; they are stripped before vfprintf so the message stays readable.
// ---------------------------------------------------------------------------

static const char *OhosHostOptionalLevelName(LogLevel level) {
    switch (level) {
        case LOG_DEBUG:
            return "D";
        case LOG_INFO:
            return "I";
        case LOG_WARN:
            return "W";
        case LOG_ERROR:
            return "E";
        case LOG_FATAL:
            return "F";
        default:
            return "?";
    }
}

static void OhosHostOptionalStripPrivacy(const char *fmt, char *out, size_t out_size) {
    size_t used = 0;
    for (size_t i = 0; fmt[i] != '\0' && used + 1 < out_size; i++) {
        if (fmt[i] == '%' && fmt[i + 1] == '{') {
            const char *close = strchr(fmt + i + 2, '}');
            if (close != NULL) {
                out[used++] = '%';                 // keep the conversion introducer
                i = (size_t)(close - fmt);         // resume at the conversion character
                continue;
            }
        }
        out[used++] = fmt[i];
    }
    out[used] = '\0';
}

int ohos_host_optional_log_print_fallback(LogType type, LogLevel level, unsigned int domain,
                                          const char *tag, const char *fmt, ...) {
    (void)type;
    (void)domain;
    char stripped[1024];
    OhosHostOptionalStripPrivacy(fmt != NULL ? fmt : "(null)", stripped, sizeof(stripped));
    va_list args;
    va_start(args, fmt);
    fprintf(stderr, "[%s][%s] ", tag != NULL ? tag : "OHOS_DOTNET",
            OhosHostOptionalLevelName(level));
    vfprintf(stderr, stripped, args);
    va_end(args);
    fputc('\n', stderr);
    fflush(stderr);
    return 0;
}
