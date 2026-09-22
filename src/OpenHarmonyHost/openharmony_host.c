#include "openharmony_host.h"

#include <sensors/vibrator.h>
#include <network/netmanager/net_connection.h>
#include <network/netmanager/net_connection_type.h>
#include <accesstoken/ability_access_control.h>
#include <inputmethod/inputmethod_controller_capi.h>
#include <inputmethod/inputmethod_inputmethod_proxy_capi.h>
#include <inputmethod/inputmethod_attach_options_capi.h>
#include <native_drawing/drawing_font.h>
#include <native_drawing/drawing_typeface.h>
#include <LocationKit/oh_location.h>
#include <LocationKit/oh_location_type.h>

#include <dlfcn.h>
#include <multimedia/image_framework/image/image_source_native.h>
#include <multimedia/image_framework/image/pixelmap_native.h>
#include <native_buffer/buffer_common.h>
#include <native_drawing/drawing_bitmap.h>
#include <native_drawing/drawing_brush.h>
#include <native_drawing/drawing_canvas.h>
#include <inputmethod/inputmethod_controller_capi.h>
#include <inputmethod/inputmethod_inputmethod_proxy_capi.h>
#include <inputmethod/inputmethod_attach_options_capi.h>
#include <native_drawing/drawing_font.h>
#include <native_drawing/drawing_matrix.h>
#include <native_drawing/drawing_path.h>
#include <native_drawing/drawing_pixel_map.h>
#include <native_drawing/drawing_point.h>
#include <native_drawing/drawing_shader_effect.h>
#include <native_drawing/drawing_shadow_layer.h>
#include <native_drawing/drawing_pen.h>
#include <native_drawing/drawing_rect.h>
#include <native_drawing/drawing_text_blob.h>
#include <native_drawing/drawing_types.h>
#include <native_buffer/native_buffer.h>
#include <native_window/external_window.h>
#include <hilog/log.h>
#include <pthread.h>
#include <sys/mman.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// NOTE: signature is (argc, argv, host_path, dotnet_root, app_path) — see native/corehost/hostfxr.h.
typedef int (*ohos_main_startupinfo_fn)(const int argc, const char* const* argv,
                                        const char* host_path, const char* dotnet_root,
                                        const char* app_path);

typedef struct {
    size_t size;
    const char* host_path;
    const char* dotnet_root;
} ohos_hostfxr_initialize_parameters;

typedef int (*ohos_initialize_for_runtime_config_fn)(const char*, const ohos_hostfxr_initialize_parameters*, void**);
typedef int (*ohos_get_runtime_delegate_fn)(void*, int, void**);
typedef int (*ohos_close_fn)(void*);
typedef void (*ohos_error_writer_fn)(const char*);
typedef void (*ohos_set_error_writer_fn)(ohos_error_writer_fn);
typedef int (*ohos_load_assembly_and_get_function_pointer_fn)(const char*, const char*, const char*, const char*, void*, void**);

#define OHOS_HDT_LOAD_ASSEMBLY_AND_GET_FUNCTION_POINTER 5

static void ohos_error_writer(const char* message) {
    fprintf(stderr, "[hostfxr] %s\n", message);
}

static int path_join(char* dst, size_t dst_size, const char* dir, const char* file) {
    int written = snprintf(dst, dst_size, "%s/%s", dir, file);
    return written > 0 && (size_t)written < dst_size ? 0 : -1;
}

int ohos_host_run_app(const char* app_dir, const char* app_assembly_file, int argc, const char* const* argv) {
    char hostfxr_path[4096];
    char app_assembly_path[4096];
    if (path_join(hostfxr_path, sizeof(hostfxr_path), app_dir, "libhostfxr.so") != 0 ||
        path_join(app_assembly_path, sizeof(app_assembly_path), app_dir, app_assembly_file) != 0) {
        return -1;
    }

    void* hostfxr = dlopen(hostfxr_path, RTLD_NOW | RTLD_LOCAL);
    if (hostfxr == NULL) {
        const char* dl_error = dlerror();
        OH_LOG_ERROR(LOG_APP, "[openharmony-host] run_app dlopen(%{public}s) failed: %{public}s",
                     hostfxr_path, dl_error);
        fprintf(stderr, "[openharmony-host] dlopen(%s) failed: %s\n", hostfxr_path, dl_error);
        return -1;
    }

    ohos_set_error_writer_fn set_error_writer =
        (ohos_set_error_writer_fn)dlsym(hostfxr, "hostfxr_set_error_writer");
    if (set_error_writer != NULL) {
        set_error_writer(ohos_error_writer);
    }

    // Preferred entry: same path the apphost uses; supports both framework-dependent
    // and self-contained runtimeconfigs, and runs the application's own Main.
    ohos_main_startupinfo_fn main_startupinfo =
        (ohos_main_startupinfo_fn)dlsym(hostfxr, "hostfxr_main_startupinfo");
    if (main_startupinfo != NULL) {
        const char** app_argv = (const char**)malloc((size_t)(argc + 1) * sizeof(const char*));
        if (app_argv == NULL) {
            return -1;
        }
        app_argv[0] = app_assembly_path;
        for (int i = 0; i < argc; i++) {
            app_argv[i + 1] = argv[i];
        }
        // Same contract as the apphost: dotnet_root comes from the environment (may
        // be NULL for self-contained apps), never from the app directory.
        const char* dotnet_root = getenv("DOTNET_ROOT");
        int exit_code = main_startupinfo(argc + 1, app_argv, app_dir, dotnet_root, app_assembly_path);
        free((void*)app_argv);
        OH_LOG_INFO(LOG_APP, "[openharmony-host] run_app Main exited rc=%{public}d", exit_code);
        return exit_code;
    }

    // Fallback: component hosting (framework-dependent only; self-contained components
    // are not supported by hostfxr). Used when the application publishes a managed
    // entry point through Microsoft.OpenHarmony.Hosting instead of Main.
    ohos_initialize_for_runtime_config_fn initialize =
        (ohos_initialize_for_runtime_config_fn)dlsym(hostfxr, "hostfxr_initialize_for_runtime_config");
    ohos_get_runtime_delegate_fn get_delegate =
        (ohos_get_runtime_delegate_fn)dlsym(hostfxr, "hostfxr_get_runtime_delegate");
    ohos_close_fn close_ctx = (ohos_close_fn)dlsym(hostfxr, "hostfxr_close");
    if (initialize == NULL || get_delegate == NULL || close_ctx == NULL) {
        fprintf(stderr, "[openharmony-host] hostfxr symbols missing\n");
        return -1;
    }

    char runtime_config_path[4096];
    {
        const char* dot = strrchr(app_assembly_file, '.');
        size_t stem_len = dot != NULL ? (size_t)(dot - app_assembly_file) : strlen(app_assembly_file);
        int written = snprintf(runtime_config_path, sizeof(runtime_config_path), "%s/%.*s.runtimeconfig.json",
                               app_dir, (int)stem_len, app_assembly_file);
        if (written <= 0 || (size_t)written >= sizeof(runtime_config_path)) {
            return -1;
        }
    }

    char hosting_assembly_path[4096];
    if (path_join(hosting_assembly_path, sizeof(hosting_assembly_path), app_dir, "Microsoft.OpenHarmony.Hosting.dll") != 0) {
        return -1;
    }

    ohos_hostfxr_initialize_parameters params;
    params.size = sizeof(params);
    params.host_path = app_dir;
    params.dotnet_root = app_dir;

    void* ctx = NULL;
    int rc = initialize(runtime_config_path, &params, &ctx);
    if (rc != 0 || ctx == NULL) {
        fprintf(stderr, "[openharmony-host] hostfxr_initialize_for_runtime_config rc=0x%x\n", rc);
        return -1;
    }

    void* loader = NULL;
    rc = get_delegate(ctx, OHOS_HDT_LOAD_ASSEMBLY_AND_GET_FUNCTION_POINTER, &loader);
    if (rc != 0 || loader == NULL) {
        fprintf(stderr, "[openharmony-host] get_runtime_delegate rc=0x%x\n", rc);
        close_ctx(ctx);
        return -1;
    }

    void* entry = NULL;
    rc = ((ohos_load_assembly_and_get_function_pointer_fn)loader)(
        hosting_assembly_path,
        "Microsoft.OpenHarmony.Hosting.OpenHarmonyEntryPoint, Microsoft.OpenHarmony.Hosting",
        "openharmony_app_main", NULL, NULL, &entry);
    if (rc != 0 || entry == NULL) {
        fprintf(stderr, "[openharmony-host] get_function_pointer rc=0x%x\n", rc);
        close_ctx(ctx);
        return -1;
    }

    size_t payload_len = strlen(app_assembly_path) + 1;
    for (int i = 0; i < argc; i++) {
        payload_len += strlen(argv[i]) + 1;
    }
    char* payload = (char*)malloc(payload_len);
    if (payload == NULL) {
        close_ctx(ctx);
        return -1;
    }
    char* cursor = payload;
    cursor += sprintf(cursor, "%s", app_assembly_path);
    for (int i = 0; i < argc; i++) {
        cursor += sprintf(cursor, "\n%s", argv[i]);
    }

    int exit_code = ((int (*)(const char*))entry)(payload);
    free(payload);
    close_ctx(ctx);
    return exit_code;
}

// ---------------------------------------------------------------------------
// Bridged mode: the managed application is started through the command-line
// hostfxr entry point (self-contained friendly) and registers its callbacks
// back into this library; the shell pushes lifecycle/node events into them.
// ---------------------------------------------------------------------------

typedef int (*ohos_initialize_for_dotnet_command_line_fn)(int, const char* const*,
                                                          const ohos_hostfxr_initialize_parameters*,
                                                          void**);
typedef int (*ohos_run_app_fn)(void*);

#define OHOS_MAX_PENDING_LIFECYCLE 32

// Serializes the context slots (g_pending_context_json below and the handle's context_json)
// between the shell thread calling ohos_host_set_app_context and the launch thread running
// ohos_host_start_app. Without it the launch thread can read or free the pending snapshot
// while the setter replaces it (and the setter can free it under the reader).
static pthread_mutex_t g_context_mutex = PTHREAD_MUTEX_INITIALIZER;

// Retired context snapshots: a managed reader may still be copying the pointer returned by
// ohos_host_get_app_context when ohos_host_set_app_context replaces it, so replaced strings
// are retired and freed at join instead of being freed under the reader.
typedef struct OhosRetiredContext {
    char* json;
    struct OhosRetiredContext* next;
} OhosRetiredContext;

struct OhosHostAppHandle {
    void* hostfxr;
    void* ctx;
    int (*run_app)(void*);
    int (*close_ctx)(void*);
    pthread_t thread;
    int exit_code;
    int joined;
    char* context_json;
    OhosRetiredContext* retired_contexts;
    void* node_content;
    void (*bridge_lifecycle)(int);
    void (*bridge_node)(void*);
    void (*bridge_surface)(void*, int, int, int);
    void (*bridge_touch)(int, float, float, int, int);
    void (*bridge_frame)(int64_t, int64_t);
    void (*bridge_text_input)(const char*);
    void (*bridge_text_submitted)(void);
    void (*bridge_keystore_result)(int request_id, int rc, const char* data_base64);
    void (*bridge_picker_result)(int request_id, int rc, const char* name, const char* data_base64);
    void (*bridge_web_event)(const char* state, const char* url);
    void (*bridge_permission_result)(int request_id, int granted);
    void (*bridge_notification_permission_result)(int request_id, int granted);
    void (*bridge_clipboard_result)(int request_id, int rc, const char* text);
    void (*bridge_clipboard_changed)(void);
    void (*bridge_geocode_result)(int request_id, int rc, const char* json);
    void (*bridge_network_access)(int level);
    void* surface_window;
    int surface_width;
    int surface_height;
    int surface_state;
    int pending_lifecycle[OHOS_MAX_PENDING_LIFECYCLE];
    int pending_count;
};

// One bridged application per process, matching the ArkTS one-ability model.
static OhosHostAppHandle* g_app = NULL;

// A context published before the app handle exists (the page can appear before the ability's
// bootstrap reaches start_app). start_app adopts this snapshot when it has no context of its
// own; an app-provided context always wins. Guarded by g_context_mutex: start_app takes the
// snapshot out of this slot before using it, so no reader can race a replacement free.
static char* g_pending_context_json = NULL;

