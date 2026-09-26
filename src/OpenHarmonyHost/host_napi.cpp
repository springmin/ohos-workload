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
#include "host_optional_log.h"  // after hilog/log.h: routes OH_LOG_* through the optional shim
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <exception>
#include <memory>
#include <mutex>
#include <utility>

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

// XComponent (surface) support: the env, the exports reference and the bound XComponent live
// in the current HostBinding (see the g_* accessors below); nothing here is a process-wide
// global any more.

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

struct HostJsReply;
struct HostMenuSnapshot;

// The result a synchronous HostCallJs() call consumes. kBool backs the shell's boolean
// "handled" answers, kInt the numeric ones; kNone is a fire-and-forget notification.
enum class HostJsResult {
    kNone,
    kBool,
    kInt,
};

// Completion slot of one synchronous shell call. Heap-owned and shared: the waiting caller
// and the JS-thread dispatch both hold a shared_ptr, so a timeout (the caller gives up but the
// call is already queued) cannot free the slot under the dispatcher. The dispatcher never
// writes into an abandoned slot, and HostSinkReset completes every queued slot with
// napi_closing when the threadsafe function is aborted.
struct HostJsReply {
    std::mutex mutex;
    std::condition_variable cv;
    bool done = false;
    bool abandoned = false;
    bool has_bool = false;
    bool bool_value = false;
    bool has_int = false;
    int32_t int_value = 0;
    napi_status status = napi_generic_failure;
};

// One notification: the argument vector the shell callback will be invoked with. A call is
// either asynchronous (result kNone, reply null) or synchronous through HostCallJs (a reply
// slot plus the expected result kind). The menu change sink additionally carries the immutable
// menu table snapshot handed to the JS side.
struct SinkCall {
    enum { kMaxArgs = 5 };
    int count = 0;
    SinkArg args[kMaxArgs];
    // Set when an AddString argument exceeded its cap: a notification with a missing or partial
    // argument must not be delivered (see HostSinkPost).
    bool overflow = false;
    HostJsResult result_kind = HostJsResult::kNone;
    std::shared_ptr<HostJsReply> reply;
    std::shared_ptr<const HostMenuSnapshot> menu_snapshot;

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

// Thread-safe listener slots. The managed side registers each result callback once (on the
// managed thread), the shell answers on the JS/ArkUI thread; the atomic store/load pair below
// is the publish/consume edge the raw function pointers lacked, so the read side can never
// observe a torn or stale pointer. Fn is a plain function pointer type; reads go through
// HostListenerLoad so every call site uses the acquire load explicitly.
template <typename Fn>
static Fn HostListenerLoad(const std::atomic<Fn>& slot) {
    return slot.load(std::memory_order_acquire);
}

template <typename Fn>
static void HostListenerStore(std::atomic<Fn>& slot, void* callback) {
    slot.store(reinterpret_cast<Fn>(callback), std::memory_order_release);
}

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

// The managed-side menu table is published as an immutable snapshot: ohos_host_menu_begin/item
// fill a builder vector on the managed thread, commit copies it into a fresh snapshot and hands
// that snapshot to the JS thread through the menu sink. The JS-thread menu getters read the
// snapshot the JS thread received (or, before the first delivery, the last published one), so
// no mutable table is ever read across threads.
struct HostMenuItem {
    std::string text;
    bool enabled = false;
};

struct HostMenuSnapshot {
    std::vector<HostMenuItem> items;
};

// Everything the host binds to one JS environment: the env handle, the exports/XComponent
// references, the JS-thread identity and every registered sink with its threadsafe function.
// A page rebuild (or an ability restart) calls Init with a new env; the previous binding is
// torn down with the env that created its references and a new one is claimed, so a stale
// napi_ref is never deleted (or used) through the wrong env.
struct HostBinding {
    napi_env env = nullptr;
    pthread_t js_thread{};
    bool js_thread_valid = false;
    napi_ref exports_ref = nullptr;
    napi_ref xcomponent_export_ref = nullptr;
    OH_NativeXComponent* xcomponent = nullptr;

    // Menu tables: the builder and the last published snapshot are managed-thread state under
    // menu_lock; menu_js is the immutable snapshot the JS thread is currently serving (only
    // the JS thread reads or writes it, so it needs no lock).
    std::mutex menu_lock;
    std::vector<HostMenuItem> menu_build;
    std::shared_ptr<const HostMenuSnapshot> menu_latest;
    std::shared_ptr<const HostMenuSnapshot> menu_js;

    HostSink text_input{"text input", true};
    HostSink keystore{"keystore", true};
    HostSink notification{"notification", false};
    HostSink tts{"tts", false};
    HostSink contacts{"contacts", false};
    HostSink calendar{"calendar", false};
    HostSink bluetooth{"bluetooth", false};
    HostSink bluetooth_gatt{"bluetooth gatt", false};
    HostSink print{"print", false};
    HostSink ability{"ability", false};
    HostSink flashlight{"flashlight", false};
    HostSink focus{"focus", false};
    HostSink menu_changed{"menu", false};
    HostSink picker{"picker", true};
    HostSink web{"web", true};
    HostSink keep_screen_on{"keep screen on", false};
    HostSink window_title{"window title", false};
    HostSink window_rect{"window rect", false};
    HostSink screenshot{"screenshot", false};
    HostSink shell_search{"shell search", false};
    HostSink shell_flyout{"shell flyout", false};
    HostSink web_eval{"web eval", false};
    HostSink hybrid_invoke_result{"hybrid invoke result", false};
    HostSink raw_file{"raw file", false};
    HostSink permission{"permission", false};
    HostSink notification_permission{"notification permission", false};
    HostSink clipboard{"clipboard", false};
    HostSink geocode{"geocode", false};
    HostSink vibration{"vibration", true};
    // HMS Kits (Share/Scan; KIT-IMPL 2026-09-25): registered by the shell only when its runtime
    // provides @kit.ShareKit / @kit.ScanKit. On the default OpenHarmony SDK build the probe
    // fails and the sinks stay unset, so both exports answer -1 and the managed side degrades.
    HostSink share_kit{"share kit", false};
    HostSink scan{"scan", false};
    // HMS Kits (Push/Account/Map; KIT-EXT2 2026-09-25): same contract for the second batch.
    HostSink push{"push", false};
    HostSink account{"account", false};
    HostSink map{"map", false};
    // HMS Kits (Live View; R2-SHELL-EXT 2026-09-26): same contract for the third probe.
    HostSink liveview{"live view", false};
};

struct HostBindingSlot {
    HostBinding binding;
    bool active = false;
    bool hook_registered = false;
};

// Static storage (never freed) so an env cleanup hook can hold the slot address safely.
// Slot 0 is the home slot: it backs the g_host pointer before the first Init and after the
// current binding is torn down, so HostSinkPost from a stray managed call drops instead of
// dereferencing a dangling binding.
constexpr int kHostBindingSlotCount = 4;
static HostBindingSlot g_binding_slots[kHostBindingSlotCount];
static HostBinding* g_host = &g_binding_slots[0].binding;

// The g_* names are the call sites' (and the regression pins') vocabulary; each expands to the
// current binding's member so no call can reach another environment's sinks or references.
#define g_env (g_host->env)
#define g_exports_ref (g_host->exports_ref)
#define g_xcomponent (g_host->xcomponent)
#define g_xcomponent_export_ref (g_host->xcomponent_export_ref)
#define g_text_input_sink (g_host->text_input)
#define g_keystore_sink (g_host->keystore)
#define g_notification_sink (g_host->notification)
#define g_tts_sink (g_host->tts)
#define g_contacts_sink (g_host->contacts)
#define g_calendar_sink (g_host->calendar)
#define g_bluetooth_sink (g_host->bluetooth)
#define g_bluetooth_gatt_sink (g_host->bluetooth_gatt)
#define g_print_sink (g_host->print)
#define g_ability_sink (g_host->ability)
#define g_flashlight_sink (g_host->flashlight)
#define g_focus_sink (g_host->focus)
#define g_menu_changed_sink (g_host->menu_changed)
#define g_picker_sink (g_host->picker)
#define g_web_sink (g_host->web)
#define g_keep_screen_on_sink (g_host->keep_screen_on)
#define g_window_title_sink (g_host->window_title)
#define g_window_rect_sink (g_host->window_rect)
#define g_screenshot_sink (g_host->screenshot)
#define g_shell_search_sink (g_host->shell_search)
#define g_shell_flyout_sink (g_host->shell_flyout)
#define g_web_eval_sink (g_host->web_eval)
#define g_hybrid_invoke_result_sink (g_host->hybrid_invoke_result)
#define g_raw_file_sink (g_host->raw_file)
#define g_permission_sink (g_host->permission)
#define g_notification_permission_sink (g_host->notification_permission)
#define g_clipboard_sink (g_host->clipboard)
#define g_geocode_sink (g_host->geocode)
#define g_vibration_sink (g_host->vibration)
#define g_share_kit_sink (g_host->share_kit)
#define g_scan_sink (g_host->scan)
#define g_push_sink (g_host->push)
#define g_account_sink (g_host->account)
#define g_map_sink (g_host->map)
#define g_liveview_sink (g_host->liveview)

// Table-driven sink registry: the single enumeration of every per-env sink, so HostSinkReset
// cannot miss one on a page rebuild or env teardown. Keep this list aligned with the members.
template <typename F>
static void HostForEachSink(HostBinding& binding, F&& visit) {
    visit(binding.text_input);
    visit(binding.keystore);
    visit(binding.notification);
    visit(binding.tts);
    visit(binding.contacts);
    visit(binding.calendar);
    visit(binding.bluetooth);
    visit(binding.bluetooth_gatt);
    visit(binding.print);
    visit(binding.ability);
    visit(binding.flashlight);
    visit(binding.focus);
    visit(binding.menu_changed);
    visit(binding.picker);
    visit(binding.web);
    visit(binding.keep_screen_on);
    visit(binding.window_title);
    visit(binding.window_rect);
    visit(binding.screenshot);
    visit(binding.shell_search);
    visit(binding.shell_flyout);
    visit(binding.web_eval);
    visit(binding.hybrid_invoke_result);
    visit(binding.raw_file);
    visit(binding.permission);
    visit(binding.notification_permission);
    visit(binding.clipboard);
    visit(binding.geocode);
    visit(binding.vibration);
    visit(binding.share_kit);
    visit(binding.scan);
    visit(binding.push);
    visit(binding.account);
    visit(binding.map);
    visit(binding.liveview);
}

std::string GetStringArg(napi_env env, napi_value value);

// --- JS-thread identity, env binding and exception discipline ---------------------

// True only on the JS/UI thread that Init() ran on. Every napi call in this file goes through
// HostCallCallback (or a TSFN dispatch, which the engine runs there), and this predicate is the
// gate: a cross-thread napi touch is reported once and turned into a safe failure.
static bool HostIsJsThread() {
    HostBinding* binding = g_host;
    return binding != nullptr && binding->js_thread_valid && pthread_equal(pthread_self(), binding->js_thread);
}

// The binding that belongs to env, or null when that env no longer owns one.
static HostBinding* HostBindingFor(napi_env env) {
    if (env == nullptr) {
        return nullptr;
    }
    for (int i = 0; i < kHostBindingSlotCount; i++) {
        HostBindingSlot& slot = g_binding_slots[i];
        if (slot.active && slot.binding.env == env) {
            return &slot.binding;
        }
    }
    return nullptr;
}

// Completes one synchronous call. Runs on the JS thread (dispatch) or during a sink reset;
// an abandoned reply (the caller timed out) is left untouched but still woken.
static void HostJsReplyComplete(const std::shared_ptr<HostJsReply>& reply, napi_status status,
                                bool has_bool, bool bool_value, bool has_int, int32_t int_value) {
    if (!reply) {
        return;
    }
    std::lock_guard<std::mutex> guard(reply->mutex);
    if (!reply->abandoned) {
        reply->status = status;
        reply->has_bool = has_bool;
        reply->bool_value = bool_value;
        reply->has_int = has_int;
        reply->int_value = int_value;
        reply->done = true;
    }
    reply->cv.notify_all();
}

// Consumes a pending JS exception after a shell callback ran. The callback's own error handling
// is its business, but an exception left pending at the napi boundary would abort the next
// napi call on the thread; every HostCallCallback therefore drains it and logs the value.
static void HostClearPendingException(napi_env env, const char* where) {
    bool pending = false;
    if (napi_is_exception_pending(env, &pending) != napi_ok || !pending) {
        return;
    }
    napi_value exception = nullptr;
    if (napi_get_and_clear_last_exception(env, &exception) != napi_ok) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] %{public}s: shell callback left a pending exception that could not be cleared", where);
        return;
    }
    std::string message;
    napi_value as_string = nullptr;
    if (exception != nullptr && napi_coerce_to_string(env, exception, &as_string) == napi_ok && as_string != nullptr) {
        message = GetStringArg(env, as_string);
    }
    if (message.empty()) {
        message = "<non-string exception>";
    } else if (message.size() > 256) {
        message.resize(256);
    }
    OH_LOG_WARN(LOG_APP, "[openharmony-host] %{public}s: shell callback threw: %{public}s", where, message.c_str());
}

