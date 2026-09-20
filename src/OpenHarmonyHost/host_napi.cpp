// NAPI module that hosts a published .NET app inside an OpenHarmony application.
// ArkTS side:
//   import host from 'libopenharmonyhost.so';
//   host.startApp(appDir, assemblyFile, contextJson);   // async, returns immediately
//   host.notifyLifecycle(event);                         // 0=create 1=destroy 2=fg 3=bg
//   host.setNodeContent(nodeContentHandle);              // ArkUI NodeContent
//   host.stopApp();                                      // sends destroy
//   host.runApp(appDir, assemblyFile);                   // sync one-shot, returns exit code
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <arkui/native_node_napi.h>
#include <napi/native_api.h>
#include <hilog/log.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Forward declarations: the module function table below references these (defined at the end).
napi_value AttachAccessibilityNode(napi_env env, napi_callback_info info);
static int AttachAccessibilityValue(napi_env env, napi_value value);
napi_value AccessibilityStatus(napi_env env, napi_callback_info info);

#include <string>
#include <vector>

#include "openharmony_host.h"

#define OHOS_HOST_DOMAIN 0x0002
#define OHOS_HOST_TAG "OHOS_DOTNET"

namespace {

OhosHostAppHandle* g_handle = nullptr;

// XComponent (surface) support -------------------------------------------------
napi_env g_env = nullptr;
napi_ref g_exports_ref = nullptr;
napi_ref g_text_input_sink_ref = nullptr;
OH_NativeXComponent* g_xcomponent = nullptr;

void OnSurfaceCreated(OH_NativeXComponent* component, void* window) {
    uint64_t width = 0;
    uint64_t height = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &width, &height);
    ohos_host_set_native_window(window, static_cast<int>(width), static_cast<int>(height),
                                OHOS_SURFACE_CREATED);
}

void OnSurfaceChanged(OH_NativeXComponent* component, void* window) {
    uint64_t width = 0;
    uint64_t height = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &width, &height);
    ohos_host_set_native_window(window, static_cast<int>(width), static_cast<int>(height),
                                OHOS_SURFACE_CHANGED);
}

void OnSurfaceDestroyed(OH_NativeXComponent* component, void* window) {
    (void)component;
    ohos_host_set_native_window(window, 0, 0, OHOS_SURFACE_DESTROYED);
}

extern "C" void OhosNotifyPinch(int phase, double scale, float x, float y);

static bool g_pinch_active = false;
static double g_pinch_start_distance = 0.0;

// Two-finger pinch straight from the XComponent touch event (the event carries every point).
static void MaybeReportPinch(OH_NativeXComponent* component, const OH_NativeXComponent_TouchEvent& event) {
    if (event.numPoints >= 2) {
        float x0 = 0.0f, y0 = 0.0f, x1 = 0.0f, y1 = 0.0f;
        OH_NativeXComponent_GetTouchPointWindowX(component, 0, &x0);
        OH_NativeXComponent_GetTouchPointWindowY(component, 0, &y0);
        OH_NativeXComponent_GetTouchPointWindowX(component, 1, &x1);
        OH_NativeXComponent_GetTouchPointWindowY(component, 1, &y1);
        double dx = static_cast<double>(x1) - static_cast<double>(x0);
        double dy = static_cast<double>(y1) - static_cast<double>(y0);
        double squared = dx * dx + dy * dy;
        double distance = squared > 0.0 ? __builtin_sqrt(squared) : 1.0;
        float centerX = static_cast<float>((static_cast<double>(x0) + static_cast<double>(x1)) / 2.0);
        float centerY = static_cast<float>((static_cast<double>(y0) + static_cast<double>(y1)) / 2.0);
        if (!g_pinch_active) {
            g_pinch_active = true;
            g_pinch_start_distance = distance;
            OhosNotifyPinch(0, 1.0, centerX, centerY);
        } else {
            double scale = g_pinch_start_distance > 0.0 ? distance / g_pinch_start_distance : 1.0;
            OhosNotifyPinch(1, scale, centerX, centerY);
        }
    } else if (g_pinch_active) {
        g_pinch_active = false;
        g_pinch_start_distance = 0.0;
        OhosNotifyPinch(2, 1.0, 0.0f, 0.0f);
    }
}

void OnTouch(OH_NativeXComponent* component, void* window) {
    OH_NativeXComponent_TouchEvent event = {};
    if (OH_NativeXComponent_GetTouchEvent(component, window, &event) != 0) {
        return;
    }
    MaybeReportPinch(component, event);
    float x = event.x;
    float y = event.y;
    if (event.numPoints > 0) {
        OH_NativeXComponent_GetTouchPointWindowX(component, 0, &x);
        OH_NativeXComponent_GetTouchPointWindowY(component, 0, &y);
    }
    ohos_host_notify_touch(static_cast<int>(event.type), x, y,
                           static_cast<int>(event.numPoints), static_cast<int>(event.id));
}

void OnMouse(OH_NativeXComponent* component, void* window) {
    OH_NativeXComponent_MouseEvent event = {};
    if (OH_NativeXComponent_GetMouseEvent(component, window, &event) != 0) {
        return;
    }
    int type = 2;  // move
    if (event.action == OH_NATIVEXCOMPONENT_MOUSE_PRESS) {
        type = 0;
    } else if (event.action == OH_NATIVEXCOMPONENT_MOUSE_RELEASE) {
        type = 1;
    }
    ohos_host_notify_touch(type, event.x, event.y, 1, 0);
}

void OnFrame(OH_NativeXComponent* component, uint64_t timestamp, uint64_t targetTimestamp) {
    (void)component;
    ohos_host_notify_frame(static_cast<int64_t>(timestamp), static_cast<int64_t>(targetTimestamp));
}

// The framework exposes the native XComponent through the module exports
// (OH_NATIVE_XCOMPONENT_OBJ) when the page uses <XComponent libraryname="...">.
void TryRegisterXComponent() {
    if (g_env == nullptr || g_exports_ref == nullptr || g_xcomponent != nullptr) {
        return;
    }
    napi_value exports = nullptr;
    if (napi_get_reference_value(g_env, g_exports_ref, &exports) != napi_ok || exports == nullptr) {
        return;
    }
    napi_value exportInstance = nullptr;
    if (napi_get_named_property(g_env, exports, OH_NATIVE_XCOMPONENT_OBJ, &exportInstance) != napi_ok) {
        return;
    }
    void* native = nullptr;
    if (napi_unwrap(g_env, exportInstance, &native) != napi_ok || native == nullptr) {
        return;
    }
    g_xcomponent = reinterpret_cast<OH_NativeXComponent*>(native);
    static OH_NativeXComponent_Callback callback = {
        .OnSurfaceCreated = OnSurfaceCreated,
        .OnSurfaceChanged = OnSurfaceChanged,
        .OnSurfaceDestroyed = OnSurfaceDestroyed,
        .DispatchTouchEvent = OnTouch,
    };
    if (OH_NativeXComponent_RegisterCallback(g_xcomponent, &callback) != 0) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] RegisterCallback failed");
        g_xcomponent = nullptr;
        return;
    }
    static OH_NativeXComponent_MouseEvent_Callback mouseCallback = {
        .DispatchMouseEvent = OnMouse,
        .DispatchHoverEvent = nullptr,
    };
    OH_NativeXComponent_RegisterMouseEventCallback(g_xcomponent, &mouseCallback);
    OH_NativeXComponent_RegisterOnFrameCallback(g_xcomponent, OnFrame);
    char id[128] = {0};
    uint64_t size = sizeof(id);
    if (OH_NativeXComponent_GetXComponentId(g_xcomponent, id, &size) == 0) {
        OH_LOG_INFO(LOG_APP, "[openharmony-host] xcomponent '%{public}s' registered (touch+frame)", id);
    }
}

