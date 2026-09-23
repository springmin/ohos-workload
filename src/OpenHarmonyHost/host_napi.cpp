// NAPI module that hosts a published .NET app inside an OpenHarmony application.
// ArkTS side:
//   import host from 'libopenharmonyhost.so';
//   host.startApp(appDir, assemblyFile, contextJson);   // async, returns immediately
//   host.setAppContext(contextJson);                     // (re-)publish the app context
//   host.notifyAppContext();                             // re-emit the stored snapshot
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

#include <mutex>

// Forward declarations: the module function table below references these (defined at the end).
napi_value AttachAccessibilityNode(napi_env env, napi_callback_info info);
static int AttachAccessibilityValue(napi_env env, napi_value value);
napi_value AccessibilityStatus(napi_env env, napi_callback_info info);
napi_value AccessibilityNodeCount(napi_env env, napi_callback_info info);

#include <string>
#include <vector>

#include "openharmony_host.h"

#define OHOS_HOST_DOMAIN 0x0002
#define OHOS_HOST_TAG "OHOS_DOTNET"

namespace {

OhosHostAppHandle* g_handle = nullptr;

// startApp re-entry guard. The C entry (ohos_host_start_app) has its own guard; this one
// rejects a second JS call before it allocates a LaunchRequest or spawns a launch thread, so
// a duplicate call cannot leak a request or race the first launch. It is cleared when a
// launch fails (retry allowed); after a success g_handle rejects later calls on its own.
std::mutex g_launch_lock;
bool g_launch_requested = false;

// XComponent (surface) support -------------------------------------------------
napi_env g_env = nullptr;
napi_ref g_exports_ref = nullptr;
OH_NativeXComponent* g_xcomponent = nullptr;

// Host -> shell dispatch over napi_threadsafe_function ---------------------------
// The managed app runs on its own thread, but ArkTS values and the shell's callbacks may
// only be touched on the JS/UI thread. Every sink therefore owns a
// napi_threadsafe_function created from the registered function by Register*Sink;
// notifications copy their arguments into a heap block and enqueue it with
// napi_call_threadsafe_function. The queue is small, bounded and always called
// non-blocking: when it is full the notification is dropped after one log line instead
// of blocking the caller or touching the JS thread from the wrong side. The shell-side
// deferral stays in place as defence in depth.
//
// napi_threadsafe_function surface used (napi/native_api.h + node_api_types.h):
//   napi_status napi_create_threadsafe_function(napi_env env, napi_value func,
//       napi_value async_resource, napi_value async_resource_name, size_t max_queue_size,
//       size_t initial_thread_count, void* thread_finalize_data,
//       napi_finalize thread_finalize_cb, void* context,
//       napi_threadsafe_function_call_js call_js_cb, napi_threadsafe_function* result);
//   napi_status napi_call_threadsafe_function(napi_threadsafe_function func, void* data,
//       napi_threadsafe_function_call_mode is_blocking);   // napi_tsfn_nonblocking
//   napi_status napi_release_threadsafe_function(napi_threadsafe_function func,
//       napi_threadsafe_function_release_mode mode);       // napi_tsfn_abort
//   typedef void (*napi_threadsafe_function_call_js)(napi_env env, napi_value js_callback,
//       void* context, void* data);

// Length caps for the strings crossing the bridge. Control strings are the identifiers, paths
// and UI text the shell applies; results are payloads handed to the managed side. An over-long
// value is logged and dropped (never delivered truncated).
constexpr size_t kMaxControlBytes = 64 * 1024;
constexpr size_t kMaxResultBytes = 1024 * 1024;
// A screenshot output path is a filesystem path, not a payload: keep it well below PATH_MAX.
constexpr size_t kMaxScreenshotPathBytes = 4096;
// The connectivity capability encoding is a short comma-separated bearer-type list (the shell
// caps it at 8 entries / 32 characters); NotifyNetworkAccess drops a bigger payload.
constexpr size_t kMaxNetworkCapabilityBytes = 64;

struct SinkArg {
    bool is_string = false;
    int32_t int_value = 0;
    std::string string_value;
};

// One notification: the argument vector the shell callback will be invoked with.
struct SinkCall {
    enum { kMaxArgs = 5 };
    int count = 0;
    SinkArg args[kMaxArgs];
    // Set when an AddString argument exceeded its cap: a notification with a missing or partial
    // argument must not be delivered (see HostSinkPost).
    bool overflow = false;

    void AddInt(int32_t value) {
        if (count < kMaxArgs) {
            args[count].is_string = false;
            args[count].int_value = value;
            count++;
        }
    }

    // Appends one string argument. max_bytes defaults to the result cap; control strings pass
    // kMaxControlBytes at their call site. Returns false after one log line when the value is
    // longer than the cap (the argument is not appended and the call is marked as overflow).
    bool AddString(const char* value, size_t max_bytes = kMaxResultBytes) {
        size_t length = value != nullptr ? strlen(value) : 0;
        if (length > max_bytes) {
            OH_LOG_WARN(LOG_APP, "[openharmony-host] string argument dropped: %{public}d bytes over the %{public}d cap",
                        (int)length, (int)max_bytes);
            overflow = true;
            return false;
        }
        if (count < kMaxArgs) {
            args[count].is_string = true;
            args[count].string_value = value != nullptr ? value : "";
            count++;
        }
        return true;
    }
};

// True when a control string fits the 64 KiB cap; an over-long value is logged against the
// calling API and must be dropped by the caller (a C setter returns -1/0, a void listener
// drops the notification).
static bool ControlStringFits(const char* value, const char* api) {
    size_t length = value != nullptr ? strlen(value) : 0;
    if (length <= kMaxControlBytes) {
        return true;
    }
    OH_LOG_WARN(LOG_APP, "[openharmony-host] %{public}s: string argument dropped: %{public}d bytes over the %{public}d cap",
                api, (int)length, (int)kMaxControlBytes);
    return false;
}

// One per registered sink: the threadsafe function bound to the shell callback plus the
// bookkeeping needed to free queued notifications when the sink is replaced.
struct HostSink {
    HostSink(const char* sink_name, bool use_global_this)
        : name(sink_name), global_this(use_global_this) {}

    const char* name = "";
    // The direct calls used the sink itself as `this` in most places and the JS global in
    // the web/picker/vibration/text-input paths; the dispatch keeps that per sink.
    bool global_this = false;
    napi_threadsafe_function tsfn = nullptr;
    bool queue_full_logged = false;
    std::mutex lock;
    std::vector<SinkCall*> pending;
};

// Runs on the JS/UI thread: builds the arguments, calls the shell callback and releases
// the payload. A throwing callback is ignored, exactly like the discarded
// napi_call_function return value used to be.
static void HostSinkDispatch(napi_env env, napi_value js_callback, void* context, void* data) {
    HostSink* sink = static_cast<HostSink*>(context);
    SinkCall* call = static_cast<SinkCall*>(data);
    if (call == nullptr) {
        return;
    }
    if (sink != nullptr) {
        std::lock_guard<std::mutex> guard(sink->lock);
        for (size_t i = 0; i < sink->pending.size(); i++) {
            if (sink->pending[i] == call) {
                sink->pending.erase(sink->pending.begin() + (std::ptrdiff_t)i);
                break;
            }
        }
    }
    if (env != nullptr && js_callback != nullptr) {
        // Every slot is initialized: an argument whose napi creation fails is replaced by
        // undefined instead of being passed uninitialized to the shell callback.
        napi_value argv[SinkCall::kMaxArgs] = {};
        for (int i = 0; i < call->count; i++) {
            napi_status status = napi_generic_failure;
            if (call->args[i].is_string) {
                status = napi_create_string_utf8(env, call->args[i].string_value.c_str(), NAPI_AUTO_LENGTH, &argv[i]);
            } else {
                status = napi_create_int32(env, call->args[i].int_value, &argv[i]);
            }
            if (status != napi_ok || argv[i] == nullptr) {
                argv[i] = nullptr;
                napi_get_undefined(env, &argv[i]);
            }
        }
        napi_value this_arg = js_callback;
        if (sink != nullptr && sink->global_this && napi_get_global(env, &this_arg) != napi_ok) {
            this_arg = js_callback;
        }
        napi_value result = nullptr;
        napi_call_function(env, this_arg, js_callback, (size_t)call->count, argv, &result);
    }
    delete call;
}

// Destroys the sink's threadsafe function and frees anything still queued. Runs on the JS
// thread (Register*Sink), so it cannot overlap a HostSinkDispatch that is executing there;
// aborting drops the pending items without calling the dispatch, hence the explicit free.
static void HostSinkReset(HostSink& sink) {
    std::lock_guard<std::mutex> guard(sink.lock);
    if (sink.tsfn != nullptr) {
        napi_release_threadsafe_function(sink.tsfn, napi_tsfn_abort);
        sink.tsfn = nullptr;
    }
    for (SinkCall* call : sink.pending) {
        delete call;
    }
    sink.pending.clear();
    sink.queue_full_logged = false;
}

// Enqueues one notification. Never blocks: returns false when the call was dropped (no
// sink registered, queue full or the threadsafe function is closing). The payload is
// always consumed, so callers must not touch it afterwards.
static bool HostSinkPost(HostSink& sink, SinkCall* call) {
    if (call == nullptr) {
        return false;
    }
    if (call->overflow) {
        // An argument exceeded its cap (already logged by AddString): never deliver a notification
        // with a missing or partial argument.
        delete call;
        return false;
    }
    bool posted = false;
    {
        std::lock_guard<std::mutex> guard(sink.lock);
        if (sink.tsfn != nullptr) {
            sink.pending.push_back(call);
            napi_status status = napi_call_threadsafe_function(sink.tsfn, call, napi_tsfn_nonblocking);
            if (status == napi_ok) {
                sink.queue_full_logged = false;
                posted = true;
            } else {
                // Not enqueued: our entry is still the last one (the lock keeps the
                // dispatch from mutating `pending` meanwhile).
                sink.pending.pop_back();
                if (status == napi_queue_full && !sink.queue_full_logged) {
                    sink.queue_full_logged = true;
                    OH_LOG_WARN(LOG_APP, "[openharmony-host] %{public}s: callback queue full, dropping notification",
                                sink.name);
                }
            }
        }
    }
    if (!posted) {
        delete call;
    }
    return posted;
}

// Creates (or replaces) the sink's threadsafe function from the ArkTS callback. Runs on
// the JS thread; the previous function, if any, is aborted here and never carries over.
static void HostSinkRegister(napi_env env, HostSink& sink, napi_value function) {
    HostSinkReset(sink);
    napi_value resource_name = nullptr;
    napi_create_string_utf8(env, sink.name, NAPI_AUTO_LENGTH, &resource_name);
    if (resource_name == nullptr) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] %{public}s: could not name the callback queue", sink.name);
        return;
    }
    std::lock_guard<std::mutex> guard(sink.lock);
    napi_status status = napi_create_threadsafe_function(
        env, function, nullptr, resource_name, 64, 1, nullptr, nullptr, &sink,
        HostSinkDispatch, &sink.tsfn);
    if (status != napi_ok) {
        sink.tsfn = nullptr;
        OH_LOG_WARN(LOG_APP, "[openharmony-host] %{public}s: callback queue unavailable (%{public}d)",
                    sink.name, (int)status);
    }
}

HostSink g_text_input_sink("text input", true);

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

HostSink g_keystore_sink("keystore", true);

// Called by the host core (managed side) to run a HUKS operation in the ArkTS shell.
void OnKeystoreRequest(int requestId, const char* op, const char* alias, const char* dataBase64) {
    SinkCall* call = new SinkCall();
    call->AddInt(requestId);
    call->AddString(op);
    call->AddString(alias);
    call->AddString(dataBase64);
    HostSinkPost(g_keystore_sink, call);
}

// ArkTS calls host.registerKeystoreSink(fn) to receive keystore requests.
HostSink g_notification_sink("notification", false);

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
    SinkCall* call = new SinkCall();
    call->AddInt(id);
    call->AddString(title);
    call->AddString(text);
    HostSinkPost(g_notification_sink, call);
}