// Builds the callback argument vector from a SinkCall. Every slot is initialized: an argument
// whose napi creation fails is replaced by undefined instead of being passed uninitialized.
static void HostMakeArgs(napi_env env, const SinkCall& call, napi_value* argv) {
    for (int i = 0; i < call.count && i < SinkCall::kMaxArgs; i++) {
        napi_status status = napi_generic_failure;
        if (call.args[i].is_string) {
            status = napi_create_string_utf8(env, call.args[i].string_value.c_str(), NAPI_AUTO_LENGTH, &argv[i]);
        } else {
            status = napi_create_int32(env, call.args[i].int_value, &argv[i]);
        }
        if (status != napi_ok || argv[i] == nullptr) {
            argv[i] = nullptr;
            napi_get_undefined(env, &argv[i]);
        }
    }
}

// The single door every napi_call_function in this file goes through: the JS-thread/env gate,
// the call itself and the exception drain. Returns the napi status; a rejected call (wrong
// thread or env) reports napi_generic_failure without touching the engine.
static napi_status HostCallCallback(napi_env env, napi_value this_arg, napi_value function,
                                    size_t argc, napi_value* argv, napi_value* result, const char* where) {
    if (env == nullptr || g_host->env != env || !HostIsJsThread()) {
        static bool offThreadLogged = false;
        if (!offThreadLogged) {
            offThreadLogged = true;
            OH_LOG_WARN(LOG_APP, "[openharmony-host] %{public}s: napi callback attempted off the JS thread or env, ignored", where);
        }
        return napi_generic_failure;
    }
    napi_status status = napi_call_function(env, this_arg, function, argc, argv, result);
    HostClearPendingException(env, where);
    return status;
}

// Runs on the JS/UI thread: builds the arguments, calls the shell callback and releases
// the payload. A throwing callback is cleared and ignored, exactly like the discarded
// napi_call_function return value used to be. A synchronous call's reply is completed here,
// with the answer converted while the JS values are still valid.
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
    // The menu table snapshot is delivered before the callback so the shell's pull
    // (menuCount/menuItem) reads exactly the version the notification announced.
    if (env != nullptr && call->menu_snapshot) {
        HostBinding* binding = HostBindingFor(env);
        if (binding != nullptr) {
            binding->menu_js = std::move(call->menu_snapshot);
        }
    }
    napi_status call_status = napi_generic_failure;
    bool has_bool = false;
    bool bool_value = false;
    bool has_int = false;
    int32_t int_value = 0;
    if (env != nullptr && js_callback != nullptr) {
        napi_value argv[SinkCall::kMaxArgs] = {};
        HostMakeArgs(env, *call, argv);
        napi_value this_arg = js_callback;
        if (sink != nullptr && sink->global_this && napi_get_global(env, &this_arg) != napi_ok) {
            this_arg = js_callback;
        }
        napi_value result = nullptr;
        call_status = HostCallCallback(env, this_arg, js_callback, (size_t)call->count, argv, &result,
                                       sink != nullptr ? sink->name : "sink");
        if (call_status == napi_ok && call->reply) {
            if (call->result_kind == HostJsResult::kBool && result != nullptr) {
                has_bool = napi_get_value_bool(env, result, &bool_value) == napi_ok;
            } else if (call->result_kind == HostJsResult::kInt && result != nullptr) {
                has_int = napi_get_value_int32(env, result, &int_value) == napi_ok;
            }
        }
    }
    if (call->reply) {
        HostJsReplyComplete(call->reply, call_status, has_bool, bool_value, has_int, int_value);
    }
    delete call;
}

// Destroys the sink's threadsafe function and frees anything still queued. Runs on the JS
// thread (Register*Sink, env teardown), so it cannot overlap a HostSinkDispatch that is
// executing there; aborting drops the pending items without calling the dispatch, hence the
// explicit free. Every queued synchronous call is completed with napi_closing first, so a
// waiting managed thread never has to wait out its timeout.
static void HostSinkReset(HostSink& sink) {
    std::lock_guard<std::mutex> guard(sink.lock);
    if (sink.tsfn != nullptr) {
        napi_release_threadsafe_function(sink.tsfn, napi_tsfn_abort);
        sink.tsfn = nullptr;
    }
    for (SinkCall* call : sink.pending) {
        HostJsReplyComplete(call->reply, napi_closing, false, false, false, 0);
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
    try {
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
    } catch (...) {
        // A failed pending-vector growth owns nothing: the payload is freed below.
        OH_LOG_ERROR(LOG_APP, "[openharmony-host] %{public}s: could not queue the notification", sink.name);
        posted = false;
    }
    if (!posted) {
        delete call;
    }
    return posted;
}

// Synchronous shell call over the sink's threadsafe function: the call is queued for the JS
// thread and the managed caller waits for the reply. This is the only legitimate shape for the
// request/answer sinks (launcher/browser/share, flashlight, focus): the answer is consumed
// synchronously, but the napi objects are only ever touched by the JS thread.
constexpr int kHostCallTimeoutMs = 5000;

// Exactly one of bool_out/int_out selects the expected answer type. Returns napi_ok when the
// shell callback ran (the out parameter then carries its answer, defaulting to false/0 when the
// shell returned nothing convertible) and a failure status when no sink was registered, the
// queue was unavailable or the shell did not answer within the timeout.
static napi_status HostCallJs(HostSink& sink, SinkCall* call, bool* bool_out, int32_t* int_out) {
    if (call == nullptr || (bool_out == nullptr && int_out == nullptr)) {
        delete call;
        return napi_invalid_arg;
    }
    if (call->overflow) {
        // An argument exceeded its cap (already logged by AddString): the request is invalid.
        delete call;
        return napi_invalid_arg;
    }
    call->result_kind = bool_out != nullptr ? HostJsResult::kBool : HostJsResult::kInt;
    bool posted = false;
    napi_status status = napi_generic_failure;
    std::shared_ptr<HostJsReply> reply;
    try {
        call->reply = std::make_shared<HostJsReply>();
        reply = call->reply;
        std::lock_guard<std::mutex> guard(sink.lock);
        if (sink.tsfn != nullptr) {
            sink.pending.push_back(call);
            status = napi_call_threadsafe_function(sink.tsfn, call, napi_tsfn_nonblocking);
            if (status == napi_ok) {
                posted = true;
            } else {
                // Not enqueued: our entry is still the last one (the lock keeps the
                // dispatch from mutating `pending` meanwhile).
                sink.pending.pop_back();
            }
        } else {
            status = napi_generic_failure;
        }
    } catch (...) {
        // Allocation failure while building/queueing the reply: the call is still ours.
        OH_LOG_ERROR(LOG_APP, "[openharmony-host] %{public}s: could not queue the synchronous call", sink.name);
    }
    if (!posted) {
        // Still ours: no dispatch or reset can have seen it (the lock covered the hand-off).
        delete call;
        return status;
    }

    // From here on the dispatcher (or a sink reset) owns the call; only the reply is shared.
    std::unique_lock<std::mutex> lock(reply->mutex);
    if (!reply->cv.wait_for(lock, std::chrono::milliseconds(kHostCallTimeoutMs), [&reply] { return reply->done; })) {
        reply->abandoned = true;
        if (bool_out != nullptr) {
            *bool_out = false;
        }
        if (int_out != nullptr) {
            *int_out = 0;
        }
        OH_LOG_WARN(LOG_APP, "[openharmony-host] %{public}s: shell callback did not answer within %{public}d ms; request failed",
                    sink.name, kHostCallTimeoutMs);
        return napi_generic_failure;
    }
    status = reply->status;
    if (bool_out != nullptr) {
        *bool_out = reply->has_bool && reply->bool_value;
    }
    if (int_out != nullptr) {
        *int_out = reply->has_int ? reply->int_value : 0;
    }
    return status;
}

// Replaces a reference slot with a fresh +1 reference, or clears it for a null value. The new
// reference is created and validated before the old one is deleted, so a failed create leaves
// the previous value in place (no half-updated slot). JS thread only.
static napi_status HostRefReplace(napi_env env, napi_ref* slot, napi_value value) {
    if (env == nullptr || slot == nullptr) {
        return napi_invalid_arg;
    }
    if (g_host->env != env || !HostIsJsThread()) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] reference update attempted off the JS thread or env, ignored");
        return napi_generic_failure;
    }
    if (value == nullptr) {
        if (*slot != nullptr) {
            napi_delete_reference(env, *slot);
            *slot = nullptr;
        }
        return napi_ok;
    }
    napi_ref created = nullptr;
    napi_status status = napi_create_reference(env, value, 1, &created);
    if (status != napi_ok || created == nullptr) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] could not create a reference (%{public}d)", (int)status);
        return status != napi_ok ? status : napi_generic_failure;
    }
    if (*slot != nullptr) {
        napi_delete_reference(env, *slot);
    }
    *slot = created;
    return napi_ok;
}

// Creates (or replaces) the sink's threadsafe function from the ArkTS callback. Runs on
// the JS thread; the previous function, if any, is aborted here and never carries over. The
// single type check for every register*Sink handler lives here: a non-function argument is
// logged and ignored, so no handler can forget it.
static void HostSinkRegister(napi_env env, HostSink& sink, napi_value function) {
    if (g_host->env != env || !HostIsJsThread()) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] %{public}s: registration attempted off the JS thread or env, ignored", sink.name);
        return;
    }
    napi_valuetype type = napi_undefined;
    if (function == nullptr || napi_typeof(env, function, &type) != napi_ok || type != napi_function) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] %{public}s: sink is not a function, ignored", sink.name);
        return;
    }
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
    } else {
        OH_LOG_INFO(LOG_APP, "[openharmony-host] %{public}s sink registered", sink.name);
    }
}

// Shared body of the register*Sink napi handlers: pulls the single callback argument and
// installs it through HostSinkRegister (the one place that type-checks and asserts the JS
// thread). Returns undefined, like every handler did.
static napi_value HostSinkRegisterFromArgs(napi_env env, napi_callback_info info, HostSink& sink) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1) {
        HostSinkRegister(env, sink, argv[0]);
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// --- per-env lifetime --------------------------------------------------------------

// Releases every threadsafe function a binding owns (and any queued call).
static void HostResetAllSinks(HostBinding& binding) {
    HostForEachSink(binding, [](HostSink& sink) { HostSinkReset(sink); });
}

static void HostEnvCleanup(void* arg);

// Tears a binding down using the env that created it: a page rebuild with a new env must never
// delete the old env's references through the new env. from_hook is set when the engine calls
// HostEnvCleanup itself (the hook entry is already gone then).
static void HostBindingTeardown(HostBindingSlot* slot, bool from_hook) {
    if (slot == nullptr || !slot->active) {
        return;
    }
    HostBinding& binding = slot->binding;
    napi_env env = binding.env;
    HostResetAllSinks(binding);
    if (env != nullptr) {
        if (binding.exports_ref != nullptr) {
            napi_delete_reference(env, binding.exports_ref);
            binding.exports_ref = nullptr;
        }
        if (binding.xcomponent_export_ref != nullptr) {
            napi_delete_reference(env, binding.xcomponent_export_ref);
            binding.xcomponent_export_ref = nullptr;
        }
    }
    binding.xcomponent = nullptr;
    {
        std::lock_guard<std::mutex> guard(binding.menu_lock);
        binding.menu_build.clear();
        binding.menu_latest.reset();
    }
    binding.menu_js.reset();
    binding.env = nullptr;
    binding.js_thread_valid = false;
    slot->active = false;
    if (!from_hook && env != nullptr && slot->hook_registered) {
        napi_remove_env_cleanup_hook(env, HostEnvCleanup, slot);
    }
    slot->hook_registered = false;
    if (g_host == &binding) {
        g_host = &g_binding_slots[0].binding;
    }
    OH_LOG_INFO(LOG_APP, "[openharmony-host] binding for env %{public}p torn down", (void*)env);
}

// The env is going away: release the binding it owns and drop every napi object with it.
static void HostEnvCleanup(void* arg) {
    HostBindingTeardown(static_cast<HostBindingSlot*>(arg), true);
}

// Returns the binding for env, creating (and claiming a slot for) it when Init runs for a new
// env. Init re-entering with the same env reuses the binding and keeps its sinks; a different
// env first tears the previous bindings down with their own env.
static HostBinding* HostEnsureBinding(napi_env env) {
    if (env == nullptr) {
        return g_host;
    }
    HostBinding* existing = HostBindingFor(env);
    if (existing != nullptr) {
        g_host = existing;
        return g_host;
    }
    for (int i = 0; i < kHostBindingSlotCount; i++) {
        if (g_binding_slots[i].active) {
            HostBindingTeardown(&g_binding_slots[i], false);
        }
    }
    HostBindingSlot* slot = nullptr;
    for (int i = 0; i < kHostBindingSlotCount; i++) {
        if (!g_binding_slots[i].active) {
            slot = &g_binding_slots[i];
            break;
        }
    }
    if (slot == nullptr) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] Init with a new env while all bindings are live");
        return g_host;
    }
    slot->binding.env = env;
    slot->binding.js_thread = pthread_self();
    slot->binding.js_thread_valid = true;
    slot->active = true;
    if (!slot->hook_registered) {
        napi_status hook = napi_add_env_cleanup_hook(env, HostEnvCleanup, slot);
        if (hook == napi_ok) {
            slot->hook_registered = true;
        } else {
            OH_LOG_WARN(LOG_APP, "[openharmony-host] could not register the env cleanup hook (%{public}d)", (int)hook);
        }
    }
    g_host = &slot->binding;
    return g_host;
}

