// Optional OpenHarmony system library shim.
//
// The host .so must load on devices whose system image ships a reduced library set: a
// missing library or symbol must disable one feature, never fail the dlopen of
// libopenharmonyhost.so. Every API below is therefore resolved on demand with
// dlopen/dlsym (host_optional.c) instead of a DT_NEEDED entry, the resolved function
// pointers are cached once (pthread_once, never per frame), and the call sites are
// redirected to the safe wrappers at the bottom of this header.
//
// Contract for a wrapper:
//   - library/symbol available -> call through, exact upstream behavior;
//   - unavailable              -> return the documented safe failure (NULL / non-zero
//                                 status / false / zeroed out-param) and leave every
//                                 out-parameter untouched.
//
// Adding an optional dependency:
//   1. add the pointer to the group struct and the wrapper + #define below;
//   2. resolve it in host_optional.c (symbol name + candidate soname);
//   3. add its API prefix to the [undefined] section of host-deps.conf so
//      scripts/build-host.sh fails the build if a direct call is reintroduced.
//
// Include this header AFTER the OpenHarmony NDK headers of the translation unit: the
// #define block is meant to rewrite the call sites below it, not the declarations above.

#ifndef OHOS_HOST_OPTIONAL_H
#define OHOS_HOST_OPTIONAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <LocationKit/oh_location.h>
#include <LocationKit/oh_location_type.h>
#include <accesstoken/ability_access_control.h>
#include <inputmethod/inputmethod_attach_options_capi.h>
#include <inputmethod/inputmethod_controller_capi.h>
#include <inputmethod/inputmethod_inputmethod_proxy_capi.h>
#include <inputmethod/inputmethod_text_editor_proxy_capi.h>
#include <multimedia/image_framework/image/image_source_native.h>
#include <multimedia/image_framework/image/pixelmap_native.h>
#include <native_window/external_window.h>
#include <network/netmanager/net_connection.h>
#include <network/netmanager/net_connection_type.h>
#include <sensors/oh_sensor.h>
#include <sensors/vibrator.h>

#include "host_optional_log.h"

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Resolved API tables. `available` is true only when every pointer of the group
// resolved; the per-call wrappers check the individual pointer as well, so a partially
// resolved group stays safe.
// ---------------------------------------------------------------------------

typedef struct {
    InputMethod_TextEditorProxy *(*TextEditorProxy_Create)(void);
    InputMethod_ErrorCode (*TextEditorProxy_SetInsertTextFunc)(
        InputMethod_TextEditorProxy *proxy, OH_TextEditorProxy_InsertTextFunc func);
    InputMethod_ErrorCode (*TextEditorProxy_SetDeleteForwardFunc)(
        InputMethod_TextEditorProxy *proxy, OH_TextEditorProxy_DeleteForwardFunc func);
    InputMethod_ErrorCode (*TextEditorProxy_SetDeleteBackwardFunc)(
        InputMethod_TextEditorProxy *proxy, OH_TextEditorProxy_DeleteBackwardFunc func);
    InputMethod_ErrorCode (*TextEditorProxy_SetGetTextConfigFunc)(
        InputMethod_TextEditorProxy *proxy, OH_TextEditorProxy_GetTextConfigFunc func);
    InputMethod_AttachOptions *(*AttachOptions_Create)(bool showKeyboard);
    void (*AttachOptions_Destroy)(InputMethod_AttachOptions *options);
    InputMethod_ErrorCode (*InputMethodController_Attach)(InputMethod_TextEditorProxy *proxy,
                                                          InputMethod_AttachOptions *options,
                                                          InputMethod_InputMethodProxy **out);
    InputMethod_ErrorCode (*InputMethodController_Detach)(InputMethod_InputMethodProxy *proxy);
    void (*TextEditorProxy_Destroy)(InputMethod_TextEditorProxy *proxy);
    InputMethod_ErrorCode (*InputMethodProxy_ShowKeyboard)(InputMethod_InputMethodProxy *proxy);
    InputMethod_ErrorCode (*InputMethodProxy_HideKeyboard)(InputMethod_InputMethodProxy *proxy);
    bool available;
} OhosHostOptionalImeApi;

typedef struct {
    int32_t (*HandleOpt)(OHNativeWindow *window, int code, ...);
    int32_t (*RequestBuffer)(OHNativeWindow *window, OHNativeWindowBuffer **buffer, int *fenceFd);
    int32_t (*FlushBuffer)(OHNativeWindow *window, OHNativeWindowBuffer *buffer, int fenceFd,
                           Region region);
    BufferHandle *(*GetBufferHandleFromNative)(OHNativeWindowBuffer *buffer);
    bool available;
} OhosHostOptionalNativeWindowApi;