// Lifecycle events and the NodeContent handle that arrive before an app handle exists (the
// shell can push ability events while the launch thread is still initializing the runtime).
// They are queued here and transferred to the handle when start_app publishes it, so the
// managed bridge still sees them once it registers. Guarded by g_context_mutex.
static int g_pending_lifecycle[OHOS_MAX_PENDING_LIFECYCLE];
static int g_pending_lifecycle_count = 0;
static void* g_pending_node_content = NULL;

// Bridge callbacks registered by the managed side while no app handle exists. start_app binds
// them to the handle when it publishes g_app (and flushes the queues above to them) instead of
// dropping the registration: the managed bridge registers once and never retries. Guarded by
// g_context_mutex like the queues above.
static void* g_pending_bridge_lifecycle = NULL;
static void* g_pending_bridge_node = NULL;
static void* g_pending_bridge_surface = NULL;

// Defined after the context helpers; used by the failed-launch cleanup in start_app.
static void OhosHostFreeRetiredContexts(OhosHostAppHandle* handle);

// start_app re-entry guard: one bridged application per process, and a second start while the
// first is still initializing would overwrite g_app and leak the first handle.
static int g_launch_in_progress = 0;

// Clears the re-entry guard after a failed launch. A successful launch keeps g_app set, which
// rejects a second start on its own.
static void OhosHostEndLaunch(void) {
    pthread_mutex_lock(&g_context_mutex);
    g_launch_in_progress = 0;
    pthread_mutex_unlock(&g_context_mutex);
}

// The XComponent may be created before the application handle exists, so keep the latest
// surface state here and forward it when the bridge registers.
static void* g_surface_window = NULL;
static int g_surface_width = 0;
static int g_surface_height = 0;
static int g_surface_state = -1;
static int g_surface_valid = 0;

static void* OhosAppThread(void* arg) {
    OhosHostAppHandle* handle = (OhosHostAppHandle*)arg;
    fprintf(stderr, "[openharmony-host] run_app entering\n");
    fflush(stderr);
    handle->exit_code = handle->run_app(handle->ctx);
    fprintf(stderr, "[openharmony-host] run_app exited: %d\n", handle->exit_code);
    fflush(stderr);
    OH_LOG_INFO(LOG_APP, "[openharmony-host] app Main exited rc=%{public}d", handle->exit_code);
    return NULL;
}

// Whether a context JSON names a payload directory: the "appDir" key is present and its value
// is a non-empty string. The shells emit compact JSON (JSON.stringify), so the textual check
// is enough to tell a real snapshot from the empty/placeholder one; a false negative only
// keeps the start context (the managed parser still sees both sources).
static int OhosHostContextNamesAppDir(const char* json) {
    if (json == NULL) {
        return 0;
    }
    const char* key = strstr(json, "\"appDir\"");
    if (key == NULL) {
        return 0;
    }
    const char* colon = strchr(key + 8, ':');
    if (colon == NULL) {
        return 0;
    }
    const char* value = colon + 1;
    while (*value == ' ' || *value == '\t' || *value == '\n' || *value == '\r') {
        value++;
    }
    if (*value != '"') {
        return 0;
    }
    value++;
    return *value != '"' && *value != '\0';
}

// Binds a bridge registration to a live handle and delivers everything the handle queued
// before it: the pre-publish lifecycle queue, the pending NodeContent and the current surface.
// The queue fields are copied and cleared under g_context_mutex; the node content is taken over
// and its slot cleared, so a second registration (Attach is one-shot, but a re-register must
// not double-attach) cannot deliver it twice. The managed callbacks run after the unlock: a
// callback may re-enter any host entry, and g_context_mutex never nests and is never held
// across a managed callback (the a11y path uses its own g_a11y_mutex, never this one).
static void OhosHostBindAndFlushBridge(OhosHostAppHandle* handle, void* lifecycle, void* node, void* surface) {
    int pending[OHOS_MAX_PENDING_LIFECYCLE];
    int pending_count = 0;
    void* node_content = NULL;
    int has_surface = 0;
    void* surface_window = NULL;
    int surface_width = 0;
    int surface_height = 0;
    int surface_state = -1;
    pthread_mutex_lock(&g_context_mutex);
    if (handle == NULL || g_app != handle) {
        // Joined (or never published): do not touch the handle, it is not ours anymore.
        pthread_mutex_unlock(&g_context_mutex);
        return;
    }
    handle->bridge_lifecycle = (void (*)(int))lifecycle;
    handle->bridge_node = (void (*)(void*))node;
    handle->bridge_surface = (void (*)(void*, int, int, int))surface;
    pending_count = handle->pending_count;
    for (int i = 0; i < pending_count; i++) {
        pending[i] = handle->pending_lifecycle[i];
    }
    handle->pending_count = 0;
    if (node != NULL && handle->node_content != NULL) {
        node_content = handle->node_content;
        handle->node_content = NULL;
    }
    if (surface != NULL && g_surface_valid) {
        has_surface = 1;
        surface_window = g_surface_window;
        surface_width = g_surface_width;
        surface_height = g_surface_height;
        surface_state = g_surface_state;
    }
    pthread_mutex_unlock(&g_context_mutex);
    if (has_surface) {
        ((void (*)(void*, int, int, int))surface)(surface_window, surface_width, surface_height, surface_state);
    }
    for (int i = 0; i < pending_count; i++) {
        if (lifecycle != NULL) {
            ((void (*)(int))lifecycle)(pending[i]);
        }
    }
    if (node != NULL && node_content != NULL) {
        ((void (*)(void*))node)(node_content);
    }
}

int ohos_host_start_app(const char* app_dir, const char* app_assembly_file,
                        const char* args_json, const char* context_json,
                        OhosHostAppHandle** out_handle) {
    OH_LOG_INFO(LOG_APP, "[openharmony-host] start_app begin dir=%{public}s", app_dir != NULL ? app_dir : "(null)");
    // Reject a second start up front: one bridged application per process (g_app), and until
    // the first launch publishes its handle the guard keeps two launch threads from racing
    // g_app/g_pending_context_json. No state is allocated on a rejected call.
    pthread_mutex_lock(&g_context_mutex);
    if (g_app != NULL || g_launch_in_progress) {
        pthread_mutex_unlock(&g_context_mutex);
        fprintf(stderr, "[openharmony-host] start_app: an app is already running or launching\n");
        return -1;
    }
    g_launch_in_progress = 1;
    pthread_mutex_unlock(&g_context_mutex);

    char hostfxr_path[4096];
    char app_assembly_path[4096];
    if (path_join(hostfxr_path, sizeof(hostfxr_path), app_dir, "libhostfxr.so") != 0 ||
        path_join(app_assembly_path, sizeof(app_assembly_path), app_dir, app_assembly_file) != 0) {
        OhosHostEndLaunch();
        return -1;
    }

    void* hostfxr = dlopen(hostfxr_path, RTLD_NOW | RTLD_LOCAL);
    if (hostfxr == NULL) {
        const char* dl_error = dlerror();
        OH_LOG_ERROR(LOG_APP, "[openharmony-host] start_app dlopen(%{public}s) failed: %{public}s",
                     hostfxr_path, dl_error);
        fprintf(stderr, "[openharmony-host] dlopen(%s) failed: %s\n", hostfxr_path, dl_error);
        OhosHostEndLaunch();
        return -1;
    }

    ohos_set_error_writer_fn set_error_writer = (ohos_set_error_writer_fn)dlsym(hostfxr, "hostfxr_set_error_writer");
    if (set_error_writer != NULL) {
        set_error_writer(ohos_error_writer);
    }

    ohos_initialize_for_dotnet_command_line_fn initialize =
        (ohos_initialize_for_dotnet_command_line_fn)dlsym(hostfxr, "hostfxr_initialize_for_dotnet_command_line");
    ohos_close_fn close_ctx = (ohos_close_fn)dlsym(hostfxr, "hostfxr_close");
    ohos_run_app_fn run_app = (ohos_run_app_fn)dlsym(hostfxr, "hostfxr_run_app");
    if (initialize == NULL || close_ctx == NULL || run_app == NULL) {
        fprintf(stderr, "[openharmony-host] hostfxr symbols missing\n");
        OH_LOG_ERROR(LOG_APP, "[openharmony-host] start_app: hostfxr symbols missing in %{public}s", hostfxr_path);
        OhosHostEndLaunch();
        return -1;
    }

    // A context published before this call (ohos_host_set_app_context while no handle
    // existed) supersedes a start context that is absent or does not name a payload
    // directory: the page can publish before the ability's bootstrap reaches start_app, and
    // the stale start context must not overwrite the explicit publish. The adoption itself
    // happens below, after initialize, under g_context_mutex.
    const char* effective_context = context_json;
    if (effective_context != NULL && effective_context[0] == '\0') {
        effective_context = NULL;
    }

    const char* argv[1] = {app_assembly_path};
    ohos_hostfxr_initialize_parameters params;
    params.size = sizeof(params);
    params.host_path = app_dir;
    params.dotnet_root = getenv("DOTNET_ROOT");

    void* ctx = NULL;
    int rc = initialize(1, argv, &params, &ctx);
    if (rc != 0 || ctx == NULL) {
        fprintf(stderr, "[openharmony-host] initialize_for_dotnet_command_line rc=0x%x\n", rc);
        OH_LOG_ERROR(LOG_APP, "[openharmony-host] start_app: hostfxr command-line init rc=0x%{public}x dir=%{public}s",
                     (unsigned)rc, app_dir != NULL ? app_dir : "(null)");
        OhosHostEndLaunch();
        return -1;
    }

    OhosHostAppHandle* handle = (OhosHostAppHandle*)calloc(1, sizeof(OhosHostAppHandle));
    if (handle == NULL) {
        close_ctx(ctx);
        OhosHostEndLaunch();
        return -1;
    }
    handle->hostfxr = hostfxr;
    handle->ctx = ctx;
    handle->run_app = run_app;
    handle->close_ctx = close_ctx;
    (void)args_json;
    // Resolve the pending context and publish the handle under one lock: a set_app_context
    // that ran before this critical section left its snapshot in the pending slot and is
    // adopted (or freed as superseded) here, one that runs after sees g_app and retires the
    // handle snapshot instead. The launch thread never touches the pending slot outside the
    // lock, so no reader can race a replacement free.
    pthread_mutex_lock(&g_context_mutex);
    char* adopted_pending = NULL;
    if (g_pending_context_json != NULL &&
        (effective_context == NULL || !OhosHostContextNamesAppDir(effective_context))) {
        adopted_pending = g_pending_context_json;
        g_pending_context_json = NULL;
        effective_context = adopted_pending;
    } else if (g_pending_context_json != NULL) {
        // Superseded by a start context that names a payload directory; free it here while
        // the lock guarantees no reader can hold it.
        free(g_pending_context_json);
        g_pending_context_json = NULL;
    }
    if (effective_context != NULL) {
        setenv("OHOS_HOST_APP_CONTEXT", effective_context, 1);
        handle->context_json = strdup(effective_context);
    }
    // The pending snapshot was adopted or superseded; the handle owns its own copy now.
    free(adopted_pending);
    // Events that arrived before the handle existed are transferred to it here (the managed
    // bridge cannot have registered yet: register_bridge requires g_app), and any later event
    // goes straight to the handle's own queue.
    handle->pending_count = g_pending_lifecycle_count;
    for (int i = 0; i < g_pending_lifecycle_count; i++) {
        handle->pending_lifecycle[i] = g_pending_lifecycle[i];
    }
    g_pending_lifecycle_count = 0;
    if (g_pending_node_content != NULL) {
        handle->node_content = g_pending_node_content;
        g_pending_node_content = NULL;
    }
    // A bridge registered before this handle existed is bound atomically with the publish, so
    // a racing notify sees the real callbacks and never queues an event behind a registration
    // that already happened. The callback values are captured for the post-create flush below
    // and for the failed-launch path, which hands them back for a retry.
    void* pending_lifecycle_cb = g_pending_bridge_lifecycle;
    void* pending_node_cb = g_pending_bridge_node;
    void* pending_surface_cb = g_pending_bridge_surface;
    g_pending_bridge_lifecycle = NULL;
    g_pending_bridge_node = NULL;
    g_pending_bridge_surface = NULL;
    handle->bridge_lifecycle = (void (*)(int))pending_lifecycle_cb;
    handle->bridge_node = (void (*)(void*))pending_node_cb;
    handle->bridge_surface = (void (*)(void*, int, int, int))pending_surface_cb;
    int pending_bridge = pending_lifecycle_cb != NULL || pending_node_cb != NULL || pending_surface_cb != NULL;
    g_app = handle;
    g_launch_in_progress = 0;
    pthread_mutex_unlock(&g_context_mutex);

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_JOINABLE);
    const char* run_sync = getenv("OHOS_HOST_RUN_SYNC");
    if (run_sync != NULL && run_sync[0] == '1') {
        fprintf(stderr, "[openharmony-host] start_app: running the app on the calling thread\n");
        fflush(stderr);
        if (pending_bridge) {
            OhosHostBindAndFlushBridge(handle, pending_lifecycle_cb, pending_node_cb, pending_surface_cb);
        }
        // Hand the handle out first so the shell can push events while the app runs.
        *out_handle = handle;
        handle->exit_code = run_app(ctx);
        handle->joined = 1;
        return 0;
    }
    fprintf(stderr, "[openharmony-host] start_app: launching app thread\n");
    fflush(stderr);
    int thread_rc = pthread_create(&handle->thread, &attr, OhosAppThread, handle);
    pthread_attr_destroy(&attr);
    if (thread_rc != 0) {
        fprintf(stderr, "[openharmony-host] pthread_create failed: %d\n", thread_rc);
        char* context_json = NULL;
        pthread_mutex_lock(&g_context_mutex);
        if (g_app == handle) {
            g_app = NULL;
        }
        // The launch must not consume what it transferred: hand the queued events and the
        // NodeContent back to the pending slots the next start_app adopts, and requeue a
        // pre-launch bridge registration too (the managed side never re-registers it).
        for (int i = 0; i < handle->pending_count && g_pending_lifecycle_count < OHOS_MAX_PENDING_LIFECYCLE; i++) {
            g_pending_lifecycle[g_pending_lifecycle_count++] = handle->pending_lifecycle[i];
        }
        handle->pending_count = 0;
        if (handle->node_content != NULL) {
            g_pending_node_content = handle->node_content;
            handle->node_content = NULL;
        }
        if (pending_bridge) {
            g_pending_bridge_lifecycle = pending_lifecycle_cb;
            g_pending_bridge_node = pending_node_cb;
            g_pending_bridge_surface = pending_surface_cb;
        }
        context_json = handle->context_json;
        handle->context_json = NULL;
        OhosHostFreeRetiredContexts(handle);
        pthread_mutex_unlock(&g_context_mutex);
        close_ctx(ctx);
        free(context_json);
        free(handle);
        return -1;
    }
    if (pending_bridge) {
        // The app thread is live: deliver what the handle queued before the registration was
        // published, exactly like a register_bridge call would.
        OhosHostBindAndFlushBridge(handle, pending_lifecycle_cb, pending_node_cb, pending_surface_cb);
    }

    OH_LOG_INFO(LOG_APP, "[openharmony-host] start_app launched dir=%{public}s", app_dir != NULL ? app_dir : "(null)");
    *out_handle = handle;
    return 0;
}