// ArkTS calls host.registerNotificationSink(fn) to publish notifications.
napi_value RegisterNotificationSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) {
        return nullptr;
    }
    HostSinkRegister(env, g_notification_sink, argv[0]);
    return nullptr;
}

// TextToSpeech: the managed side forwards speak requests through ohos_host_tts_speak; the
// ArkTS shell's sink (registerTtsSink) owns the Speech Kit call and answers with
// host.notifyTtsResult(requestId, code).
HostSink g_tts_sink("tts", false);
static void (*g_tts_result_listener)(int request_id, int code) = nullptr;

// Called from the host C layer (managed P/Invoke): forwards a speak request to ArkTS.
extern "C" int ohos_host_tts_speak(int request_id, const char* text, const char* locale) {
    SinkCall* call = new SinkCall();
    call->AddInt(request_id);
    call->AddString(text);
    call->AddString(locale);
    return HostSinkPost(g_tts_sink, call) ? 0 : -1;
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
            HostSinkRegister(env, g_tts_sink, argv[0]);
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
HostSink g_contacts_sink("contacts", false);
HostSink g_calendar_sink("calendar", false);
static void (*g_contacts_result_listener)(int request_id, int code, const char* payload) = nullptr;
static void (*g_calendar_result_listener)(int request_id, int code, const char* payload) = nullptr;

// Called from managed code (P/Invoke): forwards a name-prefix lookup (limit caps the number of
// returned rows) to the ArkTS sink; returns 0 when it was dispatched.
extern "C" int ohos_host_contacts_query(int request_id, const char* name_prefix, int limit) {
    SinkCall* call = new SinkCall();
    call->AddInt(request_id);
    call->AddString(name_prefix);
    call->AddInt(limit);
    return HostSinkPost(g_contacts_sink, call) ? 0 : -1;
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
            HostSinkRegister(env, g_contacts_sink, argv[0]);
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
    SinkCall* call = new SinkCall();
    call->AddInt(request_id);
    call->AddInt(op);
    call->AddString(arg1);
    call->AddString(arg2);
    call->AddString(arg3);
    return HostSinkPost(g_calendar_sink, call) ? 0 : -1;
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
            HostSinkRegister(env, g_calendar_sink, argv[0]);
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
HostSink g_bluetooth_sink("bluetooth", false);
static void (*g_bluetooth_result_listener)(int request_id, int code, const char* payload) = nullptr;

// Called from managed code (P/Invoke): forwards a Bluetooth operation to the ArkTS sink;
// returns 0 when it was dispatched.
extern "C" int ohos_host_bluetooth_query(int request_id, int op) {
    SinkCall* call = new SinkCall();
    call->AddInt(request_id);
    call->AddInt(op);
    return HostSinkPost(g_bluetooth_sink, call) ? 0 : -1;
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
            HostSinkRegister(env, g_bluetooth_sink, argv[0]);
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

// Discovery pushes each found device (the shell's bluetoothDeviceFind listener) through
// host.notifyBluetoothDeviceFound("name\taddress"). The managed side receives it through the
// callback registered with ohos_host_bluetooth_register_device_found (a separate export, so an
// older host without it still serves the query operations - the managed side only loses push).
static void (*g_bluetooth_device_listener)(const char* payload) = nullptr;

extern "C" void ohos_host_bluetooth_register_device_found(void* callback) {
    g_bluetooth_device_listener = (void (*)(const char*))callback;
}

extern "C" void ohos_host_bluetooth_device_found(const char* payload) {
    if (g_bluetooth_device_listener != nullptr) {
        g_bluetooth_device_listener(payload != nullptr ? payload : "");
    }
}

// ArkTS calls host.notifyBluetoothDeviceFound("name\taddress") for each discovered device.
napi_value NotifyBluetoothDeviceFound(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string payload;
    if (argc >= 1) payload = GetStringArg(env, argv[0]);
    ohos_host_bluetooth_device_found(payload.c_str());
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Bluetooth GATT (platform extra): the managed side forwards one request through
// ohos_host_bluetooth_gatt_request(requestId, op, payload); the ArkTS shell's
// registerBluetoothGattSink handler requests ohos.permission.ACCESS_BLUETOOTH (user_grant),
// lazily imports @kit.ConnectivityKit and runs the GATT client operations on
// ble.createGattClientDevice(address): connect/disconnect/close, getServices,
// readCharacteristicValue/writeCharacteristicValue, readDescriptorValue/writeDescriptorValue,
// setCharacteristicChangeNotification and setBLEMtuSize, with the BLECharacteristicChange/
// BLEConnectionStateChange/BLEMtuChange listeners pushed as device events. Requests and answers
// travel as one operation code plus a tab-separated payload; code 0 is a complete answer, -1
// unavailable, -2 a transient kit failure. The request payload is capped by AddString (a
// missing shell sink or an over-long payload answers -1 without dispatching). The device-event
// push lives on its own export so a host without it still serves the request/response half.
HostSink g_bluetooth_gatt_sink("bluetooth gatt", false);
static void (*g_bluetooth_gatt_result_listener)(int request_id, int code, const char* payload) = nullptr;
static void (*g_bluetooth_gatt_event_listener)(const char* payload) = nullptr;

// Called from managed code (P/Invoke): forwards a GATT operation to the ArkTS sink; returns 0
// when it was dispatched, -1 when there is no sink (or the payload was dropped).
extern "C" int ohos_host_bluetooth_gatt_request(int request_id, int op, const char* payload) {
    SinkCall* call = new SinkCall();
    call->AddInt(request_id);
    call->AddInt(op);
    call->AddString(payload);
    if (!HostSinkPost(g_bluetooth_gatt_sink, call)) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] bluetooth gatt: request dropped (no shell sink or over-long payload)");
        return -1;
    }
    return 0;
}

// The managed side registers the callback that completes a pending GATT request.
extern "C" void ohos_host_bluetooth_gatt_register_result(void* callback) {
    g_bluetooth_gatt_result_listener = (void (*)(int, int, const char*))callback;
}

// Called by the NAPI notify below: hands the shell's answer back to managed code. The listener
// is invoked outside any sink lock (HostSinkPost/HostSinkDispatch never call back under one).
extern "C" void ohos_host_bluetooth_gatt_result(int request_id, int code, const char* payload) {
    if (g_bluetooth_gatt_result_listener != nullptr) {
        g_bluetooth_gatt_result_listener(request_id, code, payload != nullptr ? payload : "");
    }
}

// The managed side registers the callback that receives the unsolicited device events.
extern "C" void ohos_host_bluetooth_gatt_register_event(void* callback) {
    g_bluetooth_gatt_event_listener = (void (*)(const char*))callback;
}

// Called by the NAPI notify below: pushes one device event (value change / connection state /
// MTU) to managed code, NULL-safe.
extern "C" void ohos_host_bluetooth_gatt_event(const char* payload) {
    if (g_bluetooth_gatt_event_listener != nullptr) {
        g_bluetooth_gatt_event_listener(payload != nullptr ? payload : "");
    }
}

// ArkTS calls host.registerBluetoothGattSink(fn) to receive GATT requests.
napi_value RegisterBluetoothGattSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            HostSinkRegister(env, g_bluetooth_gatt_sink, argv[0]);
            OH_LOG_INFO(LOG_APP, "[openharmony-host] bluetooth gatt sink registered");
        } else {
            OH_LOG_WARN(LOG_APP, "[openharmony-host] bluetooth gatt sink: not a function, ignored");
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notifyBluetoothGattResult(requestId, code, payload) when a request finished.
napi_value NotifyBluetoothGattResult(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int requestId = 0;
    int code = -1;
    std::string payload;
    if (argc >= 1) napi_get_value_int32(env, argv[0], &requestId);
    if (argc >= 2) napi_get_value_int32(env, argv[1], &code);
    if (argc >= 3) payload = GetStringArg(env, argv[2]);
    ohos_host_bluetooth_gatt_result(requestId, code, payload.c_str());
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notifyBluetoothGattEvent(payload) for one unsolicited device event.
napi_value NotifyBluetoothGattEvent(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string payload;
    if (argc >= 1) payload = GetStringArg(env, argv[0]);
    ohos_host_bluetooth_gatt_event(payload.c_str());
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Printing (Print Kit): the managed side forwards a file path through ohos_host_print_file;
// the ArkTS shell's registerPrintSink handler calls @ohos.print print.print([path], context)
// (ohos.permission.PRINT is system_grant, so the shell does not prompt) and answers through
// host.notifyPrintResult with code 0 when the system print UI accepted the job and -1 when
// the framework rejected it. The message carries the framework error for the host log.
HostSink g_print_sink("print", false);
static void (*g_print_result_listener)(int request_id, int code, const char* message) = nullptr;

// Called from managed code (P/Invoke): forwards a print file path to the ArkTS sink.
extern "C" int ohos_host_print_file(int request_id, const char* path) {
    SinkCall* call = new SinkCall();
    call->AddInt(request_id);
    call->AddString(path);
    return HostSinkPost(g_print_sink, call) ? 0 : -1;
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
            HostSinkRegister(env, g_print_sink, argv[0]);
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
// 2 = availability probe, answered by the shell without launching anything,
// 3 = share file (implicit sendData Want; text carries the MIME type),
// 4 = explicit Want (IAppInfo.ShowSettingsUI): uri carries the bundle name and text the ability
// name; the shell tries that Want first and falls back to the implicit 'ohos.settings' action
// when the explicit form does not resolve (a device whose settings bundle differs).
//
// This is the one sink that deliberately stays on a direct napi_call_function: the managed side
// consumes the shell's boolean answer (Launcher.CanOpenAsync / TryOpenAsync return it), and a
// napi_threadsafe_function only reports "queued", not "handled". Moving it to the TSFN would
// silently report every request as dispatched. The call is synchronous with the .NET thread and
// the shell-side deferral covers the JS/UI-thread hop.
napi_ref g_ability_sink_ref = nullptr;

// Flags for ohos_host_ability_start_ex: bit 0 is FLAG_AUTH_READ_URI_PERMISSION (the shell asks
// the ability manager to grant the receiver read access to a file:// uri); the host forwards
// the bits as-is.
//
// Direct-call implementation shared by the three- and five-argument exports (the fifth is the
// optional title; NULL/"" keeps the previous shape, and the shell only adds
// wantConstant.Params.CONTENT_TITLE_KEY for a non-empty title).
static int AbilityStartInternal(int kind, const char* uri, const char* text, const char* title, int flags) {
    if (g_env == nullptr || g_ability_sink_ref == nullptr) {
        return -1;
    }
    if (title != nullptr && !ControlStringFits(title, "ability_start_title")) {
        return -1;
    }
    napi_value sink = nullptr;
    if (napi_get_reference_value(g_env, g_ability_sink_ref, &sink) != napi_ok || sink == nullptr) {
        return -1;
    }
    napi_value argv[5];
    napi_create_int32(g_env, kind, &argv[0]);
    napi_create_string_utf8(g_env, uri != nullptr ? uri : "", NAPI_AUTO_LENGTH, &argv[1]);
    napi_create_string_utf8(g_env, text != nullptr ? text : "", NAPI_AUTO_LENGTH, &argv[2]);
    napi_create_string_utf8(g_env, title != nullptr ? title : "", NAPI_AUTO_LENGTH, &argv[3]);
    napi_create_int32(g_env, flags, &argv[4]);
    napi_value result = nullptr;
    if (napi_call_function(g_env, sink, sink, 5, argv, &result) != napi_ok) {
        return -1;
    }
    bool handled = false;
    if (result == nullptr || napi_get_value_bool(g_env, result, &handled) != napi_ok || !handled) {
        return -1;
    }
    return 0;
}

// Called from managed code (P/Invoke): forwards an ability-start request to the ArkTS shell and
// returns 0 when the sink handled it (dispatched or, for the probe, available). The
// three-argument form stays for a managed side/host library pair that predates the title and
// flag arguments; it is exactly the five-argument form with title NULL and flags 0.
extern "C" int ohos_host_ability_start(int kind, const char* uri, const char* text) {
    return AbilityStartInternal(kind, uri, text, nullptr, 0);
}

// Called from managed code (P/Invoke): like ohos_host_ability_start with the optional content
// title (wantConstant.Params.CONTENT_TITLE_KEY, 'ohos.extra.param.key.contentTitle') and Want
// flags (bit 0 = FLAG_AUTH_READ_URI_PERMISSION). Additive export: the three-argument form above
// keeps its ABI and behaviour, and a shell sink that ignores the extra arguments still handles
// the request (the sink signature grew, not the protocol).
extern "C" int ohos_host_ability_start_ex(int kind, const char* uri, const char* text, const char* title, int flags) {
    return AbilityStartInternal(kind, uri, text, title, flags);
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

// Flashlight (Camera Kit torch): the managed side calls ohos_host_flashlight_set(on) and
// receives the ArkTS shell's boolean answer. on 0 = torch off, 1 = torch on, 2 = support
// probe (isTorchSupported only, no torch call). The shell's registerFlashlightSink handler
// creates/caches the camera manager (camera.getCameraManager), checks isTorchSupported and
// calls setTorchMode(camera.TorchMode.ON/OFF); setTorchMode is synchronous and throws on
// failure, so the callback answers whether the kit accepted the request.
//
// Like the ability sink above, this one deliberately stays on a direct napi_call_function:
// the managed side consumes the boolean answer (IFlashlight.IsSupportedAsync and the
// turn-on/off result) and a napi_threadsafe_function only reports "queued", not "handled".
// The shell callback answers synchronously and catches its own errors, so there is nothing
// to await; a missing sink or a non-boolean answer is reported as "not handled".
napi_ref g_flashlight_sink_ref = nullptr;

// Called from managed code (P/Invoke): asks the ArkTS shell to set or probe the torch.
// Returns 0 when the sink answered true, -1 when no sink is registered, the call failed or
// the answer was false.
extern "C" int ohos_host_flashlight_set(int on) {
    if (g_env == nullptr || g_flashlight_sink_ref == nullptr) {
        return -1;
    }
    napi_value sink = nullptr;
    if (napi_get_reference_value(g_env, g_flashlight_sink_ref, &sink) != napi_ok || sink == nullptr) {
        return -1;
    }
    napi_value argv[1];
    napi_create_int32(g_env, on, &argv[0]);
    napi_value result = nullptr;
    if (napi_call_function(g_env, sink, sink, 1, argv, &result) != napi_ok) {
        return -1;
    }
    bool handled = false;
    if (result == nullptr || napi_get_value_bool(g_env, result, &handled) != napi_ok || !handled) {
        return -1;
    }
    return 0;
}

// ArkTS calls host.registerFlashlightSink(fn) to receive torch set/probe requests.
napi_value RegisterFlashlightSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            if (g_flashlight_sink_ref != nullptr) {
                napi_delete_reference(env, g_flashlight_sink_ref);
            }
            napi_create_reference(env, argv[0], 1, &g_flashlight_sink_ref);
            OH_LOG_INFO(LOG_APP, "[openharmony-host] flashlight sink registered");
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Focus: the managed side (VisualElement.Focus()/Unfocus() on the text handlers) asks the
// ArkTS shell to hand ArkUI focus to a target id through ohos_host_request_focus; the shell's
// registerFocusSink handler calls focusControl.requestFocus(id) and answers whether it did.
// Same direct napi_call_function shape as the ability/flashlight sinks: the managed side
// consumes the boolean answer (a queued TSFN call cannot report "handled"). The target id is a
// control string: a NULL/empty/over-cap id is rejected before the call.
napi_ref g_focus_sink_ref = nullptr;

extern "C" int ohos_host_request_focus(const char* target_id) {
    if (g_env == nullptr || g_focus_sink_ref == nullptr) {
        return -1;
    }
    if (target_id == nullptr || target_id[0] == '\0' || !ControlStringFits(target_id, "request_focus")) {
        return -1;
    }
    napi_value sink = nullptr;
    if (napi_get_reference_value(g_env, g_focus_sink_ref, &sink) != napi_ok || sink == nullptr) {
        return -1;
    }
    napi_value argv[1];
    napi_create_string_utf8(g_env, target_id, NAPI_AUTO_LENGTH, &argv[0]);
    napi_value result = nullptr;
    if (napi_call_function(g_env, sink, sink, 1, argv, &result) != napi_ok) {
        return -1;
    }
    bool handled = false;
    if (result == nullptr || napi_get_value_bool(g_env, result, &handled) != napi_ok || !handled) {
        return -1;
    }
    return 0;
}

// ArkTS calls host.registerFocusSink(fn) to receive focus requests.
napi_value RegisterFocusSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            if (g_focus_sink_ref != nullptr) {
                napi_delete_reference(env, g_focus_sink_ref);
            }
            napi_create_reference(env, argv[0], 1, &g_focus_sink_ref);
            OH_LOG_INFO(LOG_APP, "[openharmony-host] focus sink registered");
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
HostSink g_menu_changed_sink("menu", false);
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

// Asks the shell to rebuild its menu state from the table just committed. The item count is
// captured here (the table may be rebuilt before the JS thread drains the queue).
static void NotifyMenuChanged() {
    SinkCall* call = new SinkCall();
    call->AddInt((int32_t)g_menu_items.size());
    HostSinkPost(g_menu_changed_sink, call);
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
            HostSinkRegister(env, g_menu_changed_sink, argv[0]);
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

HostSink g_picker_sink("picker", true);
HostSink g_web_sink("web", true);

void OnPickerRequest(int requestId, int kind) {
    SinkCall* call = new SinkCall();
    call->AddInt(requestId);
    call->AddInt(kind);
    HostSinkPost(g_picker_sink, call);
}

void OnWebCommand(const char* op, const char* arg) {
    SinkCall* call = new SinkCall();
    call->AddString(op);
    call->AddString(arg);
    HostSinkPost(g_web_sink, call);
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
            HostSinkRegister(env, g_web_sink, argv[0]);
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

// ArkTS calls host.notifySoftInputArea(bottom) from the window's avoidAreaChange observer for
// the keyboard (AvoidAreaType.TYPE_KEYBOARD); the host stores the height for the managed
// safe-area model (SafeAreaEdges.SoftInput/All). The system avoid area keeps its own slot.
napi_value NotifySoftInputArea(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t bottom = 0;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &bottom);
    }
    ohos_host_set_soft_input_area(bottom);
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

// Battery (Basic Services Kit): the ArkTS shell reports the batteryInfo snapshot through
// host.notifyBattery("soc\tchargeState\tpluggedType\tpresent\tpowerMode") at page start and on
// the battery/charging/power-save common events. The last payload is remembered and replayed
// when the managed listener registers through ohos_host_battery_set_listener, so the managed
// Battery properties have the current values regardless of which side starts first.
static void (*g_battery_listener)(const char* payload) = nullptr;
static std::string g_battery_payload;

extern "C" void ohos_host_battery_set_listener(void* callback) {
    g_battery_listener = (void (*)(const char*))callback;
    if (g_battery_listener != nullptr && !g_battery_payload.empty()) {
        g_battery_listener(g_battery_payload.c_str());
    }
}

napi_value NotifyBattery(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string payload;
    if (argc >= 1) payload = GetStringArg(env, argv[0]);
    g_battery_payload = payload;
    if (g_battery_listener != nullptr) {
        g_battery_listener(payload.c_str());
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Display: same push shape for DeviceDisplay, through
// host.notifyDisplay("width\theight\tdensityDPI\trotation\trefreshRate\torientation") at page
// start and on display.on('change'); the last payload is replayed on listener registration.
static void (*g_display_listener)(const char* payload) = nullptr;
static std::string g_display_payload;

extern "C" void ohos_host_display_set_listener(void* callback) {
    g_display_listener = (void (*)(const char*))callback;
    if (g_display_listener != nullptr && !g_display_payload.empty()) {
        g_display_listener(g_display_payload.c_str());
    }
}

napi_value NotifyDisplay(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string payload;
    if (argc >= 1) payload = GetStringArg(env, argv[0]);
    g_display_payload = payload;
    if (g_display_listener != nullptr) {
        g_display_listener(payload.c_str());
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Keep screen on (Basic Services Kit window manager): the managed DeviceDisplay.KeepScreenOn
// setter calls ohos_host_keep_screen_on(on) (0 = release, 1 = keep on, other values pass
// through). The ArkTS shell's registerKeepScreenOnSink handler resolves the last window
// (window.getLastWindow) and applies setWindowKeepScreenOn, which is asynchronous, so this is
// one-way: the managed getter reflects the last value the host accepted (post succeeded),
// and no answer travels back. A missing sink, no window or a rejected call degrades silently.
HostSink g_keep_screen_on_sink("keep screen on", false);

// Called from managed code (P/Invoke): returns 0 when the request was queued for the shell.
extern "C" int ohos_host_keep_screen_on(int on) {
    SinkCall* call = new SinkCall();
    call->AddInt(on);
    return HostSinkPost(g_keep_screen_on_sink, call) ? 0 : -1;
}

// ArkTS calls host.registerKeepScreenOnSink(fn) to receive keep-screen-on changes.
napi_value RegisterKeepScreenOnSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            HostSinkRegister(env, g_keep_screen_on_sink, argv[0]);
            OH_LOG_INFO(LOG_APP, "[openharmony-host] keep screen on sink registered");
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ---------------------------------------------------------------------------
// Window chrome: the managed window handler calls ohos_host_set_window_title /
// ohos_host_set_window_rect (P/Invoke); the ArkTS shell's registerWindowTitleSink /
// registerWindowRectSink handlers apply them to the main window (window.setWindowTitle,
// SessionManager API 15+; window.moveWindowTo + window.resize, API 11+). One-way like
// keep-screen-on: the return value only reports whether the request was queued for the shell.
// ---------------------------------------------------------------------------
HostSink g_window_title_sink("window title", false);
HostSink g_window_rect_sink("window rect", false);

// Called from managed code (P/Invoke): returns 0 when the title was queued for the shell.
extern "C" int ohos_host_set_window_title(const char* utf8) {
    if (utf8 == nullptr || utf8[0] == '\0') {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] set_window_title: empty title");
        return -1;
    }
    if (!ControlStringFits(utf8, "set_window_title")) {
        return -1;
    }
    SinkCall* call = new SinkCall();
    call->AddString(utf8, kMaxControlBytes);
    if (!HostSinkPost(g_window_title_sink, call)) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] set_window_title: no shell window title sink");
        return -1;
    }
    return 0;
}

// Documented window-rect bounds: the shell applies the values to the main window with
// moveWindowTo + resize and the managed side is not trusted to keep them sane. Width/height
// are clamped into (0, 16384] and x/y into [-32768, 32768] before the request is queued.
constexpr int kMaxWindowDimension = 16384;
constexpr int kMaxWindowOffset = 32768;

// Called from managed code (P/Invoke): returns 0 when the rectangle was queued for the shell.
extern "C" int ohos_host_set_window_rect(int x, int y, int w, int h) {
    if (w <= 0 || h <= 0) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] set_window_rect: invalid size %{public}dx%{public}d", w, h);
        return -1;
    }
    if (w > kMaxWindowDimension) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] set_window_rect: width clamped from %{public}d", w);
        w = kMaxWindowDimension;
    }
    if (h > kMaxWindowDimension) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] set_window_rect: height clamped from %{public}d", h);
        h = kMaxWindowDimension;
    }
    if (x > kMaxWindowOffset) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] set_window_rect: x clamped from %{public}d", x);
        x = kMaxWindowOffset;
    } else if (x < -kMaxWindowOffset) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] set_window_rect: x clamped from %{public}d", x);
        x = -kMaxWindowOffset;
    }
    if (y > kMaxWindowOffset) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] set_window_rect: y clamped from %{public}d", y);
        y = kMaxWindowOffset;
    } else if (y < -kMaxWindowOffset) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] set_window_rect: y clamped from %{public}d", y);
        y = -kMaxWindowOffset;
    }
    SinkCall* call = new SinkCall();
    call->AddInt(x);
    call->AddInt(y);
    call->AddInt(w);
    call->AddInt(h);
    if (!HostSinkPost(g_window_rect_sink, call)) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] set_window_rect: no shell window rect sink");
        return -1;
    }
    return 0;
}