typedef struct {
    int32_t (*PlayVibration)(int32_t duration, Vibrator_Attribute attribute);
    bool available;
} OhosHostOptionalVibratorApi;

typedef struct {
    Sensor_Info **(*CreateInfos)(uint32_t count);
    Sensor_Result (*GetInfos)(Sensor_Info **infos, uint32_t *count);
    int32_t (*DestroyInfos)(Sensor_Info **infos, uint32_t count);
    int32_t (*InfoGetType)(Sensor_Info *info, Sensor_Type *type);
    Sensor_SubscriptionId *(*CreateSubscriptionId)(void);
    int32_t (*SubscriptionIdSetType)(Sensor_SubscriptionId *id, const Sensor_Type type);
    int32_t (*DestroySubscriptionId)(Sensor_SubscriptionId *id);
    Sensor_SubscriptionAttribute *(*CreateSubscriptionAttribute)(void);
    int32_t (*SubscriptionAttributeSetSamplingInterval)(Sensor_SubscriptionAttribute *attribute,
                                                        const int64_t samplingInterval);
    int32_t (*DestroySubscriptionAttribute)(Sensor_SubscriptionAttribute *attribute);
    Sensor_Subscriber *(*CreateSubscriber)(void);
    int32_t (*SubscriberSetCallback)(Sensor_Subscriber *subscriber,
                                     const Sensor_EventCallback callback);
    int32_t (*DestroySubscriber)(Sensor_Subscriber *subscriber);
    Sensor_Result (*Subscribe)(const Sensor_SubscriptionId *id,
                               const Sensor_SubscriptionAttribute *attribute,
                               const Sensor_Subscriber *subscriber);
    Sensor_Result (*Unsubscribe)(const Sensor_SubscriptionId *id,
                                 const Sensor_Subscriber *subscriber);
    int32_t (*EventGetType)(Sensor_Event *event, Sensor_Type *type);
    int32_t (*EventGetData)(Sensor_Event *event, float **data, uint32_t *length);
    int32_t (*EventGetTimestamp)(Sensor_Event *event, int64_t *timestamp);
    bool available;
} OhosHostOptionalSensorApi;

typedef struct {
    Location_RequestConfig *(*CreateRequestConfig)(void);
    void (*DestroyRequestConfig)(Location_RequestConfig *config);
    void (*RequestConfigSetCallback)(Location_RequestConfig *config,
                                     Location_InfoCallback callback, void *userData);
    Location_ResultCode (*StartLocating)(const Location_RequestConfig *config);
    Location_ResultCode (*StopLocating)(const Location_RequestConfig *config);
    Location_BasicInfo (*InfoGetBasicInfo)(Location_Info *location);
    bool available;
} OhosHostOptionalLocationApi;

typedef struct {
    int32_t (*HasDefaultNet)(int32_t *hasDefaultNet);
    int32_t (*GetDefaultNet)(NetConn_NetHandle *netHandle);
    int32_t (*GetNetCapabilities)(NetConn_NetHandle *netHandle,
                                  NetConn_NetCapabilities *netCapabilities);
    bool available;
} OhosHostOptionalNetConnApi;

typedef struct {
    bool (*CheckSelfPermission)(const char *permission);
    bool available;
} OhosHostOptionalAbilityAccessApi;

typedef struct {
    Image_ErrorCode (*ImageSourceCreateFromData)(uint8_t *data, size_t dataSize,
                                                 OH_ImageSourceNative **res);
    Image_ErrorCode (*ImageSourceCreatePixelmap)(OH_ImageSourceNative *source,
                                                 OH_DecodingOptions *options,
                                                 OH_PixelmapNative **pixelmap);
    Image_ErrorCode (*ImageSourceRelease)(OH_ImageSourceNative *source);
    Image_ErrorCode (*PixelmapNativeGetImageInfo)(OH_PixelmapNative *pixelmap,
                                                  OH_Pixelmap_ImageInfo *imageInfo);
    Image_ErrorCode (*PixelmapNativeRelease)(OH_PixelmapNative *pixelmap);
    Image_ErrorCode (*PixelmapImageInfoCreate)(OH_Pixelmap_ImageInfo **info);
    Image_ErrorCode (*PixelmapImageInfoGetWidth)(OH_Pixelmap_ImageInfo *info, uint32_t *width);
    Image_ErrorCode (*PixelmapImageInfoGetHeight)(OH_Pixelmap_ImageInfo *info, uint32_t *height);
    Image_ErrorCode (*PixelmapImageInfoRelease)(OH_Pixelmap_ImageInfo *info);
    bool available;
} OhosHostOptionalImageApi;