const char* ohos_host_get_app_context(void) {
    // The snapshot is replaced under g_context_mutex (set_app_context) and freed under it at
    // join, so the getter reads the handle under the same lock. The returned pointer follows
    // the documented contract: owned by the handle, valid until the next publish or join.
    pthread_mutex_lock(&g_context_mutex);
    const char* json = g_app != NULL ? g_app->context_json : NULL;
    pthread_mutex_unlock(&g_context_mutex);
    return json;
}

// Keeps a replaced snapshot alive until join: a managed reader may be copying the string the
// getter returned when the replacement lands. If the bookkeeping node cannot be allocated the
// snapshot is leaked instead of freed under the reader - the safer failure mode.
static void OhosHostRetireContextSnapshot(OhosHostAppHandle* handle, char* json) {
    if (handle == NULL || json == NULL) {
        return;
    }
    OhosRetiredContext* retired = (OhosRetiredContext*)malloc(sizeof(OhosRetiredContext));
    if (retired == NULL) {
        fprintf(stderr, "[openharmony-host] set_app_context: retire node alloc failed; keeping the old snapshot\n");
        return;
    }
    retired->json = json;
    retired->next = handle->retired_contexts;
    handle->retired_contexts = retired;
}

static void OhosHostFreeRetiredContexts(OhosHostAppHandle* handle) {
    OhosRetiredContext* retired = handle->retired_contexts;
    handle->retired_contexts = NULL;
    while (retired != NULL) {
        OhosRetiredContext* next = retired->next;
        free(retired->json);
        free(retired);
        retired = next;
    }
}

// Replays the stored surface state to the registered managed bridge. The managed surface
// callback re-reads the app context before it forwards the event
// (OpenHarmonyBridge.OnSurfaceNative -> RefreshContext), so this is the notification path a
// context re-publish rides. Returns 1 when the bridge callback was invoked.
static int OhosHostReplaySurfaceNotification(void) {
    if (g_app == NULL || g_app->bridge_surface == NULL || !g_surface_valid) {
        return 0;
    }
    if (g_surface_state != (int)OHOS_SURFACE_CREATED && g_surface_state != (int)OHOS_SURFACE_CHANGED) {
        // Only a live surface carries the event the managed side refreshes on; a destroyed
        // one must not be replayed, and the next created/changed event re-reads anyway.
        return 0;
    }
    g_app->bridge_surface(g_surface_window, g_surface_width, g_surface_height, g_surface_state);
    return 1;
}

int ohos_host_notify_context(void) {
    return OhosHostReplaySurfaceNotification();
}

// ---------------------------------------------------------------------------
// Bundle metadata (Essentials IAppInfo version/build/name): the shell publishes the HAP's
// real values once at page load; the managed side reads stored copies.
// ---------------------------------------------------------------------------

static pthread_mutex_t g_bundle_info_mutex = PTHREAD_MUTEX_INITIALIZER;
static char* g_bundle_version = NULL;
static char* g_bundle_build = NULL;
static char* g_bundle_name = NULL;

// Replaces one field. A replaced string is deliberately not freed: the getters return the
// stored pointer and a managed reader may still be copying it while a re-publish lands. The
// shell publishes once per page, so the bounded leak (a few bytes) is the safe failure mode.
static void OhosHostStoreBundleField(char** slot, const char* value) {
    char* copy = NULL;
    if (value != NULL && value[0] != '\0') {
        copy = strdup(value);
        if (copy == NULL) {
            return;
        }
    }
    pthread_mutex_lock(&g_bundle_info_mutex);
    *slot = copy;
    pthread_mutex_unlock(&g_bundle_info_mutex);
}

int ohos_host_set_bundle_info(const char* version, const char* build, const char* name) {
    if (version == NULL || version[0] == '\0' || build == NULL || build[0] == '\0') {
        fprintf(stderr, "[openharmony-host] set_bundle_info: version/build are required\n");
        return -1;
    }
    OhosHostStoreBundleField(&g_bundle_version, version);
    OhosHostStoreBundleField(&g_bundle_build, build);
    OhosHostStoreBundleField(&g_bundle_name, name);
    fprintf(stderr, "[openharmony-host] set_bundle_info: version=%s build=%s\n", version, build);
    return 0;
}

static const char* OhosHostReadBundleField(char** slot) {
    pthread_mutex_lock(&g_bundle_info_mutex);
    const char* value = *slot != NULL ? *slot : "";
    pthread_mutex_unlock(&g_bundle_info_mutex);
    return value;
}

const char* ohos_host_get_bundle_version(void) {
    return OhosHostReadBundleField(&g_bundle_version);
}

const char* ohos_host_get_bundle_build(void) {
    return OhosHostReadBundleField(&g_bundle_build);
}

const char* ohos_host_get_bundle_name(void) {
    return OhosHostReadBundleField(&g_bundle_name);
}

int ohos_host_set_app_context(const char* json) {
    if (json == NULL || json[0] == '\0') {
        fprintf(stderr, "[openharmony-host] set_app_context: empty context ignored\n");
        return -1;
    }
    char* copy = strdup(json);
    if (copy == NULL) {
        return -1;
    }
    // The pending-vs-live decision is taken under g_context_mutex: start_app publishes g_app
    // under the same lock, so a publish racing the launch either lands in the pending slot the
    // launch adopts or replaces the handle snapshot, never a mix of both.
    pthread_mutex_lock(&g_context_mutex);
    if (g_app == NULL) {
        // No handle yet: keep the snapshot for the next start_app, which adopts it only when
        // it has no context of its own. The lock makes this replacement atomic with the
        // launch thread's adoption in start_app, which takes the pointer out of the slot
        // before using it, so the pending copy has no concurrent reader here.
        free(g_pending_context_json);
        g_pending_context_json = copy;
        pthread_mutex_unlock(&g_context_mutex);
        fprintf(stderr, "[openharmony-host] set_app_context: kept %d bytes for the next start_app\n",
                (int)strlen(copy));
        return 0;
    }
    setenv("OHOS_HOST_APP_CONTEXT", copy, 1);
    OhosHostRetireContextSnapshot(g_app, g_app->context_json);
    g_app->context_json = copy;
    pthread_mutex_unlock(&g_context_mutex);
    int notified = OhosHostReplaySurfaceNotification();
    fprintf(stderr, "[openharmony-host] set_app_context: %d bytes, notified=%d\n",
            (int)strlen(copy), notified);
    return 0;
}

void ohos_host_register_bridge(void* lifecycle, void* node, void* surface) {
    fprintf(stderr, "[openharmony-host] register_bridge lifecycle=%p node=%p surface=%p g_app=%p\n",
            lifecycle, node, surface, (void*)g_app);
    fflush(stderr);
    pthread_mutex_lock(&g_context_mutex);
    OhosHostAppHandle* handle = g_app;
    if (handle == NULL) {
        // The managed side can register before start_app publishes the handle (this used to be
        // a silent no-op the managed bridge never retries). Queue the callbacks like the
        // lifecycle/node-content queues; start_app binds and flushes them on publish.
        g_pending_bridge_lifecycle = lifecycle;
        g_pending_bridge_node = node;
        g_pending_bridge_surface = surface;
        pthread_mutex_unlock(&g_context_mutex);
        return;
    }
    pthread_mutex_unlock(&g_context_mutex);
    // Bind and flush under the queue lock; the callbacks themselves run outside it.
    OhosHostBindAndFlushBridge(handle, lifecycle, node, surface);
}

// Draws a frame into the XComponent surface. mode 0 = RGBA gradient (first frame proof),
// mode 1 = solid colour (managed request). Returns 0 on success.
static int OhosDrawFrame(void* window, int width, int height, int mode, unsigned int argb) {
    if (window == NULL || width <= 0 || height <= 0) {
        return -1;
    }
    OHNativeWindow* native_window = (OHNativeWindow*)window;
    uint64_t usage = NATIVEBUFFER_USAGE_CPU_WRITE | NATIVEBUFFER_USAGE_MEM_DMA;
    if (OH_NativeWindow_NativeWindowHandleOpt(native_window, SET_BUFFER_GEOMETRY, width, height) != 0 ||
        OH_NativeWindow_NativeWindowHandleOpt(native_window, SET_FORMAT, NATIVEBUFFER_PIXEL_FMT_RGBA_8888) != 0 ||
        OH_NativeWindow_NativeWindowHandleOpt(native_window, SET_USAGE, usage) != 0) {
        fprintf(stderr, "[openharmony-host] surface: buffer options failed\n");
        return -1;
    }

    int fence = -1;
    OHNativeWindowBuffer* buffer = NULL;
    if (OH_NativeWindow_NativeWindowRequestBuffer(native_window, &buffer, &fence) != 0 || buffer == NULL) {
        fprintf(stderr, "[openharmony-host] surface: request buffer failed\n");
        return -1;
    }
    BufferHandle* handle = OH_NativeWindow_GetBufferHandleFromNative(buffer);
    if (handle != NULL) {
        void* addr = mmap(handle->virAddr, handle->size, PROT_READ | PROT_WRITE, MAP_SHARED, handle->fd, 0);
        if (addr != MAP_FAILED) {
            uint8_t* base = (uint8_t*)addr;
            for (int y = 0; y < height; y++) {
                uint32_t* row = (uint32_t*)(base + (size_t)y * handle->stride);
                for (int x = 0; x < width; x++) {
                    if (mode == 1) {
                        row[x] = argb;
                    } else {
                        uint8_t r = (uint8_t)(255 * x / (width > 1 ? width - 1 : 1));
                        uint8_t g = (uint8_t)(255 * y / (height > 1 ? height - 1 : 1));
                        row[x] = (uint32_t)r | ((uint32_t)g << 8) | ((uint32_t)0x80 << 16) | ((uint32_t)0xff << 24);
                    }
                }
            }
            munmap(addr, handle->size);
        }
    }
    Region region = { NULL, 0 };
    OH_NativeWindow_NativeWindowFlushBuffer(native_window, buffer, fence, region);
    fprintf(stderr, "[openharmony-host] surface: frame drawn (mode=%d %dx%d)\n", mode, width, height);
    fflush(stderr);
    return 0;
}

