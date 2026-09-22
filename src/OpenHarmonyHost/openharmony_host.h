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

/// The UTF-8 context JSON passed to start_app (NULL when none), or the snapshot published
/// later through ohos_host_set_app_context. The caller must not free it; the handle owns it
/// (replaced snapshots stay alive too) until joined.
const char* ohos_host_get_app_context(void);

/// Re-publishes the application context JSON. The native host otherwise stores the context
/// once, in ohos_host_start_app; this entry lets the shell publish the real one once the
/// payload directory is known (or after the surface is ready), so a start_app call with an
/// empty context is not final.
/// With a live app handle the snapshot is copied, exported through OHOS_HOST_APP_CONTEXT
/// and re-emitted through the surface notification path the managed bridge re-reads the
/// context on (OpenHarmonyBridge.RefreshContext). Before the handle exists the snapshot is
/// kept for the next start_app, which adopts it when it has no context of its own or that
/// context does not name a payload directory.
/// Returns 0 when the JSON was stored (or kept), -1 for a NULL/empty argument or when the
/// snapshot could not be copied.
int ohos_host_set_app_context(const char* json);

/// Re-emits the stored snapshot through the same notification path as
/// ohos_host_set_app_context, without changing it. Returns 1 when the managed bridge was
/// notified, 0 when there is no live channel (no app handle, no bridge registered or no
/// created/changed surface to replay; the next surface/lifecycle event re-reads the context
/// anyway).
int ohos_host_notify_context(void);

/// Bundle metadata (Essentials IAppInfo): the ArkTS shell reads the HAP's real version/build/
/// name with bundleManager.getBundleInfoForSelfSync once at page load and forwards it through
/// the NAPI wrapper (host.setBundleInfo). The native host stores copies; the getters return ""
/// (never NULL) until the shell publishes. `build` is the versionCode as text.
int ohos_host_set_bundle_info(const char* version, const char* build, const char* name);
const char* ohos_host_get_bundle_version(void);
const char* ohos_host_get_bundle_build(void);
const char* ohos_host_get_bundle_name(void);

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

/// Registers the managed pinch callback (optional; declared here so the definition in
/// openharmony_host.c gets C linkage even though the file is compiled as C++):
/// void (*)(int phase, double scale, float x, float y). The managed side requests the
/// unmangled export name "ohos_host_register_pinch" (OpenHarmonyApp.RegisterPinch).
void ohos_host_register_pinch(void* callback);

/// Forwards an XComponent touch event to the managed bridge (type: 0=down 1=up 2=move 3=cancel).
void ohos_host_notify_touch(int type, float x, float y, int pointerCount, int pointerId);

/// Text input: forwards text typed in the ArkTS shell to the managed bridge.
void ohos_host_notify_text_input(const char* utf8);

/// Essentials over the NDK: vibration (OH_Vibrator_PlayVibration).
int ohos_host_vibrate(int duration_ms);

/// Essentials over the NDK: network access (0 unknown, 1 none, 2 local, 3 internet).
int ohos_host_network_access(void);

/// Safe area: the shell reports the window's avoid area; the host stores it for the app host.
void ohos_host_set_avoid_area(int top, int bottom, int left, int right);
int ohos_host_get_avoid_area(int* top, int* bottom, int* left, int* right);

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

/// Runtime permissions: the managed side asks the ArkTS shell to prompt for one permission
/// (abilityAccessCtrl.requestPermissionsFromUser); the shell's registerPermissionSink handler
/// answers through host.permissionResult -> ohos_host_permission_complete. The listener is
/// registered by the NAPI layer; the result callback by the managed side.
void ohos_host_permission_set_listener(void (*listener)(const char* permission, int request_id));
void ohos_host_request_permission(const char* permission, int request_id);
void ohos_host_register_permission_result(void* callback);
void ohos_host_permission_complete(int request_id, int granted);