typedef struct {
    OhosHostOptionalImeApi ime;
    OhosHostOptionalNativeWindowApi native_window;
    OhosHostOptionalVibratorApi vibrator;
    OhosHostOptionalSensorApi sensor;
    OhosHostOptionalLocationApi location;
    OhosHostOptionalNetConnApi net_conn;
    OhosHostOptionalAbilityAccessApi ability_access;
    OhosHostOptionalImageApi image;
} OhosHostOptionalApis;

extern OhosHostOptionalApis g_ohos_host_optional;

// ---------------------------------------------------------------------------
// Availability helpers for call sites that can skip work entirely (one line, no dlsym).
// ---------------------------------------------------------------------------

static inline bool ohos_host_optional_ime_available(void) {
    ohos_host_optional_ensure();
    return g_ohos_host_optional.ime.available;
}
static inline bool ohos_host_optional_native_window_available(void) {
    ohos_host_optional_ensure();
    return g_ohos_host_optional.native_window.available;
}
static inline bool ohos_host_optional_vibrator_available(void) {
    ohos_host_optional_ensure();
    return g_ohos_host_optional.vibrator.available;
}
static inline bool ohos_host_optional_sensor_available(void) {
    ohos_host_optional_ensure();
    return g_ohos_host_optional.sensor.available;
}
static inline bool ohos_host_optional_location_available(void) {
    ohos_host_optional_ensure();
    return g_ohos_host_optional.location.available;
}
static inline bool ohos_host_optional_net_conn_available(void) {
    ohos_host_optional_ensure();
    return g_ohos_host_optional.net_conn.available;
}
static inline bool ohos_host_optional_ability_access_available(void) {
    ohos_host_optional_ensure();
    return g_ohos_host_optional.ability_access.available;
}
static inline bool ohos_host_optional_image_available(void) {
    ohos_host_optional_ensure();
    return g_ohos_host_optional.image.available;
}

// ---------------------------------------------------------------------------
// IME: libace_ndk.z.so carries the API 12+ entry points, but reduced images were
// observed without them (OH_InputMethodProxy_ShowKeyboard et al.).
// ---------------------------------------------------------------------------

static inline InputMethod_TextEditorProxy *ohos_host_optional_ime_text_editor_proxy_create(void) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.ime.TextEditorProxy_Create == NULL) {
        return NULL;
    }
    return g_ohos_host_optional.ime.TextEditorProxy_Create();
}

static inline InputMethod_ErrorCode ohos_host_optional_ime_text_editor_proxy_set_insert_text_func(
    InputMethod_TextEditorProxy *proxy, OH_TextEditorProxy_InsertTextFunc func) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.ime.TextEditorProxy_SetInsertTextFunc == NULL) {
        return (InputMethod_ErrorCode)-1;
    }
    return g_ohos_host_optional.ime.TextEditorProxy_SetInsertTextFunc(proxy, func);
}

static inline InputMethod_ErrorCode
ohos_host_optional_ime_text_editor_proxy_set_delete_forward_func(
    InputMethod_TextEditorProxy *proxy, OH_TextEditorProxy_DeleteForwardFunc func) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.ime.TextEditorProxy_SetDeleteForwardFunc == NULL) {
        return (InputMethod_ErrorCode)-1;
    }
    return g_ohos_host_optional.ime.TextEditorProxy_SetDeleteForwardFunc(proxy, func);
}

static inline InputMethod_ErrorCode
ohos_host_optional_ime_text_editor_proxy_set_delete_backward_func(
    InputMethod_TextEditorProxy *proxy, OH_TextEditorProxy_DeleteBackwardFunc func) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.ime.TextEditorProxy_SetDeleteBackwardFunc == NULL) {
        return (InputMethod_ErrorCode)-1;
    }
    return g_ohos_host_optional.ime.TextEditorProxy_SetDeleteBackwardFunc(proxy, func);
}

static inline InputMethod_ErrorCode
ohos_host_optional_ime_text_editor_proxy_set_get_text_config_func(
    InputMethod_TextEditorProxy *proxy, OH_TextEditorProxy_GetTextConfigFunc func) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.ime.TextEditorProxy_SetGetTextConfigFunc == NULL) {
        return (InputMethod_ErrorCode)-1;
    }
    return g_ohos_host_optional.ime.TextEditorProxy_SetGetTextConfigFunc(proxy, func);
}

static inline InputMethod_AttachOptions *ohos_host_optional_ime_attach_options_create(
    bool showKeyboard) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.ime.AttachOptions_Create == NULL) {
        return NULL;
    }
    return g_ohos_host_optional.ime.AttachOptions_Create(showKeyboard);
}