// Thin wrapper for the managed-facing C exports that allocate: a C++ exception is flattened
// into a logged failure instead of unwinding into the P/Invoke frame.
template <typename F>
static int HostCxxBoundary(const char* where, F&& body) {
    try {
        return body();
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "[openharmony-host] %{public}s: native exception: %{public}s", where, e.what());
    } catch (...) {
        OH_LOG_ERROR(LOG_APP, "[openharmony-host] %{public}s: native exception (unknown)", where);
    }
    return -1;
}

// Same boundary for the void exports and the host-core callbacks: the notification is dropped
// and logged instead of unwinding through a C frame.
template <typename F>
static void HostCxxBoundaryVoid(const char* where, F&& body) {
    try {
        body();
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "[openharmony-host] %{public}s: native exception: %{public}s", where, e.what());
    } catch (...) {
        OH_LOG_ERROR(LOG_APP, "[openharmony-host] %{public}s: native exception (unknown)", where);
    }
}

// The unified NAPI entry boundary. Init rewrites every exported method in the property table to
// point here, with the real handler carried in the descriptor's data field: a C++ exception
// thrown while a handler builds its arguments must not unwind through the engine's C frame, so
// it is caught here and surfaced as a JS exception instead.
static napi_value HostNapiEntry(napi_env env, napi_callback_info info) {
    void* data = nullptr;
    napi_value this_arg = nullptr;
    napi_value argv[1] = {nullptr};
    size_t argc = 1;
    if (env == nullptr || napi_get_cb_info(env, info, &argc, argv, &this_arg, &data) != napi_ok ||
        data == nullptr) {
        if (env != nullptr) {
            napi_throw_error(env, nullptr, "host: entry point is not bound");
        }
        return nullptr;
    }
    napi_callback handler = reinterpret_cast<napi_callback>(data);
    try {
        return handler(env, info);
    } catch (const std::exception& e) {
        HostClearPendingException(env, "host entry");
        OH_LOG_ERROR(LOG_APP, "[openharmony-host] host entry: native exception: %{public}s", e.what());
        napi_throw_error(env, nullptr, e.what());
    } catch (...) {
        HostClearPendingException(env, "host entry");
        OH_LOG_ERROR(LOG_APP, "[openharmony-host] host entry: native exception (unknown)");
        napi_throw_error(env, nullptr, "host: native exception");
    }
    return nullptr;
}


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

// Finalizer for the borrowed OH_NativeXComponent behind the JS wrapper: napi_unwrap hands out
// the framework's pointer, and the wrapper's own lifetime can end while this binding still
// stores it (a page rebuild releases the old xcomponent_export_ref; the object may then be
// collected at any time). The finalizer is armed per wrapper with finalize_data = the raw
// pointer and finalize_hint = the binding (static storage, valid even after teardown), so a
// late finalizer from a replaced page compares against the new pointer and leaves it alone.
static void HostXComponentWrapperFinalized(napi_env env, void* data, void* hint) {
    (void)env;
    HostBinding* binding = static_cast<HostBinding*>(hint);
    OH_NativeXComponent* component = reinterpret_cast<OH_NativeXComponent*>(data);
    if (binding != nullptr && binding->xcomponent == component) {
        binding->xcomponent = nullptr;
        OH_LOG_WARN(LOG_APP, "[openharmony-host] xcomponent wrapper collected: borrowed pointer cleared");
    }
}

// The framework exposes the native XComponent through the module exports
// (OH_NATIVE_XCOMPONENT_OBJ) when the page uses <XComponent libraryname="...">.
void TryRegisterXComponent() {
    HostBinding* binding = g_host;
    if (binding->env == nullptr || binding->exports_ref == nullptr || binding->xcomponent != nullptr) {
        return;
    }
    if (!HostIsJsThread()) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] registerXComponent: not on the JS thread, ignored");
        return;
    }
    napi_env env = binding->env;
    napi_value exports = nullptr;
    if (napi_get_reference_value(env, binding->exports_ref, &exports) != napi_ok || exports == nullptr) {
        return;
    }
    napi_value exportInstance = nullptr;
    if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &exportInstance) != napi_ok) {
        return;
    }
    void* native = nullptr;
    if (napi_unwrap(env, exportInstance, &native) != napi_ok || native == nullptr) {
        return;
    }
    // Keep the JS object that owns the native XComponent alive for the binding's lifetime: a
    // collected wrapper would leave the raw pointer below dangling. The reference is released
    // by HostBindingTeardown (a page rebuild re-binds it to the new env's object).
    if (HostRefReplace(env, &binding->xcomponent_export_ref, exportInstance) != napi_ok) {
        return;
    }
    binding->xcomponent = reinterpret_cast<OH_NativeXComponent*>(native);
    // Arm the wrapper finalizer now that the binding stores the borrowed pointer (see
    // HostXComponentWrapperFinalized). A failure only costs the late-clear safety net.
    if (napi_add_finalizer(env, exportInstance, native, HostXComponentWrapperFinalized, binding,
                           nullptr) != napi_ok) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] xcomponent wrapper finalizer could not be armed");
    }
    static OH_NativeXComponent_Callback callback = {
        .OnSurfaceCreated = OnSurfaceCreated,
        .OnSurfaceChanged = OnSurfaceChanged,
        .OnSurfaceDestroyed = OnSurfaceDestroyed,
        .DispatchTouchEvent = OnTouch,
    };
    static OH_NativeXComponent_MouseEvent_Callback mouseCallback = {
        .DispatchMouseEvent = OnMouse,
        .DispatchHoverEvent = nullptr,
    };
    if (OH_NativeXComponent_RegisterCallback(binding->xcomponent, &callback) != 0) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] RegisterCallback failed");
        binding->xcomponent = nullptr;
        return;
    }
    OH_NativeXComponent_RegisterMouseEventCallback(binding->xcomponent, &mouseCallback);
    OH_NativeXComponent_RegisterOnFrameCallback(binding->xcomponent, OnFrame);
    char id[128] = {0};
    uint64_t size = sizeof(id);
    if (OH_NativeXComponent_GetXComponentId(binding->xcomponent, id, &size) == 0) {
        OH_LOG_INFO(LOG_APP, "[openharmony-host] xcomponent '%{public}s' registered (touch+frame)", id);
    }
}

std::string GetStringArg(napi_env env, napi_value value);

// (sink moved into the current HostBinding; see the g_* accessors above)

// Called by the host core (managed side) to run a HUKS operation in the ArkTS shell.
void OnKeystoreRequest(int requestId, const char* op, const char* alias, const char* dataBase64) {
    HostCxxBoundaryVoid("keystore request", [&] {
        SinkCall* call = new SinkCall();
        call->AddInt(requestId);
        call->AddString(op);
        call->AddString(alias);
        call->AddString(dataBase64);
        HostSinkPost(g_keystore_sink, call);
    });
}

// ArkTS calls host.registerKeystoreSink(fn) to receive keystore requests.
// (sink moved into the current HostBinding; see the g_* accessors above)

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
    HostCxxBoundaryVoid("notification", [&] {
        SinkCall* call = new SinkCall();
        call->AddInt(id);
        call->AddString(title);
        call->AddString(text);
        HostSinkPost(g_notification_sink, call);
    });
}

// ArkTS calls host.registerNotificationSink(fn) to publish notifications.
napi_value RegisterNotificationSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_notification_sink);
}

// TextToSpeech: the managed side forwards speak requests through ohos_host_tts_speak; the
// ArkTS shell's sink (registerTtsSink) owns the Speech Kit call and answers with
// host.notifyTtsResult(requestId, code).
// (sink moved into the current HostBinding; see the g_* accessors above)
static std::atomic<void (*)(int, int)> g_tts_result_listener{nullptr};

// Called from the host C layer (managed P/Invoke): forwards a speak request to ArkTS.
extern "C" int ohos_host_tts_speak(int request_id, const char* text, const char* locale) {
    return HostCxxBoundary("tts speak", [&] {
        SinkCall* call = new SinkCall();
        call->AddInt(request_id);
        call->AddString(text);
        call->AddString(locale);
        return HostSinkPost(g_tts_sink, call) ? 0 : -1;
    });
}

// The managed side registers the callback that completes a pending speak request.
extern "C" void ohos_host_tts_register_result(void* callback) {
    HostListenerStore(g_tts_result_listener, callback);
}

// Called by the NAPI notify below: hands the shell's answer back to managed code.
extern "C" void ohos_host_tts_result(int request_id, int code) {
    auto listener = HostListenerLoad(g_tts_result_listener);
    if (listener != nullptr) {
        listener(request_id, code);
    }
}

// ArkTS calls host.registerTtsSink(fn) to receive speak requests.
napi_value RegisterTtsSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_tts_sink);
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

// HMS Kits (Share/Scan; KIT-IMPL 2026-09-25). Both sinks exist only when the ArkTS shell's
// runtime provides the kit: the default OpenHarmony SDK build registers neither (the shell's
// variable-specifier import() probe fails and the failure is cached), so every export below
// answers "unavailable" and the managed side keeps its documented degradation. On an HMS device
// (the ARKTS_SDK_FLAVOR=harmony shell) the probe resolves, the sink registers and the calls
// reach systemShare / scanBarcode.
//
// Share (multi-file): ohos_host_share_kit_share hands the '\n'-separated file:// URI list and
// the optional title to the shell sink, which builds systemShare.SharedData/ShareController and
// calls show(); the sink's synchronous boolean answer (dispatched or not) is consumed through
// HostCallJs, the same shape as the ability sink. No result round-trip: MAUI's IShare contract
// completes when the request is handed to the platform.
static std::atomic<void (*)(int, int, const char*)> g_scan_result_listener{nullptr};

// Called from managed code (P/Invoke): forwards a multi-file share to the ArkTS shell sink.
// Returns 0 when the sink accepted (dispatched), -1 when it is unregistered or the dispatch
// failed (the managed side then reports the once-per-process Share Kit note).
extern "C" int ohos_host_share_kit_share(const char* uris, const char* title) {
    if (uris == nullptr || uris[0] == '\0' || !ControlStringFits(uris, "share_kit_uris")) {
        return -1;
    }
    if (title != nullptr && !ControlStringFits(title, "share_kit_title")) {
        return -1;
    }
    return HostCxxBoundary("share_kit_share", [uris, title] {
        SinkCall* call = new SinkCall();
        call->AddString(uris, kMaxControlBytes);
        call->AddString(title != nullptr ? title : "", kMaxControlBytes);
        bool handled = false;
        napi_status status = HostCallJs(g_share_kit_sink, call, &handled, nullptr);
        return status == napi_ok && handled ? 0 : -1;
    });
}

// ArkTS calls host.registerShareKitSink(fn) when the Share Kit probe succeeded.
napi_value RegisterShareKitSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_share_kit_sink);
}

// Scan (default UI): the scan is asynchronous (the user scans in the system UI), so it follows
// the TTS shape. ohos_host_scan_request(request_id) queues the request; the shell answers with
// host.notifyScanResult(requestId, code, value), which lands in the callback registered by
// ohos_host_scan_register_result. rc: 0 success (value = result.originalValue), -1 unavailable
// or failed, -2 the user cancelled (Scan Kit error 1000500002).
extern "C" int ohos_host_scan_request(int request_id) {
    return HostCxxBoundary("scan request", [&] {
        SinkCall* call = new SinkCall();
        call->AddInt(request_id);
        return HostSinkPost(g_scan_sink, call) ? 0 : -1;
    });
}

// 1 when the ArkTS shell registered the scan sink (the managed OpenHarmonyScan.IsSupported
// probe: it must not launch the scanner just to answer availability).
extern "C" int ohos_host_scan_available(void) {
    return g_scan_sink.tsfn != nullptr ? 1 : 0;
}

// The managed side registers the callback that completes a pending scan request.
extern "C" void ohos_host_scan_register_result(void* callback) {
    HostListenerStore(g_scan_result_listener, callback);
}

// Called by the NAPI notify below: hands the shell's answer back to managed code. value is NULL
// for a non-zero rc and delivered as "".
extern "C" void ohos_host_scan_result(int request_id, int code, const char* value) {
    auto listener = HostListenerLoad(g_scan_result_listener);
    if (listener != nullptr) {
        listener(request_id, code, value != nullptr ? value : "");
    }
}