/// Notification enablement for MAUI's Permissions.PostNotifications. OpenHarmony does not gate
/// notification publishing behind abilityAccessCtrl; the per-app switch is the system enable
/// dialog, so this rides its own request/response bridge (same shape as the permission one).
/// op 0 = read the current enable state (notificationManager.isNotificationEnabledSync, no
/// dialog), op 1 = ask the system to show its enable dialog (requestEnableNotification). The
/// shell's registerNotificationPermissionSink handler answers through
/// host.notificationPermissionResult -> ohos_host_notification_permission_complete with the
/// enable state after the call. The listener is registered by the NAPI layer; the result
/// callback by the managed side.
void ohos_host_notification_permission_set_listener(void (*listener)(int op, int request_id));
void ohos_host_notification_permission_request(int op, int request_id);
void ohos_host_notification_permission_register_result(void* callback);
void ohos_host_notification_permission_complete(int request_id, int granted);

/// Clipboard: the managed side asks the ArkTS shell to run one pasteboard operation through
/// host.registerClipboardSink. op: 0 has text, 1 get text, 2 set text; `text` carries the
/// value for set (and for get the shell may ignore it). The answer comes back through
/// ohos_host_clipboard_complete(request_id, rc, text) with rc 0 = success, -1 = unavailable
/// (permission denied/pasteboard or sink missing); for op 0 the payload is "1"/"0", for op 1
/// the clipboard text (possibly empty) and for op 2 empty. The shell's pasteboard 'update'
/// observer reports changes through ohos_host_clipboard_notify_changed (no request id).
void ohos_host_clipboard_set_listener(void (*listener)(int request_id, int op, const char* text));
void ohos_host_clipboard_request(int request_id, int op, const char* text);
void ohos_host_clipboard_register_result(void* callback);
void ohos_host_clipboard_complete(int request_id, int rc, const char* text);
void ohos_host_clipboard_register_changed(void* callback);
void ohos_host_clipboard_notify_changed(void);

/// Connectivity: the managed side registers a listener for network-access changes (the level
/// is the same 0 unknown / 1 none / 2 local / 3 internet encoding as ohos_host_network_access)
/// and the NAPI layer notifies it from host.notifyNetworkAccess, the shell's observer push.
void ohos_host_network_access_register(void* callback);
void ohos_host_network_access_notify(void);

/// Window chrome: the managed side asks the ArkTS shell to apply the main window's title
/// (window.setWindowTitle, SessionManager, API 15+) and its rectangle (window.moveWindowTo +
/// window.resize, API 11+). Both return 0 when the request reached the shell sink and -1 when
/// there is no shell listener or the argument is invalid (NULL/empty title, non-positive size).
int ohos_host_set_window_title(const char* utf8);
int ohos_host_set_window_rect(int x, int y, int w, int h);

/// Shell search: the managed SearchHandler state is published to the shell through
/// ohos_host_shell_search_set (the shell applies it to its search field); the shell reports
/// the user's interactions back through ohos_host_shell_search_notify, which invokes the
/// listener registered by ohos_host_shell_search_set_listener. op: 0 query changed, 1 submit,
/// 2 cancel (clear).
int ohos_host_shell_search_set(const char* query, const char* placeholder, int visible, int enabled);
void ohos_host_shell_search_set_listener(void (*listener)(int op, const char* text));
void ohos_host_shell_search_notify(int op, const char* text);

/// Shell flyout: the text of the shell flyout panel's header/footer labels. NULL or "" clears
/// the label. Returns 0 when the text reached the shell sink, -1 when there is none.
int ohos_host_shell_flyout_header(const char* text);
int ohos_host_shell_flyout_footer(const char* text);

/// Screenshot: asks the ArkTS shell to snapshot the main window (window.snapshot) and write a
/// PNG to out_path (an app cache/files path chosen by the caller). Returns 0 when the request
/// reached the shell sink, -1 when there is none or out_path is NULL/empty. The write is
/// asynchronous: the shell logs its own failure and the caller reads the file when ready.
int ohos_host_screenshot(const char* out_path);

/// Geocoding request/response (same shape as the clipboard bridge): the managed side asks
/// through ohos_host_geocode_request (op 0 = address -> location, arg is a JSON object of one
/// address; op 1 = location -> address, arg is "lat,lon"); the shell answers through
/// ohos_host_geocode_complete, delivered to the callback registered by
/// ohos_host_register_geocode_result. rc 0 = success with a JSON GeoAddress array, -1 =
/// unavailable (no sink, no permission, no service or malformed argument).
void ohos_host_geocode_set_listener(void (*listener)(int request_id, int op, const char* arg));
int ohos_host_geocode_request(int op, const char* arg, int request_id);
void ohos_host_register_geocode_result(void* callback);
void ohos_host_geocode_complete(int request_id, int rc, const char* json);

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