std::string GetStringArg(napi_env env, napi_value value);

napi_ref g_keystore_sink_ref = nullptr;

// Called by the host core (managed side) to run a HUKS operation in the ArkTS shell.
void OnKeystoreRequest(int requestId, const char* op, const char* alias, const char* dataBase64) {
    if (g_env == nullptr || g_keystore_sink_ref == nullptr) {
        return;
    }
    napi_value sink = nullptr;
    if (napi_get_reference_value(g_env, g_keystore_sink_ref, &sink) != napi_ok || sink == nullptr) {
        return;
    }
    napi_value global = nullptr;
    napi_get_global(g_env, &global);
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_create_int32(g_env, requestId, &argv[0]);
    napi_create_string_utf8(g_env, op != nullptr ? op : "", NAPI_AUTO_LENGTH, &argv[1]);
    napi_create_string_utf8(g_env, alias != nullptr ? alias : "", NAPI_AUTO_LENGTH, &argv[2]);
    napi_create_string_utf8(g_env, dataBase64 != nullptr ? dataBase64 : "", NAPI_AUTO_LENGTH, &argv[3]);
    napi_value result = nullptr;
    napi_call_function(g_env, global, sink, 4, argv, &result);
}

// ArkTS calls host.registerKeystoreSink(fn) to receive keystore requests.
napi_ref g_picker_sink_ref = nullptr;
napi_ref g_notification_sink_ref = nullptr;

extern "C" void OhosNotifyPinch(int phase, double scale, float x, float y);

napi_value NotifyPinch(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t phase = 0;
    double scale = 1.0;
    double x = 0.0;
    double y = 0.0;
    if (argc > 0) napi_get_value_int32(env, argv[0], &phase);
    if (argc > 1) napi_get_value_double(env, argv[1], &scale);
    if (argc > 2) napi_get_value_double(env, argv[2], &x);
    if (argc > 3) napi_get_value_double(env, argv[3], &y);
    OhosNotifyPinch(phase, scale, (float)x, (float)y);
    return nullptr;
}

// Called from the host C layer: forwards a notification publish request to ArkTS.
extern "C" void OhosNotifyNotification(int id, const char* title, const char* text) {
    if (g_env == nullptr || g_notification_sink_ref == nullptr) {
        return;
    }
    napi_value sink = nullptr;
    if (napi_get_reference_value(g_env, g_notification_sink_ref, &sink) != napi_ok || sink == nullptr) {
        return;
    }
    napi_value argv[3];
    napi_create_int32(g_env, id, &argv[0]);
    napi_create_string_utf8(g_env, title != nullptr ? title : "", NAPI_AUTO_LENGTH, &argv[1]);
    napi_create_string_utf8(g_env, text != nullptr ? text : "", NAPI_AUTO_LENGTH, &argv[2]);
    napi_value result = nullptr;
    napi_call_function(g_env, sink, sink, 3, argv, &result);
}

// ArkTS calls host.registerNotificationSink(fn) to publish notifications.
napi_value RegisterNotificationSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) {
        return nullptr;
    }
    if (g_notification_sink_ref != nullptr) {
        napi_delete_reference(env, g_notification_sink_ref);
    }
    napi_create_reference(env, argv[0], 1, &g_notification_sink_ref);
    return nullptr;
}

// TextToSpeech: the managed side forwards speak requests through ohos_host_tts_speak; the
// ArkTS shell's sink (registerTtsSink) owns the Speech Kit call and answers with
// host.notifyTtsResult(requestId, code).
napi_ref g_tts_sink_ref = nullptr;
static void (*g_tts_result_listener)(int request_id, int code) = nullptr;

// Called from the host C layer (managed P/Invoke): forwards a speak request to ArkTS.
extern "C" int ohos_host_tts_speak(int request_id, const char* text, const char* locale) {
    if (g_env == nullptr || g_tts_sink_ref == nullptr) {
        return -1;
    }
    napi_value sink = nullptr;
    if (napi_get_reference_value(g_env, g_tts_sink_ref, &sink) != napi_ok || sink == nullptr) {
        return -1;
    }
    napi_value argv[3];
    napi_create_int32(g_env, request_id, &argv[0]);
    napi_create_string_utf8(g_env, text != nullptr ? text : "", NAPI_AUTO_LENGTH, &argv[1]);
    napi_create_string_utf8(g_env, locale != nullptr ? locale : "", NAPI_AUTO_LENGTH, &argv[2]);
    napi_value result = nullptr;
    napi_status status = napi_call_function(g_env, sink, sink, 3, argv, &result);
    return status == napi_ok ? 0 : -1;
}

// The managed side registers the callback that completes a pending speak request.
extern "C" void ohos_host_tts_register_result(void* callback) {
    g_tts_result_listener = (void (*)(int, int))callback;
}

// Called by the NAPI notify below: hands the shell's answer back to managed code.
extern "C" void ohos_host_tts_result(int request_id, int code) {
    if (g_tts_result_listener != nullptr) {
        g_tts_result_listener(request_id, code);
    }
}

// ArkTS calls host.registerTtsSink(fn) to receive speak requests.
napi_value RegisterTtsSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            if (g_tts_sink_ref != nullptr) {
                napi_delete_reference(env, g_tts_sink_ref);
            }
            napi_create_reference(env, argv[0], 1, &g_tts_sink_ref);
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notifyTtsResult(requestId, code) when the engine finished.
napi_value NotifyTtsResult(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int requestId = 0;
    int code = -1;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &requestId);
    }
    if (argc >= 2) {
        napi_get_value_int32(env, argv[1], &code);
    }
    ohos_host_tts_result(requestId, code);
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Contacts (Contacts Kit) and Calendar (Calendar Kit): the managed side forwards a request
// through ohos_host_contacts_query / ohos_host_calendar_list / ohos_host_calendar_add; the
// ArkTS shell's registerContactsSink / registerCalendarSink handlers own the kit calls (and the
// runtime permission request) and answer through host.notifyContactsResult /
// host.notifyCalendarResult. The payload is a delimited table, one record per line with '\t'
// separated fields (contacts: name, phone; calendar: title, start ISO-8601, end ISO-8601);
// code 0 means the answer is complete (an empty payload is a valid "no records"), code -1 means
// the kit, the permission or the sink was unavailable.
napi_ref g_contacts_sink_ref = nullptr;
napi_ref g_calendar_sink_ref = nullptr;
static void (*g_contacts_result_listener)(int request_id, int code, const char* payload) = nullptr;
static void (*g_calendar_result_listener)(int request_id, int code, const char* payload) = nullptr;

// Called from managed code (P/Invoke): forwards a name-prefix lookup (limit caps the number of
// returned rows) to the ArkTS sink; returns 0 when it was dispatched.
extern "C" int ohos_host_contacts_query(int request_id, const char* name_prefix, int limit) {
    if (g_env == nullptr || g_contacts_sink_ref == nullptr) {
        return -1;
    }
    napi_value sink = nullptr;
    if (napi_get_reference_value(g_env, g_contacts_sink_ref, &sink) != napi_ok || sink == nullptr) {
        return -1;
    }
    napi_value argv[3];
    napi_create_int32(g_env, request_id, &argv[0]);
    napi_create_string_utf8(g_env, name_prefix != nullptr ? name_prefix : "", NAPI_AUTO_LENGTH, &argv[1]);
    napi_create_int32(g_env, limit, &argv[2]);
    napi_value result = nullptr;
    napi_status status = napi_call_function(g_env, sink, sink, 3, argv, &result);
    return status == napi_ok ? 0 : -1;
}

// The managed side registers the callback that completes a pending contacts request.
extern "C" void ohos_host_contacts_register_result(void* callback) {
    g_contacts_result_listener = (void (*)(int, int, const char*))callback;
}

