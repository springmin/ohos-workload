// Off-device unit tests for the per-window dispatch bridge (MULTIWINDOW-L M2, M2-ow).
// Pure C: compiles and runs on the development host, no device, no NAPI, no OpenHarmony SDK.
// Run through scripts/selftest-host-window-bridge.sh (it also checks the same source ships in
// the host build via CMakeLists.txt, scripts/build-host.sh and the export contract's SOURCES).
//
// Required M2 cases: the window id and payload arrive unchanged on all three channels, an
// empty/NULL id is dropped, re-registration replaces a callback, NULL disables one channel,
// a no-op before registration, and a callback may re-register from inside the callback.
// M4-04 adds the pinch channel (phase/scale/centre, own id, NULL disables it).
#include <stdio.h>
#include <string.h>

#include "host_window_bridge.h"

static int g_checks = 0;
static int g_failures = 0;

static void Check(int ok, const char* label) {
    g_checks++;
    if (ok) {
        printf("[PASS] %s\n", label);
    } else {
        g_failures++;
        printf("[FAIL] %s\n", label);
    }
}

// --- recording callbacks ---------------------------------------------------------------

static int g_surface_calls = 0;
static char g_surface_id[64];
static void* g_surface_window = NULL;
static int g_surface_width = 0;
static int g_surface_height = 0;
static int g_surface_state = -1;
static int g_reenter_from_surface = 0;

static void OnSurface(const char* id, void* window, int width, int height, int state) {
    g_surface_calls++;
    snprintf(g_surface_id, sizeof(g_surface_id), "%s", id);
    g_surface_window = window;
    g_surface_width = width;
    g_surface_height = height;
    g_surface_state = state;
    if (g_reenter_from_surface) {
        // The bridge must not hold its lock across the callback: re-registering from inside a
        // callback has to succeed (and must not deadlock).
        g_reenter_from_surface = 0;
        ohos_host_register_window_bridge(NULL, NULL, NULL);
    }
}

static int g_touch_calls = 0;
static char g_touch_id[64];
static int g_touch_type = -1;
static const OhosTouchPoint* g_touch_points = NULL;
static int g_touch_count = -1;
static int g_touch_pointer = -1;
static float g_touch_x = 0.0f;
static float g_touch_y = 0.0f;

static void OnTouch(const char* id, int type, const OhosTouchPoint* points, int count,
                    int pointerId, float x, float y) {
    g_touch_calls++;
    snprintf(g_touch_id, sizeof(g_touch_id), "%s", id);
    g_touch_type = type;
    g_touch_points = points;
    g_touch_count = count;
    g_touch_pointer = pointerId;
    g_touch_x = x;
    g_touch_y = y;
}

static int g_frame_calls = 0;
static char g_frame_id[64];
static int64_t g_frame_timestamp = -1;
static int64_t g_frame_target = -1;

static void OnFrame(const char* id, int64_t timestamp, int64_t targetTimestamp) {
    g_frame_calls++;
    snprintf(g_frame_id, sizeof(g_frame_id), "%s", id);
    g_frame_timestamp = timestamp;
    g_frame_target = targetTimestamp;
}

// MULTIWINDOW-L M4-04: the per-window pinch channel (phase 0 start, 1 update, 2 end).
static int g_pinch_calls = 0;
static char g_pinch_id[64];
static int g_pinch_phase = -1;
static double g_pinch_scale = 0.0;
static float g_pinch_x = 0.0f;
static float g_pinch_y = 0.0f;

static void OnPinch(const char* id, int phase, double scale, float x, float y) {
    g_pinch_calls++;
    snprintf(g_pinch_id, sizeof(g_pinch_id), "%s", id);
    g_pinch_phase = phase;
    g_pinch_scale = scale;
    g_pinch_x = x;
    g_pinch_y = y;
}