/// Pushes a lifecycle event into the managed bridge (queued until the handle is published and
/// the bridge registers; events pushed before the handle exists are transferred to it).
void ohos_host_notify_lifecycle(OhosHostAppHandle* handle, ohos_lifecycle_event event);

/// Stores the ArkUI NodeContent handle for the managed app (0 clears it); a value received
/// before the app handle exists is queued and delivered when the bridge registers.
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

// --- accessibility shadow tree (native node table) ---------------------------------
// The managed runtime publishes one node per rendered frame through
// ohos_host_accessibility_node; the NAPI accessibility provider reads the table back
// through ohos_host_accessibility_get and fills ArkUI element info from it.
// THE ARGUMENT ORDER IS THE CONTRACT: the managed DllImport in maui-ohos
// (OpenHarmonyAccessibility.AccessibilityNode), this header and openharmony_host.c must
// all agree. Under AAPCS64 any arity/order drift shifts arguments silently (an earlier
// revision declared hint as the managed 6th argument while the C side had none, so flags
// and actions were delivered swapped on device), which is why the interaction harness
// reflects the managed parameter list and compares it against the C source. Do not
// reorder, insert or drop arguments without changing both sides and the harness assertion.
// Absent values: hint may be NULL; a range is only valid when range_min <= range_max
// (NaN compares false); checked is -1 when unknown/not applicable and 0/1 otherwise.
int ohos_host_accessibility_begin(int count);
int ohos_host_accessibility_node(int id, int parent_id, const char* role, const char* text,
                                 const char* description, const char* hint,
                                 float x, float y, float width, float height,
                                 int flags, int actions,
                                 double range_min, double range_max, double range_current,
                                 int checked);
int ohos_host_accessibility_commit(void);
int ohos_host_accessibility_count(void);
/// Published node count (the number of nodes the provider sees after the last commit).
/// Read by the ArkTS shell through the NAPI accessibilityNodeCount export, which backs the
/// accessibility self-check dialog. The distinct name keeps the off-device publish-contract
/// reflection (which resolves the 16-argument publish function by its exact name) unambiguous;
/// this function is not part of that contract.
int ohos_host_accessibility_node_count(void);
/// Reads one published node. The string outputs are copies owned by the host (per-thread,
/// valid until the next get on the same thread), never pointers into the mutable node table,
/// so a concurrent ohos_host_accessibility_begin/commit cannot free them under the caller.
/// The caller must not free them. Mirrors the publish argument order.
int ohos_host_accessibility_get(int index, int* id, int* parent_id, const char** role,
                                const char** text, const char** description, const char** hint,
                                float* x, float* y, float* width, float* height,
                                int* flags, int* actions,
                                double* range_min, double* range_max, double* range_current,
                                int* checked);
void ohos_host_accessibility_set_action_listener(void* callback);
int ohos_host_accessibility_send_event(int event_type);
int ohos_host_accessibility_provider_status(void);
/// Announces text through the platform screen reader: creates an accessibility event with
/// event type ARKUI_ACCESSIBILITY_NATIVE_EVENT_TYPE_ANNOUNCE_FOR_ACCESSIBILITY, sets the
/// announced text and sends it asynchronously through the attached provider. Same lifetime
/// discipline as ohos_host_accessibility_send_event (the event is destroyed on every path).
/// Returns 1 when the event was created and sent, 0 when there is no provider or the text is
/// NULL/empty.
int ohos_host_accessibility_announce(const char* text);

/// The ArkUI NodeContent handle previously stored (may be NULL).
void* ohos_host_get_node_content(OhosHostAppHandle* handle);

/// Waits for the managed application to finish and returns its exit code
/// (also releases the handle).
int ohos_host_join_app(OhosHostAppHandle* handle);

#ifdef __cplusplus
}
#endif

#endif  // OPENHARMONY_HOST_H