// Called by the NAPI notify below: hands the shell's answer back to managed code.
extern "C" void ohos_host_contacts_result(int request_id, int code, const char* payload) {
    if (g_contacts_result_listener != nullptr) {
        g_contacts_result_listener(request_id, code, payload != nullptr ? payload : "");
    }
}

// ArkTS calls host.registerContactsSink(fn) to receive contacts lookups.
napi_value RegisterContactsSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            if (g_contacts_sink_ref != nullptr) {
                napi_delete_reference(env, g_contacts_sink_ref);
            }
            napi_create_reference(env, argv[0], 1, &g_contacts_sink_ref);
            OH_LOG_INFO(LOG_APP, "[openharmony-host] contacts sink registered");
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notifyContactsResult(requestId, code, payload) when a lookup finished.
napi_value NotifyContactsResult(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int requestId = 0;
    int code = -1;
    std::string payload;
    if (argc >= 1) napi_get_value_int32(env, argv[0], &requestId);
    if (argc >= 2) napi_get_value_int32(env, argv[1], &code);
    if (argc >= 3) payload = GetStringArg(env, argv[2]);
    ohos_host_contacts_result(requestId, code, payload.c_str());
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Calls the calendar sink: op 0 = list (arg1 = days), op 1 = add (arg1 = title,
// arg2 = start ISO-8601, arg3 = end ISO-8601).
static int CallCalendarSink(int request_id, int op, const char* arg1, const char* arg2, const char* arg3) {
    if (g_env == nullptr || g_calendar_sink_ref == nullptr) {
        return -1;
    }
    napi_value sink = nullptr;
    if (napi_get_reference_value(g_env, g_calendar_sink_ref, &sink) != napi_ok || sink == nullptr) {
        return -1;
    }
    napi_value argv[5];
    napi_create_int32(g_env, request_id, &argv[0]);
    napi_create_int32(g_env, op, &argv[1]);
    napi_create_string_utf8(g_env, arg1 != nullptr ? arg1 : "", NAPI_AUTO_LENGTH, &argv[2]);
    napi_create_string_utf8(g_env, arg2 != nullptr ? arg2 : "", NAPI_AUTO_LENGTH, &argv[3]);
    napi_create_string_utf8(g_env, arg3 != nullptr ? arg3 : "", NAPI_AUTO_LENGTH, &argv[4]);
    napi_value result = nullptr;
    napi_status status = napi_call_function(g_env, sink, sink, 5, argv, &result);
    return status == napi_ok ? 0 : -1;
}

// Called from managed code (P/Invoke): lists events in the next `days` days.
extern "C" int ohos_host_calendar_list(int request_id, int days) {
    char buffer[32];
    buffer[0] = '\0';
    snprintf(buffer, sizeof(buffer), "%d", days);
    return CallCalendarSink(request_id, 0, buffer, "", "");
}

// Called from managed code (P/Invoke): adds one event from ISO-8601 start/end times.
extern "C" int ohos_host_calendar_add(int request_id, const char* title, const char* start_iso, const char* end_iso) {
    return CallCalendarSink(request_id, 1, title, start_iso, end_iso);
}

// The managed side registers the callback that completes a pending calendar request.
extern "C" void ohos_host_calendar_register_result(void* callback) {
    g_calendar_result_listener = (void (*)(int, int, const char*))callback;
}

// Called by the NAPI notify below: hands the shell's answer back to managed code.
extern "C" void ohos_host_calendar_result(int request_id, int code, const char* payload) {
    if (g_calendar_result_listener != nullptr) {
        g_calendar_result_listener(request_id, code, payload != nullptr ? payload : "");
    }
}

// ArkTS calls host.registerCalendarSink(fn) to receive calendar list/add requests.
napi_value RegisterCalendarSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            if (g_calendar_sink_ref != nullptr) {
                napi_delete_reference(env, g_calendar_sink_ref);
            }
            napi_create_reference(env, argv[0], 1, &g_calendar_sink_ref);
            OH_LOG_INFO(LOG_APP, "[openharmony-host] calendar sink registered");
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notifyCalendarResult(requestId, code, payload) when a request finished.
napi_value NotifyCalendarResult(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int requestId = 0;
    int code = -1;
    std::string payload;
    if (argc >= 1) napi_get_value_int32(env, argv[0], &requestId);
    if (argc >= 2) napi_get_value_int32(env, argv[1], &code);
    if (argc >= 3) payload = GetStringArg(env, argv[2]);
    ohos_host_calendar_result(requestId, code, payload.c_str());
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Bluetooth (Connectivity Kit): the managed side forwards a request through
// ohos_host_bluetooth_query (op 0 = adapter state, 1 = paired devices, 2 = start discovery,
// 3 = stop discovery); the ArkTS shell's registerBluetoothSink handler requests
// ohos.permission.ACCESS_BLUETOOTH (user_grant) and runs the kit call
// (@kit.ConnectivityKit access.getState / connection.getPairedDevices /
// connection.getRemoteDeviceName / startBluetoothDiscovery / stopBluetoothDiscovery), then
// answers through host.notifyBluetoothResult. The payload is a '\n' separated table of
// "name\taddress" records (paired devices) or the decimal access.BluetoothState (state);
// code 0 is a complete answer, -1 unavailable, -2 a transient kit failure.
napi_ref g_bluetooth_sink_ref = nullptr;
static void (*g_bluetooth_result_listener)(int request_id, int code, const char* payload) = nullptr;

// Called from managed code (P/Invoke): forwards a Bluetooth operation to the ArkTS sink;
// returns 0 when it was dispatched.
extern "C" int ohos_host_bluetooth_query(int request_id, int op) {
    if (g_env == nullptr || g_bluetooth_sink_ref == nullptr) {
        return -1;
    }
    napi_value sink = nullptr;
    if (napi_get_reference_value(g_env, g_bluetooth_sink_ref, &sink) != napi_ok || sink == nullptr) {
        return -1;
    }
    napi_value argv[2];
    napi_create_int32(g_env, request_id, &argv[0]);
    napi_create_int32(g_env, op, &argv[1]);
    napi_value result = nullptr;
    napi_status status = napi_call_function(g_env, sink, sink, 2, argv, &result);
    return status == napi_ok ? 0 : -1;
}

// The managed side registers the callback that completes a pending Bluetooth request.
extern "C" void ohos_host_bluetooth_register_result(void* callback) {
    g_bluetooth_result_listener = (void (*)(int, int, const char*))callback;
}

// Called by the NAPI notify below: hands the shell's answer back to managed code.
extern "C" void ohos_host_bluetooth_result(int request_id, int code, const char* payload) {
    if (g_bluetooth_result_listener != nullptr) {
        g_bluetooth_result_listener(request_id, code, payload != nullptr ? payload : "");
    }
}

// ArkTS calls host.registerBluetoothSink(fn) to receive Bluetooth requests.
napi_value RegisterBluetoothSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            if (g_bluetooth_sink_ref != nullptr) {
                napi_delete_reference(env, g_bluetooth_sink_ref);
            }
            napi_create_reference(env, argv[0], 1, &g_bluetooth_sink_ref);
            OH_LOG_INFO(LOG_APP, "[openharmony-host] bluetooth sink registered");
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notifyBluetoothResult(requestId, code, payload) when a request finished.
napi_value NotifyBluetoothResult(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int requestId = 0;
    int code = -1;
    std::string payload;
    if (argc >= 1) napi_get_value_int32(env, argv[0], &requestId);
    if (argc >= 2) napi_get_value_int32(env, argv[1], &code);
    if (argc >= 3) payload = GetStringArg(env, argv[2]);
    ohos_host_bluetooth_result(requestId, code, payload.c_str());
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Printing (Print Kit): the managed side forwards a file path through ohos_host_print_file;
// the ArkTS shell's registerPrintSink handler calls @ohos.print print.print([path], context)
// (ohos.permission.PRINT is system_grant, so the shell does not prompt) and answers through
// host.notifyPrintResult with code 0 when the system print UI accepted the job and -1 when
// the framework rejected it. The message carries the framework error for the host log.
napi_ref g_print_sink_ref = nullptr;
static void (*g_print_result_listener)(int request_id, int code, const char* message) = nullptr;

// Called from managed code (P/Invoke): forwards a print file path to the ArkTS sink.
extern "C" int ohos_host_print_file(int request_id, const char* path) {
    if (g_env == nullptr || g_print_sink_ref == nullptr) {
        return -1;
    }
    napi_value sink = nullptr;
    if (napi_get_reference_value(g_env, g_print_sink_ref, &sink) != napi_ok || sink == nullptr) {
        return -1;
    }
    napi_value argv[2];
    napi_create_int32(g_env, request_id, &argv[0]);
    napi_create_string_utf8(g_env, path != nullptr ? path : "", NAPI_AUTO_LENGTH, &argv[1]);
    napi_value result = nullptr;
    napi_status status = napi_call_function(g_env, sink, sink, 2, argv, &result);
    return status == napi_ok ? 0 : -1;
}

// The managed side registers the callback that completes a pending print request.
extern "C" void ohos_host_print_register_result(void* callback) {
    g_print_result_listener = (void (*)(int, int, const char*))callback;
}

// Called by the NAPI notify below: hands the shell's answer back to managed code.
extern "C" void ohos_host_print_result(int request_id, int code, const char* message) {
    if (g_print_result_listener != nullptr) {
        g_print_result_listener(request_id, code, message != nullptr ? message : "");
    }
}

// ArkTS calls host.registerPrintSink(fn) to receive print requests.
napi_value RegisterPrintSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            if (g_print_sink_ref != nullptr) {
                napi_delete_reference(env, g_print_sink_ref);
            }
            napi_create_reference(env, argv[0], 1, &g_print_sink_ref);
            OH_LOG_INFO(LOG_APP, "[openharmony-host] print sink registered");
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notifyPrintResult(requestId, code, message) when a request finished.
napi_value NotifyPrintResult(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int requestId = 0;
    int code = -1;
    std::string message;
    if (argc >= 1) napi_get_value_int32(env, argv[0], &requestId);
    if (argc >= 2) napi_get_value_int32(env, argv[1], &code);
    if (argc >= 3) message = GetStringArg(env, argv[2]);
    ohos_host_print_result(requestId, code, message.c_str());
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// App launching: Launcher/Browser/Share forward requests through ohos_host_ability_start; the
// ArkTS shell's sink (registerAbilitySink) owns the UIAbilityContext.startAbility call.
// kind 0 = open uri (implicit viewData Want), 1 = share text (implicit sendData Want),
// 2 = availability probe, answered by the shell without launching anything.
napi_ref g_ability_sink_ref = nullptr;

// Called from managed code (P/Invoke): forwards an ability-start request to the ArkTS shell and
// returns 0 when the sink handled it (dispatched or, for the probe, available).
extern "C" int ohos_host_ability_start(int kind, const char* uri, const char* text) {
    if (g_env == nullptr || g_ability_sink_ref == nullptr) {
        return -1;
    }
    napi_value sink = nullptr;
    if (napi_get_reference_value(g_env, g_ability_sink_ref, &sink) != napi_ok || sink == nullptr) {
        return -1;
    }
    napi_value argv[3];
    napi_create_int32(g_env, kind, &argv[0]);
    napi_create_string_utf8(g_env, uri != nullptr ? uri : "", NAPI_AUTO_LENGTH, &argv[1]);
    napi_create_string_utf8(g_env, text != nullptr ? text : "", NAPI_AUTO_LENGTH, &argv[2]);
    napi_value result = nullptr;
    if (napi_call_function(g_env, sink, sink, 3, argv, &result) != napi_ok) {
        return -1;
    }
    bool handled = false;
    if (result == nullptr || napi_get_value_bool(g_env, result, &handled) != napi_ok || !handled) {
        return -1;
    }
    return 0;
}

// ArkTS calls host.registerAbilitySink(fn) to receive launcher/browser/share requests.
napi_value RegisterAbilitySink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            if (g_ability_sink_ref != nullptr) {
                napi_delete_reference(env, g_ability_sink_ref);
            }
            napi_create_reference(env, argv[0], 1, &g_ability_sink_ref);
            OH_LOG_INFO(LOG_APP, "[openharmony-host] ability sink registered");
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Menus: the managed side publishes the current page's menu items as a flat table
// (ohos_host_menu_begin/item/commit). The ArkTS shell pulls it back through menuCount/menuItem
// after registerMenuChangedSink fires (count, also sent for an empty table so the menu hides),
// and reports a tap with host.notifyMenuAction(index) -> the managed activation callback.
// The table carries text/enabled only: nested MenuFlyoutSubItems are flattened by the managed
// publisher, which drops the depth information because this table has no column for it.
struct HostMenuItem {
    std::string text;
    bool enabled;
};

static std::vector<HostMenuItem> g_menu_items;
static napi_ref g_menu_changed_sink_ref = nullptr;
static void (*g_menu_action_listener)(int index) = nullptr;

// ArkTS calls host.menuCount() to size its @State array.
napi_value MenuCount(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value result = nullptr;
    napi_create_int32(env, (int32_t)g_menu_items.size(), &result);
    return result;
}

// ArkTS calls host.menuItem(index) and receives { text, enabled } (undefined out of range).
napi_value MenuGetItem(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t index = -1;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &index);
    }
    if (index < 0 || (size_t)index >= g_menu_items.size()) {
        napi_value undefined = nullptr;
        napi_get_undefined(env, &undefined);
        return undefined;
    }
    const HostMenuItem& item = g_menu_items[(size_t)index];
    napi_value object = nullptr;
    napi_create_object(env, &object);
    napi_value text = nullptr;
    napi_create_string_utf8(env, item.text.c_str(), NAPI_AUTO_LENGTH, &text);
    napi_set_named_property(env, object, "text", text);
    napi_value enabled = nullptr;
    napi_get_boolean(env, item.enabled, &enabled);
    napi_set_named_property(env, object, "enabled", enabled);
    return object;
}

// Asks the shell to rebuild its menu state from the table just committed.
static void NotifyMenuChanged() {
    if (g_env == nullptr || g_menu_changed_sink_ref == nullptr) {
        return;
    }
    napi_value sink = nullptr;
    if (napi_get_reference_value(g_env, g_menu_changed_sink_ref, &sink) != napi_ok || sink == nullptr) {
        return;
    }
    napi_value argv[1] = {nullptr};
    napi_create_int32(g_env, (int32_t)g_menu_items.size(), &argv[0]);
    napi_value result = nullptr;
    napi_call_function(g_env, sink, sink, 1, argv, &result);
}

// Managed P/Invoke: opens a new menu table (drops the previous one).
extern "C" int ohos_host_menu_begin(int count) {
    g_menu_items.clear();
    if (count > 0) {
        g_menu_items.reserve((size_t)count);
    }
    return 0;
}

// Managed P/Invoke: sets one row; index is the row position published back to the shell.
extern "C" int ohos_host_menu_item(int index, const char* text, int enabled) {
    if (index < 0) {
        return -1;
    }
    size_t position = (size_t)index;
    if (position >= g_menu_items.size()) {
        g_menu_items.resize(position + 1);
    }
    g_menu_items[position].text = text != nullptr ? text : "";
    g_menu_items[position].enabled = enabled != 0;
    return 0;
}

// Managed P/Invoke: publishes the table and reports the new count.
extern "C" int ohos_host_menu_commit(void) {
    NotifyMenuChanged();
    return (int)g_menu_items.size();
}

// Managed P/Invoke: registers the callback invoked by host.notifyMenuAction(index).
extern "C" void ohos_host_menu_set_listener(void* callback) {
    g_menu_action_listener = (void (*)(int))callback;
}

// ArkTS calls host.registerMenuChangedSink(fn) to be told when the table changed.
napi_value RegisterMenuChangedSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            if (g_menu_changed_sink_ref != nullptr) {
                napi_delete_reference(env, g_menu_changed_sink_ref);
            }
            napi_create_reference(env, argv[0], 1, &g_menu_changed_sink_ref);
            OH_LOG_INFO(LOG_APP, "[openharmony-host] menu sink registered");
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notifyMenuAction(index) when a menu row is tapped.
napi_value NotifyMenuAction(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t index = -1;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &index);
    }
    if (index >= 0 && g_menu_action_listener != nullptr) {
        g_menu_action_listener((int)index);
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_ref g_web_sink_ref = nullptr;

void OnPickerRequest(int requestId, int kind) {
    if (g_env == nullptr || g_picker_sink_ref == nullptr) {
        return;
    }
    napi_value sink = nullptr;
    if (napi_get_reference_value(g_env, g_picker_sink_ref, &sink) != napi_ok || sink == nullptr) {
        return;
    }
    napi_value global = nullptr;
    napi_get_global(g_env, &global);
    napi_value argv[2] = {nullptr, nullptr};
    napi_create_int32(g_env, requestId, &argv[0]);
    napi_create_int32(g_env, kind, &argv[1]);
    napi_value result = nullptr;
    napi_call_function(g_env, global, sink, 2, argv, &result);
}

void OnWebCommand(const char* op, const char* arg) {
    if (g_env == nullptr || g_web_sink_ref == nullptr) {
        return;
    }
    napi_value sink = nullptr;
    if (napi_get_reference_value(g_env, g_web_sink_ref, &sink) != napi_ok || sink == nullptr) {
        return;
    }
    napi_value global = nullptr;
    napi_get_global(g_env, &global);
    napi_value argv[2] = {nullptr, nullptr};
    napi_create_string_utf8(g_env, op, NAPI_AUTO_LENGTH, &argv[0]);
    napi_create_string_utf8(g_env, arg, NAPI_AUTO_LENGTH, &argv[1]);
    napi_value result = nullptr;
    napi_call_function(g_env, global, sink, 2, argv, &result);
}

// ArkTS calls host.registerWebSink(fn) to receive web commands.
napi_value RegisterWebSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            if (g_web_sink_ref != nullptr) {
                napi_delete_reference(env, g_web_sink_ref);
            }
            napi_create_reference(env, argv[0], 1, &g_web_sink_ref);
            ohos_host_web_set_listener(OnWebCommand);
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notifyAvoidArea(top, bottom, left, right).
napi_value NotifyAvoidArea(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int values[4] = {0, 0, 0, 0};
    for (size_t i = 0; i < 4 && i < argc; i++) {
        napi_get_value_int32(env, argv[i], &values[i]);
    }
    ohos_host_set_avoid_area(values[0], values[1], values[2], values[3]);
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notifyTheme(isDark) when the device colour mode changes (1 = dark, 0 = light).
static void (*g_theme_listener)(int isDark) = nullptr;

extern "C" void ohos_host_theme_set_listener(void* callback) {
    g_theme_listener = (void (*)(int))callback;
}

napi_value NotifyTheme(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t isDark = 0;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &isDark);
    }
    if (g_theme_listener != nullptr) {
        g_theme_listener(isDark != 0 ? 1 : 0);
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notifyWebEvent(state, url).
napi_value NotifyWebEvent(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string state;
    std::string url;
    if (argc >= 1) state = GetStringArg(env, argv[0]);
    if (argc >= 2) url = GetStringArg(env, argv[1]);
    ohos_host_web_notify_event(state.c_str(), url.c_str());
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// JavaScript bridge: the managed side evaluates scripts through ohos_host_web_eval; the ArkTS
// shell's registerWebEvalSink handler runs them on the ArkWeb controller and answers with
// host.notifyWebEvalResult(requestId, result, error). Page messages posted from JavaScript
// through the dotnetHost proxy arrive as host.notifyJsMessage(payload) and are forwarded to the
// managed callback registered with ohos_host_web_js_register_message.
napi_ref g_web_eval_sink_ref = nullptr;
static void (*g_web_eval_result_listener)(int request_id, const char* result, int error) = nullptr;
static void (*g_web_js_message_listener)(const char* payload) = nullptr;

// Called from managed code (P/Invoke): forwards a script evaluation request to the ArkTS sink.
extern "C" int ohos_host_web_eval(const char* script, int request_id) {
    if (g_env == nullptr || g_web_eval_sink_ref == nullptr) {
        return -1;
    }
    napi_value sink = nullptr;
    if (napi_get_reference_value(g_env, g_web_eval_sink_ref, &sink) != napi_ok || sink == nullptr) {
        return -1;
    }
    napi_value argv[2] = {nullptr, nullptr};
    napi_create_string_utf8(g_env, script != nullptr ? script : "", NAPI_AUTO_LENGTH, &argv[0]);
    napi_create_int32(g_env, request_id, &argv[1]);
    napi_value result = nullptr;
    napi_status status = napi_call_function(g_env, sink, sink, 2, argv, &result);
    return status == napi_ok ? 0 : -1;
}

// The managed side registers the callback that completes a pending script evaluation.
extern "C" void ohos_host_web_js_register_result(void* callback) {
    g_web_eval_result_listener = (void (*)(int, const char*, int))callback;
}

// The managed side registers the callback that receives JavaScript page messages.
extern "C" void ohos_host_web_js_register_message(void* callback) {
    g_web_js_message_listener = (void (*)(const char*))callback;
}

// ArkTS calls host.registerWebEvalSink(fn) to receive script evaluation requests.
napi_value RegisterWebEvalSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            if (g_web_eval_sink_ref != nullptr) {
                napi_delete_reference(env, g_web_eval_sink_ref);
            }
            napi_create_reference(env, argv[0], 1, &g_web_eval_sink_ref);
            OH_LOG_INFO(LOG_APP, "[openharmony-host] web eval sink registered");
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notifyWebEvalResult(requestId, result, error) when runJavaScript finished.
napi_value NotifyWebEvalResult(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int requestId = 0;
    std::string result;
    int error = 0;
    if (argc >= 1) napi_get_value_int32(env, argv[0], &requestId);
    if (argc >= 2) result = GetStringArg(env, argv[1]);
    if (argc >= 3) napi_get_value_int32(env, argv[2], &error);
    if (g_web_eval_result_listener != nullptr) {
        g_web_eval_result_listener(requestId, result.c_str(), error);
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notifyJsMessage(payload) from the dotnetHost.postMessage JavaScript proxy.
napi_value NotifyJsMessage(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string payload;
    if (argc >= 1) payload = GetStringArg(env, argv[0]);
    if (g_web_js_message_listener != nullptr) {
        g_web_js_message_listener(payload.c_str());
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.registerPickerSink(fn) to receive picker requests.
napi_value RegisterPickerSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            if (g_picker_sink_ref != nullptr) {
                napi_delete_reference(env, g_picker_sink_ref);
            }
            napi_create_reference(env, argv[0], 1, &g_picker_sink_ref);
            ohos_host_picker_set_listener(OnPickerRequest);
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notifyPickerResult(requestId, rc, name, dataBase64).
napi_value NotifyPickerResult(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int requestId = 0;
    int rc = -1;
    std::string name;
    std::string data;
    if (argc >= 1) napi_get_value_int32(env, argv[0], &requestId);
    if (argc >= 2) napi_get_value_int32(env, argv[1], &rc);
    if (argc >= 3) name = GetStringArg(env, argv[2]);
    if (argc >= 4) data = GetStringArg(env, argv[3]);
    ohos_host_picker_complete(requestId, rc, name.c_str(), data.c_str());
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.registerVibrationSink(fn) to receive vibration requests (the preferred
// path is the NDK export ohos_host_vibrate; this sink stays for shells that provide one).
napi_ref g_vibration_sink_ref = nullptr;

void OnVibrationRequest(int durationMs) {
    if (g_env != nullptr && g_vibration_sink_ref != nullptr) {
        napi_value sink = nullptr;
        if (napi_get_reference_value(g_env, g_vibration_sink_ref, &sink) == napi_ok && sink != nullptr) {
            napi_value global = nullptr;
            napi_get_global(g_env, &global);
            napi_value arg = nullptr;
            napi_create_int32(g_env, durationMs, &arg);
            napi_value result = nullptr;
            napi_call_function(g_env, global, sink, 1, &arg, &result);
        }
    }
}

napi_value RegisterVibrationSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            if (g_vibration_sink_ref != nullptr) {
                napi_delete_reference(env, g_vibration_sink_ref);
            }
            napi_create_reference(env, argv[0], 1, &g_vibration_sink_ref);
            ohos_host_set_vibration_listener(OnVibrationRequest);
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value RegisterKeystoreSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            if (g_keystore_sink_ref != nullptr) {
                napi_delete_reference(env, g_keystore_sink_ref);
            }
            napi_create_reference(env, argv[0], 1, &g_keystore_sink_ref);
            ohos_host_keystore_set_listener(OnKeystoreRequest);
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notifyKeystoreResult(requestId, rc, dataBase64).
napi_value NotifyKeystoreResult(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int requestId = 0;
    int rc = -1;
    std::string data;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &requestId);
    }
    if (argc >= 2) {
        napi_get_value_int32(env, argv[1], &rc);
    }
    if (argc >= 3) {
        data = GetStringArg(env, argv[2]);
    }
    ohos_host_keystore_complete(requestId, rc, data.c_str());
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Called by the host core (managed side) to show/hide the ArkTS soft keyboard.
void OnTextInputRequest(int show) {
    if (g_env == nullptr || g_text_input_sink_ref == nullptr) {
        return;
    }
    napi_value sink = nullptr;
    if (napi_get_reference_value(g_env, g_text_input_sink_ref, &sink) != napi_ok || sink == nullptr) {
        return;
    }
    napi_value global = nullptr;
    napi_get_global(g_env, &global);
    napi_value arg = nullptr;
    napi_create_int32(g_env, show, &arg);
    napi_value result = nullptr;
    napi_call_function(g_env, global, sink, 1, &arg, &result);
}

// ArkTS calls host.registerTextInputSink(fn) so the shell can show/hide its input.
napi_value RegisterTextInputSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            if (g_text_input_sink_ref != nullptr) {
                napi_delete_reference(env, g_text_input_sink_ref);
            }
            napi_create_reference(env, argv[0], 1, &g_text_input_sink_ref);
            ohos_host_set_text_input_listener(OnTextInputRequest);
            OH_LOG_INFO(LOG_APP, "[openharmony-host] text input sink registered");
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notifyTextSubmitted(text) when the return key is pressed.
napi_value NotifyTextSubmitted(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        std::string text = GetStringArg(env, argv[0]);
        ohos_host_notify_text_input(text.c_str());
    }
    ohos_host_notify_text_submitted();
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notifyTextInput(text) on every change.
napi_value NotifyTextInput(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        std::string text = GetStringArg(env, argv[0]);
        ohos_host_notify_text_input(text.c_str());
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value RegisterXComponent(napi_env env, napi_callback_info info) {
    (void)info;
    if (g_env == nullptr) {
        g_env = env;
    }
    TryRegisterXComponent();
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

struct LaunchRequest {
    char* app_dir;
    char* assembly;
    char* context_json;
};

std::string GetStringArg(napi_env env, napi_value value) {
    size_t length = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &length);
    std::string result(length, '\0');
    napi_get_value_string_utf8(env, value, result.data(), length + 1, &length);
    return result;
}

bool TryGetStringArg(napi_env env, napi_value value, std::string* out) {
    napi_valuetype type = napi_undefined;
    napi_typeof(env, value, &type);
    if (type != napi_string) {
        return false;
    }
    *out = GetStringArg(env, value);
    return true;
}

void* LaunchThread(void* arg) {
    LaunchRequest* request = static_cast<LaunchRequest*>(arg);
    OhosHostAppHandle* handle = nullptr;
    int rc = ohos_host_start_app(request->app_dir, request->assembly, nullptr, request->context_json, &handle);
    g_handle = handle;
    if (rc != 0) {
        OH_LOG_ERROR(LOG_APP, "[openharmony-host] start_app failed rc=%{public}d", rc);
    } else {
        OH_LOG_INFO(LOG_APP, "[openharmony-host] app %{public}s started", request->assembly);
    }
    free(request->app_dir);
    free(request->assembly);
    free(request->context_json);
    delete request;
    return nullptr;
}

napi_value StartApp(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "startApp(appDir, assemblyFile, contextJson?) requires two strings");
        return nullptr;
    }

    std::string app_dir = GetStringArg(env, argv[0]);
    std::string assembly = GetStringArg(env, argv[1]);
    std::string context;
    if (argc >= 3) {
        TryGetStringArg(env, argv[2], &context);
    }

    LaunchRequest* request = new LaunchRequest();
    request->app_dir = strdup(app_dir.c_str());
    request->assembly = strdup(assembly.c_str());
    request->context_json = context.empty() ? nullptr : strdup(context.c_str());

    pthread_t thread;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int rc = pthread_create(&thread, &attr, LaunchThread, request);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        OH_LOG_ERROR(LOG_APP, "[openharmony-host] pthread_create failed: %{public}d", rc);
        free(request->app_dir);
        free(request->assembly);
        free(request->context_json);
        delete request;
        napi_throw_error(env, nullptr, "failed to start the .NET app thread");
        return nullptr;
    }

    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value NotifyLifecycle(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t event = 0;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &event);
    }
    // The handle is created by the launch thread; the native side queues events
    // until the managed bridge registers, so a race here is harmless.
    ohos_host_notify_lifecycle(g_handle, static_cast<ohos_lifecycle_event>(event));
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value SetNodeContent(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        // The ArkTS side passes a NodeContent (from @ohos.arkui.node); convert it to
        // the native handle the managed app can attach ArkUI nodes to.
        ArkUI_NodeContentHandle content = nullptr;
        if (OH_ArkUI_GetNodeContentFromNapiValue(env, argv[0], &content) == 0) {
            ohos_host_set_node_content(g_handle, content);
        } else {
            OH_LOG_WARN(LOG_APP, "[openharmony-host] setNodeContent: not a NodeContent value");
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
    // The accessibility provider rides the same NodeContent the shell hands over.
    AttachAccessibilityValue(env, argv[0]);
}

napi_value StopApp(napi_env env, napi_callback_info info) {
    (void)info;
    ohos_host_notify_lifecycle(g_handle, OHOS_LIFECYCLE_DESTROY);
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value RunApp(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "runApp(appDir, assemblyFile) requires two strings");
        return nullptr;
    }
    std::string app_dir = GetStringArg(env, argv[0]);
    std::string assembly = GetStringArg(env, argv[1]);
    int exit_code = ohos_host_run_app(app_dir.c_str(), assembly.c_str(), 0, nullptr);
    napi_value result = nullptr;
    napi_create_int32(env, exit_code, &result);
    return result;
}

napi_value Init(napi_env env, napi_value exports) {
    g_env = env;
    napi_create_reference(env, exports, 1, &g_exports_ref);
    TryRegisterXComponent();
    napi_property_descriptor properties[] = {
        {"registerXComponent", nullptr, RegisterXComponent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerTextInputSink", nullptr, RegisterTextInputSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyTextInput", nullptr, NotifyTextInput, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyTextSubmitted", nullptr, NotifyTextSubmitted, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerKeystoreSink", nullptr, RegisterKeystoreSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerVibrationSink", nullptr, RegisterVibrationSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerPickerSink", nullptr, RegisterPickerSink, nullptr, nullptr, nullptr, napi_default, nullptr},

        {"registerNotificationSink", nullptr, RegisterNotificationSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerTtsSink", nullptr, RegisterTtsSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyTtsResult", nullptr, NotifyTtsResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerContactsSink", nullptr, RegisterContactsSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyContactsResult", nullptr, NotifyContactsResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerCalendarSink", nullptr, RegisterCalendarSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyCalendarResult", nullptr, NotifyCalendarResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerBluetoothSink", nullptr, RegisterBluetoothSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyBluetoothResult", nullptr, NotifyBluetoothResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerPrintSink", nullptr, RegisterPrintSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyPrintResult", nullptr, NotifyPrintResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerAbilitySink", nullptr, RegisterAbilitySink, nullptr, nullptr, nullptr, napi_default, nullptr},

        {"registerMenuChangedSink", nullptr, RegisterMenuChangedSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"menuCount", nullptr, MenuCount, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"menuItem", nullptr, MenuGetItem, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyMenuAction", nullptr, NotifyMenuAction, nullptr, nullptr, nullptr, napi_default, nullptr},

        {"notifyPinch", nullptr, NotifyPinch, nullptr, nullptr, nullptr, napi_default, nullptr},



        {"accessibilityStatus", nullptr, AccessibilityStatus, nullptr, nullptr, nullptr, napi_default, nullptr},



        {"attachAccessibilityNode", nullptr, AttachAccessibilityNode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerWebSink", nullptr, RegisterWebSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyWebEvent", nullptr, NotifyWebEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerWebEvalSink", nullptr, RegisterWebEvalSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyWebEvalResult", nullptr, NotifyWebEvalResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyJsMessage", nullptr, NotifyJsMessage, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyAvoidArea", nullptr, NotifyAvoidArea, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyTheme", nullptr, NotifyTheme, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyPickerResult", nullptr, NotifyPickerResult, nullptr, nullptr, nullptr, napi_default, nullptr},

        {"notifyKeystoreResult", nullptr, NotifyKeystoreResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startApp", nullptr, StartApp, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyLifecycle", nullptr, NotifyLifecycle, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setNodeContent", nullptr, SetNodeContent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopApp", nullptr, StopApp, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runApp", nullptr, RunApp, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}

}  // namespace

static napi_module g_hostModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "openharmonyhost",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterHostModule(void) {
    napi_module_register(&g_hostModule);
}


// ---------------------------------------------------------------------------
// Accessibility provider: serves the node table published by the runtime to
// ArkUI's accessibility framework (see docs/plans/2026-09-19-ohos-arkts-handover-status.md 3b).
// ---------------------------------------------------------------------------
#include <arkui/native_node_napi.h>
#include <arkui/native_interface_accessibility.h>
#include <cstring>

extern "C" int ohos_host_accessibility_count(void);
extern "C" int ohos_host_accessibility_get(int index, int* id, int* parent_id, const char** role,
                                           const char** text, const char** description,
                                           float* x, float* y, float* width, float* height,
                                           int* flags, int* actions);

static ArkUI_AccessibilityProvider* g_a11y_provider = nullptr;
static int g_a11y_status = 0;  // 0 = not attached, 1 = attached
static void (*g_a11y_action_listener)(int id, int action) = nullptr;

// Layout coordinates can be extreme or NaN; the framework rect is int32, so clamp them.
static int32_t A11yCoord(float value) {
    if (value != value) {
        return 0;
    }
    if (value < -32768.0f) {
        return -32768;
    }
    if (value > 32767.0f) {
        return 32767;
    }
    return (int32_t)value;
}

static void A11yAddNode(ArkUI_AccessibilityElementInfoList* list, int index) {
    int id = 0, parent = 0, flags = 0, actions = 0;
    const char* role = nullptr; const char* text = nullptr; const char* description = nullptr;
    float x = 0, y = 0, w = 0, h = 0;
    if (ohos_host_accessibility_get(index, &id, &parent, &role, &text, &description,
                                    &x, &y, &w, &h, &flags, &actions) != 0) {
        return;
    }
    ArkUI_AccessibilityElementInfo* info = OH_ArkUI_AddAndGetAccessibilityElementInfo(list);
    if (info == nullptr) {
        return;
    }
    OH_ArkUI_AccessibilityElementInfoSetElementId(info, id);
    OH_ArkUI_AccessibilityElementInfoSetParentId(info, parent);
    OH_ArkUI_AccessibilityElementInfoSetComponentType(info, role != nullptr ? role : "group");
    if (text != nullptr) {
        OH_ArkUI_AccessibilityElementInfoSetAccessibilityText(info, text);
    }
    if (description != nullptr) {
        OH_ArkUI_AccessibilityElementInfoSetContents(info, description);
    }
    ArkUI_AccessibleRect rect;
    rect.leftTopX = A11yCoord(x);
    rect.leftTopY = A11yCoord(y);
    rect.rightBottomX = A11yCoord(x + w);
    rect.rightBottomY = A11yCoord(y + h);
    OH_ArkUI_AccessibilityElementInfoSetScreenRect(info, &rect);
    OH_ArkUI_AccessibilityElementInfoSetClickable(info, (actions & 0x10) != 0);
    OH_ArkUI_AccessibilityElementInfoSetEnabled(info, (flags & 1) != 0);
    OH_ArkUI_AccessibilityElementInfoSetFocusable(info, (flags & 2) != 0);
}

static int32_t A11yFindById(int64_t elementId, ArkUI_AccessibilitySearchMode mode,
                            int32_t requestId, ArkUI_AccessibilityElementInfoList* list) {
    (void)requestId;
    int count = ohos_host_accessibility_count();
    if (count <= 0) {
        return ARKUI_ACCESSIBILITY_NATIVE_RESULT_FAILED;
    }
    if (elementId <= 0) {
        A11yAddNode(list, 0);              // root
        return ARKUI_ACCESSIBILITY_NATIVE_RESULT_SUCCESSFUL;
    }
    for (int i = 0; i < count; i++) {
        int id = 0;
        ohos_host_accessibility_get(i, &id, nullptr, nullptr, nullptr, nullptr,
                                   nullptr, nullptr, nullptr, nullptr, nullptr, nullptr);
        if (id == (int)elementId) {
            A11yAddNode(list, i);
            if ((int)mode & ARKUI_ACCESSIBILITY_NATIVE_SEARCH_MODE_PREFETCH_CHILDREN) {
                for (int j = 0; j < count; j++) {
                    int parent = 0;
                    ohos_host_accessibility_get(j, nullptr, &parent, nullptr, nullptr, nullptr,
                                               nullptr, nullptr, nullptr, nullptr, nullptr, nullptr);
                    if (parent == id) {
                        A11yAddNode(list, j);
                    }
                }
            }
            return ARKUI_ACCESSIBILITY_NATIVE_RESULT_SUCCESSFUL;
        }
    }
    return ARKUI_ACCESSIBILITY_NATIVE_RESULT_FAILED;
}

static int32_t A11yFindByText(int64_t elementId, const char* text, int32_t requestId,
                              ArkUI_AccessibilityElementInfoList* list) {
    (void)elementId; (void)requestId;
    if (text == nullptr) {
        return ARKUI_ACCESSIBILITY_NATIVE_RESULT_BAD_PARAMETER;
    }
    int count = ohos_host_accessibility_count();
    int found = 0;
    for (int i = 0; i < count; i++) {
        const char* nodeText = nullptr; const char* description = nullptr;
        ohos_host_accessibility_get(i, nullptr, nullptr, nullptr, &nodeText, &description,
                                   nullptr, nullptr, nullptr, nullptr, nullptr, nullptr);
        if ((nodeText != nullptr && strstr(nodeText, text) != nullptr) ||
            (description != nullptr && strstr(description, text) != nullptr)) {
            A11yAddNode(list, i);
            found++;
        }
    }
    return found > 0 ? ARKUI_ACCESSIBILITY_NATIVE_RESULT_SUCCESSFUL : ARKUI_ACCESSIBILITY_NATIVE_RESULT_FAILED;
}

static int A11yFirstFocusable(int afterIndex) {
    int count = ohos_host_accessibility_count();
    for (int step = 0; step < count; step++) {
        int i = (afterIndex + 1 + step) % count;
        int flags = 0;
        ohos_host_accessibility_get(i, nullptr, nullptr, nullptr, nullptr, nullptr,
                                   nullptr, nullptr, nullptr, nullptr, &flags, nullptr);
        if ((flags & 2) != 0) {
            return i;
        }
    }
    return -1;
}

static int32_t A11yFillSingle(int index, ArkUI_AccessibilityElementInfo* info) {
    if (index < 0 || info == nullptr) {
        return ARKUI_ACCESSIBILITY_NATIVE_RESULT_FAILED;
    }
    int id = 0, parent = 0, flags = 0, actions = 0;
    const char* role = nullptr; const char* text = nullptr; const char* description = nullptr;
    float x = 0, y = 0, w = 0, h = 0;
    if (ohos_host_accessibility_get(index, &id, &parent, &role, &text, &description,
                                    &x, &y, &w, &h, &flags, &actions) != 0) {
        return ARKUI_ACCESSIBILITY_NATIVE_RESULT_FAILED;
    }
    OH_ArkUI_AccessibilityElementInfoSetElementId(info, id);
    OH_ArkUI_AccessibilityElementInfoSetParentId(info, parent);
    OH_ArkUI_AccessibilityElementInfoSetComponentType(info, role != nullptr ? role : "group");
    if (text != nullptr) {
        OH_ArkUI_AccessibilityElementInfoSetAccessibilityText(info, text);
    }
    if (description != nullptr) {
        OH_ArkUI_AccessibilityElementInfoSetContents(info, description);
    }
    ArkUI_AccessibleRect rect;
    rect.leftTopX = A11yCoord(x); rect.leftTopY = A11yCoord(y);
    rect.rightBottomX = A11yCoord(x + w); rect.rightBottomY = A11yCoord(y + h);
    OH_ArkUI_AccessibilityElementInfoSetScreenRect(info, &rect);
    OH_ArkUI_AccessibilityElementInfoSetClickable(info, (actions & 0x10) != 0);
    OH_ArkUI_AccessibilityElementInfoSetEnabled(info, (flags & 1) != 0);
    OH_ArkUI_AccessibilityElementInfoSetFocusable(info, (flags & 2) != 0);
    return ARKUI_ACCESSIBILITY_NATIVE_RESULT_SUCCESSFUL;
}

static int32_t A11yFocused(int64_t elementId, ArkUI_AccessibilityFocusType focusType,
                           int32_t requestId, ArkUI_AccessibilityElementInfo* info) {
    (void)elementId; (void)focusType; (void)requestId;
    return A11yFillSingle(A11yFirstFocusable(-1), info);
}

static int32_t A11yNextFocus(int64_t elementId, ArkUI_AccessibilityFocusMoveDirection direction,
                             int32_t requestId, ArkUI_AccessibilityElementInfo* info) {
    (void)direction; (void)requestId;
    return A11yFillSingle(A11yFirstFocusable((int)elementId - 1), info);
}

static int32_t A11yExecuteAction(int64_t elementId, ArkUI_Accessibility_ActionType action,
                                 ArkUI_AccessibilityActionArguments* arguments, int32_t requestId) {
    (void)arguments; (void)requestId;
    if (g_a11y_action_listener != nullptr) {
        g_a11y_action_listener((int)elementId, (int)action);
        return ARKUI_ACCESSIBILITY_NATIVE_RESULT_SUCCESSFUL;
    }
    return ARKUI_ACCESSIBILITY_NATIVE_RESULT_FAILED;
}

static int32_t A11yClearFocus(void) {
    return ARKUI_ACCESSIBILITY_NATIVE_RESULT_SUCCESSFUL;
}

static int32_t A11yCursorPosition(int64_t elementId, int32_t requestId, int32_t* index) {
    (void)elementId; (void)requestId;
    if (index != nullptr) {
        *index = 0;
    }
    return ARKUI_ACCESSIBILITY_NATIVE_RESULT_SUCCESSFUL;
}

static ArkUI_AccessibilityProviderCallbacks g_a11y_callbacks = {
    A11yFindById, A11yFindByText, A11yFocused, A11yNextFocus,
    A11yExecuteAction, A11yClearFocus, A11yCursorPosition,
};

// ArkTS calls host.attachAccessibilityNode(nodeOrNodeContent) with the node that hosts our content.
static int AttachAccessibilityValue(napi_env env, napi_value value) {
    if (value == nullptr) {
        return g_a11y_status;
    }
    ArkUI_NodeHandle node = nullptr;
    if (OH_ArkUI_GetNodeHandleFromNapiValue(env, value, &node) == 0 && node != nullptr) {
        g_a11y_status = 2;  // frame node received
        if (OH_ArkUI_NativeModule_GetNativeAccessibilityProvider(&node, &g_a11y_provider) == 0 &&
            g_a11y_provider != nullptr &&
            OH_ArkUI_AccessibilityProviderRegisterCallback(g_a11y_provider, &g_a11y_callbacks) == 0) {
            g_a11y_status = 1;  // provider attached
        }
        return g_a11y_status;
    }
    ArkUI_NodeContentHandle content = nullptr;
    if (OH_ArkUI_GetNodeContentFromNapiValue(env, value, &content) == 0 && content != nullptr) {
        g_a11y_status = 3;  // node content received; a custom node still has to be supplied
    }
    return g_a11y_status;
}

napi_value AttachAccessibilityNode(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) {
        return nullptr;
    }
    AttachAccessibilityValue(env, argv[0]);
    napi_value result = nullptr;
    napi_create_int32(env, g_a11y_status, &result);
    return result;
}

napi_value AccessibilityStatus(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value result = nullptr;
    napi_create_int32(env, g_a11y_status, &result);
    return result;
}


// Managed side hooks: register the action listener and push accessibility events.
extern "C" void ohos_host_accessibility_set_action_listener(void* callback) {
    g_a11y_action_listener = (void (*)(int, int))callback;
}

extern "C" int ohos_host_accessibility_send_event(int eventType) {
    if (g_a11y_provider == nullptr || eventType == 0) {
        return 0;
    }
    ArkUI_AccessibilityEventInfo* event = OH_ArkUI_CreateAccessibilityEventInfo();
    if (event == nullptr) {
        return 0;
    }
    if (OH_ArkUI_AccessibilityEventSetEventType(event, (ArkUI_AccessibilityEventType)eventType) != 0) {
        OH_ArkUI_DestoryAccessibilityEventInfo(event);
        return 0;
    }
    OH_ArkUI_SendAccessibilityAsyncEvent(g_a11y_provider, event, nullptr);
    return 1;
}


// C entry point so the managed runtime can log the attach state (1/2/3, see the handover status).
extern "C" int ohos_host_accessibility_provider_status(void) {
    return g_a11y_status;
}
