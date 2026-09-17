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
/// lifecycle: void (*)(int), node: void (*)(void*), surface: void (*)(void*, int, int, int).
/// Any of them may be NULL.
void ohos_host_register_bridge(void* lifecycle, void* node, void* surface);

/// Surface state pushed to the managed bridge (see ohos_host_set_native_window).
typedef enum {
    OHOS_SURFACE_CREATED = 0,
    OHOS_SURFACE_CHANGED = 1,
    OHOS_SURFACE_DESTROYED = 2,
} ohos_surface_state;

/// Stores the XComponent surface (OHNativeWindow*) and notifies the managed bridge.
/// width/height are the surface size in pixels (may be 0 when unknown).
void ohos_host_set_native_window(void* window, int width, int height, ohos_surface_state state);

/// Pushes a lifecycle event into the managed bridge (queued until registered).
void ohos_host_notify_lifecycle(OhosHostAppHandle* handle, ohos_lifecycle_event event);

/// Stores the ArkUI NodeContent handle for the managed app (0 clears it).
void ohos_host_set_node_content(OhosHostAppHandle* handle, void* node_content);

/// Fills the current XComponent surface with a solid colour (0xAARRGGBB).
/// Returns 0 when the surface accepted the frame, -1 when there is no surface yet.
/// Managed code uses this to drive the surface before a real renderer is attached.
int ohos_host_fill_surface(unsigned int argb);

// --- drawing bridge (native_drawing, the Skia-backed platform 2D API) --------------
// A minimal immediate-mode canvas over the current surface, used by managed code until a
// full renderer (Microsoft.Maui.Graphics/Skia) is attached. All calls are no-ops when there
// is no surface.
int  ohos_host_draw_begin(int width, int height);
void ohos_host_draw_clear(unsigned int argb);
void ohos_host_draw_rect(int x, int y, int width, int height, unsigned int argb, int filled);
int  ohos_host_draw_text(int x, int y, const char* utf8, float size, unsigned int argb);
// --- canvas state / metrics / images ----------------------------------------------
int  ohos_host_measure_text(const char* utf8, float size, int* width, int* height);
void ohos_host_draw_save(void);
void ohos_host_draw_restore(void);
void ohos_host_draw_clip_rect(float x, float y, float width, float height, int subtract);
void ohos_host_draw_clip_polyline(const float* xy, int count);
/// Decodes PNG/JPEG bytes and draws them into the destination rectangle.
int  ohos_host_draw_image_bytes(const void* data, int length, float x, float y, float width, float height);

/// Draws a polyline/polygon from packed coordinates [x0,y0,x1,y1,...]. Curves are
/// flattened by the caller. filled = 1 fills (closed), otherwise strokes with stroke_width.
void ohos_host_draw_polyline(const float* xy, int count, int closed, unsigned int argb, int filled, float stroke_width);
int  ohos_host_draw_present(void);

/// The ArkUI NodeContent handle previously stored (may be NULL).
void* ohos_host_get_node_content(OhosHostAppHandle* handle);

/// Waits for the managed application to finish and returns its exit code
/// (also releases the handle).
int ohos_host_join_app(OhosHostAppHandle* handle);

#ifdef __cplusplus
}
#endif

#endif  // OPENHARMONY_HOST_H