static void OhosDrawFirstFrame(void* window, int width, int height) {
    OhosDrawFrame(window, width, height, 0, 0);
}

int ohos_host_fill_surface(unsigned int argb) {
    if (!g_surface_valid || g_surface_state == (int)OHOS_SURFACE_DESTROYED) {
        fprintf(stderr, "[openharmony-host] fill_surface: no surface yet\n");
        return -1;
    }
    return OhosDrawFrame(g_surface_window, g_surface_width, g_surface_height, 1, argb);
}

void ohos_host_set_native_window(void* window, int width, int height, ohos_surface_state state) {
    fprintf(stderr, "[openharmony-host] surface state=%d window=%p %dx%d\n",
            (int)state, window, width, height);
    fflush(stderr);
    g_surface_window = window;
    g_surface_width = width;
    g_surface_height = height;
    g_surface_state = (int)state;
    g_surface_valid = 1;
    if (state == OHOS_SURFACE_CREATED || state == OHOS_SURFACE_CHANGED) {
        OhosDrawFirstFrame(window, width, height);
    }
    if (g_app != NULL) {
        g_app->surface_window = window;
        g_app->surface_width = width;
        g_app->surface_height = height;
        g_app->surface_state = (int)state;
        if (g_app->bridge_surface != NULL) {
            g_app->bridge_surface(window, width, height, (int)state);
        }
    }
}

void ohos_host_register_text_input(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_text_input = (void (*)(const char*))callback;
    }
}

void ohos_host_register_input(void* touch, void* frame) {
    fprintf(stderr, "[openharmony-host] register_input touch=%p frame=%p g_app=%p\n", touch, frame, (void*)g_app);
    fflush(stderr);
    if (g_app == NULL) {
        return;
    }
    g_app->bridge_touch = (void (*)(int, float, float, int, int))touch;
    g_app->bridge_frame = (void (*)(int64_t, int64_t))frame;
}

void ohos_host_notify_touch(int type, float x, float y, int pointerCount, int pointerId) {
    if (g_app != NULL && g_app->bridge_touch != NULL) {
        g_app->bridge_touch(type, x, y, pointerCount, pointerId);
    }
}

static void (*g_text_input_listener)(int show) = NULL;

void ohos_host_set_text_input_listener(void (*listener)(int show)) {
    g_text_input_listener = listener;
}

void ohos_host_request_text_input(int show) {
    fprintf(stderr, "[openharmony-host] text input request: %d\n", show);
    fflush(stderr);
    if (g_text_input_listener != NULL) {
        g_text_input_listener(show);
    }
}

// ---------------------------------------------------------------------------
// Essentials implemented directly on the OpenHarmony NDK (no ArkTS involved).
// ---------------------------------------------------------------------------

int ohos_host_vibrate(int duration_ms) {
    Vibrator_Attribute attribute;
    attribute.vibratorId = 0;
    attribute.usage = (Vibrator_Usage)0; /* Vibrator_Usage default (unknown) */
    int32_t rc = OH_Vibrator_PlayVibration(duration_ms > 0 ? duration_ms : 100, attribute);
    if (rc != 0) {
        fprintf(stderr, "[openharmony-host] vibrate rc=%d\n", rc);
    }
    return (int)rc;
}

// ---------------------------------------------------------------------------
// Geolocation: a locating session whose callback stores the newest fix.
// ---------------------------------------------------------------------------

static double g_last_latitude = 0.0;
static double g_last_longitude = 0.0;
static double g_last_altitude = 0.0;
static int g_location_has_fix = 0;
static Location_RequestConfig* g_location_config = NULL;

static void OnLocationReported(Location_Info* location, void* userData) {
    (void)userData;
    if (location == NULL) {
        return;
    }
    Location_BasicInfo info = OH_LocationInfo_GetBasicInfo(location);
    g_last_latitude = info.latitude;
    g_last_longitude = info.longitude;
    g_last_altitude = info.altitude;
    g_location_has_fix = 1;
}

int ohos_host_location_start(void) {
    if (g_location_config == NULL) {
        g_location_config = OH_Location_CreateRequestConfig();
        if (g_location_config == NULL) {
            return -1;
        }
        OH_LocationRequestConfig_SetCallback(g_location_config, OnLocationReported, NULL);
    }
    int32_t rc = OH_Location_StartLocating(g_location_config);
    if (rc != 0) {
        fprintf(stderr, "[openharmony-host] location start rc=%d\n", rc);
    }
    return (int)rc;
}

int ohos_host_location_stop(void) {
    if (g_location_config == NULL) {
        return 0;
    }
    int32_t rc = OH_Location_StopLocating(g_location_config);
    return (int)rc;
}

int ohos_host_location_get(double* latitude, double* longitude, double* altitude) {
    if (!g_location_has_fix) {
        return 0;
    }
    if (latitude != NULL) *latitude = g_last_latitude;
    if (longitude != NULL) *longitude = g_last_longitude;
    if (altitude != NULL) *altitude = g_last_altitude;
    return 1;
}

// ---------------------------------------------------------------------------
// Soft keyboard: attach an (empty) editor proxy so the platform can show the input method.
// The text callbacks are the next step; this already drives the keyboard from the platform.
// ---------------------------------------------------------------------------

static InputMethod_TextEditorProxy* g_editor_proxy = NULL;
static InputMethod_InputMethodProxy* g_inputmethod_proxy = NULL;

// IME text callback buffer: the host tracks what the keyboard typed so insert/delete can be
// forwarded to the managed bridge as whole-text updates (the existing TextInput contract).
static char g_ime_text[4096] = {0};

static void ImeForwardText(void) {
    if (g_app != NULL && g_app->bridge_text_input != NULL) {
        g_app->bridge_text_input(g_ime_text);
    }
}

// The largest prefix of utf8 that is at most limit bytes and ends on a UTF-8 sequence
// boundary (walks back over continuation bytes whose lead byte was cut off). The IME paths
// use it so a truncated buffer is always valid UTF-8 for the managed TextInput contract.
static size_t ImeUtf8PrefixLength(const char* utf8, size_t limit) {
    size_t take = strlen(utf8);
    if (take > limit) {
        take = limit;
        while (take > 0 && ((unsigned char)utf8[take] & 0xC0) == 0x80) {
            take--;
        }
    }
    return take;
}

static void ImeAppendUtf8(const char* utf8) {
    size_t used = strlen(g_ime_text);
    if (used >= sizeof(g_ime_text) - 1) {
        return;
    }
    size_t take = ImeUtf8PrefixLength(utf8, sizeof(g_ime_text) - 1 - used);
    memcpy(g_ime_text + used, utf8, take);
    g_ime_text[used + take] = '\0';
}

static void ImeDeleteBackward(int32_t length) {
    for (int32_t i = 0; i < length; i++) {
        size_t used = strlen(g_ime_text);
        if (used > 0) {
            /* Back off one UTF-8 sequence. */
            size_t cut = used - 1;
            while (cut > 0 && (g_ime_text[cut] & 0xC0) == 0x80) {
                cut--;
            }
            g_ime_text[cut] = '\0';
        }
    }
}

static void OnImeInsertText(InputMethod_TextEditorProxy* proxy, const char16_t* text, size_t length) {
    (void)proxy;
    if (text == NULL || length == 0) {
        return;
    }
    /* UTF-16 -> UTF-8. Surrogate pairs become one 4-byte sequence, and the loop stops before
       the code point that would not fit together with the terminator, so the buffer never
       ends inside a sequence nor with half of a surrogate pair (BMP-only lone surrogates keep
       the historical pass-through). */
    char utf8[1024];
    size_t out = 0;
    for (size_t i = 0; i < length; i++) {
        uint32_t c = (uint32_t)text[i];
        size_t bytes;
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < length &&
            text[i + 1] >= 0xDC00 && text[i + 1] <= 0xDFFF) {
            c = 0x10000 + ((c - 0xD800) << 10) + ((uint32_t)text[i + 1] - 0xDC00);
            i++;
            bytes = 4;
        } else if (c < 0x80) {
            bytes = 1;
        } else if (c < 0x800) {
            bytes = 2;
        } else {
            bytes = 3;
        }
        if (out + bytes + 1 > sizeof(utf8)) {
            break;   /* no room for this code point and the terminator */
        }
        if (bytes == 4) {
            utf8[out++] = (char)(0xF0 | (c >> 18));
            utf8[out++] = (char)(0x80 | ((c >> 12) & 0x3F));
            utf8[out++] = (char)(0x80 | ((c >> 6) & 0x3F));
            utf8[out++] = (char)(0x80 | (c & 0x3F));
        } else if (bytes == 3) {
            utf8[out++] = (char)(0xE0 | (c >> 12));
            utf8[out++] = (char)(0x80 | ((c >> 6) & 0x3F));
            utf8[out++] = (char)(0x80 | (c & 0x3F));
        } else if (bytes == 2) {
            utf8[out++] = (char)(0xC0 | (c >> 6));
            utf8[out++] = (char)(0x80 | (c & 0x3F));
        } else {
            utf8[out++] = (char)c;
        }
    }
    utf8[out] = '\0';
    ImeAppendUtf8(utf8);
    ImeForwardText();
}

static void OnImeDeleteForward(InputMethod_TextEditorProxy* proxy, int32_t length) {
    (void)proxy;
    (void)length;
    /* Forward deletion at the end of the buffer is a no-op for our single-caret model. */
}

static void OnImeDeleteBackward(InputMethod_TextEditorProxy* proxy, int32_t length) {
    (void)proxy;
    ImeDeleteBackward(length);
    ImeForwardText();
}

static void OnImeGetTextConfig(InputMethod_TextEditorProxy* proxy, InputMethod_TextConfig* config) {
    (void)proxy;
    (void)config;
}

void ohos_host_keyboard_set_text(const char* utf8) {
    g_ime_text[0] = '\0';
    if (utf8 != NULL) {
        // Truncate to the buffer but back off to a UTF-8 sequence boundary; the old strncpy
        // could hand the managed side a buffer ending in half of a multi-byte character.
        size_t take = ImeUtf8PrefixLength(utf8, sizeof(g_ime_text) - 1);
        memcpy(g_ime_text, utf8, take);
        g_ime_text[take] = '\0';
    }
}

