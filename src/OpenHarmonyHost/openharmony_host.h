// Native runtime host for OpenHarmony: loads hostfxr from the published app
// directory and runs the managed application, either in one-shot mode
// (hostfxr_main_startupinfo, like the apphost) or in bridged mode where the
// native shell pushes lifecycle/node events into the live managed app
// (callbacks are registered from the managed side, see ohos_host_register_bridge).
#ifndef OPENHARMONY_HOST_H
#define OPENHARMONY_HOST_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Lifecycle events pushed from the native shell to the managed bridge.
typedef enum {
    OHOS_LIFECYCLE_CREATE = 0,
    OHOS_LIFECYCLE_DESTROY = 1,
    OHOS_LIFECYCLE_FOREGROUND = 2,
    OHOS_LIFECYCLE_BACKGROUND = 3,
} ohos_lifecycle_event;

typedef struct OhosHostAppHandle OhosHostAppHandle;

/// One-shot launch: runs the application's Main and returns its exit code.
/// Self-contained and framework-dependent publish outputs are both supported.
int ohos_host_run_app(const char* app_dir, const char* app_assembly_file, int argc, const char* const* argv);

/// Bridged launch: initializes the runtime and runs Main on a background thread.
/// context_json is kept for the managed side (ohos_host_get_app_context).
/// Returns 0 on success.
int ohos_host_start_app(const char* app_dir, const char* app_assembly_file,
                        const char* args_json, const char* context_json,
                        OhosHostAppHandle** handle);

/// The UTF-8 context JSON passed to start_app (NULL when none). The caller must
/// not free it; the handle owns it until joined.
const char* ohos_host_get_app_context(void);

/// Called by the managed side (Microsoft.OpenHarmony.Hosting) once it is ready.
/// lifecycle: void (*)(int), node: void (*)(void*). Both may be NULL.
void ohos_host_register_bridge(void* lifecycle, void* node);

/// Pushes a lifecycle event into the managed bridge (queued until registered).
void ohos_host_notify_lifecycle(OhosHostAppHandle* handle, ohos_lifecycle_event event);

/// Stores the ArkUI NodeContent handle for the managed app (0 clears it).
void ohos_host_set_node_content(OhosHostAppHandle* handle, void* node_content);

/// The ArkUI NodeContent handle previously stored (may be NULL).
void* ohos_host_get_node_content(OhosHostAppHandle* handle);

/// Waits for the managed application to finish and returns its exit code
/// (also releases the handle).
int ohos_host_join_app(OhosHostAppHandle* handle);

#ifdef __cplusplus
}
#endif

#endif  // OPENHARMONY_HOST_H
