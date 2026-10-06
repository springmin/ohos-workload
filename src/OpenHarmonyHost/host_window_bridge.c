// Per-window dispatch bridge (MULTIWINDOW-L M2, M2-ow). See host_window_bridge.h for the
// contract; this file is pure C (no NAPI/OpenHarmony headers) so it is unit-testable
// off-device.
#include "host_window_bridge.h"

#include <pthread.h>
#include <stddef.h>

typedef void (*ohos_host_window_surface_fn)(const char*, void*, int, int, int);
typedef void (*ohos_host_window_touch_fn)(const char*, int, const OhosTouchPoint*, int, int,
                                          float, float);
typedef void (*ohos_host_window_frame_fn)(const char*, int64_t, int64_t);

static ohos_host_window_surface_fn g_window_surface = NULL;
static ohos_host_window_touch_fn g_window_touch = NULL;
static ohos_host_window_frame_fn g_window_frame = NULL;
static ohos_host_window_pinch_fn g_window_pinch = NULL;
static pthread_mutex_t g_window_bridge_lock = PTHREAD_MUTEX_INITIALIZER;

void ohos_host_register_window_bridge(void* surface, void* touch, void* frame) {
    pthread_mutex_lock(&g_window_bridge_lock);
    g_window_surface = (ohos_host_window_surface_fn)surface;
    g_window_touch = (ohos_host_window_touch_fn)touch;
    g_window_frame = (ohos_host_window_frame_fn)frame;
    pthread_mutex_unlock(&g_window_bridge_lock);
}

void ohos_host_register_window_pinch(void* pinch) {
    pthread_mutex_lock(&g_window_bridge_lock);
    g_window_pinch = (ohos_host_window_pinch_fn)pinch;
    pthread_mutex_unlock(&g_window_bridge_lock);
}

void ohos_host_window_bridge_reset(void) {
    pthread_mutex_lock(&g_window_bridge_lock);
    g_window_surface = NULL;
    g_window_touch = NULL;
    g_window_frame = NULL;
    g_window_pinch = NULL;
    pthread_mutex_unlock(&g_window_bridge_lock);
}

// A callback must never run under g_window_bridge_lock: the managed handler may call back into
// registration (or into the host's other bridges), and a mutex held across managed code would
// make that a deadlock. The slot is copied under the lock, then invoked after it.
static int WindowIdValid(const char* id) {
    return id != NULL && id[0] != '\0';
}

void ohos_host_set_window_native_window(const char* id, void* window, int width, int height,
                                        ohos_surface_state state) {
    if (!WindowIdValid(id)) {
        return;
    }
    ohos_host_window_surface_fn callback;
    pthread_mutex_lock(&g_window_bridge_lock);
    callback = g_window_surface;
    pthread_mutex_unlock(&g_window_bridge_lock);
    if (callback != NULL) {
        callback(id, window, width, height, (int)state);
    }
}

void ohos_host_notify_window_touch(const char* id, int type, const OhosTouchPoint* points,
                                   int count, int pointerId, float x, float y) {
    if (!WindowIdValid(id)) {
        return;
    }
    ohos_host_window_touch_fn callback;
    pthread_mutex_lock(&g_window_bridge_lock);
    callback = g_window_touch;
    pthread_mutex_unlock(&g_window_bridge_lock);
    if (callback != NULL) {
        callback(id, type, points, count, pointerId, x, y);
    }
}

void ohos_host_notify_window_frame(const char* id, int64_t timestamp, int64_t targetTimestamp) {
    if (!WindowIdValid(id)) {
        return;
    }
    ohos_host_window_frame_fn callback;
    pthread_mutex_lock(&g_window_bridge_lock);
    callback = g_window_frame;
    pthread_mutex_unlock(&g_window_bridge_lock);
    if (callback != NULL) {
        callback(id, timestamp, targetTimestamp);
    }
}

void ohos_host_notify_window_pinch(const char* id, int phase, double scale, float x, float y) {
    if (!WindowIdValid(id)) {
        return;
    }
    ohos_host_window_pinch_fn callback;
    pthread_mutex_lock(&g_window_bridge_lock);
    callback = g_window_pinch;
    pthread_mutex_unlock(&g_window_bridge_lock);
    if (callback != NULL) {
        callback(id, phase, scale, x, y);
    }
}