// ArkTS calls host.registerScanSink(fn) when the Scan Kit probe succeeded.
napi_value RegisterScanSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_scan_sink);
}

// ArkTS calls host.notifyScanResult(requestId, code, value) when the scan finished/cancelled.
napi_value NotifyScanResult(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int requestId = 0;
    int code = -1;
    std::string value;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &requestId);
    }
    if (argc >= 2) {
        napi_get_value_int32(env, argv[1], &code);
    }
    if (argc >= 3) {
        value = GetStringArg(env, argv[2]);
    }
    ohos_host_scan_result(requestId, code, value.c_str());
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// HMS Kits (Push/Account/Map; KIT-EXT2 2026-09-25; Map overlay R2-3 2026-09-26). Same shape as
// Share/Scan: each sink exists only when the ArkTS shell's runtime provides the kit, so the
// default OpenHarmony SDK build registers none, every export answers "unavailable" and the
// managed side keeps its documented degradation. Push and Account are asynchronous (the user may
// be shown UI / the AGC call may take time), so they follow the TTS/Scan shape: the managed side
// queues a request id, the shell answers through host.notifyPushResult/host.notifyAccountResult.
// Map: op 0 is the capability probe (bit 0 = @kit.MapKit resolved, bit 1 = the shell's overlay
// module resolved, which needs the HarmonyOS flavor build); ops 1..6 drive the optional
// MapComponent overlay (create/destroy/show/hide/set region/add marker) and the shell also pushes
// unsolicited overlay events with request id 0 (ready / marker click / camera idle). All Map
// answers and events travel through host.notifyMapResult, so the export set stays at four.
//
// Push: op 0 getToken (rc 0 + token), op 1 deleteToken (rc 0). rc -1 = unavailable, a positive
// rc = the Push Kit BusinessError code (1000900010/1000900012, ...). Account: op 0 quick-login
// anonymous phone, op 1 authorize the '\n'-separated scopes (rc 0 + payload, -1 unavailable or
// state mismatch, positive = the Account Kit BusinessError code). Map: see the header
// documentation for the op/answer map.
static std::atomic<void (*)(int, int, int, const char*)> g_push_result_listener{nullptr};
static std::atomic<void (*)(int, int, int, const char*)> g_account_result_listener{nullptr};
static std::atomic<void (*)(int, int, int, const char*)> g_map_result_listener{nullptr};

// Called from managed code (P/Invoke): 1 when the shell registered the Push sink. The managed
// OpenHarmonyPush.IsSupported probe must not trigger a token request just to answer.
extern "C" int ohos_host_push_available(void) {
    return g_push_sink.tsfn != nullptr ? 1 : 0;
}

// Called from managed code (P/Invoke): queues one Push operation. 0 queued, -1 when the sink is
// unregistered (the answer then never arrives and the managed side reports unavailable).
extern "C" int ohos_host_push_request(int request_id, int op) {
    return HostCxxBoundary("push request", [&] {
        SinkCall* call = new SinkCall();
        call->AddInt(request_id);
        call->AddInt(op);
        return HostSinkPost(g_push_sink, call) ? 0 : -1;
    });
}

// The managed side registers the callback that completes a pending push request.
extern "C" void ohos_host_push_register_result(void* callback) {
    HostListenerStore(g_push_result_listener, callback);
}

// Called by the NAPI notify below: hands the shell's answer back to managed code. token is "" for
// a non-zero rc.
extern "C" void ohos_host_push_result(int request_id, int op, int code, const char* token) {
    auto listener = HostListenerLoad(g_push_result_listener);
    if (listener != nullptr) {
        listener(request_id, op, code, token != nullptr ? token : "");
    }
}

// ArkTS calls host.registerPushSink(fn) when the Push Kit probe succeeded.
napi_value RegisterPushSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_push_sink);
}

// ArkTS calls host.notifyPushResult(requestId, op, code, token) when the call finished.
napi_value NotifyPushResult(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int requestId = 0;
    int op = 0;
    int code = -1;
    std::string token;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &requestId);
    }
    if (argc >= 2) {
        napi_get_value_int32(env, argv[1], &op);
    }
    if (argc >= 3) {
        napi_get_value_int32(env, argv[2], &code);
    }
    if (argc >= 4) {
        token = GetStringArg(env, argv[3]);
    }
    ohos_host_push_result(requestId, op, code, token.c_str());
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Called from managed code (P/Invoke): 1 when the shell registered the Account sink.
extern "C" int ohos_host_account_available(void) {
    return g_account_sink.tsfn != nullptr ? 1 : 0;
}

// Called from managed code (P/Invoke): queues one Account operation with its '\n'-separated
// scope list (empty for op 0, which fixes quickLoginAnonymousPhone in the shell). 0 queued, -1
// when the sink is unregistered or the scope string exceeds the control-string cap.
extern "C" int ohos_host_account_request(int request_id, int op, const char* scopes) {
    return HostCxxBoundary("account request", [&] {
        if (scopes != nullptr && !ControlStringFits(scopes, "account_scopes")) {
            return -1;
        }
        SinkCall* call = new SinkCall();
        call->AddInt(request_id);
        call->AddInt(op);
        call->AddString(scopes != nullptr ? scopes : "", kMaxControlBytes);
        return HostSinkPost(g_account_sink, call) ? 0 : -1;
    });
}

// The managed side registers the callback that completes a pending account request.
extern "C" void ohos_host_account_register_result(void* callback) {
    HostListenerStore(g_account_result_listener, callback);
}

// Called by the NAPI notify below: payload is "" for a non-zero rc.
extern "C" void ohos_host_account_result(int request_id, int op, int code, const char* payload) {
    auto listener = HostListenerLoad(g_account_result_listener);
    if (listener != nullptr) {
        listener(request_id, op, code, payload != nullptr ? payload : "");
    }
}

// ArkTS calls host.registerAccountSink(fn) when the Account Kit probe succeeded.
napi_value RegisterAccountSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_account_sink);
}

// ArkTS calls host.notifyAccountResult(requestId, op, code, payload) when the request finished.
napi_value NotifyAccountResult(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int requestId = 0;
    int op = 0;
    int code = -1;
    std::string payload;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &requestId);
    }
    if (argc >= 2) {
        napi_get_value_int32(env, argv[1], &op);
    }
    if (argc >= 3) {
        napi_get_value_int32(env, argv[2], &code);
    }
    if (argc >= 4) {
        payload = GetStringArg(env, argv[3]);
    }
    ohos_host_account_result(requestId, op, code, payload.c_str());
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Called from managed code (P/Invoke): 1 when the shell registered the Map sink.
extern "C" int ohos_host_map_available(void) {
    return g_map_sink.tsfn != nullptr ? 1 : 0;
}

// Called from managed code (P/Invoke): queues one Map command (op + JSON args; see the header
// for the op map). 0 queued, -1 when the sink is unregistered or the args string exceeds the
// control-string cap.
extern "C" int ohos_host_map_command(int request_id, int op, const char* args) {
    return HostCxxBoundary("map command", [&] {
        if (args != nullptr && !ControlStringFits(args, "map_args")) {
            return -1;
        }
        SinkCall* call = new SinkCall();
        call->AddInt(request_id);
        call->AddInt(op);
        call->AddString(args != nullptr ? args : "", kMaxControlBytes);
        return HostSinkPost(g_map_sink, call) ? 0 : -1;
    });
}

// The managed side registers the callback that completes a pending map command and receives the
// unsolicited overlay events (request_id 0).
extern "C" void ohos_host_map_register_result(void* callback) {
    HostListenerStore(g_map_result_listener, callback);
}

// Called by the NAPI notify below: hands one answer/event back to managed code. payload is ""
// for a non-zero code (answers) and for the ready event.
extern "C" void ohos_host_map_result(int request_id, int op, int code, const char* payload) {
    auto listener = HostListenerLoad(g_map_result_listener);
    if (listener != nullptr) {
        listener(request_id, op, code, payload != nullptr ? payload : "");
    }
}

// ArkTS calls host.registerMapSink(fn) when the Map Kit probe succeeded.
napi_value RegisterMapSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_map_sink);
}

// ArkTS calls host.notifyMapResult(requestId, op, code, payload) when a command finished or the
// overlay raised an event (requestId 0).
napi_value NotifyMapResult(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int requestId = 0;
    int op = 0;
    int code = -1;
    std::string payload;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &requestId);
    }
    if (argc >= 2) {
        napi_get_value_int32(env, argv[1], &op);
    }
    if (argc >= 3) {
        napi_get_value_int32(env, argv[2], &code);
    }
    if (argc >= 4) {
        payload = GetStringArg(env, argv[3]);
    }
    ohos_host_map_result(requestId, op, code, payload.c_str());
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// HMS Live View Kit (R2-SHELL-EXT 2026-09-26): the third kit probe batch, same shape as
// Push/Account. The sink exists only when the ArkTS shell's runtime passes the
// SystemCapability.LiveView.LiveViewService check and resolves @kit.LiveViewKit, so the default
// OpenHarmony SDK build registers nothing, every export answers "unavailable" and the managed
// OpenHarmonyLiveView keeps its documented degradation.
//
// op 0 create / op 1 update / op 2 stop, args is the JSON payload the shell parses
// ({"id","title","text","progress","time"} for 0/1, {"id"} for 2). The answer arrives through
// host.notifyLiveViewResult -> ohos_host_liveview_result: code 0 applied, -1 unavailable (no
// kit/sink or no view the shell owns), -2 the kit call failed or the args were malformed, -3 the
// user's live view switch is off (isLiveViewEnabled false), a positive value is the Live View
// Kit BusinessError code (1003500004 switch, 1003500005 entitlement, ...).
static std::atomic<void (*)(int, int, int, const char*)> g_liveview_result_listener{nullptr};

// Called from managed code (P/Invoke): 1 when the shell registered the Live View sink. The
// managed OpenHarmonyLiveView.IsSupported probe must not call the kit just to answer.
extern "C" int ohos_host_liveview_available(void) {
    return g_liveview_sink.tsfn != nullptr ? 1 : 0;
}

// Called from managed code (P/Invoke): queues one Live View operation. 0 queued, -1 when the
// sink is unregistered or the args string exceeds the control-string cap.
extern "C" int ohos_host_liveview_request(int request_id, int op, const char* args) {
    return HostCxxBoundary("live view request", [&] {
        if (args != nullptr && !ControlStringFits(args, "liveview_args")) {
            return -1;
        }
        SinkCall* call = new SinkCall();
        call->AddInt(request_id);
        call->AddInt(op);
        call->AddString(args != nullptr ? args : "", kMaxControlBytes);
        return HostSinkPost(g_liveview_sink, call) ? 0 : -1;
    });
}

// The managed side registers the callback that completes a pending live view request.
extern "C" void ohos_host_liveview_register_result(void* callback) {
    HostListenerStore(g_liveview_result_listener, callback);
}

// Called by the NAPI notify below: payload is "" for a non-zero code.
extern "C" void ohos_host_liveview_result(int request_id, int op, int code, const char* payload) {
    auto listener = HostListenerLoad(g_liveview_result_listener);
    if (listener != nullptr) {
        listener(request_id, op, code, payload != nullptr ? payload : "");
    }
}

// ArkTS calls host.registerLiveViewSink(fn) when the Live View probe succeeded.
napi_value RegisterLiveViewSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_liveview_sink);
}

// ArkTS calls host.notifyLiveViewResult(requestId, op, code, payload) when an operation finished.
napi_value NotifyLiveViewResult(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int requestId = 0;
    int op = 0;
    int code = -1;
    std::string payload;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &requestId);
    }
    if (argc >= 2) {
        napi_get_value_int32(env, argv[1], &op);
    }
    if (argc >= 3) {
        napi_get_value_int32(env, argv[2], &code);
    }
    if (argc >= 4) {
        payload = GetStringArg(env, argv[3]);
    }
    ohos_host_liveview_result(requestId, op, code, payload.c_str());
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
// (sink moved into the current HostBinding; see the g_* accessors above)
// (sink moved into the current HostBinding; see the g_* accessors above)
static std::atomic<void (*)(int, int, const char*)> g_contacts_result_listener{nullptr};
static std::atomic<void (*)(int, int, const char*)> g_calendar_result_listener{nullptr};

// Called from managed code (P/Invoke): forwards a name-prefix lookup (limit caps the number of
// returned rows) to the ArkTS sink; returns 0 when it was dispatched.
extern "C" int ohos_host_contacts_query(int request_id, const char* name_prefix, int limit) {
    return HostCxxBoundary("contacts query", [&] {
        SinkCall* call = new SinkCall();
        call->AddInt(request_id);
        call->AddString(name_prefix);
        call->AddInt(limit);
        return HostSinkPost(g_contacts_sink, call) ? 0 : -1;
    });
}

// The managed side registers the callback that completes a pending contacts request.
extern "C" void ohos_host_contacts_register_result(void* callback) {
    HostListenerStore(g_contacts_result_listener, callback);
}