static int EnsureInputMethod(void) {
    if (g_inputmethod_proxy != NULL) {
        return 0;
    }
    if (g_editor_proxy == NULL) {
        g_editor_proxy = OH_TextEditorProxy_Create();
        if (g_editor_proxy == NULL) {
            return -1;
        }
        OH_TextEditorProxy_SetInsertTextFunc(g_editor_proxy, OnImeInsertText);
        OH_TextEditorProxy_SetDeleteForwardFunc(g_editor_proxy, OnImeDeleteForward);
        OH_TextEditorProxy_SetDeleteBackwardFunc(g_editor_proxy, OnImeDeleteBackward);
        OH_TextEditorProxy_SetGetTextConfigFunc(g_editor_proxy, OnImeGetTextConfig);
    }
    InputMethod_AttachOptions* options = OH_AttachOptions_Create(false);
    if (options == NULL) {
        return -1;
    }
    InputMethod_ErrorCode rc = OH_InputMethodController_Attach(g_editor_proxy, options, &g_inputmethod_proxy);
    OH_AttachOptions_Destroy(options);
    if (rc != 0) {
        fprintf(stderr, "[openharmony-host] input method attach rc=%d\n", rc);
        g_inputmethod_proxy = NULL;
        return (int)rc;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Safe area: reported by the shell (window.getWindowAvoidArea) and consumed by the app host.
// ---------------------------------------------------------------------------

static int g_avoid_top = 0;
static int g_avoid_bottom = 0;
static int g_avoid_left = 0;
static int g_avoid_right = 0;

void ohos_host_set_avoid_area(int top, int bottom, int left, int right) {
    g_avoid_top = top > 0 ? top : 0;
    g_avoid_bottom = bottom > 0 ? bottom : 0;
    g_avoid_left = left > 0 ? left : 0;
    g_avoid_right = right > 0 ? right : 0;
    fprintf(stderr, "[openharmony-host] avoid area t=%d b=%d l=%d r=%d\n", g_avoid_top, g_avoid_bottom, g_avoid_left, g_avoid_right);
}

int ohos_host_get_avoid_area(int* top, int* bottom, int* left, int* right) {
    if (top != NULL) *top = g_avoid_top;
    if (bottom != NULL) *bottom = g_avoid_bottom;
    if (left != NULL) *left = g_avoid_left;
    if (right != NULL) *right = g_avoid_right;
    return 1;
}

// ---------------------------------------------------------------------------
// WebView: the shell owns a hidden ArkWeb component; commands drive it and page events come back.
// ---------------------------------------------------------------------------

static void (*g_web_listener)(const char* op, const char* arg) = NULL;

void ohos_host_web_set_listener(void (*listener)(const char*, const char*)) {
    g_web_listener = listener;
}

void ohos_host_web_register_event(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_web_event = (void (*)(const char*, const char*))callback;
    }
}

void ohos_host_web_command(const char* op, const char* arg) {
    if (g_web_listener != NULL) {
        g_web_listener(op != NULL ? op : "", arg != NULL ? arg : "");
    }
}

void ohos_host_web_notify_event(const char* state, const char* url) {
    if (g_app != NULL && g_app->bridge_web_event != NULL) {
        g_app->bridge_web_event(state != NULL ? state : "", url != NULL ? url : "");
    }
}

// ---------------------------------------------------------------------------
// Pickers: requests go to the ArkTS shell (system picker), results come back with the file
// name and its content encoded as base64.
// ---------------------------------------------------------------------------

static void (*g_picker_listener)(int request_id, int kind) = NULL;

void ohos_host_picker_set_listener(void (*listener)(int, int)) {
    g_picker_listener = listener;
}

void ohos_host_picker_register_result(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_picker_result = (void (*)(int, int, const char*, const char*))callback;
    }
}

void ohos_host_picker_request(int request_id, int kind) {
    if (g_picker_listener != NULL) {
        g_picker_listener(request_id, kind);
    }
}

void ohos_host_picker_complete(int request_id, int rc, const char* name, const char* data_base64) {
    if (g_app != NULL && g_app->bridge_picker_result != NULL) {
        g_app->bridge_picker_result(request_id, rc, name, data_base64);
    }
}

// ---------------------------------------------------------------------------
// Runtime permissions: requests go to the ArkTS shell (abilityAccessCtrl), the granted/
// denied answer comes back through host.permissionResult.
// ---------------------------------------------------------------------------

static void (*g_permission_listener)(const char* permission, int request_id) = NULL;

void ohos_host_permission_set_listener(void (*listener)(const char*, int)) {
    g_permission_listener = listener;
}

void ohos_host_register_permission_result(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_permission_result = (void (*)(int, int))callback;
    }
}

void ohos_host_request_permission(const char* permission, int request_id) {
    if (g_permission_listener != NULL) {
        g_permission_listener(permission != NULL ? permission : "", request_id);
    }
}

void ohos_host_permission_complete(int request_id, int granted) {
    if (g_app != NULL && g_app->bridge_permission_result != NULL) {
        g_app->bridge_permission_result(request_id, granted != 0 ? 1 : 0);
    }
}

// ---------------------------------------------------------------------------
// Notification enablement (MAUI Permissions.PostNotifications): op 0 reads the system enable
// state, op 1 shows the system enable dialog; the shell answers through
// host.notificationPermissionResult -> ohos_host_notification_permission_complete.
// ---------------------------------------------------------------------------

static void (*g_notification_permission_listener)(int op, int request_id) = NULL;

void ohos_host_notification_permission_set_listener(void (*listener)(int, int)) {
    g_notification_permission_listener = listener;
}

void ohos_host_notification_permission_register_result(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_notification_permission_result = (void (*)(int, int))callback;
    }
}

void ohos_host_notification_permission_request(int op, int request_id) {
    if (g_notification_permission_listener != NULL) {
        g_notification_permission_listener(op, request_id);
    }
}

void ohos_host_notification_permission_complete(int request_id, int granted) {
    if (g_app != NULL && g_app->bridge_notification_permission_result != NULL) {
        g_app->bridge_notification_permission_result(request_id, granted != 0 ? 1 : 0);
    }
}

// ---------------------------------------------------------------------------
// Clipboard: requests go to the ArkTS shell (@ohos.pasteboard); the shell answers through
// host.clipboardResult and pushes change notifications through host.notifyClipboardChanged.
// ---------------------------------------------------------------------------

static void (*g_clipboard_listener)(int request_id, int op, const char* text) = NULL;

void ohos_host_clipboard_set_listener(void (*listener)(int, int, const char*)) {
    g_clipboard_listener = listener;
}

void ohos_host_clipboard_register_result(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_clipboard_result = (void (*)(int, int, const char*))callback;
    }
}

void ohos_host_clipboard_request(int request_id, int op, const char* text) {
    if (g_clipboard_listener != NULL) {
        g_clipboard_listener(request_id, op, text != NULL ? text : "");
    }
}

void ohos_host_clipboard_complete(int request_id, int rc, const char* text) {
    if (g_app != NULL && g_app->bridge_clipboard_result != NULL) {
        g_app->bridge_clipboard_result(request_id, rc, text != NULL ? text : "");
    }
}

void ohos_host_clipboard_register_changed(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_clipboard_changed = (void (*)(void))callback;
    }
}

void ohos_host_clipboard_notify_changed(void) {
    if (g_app != NULL && g_app->bridge_clipboard_changed != NULL) {
        g_app->bridge_clipboard_changed();
    }
}

// ---------------------------------------------------------------------------
// Shell search: the managed side publishes the SearchHandler state through
// ohos_host_shell_search_set (a one-way command dispatched by the NAPI shell search sink);
// the shell's search field reports the user's interactions back through
// ohos_host_shell_search_notify, which invokes the managed listener registered here.
// ---------------------------------------------------------------------------

static void (*g_shell_search_listener)(int op, const char* text) = NULL;

void ohos_host_shell_search_set_listener(void (*listener)(int, const char*)) {
    g_shell_search_listener = listener;
}

void ohos_host_shell_search_notify(int op, const char* text) {
    if (g_shell_search_listener != NULL) {
        g_shell_search_listener(op, text != NULL ? text : "");
    }
}

// ---------------------------------------------------------------------------
// Geocoding: requests go to the ArkTS shell (@ohos.geoLocationManager, lazily imported and
// permission-aware); the answer comes back through host.geocodeResult.
// ---------------------------------------------------------------------------

static void (*g_geocode_listener)(int request_id, int op, const char* arg) = NULL;

void ohos_host_geocode_set_listener(void (*listener)(int, int, const char*)) {
    g_geocode_listener = listener;
}

int ohos_host_geocode_request(int op, const char* arg, int request_id) {
    if (arg == NULL || g_geocode_listener == NULL) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] geocode request dropped: arg=%{public}s listener=%{public}s",
                    arg == NULL ? "null" : "set", g_geocode_listener == NULL ? "missing" : "set");
        return -1;
    }
    g_geocode_listener(request_id, op, arg);
    return 0;
}

void ohos_host_register_geocode_result(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_geocode_result = (void (*)(int, int, const char*))callback;
    }
}

void ohos_host_geocode_complete(int request_id, int rc, const char* json) {
    if (g_app != NULL && g_app->bridge_geocode_result != NULL) {
        g_app->bridge_geocode_result(request_id, rc, json != NULL ? json : "");
    }
}

// ---------------------------------------------------------------------------
// Connectivity: the shell's network observer calls ohos_host_network_access_notify, which
// re-reads the level through the same NDK path as ohos_host_network_access and hands it to
// the managed listener (registered by the managed side).
// ---------------------------------------------------------------------------

void ohos_host_network_access_register(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_network_access = (void (*)(int))callback;
    }
}

void ohos_host_network_access_notify(void) {
    if (g_app != NULL && g_app->bridge_network_access != NULL) {
        g_app->bridge_network_access(ohos_host_network_access());
    }
}

int ohos_host_keyboard_show(void) {
    if (EnsureInputMethod() != 0 || g_inputmethod_proxy == NULL) {
        return -1;
    }
    return (int)OH_InputMethodProxy_ShowKeyboard(g_inputmethod_proxy);
}

int ohos_host_keyboard_hide(void) {
    if (g_inputmethod_proxy == NULL) {
        return 0;
    }
    return (int)OH_InputMethodProxy_HideKeyboard(g_inputmethod_proxy);
}

int ohos_host_network_access(void) {
    int32_t hasDefault = 0;
    if (OH_NetConn_HasDefaultNet(&hasDefault) != 0 || hasDefault == 0) {
        return 1; /* none */
    }
    NetConn_NetHandle handle;
    if (OH_NetConn_GetDefaultNet(&handle) != 0) {
        return 2; /* local */
    }
    NetConn_NetCapabilities capabilities;
    if (OH_NetConn_GetNetCapabilities(&handle, &capabilities) != 0) {
        return 2;
    }
    for (int32_t i = 0; i < capabilities.netCapsSize; i++) {
        if (capabilities.netCaps[i] == NETCONN_NET_CAPABILITY_INTERNET) {
            return 3; /* internet */
        }
    }
    return 2;
}

int ohos_host_check_permission(const char* permission) {
    if (permission == NULL) {
        return 0;
    }
    return OH_AT_CheckSelfPermission(permission) ? 1 : 0;
}

static void (*g_vibration_listener)(int duration_ms) = NULL;

void ohos_host_set_vibration_listener(void (*listener)(int)) {
    g_vibration_listener = listener;
}

void ohos_host_request_vibration(int duration_ms) {
    if (g_vibration_listener != NULL) {
        g_vibration_listener(duration_ms);
    }
}

static void (*g_keystore_listener)(int request_id, const char* op, const char* alias, const char* data_base64) = NULL;

void ohos_host_keystore_set_listener(void (*listener)(int, const char*, const char*, const char*)) {
    g_keystore_listener = listener;
}

void ohos_host_keystore_register_result(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_keystore_result = (void (*)(int, int, const char*))callback;
    }
}

void ohos_host_keystore_request(int request_id, const char* op, const char* alias, const char* data_base64) {
    if (g_keystore_listener != NULL) {
        g_keystore_listener(request_id, op, alias, data_base64);
    }
}

void ohos_host_keystore_complete(int request_id, int rc, const char* data_base64) {
    if (g_app != NULL && g_app->bridge_keystore_result != NULL) {
        g_app->bridge_keystore_result(request_id, rc, data_base64);
    }
}

void ohos_host_notify_text_submitted(void) {
    if (g_app != NULL && g_app->bridge_text_submitted != NULL) {
        g_app->bridge_text_submitted();
    }
}

void ohos_host_register_text_submitted(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_text_submitted = (void (*)(void))callback;
    }
}

void ohos_host_notify_text_input(const char* utf8) {
    if (g_app != NULL && g_app->bridge_text_input != NULL && utf8 != NULL) {
        g_app->bridge_text_input(utf8);
    }
}

void ohos_host_notify_frame(int64_t timestamp, int64_t targetTimestamp) {
    if (g_app != NULL && g_app->bridge_frame != NULL) {
        g_app->bridge_frame(timestamp, targetTimestamp);
    }
}

void ohos_host_notify_lifecycle(OhosHostAppHandle* handle, ohos_lifecycle_event event) {
    fprintf(stderr, "[openharmony-host] notify evt=%d handle=%p registered=%d\n",
            (int)event, (void*)handle, handle ? (handle->bridge_lifecycle != NULL) : -1);
    fflush(stderr);
    if (handle == NULL) {
        // The NAPI g_handle is written only after start_app returns, so an event pushed while
        // the launch is still initializing arrives with a NULL handle. Resolve it through
        // g_app, or queue it for the handle that start_app is about to publish, instead of
        // dropping the event.
        pthread_mutex_lock(&g_context_mutex);
        handle = g_app;
        if (handle == NULL) {
            if (g_pending_lifecycle_count < OHOS_MAX_PENDING_LIFECYCLE) {
                g_pending_lifecycle[g_pending_lifecycle_count++] = (int)event;
            }
            pthread_mutex_unlock(&g_context_mutex);
            return;
        }
        pthread_mutex_unlock(&g_context_mutex);
    }
    // The registration check and the append must be atomic against register_bridge's flush
    // (both under g_context_mutex): an event that reads "not registered yet" and then appends
    // after the flush would sit in the queue forever, because the managed bridge registers
    // once and never drains it again. The callback runs after the unlock.
    pthread_mutex_lock(&g_context_mutex);
    void (*callback)(int) = handle->bridge_lifecycle;
    if (callback != NULL) {
        pthread_mutex_unlock(&g_context_mutex);
        callback((int)event);
        return;
    }
    if (handle->pending_count < OHOS_MAX_PENDING_LIFECYCLE) {
        handle->pending_lifecycle[handle->pending_count++] = (int)event;
    }
    pthread_mutex_unlock(&g_context_mutex);
}

