// Per-instance accessibility shadow-node table (MULTIWINDOW-L2 option a, W1).
//
// The host has always served one process-global node table: the managed runtime publishes it
// per rendered frame (ohos_host_accessibility_begin/node/commit) and the NAPI accessibility
// provider reads it back (count/get/index_of). MULTIWINDOW-L2 adds a second provider for the
// child window (OH_ArkUI_AccessibilityProviderRegisterCallbackWithInstance); two windows
// publishing into one table would overwrite each other, so the table is partitioned per
// provider instance.
//
// The module is pure C (stdlib/pthread/string only), so host_a11y_table_test.c exercises the
// partition semantics off-device through scripts/selftest-host-a11y-table.sh. It is compiled
// into libopenharmonyhost.so by scripts/build-host.sh and src/OpenHarmonyHost/CMakeLists.txt.
#ifndef OPENHARMONY_HOST_A11Y_TABLE_H
#define OPENHARMONY_HOST_A11Y_TABLE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Longest accepted instance id, NUL included (the shell's managed window ids are short:
// "sub-1", "main", ...). A longer id is rejected by every *_for entry.
#define OHOS_A11Y_INSTANCE_MAX 64

// Number of named partitions besides the legacy primary one. The runtime opens at most one
// managed child window (application-level N=1), so 8 keeps room for id reuse across sessions
// while bounding what a buggy caller can allocate.
#define OHOS_A11Y_MAX_NAMED_PARTITIONS 8

// True when the instance id is a non-empty printable-ASCII string within OHOS_A11Y_INSTANCE_MAX.
// The NULL/empty string is the legacy primary partition and is accepted by the callers, not here.
int ohos_host_accessibility_instance_valid(const char* instance);

// Drops every partition. Unit tests only (the runtime never clears a provider's table: a
// window's next publish rebuilds it, exactly like the legacy table).
void ohos_host_accessibility_table_reset(void);

#ifdef __cplusplus
}
#endif

#endif  // OPENHARMONY_HOST_A11Y_TABLE_H