// Called by the NAPI notify below: hands the shell's answer back to managed code.
extern "C" void ohos_host_contacts_result(int request_id, int code, const char* payload) {
    auto listener = HostListenerLoad(g_contacts_result_listener);
    if (listener != nullptr) {
        listener(request_id, code, payload != nullptr ? payload : "");
    }
}

// ArkTS calls host.registerContactsSink(fn) to receive contacts lookups.
napi_value RegisterContactsSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_contacts_sink);
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
    return HostCxxBoundary("calendar sink", [&] {
        SinkCall* call = new SinkCall();
        call->AddInt(request_id);
        call->AddInt(op);
        call->AddString(arg1);
        call->AddString(arg2);
        call->AddString(arg3);
        return HostSinkPost(g_calendar_sink, call) ? 0 : -1;
    });
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
    HostListenerStore(g_calendar_result_listener, callback);
}

// Called by the NAPI notify below: hands the shell's answer back to managed code.
extern "C" void ohos_host_calendar_result(int request_id, int code, const char* payload) {
    auto listener = HostListenerLoad(g_calendar_result_listener);
    if (listener != nullptr) {
        listener(request_id, code, payload != nullptr ? payload : "");
    }
}

// ArkTS calls host.registerCalendarSink(fn) to receive calendar list/add requests.
napi_value RegisterCalendarSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_calendar_sink);
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
// (sink moved into the current HostBinding; see the g_* accessors above)
static std::atomic<void (*)(int, int, const char*)> g_bluetooth_result_listener{nullptr};

// Called from managed code (P/Invoke): forwards a Bluetooth operation to the ArkTS sink;
// returns 0 when it was dispatched.
extern "C" int ohos_host_bluetooth_query(int request_id, int op) {
    return HostCxxBoundary("bluetooth query", [&] {
        SinkCall* call = new SinkCall();
        call->AddInt(request_id);
        call->AddInt(op);
        return HostSinkPost(g_bluetooth_sink, call) ? 0 : -1;
    });
}

// The managed side registers the callback that completes a pending Bluetooth request.
extern "C" void ohos_host_bluetooth_register_result(void* callback) {
    HostListenerStore(g_bluetooth_result_listener, callback);
}

// Called by the NAPI notify below: hands the shell's answer back to managed code.
extern "C" void ohos_host_bluetooth_result(int request_id, int code, const char* payload) {
    auto listener = HostListenerLoad(g_bluetooth_result_listener);
    if (listener != nullptr) {
        listener(request_id, code, payload != nullptr ? payload : "");
    }
}

// ArkTS calls host.registerBluetoothSink(fn) to receive Bluetooth requests.
napi_value RegisterBluetoothSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_bluetooth_sink);
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
static std::atomic<void (*)(const char*)> g_bluetooth_device_listener{nullptr};

extern "C" void ohos_host_bluetooth_register_device_found(void* callback) {
    HostListenerStore(g_bluetooth_device_listener, callback);
}

extern "C" void ohos_host_bluetooth_device_found(const char* payload) {
    auto listener = HostListenerLoad(g_bluetooth_device_listener);
    if (listener != nullptr) {
        listener(payload != nullptr ? payload : "");
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
// (sink moved into the current HostBinding; see the g_* accessors above)
static std::atomic<void (*)(int, int, const char*)> g_bluetooth_gatt_result_listener{nullptr};
static std::atomic<void (*)(const char*)> g_bluetooth_gatt_event_listener{nullptr};

// Called from managed code (P/Invoke): forwards a GATT operation to the ArkTS sink; returns 0
// when it was dispatched, -1 when there is no sink (or the payload was dropped).
extern "C" int ohos_host_bluetooth_gatt_request(int request_id, int op, const char* payload) {
    return HostCxxBoundary("bluetooth gatt request", [&] {
        SinkCall* call = new SinkCall();
        call->AddInt(request_id);
        call->AddInt(op);
        call->AddString(payload);
        if (!HostSinkPost(g_bluetooth_gatt_sink, call)) {
            OH_LOG_WARN(LOG_APP, "[openharmony-host] bluetooth gatt: request dropped (no shell sink or over-long payload)");
            return -1;
        }
        return 0;
    });
}

// The managed side registers the callback that completes a pending GATT request.
extern "C" void ohos_host_bluetooth_gatt_register_result(void* callback) {
    HostListenerStore(g_bluetooth_gatt_result_listener, callback);
}

// Called by the NAPI notify below: hands the shell's answer back to managed code. The listener
// is invoked outside any sink lock (HostSinkPost/HostSinkDispatch never call back under one).
extern "C" void ohos_host_bluetooth_gatt_result(int request_id, int code, const char* payload) {
    auto listener = HostListenerLoad(g_bluetooth_gatt_result_listener);
    if (listener != nullptr) {
        listener(request_id, code, payload != nullptr ? payload : "");
    }
}

// The managed side registers the callback that receives the unsolicited device events.
extern "C" void ohos_host_bluetooth_gatt_register_event(void* callback) {
    HostListenerStore(g_bluetooth_gatt_event_listener, callback);
}

// Called by the NAPI notify below: pushes one device event (value change / connection state /
// MTU) to managed code, NULL-safe.
extern "C" void ohos_host_bluetooth_gatt_event(const char* payload) {
    auto listener = HostListenerLoad(g_bluetooth_gatt_event_listener);
    if (listener != nullptr) {
        listener(payload != nullptr ? payload : "");
    }
}

// ArkTS calls host.registerBluetoothGattSink(fn) to receive GATT requests.
napi_value RegisterBluetoothGattSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_bluetooth_gatt_sink);
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
// (sink moved into the current HostBinding; see the g_* accessors above)
static std::atomic<void (*)(int, int, const char*)> g_print_result_listener{nullptr};

// Called from managed code (P/Invoke): forwards a print file path to the ArkTS sink.
extern "C" int ohos_host_print_file(int request_id, const char* path) {
    return HostCxxBoundary("print file", [&] {
        SinkCall* call = new SinkCall();
        call->AddInt(request_id);
        call->AddString(path);
        return HostSinkPost(g_print_sink, call) ? 0 : -1;
    });
}

// The managed side registers the callback that completes a pending print request.
extern "C" void ohos_host_print_register_result(void* callback) {
    HostListenerStore(g_print_result_listener, callback);
}

// Called by the NAPI notify below: hands the shell's answer back to managed code.
extern "C" void ohos_host_print_result(int request_id, int code, const char* message) {
    auto listener = HostListenerLoad(g_print_result_listener);
    if (listener != nullptr) {
        listener(request_id, code, message != nullptr ? message : "");
    }
}

// ArkTS calls host.registerPrintSink(fn) to receive print requests.
napi_value RegisterPrintSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_print_sink);
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
// This sink answers the managed side synchronously: the shell callback returns true when it
// dispatched (or, for the probe, the target is available). The answer travels through the
// TSFN reply (HostCallJs), so the napi call still runs on the JS thread; the old direct
// napi_call_function from the .NET thread was a cross-thread napi use.

// Flags for ohos_host_ability_start_ex: bit 0 is FLAG_AUTH_READ_URI_PERMISSION (the shell asks
// the ability manager to grant the receiver read access to a file:// uri); the host forwards
// the bits as-is.
//
// Synchronous implementation shared by the three- and five-argument exports (the fifth is the
// optional title; NULL/"" keeps the previous shape, and the shell only adds
// wantConstant.Params.CONTENT_TITLE_KEY for a non-empty title).
static int AbilityStartInternal(int kind, const char* uri, const char* text, const char* title, int flags) {
    if (title != nullptr && !ControlStringFits(title, "ability_start_title")) {
        return -1;
    }
    return HostCxxBoundary("ability_start", [kind, uri, text, title, flags] {
        SinkCall* call = new SinkCall();
        call->AddInt(kind);
        call->AddString(uri != nullptr ? uri : "");
        call->AddString(text != nullptr ? text : "");
        call->AddString(title != nullptr ? title : "", kMaxControlBytes);
        call->AddInt(flags);
        bool handled = false;
        napi_status status = HostCallJs(g_host->ability, call, &handled, nullptr);
        return status == napi_ok && handled ? 0 : -1;
    });
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
    return HostSinkRegisterFromArgs(env, info, g_host->ability);
}

// Flashlight (Camera Kit torch): the managed side calls ohos_host_flashlight_set(on) and
// receives the ArkTS shell's boolean answer. on 0 = torch off, 1 = torch on, 2 = support
// probe (isTorchSupported only, no torch call). The shell's registerFlashlightSink handler
// creates/caches the camera manager (camera.getCameraManager), checks isTorchSupported and
// calls setTorchMode(camera.TorchMode.ON/OFF); setTorchMode is synchronous and throws on
// failure, so the callback answers whether the kit accepted the request.
//
// Like the ability sink above, this one answers synchronously through HostCallJs: the managed
// side consumes the boolean answer (IFlashlight.IsSupportedAsync and the turn-on/off result)
// while the shell callback still runs on the JS thread. The shell callback catches its own
// errors; a missing sink or a non-boolean answer is reported as "not handled".

// Called from managed code (P/Invoke): asks the ArkTS shell to set or probe the torch.
// Returns 0 when the sink answered true, -1 when no sink is registered, the call failed or
// the answer was false.
extern "C" int ohos_host_flashlight_set(int on) {
    return HostCxxBoundary("flashlight_set", [on] {
        SinkCall* call = new SinkCall();
        call->AddInt(on);
        bool handled = false;
        napi_status status = HostCallJs(g_host->flashlight, call, &handled, nullptr);
        return status == napi_ok && handled ? 0 : -1;
    });
}

// ArkTS calls host.registerFlashlightSink(fn) to receive torch set/probe requests.
napi_value RegisterFlashlightSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_host->flashlight);
}

// Focus: the managed side (VisualElement.Focus()/Unfocus() on the text handlers) asks the
// ArkTS shell to hand ArkUI focus to a target id through ohos_host_request_focus; the shell's
// registerFocusSink handler calls focusControl.requestFocus(id) and answers whether it did.
// Synchronous through HostCallJs, like the ability/flashlight sinks: the managed side consumes
// the boolean answer while the shell callback runs on the JS thread. The target id is a control
// string: a NULL/empty/over-cap id is rejected before the call.
extern "C" int ohos_host_request_focus(const char* target_id) {
    if (target_id == nullptr || target_id[0] == '\0' || !ControlStringFits(target_id, "request_focus")) {
        return -1;
    }
    return HostCxxBoundary("request_focus", [target_id] {
        SinkCall* call = new SinkCall();
        call->AddString(target_id, kMaxControlBytes);
        bool handled = false;
        napi_status status = HostCallJs(g_host->focus, call, &handled, nullptr);
        return status == napi_ok && handled ? 0 : -1;
    });
}

// ArkTS calls host.registerFocusSink(fn) to receive focus requests.
napi_value RegisterFocusSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_host->focus);
}

// Menus: the managed side publishes the current page's menu items as a flat table
// (ohos_host_menu_begin/item/commit). commit copies the builder into an immutable snapshot and
// hands that snapshot to the JS thread through the menu sink, so the shell's pull
// (menuCount/menuItem) always serves a fixed value instead of a table being rewritten under it.
// The ArkTS shell pulls it back after registerMenuChangedSink fires (count, also sent for an
// empty table so the menu hides) and reports a tap with host.notifyMenuAction(index) -> the
// managed activation callback. The table carries text/enabled only: nested MenuFlyoutSubItems
// are flattened by the managed publisher, which drops the depth information because this table
// has no column for it.
static std::atomic<void (*)(int)> g_menu_action_listener{nullptr};

// The snapshot the JS thread serves from: the one the newest dispatch delivered, or the last
// published one when the shell pulls before any delivery. menu_js is JS-thread-only; the
// fallback copies menu_latest under the lock, so the pull never touches the builder.
static std::shared_ptr<const HostMenuSnapshot> HostMenuSnapshotForJs() {
    HostBinding* binding = g_host;
    if (binding->menu_js) {
        return binding->menu_js;
    }
    std::lock_guard<std::mutex> guard(binding->menu_lock);
    return binding->menu_latest;
}