void ohos_host_set_node_content(OhosHostAppHandle* handle, void* node_content) {
    if (handle == NULL) {
        // Same pre-handle window as ohos_host_notify_lifecycle: the shell can hand the
        // NodeContent over before the launch thread publishes the handle. Store it for the
        // handle start_app creates; register_bridge then forwards it to the managed side
        // (OHOS_HOST_APP_CONTEXT-style late delivery).
        pthread_mutex_lock(&g_context_mutex);
        handle = g_app;
        if (handle == NULL) {
            g_pending_node_content = node_content;
            pthread_mutex_unlock(&g_context_mutex);
            return;
        }
        pthread_mutex_unlock(&g_context_mutex);
    }
    // Bind the content under the same lock register_bridge's flush takes, and clear the slot
    // when a live bridge takes it over: whichever side wins the lock delivers exactly once
    // (the flush path also clears, see OhosHostBindAndFlushBridge). The callback itself runs
    // outside the lock; a clear (NULL) still notifies the managed side like before.
    void (*callback)(void*) = NULL;
    pthread_mutex_lock(&g_context_mutex);
    handle->node_content = node_content;
    if (handle->bridge_node != NULL) {
        callback = handle->bridge_node;
        handle->node_content = NULL;
    }
    pthread_mutex_unlock(&g_context_mutex);
    if (callback != NULL) {
        callback(node_content);
    }
}

void* ohos_host_get_node_content(OhosHostAppHandle* handle) {
    return handle != NULL ? handle->node_content : NULL;
}

int ohos_host_join_app(OhosHostAppHandle* handle) {
    if (handle == NULL) {
        return -1;
    }
    // The join itself stays outside g_context_mutex: the app thread may still be inside a
    // managed callback that calls a host entry taking the lock, and blocking there would
    // deadlock the join.
    if (!handle->joined) {
        pthread_join(handle->thread, NULL);
        handle->joined = 1;
    }
    // Detach and free under the lock get/set_app_context use: a getter that already resolved
    // g_app is serialized with the free, and a setter that runs after sees g_app == NULL and
    // parks its snapshot in the pending slot instead of touching the freed handle.
    pthread_mutex_lock(&g_context_mutex);
    int exit_code = handle->exit_code;
    // The runtime is intentionally not closed here: managed worker threads may still be
    // running and the application process owns the runtime until it exits.
    if (g_app == handle) {
        g_app = NULL;
    }
    free(handle->context_json);
    OhosHostFreeRetiredContexts(handle);
    free(handle);
    pthread_mutex_unlock(&g_context_mutex);
    return exit_code;
}

// ---------------------------------------------------------------------------
// Drawing bridge: an immediate-mode canvas over the current XComponent surface,
// implemented with native_drawing (the Skia-backed platform 2D API).
// ---------------------------------------------------------------------------

static OH_Drawing_Bitmap* g_canvas_bitmap = NULL;
static OH_Drawing_ShaderEffect* g_brush_shader = NULL;
static OH_Drawing_ShadowLayer* g_brush_shadow = NULL;

static OH_Drawing_Brush* OhosMakeFillBrush(unsigned int argb) {
    OH_Drawing_Brush* brush = OH_Drawing_BrushCreate();
    if (brush == NULL) {
        return NULL;
    }
    OH_Drawing_BrushSetColor(brush, (uint32_t)argb);
    if (g_brush_shader != NULL) {
        OH_Drawing_BrushSetShaderEffect(brush, g_brush_shader);
    }
    if (g_brush_shadow != NULL) {
        OH_Drawing_BrushSetShadowLayer(brush, g_brush_shadow);
    }
    return brush;
}

void ohos_host_draw_clear_effects(void) {
    if (g_brush_shader != NULL) {
        OH_Drawing_ShaderEffectDestroy(g_brush_shader);
        g_brush_shader = NULL;
    }
    if (g_brush_shadow != NULL) {
        OH_Drawing_ShadowLayerDestroy(g_brush_shadow);
        g_brush_shadow = NULL;
    }
}

void ohos_host_draw_set_linear_gradient(float x0, float y0, float x1, float y1,
                                        const unsigned int* colors, const float* stops, int count) {
    if (colors == NULL || count < 2) {
        return;
    }
    OH_Drawing_Point* start = OH_Drawing_PointCreate(x0, y0);
    OH_Drawing_Point* end = OH_Drawing_PointCreate(x1, y1);
    if (start == NULL || end == NULL) {
        return;
    }
    if (g_brush_shader != NULL) {
        OH_Drawing_ShaderEffectDestroy(g_brush_shader);
        g_brush_shader = NULL;
    }
    g_brush_shader = OH_Drawing_ShaderEffectCreateLinearGradient(start, end, (const uint32_t*)colors,
                                                                stops, (uint32_t)count, CLAMP);
    OH_Drawing_PointDestroy(start);
    OH_Drawing_PointDestroy(end);
}

void ohos_host_draw_set_radial_gradient(float cx, float cy, float radius,
                                        const unsigned int* colors, const float* stops, int count) {
    if (colors == NULL || count < 2 || radius <= 0.0f) {
        return;
    }
    OH_Drawing_Point* center = OH_Drawing_PointCreate(cx, cy);
    if (center == NULL) {
        return;
    }
    if (g_brush_shader != NULL) {
        OH_Drawing_ShaderEffectDestroy(g_brush_shader);
        g_brush_shader = NULL;
    }
    g_brush_shader = OH_Drawing_ShaderEffectCreateRadialGradient(center, radius, (const uint32_t*)colors,
                                                                stops, (uint32_t)count, CLAMP);
    OH_Drawing_PointDestroy(center);
}

int ohos_host_draw_set_image_pattern(const void* data, int length, int tileModeX, int tileModeY,
                                     float scaleX, float scaleY) {
    if (data == NULL || length <= 0) {
        return -1;
    }
    OH_ImageSourceNative* source = NULL;
    if (OH_ImageSourceNative_CreateFromData((uint8_t*)data, (size_t)length, &source) != IMAGE_SUCCESS || source == NULL) {
        return -1;
    }
    OH_PixelmapNative* pixelmap = NULL;
    int rc = -1;
    if (OH_ImageSourceNative_CreatePixelmap(source, NULL, &pixelmap) == IMAGE_SUCCESS && pixelmap != NULL) {
        OH_Drawing_PixelMap* drawingPixelMap = OH_Drawing_PixelMapGetFromOhPixelMapNative(pixelmap);
        if (drawingPixelMap != NULL) {
            OH_Drawing_SamplingOptions* sampling = OH_Drawing_SamplingOptionsCreate(FILTER_MODE_LINEAR, MIPMAP_MODE_LINEAR);
            OH_Drawing_Matrix* matrix = NULL;
            if (scaleX != 1.0f || scaleY != 1.0f) {
                matrix = OH_Drawing_MatrixCreateScale(scaleX, scaleY, 0, 0);
            }
            OH_Drawing_ShaderEffect* shader = OH_Drawing_ShaderEffectCreatePixelMapShader(
                drawingPixelMap, (OH_Drawing_TileMode)tileModeX, (OH_Drawing_TileMode)tileModeY, sampling, matrix);
            if (shader != NULL) {
                if (g_brush_shader != NULL) {
                    OH_Drawing_ShaderEffectDestroy(g_brush_shader);
                }
                g_brush_shader = shader;
                rc = 0;
            }
            if (matrix != NULL) {
                OH_Drawing_MatrixDestroy(matrix);
            }
            OH_Drawing_SamplingOptionsDestroy(sampling);
        }
        OH_PixelmapNative_Release(pixelmap);
    }
    OH_ImageSourceNative_Release(source);
    return rc;
}

void ohos_host_draw_set_shadow(float dx, float dy, float blur, unsigned int argb) {
    if (g_brush_shadow != NULL) {
        OH_Drawing_ShadowLayerDestroy(g_brush_shadow);
        g_brush_shadow = NULL;
    }
    g_brush_shadow = OH_Drawing_ShadowLayerCreate(blur, dx, dy, (uint32_t)argb);
}
static OH_Drawing_Canvas* g_canvas = NULL;
static int g_canvas_width = 0;
static int g_canvas_height = 0;

int ohos_host_draw_begin(int width, int height) {
    if (width <= 0 || height <= 0) {
        return -1;
    }
    if (g_canvas != NULL && g_canvas_width == width && g_canvas_height == height) {
        return 0;
    }
    if (g_canvas != NULL) {
        OH_Drawing_CanvasDestroy(g_canvas);
        g_canvas = NULL;
    }
    if (g_canvas_bitmap != NULL) {
        OH_Drawing_BitmapDestroy(g_canvas_bitmap);
        g_canvas_bitmap = NULL;
    }
    g_canvas_bitmap = OH_Drawing_BitmapCreate();
    if (g_canvas_bitmap == NULL) {
        return -1;
    }
    OH_Drawing_BitmapFormat format = { COLOR_FORMAT_RGBA_8888, ALPHA_FORMAT_OPAQUE };
    OH_Drawing_BitmapBuild(g_canvas_bitmap, (uint32_t)width, (uint32_t)height, &format);
    g_canvas = OH_Drawing_CanvasCreate();
    if (g_canvas == NULL) {
        return -1;
    }
    OH_Drawing_CanvasBind(g_canvas, g_canvas_bitmap);
    g_canvas_width = width;
    g_canvas_height = height;
    fprintf(stderr, "[openharmony-host] canvas %dx%d ready\n", width, height);
    return 0;
}

void ohos_host_draw_clear(unsigned int argb) {
    if (g_canvas != NULL) {
        OH_Drawing_CanvasClear(g_canvas, (uint32_t)argb);
    }
}

void ohos_host_draw_rect(int x, int y, int width, int height, unsigned int argb, int filled) {
    if (g_canvas == NULL) {
        return;
    }
    OH_Drawing_Rect* rect = OH_Drawing_RectCreate((float)x, (float)y, (float)(x + width), (float)(y + height));
    if (rect == NULL) {
        return;
    }
    if (filled) {
        OH_Drawing_Brush* brush = OhosMakeFillBrush(argb);
        OH_Drawing_CanvasAttachBrush(g_canvas, brush);
        OH_Drawing_CanvasDrawRect(g_canvas, rect);
        OH_Drawing_CanvasDetachBrush(g_canvas);
        OH_Drawing_BrushDestroy(brush);
    } else {
        OH_Drawing_Pen* pen = OH_Drawing_PenCreate();
        OH_Drawing_PenSetColor(pen, (uint32_t)argb);
        OH_Drawing_PenSetWidth(pen, 2.0f);
        OH_Drawing_CanvasAttachPen(g_canvas, pen);
        OH_Drawing_CanvasDrawRect(g_canvas, rect);
        OH_Drawing_CanvasDetachPen(g_canvas);
        OH_Drawing_PenDestroy(pen);
    }
    OH_Drawing_RectDestroy(rect);
}

static OH_Drawing_Typeface* g_custom_typeface = NULL;

void ohos_host_set_font_file(const char* path) {
    if (g_custom_typeface != NULL) {
        OH_Drawing_TypefaceDestroy(g_custom_typeface);
        g_custom_typeface = NULL;
    }
    if (path == NULL || *path == '\0') {
        return;
    }
    g_custom_typeface = OH_Drawing_TypefaceCreateFromFile(path, 0);
    fprintf(stderr, "[openharmony-host] font file %s -> %s\n", path,
            g_custom_typeface != NULL ? "loaded" : "failed");
}

