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

/// Input + frame callbacks (registered by the managed bridge in addition to the render
/// bridge). touch: void (*)(int type, float x, float y, int pointerCount, int pointerId);
/// frame: void (*)(int64_t timestamp, int64_t targetTimestamp). Both may be NULL.
void ohos_host_register_input(void* touch, void* frame);

/// Registers the managed text-input callback (optional; apps without text input skip it).
void ohos_host_register_text_input(void* callback);

/// Forwards an XComponent touch event to the managed bridge (type: 0=down 1=up 2=move 3=cancel).
void ohos_host_notify_touch(int type, float x, float y, int pointerCount, int pointerId);

/// Text input: forwards text typed in the ArkTS shell to the managed bridge.
void ohos_host_notify_text_input(const char* utf8);

/// Essentials over the NDK: vibration (OH_Vibrator_PlayVibration).
int ohos_host_vibrate(int duration_ms);

/// Essentials over the NDK: network access (0 unknown, 1 none, 2 local, 3 internet).
int ohos_host_network_access(void);

/// WebView: commands (op: show/hide/load/eval/back) go to the shell's ArkWeb component, page
/// events come back through ohos_host_web_register_event.
void ohos_host_web_set_listener(void (*listener)(const char* op, const char* arg));
void ohos_host_web_register_event(void* callback);
void ohos_host_web_command(const char* op, const char* arg);
void ohos_host_web_notify_event(const char* state, const char* url);

/// Pickers: the managed side asks the ArkTS shell to open the system picker (kind: 0 file,
/// 1 photo, 2 video) and receives the chosen file's name plus base64 content.
void ohos_host_picker_set_listener(void (*listener)(int request_id, int kind));
void ohos_host_picker_register_result(void* callback);
void ohos_host_picker_request(int request_id, int kind);
void ohos_host_picker_complete(int request_id, int rc, const char* name, const char* data_base64);

/// Soft keyboard through the input-method NDK (attach + show/hide).
int ohos_host_keyboard_show(void);
/// Seeds the IME buffer with the focused editor's current text.
void ohos_host_keyboard_set_text(const char* utf8);
int ohos_host_keyboard_hide(void);

/// Custom fonts: loads a typeface from a font file used by all text drawing/measuring (an empty
/// path restores the platform default face).
void ohos_host_set_font_file(const char* path);

/// Essentials over the NDK: geolocation (OH_Location_*). Start/stop a locating session and read
/// the most recent fix (returns 1 when a fix is available, 0 otherwise).
int ohos_host_location_start(void);
int ohos_host_location_stop(void);
int ohos_host_location_get(double* latitude, double* longitude, double* altitude);

/// Essentials over the NDK: self permission check (OH_AT_CheckSelfPermission).
int ohos_host_check_permission(const char* permission);

/// Essentials: asks the ArkTS shell to vibrate (listener registered by the NAPI layer).
void ohos_host_request_vibration(int duration_ms);
void ohos_host_set_vibration_listener(void (*listener)(int duration_ms));

/// Universal key store (HUKS) bridge: the managed side asks the ArkTS shell to run key
/// operations; results come back through ohos_host_keystore_complete.
void ohos_host_keystore_set_listener(void (*listener)(int request_id, const char* op, const char* alias, const char* data_base64));
void ohos_host_keystore_register_result(void* callback);
void ohos_host_keystore_request(int request_id, const char* op, const char* alias, const char* data_base64);
void ohos_host_keystore_complete(int request_id, int rc, const char* data_base64);

/// Text input: the user pressed the keyboard's submit/return key.
void ohos_host_notify_text_submitted(void);

/// Registers the managed text-submitted callback (optional).
void ohos_host_register_text_submitted(void* callback);

/// Asks the ArkTS shell to show/hide the soft keyboard (the NAPI layer owns the sink).
void ohos_host_request_text_input(int show);

/// The NAPI layer registers a listener that talks to the ArkTS shell.
void ohos_host_set_text_input_listener(void (*listener)(int show));

/// Forwards an XComponent frame callback to the managed bridge.
void ohos_host_notify_frame(int64_t timestamp, int64_t targetTimestamp);

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
// Brush effects (apply to subsequent fills/text until cleared).
void ohos_host_draw_set_linear_gradient(float x0, float y0, float x1, float y1,
                                        const unsigned int* colors, const float* stops, int count);
void ohos_host_draw_set_radial_gradient(float cx, float cy, float radius,
                                        const unsigned int* colors, const float* stops, int count);
/// Tile-image pattern shader (PNG/JPEG bytes), applied to subsequent fills.
/// tileModeX/Y: 0=clamp, 1=repeat, 2=mirror. Returns 0 on success.
int  ohos_host_draw_set_image_pattern(const void* data, int length, int tileModeX, int tileModeY,
                                      float scaleX, float scaleY);

void ohos_host_draw_set_shadow(float dx, float dy, float blur, unsigned int argb);
void ohos_host_draw_clear_effects(void);

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
