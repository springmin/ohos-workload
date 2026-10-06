// Per-window XComponent surface registry (MULTIWINDOW-L M1).
//
// The host used to bind exactly one XComponent: one xcomponent slot in host_napi.cpp and one
// g_surface_window/g_surface_* set in openharmony_host.c behind the managed bridge's surface
// callback. MULTIWINDOW-M proved an application subwindow carries its own XComponent (the
// framework calls NAPI Init once per XComponent and each call carries its own
// OH_NATIVE_XCOMPONENT_OBJ), so the host keeps one record per registered XComponent ("window")
// and routes every surface lifecycle event to the record its component belongs to.
//
// This module is the storage for that registry. It is deliberately pure C with no NAPI or
// OpenHarmony headers, so the same source that ships in libopenharmonyhost.so is exercised
// off-device by src/OpenHarmonyHost/host_window_registry_test.c through
// scripts/selftest-host-registry.sh. host_napi.cpp is the only caller in M1.
//
// The legacy single-window path stays authoritative for the primary window: its record is marked
// primary and the caller keeps forwarding its surface events through the historical
// ohos_host_set_native_window entry (and its g_surface_* state), so a single-XComponent shell
// keeps byte-for-byte the same behaviour. Secondary windows only record their surface state in
// M1; the per-window managed renderer attaches in M2.
//
// All functions are callable from any thread (the module owns one mutex) and copy records out,
// so no pointer into the table ever escapes.

#ifndef OPENHARMONY_HOST_WINDOW_REGISTRY_H
#define OPENHARMONY_HOST_WINDOW_REGISTRY_H

#ifdef __cplusplus
extern "C" {
#endif

// Window-id and capacity bounds. An id longer than the maximum is rejected (INVALID) rather than
// silently truncated, so a caller cannot collide two windows by overflow.
#define OHOS_HOST_WINDOW_ID_MAX 63
#define OHOS_HOST_WINDOW_COUNT_MAX 8

// The primary (legacy single-surface) window's id. HostClaimXComponent in host_napi.cpp assigns
// it to the first claimed XComponent; hosts keep using the historical single-surface path.
#define OHOS_HOST_WINDOW_PRIMARY_ID "main"

typedef enum ohos_host_window_status {
    OHOS_HOST_WINDOW_OK = 0,
    // The id is registered to a different component, or the component is already registered
    // under another id. Registration is idempotent for an identical (id, component) pair.
    OHOS_HOST_WINDOW_DUPLICATE = -1,
    // OHOS_HOST_WINDOW_COUNT_MAX windows are already registered.
    OHOS_HOST_WINDOW_FULL = -2,
    // NULL/empty/over-long id or NULL component.
    OHOS_HOST_WINDOW_INVALID = -3,
    // The id (or, for the component lookup, the component) is not registered.
    OHOS_HOST_WINDOW_NOT_FOUND = -4,
} ohos_host_window_status;

// One registered window. id is NUL-terminated; component is the OH_NativeXComponent* identity
// the callbacks receive (opaque here), owner the registering binding (opaque; bulk-unregistered
// on env teardown), surface the OHNativeWindow* from the last surface callback. state mirrors
// ohos_surface_state (0 created / 1 changed / 2 destroyed), -1 before the first surface event;
// the counter fields let the device probe tell an event was routed.
typedef struct ohos_host_window_record {
    char id[OHOS_HOST_WINDOW_ID_MAX + 1];
    void* component;
    void* owner;
    void* surface;
    int width;
    int height;
    int state;
    int primary;
    unsigned long long surface_events;
    unsigned long long touch_events;
    unsigned long long frame_events;
} ohos_host_window_record;

// Registers component under id. primary marks the legacy single-surface window. Re-registering
// the same (id, component) pair is a no-op (OK); a duplicate id or component is rejected and a
// full table returns FULL. On failure nothing is stored.
int ohos_host_window_register(const char* id, void* component, void* owner, int primary);

// Renames the window registered for a component to new_id (MULTIWINDOW-L M3): the shell's
// explicit registerXComponent(id) is authoritative over an auto-derived component id, so the
// managed session id and the host registry id stay identical. The primary flag and the counters
// stay with the record; a new_id already taken by another component returns DUPLICATE, an
// unknown component NOT_FOUND and an invalid id INVALID.
int ohos_host_window_rename_component(void* component, const char* new_id);

// Records one surface lifecycle event (created/changed/destroyed) for id: stores the window
// pointer and geometry, updates the state and bumps surface_events. Out-of-order events are
// accepted (the platform recreates a surface after a destroy without a re-registration); an
// event for an unknown id returns NOT_FOUND and changes nothing.
int ohos_host_window_surface(const char* id, void* surface, int width, int height, int state);

// Records the same surface event keyed by the component pointer the callback received (the
// routing key), looking the record up and updating it under one lock: unlike the id-keyed
// variant, an unregister/re-register of the same id between a lookup and an update cannot
// attribute the event to a different component's record. Copies the updated record to out.
// Unknown component returns NOT_FOUND; NULL component or NULL out returns INVALID.
int ohos_host_window_surface_component(void* component, void* surface, int width, int height,
                                       int state, ohos_host_window_record* out);

// Bumps the routed-event counters (the per-window input/frame lifecycle in M1: recorded, not
// yet dispatched to a per-window managed bridge). Unknown id returns NOT_FOUND.
int ohos_host_window_note_touch(const char* id);
int ohos_host_window_note_frame(const char* id);

// Removes id. A late event after the removal returns NOT_FOUND.
int ohos_host_window_unregister(const char* id);

// Removes every window registered with this owner and returns the number removed (0 for a NULL
// owner or none matching). Called from the NAPI binding teardown so a page rebuild cannot leave
// records pointing at a dead env's components.
int ohos_host_window_unregister_owner(void* owner);

// Copies the record for id / for a component pointer into out. Returns NOT_FOUND (id or
// component unknown) or INVALID (NULL out).
int ohos_host_window_lookup(const char* id, ohos_host_window_record* out);
int ohos_host_window_lookup_component(void* component, ohos_host_window_record* out);

// Copies the index-th record in registration order (removals compact the table). Out-of-range
// index or NULL out returns -1.
int ohos_host_window_at(int index, ohos_host_window_record* out);

// Number of registered windows.
int ohos_host_window_count(void);

// Drops every record (unit tests; not used by the host runtime).
void ohos_host_window_reset(void);

#ifdef __cplusplus
}
#endif

#endif  // OPENHARMONY_HOST_WINDOW_REGISTRY_H