int ohos_host_draw_text(int x, int y, const char* utf8, float size, unsigned int argb) {
    if (g_canvas == NULL || utf8 == NULL || *utf8 == '\0') {
        return -1;
    }
    OH_Drawing_Font* font = OH_Drawing_FontCreate();
    if (font == NULL) {
        return -1;
    }
    if (g_custom_typeface != NULL) {
        OH_Drawing_FontSetTypeface(font, g_custom_typeface);
    }
    OH_Drawing_FontSetTextSize(font, size);
    if (g_custom_typeface != NULL) {
        OH_Drawing_FontSetTypeface(font, g_custom_typeface);
    }
    OH_Drawing_TextBlob* blob = OH_Drawing_TextBlobCreateFromString(utf8, font, TEXT_ENCODING_UTF8);
    int rc = -1;
    if (blob != NULL) {
        OH_Drawing_Brush* brush = OhosMakeFillBrush(argb);
        OH_Drawing_CanvasAttachBrush(g_canvas, brush);
        OH_Drawing_CanvasDrawTextBlob(g_canvas, blob, (float)x, (float)y);
        OH_Drawing_CanvasDetachBrush(g_canvas);
        OH_Drawing_BrushDestroy(brush);
        OH_Drawing_TextBlobDestroy(blob);
        rc = 0;
    }
    OH_Drawing_FontDestroy(font);
    return rc;
}

void ohos_host_draw_polyline(const float* xy, int count, int closed, unsigned int argb, int filled, float stroke_width) {
    if (g_canvas == NULL || xy == NULL || count < 2) {
        return;
    }
    OH_Drawing_Path* path = OH_Drawing_PathCreate();
    if (path == NULL) {
        return;
    }
    OH_Drawing_PathMoveTo(path, xy[0], xy[1]);
    for (int i = 1; i < count; i++) {
        OH_Drawing_PathLineTo(path, xy[i * 2], xy[i * 2 + 1]);
    }
    if (closed) {
        OH_Drawing_PathClose(path);
    }
    if (filled) {
        OH_Drawing_Brush* brush = OhosMakeFillBrush(argb);
        OH_Drawing_CanvasAttachBrush(g_canvas, brush);
        OH_Drawing_CanvasDrawPath(g_canvas, path);
        OH_Drawing_CanvasDetachBrush(g_canvas);
        OH_Drawing_BrushDestroy(brush);
    } else {
        OH_Drawing_Pen* pen = OH_Drawing_PenCreate();
        OH_Drawing_PenSetColor(pen, (uint32_t)argb);
        OH_Drawing_PenSetWidth(pen, stroke_width > 0.0f ? stroke_width : 1.0f);
        OH_Drawing_CanvasAttachPen(g_canvas, pen);
        OH_Drawing_CanvasDrawPath(g_canvas, path);
        OH_Drawing_CanvasDetachPen(g_canvas);
        OH_Drawing_PenDestroy(pen);
    }
    OH_Drawing_PathDestroy(path);
}

int ohos_host_measure_text(const char* utf8, float size, int* width, int* height) {
    if (utf8 == NULL || *utf8 == '\0') {
        if (width != NULL) *width = 0;
        if (height != NULL) *height = 0;
        return -1;
    }
    OH_Drawing_Font* font = OH_Drawing_FontCreate();
    if (font == NULL) {
        return -1;
    }
    OH_Drawing_FontSetTextSize(font, size > 0 ? size : 14.0f);
    float textWidth = 0.0f;
    float textHeight = 0.0f;
    OH_Drawing_Font_Metrics metrics;
    float ascent = OH_Drawing_FontGetMetrics(font, &metrics);
    (void)ascent;
    textHeight = metrics.ascent * -1.0f + metrics.descent;
    OH_Drawing_FontMeasureText(font, utf8, strlen(utf8), TEXT_ENCODING_UTF8, NULL, &textWidth);
    if (width != NULL) *width = (int)(textWidth + 0.5f);
    if (height != NULL) *height = (int)(textHeight + 0.5f);
    OH_Drawing_FontDestroy(font);
    return 0;
}

void ohos_host_draw_save(void) {
    if (g_canvas != NULL) {
        OH_Drawing_CanvasSave(g_canvas);
    }
}

void ohos_host_draw_restore(void) {
    if (g_canvas != NULL) {
        OH_Drawing_CanvasRestore(g_canvas);
    }
}

void ohos_host_draw_clip_rect(float x, float y, float width, float height, int subtract) {
    if (g_canvas == NULL) {
        return;
    }
    OH_Drawing_Rect* rect = OH_Drawing_RectCreate(x, y, x + width, y + height);
    if (rect == NULL) {
        return;
    }
    OH_Drawing_CanvasClipRect(g_canvas, rect,
        subtract ? DIFFERENCE : INTERSECT, true);
    OH_Drawing_RectDestroy(rect);
}

void ohos_host_draw_clip_polyline(const float* xy, int count) {
    if (g_canvas == NULL || xy == NULL || count < 2) {
        return;
    }
    OH_Drawing_Path* path = OH_Drawing_PathCreate();
    if (path == NULL) {
        return;
    }
    OH_Drawing_PathMoveTo(path, xy[0], xy[1]);
    for (int i = 1; i < count; i++) {
        OH_Drawing_PathLineTo(path, xy[i * 2], xy[i * 2 + 1]);
    }
    OH_Drawing_PathClose(path);
    OH_Drawing_CanvasClipPath(g_canvas, path, INTERSECT, true);
    OH_Drawing_PathDestroy(path);
}

int ohos_host_draw_image_bytes(const void* data, int length, float x, float y, float width, float height) {
    if (g_canvas == NULL || data == NULL || length <= 0) {
        return -1;
    }
    OH_ImageSourceNative* source = NULL;
    if (OH_ImageSourceNative_CreateFromData((uint8_t*)data, (size_t)length, &source) != IMAGE_SUCCESS || source == NULL) {
        return -1;
    }
    OH_PixelmapNative* pixelmap = NULL;
    int rc = -1;
    if (OH_ImageSourceNative_CreatePixelmap(source, NULL, &pixelmap) == IMAGE_SUCCESS && pixelmap != NULL) {
        OH_Drawing_PixelMap* drawingPixelMap = OH_Drawing_PixelMapGetFromOhPixelMapNative(pixelmap);
        if (drawingPixelMap != NULL) {
            OH_Drawing_Rect* src = OH_Drawing_RectCreate(0, 0, (float)(int)width, (float)(int)height);
            OH_Drawing_Rect* dst = OH_Drawing_RectCreate(x, y, x + width, y + height);
            OH_Drawing_SamplingOptions* sampling = OH_Drawing_SamplingOptionsCreate(FILTER_MODE_LINEAR, MIPMAP_MODE_LINEAR);
            OH_Drawing_CanvasDrawPixelMapRect(g_canvas, drawingPixelMap, src, dst, sampling);
            OH_Drawing_SamplingOptionsDestroy(sampling);
            OH_Drawing_RectDestroy(src);
            OH_Drawing_RectDestroy(dst);
            rc = 0;
        }
        OH_PixelmapNative_Release(pixelmap);
    }
    OH_ImageSourceNative_Release(source);
    return rc;
}

int ohos_host_draw_present(void) {
    if (g_canvas == NULL || !g_surface_valid || g_surface_state == (int)OHOS_SURFACE_DESTROYED) {
        return -1;
    }
    OHNativeWindow* native_window = (OHNativeWindow*)g_surface_window;
    int width = g_canvas_width;
    int height = g_canvas_height;
    void* pixels = OH_Drawing_BitmapGetPixels(g_canvas_bitmap);
    if (native_window == NULL || pixels == NULL) {
        return -1;
    }
    uint64_t usage = NATIVEBUFFER_USAGE_CPU_WRITE | NATIVEBUFFER_USAGE_MEM_DMA;
    if (OH_NativeWindow_NativeWindowHandleOpt(native_window, SET_BUFFER_GEOMETRY, width, height) != 0 ||
        OH_NativeWindow_NativeWindowHandleOpt(native_window, SET_FORMAT, NATIVEBUFFER_PIXEL_FMT_RGBA_8888) != 0 ||
        OH_NativeWindow_NativeWindowHandleOpt(native_window, SET_USAGE, usage) != 0) {
        return -1;
    }
    int fence = -1;
    OHNativeWindowBuffer* buffer = NULL;
    if (OH_NativeWindow_NativeWindowRequestBuffer(native_window, &buffer, &fence) != 0 || buffer == NULL) {
        return -1;
    }
    BufferHandle* handle = OH_NativeWindow_GetBufferHandleFromNative(buffer);
    if (handle != NULL) {
        void* addr = mmap(handle->virAddr, handle->size, PROT_READ | PROT_WRITE, MAP_SHARED, handle->fd, 0);
        if (addr != MAP_FAILED) {
            uint8_t* dst = (uint8_t*)addr;
            const uint8_t* src = (const uint8_t*)pixels;
            size_t row_bytes = (size_t)width * 4;
            for (int y = 0; y < height; y++) {
                size_t copy = row_bytes <= handle->stride ? row_bytes : handle->stride;
                memcpy(dst + (size_t)y * handle->stride, src + (size_t)y * row_bytes, copy);
            }
            munmap(addr, handle->size);
        }
    }
    Region region = { NULL, 0 };
    OH_NativeWindow_NativeWindowFlushBuffer(native_window, buffer, fence, region);
    fprintf(stderr, "[openharmony-host] canvas presented (%dx%d)\n", width, height);
    return 0;
}


// ---------------------------------------------------------------------------
// Sensor Kit (NDK sensors/oh_sensor.h): subscribe/unsubscribe and forward one
// reading per event to the managed listener set by the runtime.
// ---------------------------------------------------------------------------
#include <sensors/oh_sensor.h>

static Sensor_SubscriptionId* g_sensor_id = NULL;
static Sensor_SubscriptionAttribute* g_sensor_attr = NULL;
static Sensor_Subscriber* g_sensor_subscriber = NULL;
// The listener carries four components: ORIENTATION (256) reports Euler angles in data[0..2],
// while ROTATION_VECTOR (259) additionally reports the scalar part in data[3] (w defaults to
// 1.0 for three-component payloads such as accelerometer/gyroscope/barometer readings).
static void (*g_sensor_listener)(int type, float x, float y, float z, float w, long long timestamp) = NULL;

static void OhosSensorEventCallback(Sensor_Event* event) {
    if (event == NULL || g_sensor_listener == NULL) {
        return;
    }
    Sensor_Type type = SENSOR_TYPE_ACCELEROMETER;
    OH_SensorEvent_GetType(event, &type);
    float* data = NULL;
    uint32_t length = 0;
    OH_SensorEvent_GetData(event, &data, &length);
    int64_t timestamp = 0;
    OH_SensorEvent_GetTimestamp(event, &timestamp);
    float x = (data != NULL && length > 0) ? data[0] : 0.0f;
    float y = (data != NULL && length > 1) ? data[1] : 0.0f;
    float z = (data != NULL && length > 2) ? data[2] : 0.0f;
    float w = (data != NULL && length > 3) ? data[3] : 1.0f;
    g_sensor_listener((int)type, x, y, z, w, (long long)timestamp);
}

void ohos_host_sensor_set_listener(void* listener) {
    g_sensor_listener = (void (*)(int, float, float, float, float, long long))listener;
}

void ohos_host_sensor_stop(void);

int ohos_host_sensor_is_supported(int type) {
    uint32_t capacity = 32;
    Sensor_Info** infos = OH_Sensor_CreateInfos(capacity);
    if (infos == NULL) {
        return 0;
    }
    uint32_t count = capacity;
    if (OH_Sensor_GetInfos(infos, &count) != SENSOR_SUCCESS) {
        OH_Sensor_DestroyInfos(infos, capacity);
        return 0;
    }
    int supported = 0;
    for (uint32_t i = 0; i < count; i++) {
        Sensor_Type current = SENSOR_TYPE_ACCELEROMETER;
        if (OH_SensorInfo_GetType(infos[i], &current) == SENSOR_SUCCESS && (int)current == type) {
            supported = 1;
            break;
        }
    }
    OH_Sensor_DestroyInfos(infos, capacity);
    return supported;
}

int ohos_host_sensor_start(int type, int interval_ms) {
    ohos_host_sensor_stop();
    Sensor_SubscriptionId* id = OH_Sensor_CreateSubscriptionId();
    Sensor_SubscriptionAttribute* attr = OH_Sensor_CreateSubscriptionAttribute();
    Sensor_Subscriber* subscriber = OH_Sensor_CreateSubscriber();
    if (id == NULL || attr == NULL || subscriber == NULL) {
        ohos_host_sensor_stop();
        return -1;
    }
    OH_SensorSubscriptionId_SetType(id, (Sensor_Type)type);
    OH_SensorSubscriptionAttribute_SetSamplingInterval(attr, interval_ms * 1000000LL);
    OH_SensorSubscriber_SetCallback(subscriber, OhosSensorEventCallback);
    Sensor_Result result = OH_Sensor_Subscribe(id, attr, subscriber);
    if (result != SENSOR_SUCCESS) {
        OH_Sensor_DestroySubscriptionId(id);
        OH_Sensor_DestroySubscriptionAttribute(attr);
        OH_Sensor_DestroySubscriber(subscriber);
        return (int)result;
    }
    g_sensor_id = id;
    g_sensor_attr = attr;
    g_sensor_subscriber = subscriber;
    return 0;
}