// ArkTS calls host.menuCount() to size its @State array.
napi_value MenuCount(napi_env env, napi_callback_info info) {
    (void)info;
    const std::shared_ptr<const HostMenuSnapshot> snapshot = HostMenuSnapshotForJs();
    napi_value result = nullptr;
    napi_create_int32(env, snapshot ? (int32_t)snapshot->items.size() : 0, &result);
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
    const std::shared_ptr<const HostMenuSnapshot> snapshot = HostMenuSnapshotForJs();
    if (snapshot == nullptr || index < 0 || (size_t)index >= snapshot->items.size()) {
        napi_value undefined = nullptr;
        napi_get_undefined(env, &undefined);
        return undefined;
    }
    const HostMenuItem& item = snapshot->items[(size_t)index];
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

// Snapshots the builder, stores it as the latest published table and queues the count plus the
// snapshot itself for the JS thread. Returns the published item count.
static int HostMenuPublish() {
    HostBinding* binding = g_host;
    std::shared_ptr<HostMenuSnapshot> published = std::make_shared<HostMenuSnapshot>();
    int32_t count = 0;
    {
        std::lock_guard<std::mutex> guard(binding->menu_lock);
        published->items = binding->menu_build;
        count = (int32_t)published->items.size();
        binding->menu_latest = published;
    }
    std::shared_ptr<const HostMenuSnapshot> snapshot = published;
    SinkCall* call = new SinkCall();
    call->AddInt(count);
    call->menu_snapshot = snapshot;
    if (!HostSinkPost(g_menu_changed_sink, call)) {
        // No shell sink registered: the snapshot stays available to a later pull. The commit
        // itself is a success; the shell will rebuild when the sink arrives.
        static bool noSinkLogged = false;
        if (!noSinkLogged) {
            noSinkLogged = true;
            OH_LOG_WARN(LOG_APP, "[openharmony-host] menu: no shell menu sink; the table is kept for the next pull");
        }
    }
    return (int)count;
}

// Managed P/Invoke: opens a new menu table (drops the previous one).
extern "C" int ohos_host_menu_begin(int count) {
    return HostCxxBoundary("menu_begin", [count] {
        HostBinding* binding = g_host;
        std::lock_guard<std::mutex> guard(binding->menu_lock);
        binding->menu_build.clear();
        if (count > 0) {
            binding->menu_build.reserve((size_t)count);
        }
        return 0;
    });
}

// Managed P/Invoke: sets one row; index is the row position published back to the shell.
extern "C" int ohos_host_menu_item(int index, const char* text, int enabled) {
    if (index < 0) {
        return -1;
    }
    return HostCxxBoundary("menu_item", [index, text, enabled] {
        HostBinding* binding = g_host;
        std::lock_guard<std::mutex> guard(binding->menu_lock);
        size_t position = (size_t)index;
        if (position >= binding->menu_build.size()) {
            binding->menu_build.resize(position + 1);
        }
        binding->menu_build[position].text = text != nullptr ? text : "";
        binding->menu_build[position].enabled = enabled != 0;
        return 0;
    });
}

// Managed P/Invoke: publishes the table and reports the new count.
extern "C" int ohos_host_menu_commit(void) {
    return HostCxxBoundary("menu_commit", [] { return HostMenuPublish(); });
}

// Managed P/Invoke: registers the callback invoked by host.notifyMenuAction(index).
extern "C" void ohos_host_menu_set_listener(void* callback) {
    HostListenerStore(g_menu_action_listener, callback);
}

// ArkTS calls host.registerMenuChangedSink(fn) to be told when the table changed.
napi_value RegisterMenuChangedSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_menu_changed_sink);
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
    auto listener = HostListenerLoad(g_menu_action_listener);
    if (index >= 0 && listener != nullptr) {
        listener((int)index);
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// (sink moved into the current HostBinding; see the g_* accessors above)
// (sink moved into the current HostBinding; see the g_* accessors above)

void OnPickerRequest(int requestId, int kind) {
    HostCxxBoundaryVoid("picker request", [&] {
        SinkCall* call = new SinkCall();
        call->AddInt(requestId);
        call->AddInt(kind);
        HostSinkPost(g_picker_sink, call);
    });
}

void OnWebCommand(const char* op, const char* arg) {
    HostCxxBoundaryVoid("web command", [&] {
        SinkCall* call = new SinkCall();
        call->AddString(op);
        call->AddString(arg);
        HostSinkPost(g_web_sink, call);
    });
}

// ArkTS calls host.registerWebSink(fn) to receive web commands.
napi_value RegisterWebSink(napi_env env, napi_callback_info info) {
    napi_value result = HostSinkRegisterFromArgs(env, info, g_web_sink);
    ohos_host_web_set_listener(OnWebCommand);
    return result;
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
static std::atomic<void (*)(int)> g_theme_listener{nullptr};

extern "C" void ohos_host_theme_set_listener(void* callback) {
    HostListenerStore(g_theme_listener, callback);
}

napi_value NotifyTheme(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t isDark = 0;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &isDark);
    }
    auto listener = HostListenerLoad(g_theme_listener);
    if (listener != nullptr) {
        listener(isDark != 0 ? 1 : 0);
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
static std::atomic<void (*)(const char*)> g_battery_listener{nullptr};
static std::string g_battery_payload;

extern "C" void ohos_host_battery_set_listener(void* callback) {
    HostListenerStore(g_battery_listener, callback);
    auto listener = HostListenerLoad(g_battery_listener);
    if (listener != nullptr && !g_battery_payload.empty()) {
        listener(g_battery_payload.c_str());
    }
}

napi_value NotifyBattery(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string payload;
    if (argc >= 1) payload = GetStringArg(env, argv[0]);
    g_battery_payload = payload;
    auto listener = HostListenerLoad(g_battery_listener);
    if (listener != nullptr) {
        listener(payload.c_str());
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Display: same push shape for DeviceDisplay, through
// host.notifyDisplay("width\theight\tdensityDPI\trotation\trefreshRate\torientation") at page
// start and on display.on('change'); the last payload is replayed on listener registration.
static std::atomic<void (*)(const char*)> g_display_listener{nullptr};
static std::string g_display_payload;

extern "C" void ohos_host_display_set_listener(void* callback) {
    HostListenerStore(g_display_listener, callback);
    auto listener = HostListenerLoad(g_display_listener);
    if (listener != nullptr && !g_display_payload.empty()) {
        listener(g_display_payload.c_str());
    }
}

napi_value NotifyDisplay(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string payload;
    if (argc >= 1) payload = GetStringArg(env, argv[0]);
    g_display_payload = payload;
    auto listener = HostListenerLoad(g_display_listener);
    if (listener != nullptr) {
        listener(payload.c_str());
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
// (sink moved into the current HostBinding; see the g_* accessors above)

// Called from managed code (P/Invoke): returns 0 when the request was queued for the shell.
extern "C" int ohos_host_keep_screen_on(int on) {
    return HostCxxBoundary("keep screen on", [&] {
        SinkCall* call = new SinkCall();
        call->AddInt(on);
        return HostSinkPost(g_keep_screen_on_sink, call) ? 0 : -1;
    });
}

// ArkTS calls host.registerKeepScreenOnSink(fn) to receive keep-screen-on changes.
napi_value RegisterKeepScreenOnSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_keep_screen_on_sink);
}

// ---------------------------------------------------------------------------
// Window chrome: the managed window handler calls ohos_host_set_window_title /
// ohos_host_set_window_rect (P/Invoke); the ArkTS shell's registerWindowTitleSink /
// registerWindowRectSink handlers apply them to the main window (window.setWindowTitle,
// SessionManager API 15+; window.moveWindowTo + window.resize, API 11+). One-way like
// keep-screen-on: the return value only reports whether the request was queued for the shell.
// ---------------------------------------------------------------------------
// (sink moved into the current HostBinding; see the g_* accessors above)
// (sink moved into the current HostBinding; see the g_* accessors above)

// Called from managed code (P/Invoke): returns 0 when the title was queued for the shell.
extern "C" int ohos_host_set_window_title(const char* utf8) {
    return HostCxxBoundary("set window title", [&] {
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
    });
}

// Documented window-rect bounds: the shell applies the values to the main window with
// moveWindowTo + resize and the managed side is not trusted to keep them sane. Width/height
// are clamped into (0, 16384] and x/y into [-32768, 32768] before the request is queued.
constexpr int kMaxWindowDimension = 16384;
constexpr int kMaxWindowOffset = 32768;

// Called from managed code (P/Invoke): returns 0 when the rectangle was queued for the shell.
extern "C" int ohos_host_set_window_rect(int x, int y, int w, int h) {
    return HostCxxBoundary("set window rect", [&] {
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
    });
}

// ArkTS calls host.registerWindowTitleSink(fn) to receive window title changes.
napi_value RegisterWindowTitleSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_window_title_sink);
}

// ArkTS calls host.registerWindowRectSink(fn) to receive window rectangle changes.
napi_value RegisterWindowRectSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_window_rect_sink);
}

// ---------------------------------------------------------------------------
// Screenshot: the managed side asks the ArkTS shell to snapshot the main window and write a
// PNG to an app-owned path (window.snapshot + image.createImagePacker). One-way: the shell
// logs a failed write itself and the managed caller reads the file when it is ready.
// ---------------------------------------------------------------------------
// (sink moved into the current HostBinding; see the g_* accessors above)

// Called from managed code (P/Invoke): returns 0 when the request was queued for the shell.
extern "C" int ohos_host_screenshot(const char* out_path) {
    return HostCxxBoundary("screenshot", [&] {
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
    });
}

// ArkTS calls host.registerScreenshotSink(fn) to receive screenshot requests.
napi_value RegisterScreenshotSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_screenshot_sink);
}

// ---------------------------------------------------------------------------
// Shell search: the managed SearchHandler state (query, placeholder, visible, enabled) goes
// out through ohos_host_shell_search_set; the sink registered by
// host.registerShellSearchChangedSink applies it to the shell's search field. The shell
// reports interactions back through host.notifyShellSearch -> the managed listener registered
// by ohos_host_shell_search_set_listener (op 0 query changed, 1 submit, 2 cancel).
// ---------------------------------------------------------------------------
// (sink moved into the current HostBinding; see the g_* accessors above)
std::mutex g_shell_search_lock;
std::string g_shell_search_query;
std::string g_shell_search_placeholder;
std::atomic<int> g_shell_search_visible{0};
std::atomic<int> g_shell_search_enabled{0};

// Called from managed code (P/Invoke): publishes the state and returns 0 when it reached the
// shell sink. The stored copy backs the host.shellSearch* getters the shell reads on startup.
extern "C" int ohos_host_shell_search_set(const char* query, const char* placeholder,
                                          int visible, int enabled) {
    return HostCxxBoundary("shell search set", [&] {
        if (!ControlStringFits(query, "shell_search_set") || !ControlStringFits(placeholder, "shell_search_set")) {
            return -1;
        }
        SinkCall* call = new SinkCall();
        {
            std::lock_guard<std::mutex> guard(g_shell_search_lock);
            g_shell_search_query = query != nullptr ? query : "";
            g_shell_search_placeholder = placeholder != nullptr ? placeholder : "";
            g_shell_search_visible.store(visible != 0 ? 1 : 0, std::memory_order_release);
            g_shell_search_enabled.store(enabled != 0 ? 1 : 0, std::memory_order_release);
            call->AddString(g_shell_search_query.c_str(), kMaxControlBytes);
            call->AddString(g_shell_search_placeholder.c_str(), kMaxControlBytes);
            call->AddInt(g_shell_search_visible.load(std::memory_order_acquire));
            call->AddInt(g_shell_search_enabled.load(std::memory_order_acquire));
        }
        if (!HostSinkPost(g_shell_search_sink, call)) {
            OH_LOG_WARN(LOG_APP, "[openharmony-host] shell_search_set: no shell search sink");
            return -1;
        }
        return 0;
    });
}

// ArkTS calls host.registerShellSearchChangedSink(fn) to receive the managed search state.
napi_value RegisterShellSearchChangedSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_shell_search_sink);
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
            value = g_shell_search_visible.load(std::memory_order_acquire);
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
            value = g_shell_search_enabled.load(std::memory_order_acquire);
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
// (sink moved into the current HostBinding; see the g_* accessors above)
std::mutex g_shell_flyout_lock;
std::string g_shell_flyout_header;
std::string g_shell_flyout_footer;

