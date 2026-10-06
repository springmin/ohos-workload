// Off-device unit tests for the per-instance accessibility shadow-node table
// (MULTIWINDOW-L2 option a, W1). Pure C: compiles and runs on the development host, no device,
// no NAPI, no OpenHarmony SDK. Run through scripts/selftest-host-a11y-table.sh (which also
// compiles a red-control variant that ignores the instance key and requires this binary's
// partition checks to fail, plus the build/export wiring pins).
//
// Required cases: the legacy (primary) roundtrip is byte-for-byte the historical table; named
// partitions hold their own nodes, ids and counts; a publish into one partition never changes
// another; unknown/invalid instances fail cleanly; the per-thread string copies survive a
// concurrent republish; the named-partition count is capped; reset drops everything.
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "host_a11y_table.h"
#include "openharmony_host.h"

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

// Publishes one node into one partition. The legacy form publishes into the primary partition.
static void PublishLegacy(int id, const char* role, const char* text) {
    ohos_host_accessibility_begin(1);
    ohos_host_accessibility_node(id, 0, role, text, NULL, NULL, 1, 2, 3, 4, 3, 0x10,
                                 NAN, NAN, 0, -1);
    ohos_host_accessibility_commit();
}

static void PublishFor(const char* instance, int id, const char* role, const char* text) {
    ohos_host_accessibility_begin_for(instance, 1);
    ohos_host_accessibility_node_for(instance, id, 0, role, text, NULL, NULL, 1, 2, 3, 4, 3, 0x10,
                                     NAN, NAN, 0, -1);
    ohos_host_accessibility_commit_for(instance);
}

static int ReadTextFor(const char* instance, int index, char* out, size_t out_size) {
    const char* text = NULL;
    int id = -1;
    // A NULL instance is the legacy primary export (an empty string is an invalid instance).
    int rc = instance != NULL
        ? ohos_host_accessibility_get_for(instance, index, &id, NULL, NULL, &text, NULL, NULL,
                                          NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                                          NULL)
        : ohos_host_accessibility_get(index, &id, NULL, NULL, &text, NULL, NULL, NULL, NULL, NULL,
                                      NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    if (rc != 0 || text == NULL) {
        return -1;
    }
    if (out != NULL && out_size > 0) {
        snprintf(out, out_size, "%s", text);
    }
    return id;
}

int main(void) {
    char text[32];
    ohos_host_accessibility_table_reset();

    // 1. Legacy roundtrip: the primary partition still serves the historical API exactly.
    PublishLegacy(11, "text", "main-A");
    text[0] = '\0';
    int legacyId = ReadTextFor(NULL, 0, text, sizeof(text));
    Check(ohos_host_accessibility_count() == 1 && legacyId == 11 && strcmp(text, "main-A") == 0
          && ohos_host_accessibility_index_of(11) == 0 && ohos_host_accessibility_index_of(99) == -1,
          "legacy begin/node/commit/count/get/index_of roundtrip");

    // 2. A named partition gets its own table.
    PublishFor("sub-a", 21, "button", "child-A");
    int namedId = ReadTextFor("sub-a", 0, text, sizeof(text));
    Check(ohos_host_accessibility_count_for("sub-a") == 1 && namedId == 21
          && strcmp(text, "child-A") == 0 && ohos_host_accessibility_index_of_for("sub-a", 21) == 0,
          "named partition publishes and reads its own node");

    // 3. Ids are positional per partition and must not leak across partitions.
    Check(ohos_host_accessibility_index_of_for("sub-a", 11) == -1
          && ohos_host_accessibility_index_of(21) == -1,
          "the same id only resolves in the partition that published it");

    // 4. Publishing another partition never overwrites the first one.
    PublishFor("sub-b", 31, "text", "child-B");
    int aId = ReadTextFor("sub-a", 0, text, sizeof(text));
    Check(aId == 21 && strcmp(text, "child-A") == 0
          && ohos_host_accessibility_count_for("sub-b") == 1
          && ReadTextFor("sub-b", 0, text, sizeof(text)) == 31 && strcmp(text, "child-B") == 0,
          "two providers keep independent frames (A survives B)");

    // 5. The primary partition is independent of every named one.
    Check(ohos_host_accessibility_count() == 1 && ReadTextFor(NULL, 0, text, sizeof(text)) == 11
          && strcmp(text, "main-A") == 0,
          "the primary table is untouched by named publishes");

    // 6. A republish into the primary table does not touch the named partitions.
    PublishLegacy(12, "text", "main-B");
    Check(ReadTextFor("sub-a", 0, text, sizeof(text)) == 21 && strcmp(text, "child-A") == 0
          && ReadTextFor("sub-b", 0, text, sizeof(text)) == 31 && strcmp(text, "child-B") == 0,
          "the primary republish is local to the primary partition");

    // 7. Unknown instances fail cleanly (no allocation, no crash).
    Check(ohos_host_accessibility_count_for("sub-missing") == 0
          && ohos_host_accessibility_get_for("sub-missing", 0, NULL, NULL, NULL, NULL, NULL, NULL,
                                             NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                                             NULL, NULL) == -1
          && ohos_host_accessibility_index_of_for("sub-missing", 1) == -1
          && ohos_host_accessibility_commit_for("sub-missing") == -1,
          "unknown instance reads fail cleanly");

    // 8. NULL/empty/over-long/non-printable instance ids are rejected.
    Check(ohos_host_accessibility_begin_for(NULL, 1) == -1
          && ohos_host_accessibility_begin_for("", 1) == -1
          && ohos_host_accessibility_begin_for("bad id", 1) == -1
          && !ohos_host_accessibility_instance_valid(NULL)
          && !ohos_host_accessibility_instance_valid("x y"),
          "invalid instance ids are rejected by every entry");

    // 9. The per-thread string copies stay valid across a republish of the same partition.
    const char* copy = NULL;
    ohos_host_accessibility_get_for("sub-a", 0, NULL, NULL, NULL, &copy, NULL, NULL, NULL, NULL,
                                    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    PublishFor("sub-a", 41, "text", "child-A2");
    Check(copy != NULL && strcmp(copy, "child-A") == 0,
          "a get string copy survives the partition's next begin");

    // 10. The named-partition count is capped (2 above + 6 here = 8; the 9th is rejected).
    PublishFor("sub-c", 51, "text", "c");
    PublishFor("sub-d", 52, "text", "d");
    PublishFor("sub-e", 53, "text", "e");
    PublishFor("sub-f", 54, "text", "f");
    PublishFor("sub-g", 55, "text", "g");
    PublishFor("sub-h", 56, "text", "h");
    Check(ohos_host_accessibility_count_for("sub-h") == 1
          && ohos_host_accessibility_begin_for("sub-overflow", 1) == -1
          && ohos_host_accessibility_count_for("sub-overflow") == 0,
          "named partitions are capped");

    // 11. Reset drops the primary and every named partition.
    ohos_host_accessibility_table_reset();
    Check(ohos_host_accessibility_count() == 0 && ohos_host_accessibility_count_for("sub-a") == 0
          && ohos_host_accessibility_count_for("sub-h") == 0,
          "reset drops the primary and named partitions");

    printf("[a11y-table] checks=%d failures=%d\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