// ArkTS calls host.registerWindowTitleSink(fn) to receive window title changes.
napi_value RegisterWindowTitleSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            HostSinkRegister(env, g_window_title_sink, argv[0]);
            OH_LOG_INFO(LOG_APP, "[openharmony-host] window title sink registered");
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.registerWindowRectSink(fn) to receive window rectangle changes.
napi_value RegisterWindowRectSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            HostSinkRegister(env, g_window_rect_sink, argv[0]);
            OH_LOG_INFO(LOG_APP, "[openharmony-host] window rect sink registered");
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ---------------------------------------------------------------------------
// Screenshot: the managed side asks the ArkTS shell to snapshot the main window and write a
// PNG to an app-owned path (window.snapshot + image.createImagePacker). One-way: the shell
// logs a failed write itself and the managed caller reads the file when it is ready.
// ---------------------------------------------------------------------------
HostSink g_screenshot_sink("screenshot", false);

// Called from managed code (P/Invoke): returns 0 when the request was queued for the shell.
extern "C" int ohos_host_screenshot(const char* out_path) {
    if (out_path == nullptr || out_path[0] == '\0') {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] screenshot: empty output path");
        return -1;
    }
    // Filesystem-path cap (well below PATH_MAX; the shell re-validates containment). A path
    // longer than this is a malformed request, not a payload to carry.
    if (strlen(out_path) > kMaxScreenshotPathBytes) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] screenshot: output path dropped: %{public}d bytes over the %{public}d cap",
                    (int)strlen(out_path), (int)kMaxScreenshotPathBytes);
        return -1;
    }
    SinkCall* call = new SinkCall();
    call->AddString(out_path, kMaxScreenshotPathBytes);
    if (!HostSinkPost(g_screenshot_sink, call)) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] screenshot: no shell screenshot sink");
        return -1;
    }
    return 0;
}