static int ShellFlyoutPublish(int op, const char* text) {
    return HostCxxBoundary("shell flyout", [&] {
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
    });
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
    return HostSinkRegisterFromArgs(env, info, g_shell_flyout_sink);
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
// (sink moved into the current HostBinding; see the g_* accessors above)
static std::atomic<void (*)(int, const char*, int)> g_web_eval_result_listener{nullptr};
static std::atomic<void (*)(const char*)> g_web_js_message_listener{nullptr};

// Called from managed code (P/Invoke): forwards a script evaluation request to the ArkTS sink.
extern "C" int ohos_host_web_eval(const char* script, int request_id) {
    return HostCxxBoundary("web eval", [&] {
        SinkCall* call = new SinkCall();
        call->AddString(script);
        call->AddInt(request_id);
        return HostSinkPost(g_web_eval_sink, call) ? 0 : -1;
    });
}

// The managed side registers the callback that completes a pending script evaluation.
extern "C" void ohos_host_web_js_register_result(void* callback) {
    HostListenerStore(g_web_eval_result_listener, callback);
}

// The managed side registers the callback that receives JavaScript page messages.
extern "C" void ohos_host_web_js_register_message(void* callback) {
    HostListenerStore(g_web_js_message_listener, callback);
}

// ArkTS calls host.registerWebEvalSink(fn) to receive script evaluation requests.
napi_value RegisterWebEvalSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_web_eval_sink);
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
    auto listener = HostListenerLoad(g_web_eval_result_listener);
    if (listener != nullptr) {
        listener(requestId, result.c_str(), error);
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
    auto listener = HostListenerLoad(g_web_js_message_listener);
    if (listener != nullptr) {
        listener(payload.c_str());
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
// (sink moved into the current HostBinding; see the g_* accessors above)
static std::atomic<void (*)(int, const char*, const char*)> g_hybrid_invoke_listener{nullptr};

// The managed side registers the callback that services a JS invocation (P/Invoke).
extern "C" void ohos_host_hwv_register_invoke(void* callback) {
    HostListenerStore(g_hybrid_invoke_listener, callback);
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
    auto listener = HostListenerLoad(g_hybrid_invoke_listener);
    if (listener != nullptr && !method.empty()) {
        listener(requestId, method.c_str(), args.c_str());
        rc = 0;
    }
    napi_value result = nullptr;
    napi_create_int32(env, rc, &result);
    return result;
}

// ArkTS calls host.registerHybridInvokeResultSink(fn) to receive invocation results.
napi_value RegisterHybridInvokeResultSink(napi_env env, napi_callback_info info) {
    return HostSinkRegisterFromArgs(env, info, g_hybrid_invoke_result_sink);
}

// Called from managed code (P/Invoke) with the invocation result. Returns 0 when the result
// reached the ArkTS sink, -1 when there is no result sink registered.
extern "C" int ohos_host_hwv_invoke_result(int request_id, const char* payload_json) {
    return HostCxxBoundary("hybrid invoke result", [&] {
        SinkCall* call = new SinkCall();
        call->AddInt(request_id);
        call->AddString(payload_json);
        return HostSinkPost(g_hybrid_invoke_result_sink, call) ? 0 : -1;
    });
}

// ArkTS calls host.registerPickerSink(fn) to receive picker requests.
napi_value RegisterPickerSink(napi_env env, napi_callback_info info) {
    napi_value result = HostSinkRegisterFromArgs(env, info, g_picker_sink);
    ohos_host_picker_set_listener(OnPickerRequest);
    return result;
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
// (sink moved into the current HostBinding; see the g_* accessors above)

// ceil(bytes / 3) * 4, computed without overflowing.
constexpr size_t kMaxRawFileBase64Bytes =
    ((static_cast<size_t>(OHOS_HOST_RAW_FILE_MAX_BYTES) + 2) / 3) * 4;

// Called by the host core (managed side) to ask the shell for one raw resource.
void OnRawFileRequest(int requestId, int op, const char* name) {
    HostCxxBoundaryVoid("raw file request", [&] {
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
    });
}

// ArkTS calls host.registerRawFileSink(fn) to receive raw-resource requests.
napi_value RegisterRawFileSink(napi_env env, napi_callback_info info) {
    napi_value result = HostSinkRegisterFromArgs(env, info, g_raw_file_sink);
    ohos_host_raw_file_set_listener(OnRawFileRequest);
    return result;
}

// ArkTS calls host.notifyRawFileResult(requestId, rc, dataBase64) when the read/probe finished
// over the base64 transport (the fallback for shells/SDKs without a usable rawfile descriptor;
// the descriptor read uses notifyRawFileFd below).
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

// One rawfile descriptor read: the shell obtained {fd, offset, length} from
// resourceManager.getRawFd and calls this synchronously on its own thread, so the fd is valid
// for the whole call and the shell closes it right after. The bytes are delivered to the managed
// callback before returning (no fd dup, no ownership transfer). The read is chunked (256 KiB).
// Buffer policy: only a small buffer is retained between calls (kRawFilePoolBytes); a larger
// read allocates on demand and frees when the call returns, so the old high-water vector that
// kept the largest read - up to the 8 MiB cap - alive for the process lifetime cannot happen.
// Returns 1 when the request was answered, 0 when it was not (bad coordinates, over-cap size,
// allocation failure, short/erroring read) and the shell must fall back to the base64 answer -
// the managed request stays pending until then.
constexpr size_t kRawFileReadChunkBytes = 256 * 1024;
// Retained scratch size. Every read is delivered to the managed callback before this function
// returns (the header documents that the pointer is only valid for the call), so the pool never
// has to hold what the previous largest read used; 256 KiB also bounds a temporarily idle host.
constexpr size_t kRawFilePoolBytes = 256 * 1024;

constexpr int kRawFileDelivered = 1;
constexpr int kRawFileFallback = 0;

// Retained scratch buffer and its lock. The pool lock is held for the whole read when the pool
// is used, so two shell threads cannot share one buffer; the lock is not taken for the
// on-demand path (its buffer is local).
static std::mutex g_raw_file_pool_lock;
static std::vector<unsigned char> g_raw_file_pool;

// Returns the buffer to read `size` bytes into. A size at or below the pool cap reuses the
// retained buffer under the pool lock (held for the whole read through `pool_lock`); a bigger
// size allocates `local` on demand, owned by the caller and freed on return.
static unsigned char* OhosRawFileReserve(size_t size, std::unique_lock<std::mutex>& pool_lock,
                                         std::vector<unsigned char>& local) {
    if (size <= kRawFilePoolBytes) {
        pool_lock = std::unique_lock<std::mutex>(g_raw_file_pool_lock);
        if (g_raw_file_pool.size() < size) {
            g_raw_file_pool.resize(size);  // throws bad_alloc: the caller reports the fallback
        }
        return g_raw_file_pool.data();
    }
    local.resize(size);  // throws bad_alloc: the caller reports the fallback
    return local.data();
}

int DeliverRawFileBytes(int requestId, int fd, int64_t offset, int64_t length) {
    if (fd < 0 || offset < 0 || length < 0) {
        return kRawFileFallback;
    }
    if (length > (int64_t)OHOS_HOST_RAW_FILE_MAX_BYTES) {
        // The cap belongs to this buffer: the shell also refuses, so a buggy caller cannot make
        // the host allocate past the documented 8 MiB semantics.
        return kRawFileFallback;
    }
    const size_t size = static_cast<size_t>(length);
    if (size == 0) {
        // A zero-byte rawfile is a valid answer with no data.
        ohos_host_raw_file_result_bytes(requestId, OHOS_RAW_FILE_OK, nullptr, 0);
        return kRawFileDelivered;
    }
    std::unique_lock<std::mutex> pool_lock;
    std::vector<unsigned char> local;
    unsigned char* buffer = nullptr;
    try {
        buffer = OhosRawFileReserve(size, pool_lock, local);
    } catch (...) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] raw file: cannot allocate %{public}d bytes for the descriptor read; using the base64 answer",
                    (int)size);
        return kRawFileFallback;
    }
    size_t done = 0;
    while (done < size) {
        const size_t chunk = (size - done) < kRawFileReadChunkBytes ? (size - done) : kRawFileReadChunkBytes;
        const ssize_t n = pread(fd, buffer + done, chunk, static_cast<off_t>(offset + (int64_t)done));
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            OH_LOG_WARN(LOG_APP, "[openharmony-host] raw file: descriptor read stopped at %{public}d of %{public}d bytes; using the base64 answer",
                        (int)done, (int)size);
            return kRawFileFallback;
        }
        done += static_cast<size_t>(n);
    }
    ohos_host_raw_file_result_bytes(requestId, OHOS_RAW_FILE_OK, buffer, size);
    return kRawFileDelivered;
}

// ArkTS calls host.notifyRawFileFd(requestId, fd, offset, length) after a successful
// resourceManager.getRawFd. Returns 1 when the request was answered here (the bytes were read
// and delivered, or an over-cap descriptor was answered rc -3) and 0 when the shell must fall
// back to notifyRawFileResult + getRawFileContent (no managed bytes callback, invalid
// coordinates, or a failed read - the request has then NOT been answered).
napi_value NotifyRawFileFd(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t requestId = 0;
    int32_t fd = -1;
    double offset = -1;
    double length = -1;
    if (argc >= 1) napi_get_value_int32(env, argv[0], &requestId);
    if (argc >= 2) napi_get_value_int32(env, argv[1], &fd);
    if (argc >= 3) napi_get_value_double(env, argv[2], &offset);
    if (argc >= 4) napi_get_value_double(env, argv[3], &length);
    int delivered = kRawFileFallback;
    if (ohos_host_raw_file_bytes_available() == 0) {
        static bool noBytesCallbackLogged = false;
        if (!noBytesCallbackLogged) {
            noBytesCallbackLogged = true;
            OH_LOG_WARN(LOG_APP, "[openharmony-host] raw file: no byte result callback; descriptor reads fall back to the base64 answer");
        }
    } else if (length < 0) {
        // Invalid descriptor length (the shell always sends a number): leave the answer to the
        // base64 fallback.
    } else if (length > (double)OHOS_HOST_RAW_FILE_MAX_BYTES) {
        // Refused before any read; the cap is the same one the shell checks.
        ohos_host_raw_file_result_bytes(requestId, OHOS_RAW_FILE_TOO_LARGE, nullptr, 0);
        delivered = kRawFileDelivered;
    } else if (offset < 0 || offset > (double)INT64_MAX - length) {
        // Coordinates that cannot describe a file in the HAP: leave the answer to the shell.
    } else {
        delivered = DeliverRawFileBytes(requestId, fd, (int64_t)offset, (int64_t)length);
    }
    napi_value result = nullptr;
    napi_create_int32(env, delivered, &result);
    return result;
}

// Runtime permissions: the managed side asks through ohos_host_request_permission; the sink's
// handler runs abilityAccessCtrl.requestPermissionsFromUser and answers with
// host.permissionResult(requestId, granted). Argument order matches the C listener
// (permission first, request id second).
// (sink moved into the current HostBinding; see the g_* accessors above)

void OnPermissionRequest(const char* permission, int requestId) {
    HostCxxBoundaryVoid("permission request", [&] {
        if (!ControlStringFits(permission, "permission")) {
            return;
        }
        SinkCall* call = new SinkCall();
        call->AddString(permission, kMaxControlBytes);
        call->AddInt(requestId);
        HostSinkPost(g_permission_sink, call);
    });
}