static inline void ohos_host_optional_ime_attach_options_destroy(InputMethod_AttachOptions *options) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.ime.AttachOptions_Destroy != NULL) {
        g_ohos_host_optional.ime.AttachOptions_Destroy(options);
    }
}

static inline InputMethod_ErrorCode ohos_host_optional_ime_controller_attach(
    InputMethod_TextEditorProxy *proxy, InputMethod_AttachOptions *options,
    InputMethod_InputMethodProxy **out) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.ime.InputMethodController_Attach == NULL) {
        return (InputMethod_ErrorCode)-1;
    }
    return g_ohos_host_optional.ime.InputMethodController_Attach(proxy, options, out);
}

static inline InputMethod_ErrorCode ohos_host_optional_ime_controller_detach(
    InputMethod_InputMethodProxy *proxy) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.ime.InputMethodController_Detach == NULL) {
        return (InputMethod_ErrorCode)-1;
    }
    return g_ohos_host_optional.ime.InputMethodController_Detach(proxy);
}

static inline void ohos_host_optional_ime_text_editor_proxy_destroy(
    InputMethod_TextEditorProxy *proxy) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.ime.TextEditorProxy_Destroy != NULL) {
        g_ohos_host_optional.ime.TextEditorProxy_Destroy(proxy);
    }
}

static inline InputMethod_ErrorCode ohos_host_optional_ime_proxy_show_keyboard(
    InputMethod_InputMethodProxy *proxy) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.ime.InputMethodProxy_ShowKeyboard == NULL) {
        return (InputMethod_ErrorCode)-1;
    }
    return g_ohos_host_optional.ime.InputMethodProxy_ShowKeyboard(proxy);
}

static inline InputMethod_ErrorCode ohos_host_optional_ime_proxy_hide_keyboard(
    InputMethod_InputMethodProxy *proxy) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.ime.InputMethodProxy_HideKeyboard == NULL) {
        return (InputMethod_ErrorCode)-1;
    }
    return g_ohos_host_optional.ime.InputMethodProxy_HideKeyboard(proxy);
}

// ---------------------------------------------------------------------------
// NativeWindow: libnative_window.so is absent from reduced images. Drawing needs all
// four entry points, so the wrappers fail closed and the call sites skip the frame.
// OH_NativeWindow_NativeWindowHandleOpt is variadic and therefore NOT aliased; use the
// typed setters below (the only operation codes the host needs).
// ---------------------------------------------------------------------------

static inline int32_t ohos_host_optional_native_window_set_geometry(OHNativeWindow *window,
                                                                    int32_t width, int32_t height) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.native_window.HandleOpt == NULL) {
        return -1;
    }
    return g_ohos_host_optional.native_window.HandleOpt(window, SET_BUFFER_GEOMETRY, width, height);
}

static inline int32_t ohos_host_optional_native_window_set_format(OHNativeWindow *window,
                                                                  int32_t format) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.native_window.HandleOpt == NULL) {
        return -1;
    }
    return g_ohos_host_optional.native_window.HandleOpt(window, SET_FORMAT, format);
}

static inline int32_t ohos_host_optional_native_window_set_usage(OHNativeWindow *window,
                                                                 uint64_t usage) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.native_window.HandleOpt == NULL) {
        return -1;
    }
    return g_ohos_host_optional.native_window.HandleOpt(window, SET_USAGE, usage);
}

static inline int32_t ohos_host_optional_native_window_request_buffer(
    OHNativeWindow *window, OHNativeWindowBuffer **buffer, int *fenceFd) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.native_window.RequestBuffer == NULL) {
        return -1;
    }
    return g_ohos_host_optional.native_window.RequestBuffer(window, buffer, fenceFd);
}

static inline int32_t ohos_host_optional_native_window_flush_buffer(OHNativeWindow *window,
                                                                    OHNativeWindowBuffer *buffer,
                                                                    int fenceFd, Region region) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.native_window.FlushBuffer == NULL) {
        return -1;
    }
    return g_ohos_host_optional.native_window.FlushBuffer(window, buffer, fenceFd, region);
}

static inline BufferHandle *ohos_host_optional_native_window_get_buffer_handle(
    OHNativeWindowBuffer *buffer) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.native_window.GetBufferHandleFromNative == NULL) {
        return NULL;
    }
    return g_ohos_host_optional.native_window.GetBufferHandleFromNative(buffer);
}

// ---------------------------------------------------------------------------
// Vibrator: libohvibrator.z.so is absent from reduced images; the request is dropped.
// ---------------------------------------------------------------------------