void ohos_host_sensor_stop(void) {
    if (g_sensor_id != NULL && g_sensor_subscriber != NULL) {
        OH_Sensor_Unsubscribe(g_sensor_id, g_sensor_subscriber);
    }
    if (g_sensor_id != NULL) {
        OH_Sensor_DestroySubscriptionId(g_sensor_id);
        g_sensor_id = NULL;
    }
    if (g_sensor_attr != NULL) {
        OH_Sensor_DestroySubscriptionAttribute(g_sensor_attr);
        g_sensor_attr = NULL;
    }
    if (g_sensor_subscriber != NULL) {
        OH_Sensor_DestroySubscriber(g_sensor_subscriber);
        g_sensor_subscriber = NULL;
    }
}


// ---------------------------------------------------------------------------
// Notification Kit: forwards a publish request to the ArkTS shell through the
// NAPI layer (the shell registers a sink with registerNotificationSink).
// ---------------------------------------------------------------------------
#ifdef __cplusplus
extern "C"
#endif
void OhosNotifyNotification(int id, const char* title, const char* text);

int ohos_host_notification_show(int id, const char* title, const char* text) {
    if (title == NULL) {
        return -1;
    }
    OhosNotifyNotification(id, title, text != NULL ? text : "");
    return 0;
}


// ---------------------------------------------------------------------------
// Pinch input: the shell reports phase/scale/centre; the managed listener set
// through ohos_host_register_pinch receives them.
// ---------------------------------------------------------------------------
static void (*g_pinch_listener)(int phase, double scale, float x, float y) = NULL;

void ohos_host_register_pinch(void* callback) {
    g_pinch_listener = (void (*)(int, double, float, float))callback;
}

#ifdef __cplusplus
extern "C"
#endif
void OhosNotifyPinch(int phase, double scale, float x, float y) {
    if (g_pinch_listener != NULL) {
        g_pinch_listener(phase, scale, x, y);
    }
}


// ---------------------------------------------------------------------------
// Accessibility: the runtime publishes a shadow node tree every frame. The
// provider callbacks in the NAPI layer read it back through the accessors
// below and turn it into ArkUI accessibility element information.
// ---------------------------------------------------------------------------
#include <stdlib.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

// Argument order is the publish contract shared with the managed DllImport and the NAPI
// consumer; see the declarations in openharmony_host.h before touching this struct or the
// signatures below. Absent values: hint may be NULL, a range is only valid when
// range_min <= range_max (NaN compares false), checked is -1 when unknown/not applicable.
typedef struct OhosAccessibilityNode {
    int id;
    int parent_id;
    char* role;
    char* text;
    char* description;
    char* hint;
    float x, y, width, height;
    int flags;
    int actions;
    double range_min, range_max, range_current;
    int checked;
} OhosAccessibilityNode;

static OhosAccessibilityNode* g_a11y_nodes = NULL;
static int g_a11y_capacity = 0;
static int g_a11y_fill = 0;
static int g_a11y_count = 0;

// Serializes the shadow node table between the managed publisher (begin/node/commit on the
// app thread) and the NAPI accessibility provider (count/get on the ArkUI thread).
static pthread_mutex_t g_a11y_mutex = PTHREAD_MUTEX_INITIALIZER;

// The getter must never hand the interned node strings to the provider: begin frees the whole
// table while the provider is still forwarding the fields to the ArkUI setters (A11yFillElement
// in host_napi.cpp). Each get copies the strings under g_a11y_mutex into per-thread storage
// that stays valid until the next get on that thread, so a concurrent publish can free the
// table without invalidating the caller's fill. The storage hangs off a pthread key instead of
// __thread on purpose: the host library is dlopen'ed, and the OpenHarmony toolchain lowers
// __thread to emulated TLS (libc++_shared's __emutls_get_address), while the key needs no
// TLS relocations; its destructor frees the copies when the thread exits.
#define OHOS_A11Y_COPY_SLOTS 4

typedef struct OhosA11yCopySet {
    char* strings[OHOS_A11Y_COPY_SLOTS];
    size_t sizes[OHOS_A11Y_COPY_SLOTS];
} OhosA11yCopySet;

static pthread_key_t g_a11y_copy_key;
static pthread_once_t g_a11y_copy_once = PTHREAD_ONCE_INIT;
static int g_a11y_copy_key_ready = 0;

static void OhosA11yCopySetDestroy(void* value) {
    OhosA11yCopySet* set = (OhosA11yCopySet*)value;
    if (set == NULL) {
        return;
    }
    for (int i = 0; i < OHOS_A11Y_COPY_SLOTS; i++) {
        free(set->strings[i]);
    }
    free(set);
}

static void OhosA11yCopyKeyInit(void) {
    g_a11y_copy_key_ready = pthread_key_create(&g_a11y_copy_key, OhosA11yCopySetDestroy) == 0;
}

// Caller holds g_a11y_mutex. Returns NULL when the thread cannot have copies (all string
// outputs then report the field as absent, which is the safe failure mode).
static OhosA11yCopySet* OhosA11yCopySetForThread(void) {
    pthread_once(&g_a11y_copy_once, OhosA11yCopyKeyInit);
    if (!g_a11y_copy_key_ready) {
        return NULL;
    }
    OhosA11yCopySet* set = (OhosA11yCopySet*)pthread_getspecific(g_a11y_copy_key);
    if (set == NULL) {
        set = (OhosA11yCopySet*)calloc(1, sizeof(OhosA11yCopySet));
        if (set == NULL || pthread_setspecific(g_a11y_copy_key, set) != 0) {
            free(set);
            return NULL;
        }
    }
    return set;
}

static const char* OhosA11yCopyString(OhosA11yCopySet* set, int slot, const char* value) {
    if (set == NULL || value == NULL) {
        return NULL;
    }
    size_t length = strlen(value) + 1;
    if (set->sizes[slot] < length) {
        char* grown = (char*)realloc(set->strings[slot], length);
        if (grown == NULL) {
            return NULL;   // report the field as absent rather than a dangling pointer
        }
        set->strings[slot] = grown;
        set->sizes[slot] = length;
    }
    memcpy(set->strings[slot], value, length);
    return set->strings[slot];
}

static char* OhosA11yString(const char* value) {
    if (value == NULL) {
        return NULL;
    }
    size_t length = strlen(value) + 1;
    char* copy = (char*)malloc(length);
    if (copy != NULL) {
        memcpy(copy, value, length);
    }
    return copy;
}

// Caller holds g_a11y_mutex (begin is the only caller).
static void OhosA11yFreeNodes(void) {
    if (g_a11y_nodes != NULL) {
        for (int i = 0; i < g_a11y_fill; i++) {
            free(g_a11y_nodes[i].role);
            free(g_a11y_nodes[i].text);
            free(g_a11y_nodes[i].description);
            free(g_a11y_nodes[i].hint);
        }
        free(g_a11y_nodes);
    }
    g_a11y_nodes = NULL;
    g_a11y_capacity = 0;
    g_a11y_fill = 0;
    g_a11y_count = 0;
}

int ohos_host_accessibility_begin(int count) {
    pthread_mutex_lock(&g_a11y_mutex);
    OhosA11yFreeNodes();
    if (count <= 0) {
        pthread_mutex_unlock(&g_a11y_mutex);
        return 0;
    }
    g_a11y_nodes = (OhosAccessibilityNode*)calloc((size_t)count, sizeof(OhosAccessibilityNode));
    if (g_a11y_nodes == NULL) {
        pthread_mutex_unlock(&g_a11y_mutex);
        return -1;
    }
    g_a11y_capacity = count;
    pthread_mutex_unlock(&g_a11y_mutex);
    return 0;
}

// 16 arguments, in this exact order: id, parent_id, role, text, description, hint,
// x, y, width, height, flags, actions, range_min, range_max, range_current, checked.
// The order is mirrored by the managed DllImport (maui-ohos OpenHarmonyAccessibility.cs)
// and asserted off-device by the interaction harness; see openharmony_host.h.
int ohos_host_accessibility_node(int id, int parent_id, const char* role, const char* text,
                                 const char* description, const char* hint,
                                 float x, float y, float width, float height,
                                 int flags, int actions,
                                 double range_min, double range_max, double range_current,
                                 int checked) {
    pthread_mutex_lock(&g_a11y_mutex);
    if (g_a11y_nodes == NULL || g_a11y_fill >= g_a11y_capacity) {
        pthread_mutex_unlock(&g_a11y_mutex);
        return -1;
    }
    OhosAccessibilityNode* node = &g_a11y_nodes[g_a11y_fill++];
    node->id = id;
    node->parent_id = parent_id;
    node->role = OhosA11yString(role);
    node->text = OhosA11yString(text);
    node->description = OhosA11yString(description);
    node->hint = OhosA11yString(hint);
    node->x = x;
    node->y = y;
    node->width = width;
    node->height = height;
    node->flags = flags;
    node->actions = actions;
    node->range_min = range_min;
    node->range_max = range_max;
    node->range_current = range_current;
    node->checked = checked;
    pthread_mutex_unlock(&g_a11y_mutex);
    return 0;
}

int ohos_host_accessibility_commit(void) {
    pthread_mutex_lock(&g_a11y_mutex);
    g_a11y_count = g_a11y_fill;
    int count = g_a11y_count;
    pthread_mutex_unlock(&g_a11y_mutex);
    return count;
}

int ohos_host_accessibility_count(void) {
    pthread_mutex_lock(&g_a11y_mutex);
    int count = g_a11y_count;
    pthread_mutex_unlock(&g_a11y_mutex);
    return count;
}

// Published node count for the shell's accessibility self-check (host.accessibilityNodeCount).
// Same value as ohos_host_accessibility_count; the distinct name keeps the publish-contract
// reflection described above from mistaking this symbol for the 16-argument publish function.
int ohos_host_accessibility_node_count(void) {
    return ohos_host_accessibility_count();
}

// Mirrors ohos_host_accessibility_node: 17 arguments, same order plus the output pointers
// (index first, then the 16 published fields). See openharmony_host.h. The string outputs
// point at per-thread copies taken under the table lock (OhosA11yCopySetForThread), not at
// the interned node fields, so begin can free the table while the provider fills its element.
int ohos_host_accessibility_get(int index, int* id, int* parent_id, const char** role,
                                const char** text, const char** description, const char** hint,
                                float* x, float* y, float* width, float* height,
                                int* flags, int* actions,
                                double* range_min, double* range_max, double* range_current,
                                int* checked) {
    pthread_mutex_lock(&g_a11y_mutex);
    if (g_a11y_nodes == NULL || index < 0 || index >= g_a11y_count) {
        pthread_mutex_unlock(&g_a11y_mutex);
        return -1;
    }
    OhosAccessibilityNode* node = &g_a11y_nodes[index];
    OhosA11yCopySet* copies = OhosA11yCopySetForThread();
    if (id != NULL) *id = node->id;
    if (parent_id != NULL) *parent_id = node->parent_id;
    if (role != NULL) *role = OhosA11yCopyString(copies, 0, node->role);
    if (text != NULL) *text = OhosA11yCopyString(copies, 1, node->text);
    if (description != NULL) *description = OhosA11yCopyString(copies, 2, node->description);
    if (hint != NULL) *hint = OhosA11yCopyString(copies, 3, node->hint);
    if (x != NULL) *x = node->x;
    if (y != NULL) *y = node->y;
    if (width != NULL) *width = node->width;
    if (height != NULL) *height = node->height;
    if (flags != NULL) *flags = node->flags;
    if (actions != NULL) *actions = node->actions;
    if (range_min != NULL) *range_min = node->range_min;
    if (range_max != NULL) *range_max = node->range_max;
    if (range_current != NULL) *range_current = node->range_current;
    if (checked != NULL) *checked = node->checked;
    pthread_mutex_unlock(&g_a11y_mutex);
    return 0;
}

#ifdef __cplusplus
}
#endif
