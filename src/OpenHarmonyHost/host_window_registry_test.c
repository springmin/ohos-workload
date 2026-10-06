// Off-device unit tests for the per-window XComponent surface registry (MULTIWINDOW-L M1).
// Pure C: compiles and runs on the development host, no device, no NAPI, no OpenHarmony SDK.
// Run through scripts/selftest-host-registry.sh (it also checks the same sources ship in the
// host build via CMakeLists.txt and scripts/build-host.sh).
//
// Required M1 cases: dual-surface register/unregister, duplicate ids/components, capacity,
// surface lifecycle and out-of-order events, and per-owner teardown.
#include <stdio.h>
#include <string.h>

#include "host_window_registry.h"

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

// Reads a record or fails the check with a readable label.
static int Lookup(const char* id, ohos_host_window_record* out, const char* label) {
    int rc = ohos_host_window_lookup(id, out);
    Check(rc == OHOS_HOST_WINDOW_OK, label);
    return rc == OHOS_HOST_WINDOW_OK;
}

int main(void) {
    ohos_host_window_record record;
    char long_id[OHOS_HOST_WINDOW_ID_MAX + 2];
    memset(long_id, 'x', sizeof(long_id) - 1);
    long_id[sizeof(long_id) - 1] = '\0';

    // --- fresh registry ---------------------------------------------------------------
    ohos_host_window_reset();
    Check(ohos_host_window_count() == 0, "fresh registry is empty");

    // --- primary + duplicates ---------------------------------------------------------
    Check(ohos_host_window_register(OHOS_HOST_WINDOW_PRIMARY_ID, (void*)0x10, (void*)0x100, 1) ==
              OHOS_HOST_WINDOW_OK,
          "register primary main");
    Check(ohos_host_window_count() == 1, "count is 1 after the primary");
    if (Lookup(OHOS_HOST_WINDOW_PRIMARY_ID, &record, "lookup primary")) {
        Check(record.primary == 1 && record.component == (void*)0x10 && record.owner == (void*)0x100,
              "primary record carries component/owner/primary");
        Check(record.state == -1 && record.surface == NULL && record.surface_events == 0,
              "primary record starts with no surface state");
    }
    Check(ohos_host_window_register(OHOS_HOST_WINDOW_PRIMARY_ID, (void*)0x11, NULL, 0) ==
              OHOS_HOST_WINDOW_DUPLICATE,
          "duplicate id with another component is rejected");
    Check(ohos_host_window_count() == 1, "rejected duplicate adds nothing");
    Check(ohos_host_window_register(OHOS_HOST_WINDOW_PRIMARY_ID, (void*)0x10, (void*)0x100, 1) ==
              OHOS_HOST_WINDOW_OK,
          "same id+component registration is idempotent");
    Check(ohos_host_window_count() == 1, "idempotent registration adds nothing");
    Check(ohos_host_window_register("other", (void*)0x10, NULL, 0) == OHOS_HOST_WINDOW_DUPLICATE,
          "component already registered under another id is rejected");

    // --- invalid arguments ------------------------------------------------------------
    Check(ohos_host_window_register(NULL, (void*)0x20, NULL, 0) == OHOS_HOST_WINDOW_INVALID,
          "NULL id is rejected");
    Check(ohos_host_window_register("", (void*)0x20, NULL, 0) == OHOS_HOST_WINDOW_INVALID,
          "empty id is rejected");
    Check(ohos_host_window_register(long_id, (void*)0x20, NULL, 0) == OHOS_HOST_WINDOW_INVALID,
          "over-long id is rejected (never truncated into a collision)");
    Check(ohos_host_window_register("nullcomp", NULL, NULL, 0) == OHOS_HOST_WINDOW_INVALID,
          "NULL component is rejected");

    // --- second window + surface lifecycle --------------------------------------------
    Check(ohos_host_window_register("child-a", (void*)0x20, (void*)0x100, 0) == OHOS_HOST_WINDOW_OK,
          "register second window child-a");
    Check(ohos_host_window_count() == 2, "count is 2 after the second window");
    Check(ohos_host_window_surface("child-a", (void*)0x2000, 720, 171, 0) == OHOS_HOST_WINDOW_OK,
          "surface created on child-a");
    if (Lookup("child-a", &record, "lookup after created")) {
        Check(record.surface == (void*)0x2000 && record.width == 720 && record.height == 171 &&
                  record.state == 0 && record.surface_events == 1 && record.primary == 0,
              "created event stores surface/size/state and counts once");
    }
    Check(ohos_host_window_surface("child-a", (void*)0x2000, 720, 200, 1) == OHOS_HOST_WINDOW_OK,
          "surface changed on child-a");
    if (Lookup("child-a", &record, "lookup after changed")) {
        Check(record.width == 720 && record.height == 200 && record.state == 1 &&
                  record.surface_events == 2,
              "changed event updates size/state and counts");
    }
    Check(ohos_host_window_surface("child-a", NULL, 0, 0, 2) == OHOS_HOST_WINDOW_OK,
          "surface destroyed on child-a");
    if (Lookup("child-a", &record, "lookup after destroyed")) {
        Check(record.surface == NULL && record.width == 0 && record.height == 0 && record.state == 2 &&
                  record.surface_events == 3,
              "destroyed event stores the destroyed state");
    }
    // Out of order: the platform recreates a surface without a re-registration; the late chain
    // must be accepted and must keep counting.
    Check(ohos_host_window_surface("child-a", (void*)0x2100, 700, 180, 0) == OHOS_HOST_WINDOW_OK,
          "created after destroyed (out-of-order recreate) is accepted");
    if (Lookup("child-a", &record, "lookup after recreate")) {
        Check(record.surface == (void*)0x2100 && record.width == 700 && record.height == 180 &&
                  record.state == 0 && record.surface_events == 4,
              "recreate overwrites the previous surface state");
    }

    // --- events before registration / after unregistration ----------------------------
    Check(ohos_host_window_surface("ghost", (void*)0x1, 10, 10, 0) == OHOS_HOST_WINDOW_NOT_FOUND,
          "surface event for an unknown id is dropped");
    Check(ohos_host_window_note_touch("ghost") == OHOS_HOST_WINDOW_NOT_FOUND,
          "touch event for an unknown id is dropped");
    Check(ohos_host_window_note_frame("ghost") == OHOS_HOST_WINDOW_NOT_FOUND,
          "frame event for an unknown id is dropped");

    // --- routed-event counters ---------------------------------------------------------
    Check(ohos_host_window_note_touch("child-a") == OHOS_HOST_WINDOW_OK &&
              ohos_host_window_note_touch("child-a") == OHOS_HOST_WINDOW_OK &&
              ohos_host_window_note_frame("child-a") == OHOS_HOST_WINDOW_OK,
          "touch/frame counters accept known windows");
    if (Lookup("child-a", &record, "lookup counters")) {
        Check(record.touch_events == 2 && record.frame_events == 1, "touch/frame counters are per window");
    }

    // --- component lookup (the callback routing key) -----------------------------------
    Check(ohos_host_window_lookup_component((void*)0x20, &record) == OHOS_HOST_WINDOW_OK &&
              strcmp(record.id, "child-a") == 0,
          "lookup by component returns the owning window");
    Check(ohos_host_window_lookup_component((void*)0x99, &record) == OHOS_HOST_WINDOW_NOT_FOUND,
          "lookup by unknown component fails");
    Check(ohos_host_window_lookup(NULL, &record) == OHOS_HOST_WINDOW_INVALID &&
              ohos_host_window_lookup("child-a", NULL) == OHOS_HOST_WINDOW_INVALID &&
              ohos_host_window_lookup_component(NULL, &record) == OHOS_HOST_WINDOW_INVALID,
          "lookups reject NULL id/component/out");

    // --- explicit-id rename (M3: the shell's registerXComponent id is authoritative) ----
    Check(ohos_host_window_rename_component((void*)0x20, "child-managed") == OHOS_HOST_WINDOW_OK,
          "rename: an explicit id renames the component's window");
    if (Lookup("child-managed", &record, "rename: lookup the new id")) {
        Check(strcmp(record.id, "child-managed") == 0 && record.component == (void*)0x20 &&
                  record.touch_events == 2 && record.frame_events == 1,
              "rename: the record and its counters moved to the new id");
    }
    Check(ohos_host_window_lookup("child-a", &record) == OHOS_HOST_WINDOW_NOT_FOUND,
          "rename: the old id no longer resolves");
    Check(ohos_host_window_rename_component((void*)0x20, "main") == OHOS_HOST_WINDOW_DUPLICATE,
          "rename: an id taken by another component is refused");
    Check(ohos_host_window_rename_component((void*)0x99, "child-x") == OHOS_HOST_WINDOW_NOT_FOUND &&
              ohos_host_window_rename_component(NULL, "child-x") == OHOS_HOST_WINDOW_INVALID &&
              ohos_host_window_rename_component((void*)0x20, "") == OHOS_HOST_WINDOW_INVALID,
          "rename: unknown component / NULL component / empty id are rejected");
    Check(ohos_host_window_rename_component((void*)0x20, "child-a") == OHOS_HOST_WINDOW_OK,
          "rename: renaming back keeps the later checks on their id");

    // --- unregister ---------------------------------------------------------------------
    Check(ohos_host_window_unregister("child-a") == OHOS_HOST_WINDOW_OK, "unregister child-a");
    Check(ohos_host_window_count() == 1, "count drops after unregister");
    Check(ohos_host_window_unregister("child-a") == OHOS_HOST_WINDOW_NOT_FOUND,
          "double unregister is rejected");
    Check(ohos_host_window_surface("child-a", (void*)0x1, 1, 1, 0) == OHOS_HOST_WINDOW_NOT_FOUND,
          "late surface event after unregister is dropped");
    Check(ohos_host_window_lookup_component((void*)0x20, &record) == OHOS_HOST_WINDOW_NOT_FOUND,
          "unregistered component no longer routes");

    // --- re-register the id with a fresh component --------------------------------------
    Check(ohos_host_window_register("child-a", (void*)0x21, (void*)0x100, 0) == OHOS_HOST_WINDOW_OK,
          "re-register the same id with a new component");
    if (Lookup("child-a", &record, "lookup re-registered")) {
        Check(record.component == (void*)0x21 && record.surface == NULL && record.surface_events == 0 &&
                  record.state == -1,
              "re-registered window starts from a clean record");
    }

    // --- component-keyed surface routing (atomic against id reuse) ----------------------
    // child-a is now owned by component 0x21; a late surface event that still carries the
    // previous component 0x20 must not be attributed to the re-registered record.
    Check(ohos_host_window_surface_component((void*)0x20, (void*)0x2200, 1, 1, 0, &record) ==
              OHOS_HOST_WINDOW_NOT_FOUND,
          "component surface: late event from the previous owner is dropped");
    if (Lookup("child-a", &record, "component surface: lookup after the late event")) {
        Check(record.component == (void*)0x21 && record.surface == NULL && record.surface_events == 0,
              "component surface: the new owner's record is untouched");
    }
    Check(ohos_host_window_surface_component((void*)0x21, (void*)0x2100, 640, 480, 0, &record) ==
                  OHOS_HOST_WINDOW_OK &&
              strcmp(record.id, "child-a") == 0 && record.component == (void*)0x21 &&
              record.surface == (void*)0x2100 && record.width == 640 && record.height == 480 &&
              record.state == 0 && record.surface_events == 1,
          "component surface: updates the owner's record and copies it out");
    Check(ohos_host_window_surface_component(NULL, (void*)0x1, 1, 1, 0, &record) ==
                  OHOS_HOST_WINDOW_INVALID &&
              ohos_host_window_surface_component((void*)0x21, (void*)0x1, 1, 1, 0, NULL) ==
                  OHOS_HOST_WINDOW_INVALID &&
              ohos_host_window_surface_component((void*)0x99, (void*)0x1, 1, 1, 0, &record) ==
                  OHOS_HOST_WINDOW_NOT_FOUND,
          "component surface: NULL component/out and unknown component are rejected");

    // --- capacity ------------------------------------------------------------------------
    ohos_host_window_reset();
    Check(ohos_host_window_register("w0", (void*)0x30, NULL, 1) == OHOS_HOST_WINDOW_OK,
          "capacity: first of eight registers");
    for (int i = 1; i < OHOS_HOST_WINDOW_COUNT_MAX; i++) {
        char id[16];
        snprintf(id, sizeof(id), "w%d", i);
        if (ohos_host_window_register(id, (void*)(long)(0x30 + i), NULL, 0) != OHOS_HOST_WINDOW_OK) {
            Check(0, "capacity: fill the table");
            break;
        }
    }
    Check(ohos_host_window_count() == OHOS_HOST_WINDOW_COUNT_MAX, "capacity: table is full");
    Check(ohos_host_window_register("w-overflow", (void*)0x40, NULL, 0) == OHOS_HOST_WINDOW_FULL,
          "capacity: ninth window is rejected with FULL");
    Check(ohos_host_window_unregister("w3") == OHOS_HOST_WINDOW_OK &&
              ohos_host_window_register("w-overflow", (void*)0x40, NULL, 0) == OHOS_HOST_WINDOW_OK,
          "capacity: a freed slot is reusable");

    // --- per-owner teardown (binding/env cleanup) ----------------------------------------
    ohos_host_window_reset();
    Check(ohos_host_window_register("main", (void*)0x50, (void*)0x500, 1) == OHOS_HOST_WINDOW_OK &&
              ohos_host_window_register("child", (void*)0x51, (void*)0x501, 0) == OHOS_HOST_WINDOW_OK,
          "owner teardown: two windows with distinct owners");
    Check(ohos_host_window_unregister_owner((void*)0x500) == 1, "owner teardown removes the matching window");
    Check(ohos_host_window_count() == 1, "owner teardown leaves the other owner alone");
    Check(ohos_host_window_lookup("child", &record) == OHOS_HOST_WINDOW_OK &&
              record.owner == (void*)0x501,
          "owner teardown target survives");
    Check(ohos_host_window_unregister_owner(NULL) == 0, "owner teardown with NULL owner is a no-op");
    Check(ohos_host_window_unregister_owner((void*)0x501) == 1 && ohos_host_window_count() == 0,
          "owner teardown removes the last window");

    // --- order / iteration ---------------------------------------------------------------
    ohos_host_window_reset();
    Check(ohos_host_window_register("a", (void*)0x60, NULL, 0) == OHOS_HOST_WINDOW_OK &&
              ohos_host_window_register("b", (void*)0x61, NULL, 0) == OHOS_HOST_WINDOW_OK &&
              ohos_host_window_register("c", (void*)0x62, NULL, 0) == OHOS_HOST_WINDOW_OK,
          "order: register a, b, c");
    Check(ohos_host_window_at(0, &record) == 0 && strcmp(record.id, "a") == 0 &&
              ohos_host_window_at(2, &record) == 0 && strcmp(record.id, "c") == 0,
          "order: iteration follows registration order");
    Check(ohos_host_window_at(3, &record) == -1 && ohos_host_window_at(-1, &record) == -1 &&
              ohos_host_window_at(0, NULL) == -1,
          "order: out-of-range/NULL iteration is rejected");
    Check(ohos_host_window_unregister("b") == OHOS_HOST_WINDOW_OK &&
              ohos_host_window_at(1, &record) == 0 && strcmp(record.id, "c") == 0,
          "order: removal compacts the table");

    ohos_host_window_reset();
    Check(ohos_host_window_count() == 0, "reset drops every record");

    printf("host-window-registry: %d checks, %d failure(s)\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