static inline int32_t ohos_host_optional_vibrator_play(int32_t duration,
                                                       Vibrator_Attribute attribute) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.vibrator.PlayVibration == NULL) {
        return -1;
    }
    return g_ohos_host_optional.vibrator.PlayVibration(duration, attribute);
}

// ---------------------------------------------------------------------------
// Sensor: libohsensor.so is absent from reduced images; sensor start/unsubscribe fail
// closed while every destroy/release stays a no-op for NULL handles.
// ---------------------------------------------------------------------------

static inline Sensor_Info **ohos_host_optional_sensor_create_infos(uint32_t count) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.sensor.CreateInfos == NULL) {
        return NULL;
    }
    return g_ohos_host_optional.sensor.CreateInfos(count);
}

static inline Sensor_Result ohos_host_optional_sensor_get_infos(Sensor_Info **infos,
                                                               uint32_t *count) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.sensor.GetInfos == NULL) {
        return (Sensor_Result)-1;
    }
    return g_ohos_host_optional.sensor.GetInfos(infos, count);
}

static inline int32_t ohos_host_optional_sensor_destroy_infos(Sensor_Info **infos,
                                                              uint32_t count) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.sensor.DestroyInfos == NULL) {
        return -1;
    }
    return g_ohos_host_optional.sensor.DestroyInfos(infos, count);
}

static inline int32_t ohos_host_optional_sensor_info_get_type(Sensor_Info *info,
                                                              Sensor_Type *type) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.sensor.InfoGetType == NULL) {
        return -1;
    }
    return g_ohos_host_optional.sensor.InfoGetType(info, type);
}

static inline Sensor_SubscriptionId *ohos_host_optional_sensor_create_subscription_id(void) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.sensor.CreateSubscriptionId == NULL) {
        return NULL;
    }
    return g_ohos_host_optional.sensor.CreateSubscriptionId();
}

static inline int32_t ohos_host_optional_sensor_subscription_id_set_type(
    Sensor_SubscriptionId *id, const Sensor_Type type) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.sensor.SubscriptionIdSetType == NULL) {
        return -1;
    }
    return g_ohos_host_optional.sensor.SubscriptionIdSetType(id, type);
}

static inline int32_t ohos_host_optional_sensor_destroy_subscription_id(
    Sensor_SubscriptionId *id) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.sensor.DestroySubscriptionId == NULL) {
        return -1;
    }
    return g_ohos_host_optional.sensor.DestroySubscriptionId(id);
}

static inline Sensor_SubscriptionAttribute *
ohos_host_optional_sensor_create_subscription_attribute(void) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.sensor.CreateSubscriptionAttribute == NULL) {
        return NULL;
    }
    return g_ohos_host_optional.sensor.CreateSubscriptionAttribute();
}

static inline int32_t ohos_host_optional_sensor_subscription_attribute_set_sampling_interval(
    Sensor_SubscriptionAttribute *attribute, const int64_t samplingInterval) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.sensor.SubscriptionAttributeSetSamplingInterval == NULL) {
        return -1;
    }
    return g_ohos_host_optional.sensor.SubscriptionAttributeSetSamplingInterval(attribute,
                                                                                samplingInterval);
}

static inline int32_t ohos_host_optional_sensor_destroy_subscription_attribute(
    Sensor_SubscriptionAttribute *attribute) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.sensor.DestroySubscriptionAttribute == NULL) {
        return -1;
    }
    return g_ohos_host_optional.sensor.DestroySubscriptionAttribute(attribute);
}

static inline Sensor_Subscriber *ohos_host_optional_sensor_create_subscriber(void) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.sensor.CreateSubscriber == NULL) {
        return NULL;
    }
    return g_ohos_host_optional.sensor.CreateSubscriber();
}

static inline int32_t ohos_host_optional_sensor_subscriber_set_callback(
    Sensor_Subscriber *subscriber, const Sensor_EventCallback callback) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.sensor.SubscriberSetCallback == NULL) {
        return -1;
    }
    return g_ohos_host_optional.sensor.SubscriberSetCallback(subscriber, callback);
}

static inline int32_t ohos_host_optional_sensor_destroy_subscriber(
    Sensor_Subscriber *subscriber) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.sensor.DestroySubscriber == NULL) {
        return -1;
    }
    return g_ohos_host_optional.sensor.DestroySubscriber(subscriber);
}

static inline Sensor_Result ohos_host_optional_sensor_subscribe(
    const Sensor_SubscriptionId *id, const Sensor_SubscriptionAttribute *attribute,
    const Sensor_Subscriber *subscriber) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.sensor.Subscribe == NULL) {
        return (Sensor_Result)-1;
    }
    return g_ohos_host_optional.sensor.Subscribe(id, attribute, subscriber);
}

