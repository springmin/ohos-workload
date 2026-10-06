// Per-window dispatch bridge (MULTIWINDOW-L M2, M2-ow).
//
// M1 gave the host one record per XComponent ("window") and routed every surface/touch/frame
// callback to the record's component, but only the primary window entered the managed bridge
// (the untagged legacy slots in openharmony_host.c). M2 adds one window-id tagged channel:
// host_napi.cpp calls ohos_host_set_window_native_window / ohos_host_notify_window_touch /
// ohos_host_notify_window_frame with the registry id, and this module forwards each event to
// the managed callback the hosting assembly registered through
// ohos_host_register_window_bridge. The primary window keeps its historical untagged path
// unchanged; the tagged callback additionally receives it under the id "main".
//
// The module is pure C (only the shared OhosTouchPoint/ohos_surface_state types), so
// host_window_bridge_test.c exercises it off-device through
// scripts/selftest-host-window-bridge.sh. host_napi.cpp is the only runtime caller.
//
// Threading: one mutex owns the three callback slots. The callbacks are process-global (one
// bridged application per process, matching the legacy bridge) and are invoked outside the
// lock, so a callback may re-register without deadlocking. An event with a NULL/empty window
// id is dropped; an event with no registered callback is a no-op (the managed hosting assembly
// registers in Attach, before the shell creates the XComponents).

#ifndef OPENHARMONY_HOST_WINDOW_BRIDGE_H
#define OPENHARMONY_HOST_WINDOW_BRIDGE_H

#include <stdint.h>

#include "openharmony_host.h"

#ifdef __cplusplus
extern "C" {
#endif

// The window-id tagged event entries, called by host_napi.cpp for every registered window
// (the primary window also carries id "main" here, in addition to its untagged legacy call).
// An unknown/empty/NULL id is dropped; an event without a registered callback is a no-op.
void ohos_host_set_window_native_window(const char* id, void* window, int width, int height,
                                        ohos_surface_state state);
void ohos_host_notify_window_touch(const char* id, int type, const OhosTouchPoint* points,
                                   int count, int pointerId, float x, float y);
void ohos_host_notify_window_frame(const char* id, int64_t timestamp, int64_t targetTimestamp);

// Drops every callback (unit tests only; the runtime never clears the bridge).
void ohos_host_window_bridge_reset(void);

#ifdef __cplusplus
}
#endif

#endif  // OPENHARMONY_HOST_WINDOW_BRIDGE_H