// ArkTS calls host.registerScreenshotSink(fn) to receive screenshot requests.
napi_value RegisterScreenshotSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            HostSinkRegister(env, g_screenshot_sink, argv[0]);
            OH_LOG_INFO(LOG_APP, "[openharmony-host] screenshot sink registered");
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ---------------------------------------------------------------------------
// Shell search: the managed SearchHandler state (query, placeholder, visible, enabled) goes
// out through ohos_host_shell_search_set; the sink registered by
// host.registerShellSearchChangedSink applies it to the shell's search field. The shell
// reports interactions back through host.notifyShellSearch -> the managed listener registered
// by ohos_host_shell_search_set_listener (op 0 query changed, 1 submit, 2 cancel).
// ---------------------------------------------------------------------------
HostSink g_shell_search_sink("shell search", false);
std::mutex g_shell_search_lock;
std::string g_shell_search_query;
std::string g_shell_search_placeholder;
int g_shell_search_visible = 0;
int g_shell_search_enabled = 0;

// Called from managed code (P/Invoke): publishes the state and returns 0 when it reached the
// shell sink. The stored copy backs the host.shellSearch* getters the shell reads on startup.
extern "C" int ohos_host_shell_search_set(const char* query, const char* placeholder,
                                          int visible, int enabled) {
    if (!ControlStringFits(query, "shell_search_set") || !ControlStringFits(placeholder, "shell_search_set")) {
        return -1;
    }
    SinkCall* call = new SinkCall();
    {
        std::lock_guard<std::mutex> guard(g_shell_search_lock);
        g_shell_search_query = query != nullptr ? query : "";
        g_shell_search_placeholder = placeholder != nullptr ? placeholder : "";
        g_shell_search_visible = visible != 0 ? 1 : 0;
        g_shell_search_enabled = enabled != 0 ? 1 : 0;
        call->AddString(g_shell_search_query.c_str(), kMaxControlBytes);
        call->AddString(g_shell_search_placeholder.c_str(), kMaxControlBytes);
        call->AddInt(g_shell_search_visible);
        call->AddInt(g_shell_search_enabled);
    }
    if (!HostSinkPost(g_shell_search_sink, call)) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] shell_search_set: no shell search sink");
        return -1;
    }
    return 0;
}