static inline Sensor_Result ohos_host_optional_sensor_unsubscribe(
    const Sensor_SubscriptionId *id, const Sensor_Subscriber *subscriber) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.sensor.Unsubscribe == NULL) {
        return (Sensor_Result)-1;
    }
    return g_ohos_host_optional.sensor.Unsubscribe(id, subscriber);
}

static inline int32_t ohos_host_optional_sensor_event_get_type(Sensor_Event *event,
                                                               Sensor_Type *type) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.sensor.EventGetType == NULL) {
        return -1;
    }
    return g_ohos_host_optional.sensor.EventGetType(event, type);
}

static inline int32_t ohos_host_optional_sensor_event_get_data(Sensor_Event *event, float **data,
                                                               uint32_t *length) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.sensor.EventGetData == NULL) {
        return -1;
    }
    return g_ohos_host_optional.sensor.EventGetData(event, data, length);
}

static inline int32_t ohos_host_optional_sensor_event_get_timestamp(Sensor_Event *event,
                                                                    int64_t *timestamp) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.sensor.EventGetTimestamp == NULL) {
        return -1;
    }
    return g_ohos_host_optional.sensor.EventGetTimestamp(event, timestamp);
}

// ---------------------------------------------------------------------------
// Location: liblocation_ndk.so is absent from reduced images; a start request fails and
// a callback that still fires reads a zeroed basic info.
// ---------------------------------------------------------------------------

static inline Location_RequestConfig *ohos_host_optional_location_create_request_config(void) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.location.CreateRequestConfig == NULL) {
        return NULL;
    }
    return g_ohos_host_optional.location.CreateRequestConfig();
}

static inline void ohos_host_optional_location_destroy_request_config(
    Location_RequestConfig *config) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.location.DestroyRequestConfig != NULL) {
        g_ohos_host_optional.location.DestroyRequestConfig(config);
    }
}

static inline void ohos_host_optional_location_request_config_set_callback(
    Location_RequestConfig *config, Location_InfoCallback callback, void *userData) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.location.RequestConfigSetCallback != NULL) {
        g_ohos_host_optional.location.RequestConfigSetCallback(config, callback, userData);
    }
}

static inline Location_ResultCode ohos_host_optional_location_start_locating(
    const Location_RequestConfig *config) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.location.StartLocating == NULL) {
        return (Location_ResultCode)-1;
    }
    return g_ohos_host_optional.location.StartLocating(config);
}

static inline Location_ResultCode ohos_host_optional_location_stop_locating(
    const Location_RequestConfig *config) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.location.StopLocating == NULL) {
        return (Location_ResultCode)-1;
    }
    return g_ohos_host_optional.location.StopLocating(config);
}

static inline Location_BasicInfo ohos_host_optional_location_info_get_basic_info(
    Location_Info *location) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.location.InfoGetBasicInfo == NULL) {
        Location_BasicInfo info = {0};
        return info;
    }
    return g_ohos_host_optional.location.InfoGetBasicInfo(location);
}

// ---------------------------------------------------------------------------
// NetConn: libnet_connection.so is absent from reduced images; the wrappers report "no
// default network" and the call sites keep their existing conservative answers.
// ---------------------------------------------------------------------------

static inline int32_t ohos_host_optional_net_conn_has_default_net(int32_t *hasDefaultNet) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.net_conn.HasDefaultNet == NULL) {
        if (hasDefaultNet != NULL) {
            *hasDefaultNet = 0;
        }
        return -1;
    }
    return g_ohos_host_optional.net_conn.HasDefaultNet(hasDefaultNet);
}

static inline int32_t ohos_host_optional_net_conn_get_default_net(NetConn_NetHandle *netHandle) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.net_conn.GetDefaultNet == NULL) {
        return -1;
    }
    return g_ohos_host_optional.net_conn.GetDefaultNet(netHandle);
}

static inline int32_t ohos_host_optional_net_conn_get_net_capabilities(
    NetConn_NetHandle *netHandle, NetConn_NetCapabilities *netCapabilities) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.net_conn.GetNetCapabilities == NULL) {
        return -1;
    }
    return g_ohos_host_optional.net_conn.GetNetCapabilities(netHandle, netCapabilities);
}

// ---------------------------------------------------------------------------
// Ability access control: libability_access_control.so is absent from reduced images;
// an unresolved check reports "not granted" (the conservative answer).
// ---------------------------------------------------------------------------

static inline bool ohos_host_optional_ability_access_check_self_permission(
    const char *permission) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.ability_access.CheckSelfPermission == NULL) {
        return false;
    }
    return g_ohos_host_optional.ability_access.CheckSelfPermission(permission);
}