// ArkTS calls host.registerPermissionSink(fn) to receive permission requests.
napi_value RegisterPermissionSink(napi_env env, napi_callback_info info) {
    napi_value result = HostSinkRegisterFromArgs(env, info, g_permission_sink);
    ohos_host_permission_set_listener(OnPermissionRequest);
    return result;
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
// (sink moved into the current HostBinding; see the g_* accessors above)

void OnNotificationPermissionRequest(int op, int requestId) {
    HostCxxBoundaryVoid("notification permission request", [&] {
        SinkCall* call = new SinkCall();
        call->AddInt(op);
        call->AddInt(requestId);
        HostSinkPost(g_notification_permission_sink, call);
    });
}

// ArkTS calls host.registerNotificationPermissionSink(fn) to receive enablement requests.
napi_value RegisterNotificationPermissionSink(napi_env env, napi_callback_info info) {
    napi_value result = HostSinkRegisterFromArgs(env, info, g_notification_permission_sink);
    ohos_host_notification_permission_set_listener(OnNotificationPermissionRequest);
    return result;
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
// (sink moved into the current HostBinding; see the g_* accessors above)

void OnClipboardRequest(int requestId, int op, const char* text) {
    HostCxxBoundaryVoid("clipboard request", [&] {
        if (!ControlStringFits(text, "clipboard")) {
            return;
        }
        SinkCall* call = new SinkCall();
        call->AddInt(requestId);
        call->AddInt(op);
        call->AddString(text, kMaxControlBytes);
        HostSinkPost(g_clipboard_sink, call);
    });
}

// ArkTS calls host.registerClipboardSink(fn) to receive clipboard operations.
napi_value RegisterClipboardSink(napi_env env, napi_callback_info info) {
    napi_value result = HostSinkRegisterFromArgs(env, info, g_clipboard_sink);
    ohos_host_clipboard_set_listener(OnClipboardRequest);
    return result;
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
// (sink moved into the current HostBinding; see the g_* accessors above)

void OnGeocodeRequest(int requestId, int op, const char* arg) {
    HostCxxBoundaryVoid("geocode request", [&] {
        if (!ControlStringFits(arg, "geocode")) {
            return;
        }
        SinkCall* call = new SinkCall();
        call->AddInt(requestId);
        call->AddInt(op);
        call->AddString(arg, kMaxControlBytes);
        HostSinkPost(g_geocode_sink, call);
    });
}

// ArkTS calls host.registerGeocodeSink(fn) to receive geocoding requests.
napi_value RegisterGeocodeSink(napi_env env, napi_callback_info info) {
    napi_value result = HostSinkRegisterFromArgs(env, info, g_geocode_sink);
    ohos_host_geocode_set_listener(OnGeocodeRequest);
    return result;
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
// (sink moved into the current HostBinding; see the g_* accessors above)

void OnVibrationRequest(int durationMs) {
    HostCxxBoundaryVoid("vibration request", [&] {
        SinkCall* call = new SinkCall();
        call->AddInt(durationMs);
        HostSinkPost(g_vibration_sink, call);
    });
}

napi_value RegisterVibrationSink(napi_env env, napi_callback_info info) {
    napi_value result = HostSinkRegisterFromArgs(env, info, g_vibration_sink);
    ohos_host_set_vibration_listener(OnVibrationRequest);
    return result;
}

// ArkTS calls host.registerKeystoreSink(fn) to receive keystore requests.
napi_value RegisterKeystoreSink(napi_env env, napi_callback_info info) {
    napi_value result = HostSinkRegisterFromArgs(env, info, g_keystore_sink);
    ohos_host_keystore_set_listener(OnKeystoreRequest);
    return result;
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
    HostCxxBoundaryVoid("text input request", [&] {
        SinkCall* call = new SinkCall();
        call->AddInt(show);
        HostSinkPost(g_text_input_sink, call);
    });
}

// ArkTS calls host.registerTextInputSink(fn) so the shell can show/hide its input.
napi_value RegisterTextInputSink(napi_env env, napi_callback_info info) {
    napi_value result = HostSinkRegisterFromArgs(env, info, g_text_input_sink);
    ohos_host_set_text_input_listener(OnTextInputRequest);
    return result;
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
    // Init already bound this env; refresh the recorded JS thread (this is a JS callback) and
    // retry the XComponent bind. A different env never silently rebinds here.
    if (g_host->env == env) {
        g_host->js_thread = pthread_self();
        g_host->js_thread_valid = true;
        TryRegisterXComponent();
    } else {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] registerXComponent: unknown env, ignored");
    }
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
    // Re-entrant by design: the library registers this same Init under more than one module
    // name (the alias table at the end of the file), and the loader may call the register
    // function once per name it binds. Each call returns its own exports object with the same
    // property table; the newest exports stays the XComponent reference source, and
    // TryRegisterXComponent retries until it has one (it returns early once bound).
    //
    // A page rebuild (or an ability restart) hands this function a new env: HostEnsureBinding
    // tears the previous binding down with the env that created its references, aborts its
    // threadsafe functions and claims a fresh binding, so no stale napi_ref is deleted (or
    // used) through the new env. Re-entry with the same env keeps the registered sinks.
    HostBinding* binding = HostEnsureBinding(env);
    if (binding == g_host && binding->env == env) {
        if (binding->exports_ref != nullptr) {
            OH_LOG_INFO(LOG_APP, "[openharmony-host] Init re-entered (module bound under more than one name)");
        }
        if (HostRefReplace(env, &binding->exports_ref, exports) != napi_ok) {
            OH_LOG_WARN(LOG_APP, "[openharmony-host] Init could not keep the exports object");
        }
        TryRegisterXComponent();
    }
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
        {"registerShareKitSink", nullptr, RegisterShareKitSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerScanSink", nullptr, RegisterScanSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyScanResult", nullptr, NotifyScanResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerPushSink", nullptr, RegisterPushSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyPushResult", nullptr, NotifyPushResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerAccountSink", nullptr, RegisterAccountSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyAccountResult", nullptr, NotifyAccountResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerMapSink", nullptr, RegisterMapSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyMapResult", nullptr, NotifyMapResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerLiveViewSink", nullptr, RegisterLiveViewSink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyLiveViewResult", nullptr, NotifyLiveViewResult, nullptr, nullptr, nullptr, napi_default, nullptr},
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
        {"notifyRawFileFd", nullptr, NotifyRawFileFd, nullptr, nullptr, nullptr, napi_default, nullptr},
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
    // The unified NAPI exception boundary: every exported method runs through HostNapiEntry,
    // with the real handler in the descriptor's data field (this table is the only user of
    // data). A handler that throws while allocating is reported as a JS exception instead of
    // unwinding through the engine.
    for (size_t i = 0; i < sizeof(properties) / sizeof(properties[0]); i++) {
        if (properties[i].method != nullptr) {
            properties[i].data = reinterpret_cast<void*>(properties[i].method);
            properties[i].method = HostNapiEntry;
        }
    }
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}

}  // namespace

// Native module registration -------------------------------------------------
// The device's ArkTS loader binds `import host from 'libopenharmonyhost.so'` to a NAPI module
// registered by this library, and two spellings of that binding are seen in the field:
//   * the bare module name "openharmonyhost": the Huawei documentation rule ('lib' prefix and
//     '.so' suffix stripped), and the name this library has always registered;
//   * the full file name "libopenharmonyhost.so": an ArkTS toolchain with
//     useNormalizedOHMUrl=true compiles the import into '@normalized:Y&&&libopenharmonyhost.so&'
//     and the loader looks the module up by the whole file name (the shape a known-working
//     device app binds: '@normalized:Y&&&libentry.so&' <-> nm_modname "libentry.so").
// Registering both names is free when one is unused; whichever name the loader resolves calls
// Init (safe to run more than once, see there) and logs its alias exactly once, so the device
// log answers "which name did the loader actually bind" directly.
static bool g_alias_bare_logged = false;
static bool g_alias_file_logged = false;

static napi_value HostInitBoundAsBare(napi_env env, napi_value exports) {
    if (!g_alias_bare_logged) {
        g_alias_bare_logged = true;
        OH_LOG_INFO(LOG_APP, "[openharmony-host] native module register function bound via alias '%{public}s'",
                    "openharmonyhost");
    }
    return Init(env, exports);
}

static napi_value HostInitBoundAsFile(napi_env env, napi_value exports) {
    if (!g_alias_file_logged) {
        g_alias_file_logged = true;
        OH_LOG_INFO(LOG_APP, "[openharmony-host] native module register function bound via alias '%{public}s'",
                    "libopenharmonyhost.so");
    }
    return Init(env, exports);
}

static napi_module g_hostModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = HostInitBoundAsBare,
    .nm_modname = "openharmonyhost",
    .nm_priv = nullptr,
    .reserved = {0},
};

static napi_module g_hostModuleFileAlias = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = HostInitBoundAsFile,
    .nm_modname = "libopenharmonyhost.so",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterHostModule(void) {
    napi_module_register(&g_hostModule);
    napi_module_register(&g_hostModuleFileAlias);
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

// Geometry-only read for the focus-move scans: every string output stays NULL, so a probe
// does not copy the four interned strings the full record carries.
static bool A11yReadNodeGeometry(int index, float* x, float* y, float* width, float* height,
                                 int* flags) {
    return ohos_host_accessibility_get(index, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr,
                                       x, y, width, height, flags, nullptr,
                                       nullptr, nullptr, nullptr, nullptr) == 0;
}

// Index of the node published under this id, or -1 when it is not in the table. The native
// table builds its id -> index map while publishing (ohos_host_accessibility_index_of), so
// this is O(1) instead of the linear scan it used to be.
static int A11yIndexOfId(int64_t elementId) {
    if (elementId <= 0) {
        return -1;
    }
    return ohos_host_accessibility_index_of((int)elementId);
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
static std::atomic<void (*)(int, int)> g_a11y_action_listener{nullptr};
// ArkUI only hands out the accessibility provider for a node of type ARKUI_NODE_CUSTOM. The
// custom node has to stay alive and inside the NodeContent for as long as the provider is
// registered, so it is kept here (setNodeContent may run again when the page is re-entered).
static ArkUI_NodeHandle g_a11y_custom_node = nullptr;
static bool g_a11y_custom_added = false;
// The NodeContent the CUSTOM node was added to. A page re-entry publishes a new content while
// the provider stays attached to the CUSTOM node, so the node has to be re-added to the new
// content (setNodeContent runs again); the identity is what makes that rebind detectable.
static ArkUI_NodeContentHandle g_a11y_content = nullptr;

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

// Fills one ArkUI element from a published record already read by the caller. Shared by the
// list queries (findAccessibilityNodeInfosById/findByText) and the single-node callbacks
// (findFocused/findNextFocus), so every path publishes the same fields with one table read.
static int32_t A11yFillElement(const A11yNodeRecord& node, ArkUI_AccessibilityElementInfo* info) {
    if (info == nullptr) {
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

static void A11yAddNodeRecord(ArkUI_AccessibilityElementInfoList* list, const A11yNodeRecord& node) {
    ArkUI_AccessibilityElementInfo* info = OH_ArkUI_AddAndGetAccessibilityElementInfo(list);
    if (info == nullptr) {
        return;
    }
    A11yFillElement(node, info);
}

static void A11yAddNode(ArkUI_AccessibilityElementInfoList* list, int index) {
    A11yNodeRecord node;
    if (!A11yReadNode(index, &node)) {
        return;   // keeps empty elements out of the list for a stale index
    }
    A11yAddNodeRecord(list, node);
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
    int index = A11yIndexOfId(elementId);
    if (index < 0) {
        return ARKUI_ACCESSIBILITY_NATIVE_RESULT_FAILED;
    }
    A11yNodeRecord node;
    if (!A11yReadNode(index, &node)) {
        return ARKUI_ACCESSIBILITY_NATIVE_RESULT_FAILED;
    }
    A11yAddNodeRecord(list, node);
    if ((int)mode & ARKUI_ACCESSIBILITY_NATIVE_SEARCH_MODE_PREFETCH_CHILDREN) {
        // One pass over the table, each matching child read and filled from that single
        // record: the nested scan used to read every node once per candidate child (O(N^2)).
        for (int j = 0; j < count; j++) {
            A11yNodeRecord child;
            if (A11yReadNode(j, &child) && child.parent == node.id) {
                A11yAddNodeRecord(list, child);
            }
        }
    }
    return ARKUI_ACCESSIBILITY_NATIVE_RESULT_SUCCESSFUL;
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
            A11yAddNodeRecord(list, node);
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
        if (A11yReadNodeGeometry(i, nullptr, nullptr, nullptr, nullptr, &flags) && (flags & 2) != 0) {
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
    float x = 0, y = 0, width = 0, height = 0;
    int flags = 0;
    if (!A11yReadNodeGeometry(index, &x, &y, &width, &height, &flags)) {
        return false;
    }
    if (centerX != nullptr) {
        *centerX = x + width * 0.5f;
    }
    if (centerY != nullptr) {
        *centerY = y + height * 0.5f;
    }
    if (focusable != nullptr) {
        *focusable = (flags & 2) != 0;
    }
    return true;
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
        int flags = 0;
        if (A11yReadNodeGeometry(i, nullptr, nullptr, nullptr, nullptr, &flags) && (flags & 2) != 0) {
            return i;
        }
    }
    return -1;
}

static int32_t A11yFocused(int64_t elementId, ArkUI_AccessibilityFocusType focusType,
                           int32_t requestId, ArkUI_AccessibilityElementInfo* info) {
    (void)elementId; (void)focusType; (void)requestId;
    int index = A11yFirstFocusable(-1);
    if (index < 0) {
        return ARKUI_ACCESSIBILITY_NATIVE_RESULT_FAILED;
    }
    A11yNodeRecord node;
    if (!A11yReadNode(index, &node)) {
        return ARKUI_ACCESSIBILITY_NATIVE_RESULT_FAILED;
    }
    return A11yFillElement(node, info);
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
    A11yNodeRecord node;
    if (!A11yReadNode(index, &node)) {
        return ARKUI_ACCESSIBILITY_NATIVE_RESULT_FAILED;
    }
    return A11yFillElement(node, info);
}

static int32_t A11yExecuteAction(int64_t elementId, ArkUI_Accessibility_ActionType action,
                                 ArkUI_AccessibilityActionArguments* arguments, int32_t requestId) {
    (void)arguments; (void)requestId;
    auto listener = HostListenerLoad(g_a11y_action_listener);
    if (listener != nullptr) {
        listener((int)elementId, (int)action);
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

    // FrameNode path: any frame node can reach here, but only ARKUI_NODE_CUSTOM gets a provider;
    // keep the direct attempt so the diagnosis stays 2 (received but refused).
    ArkUI_NodeHandle node = nullptr;
    if (OH_ArkUI_GetNodeHandleFromNapiValue(env, value, &node) == 0 && node != nullptr) {
        if (g_a11y_provider != nullptr) {
            return g_a11y_status;  // already attached; keep the existing binding
        }
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

    // NodeContent path: the shell hands its content over at startup (host.setNodeContent) and
    // again on a page re-entry. The provider is attached to the CUSTOM node, not to the content,
    // so the same content is a no-op while a different one moves the node over (rebind).
    ArkUI_NodeContentHandle content = nullptr;
    if (OH_ArkUI_GetNodeContentFromNapiValue(env, value, &content) != 0 || content == nullptr) {
        return g_a11y_status;
    }
    if (g_a11y_provider != nullptr && g_a11y_content == content) {
        return g_a11y_status;  // same content re-published: the provider already serves it
    }
    if (g_a11y_provider != nullptr && g_a11y_content != content) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] accessibility: NodeContent replaced; re-adding the CUSTOM node");
        g_a11y_custom_added = false;
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
        g_a11y_content = content;
    }
    g_a11y_status = 4;  // CUSTOM node is in the content; the provider has not accepted it yet

    if (g_a11y_provider != nullptr) {
        g_a11y_status = 1;  // provider stays attached to the same CUSTOM node across the rebind
        return g_a11y_status;
    }
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
    HostListenerStore(g_a11y_action_listener, callback);
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