static void ResetRecorders(void) {
    g_surface_calls = 0;
    g_surface_id[0] = '\0';
    g_surface_window = NULL;
    g_surface_width = 0;
    g_surface_height = 0;
    g_surface_state = -1;
    g_touch_calls = 0;
    g_touch_id[0] = '\0';
    g_touch_type = -1;
    g_touch_points = NULL;
    g_touch_count = -1;
    g_touch_pointer = -1;
    g_touch_x = 0.0f;
    g_touch_y = 0.0f;
    g_frame_calls = 0;
    g_frame_id[0] = '\0';
    g_frame_timestamp = -1;
    g_frame_target = -1;
    g_pinch_calls = 0;
    g_pinch_id[0] = '\0';
    g_pinch_phase = -1;
    g_pinch_scale = 0.0;
    g_pinch_x = 0.0f;
    g_pinch_y = 0.0f;
}

int main(void) {
    // --- before registration: every channel is a silent no-op --------------------------
    ohos_host_window_bridge_reset();
    ohos_host_set_window_native_window("sub-1", (void*)0x1000, 640, 480, OHOS_SURFACE_CREATED);
    ohos_host_notify_window_touch("sub-1", 0, NULL, 0, 1, 12.5f, 24.5f);
    ohos_host_notify_window_frame("sub-1", 100, 116);
    ohos_host_notify_window_pinch("sub-1", 0, 1.0, 12.5f, 24.5f);
    Check(g_surface_calls == 0 && g_touch_calls == 0 && g_frame_calls == 0 && g_pinch_calls == 0,
          "events before registration are dropped without invoking a callback");

    // --- registration forwards every payload unchanged ---------------------------------
    ohos_host_register_window_bridge((void*)OnSurface, (void*)OnTouch, (void*)OnFrame);
    ohos_host_register_window_pinch((void*)OnPinch);
    ResetRecorders();
    ohos_host_set_window_native_window("sub-1", (void*)0x2000, 640, 480, OHOS_SURFACE_CREATED);
    Check(g_surface_calls == 1 && strcmp(g_surface_id, "sub-1") == 0 &&
              g_surface_window == (void*)0x2000 && g_surface_width == 640 &&
              g_surface_height == 480 && g_surface_state == (int)OHOS_SURFACE_CREATED,
          "surface event carries id, window, size and created state");

    ohos_host_set_window_native_window("sub-2", (void*)0x3000, 800, 600, OHOS_SURFACE_CHANGED);
    Check(g_surface_calls == 2 && strcmp(g_surface_id, "sub-2") == 0 &&
              g_surface_state == (int)OHOS_SURFACE_CHANGED,
          "a second window routes its own id and changed state");

    ohos_host_set_window_native_window("sub-1", (void*)0x2000, 0, 0, OHOS_SURFACE_DESTROYED);
    Check(g_surface_calls == 3 && strcmp(g_surface_id, "sub-1") == 0 &&
              g_surface_state == (int)OHOS_SURFACE_DESTROYED &&
              g_surface_width == 0 && g_surface_height == 0,
          "destroyed state forwards with zero geometry");

    OhosTouchPoint points[2] = {{7, 10.5f, 20.5f}, {8, 30.5f, 40.5f}};
    ResetRecorders();
    ohos_host_notify_window_touch("sub-1", 2, points, 2, 8, 30.5f, 40.5f);
    Check(g_touch_calls == 1 && strcmp(g_touch_id, "sub-1") == 0 && g_touch_type == 2 &&
              g_touch_points == points && g_touch_count == 2 && g_touch_pointer == 8 &&
              g_touch_x == 30.5f && g_touch_y == 40.5f,
          "touch event carries id, points, pointer id and coordinates");

    ohos_host_notify_window_touch("sub-1", 1, NULL, 0, 0, 1.0f, 2.0f);
    Check(g_touch_calls == 2 && g_touch_points == NULL && g_touch_count == 0 &&
              g_touch_x == 1.0f && g_touch_y == 2.0f,
          "point-less touch event (final up) forwards the fallback coordinates");

    ohos_host_notify_window_frame("sub-2", 111, 116);
    Check(g_frame_calls == 1 && strcmp(g_frame_id, "sub-2") == 0 &&
              g_frame_timestamp == 111 && g_frame_target == 116,
          "frame event carries id, timestamp and target timestamp");

    // M4-04: the pinch channel mirrors the frame channel (id first, payload unchanged).
    ohos_host_notify_window_pinch("sub-1", 1, 1.75, 30.5f, 40.5f);
    Check(g_pinch_calls == 1 && strcmp(g_pinch_id, "sub-1") == 0 && g_pinch_phase == 1 &&
              g_pinch_scale == 1.75 && g_pinch_x == 30.5f && g_pinch_y == 40.5f,
          "pinch event carries id, phase, scale and centre");
    ohos_host_notify_window_pinch("sub-2", 2, 1.0, 0.0f, 0.0f);
    Check(g_pinch_calls == 2 && strcmp(g_pinch_id, "sub-2") == 0 && g_pinch_phase == 2,
          "a second window routes its own pinch stream");

    // --- invalid ids are dropped --------------------------------------------------------
    ResetRecorders();
    ohos_host_set_window_native_window(NULL, (void*)0x4000, 10, 10, OHOS_SURFACE_CREATED);
    ohos_host_set_window_native_window("", (void*)0x4000, 10, 10, OHOS_SURFACE_CREATED);
    ohos_host_notify_window_touch(NULL, 0, NULL, 0, 0, 0.0f, 0.0f);
    ohos_host_notify_window_touch("", 0, NULL, 0, 0, 0.0f, 0.0f);
    ohos_host_notify_window_frame(NULL, 1, 2);
    ohos_host_notify_window_frame("", 1, 2);
    ohos_host_notify_window_pinch(NULL, 1, 1.0, 0.0f, 0.0f);
    ohos_host_notify_window_pinch("", 1, 1.0, 0.0f, 0.0f);
    Check(g_surface_calls == 0 && g_touch_calls == 0 && g_frame_calls == 0 && g_pinch_calls == 0,
          "NULL/empty window ids are dropped on every channel");

    // --- re-registration replaces the callback -----------------------------------------
    ResetRecorders();
    ohos_host_register_window_bridge((void*)OnSurface, NULL, NULL);
    ohos_host_register_window_pinch(NULL);
    ohos_host_set_window_native_window("sub-3", (void*)0x5000, 1, 2, OHOS_SURFACE_CHANGED);
    ohos_host_notify_window_touch("sub-3", 0, NULL, 0, 0, 0.0f, 0.0f);
    ohos_host_notify_window_pinch("sub-3", 1, 2.0, 1.0f, 1.0f);
    Check(g_surface_calls == 1 && strcmp(g_surface_id, "sub-3") == 0 && g_touch_calls == 0 &&
              g_pinch_calls == 0,
          "re-registration replaces the surface channel and disables touch/pinch with NULL");

    ResetRecorders();
    ohos_host_register_window_bridge(NULL, NULL, (void*)OnFrame);
    ohos_host_set_window_native_window("sub-4", (void*)0x5000, 1, 2, OHOS_SURFACE_CHANGED);
    ohos_host_notify_window_touch("sub-4", 0, NULL, 0, 0, 0.0f, 0.0f);
    ohos_host_notify_window_frame("sub-4", 10, 16);
    Check(g_surface_calls == 0 && g_touch_calls == 0 && g_frame_calls == 1 &&
              strcmp(g_frame_id, "sub-4") == 0,
          "re-registration can enable one channel while the others stay disabled");

    // --- a callback may re-register from inside the callback ----------------------------
    ResetRecorders();
    ohos_host_register_window_bridge((void*)OnSurface, (void*)OnTouch, (void*)OnFrame);
    g_reenter_from_surface = 1;
    ohos_host_set_window_native_window("main", (void*)0x6000, 1080, 1920, OHOS_SURFACE_CREATED);
    Check(g_surface_calls == 1 && strcmp(g_surface_id, "main") == 0,
          "a callback may re-register the bridge from inside the callback (no deadlock)");
    g_reenter_from_surface = 0;
    ResetRecorders();
    ohos_host_set_window_native_window("main", (void*)0x6000, 1080, 1920, OHOS_SURFACE_CREATED);
    ohos_host_notify_window_touch("main", 0, NULL, 0, 0, 0.0f, 0.0f);
    ohos_host_notify_window_frame("main", 1, 2);
    Check(g_surface_calls == 0 && g_touch_calls == 0 && g_frame_calls == 0,
          "the re-registration from inside the callback took effect");

    ohos_host_window_bridge_reset();
    printf("[bridge] checks=%d failures=%d\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