// ---------------------------------------------------------------------------
// ImageSource/Pixelmap: libimage_source.so and libpixelmap.so are absent from reduced
// images; decoding an image fails closed (NULL pixelmap) and the release calls no-op.
// ---------------------------------------------------------------------------

static inline Image_ErrorCode ohos_host_optional_image_source_create_from_data(
    uint8_t *data, size_t dataSize, OH_ImageSourceNative **res) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.image.ImageSourceCreateFromData == NULL) {
        return (Image_ErrorCode)-1;
    }
    return g_ohos_host_optional.image.ImageSourceCreateFromData(data, dataSize, res);
}

static inline Image_ErrorCode ohos_host_optional_image_source_create_pixelmap(
    OH_ImageSourceNative *source, OH_DecodingOptions *options, OH_PixelmapNative **pixelmap) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.image.ImageSourceCreatePixelmap == NULL) {
        return (Image_ErrorCode)-1;
    }
    return g_ohos_host_optional.image.ImageSourceCreatePixelmap(source, options, pixelmap);
}

static inline void ohos_host_optional_image_source_release(OH_ImageSourceNative *source) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.image.ImageSourceRelease != NULL) {
        g_ohos_host_optional.image.ImageSourceRelease(source);
    }
}

static inline Image_ErrorCode ohos_host_optional_pixelmap_native_get_image_info(
    OH_PixelmapNative *pixelmap, OH_Pixelmap_ImageInfo *imageInfo) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.image.PixelmapNativeGetImageInfo == NULL) {
        return (Image_ErrorCode)-1;
    }
    return g_ohos_host_optional.image.PixelmapNativeGetImageInfo(pixelmap, imageInfo);
}

static inline void ohos_host_optional_pixelmap_native_release(OH_PixelmapNative *pixelmap) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.image.PixelmapNativeRelease != NULL) {
        g_ohos_host_optional.image.PixelmapNativeRelease(pixelmap);
    }
}

static inline Image_ErrorCode ohos_host_optional_pixelmap_image_info_create(
    OH_Pixelmap_ImageInfo **info) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.image.PixelmapImageInfoCreate == NULL) {
        return (Image_ErrorCode)-1;
    }
    return g_ohos_host_optional.image.PixelmapImageInfoCreate(info);
}

static inline Image_ErrorCode ohos_host_optional_pixelmap_image_info_get_width(
    OH_Pixelmap_ImageInfo *info, uint32_t *width) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.image.PixelmapImageInfoGetWidth == NULL) {
        return (Image_ErrorCode)-1;
    }
    return g_ohos_host_optional.image.PixelmapImageInfoGetWidth(info, width);
}

static inline Image_ErrorCode ohos_host_optional_pixelmap_image_info_get_height(
    OH_Pixelmap_ImageInfo *info, uint32_t *height) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.image.PixelmapImageInfoGetHeight == NULL) {
        return (Image_ErrorCode)-1;
    }
    return g_ohos_host_optional.image.PixelmapImageInfoGetHeight(info, height);
}

static inline void ohos_host_optional_pixelmap_image_info_release(OH_Pixelmap_ImageInfo *info) {
    ohos_host_optional_ensure();
    if (g_ohos_host_optional.image.PixelmapImageInfoRelease != NULL) {
        g_ohos_host_optional.image.PixelmapImageInfoRelease(info);
    }
}

#ifdef __cplusplus
}  // extern "C"
#endif

// ---------------------------------------------------------------------------
// Call-site redirects. These names must not appear as direct references anywhere in the
// host: scripts/build-host.sh fails the build when it finds one in nm -D -u output
// (host-deps.conf [undefined]).
// ---------------------------------------------------------------------------

#define OH_TextEditorProxy_Create ohos_host_optional_ime_text_editor_proxy_create
#define OH_TextEditorProxy_SetInsertTextFunc \
    ohos_host_optional_ime_text_editor_proxy_set_insert_text_func
#define OH_TextEditorProxy_SetDeleteForwardFunc \
    ohos_host_optional_ime_text_editor_proxy_set_delete_forward_func
#define OH_TextEditorProxy_SetDeleteBackwardFunc \
    ohos_host_optional_ime_text_editor_proxy_set_delete_backward_func
#define OH_TextEditorProxy_SetGetTextConfigFunc \
    ohos_host_optional_ime_text_editor_proxy_set_get_text_config_func