// ArkTS calls host.registerShellSearchChangedSink(fn) to receive the managed search state.
napi_value RegisterShellSearchChangedSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            HostSinkRegister(env, g_shell_search_sink, argv[0]);
            OH_LOG_INFO(LOG_APP, "[openharmony-host] shell search sink registered");
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Current search state for the shell (host.shellSearchQuery()/shellSearchPlaceholder()/
// shellSearchVisible()/shellSearchEnabled()); empty/false before the first publish.
static napi_value CreateUtf8String(napi_env env, const std::string& value) {
    napi_value result = nullptr;
    napi_create_string_utf8(env, value.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value ShellSearchQuery(napi_env env, napi_callback_info info) {
    (void)info;
    std::string value;
    {
        std::lock_guard<std::mutex> guard(g_shell_search_lock);
        value = g_shell_search_query;
    }
    return CreateUtf8String(env, value);
}

napi_value ShellSearchPlaceholder(napi_env env, napi_callback_info info) {
    (void)info;
    std::string value;
    {
        std::lock_guard<std::mutex> guard(g_shell_search_lock);
        value = g_shell_search_placeholder;
    }
    return CreateUtf8String(env, value);
}

napi_value ShellSearchVisible(napi_env env, napi_callback_info info) {
    (void)info;
    int value = 0;
    {
        std::lock_guard<std::mutex> guard(g_shell_search_lock);
        value = g_shell_search_visible;
    }
    napi_value result = nullptr;
    napi_create_int32(env, value, &result);
    return result;
}

napi_value ShellSearchEnabled(napi_env env, napi_callback_info info) {
    (void)info;
    int value = 0;
    {
        std::lock_guard<std::mutex> guard(g_shell_search_lock);
        value = g_shell_search_enabled;
    }
    napi_value result = nullptr;
    napi_create_int32(env, value, &result);
    return result;
}

// ArkTS calls host.notifyShellSearch(op, text) when the shell search field changed/submitted/
// was cancelled; the managed listener registered through ohos_host_shell_search_set_listener
// receives it.
napi_value NotifyShellSearch(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t op = 0;
    std::string text;
    if (argc >= 1) napi_get_value_int32(env, argv[0], &op);
    if (argc >= 2) text = GetStringArg(env, argv[1]);
    ohos_host_shell_search_notify(op, text.c_str());
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ---------------------------------------------------------------------------
// Shell flyout: the managed Shell publishes the header/footer text of its flyout sections
// through ohos_host_shell_flyout_header/footer; the sink registered by
// host.registerShellFlyoutChangedSink applies it to the shell panel labels (op 0 header,
// 1 footer, empty text clears). The stored copies back host.shellFlyoutHeader()/Footer().
// ---------------------------------------------------------------------------
HostSink g_shell_flyout_sink("shell flyout", false);
std::mutex g_shell_flyout_lock;
std::string g_shell_flyout_header;
std::string g_shell_flyout_footer;

static int ShellFlyoutPublish(int op, const char* text) {
    if (!ControlStringFits(text, op == 0 ? "shell_flyout_header" : "shell_flyout_footer")) {
        return -1;
    }
    SinkCall* call = new SinkCall();
    call->AddInt(op);
    {
        std::lock_guard<std::mutex> guard(g_shell_flyout_lock);
        std::string& slot = op == 0 ? g_shell_flyout_header : g_shell_flyout_footer;
        slot = text != nullptr ? text : "";
        call->AddString(slot.c_str(), kMaxControlBytes);
    }
    if (!HostSinkPost(g_shell_flyout_sink, call)) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] shell_flyout_%{public}s: no shell flyout sink",
                    op == 0 ? "header" : "footer");
        return -1;
    }
    return 0;
}

// Called from managed code (P/Invoke): returns 0 when the text was queued for the shell.
extern "C" int ohos_host_shell_flyout_header(const char* text) {
    return ShellFlyoutPublish(0, text);
}

// Called from managed code (P/Invoke): returns 0 when the text was queued for the shell.
extern "C" int ohos_host_shell_flyout_footer(const char* text) {
    return ShellFlyoutPublish(1, text);
}

// ArkTS calls host.registerShellFlyoutChangedSink(fn) to receive the flyout section text.
napi_value RegisterShellFlyoutChangedSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            HostSinkRegister(env, g_shell_flyout_sink, argv[0]);
            OH_LOG_INFO(LOG_APP, "[openharmony-host] shell flyout sink registered");
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Current flyout header/footer for the shell (host.shellFlyoutHeader()/shellFlyoutFooter()).
napi_value ShellFlyoutHeader(napi_env env, napi_callback_info info) {
    (void)info;
    std::string value;
    {
        std::lock_guard<std::mutex> guard(g_shell_flyout_lock);
        value = g_shell_flyout_header;
    }
    return CreateUtf8String(env, value);
}

napi_value ShellFlyoutFooter(napi_env env, napi_callback_info info) {
    (void)info;
    std::string value;
    {
        std::lock_guard<std::mutex> guard(g_shell_flyout_lock);
        value = g_shell_flyout_footer;
    }
    return CreateUtf8String(env, value);
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
HostSink g_web_eval_sink("web eval", false);
static void (*g_web_eval_result_listener)(int request_id, const char* result, int error) = nullptr;
static void (*g_web_js_message_listener)(const char* payload) = nullptr;

// Called from managed code (P/Invoke): forwards a script evaluation request to the ArkTS sink.
extern "C" int ohos_host_web_eval(const char* script, int request_id) {
    SinkCall* call = new SinkCall();
    call->AddString(script);
    call->AddInt(request_id);
    return HostSinkPost(g_web_eval_sink, call) ? 0 : -1;
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
            HostSinkRegister(env, g_web_eval_sink, argv[0]);
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

// HybridWebView JS -> .NET invocation bridge: the ArkTS shell intercepts the
// __hwvInvokeDotNet request, calls host.notifyHybridInvoke(requestId, method, argsJson) and
// keeps the intercepted WebResourceResponse open (setResponseIsReady(false)); the managed
// HybridWebView handler answers through ohos_host_hwv_invoke_result(requestId, payloadJson),
// which hands the result to the shell's registerHybridInvokeResultSink callback so the
// response can be completed.
HostSink g_hybrid_invoke_result_sink("hybrid invoke result", false);
static void (*g_hybrid_invoke_listener)(int request_id, const char* method, const char* args_json) = nullptr;

// The managed side registers the callback that services a JS invocation (P/Invoke).
extern "C" void ohos_host_hwv_register_invoke(void* callback) {
    g_hybrid_invoke_listener = (void (*)(int, const char*, const char*))callback;
}

// ArkTS calls host.notifyHybridInvoke(requestId, method, argsJson). Returns 0 when the
// invocation reached the managed listener and -1 otherwise; the shell answers a -1 with an
// error payload instead of leaving the fetch open.
napi_value NotifyHybridInvoke(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int requestId = 0;
    if (argc >= 1) napi_get_value_int32(env, argv[0], &requestId);
    std::string method;
    std::string args;
    if (argc >= 2) method = GetStringArg(env, argv[1]);
    if (argc >= 3) args = GetStringArg(env, argv[2]);
    int rc = -1;
    if (g_hybrid_invoke_listener != nullptr && !method.empty()) {
        g_hybrid_invoke_listener(requestId, method.c_str(), args.c_str());
        rc = 0;
    }
    napi_value result = nullptr;
    napi_create_int32(env, rc, &result);
    return result;
}

// ArkTS calls host.registerHybridInvokeResultSink(fn) to receive invocation results.
napi_value RegisterHybridInvokeResultSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            HostSinkRegister(env, g_hybrid_invoke_result_sink, argv[0]);
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Called from managed code (P/Invoke) with the invocation result. Returns 0 when the result
// reached the ArkTS sink, -1 when there is no result sink registered.
extern "C" int ohos_host_hwv_invoke_result(int request_id, const char* payload_json) {
    SinkCall* call = new SinkCall();
    call->AddInt(request_id);
    call->AddString(payload_json);
    return HostSinkPost(g_hybrid_invoke_result_sink, call) ? 0 : -1;
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
            HostSinkRegister(env, g_picker_sink, argv[0]);
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

// Raw HAP resources (resources/rawfile/**): the managed side forwards a request through
// ohos_host_raw_file_request; the ArkTS shell's registerRawFileSink handler lazily imports
// @ohos.resourceManager, reads the named relative path (op 0, base64 answer) or probes it
// (op 1, no content read) and answers through host.notifyRawFileResult. See openharmony_host.h
// for the rc values. One read is capped at OHOS_HOST_RAW_FILE_MAX_BYTES: the shell refuses a
// bigger file with rc -3 before encoding it, and NotifyRawFileResult refuses an over-long
// base64 argument the same way, so neither side can be made to allocate past the base64 form
// of the cap. The content travels as one base64 string - no temp files or shared paths cross
// the bridge, hence no cleanup or name-collision race.
HostSink g_raw_file_sink("raw file", false);

// ceil(bytes / 3) * 4, computed without overflowing.
constexpr size_t kMaxRawFileBase64Bytes =
    ((static_cast<size_t>(OHOS_HOST_RAW_FILE_MAX_BYTES) + 2) / 3) * 4;

// Called by the host core (managed side) to ask the shell for one raw resource.
void OnRawFileRequest(int requestId, int op, const char* name) {
    if (!ControlStringFits(name, "raw_file")) {
        // The name was refused before it could reach the shell; answer the pending managed
        // request right away (never leave it to its timeout).
        ohos_host_raw_file_result(requestId, OHOS_RAW_FILE_UNAVAILABLE, "");
        return;
    }
    SinkCall* call = new SinkCall();
    call->AddInt(requestId);
    call->AddInt(op);
    call->AddString(name, kMaxControlBytes);
    if (!HostSinkPost(g_raw_file_sink, call)) {
        // No shell sink (older shell or no page yet): answer immediately and log once.
        static bool unavailableLogged = false;
        if (!unavailableLogged) {
            unavailableLogged = true;
            OH_LOG_WARN(LOG_APP, "[openharmony-host] raw file: no shell sink; requests answer unavailable");
        }
        ohos_host_raw_file_result(requestId, OHOS_RAW_FILE_UNAVAILABLE, "");
    }
}

// ArkTS calls host.registerRawFileSink(fn) to receive raw-resource requests.
napi_value RegisterRawFileSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            HostSinkRegister(env, g_raw_file_sink, argv[0]);
            ohos_host_raw_file_set_listener(OnRawFileRequest);
            OH_LOG_INFO(LOG_APP, "[openharmony-host] raw file sink registered");
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notifyRawFileResult(requestId, rc, dataBase64) when the read/probe finished.
// The base64 argument uses its own cap instead of the 1 MiB GetStringArg result cap; a larger
// argument is not copied and a "success" carrying one is reported as TOO_LARGE.
napi_value NotifyRawFileResult(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int requestId = 0;
    int rc = OHOS_RAW_FILE_UNAVAILABLE;
    std::string data;
    if (argc >= 1) napi_get_value_int32(env, argv[0], &requestId);
    if (argc >= 2) napi_get_value_int32(env, argv[1], &rc);
    if (argc >= 3) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[2], &type);
        if (type == napi_string) {
            size_t length = 0;
            if (napi_get_value_string_utf8(env, argv[2], nullptr, 0, &length) != napi_ok ||
                length > kMaxRawFileBase64Bytes) {
                if (rc == OHOS_RAW_FILE_OK) {
                    rc = OHOS_RAW_FILE_TOO_LARGE;
                }
                OH_LOG_WARN(LOG_APP, "[openharmony-host] raw file: payload dropped: %{public}d base64 bytes over the %{public}d cap",
                            (int)length, (int)kMaxRawFileBase64Bytes);
            } else {
                data.resize(length);
                napi_get_value_string_utf8(env, argv[2], data.data(), length + 1, &length);
            }
        }
    }
    ohos_host_raw_file_result(requestId, rc, data.c_str());
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Runtime permissions: the managed side asks through ohos_host_request_permission; the sink's
// handler runs abilityAccessCtrl.requestPermissionsFromUser and answers with
// host.permissionResult(requestId, granted). Argument order matches the C listener
// (permission first, request id second).
HostSink g_permission_sink("permission", false);

void OnPermissionRequest(const char* permission, int requestId) {
    if (!ControlStringFits(permission, "permission")) {
        return;
    }
    SinkCall* call = new SinkCall();
    call->AddString(permission, kMaxControlBytes);
    call->AddInt(requestId);
    HostSinkPost(g_permission_sink, call);
}

// ArkTS calls host.registerPermissionSink(fn) to receive permission requests.
napi_value RegisterPermissionSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            HostSinkRegister(env, g_permission_sink, argv[0]);
            ohos_host_permission_set_listener(OnPermissionRequest);
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.permissionResult(requestId, granted) when the prompt was answered.
napi_value NotifyPermissionResult(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t requestId = 0;
    int32_t granted = 0;
    if (argc >= 1) napi_get_value_int32(env, argv[0], &requestId);
    if (argc >= 2) napi_get_value_int32(env, argv[1], &granted);
    ohos_host_permission_complete(requestId, granted);
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Notification enablement (Essentials Permissions.PostNotifications): the managed side asks
// through ohos_host_notification_permission_request(op, requestId); the sink's handler runs
// notificationManager.isNotificationEnabledSync (op 0) or requestEnableNotification (op 1) and
// answers with host.notificationPermissionResult(requestId, granted). Argument order matches
// the C listener (op first, request id second).
HostSink g_notification_permission_sink("notification permission", false);

void OnNotificationPermissionRequest(int op, int requestId) {
    SinkCall* call = new SinkCall();
    call->AddInt(op);
    call->AddInt(requestId);
    HostSinkPost(g_notification_permission_sink, call);
}

// ArkTS calls host.registerNotificationPermissionSink(fn) to receive enablement requests.
napi_value RegisterNotificationPermissionSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            HostSinkRegister(env, g_notification_permission_sink, argv[0]);
            ohos_host_notification_permission_set_listener(OnNotificationPermissionRequest);
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notificationPermissionResult(requestId, granted) when the shell answered.
napi_value NotifyNotificationPermissionResult(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t requestId = 0;
    int32_t granted = 0;
    if (argc >= 1) napi_get_value_int32(env, argv[0], &requestId);
    if (argc >= 2) napi_get_value_int32(env, argv[1], &granted);
    ohos_host_notification_permission_complete(requestId, granted);
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Clipboard: the managed side sends (requestId, op, text) through ohos_host_clipboard_request;
// the sink's handler runs the @ohos.pasteboard call and answers with
// host.clipboardResult(requestId, rc, text). The pasteboard 'update' observer pushes
// host.notifyClipboardChanged() through the no-argument notify below.
HostSink g_clipboard_sink("clipboard", false);

void OnClipboardRequest(int requestId, int op, const char* text) {
    if (!ControlStringFits(text, "clipboard")) {
        return;
    }
    SinkCall* call = new SinkCall();
    call->AddInt(requestId);
    call->AddInt(op);
    call->AddString(text, kMaxControlBytes);
    HostSinkPost(g_clipboard_sink, call);
}

// ArkTS calls host.registerClipboardSink(fn) to receive clipboard operations.
napi_value RegisterClipboardSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            HostSinkRegister(env, g_clipboard_sink, argv[0]);
            ohos_host_clipboard_set_listener(OnClipboardRequest);
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.clipboardResult(requestId, rc, text) with the pasteboard answer.
napi_value NotifyClipboardResult(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t requestId = 0;
    int32_t rc = -1;
    std::string text;
    if (argc >= 1) napi_get_value_int32(env, argv[0], &requestId);
    if (argc >= 2) napi_get_value_int32(env, argv[1], &rc);
    if (argc >= 3) text = GetStringArg(env, argv[2]);
    ohos_host_clipboard_complete(requestId, rc, text.c_str());
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notifyClipboardChanged() from the pasteboard 'update' observer.
napi_value NotifyClipboardChanged(napi_env env, napi_callback_info info) {
    (void)env;
    (void)info;
    ohos_host_clipboard_notify_changed();
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.notifyNetworkAccess() (bare, from netAvailable/netLost/netUnavailable) or
// host.notifyNetworkAccess(encoded) (from netCapabilitiesChange, encoded =
// NetCapabilityInfo.netCap.bearerTypes) after a NetworkKit connection event; the host parses the
// capability payload when present, re-reads the level through the same NDK path as the
// ohos_host_network_access getter and forwards both to the managed listener (the level through
// the callback, the bearer mask through ohos_host_network_capabilities).
napi_value NotifyNetworkAccess(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_string) {
            std::string encoded = GetStringArg(env, argv[0]);
            if (encoded.size() > kMaxNetworkCapabilityBytes) {
                // Same cap rule as the bridge strings: an over-long value is dropped whole
                // (never parsed partially) instead of misreporting the transports.
                OH_LOG_WARN(LOG_APP, "[openharmony-host] network capability payload dropped: %{public}d bytes over the %{public}d cap",
                            (int)encoded.size(), (int)kMaxNetworkCapabilityBytes);
            } else {
                ohos_host_set_network_capabilities(encoded.c_str());
            }
        }
    }
    ohos_host_network_access_notify();
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.keyEvent(keyCode, eventType) from the page's onKeyEvent; eventType is the
// ArkUI KeyType encoding (0 = down, 1 = up). The host forwards both to the managed callback
// registered with ohos_host_register_key_event. The call is best effort: a shell with the
// handler but a host library without the export logs the standard missing-export warning on the
// Shell side (hostCall).
napi_value KeyEvent(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t keyCode = 0;
    int32_t eventType = 0;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &keyCode);
    }
    if (argc >= 2) {
        napi_get_value_int32(env, argv[1], &eventType);
    }
    ohos_host_key_event(keyCode, eventType);
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Geocoding (Essentials): request/response like the clipboard bridge. The managed side asks
// through ohos_host_geocode_request (op 0 address -> location with a JSON object of one
// address as arg, op 1 location -> address with "lat,lon" as arg); the shell's
// @ohos.geoLocationManager call answers with host.geocodeResult(requestId, rc, json) and the
// host delivers it to the managed callback registered with ohos_host_register_geocode_result.
HostSink g_geocode_sink("geocode", false);

void OnGeocodeRequest(int requestId, int op, const char* arg) {
    if (!ControlStringFits(arg, "geocode")) {
        return;
    }
    SinkCall* call = new SinkCall();
    call->AddInt(requestId);
    call->AddInt(op);
    call->AddString(arg, kMaxControlBytes);
    HostSinkPost(g_geocode_sink, call);
}

// ArkTS calls host.registerGeocodeSink(fn) to receive geocoding requests.
napi_value RegisterGeocodeSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            HostSinkRegister(env, g_geocode_sink, argv[0]);
            ohos_host_geocode_set_listener(OnGeocodeRequest);
            OH_LOG_INFO(LOG_APP, "[openharmony-host] geocode sink registered");
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.geocodeResult(requestId, rc, json) with the geocoder's answer.
napi_value NotifyGeocodeResult(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t requestId = 0;
    int32_t rc = -1;
    std::string json;
    if (argc >= 1) napi_get_value_int32(env, argv[0], &requestId);
    if (argc >= 2) napi_get_value_int32(env, argv[1], &rc);
    if (argc >= 3) json = GetStringArg(env, argv[2]);
    ohos_host_geocode_complete(requestId, rc, json.c_str());
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.registerVibrationSink(fn) to receive vibration requests (the preferred
// path is the NDK export ohos_host_vibrate; this sink stays for shells that provide one).
HostSink g_vibration_sink("vibration", true);

void OnVibrationRequest(int durationMs) {
    SinkCall* call = new SinkCall();
    call->AddInt(durationMs);
    HostSinkPost(g_vibration_sink, call);
}

napi_value RegisterVibrationSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            HostSinkRegister(env, g_vibration_sink, argv[0]);
            ohos_host_set_vibration_listener(OnVibrationRequest);
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.registerKeystoreSink(fn) to receive keystore requests.
napi_value RegisterKeystoreSink(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[0], &type);
        if (type == napi_function) {
            HostSinkRegister(env, g_keystore_sink, argv[0]);
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
    SinkCall* call = new SinkCall();
    call->AddInt(show);
    HostSinkPost(g_text_input_sink, call);
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
            HostSinkRegister(env, g_text_input_sink, argv[0]);
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
    if (length > kMaxResultBytes) {
        // Results (web eval/picker/clipboard/geocode payloads) are capped; an over-long value is
        // dropped with a log line and never copied into the host.
        OH_LOG_WARN(LOG_APP, "[openharmony-host] string argument dropped: %{public}d bytes over the %{public}d cap",
                    (int)length, (int)kMaxResultBytes);
        return std::string();
    }
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
    if (rc != 0) {
        std::lock_guard<std::mutex> launch_guard(g_launch_lock);
        g_launch_requested = false;   // the launch failed: a retry is allowed
        OH_LOG_ERROR(LOG_APP, "[openharmony-host] start_app failed rc=%{public}d", rc);
    } else {
        std::lock_guard<std::mutex> launch_guard(g_launch_lock);
        g_handle = handle;
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

    // One app per process: reject a second call before any request/thread is allocated, so a
    // duplicate (or a racing retry) cannot leak a LaunchRequest or start a second host.
    {
        std::lock_guard<std::mutex> launch_guard(g_launch_lock);
        if (g_launch_requested || g_handle != nullptr) {
            OH_LOG_WARN(LOG_APP, "[openharmony-host] startApp: an app is already starting or running");
            napi_throw_error(env, nullptr, "startApp: an app is already starting or running");
            return nullptr;
        }
        g_launch_requested = true;
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
        {
            std::lock_guard<std::mutex> launch_guard(g_launch_lock);
            g_launch_requested = false;   // nothing was launched: a retry is allowed
        }
        napi_throw_error(env, nullptr, "failed to start the .NET app thread");
        return nullptr;
    }

    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS calls host.setAppContext(contextJson) once the payload directory is known or the
// surface is ready. After startApp the host replaces the stored snapshot and re-emits it to
// the managed bridge; before startApp the snapshot is kept for the next startApp. Returns 0
// when stored/kept, -1 when the argument is missing/empty or the copy failed.
napi_value SetAppContext(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string json;
    if (argc < 1 || !TryGetStringArg(env, argv[0], &json) || json.empty()) {
        napi_throw_type_error(env, nullptr, "setAppContext(contextJson) requires a non-empty string");
        return nullptr;
    }
    int rc = ohos_host_set_app_context(json.c_str());
    napi_value result = nullptr;
    napi_create_int32(env, rc, &result);
    return result;
}

// ArkTS calls host.notifyAppContext() to re-emit the stored snapshot without changing it.
// Returns 1 when the managed bridge was notified, 0 when there is no live channel.
napi_value NotifyAppContext(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value result = nullptr;
    napi_create_int32(env, ohos_host_notify_context(), &result);
    return result;
}

// ArkTS calls host.setBundleInfo(version, build, name) once at page load with the HAP's real
// values from bundleManager.getBundleInfoForSelfSync; the managed side reads them through
// ohos_host_get_bundle_{version,build,name}. Returns 0 when stored, -1 for a missing
// version/build (the shell reads back '' and the managed side keeps its documented fallbacks).
napi_value SetBundleInfo(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string version;
    std::string build;
    std::string name;
    if (argc >= 1) version = GetStringArg(env, argv[0]);
    if (argc >= 2) build = GetStringArg(env, argv[1]);
    if (argc >= 3) name = GetStringArg(env, argv[2]);
    int rc = ohos_host_set_bundle_info(version.c_str(), build.c_str(), name.c_str());
    napi_value result = nullptr;
    napi_create_int32(env, rc, &result);
    return result;
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
    if (argc >= 1 && argv[0] != nullptr) {
        // The ArkTS side passes a NodeContent (from @ohos.arkui.node); convert it to
        // the native handle the managed app can attach ArkUI nodes to.
        ArkUI_NodeContentHandle content = nullptr;
        if (OH_ArkUI_GetNodeContentFromNapiValue(env, argv[0], &content) == 0 && content != nullptr) {
            ohos_host_set_node_content(g_handle, content);
        } else {
            OH_LOG_WARN(LOG_APP, "[openharmony-host] setNodeContent: not a NodeContent value");
        }
        // The accessibility provider rides the same NodeContent the shell hands over, so the
        // attach runs here. It used to sit after the return above and was dead code, which left
        // the provider unattached forever.
        AttachAccessibilityValue(env, argv[0]);
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
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
        {"registerPermissionSink", nullptr, RegisterPermissionSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerNotificationPermissionSink", nullptr, RegisterNotificationPermissionSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerClipboardSink", nullptr, RegisterClipboardSink, nullptr, nullptr, nullptr, napi_default, nullptr},

        {"registerNotificationSink", nullptr, RegisterNotificationSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerTtsSink", nullptr, RegisterTtsSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyTtsResult", nullptr, NotifyTtsResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerContactsSink", nullptr, RegisterContactsSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyContactsResult", nullptr, NotifyContactsResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerCalendarSink", nullptr, RegisterCalendarSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyCalendarResult", nullptr, NotifyCalendarResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerBluetoothSink", nullptr, RegisterBluetoothSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyBluetoothResult", nullptr, NotifyBluetoothResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyBluetoothDeviceFound", nullptr, NotifyBluetoothDeviceFound, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerBluetoothGattSink", nullptr, RegisterBluetoothGattSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyBluetoothGattResult", nullptr, NotifyBluetoothGattResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyBluetoothGattEvent", nullptr, NotifyBluetoothGattEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerPrintSink", nullptr, RegisterPrintSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyPrintResult", nullptr, NotifyPrintResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerAbilitySink", nullptr, RegisterAbilitySink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerFocusSink", nullptr, RegisterFocusSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"keyEvent", nullptr, KeyEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerFlashlightSink", nullptr, RegisterFlashlightSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerKeepScreenOnSink", nullptr, RegisterKeepScreenOnSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerWindowTitleSink", nullptr, RegisterWindowTitleSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerWindowRectSink", nullptr, RegisterWindowRectSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerScreenshotSink", nullptr, RegisterScreenshotSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerShellSearchChangedSink", nullptr, RegisterShellSearchChangedSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"shellSearchQuery", nullptr, ShellSearchQuery, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"shellSearchPlaceholder", nullptr, ShellSearchPlaceholder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"shellSearchVisible", nullptr, ShellSearchVisible, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"shellSearchEnabled", nullptr, ShellSearchEnabled, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyShellSearch", nullptr, NotifyShellSearch, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerShellFlyoutChangedSink", nullptr, RegisterShellFlyoutChangedSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"shellFlyoutHeader", nullptr, ShellFlyoutHeader, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"shellFlyoutFooter", nullptr, ShellFlyoutFooter, nullptr, nullptr, nullptr, napi_default, nullptr},

        {"registerMenuChangedSink", nullptr, RegisterMenuChangedSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"menuCount", nullptr, MenuCount, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"menuItem", nullptr, MenuGetItem, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyMenuAction", nullptr, NotifyMenuAction, nullptr, nullptr, nullptr, napi_default, nullptr},

        {"notifyPinch", nullptr, NotifyPinch, nullptr, nullptr, nullptr, napi_default, nullptr},



        {"accessibilityStatus", nullptr, AccessibilityStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"accessibilityNodeCount", nullptr, AccessibilityNodeCount, nullptr, nullptr, nullptr, napi_default, nullptr},



        {"attachAccessibilityNode", nullptr, AttachAccessibilityNode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerWebSink", nullptr, RegisterWebSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyWebEvent", nullptr, NotifyWebEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerWebEvalSink", nullptr, RegisterWebEvalSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyWebEvalResult", nullptr, NotifyWebEvalResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyJsMessage", nullptr, NotifyJsMessage, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyHybridInvoke", nullptr, NotifyHybridInvoke, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerHybridInvokeResultSink", nullptr, RegisterHybridInvokeResultSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyAvoidArea", nullptr, NotifyAvoidArea, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifySoftInputArea", nullptr, NotifySoftInputArea, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyTheme", nullptr, NotifyTheme, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyBattery", nullptr, NotifyBattery, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyDisplay", nullptr, NotifyDisplay, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyPickerResult", nullptr, NotifyPickerResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerRawFileSink", nullptr, RegisterRawFileSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyRawFileResult", nullptr, NotifyRawFileResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"permissionResult", nullptr, NotifyPermissionResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notificationPermissionResult", nullptr, NotifyNotificationPermissionResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clipboardResult", nullptr, NotifyClipboardResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyClipboardChanged", nullptr, NotifyClipboardChanged, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyNetworkAccess", nullptr, NotifyNetworkAccess, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerGeocodeSink", nullptr, RegisterGeocodeSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"geocodeResult", nullptr, NotifyGeocodeResult, nullptr, nullptr, nullptr, napi_default, nullptr},

        {"notifyKeystoreResult", nullptr, NotifyKeystoreResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startApp", nullptr, StartApp, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setAppContext", nullptr, SetAppContext, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setBundleInfo", nullptr, SetBundleInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyAppContext", nullptr, NotifyAppContext, nullptr, nullptr, nullptr, napi_default, nullptr},
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
#include <arkui/native_interface.h>
#include <arkui/native_node.h>
#include <arkui/native_node_napi.h>
#include <arkui/native_interface_accessibility.h>
#include <cmath>
#include <cstring>

// The node table accessors (and the publish contract) are declared in openharmony_host.h,
// which both this file and openharmony_host.c include, so the C++ consumer and the C
// definition cannot drift apart without failing the build.

// One published record. Unset/absent fields keep the documented sentinels: checked = -1,
// range invalid when rangeMin > rangeMax (NaN also fails), hint may be null.
struct A11yNodeRecord {
    int id = 0;
    int parent = 0;
    int flags = 0;
    int actions = 0;
    int checked = -1;
    const char* role = nullptr;
    const char* text = nullptr;
    const char* description = nullptr;
    const char* hint = nullptr;
    float x = 0, y = 0, width = 0, height = 0;
    double rangeMin = 0, rangeMax = 0, rangeCurrent = 0;
};

static bool A11yReadNode(int index, A11yNodeRecord* out) {
    return ohos_host_accessibility_get(index, &out->id, &out->parent, &out->role, &out->text,
                                       &out->description, &out->hint, &out->x, &out->y,
                                       &out->width, &out->height, &out->flags, &out->actions,
                                       &out->rangeMin, &out->rangeMax, &out->rangeCurrent,
                                       &out->checked) == 0;
}

static ArkUI_AccessibilityProvider* g_a11y_provider = nullptr;
// Provider attach state, readable from ArkTS through host.accessibilityStatus() and from the
// managed side through ohos_host_accessibility_provider_status() (logged as
// "[maui] accessibility provider status=N"):
//   0 = not attached (no usable value received yet)
//   1 = provider attached, callbacks registered (expected on device)
//   2 = frame node received, but it is not a CUSTOM node, so the provider call refused it
//   3 = NodeContent received, but the native CUSTOM node could not be created or added to it
//   4 = CUSTOM node created and added to the NodeContent, but the provider refused it
static int g_a11y_status = 0;
static void (*g_a11y_action_listener)(int id, int action) = nullptr;
// ArkUI only hands out the accessibility provider for a node of type ARKUI_NODE_CUSTOM. The
// custom node has to stay alive and inside the NodeContent for as long as the provider is
// registered, so it is kept here (setNodeContent may run again when the page is re-entered).
static ArkUI_NodeHandle g_a11y_custom_node = nullptr;
static bool g_a11y_custom_added = false;

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

// The managed side publishes the ArkUI action bits (OpenHarmonyAccessibilityAction); the
// framework wants one ArkUI_AccessibleAction entry per supported action, so the bitmask is
// expanded into an array here. actionType carries the same bit value and description is the
// action name used by the framework's own vocabulary (@ohos.accessibility AccessibilityAction:
// 'click', 'longClick', 'scrollForward', 'setText', ...), which is what a screen reader shows.
// ArkUI_AccessibleAction { ArkUI_Accessibility_ActionType actionType; const char* description; }
static void A11ySetOperationActions(ArkUI_AccessibilityElementInfo* info, int actions) {
    struct ActionEntry {
        int bit;
        ArkUI_Accessibility_ActionType type;
        const char* description;
    };
    static const ActionEntry kActions[] = {
        {0x00000010, ARKUI_ACCESSIBILITY_NATIVE_ACTION_TYPE_CLICK, "click"},
        {0x00000020, ARKUI_ACCESSIBILITY_NATIVE_ACTION_TYPE_LONG_CLICK, "longClick"},
        {0x00000040, ARKUI_ACCESSIBILITY_NATIVE_ACTION_TYPE_GAIN_ACCESSIBILITY_FOCUS, "accessibilityFocus"},
        {0x00000080, ARKUI_ACCESSIBILITY_NATIVE_ACTION_TYPE_CLEAR_ACCESSIBILITY_FOCUS, "clearAccessibilityFocus"},
        {0x00000100, ARKUI_ACCESSIBILITY_NATIVE_ACTION_TYPE_SCROLL_FORWARD, "scrollForward"},
        {0x00000200, ARKUI_ACCESSIBILITY_NATIVE_ACTION_TYPE_SCROLL_BACKWARD, "scrollBackward"},
        {0x00000400, ARKUI_ACCESSIBILITY_NATIVE_ACTION_TYPE_COPY, "copy"},
        {0x00000800, ARKUI_ACCESSIBILITY_NATIVE_ACTION_TYPE_PASTE, "paste"},
        {0x00001000, ARKUI_ACCESSIBILITY_NATIVE_ACTION_TYPE_CUT, "cut"},
        {0x00002000, ARKUI_ACCESSIBILITY_NATIVE_ACTION_TYPE_SELECT_TEXT, "select"},
        {0x00004000, ARKUI_ACCESSIBILITY_NATIVE_ACTION_TYPE_SET_TEXT, "setText"},
        {0x00100000, ARKUI_ACCESSIBILITY_NATIVE_ACTION_TYPE_SET_CURSOR_POSITION, "setCursorPosition"},
    };
    ArkUI_AccessibleAction list[sizeof(kActions) / sizeof(kActions[0])];
    int32_t count = 0;
    for (const ActionEntry& entry : kActions) {
        if ((actions & entry.bit) == 0) {
            continue;
        }
        list[count].actionType = entry.type;
        list[count].description = entry.description;
        count++;
    }
    if (count > 0) {
        OH_ArkUI_AccessibilityElementInfoSetOperationActions(info, count, list);
    }
}

// Role-derived element states. The managed shadow tree publishes the role vocabulary
// button/text/textInput/checkBox/switch/slider/progress/image/group/header
// (OpenHarmonyAccessibility.RoleOf), so the states below are derived from that string alone:
//   textInput        -> editable
//   checkBox, switch -> checkable
// The checked state itself comes from the published checked field and only a real 0/1 is
// forwarded (A11ySetCheckedState); -1 means unknown and is skipped, because announcing a
// fabricated "unchecked" for a toggle that may be on is worse than staying silent.
static void A11ySetRoleStates(ArkUI_AccessibilityElementInfo* info, const char* role) {
    if (role == nullptr) {
        return;
    }
    if (strcmp(role, "textInput") == 0) {
        OH_ArkUI_AccessibilityElementInfoSetEditable(info, true);
    } else if (strcmp(role, "checkBox") == 0 || strcmp(role, "switch") == 0) {
        OH_ArkUI_AccessibilityElementInfoSetCheckable(info, true);
    }
}

// Range info is forwarded only for the roles that have one and only when the published range
// is valid (range_min <= range_max; NaN also fails that comparison). The managed side sends
// the control's own coordinate space - slider Minimum/Maximum/Value, progress 0/1/Progress -
// and marks every other role absent, so a fabricated 0/100/0 is never announced.
static void A11ySetRangeState(ArkUI_AccessibilityElementInfo* info, const char* role,
                              double rangeMin, double rangeMax, double rangeCurrent) {
    if (role == nullptr) {
        return;
    }
    if (strcmp(role, "slider") != 0 && strcmp(role, "progress") != 0) {
        return;
    }
    if (!(rangeMin <= rangeMax)) {   // absent marker; also drops a NaN from either bound
        return;
    }
    ArkUI_AccessibleRangeInfo range;
    range.min = rangeMin;
    range.max = rangeMax;
    range.current = rangeCurrent;
    OH_ArkUI_AccessibilityElementInfoSetRangeInfo(info, &range);
}

// Checked is forwarded only for a real 0/1; -1 means unknown/not applicable and is skipped
// (SetCheckable above still tells the framework the role is a toggle).
static void A11ySetCheckedState(ArkUI_AccessibilityElementInfo* info, int checked) {
    if (checked == 0 || checked == 1) {
        OH_ArkUI_AccessibilityElementInfoSetChecked(info, checked == 1);
    }
}

// Grouping and accessibility level. The managed shadow tree publishes "group" for every
// container that is not a concrete control (layouts, pages, scroll content), so those nodes
// are marked as accessibility groups instead of unnamed leaves. The level follows what the
// node itself carries: text/description/hint, an action a screen reader can offer, a check
// state or a valid range means the node must be recognized ("yes"); a node with none of
// those is layout-only (an empty container, a decoration image) and stays out of the focus
// order ("no"). "no-hide-descendants" is deliberately never used, so the children of a
// layout-only container are still announced from their own records.
static void A11ySetGroupAndLevel(ArkUI_AccessibilityElementInfo* info, const A11yNodeRecord& node) {
    if (node.role != nullptr && strcmp(node.role, "group") == 0) {
        OH_ArkUI_AccessibilityElementInfoSetAccessibilityGroup(info, true);
    }
    bool hasContent = (node.text != nullptr && node.text[0] != '\0')
        || (node.description != nullptr && node.description[0] != '\0')
        || (node.hint != nullptr && node.hint[0] != '\0');
    // (rangeMin <= rangeMax) is the host's range-validity test, so NaN (absent) falls through.
    bool recognized = hasContent || node.actions != 0
        || node.checked == 0 || node.checked == 1 || (node.rangeMin <= node.rangeMax);
    OH_ArkUI_AccessibilityElementInfoSetAccessibilityLevel(info, recognized ? "yes" : "no");
}

// Fills one ArkUI element from a published record. Shared by the list queries
// (findAccessibilityNodeInfosById/findByText) and the single-node callbacks
// (findFocused/findNextFocus), so every path publishes the same fields.
static int32_t A11yFillElement(int index, ArkUI_AccessibilityElementInfo* info) {
    if (index < 0 || info == nullptr) {
        return ARKUI_ACCESSIBILITY_NATIVE_RESULT_FAILED;
    }
    A11yNodeRecord node;
    if (!A11yReadNode(index, &node)) {
        return ARKUI_ACCESSIBILITY_NATIVE_RESULT_FAILED;
    }
    OH_ArkUI_AccessibilityElementInfoSetElementId(info, node.id);
    OH_ArkUI_AccessibilityElementInfoSetParentId(info, node.parent);
    OH_ArkUI_AccessibilityElementInfoSetComponentType(info, node.role != nullptr ? node.role : "group");
    if (node.text != nullptr) {
        OH_ArkUI_AccessibilityElementInfoSetAccessibilityText(info, node.text);
    }
    if (node.description != nullptr) {
        OH_ArkUI_AccessibilityElementInfoSetContents(info, node.description);
    }
    if (node.hint != nullptr) {
        OH_ArkUI_AccessibilityElementInfoSetHintText(info, node.hint);
    }
    ArkUI_AccessibleRect rect;
    rect.leftTopX = A11yCoord(node.x);
    rect.leftTopY = A11yCoord(node.y);
    rect.rightBottomX = A11yCoord(node.x + node.width);
    rect.rightBottomY = A11yCoord(node.y + node.height);
    OH_ArkUI_AccessibilityElementInfoSetScreenRect(info, &rect);
    OH_ArkUI_AccessibilityElementInfoSetClickable(info, (node.actions & 0x10) != 0);
    OH_ArkUI_AccessibilityElementInfoSetEnabled(info, (node.flags & 1) != 0);
    OH_ArkUI_AccessibilityElementInfoSetFocusable(info, (node.flags & 2) != 0);
    A11ySetGroupAndLevel(info, node);
    A11ySetRoleStates(info, node.role);
    A11ySetRangeState(info, node.role, node.rangeMin, node.rangeMax, node.rangeCurrent);
    A11ySetCheckedState(info, node.checked);
    A11ySetOperationActions(info, node.actions);
    return ARKUI_ACCESSIBILITY_NATIVE_RESULT_SUCCESSFUL;
}

static void A11yAddNode(ArkUI_AccessibilityElementInfoList* list, int index) {
    A11yNodeRecord probe;
    if (!A11yReadNode(index, &probe)) {
        return;   // keeps empty elements out of the list for a stale index
    }
    ArkUI_AccessibilityElementInfo* info = OH_ArkUI_AddAndGetAccessibilityElementInfo(list);
    if (info == nullptr) {
        return;
    }
    A11yFillElement(index, info);
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
        A11yNodeRecord node;
        if (!A11yReadNode(i, &node) || node.id != (int)elementId) {
            continue;
        }
        A11yAddNode(list, i);
        if ((int)mode & ARKUI_ACCESSIBILITY_NATIVE_SEARCH_MODE_PREFETCH_CHILDREN) {
            for (int j = 0; j < count; j++) {
                A11yNodeRecord child;
                if (A11yReadNode(j, &child) && child.parent == node.id) {
                    A11yAddNode(list, j);
                }
            }
        }
        return ARKUI_ACCESSIBILITY_NATIVE_RESULT_SUCCESSFUL;
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
        A11yNodeRecord node;
        if (!A11yReadNode(i, &node)) {
            continue;
        }
        if ((node.text != nullptr && strstr(node.text, text) != nullptr) ||
            (node.description != nullptr && strstr(node.description, text) != nullptr)) {
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
        A11yNodeRecord node;
        if (A11yReadNode(i, &node) && (node.flags & 2) != 0) {
            return i;
        }
    }
    return -1;
}

// --- Direction-aware focus movement (findNextFocusAccessibilityNode) -----------------------
//
// The published node table carries screen rects but no reading order, so the two kinds of move
// use different rules:
//   * UP/DOWN/LEFT/RIGHT are geometric. The origin is the centre of the current node's screen
//     rect; a candidate (any other focusable node) must lie strictly ahead on the primary axis
//     (primaryDelta >= kA11yFocusEpsilon - this drops elements behind and elements overlapping
//     the origin) and is scored as
//         primaryDelta + kA11yFocusPerpendicularPenalty * perpendicularDelta
//     so an element straight ahead beats a nearer diagonal one. The penalty is the whole
//     heuristic: it is compared in the same units as the rect (pixels), so 2:1 means "1 px of
//     sideways drift costs 2 px of forward distance". Ties go to the smaller perpendicular
//     distance, then to the earlier published index, keeping the choice deterministic.
//   * FORWARD/BACKWARD ignore geometry and walk the published index order (the order in which
//     the managed tree walk visits nodes, root first), starting after/before the current index
//     and wrapping at both ends.
// All comparisons require at least one candidate to pass `>= epsilon`, so NaN rects are skipped
// rather than poisoning the score. Nothing qualifying returns FAILED.
static const float kA11yFocusEpsilon = 1.0f;
static const float kA11yFocusPerpendicularPenalty = 2.0f;

// Reads the centre and focusable bit of one table entry; false when the index is not in the table.
static bool A11yReadNodeGeom(int index, float* centerX, float* centerY, bool* focusable) {
    A11yNodeRecord node;
    if (!A11yReadNode(index, &node)) {
        return false;
    }
    if (centerX != nullptr) {
        *centerX = node.x + node.width * 0.5f;
    }
    if (centerY != nullptr) {
        *centerY = node.y + node.height * 0.5f;
    }
    if (focusable != nullptr) {
        *focusable = (node.flags & 2) != 0;
    }
    return true;
}

// Index of the node published under this id, or -1 when it is not in the table.
static int A11yIndexOfId(int64_t elementId) {
    if (elementId <= 0) {
        return -1;
    }
    int count = ohos_host_accessibility_count();
    for (int i = 0; i < count; i++) {
        A11yNodeRecord node;
        if (A11yReadNode(i, &node) && node.id == (int)elementId) {
            return i;
        }
    }
    return -1;
}

// Nearest focusable node in one of the four geometric directions; -1 when none qualifies.
static int A11yNearestInDirection(int current, ArkUI_AccessibilityFocusMoveDirection direction) {
    float originX = 0, originY = 0;
    if (!A11yReadNodeGeom(current, &originX, &originY, nullptr)) {
        return -1;
    }
    const bool horizontal = direction == ARKUI_ACCESSIBILITY_NATIVE_DIRECTION_LEFT ||
                            direction == ARKUI_ACCESSIBILITY_NATIVE_DIRECTION_RIGHT;
    const float sign = (direction == ARKUI_ACCESSIBILITY_NATIVE_DIRECTION_RIGHT ||
                        direction == ARKUI_ACCESSIBILITY_NATIVE_DIRECTION_DOWN) ? 1.0f : -1.0f;
    int count = ohos_host_accessibility_count();
    int best = -1;
    float bestScore = 0, bestPerpendicular = 0;
    for (int i = 0; i < count; i++) {
        if (i == current) {
            continue;
        }
        float cx = 0, cy = 0;
        bool focusable = false;
        if (!A11yReadNodeGeom(i, &cx, &cy, &focusable) || !focusable) {
            continue;
        }
        float primary = sign * (horizontal ? cx - originX : cy - originY);
        if (!(primary >= kA11yFocusEpsilon)) {   // behind, overlapping, or NaN
            continue;
        }
        float perpendicular = fabsf(horizontal ? cy - originY : cx - originX);
        if (!(perpendicular >= 0.0f)) {          // NaN
            continue;
        }
        float score = primary + kA11yFocusPerpendicularPenalty * perpendicular;
        if (best < 0 || score < bestScore ||
            (score == bestScore && perpendicular < bestPerpendicular)) {
            best = i;
            bestScore = score;
            bestPerpendicular = perpendicular;
        }
    }
    return best;
}

// Index-order focus step (FORWARD/BACKWARD), wrapping at both ends. When the current id is not
// in the table, the pre-R2 assumption "id == index + 1" is kept so stale ids move relative to
// the same index as before; ids <= 0 start at the first (FORWARD) or last (BACKWARD) node.
static int A11yStepFocus(int64_t elementId, bool backward) {
    int count = ohos_host_accessibility_count();
    if (count <= 0) {
        return -1;
    }
    int start = A11yIndexOfId(elementId);
    if (start < 0) {
        if (elementId > 0) {
            start = (int)((elementId - 1) % count);
        } else {
            start = backward ? count : -1;
        }
    }
    for (int step = 1; step <= count; step++) {
        int i = backward ? (int)(((start - step) % count + count) % count)
                         : (start + step) % count;
        A11yNodeRecord node;
        if (A11yReadNode(i, &node) && (node.flags & 2) != 0) {
            return i;
        }
    }
    return -1;
}

static int32_t A11yFocused(int64_t elementId, ArkUI_AccessibilityFocusType focusType,
                           int32_t requestId, ArkUI_AccessibilityElementInfo* info) {
    (void)elementId; (void)focusType; (void)requestId;
    return A11yFillElement(A11yFirstFocusable(-1), info);
}

static int32_t A11yNextFocus(int64_t elementId, ArkUI_AccessibilityFocusMoveDirection direction,
                             int32_t requestId, ArkUI_AccessibilityElementInfo* info) {
    (void)requestId;
    int index = -1;
    switch (direction) {
        case ARKUI_ACCESSIBILITY_NATIVE_DIRECTION_UP:
        case ARKUI_ACCESSIBILITY_NATIVE_DIRECTION_DOWN:
        case ARKUI_ACCESSIBILITY_NATIVE_DIRECTION_LEFT:
        case ARKUI_ACCESSIBILITY_NATIVE_DIRECTION_RIGHT: {
            // elementId <= 0 means "no current node" (the convention used by findAccessibilityNodeInfosById,
            // where it selects the root): use the root's rect as the geometric origin.
            int current = A11yIndexOfId(elementId);
            if (current < 0 && elementId <= 0) {
                current = 0;
            }
            index = A11yNearestInDirection(current, direction);
            break;
        }
        case ARKUI_ACCESSIBILITY_NATIVE_DIRECTION_BACKWARD:
            index = A11yStepFocus(elementId, true);
            break;
        case ARKUI_ACCESSIBILITY_NATIVE_DIRECTION_FORWARD:
        default:
            // FORWARD, and also INVALID/unknown values: those keep the pre-R2 index-order move.
            index = A11yStepFocus(elementId, false);
            break;
    }
    if (index < 0) {
        return ARKUI_ACCESSIBILITY_NATIVE_RESULT_FAILED;
    }
    return A11yFillElement(index, info);
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

// Attaches the accessibility provider from the value the shell hands over. Two shapes are
// accepted: a FrameNode (host.attachAccessibilityNode) and the startup NodeContent
// (host.setNodeContent). ArkUI refuses the provider for every node type except
// ARKUI_NODE_CUSTOM, and ArkTS cannot create a custom node (typeNode.createNode(uiContext,
// 'custom') does not compile), so the NodeContent path creates the CUSTOM node here, natively,
// and adds it to the content before asking for the provider.
static int AttachAccessibilityValue(napi_env env, napi_value value) {
    if (env == nullptr || value == nullptr) {
        return g_a11y_status;
    }
    if (g_a11y_provider != nullptr) {
        return g_a11y_status;  // already attached; setNodeContent may run again on page re-entry
    }

    // FrameNode path: any frame node can reach here, but only ARKUI_NODE_CUSTOM gets a provider;
    // keep the direct attempt so the diagnosis stays 2 (received but refused).
    ArkUI_NodeHandle node = nullptr;
    if (OH_ArkUI_GetNodeHandleFromNapiValue(env, value, &node) == 0 && node != nullptr) {
        g_a11y_status = 2;  // frame node received
        ArkUI_AccessibilityProvider* provider = nullptr;
        if (OH_ArkUI_NativeModule_GetNativeAccessibilityProvider(&node, &provider) == 0 &&
            provider != nullptr &&
            OH_ArkUI_AccessibilityProviderRegisterCallback(provider, &g_a11y_callbacks) == 0) {
            g_a11y_provider = provider;
            g_a11y_status = 1;  // provider attached
        }
        return g_a11y_status;
    }

    // NodeContent path: the shell hands its content over at startup (host.setNodeContent).
    ArkUI_NodeContentHandle content = nullptr;
    if (OH_ArkUI_GetNodeContentFromNapiValue(env, value, &content) != 0 || content == nullptr) {
        return g_a11y_status;
    }
    g_a11y_status = 3;  // NodeContent received; the CUSTOM node still has to be created/added

    ArkUI_NativeNodeAPI_1* api = nullptr;
    OH_ArkUI_GetModuleInterface(ARKUI_NATIVE_NODE, ArkUI_NativeNodeAPI_1, api);
    if (api == nullptr || api->createNode == nullptr) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] accessibility: native node API unavailable");
        return g_a11y_status;
    }
    if (g_a11y_custom_node == nullptr) {
        g_a11y_custom_node = api->createNode(ARKUI_NODE_CUSTOM);
    }
    if (g_a11y_custom_node == nullptr) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] accessibility: createNode(ARKUI_NODE_CUSTOM) failed");
        return g_a11y_status;
    }
    if (!g_a11y_custom_added) {
        if (OH_ArkUI_NodeContent_AddNode(content, g_a11y_custom_node) != 0) {
            OH_LOG_WARN(LOG_APP, "[openharmony-host] accessibility: NodeContent_AddNode failed");
            return g_a11y_status;
        }
        g_a11y_custom_added = true;
    }
    g_a11y_status = 4;  // CUSTOM node is in the content; the provider has not accepted it yet

    ArkUI_NodeHandle custom = g_a11y_custom_node;
    ArkUI_AccessibilityProvider* provider = nullptr;
    if (OH_ArkUI_NativeModule_GetNativeAccessibilityProvider(&custom, &provider) != 0 ||
        provider == nullptr) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] accessibility: provider refused the CUSTOM node");
        return g_a11y_status;
    }
    if (OH_ArkUI_AccessibilityProviderRegisterCallback(provider, &g_a11y_callbacks) != 0) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] accessibility: provider callback registration failed");
        return g_a11y_status;
    }
    g_a11y_provider = provider;
    g_a11y_status = 1;  // provider attached
    OH_LOG_INFO(LOG_APP, "[openharmony-host] accessibility: provider attached to the CUSTOM node");
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

// Published node count for the shell's accessibility self-check dialog (host.accessibilityNodeCount).
// Reads the native node table's committed count; 0 before the first publish (or when no app runs).
napi_value AccessibilityNodeCount(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value result = nullptr;
    napi_create_int32(env, ohos_host_accessibility_node_count(), &result);
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
    // The provider serializes the event during the send; the caller still owns the object, so
    // it is destroyed here instead of leaking one event info per published event.
    OH_ArkUI_SendAccessibilityAsyncEvent(g_a11y_provider, event, nullptr);
    OH_ArkUI_DestoryAccessibilityEventInfo(event);
    return 1;
}

// Announces text through the attached provider. Same event lifetime discipline as
// ohos_host_accessibility_send_event: the event is destroyed on every path (including the
// setter failures) and the provider owns/copies the text during the send. Returns 1 when the
// event was created and sent, 0 when there is no provider or the text is NULL/empty.
extern "C" int ohos_host_accessibility_announce(const char* text) {
    if (text == nullptr || text[0] == '\0') {
        return 0;
    }
    if (!ControlStringFits(text, "accessibility_announce")) {
        return 0;
    }
    if (g_a11y_provider == nullptr) {
        return 0;
    }
    ArkUI_AccessibilityEventInfo* announceEvent = OH_ArkUI_CreateAccessibilityEventInfo();
    if (announceEvent == nullptr) {
        return 0;
    }
    if (OH_ArkUI_AccessibilityEventSetEventType(
            announceEvent, ARKUI_ACCESSIBILITY_NATIVE_EVENT_TYPE_ANNOUNCE_FOR_ACCESSIBILITY) != 0 ||
        OH_ArkUI_AccessibilityEventSetTextAnnouncedForAccessibility(announceEvent, text) != 0) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] accessibility announce: event setup failed");
        OH_ArkUI_DestoryAccessibilityEventInfo(announceEvent);
        return 0;
    }
    OH_ArkUI_SendAccessibilityAsyncEvent(g_a11y_provider, announceEvent, nullptr);
    OH_ArkUI_DestoryAccessibilityEventInfo(announceEvent);
    return 1;
}


// C entry point so the managed runtime can log the attach state (1/2/3, see the handover status).
extern "C" int ohos_host_accessibility_provider_status(void) {
    return g_a11y_status;
}