#define OH_TextEditorProxy_Destroy ohos_host_optional_ime_text_editor_proxy_destroy
#define OH_AttachOptions_Create ohos_host_optional_ime_attach_options_create
#define OH_AttachOptions_Destroy ohos_host_optional_ime_attach_options_destroy
#define OH_InputMethodController_Attach ohos_host_optional_ime_controller_attach
#define OH_InputMethodController_Detach ohos_host_optional_ime_controller_detach
#define OH_InputMethodProxy_ShowKeyboard ohos_host_optional_ime_proxy_show_keyboard
#define OH_InputMethodProxy_HideKeyboard ohos_host_optional_ime_proxy_hide_keyboard

#define OH_NativeWindow_NativeWindowRequestBuffer ohos_host_optional_native_window_request_buffer
#define OH_NativeWindow_NativeWindowFlushBuffer ohos_host_optional_native_window_flush_buffer
#define OH_NativeWindow_GetBufferHandleFromNative \
    ohos_host_optional_native_window_get_buffer_handle

#define OH_Vibrator_PlayVibration ohos_host_optional_vibrator_play

#define OH_Sensor_CreateInfos ohos_host_optional_sensor_create_infos
#define OH_Sensor_GetInfos ohos_host_optional_sensor_get_infos
#define OH_Sensor_DestroyInfos ohos_host_optional_sensor_destroy_infos
#define OH_SensorInfo_GetType ohos_host_optional_sensor_info_get_type
#define OH_Sensor_CreateSubscriptionId ohos_host_optional_sensor_create_subscription_id
#define OH_SensorSubscriptionId_SetType ohos_host_optional_sensor_subscription_id_set_type
#define OH_Sensor_DestroySubscriptionId ohos_host_optional_sensor_destroy_subscription_id
#define OH_Sensor_CreateSubscriptionAttribute \
    ohos_host_optional_sensor_create_subscription_attribute
#define OH_SensorSubscriptionAttribute_SetSamplingInterval \
    ohos_host_optional_sensor_subscription_attribute_set_sampling_interval
#define OH_Sensor_DestroySubscriptionAttribute \
    ohos_host_optional_sensor_destroy_subscription_attribute
#define OH_Sensor_CreateSubscriber ohos_host_optional_sensor_create_subscriber
#define OH_SensorSubscriber_SetCallback ohos_host_optional_sensor_subscriber_set_callback
#define OH_Sensor_DestroySubscriber ohos_host_optional_sensor_destroy_subscriber
#define OH_Sensor_Subscribe ohos_host_optional_sensor_subscribe
#define OH_Sensor_Unsubscribe ohos_host_optional_sensor_unsubscribe
#define OH_SensorEvent_GetType ohos_host_optional_sensor_event_get_type
#define OH_SensorEvent_GetData ohos_host_optional_sensor_event_get_data
#define OH_SensorEvent_GetTimestamp ohos_host_optional_sensor_event_get_timestamp

#define OH_Location_CreateRequestConfig ohos_host_optional_location_create_request_config
#define OH_Location_DestroyRequestConfig ohos_host_optional_location_destroy_request_config
#define OH_LocationRequestConfig_SetCallback \
    ohos_host_optional_location_request_config_set_callback
#define OH_Location_StartLocating ohos_host_optional_location_start_locating
#define OH_Location_StopLocating ohos_host_optional_location_stop_locating
#define OH_LocationInfo_GetBasicInfo ohos_host_optional_location_info_get_basic_info

#define OH_NetConn_HasDefaultNet ohos_host_optional_net_conn_has_default_net
#define OH_NetConn_GetDefaultNet ohos_host_optional_net_conn_get_default_net
#define OH_NetConn_GetNetCapabilities ohos_host_optional_net_conn_get_net_capabilities

#define OH_AT_CheckSelfPermission ohos_host_optional_ability_access_check_self_permission

#define OH_ImageSourceNative_CreateFromData ohos_host_optional_image_source_create_from_data
#define OH_ImageSourceNative_CreatePixelmap ohos_host_optional_image_source_create_pixelmap
#define OH_ImageSourceNative_Release ohos_host_optional_image_source_release
#define OH_PixelmapNative_GetImageInfo ohos_host_optional_pixelmap_native_get_image_info
#define OH_PixelmapNative_Release ohos_host_optional_pixelmap_native_release
#define OH_PixelmapImageInfo_Create ohos_host_optional_pixelmap_image_info_create
#define OH_PixelmapImageInfo_GetWidth ohos_host_optional_pixelmap_image_info_get_width
#define OH_PixelmapImageInfo_GetHeight ohos_host_optional_pixelmap_image_info_get_height
#define OH_PixelmapImageInfo_Release ohos_host_optional_pixelmap_image_info_release

#endif  // OHOS_HOST_OPTIONAL_H
