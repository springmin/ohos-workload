#!/bin/sh
# selftest-host-a11y-table.sh - off-device unit tests for the per-instance accessibility
# shadow-node table (MULTIWINDOW-L2 option a, W1: src/OpenHarmonyHost/host_a11y_table.c).
#
# The module ships inside libopenharmonyhost.so but is pure C (pthread/stdlib only), so this
# selftest compiles the shipped source with the development host's compiler and runs the unit
# cases without a device or an SDK:
#   green  - the legacy (primary) roundtrip plus the named-partition semantics: A/B frames stay
#            independent, ids resolve per partition, unknown/invalid instances fail cleanly,
#            the per-thread string copies survive a republish, the partition count is capped;
#   red    - the same test binary built against a copy of the source whose instance guard is
#            disabled (every named lookup falls back to the primary table, the exact regression
#            the partition prevents) must FAIL: the partition check turns assert=False. This is
#            the offline negative control for "A被B覆盖".
# The source-wiring pins keep the same file in the device build, the export contract and the
# NAPI/managed/shell consumers.
#
# Env: CC=<compiler>          compiler probe override (default: cc, clang, gcc)
#      SELFTEST_TMPDIR=<dir>  work dir base (default: the approved opencode dir, else TMPDIR,
#                             else /tmp)
#      SELFTEST_KEEP=1        keep the work dir even when all checks pass
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="1 (2026-10-06)"
# The unit binary's check count must stay at or above this floor; declared next to the suite
# contract so deleting/reducing cases fails the gate instead of silently shrinking coverage.
HOST_A11Y_TABLE_FLOOR=10

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

W="$(cd "$(dirname "$0")/.." && pwd)"
HOST="$W/src/OpenHarmonyHost"
TABLE="$HOST/host_a11y_table.c"
TEST="$HOST/host_a11y_table_test.c"
WORK_BASE="${SELFTEST_TMPDIR:-}"
if [ -z "$WORK_BASE" ]; then
    if [ -d /data/storage/el2/base/tmp/opencode ]; then
        WORK_BASE="/data/storage/el2/base/tmp/opencode"
    elif [ -n "${TMPDIR:-}" ]; then
        WORK_BASE="$TMPDIR"
    else
        WORK_BASE="/tmp"
    fi
fi
KEEP="${SELFTEST_KEEP:-0}"

for f in "$TABLE" "$TEST" "$HOST/host_a11y_table.h" "$HOST/openharmony_host.h"; do
    [ -f "$f" ] || { printf 'FATAL: missing %s\n' "$f" >&2; exit 1; }
done

WORK="$(mktemp -d "$WORK_BASE/selftest-host-a11y-table.XXXXXX")" || {
    printf 'FATAL: cannot create a work dir under %s\n' "$WORK_BASE" >&2
    exit 1
}
CHECKS=0
FAILED=0
cleanup() {
    if [ "$KEEP" = 1 ] || [ "$FAILED" -ne 0 ]; then
        log "work dir kept: $WORK"
    else
        rm -rf "$WORK"
    fi
}
trap 'cleanup' 0 1 2 3 15

pass_() { CHECKS=$((CHECKS + 1)); printf '  [PASS] %s\n' "$*"; }
fail_() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$*" >&2; }

log "selftest-host-a11y-table v$SELFTEST_VERSION"
log "repo: $W"
log "work: $WORK"

# ---- T1: compiler probe ---------------------------------------------------------------
# Same probe as the other host selftests: a candidate must compile AND run.
section "T1 compiler probe"
printf 'int main(void) { return 0; }\n' > "$WORK/cc_probe.c"
CC_BIN=""
for cand in "${CC:-}" cc clang gcc; do
    [ -n "$cand" ] || continue
    command -v "$cand" >/dev/null 2>&1 || continue
    if env -u LD_LIBRARY_PATH "$cand" "$WORK/cc_probe.c" -o "$WORK/cc_probe" >/dev/null 2>&1 &&
        "$WORK/cc_probe" >/dev/null 2>&1; then
        CC_BIN="$cand"
        break
    fi
    log "   note: compiler candidate $cand failed the compile+run probe; trying the next one"
done
if [ -n "$CC_BIN" ]; then
    pass_ "T1 compiler probe succeeded ($CC_BIN)"
else
    fail_ "T1 no working C compiler found (set CC=)"
fi

# ---- T2: build the shipped table + unit tests -----------------------------------------
section "T2 build (green)"
if [ -n "$CC_BIN" ]; then
    if env -u LD_LIBRARY_PATH "$CC_BIN" -O2 -Wall -I"$HOST" \
        "$TABLE" "$TEST" -o "$WORK/host-a11y-table-test" > "$WORK/build.log" 2>&1; then
        if [ -s "$WORK/build.log" ]; then
            sed 's/^/   /' "$WORK/build.log"
        fi
        pass_ "T2 host_a11y_table.c + test compile cleanly"
    else
        sed 's/^/   /' "$WORK/build.log" >&2
        fail_ "T2 the table unit test does not compile"
    fi
else
    fail_ "T2 skipped (no compiler)"
fi

# ---- T3: run the green unit cases ------------------------------------------------------
section "T3 unit cases (green)"
if [ -n "$CC_BIN" ] && [ -x "$WORK/host-a11y-table-test" ]; then
    if "$WORK/host-a11y-table-test" > "$WORK/test.log" 2>&1; then
        RC=0
    else
        RC=$?
    fi
    sed 's/^/   /' "$WORK/test.log"
    SUMMARY="$(sed -n 's/^\[a11y-table\] checks=\([0-9][0-9]*\) failures=\([0-9][0-9]*\)$/\1 \2/p' "$WORK/test.log" | tail -1)"
    CASES="${SUMMARY%% *}"
    FAILS="${SUMMARY##* }"
    if [ "$RC" -eq 0 ] && [ -n "$SUMMARY" ] && [ "$FAILS" = "0" ]; then
        pass_ "T3 unit binary exits 0 with $CASES/$CASES checks"
    else
        fail_ "T3 unit binary failed (exit $RC, summary '$SUMMARY')"
    fi
    if [ -n "$CASES" ] && [ "$CASES" -ge "$HOST_A11Y_TABLE_FLOOR" ] 2>/dev/null; then
        pass_ "T3 check count $CASES >= floor $HOST_A11Y_TABLE_FLOOR"
    else
        fail_ "T3 check count '$CASES' is below the floor $HOST_A11Y_TABLE_FLOOR"
    fi
else
    fail_ "T3 skipped (no unit binary)"
fi

# ---- T4: offline red control - the instance key ignored must fail the partition checks -
# The exact regression: OhosA11yPartitionForLocked resolves every instance to the primary
# table, so the child publish overwrites the main frame (and vice versa). The patched copy is
# built with the same test; the run must fail and print a partition [FAIL].
section "T4 red control (instance key ignored)"
if [ -n "$CC_BIN" ]; then
    # The guard is the first "if (...) { return NULL; }" in the resolver; the red variant adds an
    # unconditional fallback to the primary partition right after that guard, so every named
    # lookup (write and read) hits the main table while invalid instances still fail.
    awk '
        /^static OhosA11yPartition\* OhosA11yPartitionForLocked/ { infn = 1 }
        infn && /^    }$/ {
            print
            print "    return &g_a11y_primary;   /* RED CONTROL: instance key ignored */"
            infn = 0
            next
        }
        { print }
    ' "$TABLE" > "$WORK/host_a11y_table.red.c"
    if cmp -s "$TABLE" "$WORK/host_a11y_table.red.c"; then
        fail_ "T4 red patch did not apply (the partition guard moved?)"
    else
        if env -u LD_LIBRARY_PATH "$CC_BIN" -O2 -Wall -I"$HOST" \
            "$WORK/host_a11y_table.red.c" "$TEST" -o "$WORK/host-a11y-table-red" > "$WORK/red-build.log" 2>&1; then
            if "$WORK/host-a11y-table-red" > "$WORK/red-run.log" 2>&1; then
                RED_RC=0
            else
                RED_RC=$?
            fi
            sed 's/^/   /' "$WORK/red-run.log"
            if [ "$RED_RC" -ne 0 ] && grep -q '^\[FAIL\]' "$WORK/red-run.log"; then
                pass_ "T4 red binary fails ($RED_RC) with a partition [FAIL]"
            else
                fail_ "T4 the red control did not detect the ignored instance key (exit $RED_RC)"
            fi
        else
            sed 's/^/   /' "$WORK/red-build.log" >&2
            fail_ "T4 the red-control variant does not compile"
        fi
    fi
else
    fail_ "T4 skipped (no compiler)"
fi

# ---- T5: the same source is wired into the device build, the export contract and the consumers
section "T5 device build / export contract / consumer wiring"
if grep -q 'host_a11y_table\.c' "$HOST/CMakeLists.txt"; then
    pass_ "T5 CMakeLists.txt compiles host_a11y_table.c"
else
    fail_ "T5 CMakeLists.txt does not compile host_a11y_table.c"
fi
if grep -q 'host_a11y_table\.c' "$W/scripts/build-host.sh"; then
    pass_ "T5 build-host.sh compiles host_a11y_table.c"
else
    fail_ "T5 build-host.sh does not compile host_a11y_table.c"
fi
if grep -q '"host_a11y_table.c"' "$W/scripts/check-host-exports.py"; then
    pass_ "T5 check-host-exports.py SOURCES covers host_a11y_table.c"
else
    fail_ "T5 check-host-exports.py SOURCES misses host_a11y_table.c"
fi
if grep -q '^ohos_host_accessibility_begin_for$' "$HOST/host-exports.txt" &&
    grep -q '^ohos_host_accessibility_node_for$' "$HOST/host-exports.txt" &&
    grep -q '^ohos_host_accessibility_commit_for$' "$HOST/host-exports.txt" &&
    grep -q '^ohos_host_accessibility_provider_status_for$' "$HOST/host-exports.txt" &&
    grep -q '^ohos_host_accessibility_send_event_for$' "$HOST/host-exports.txt" &&
    grep -q '^ohos_host_accessibility_set_window_action_listener$' "$HOST/host-exports.txt"; then
    pass_ "T5 host-exports.txt lists the per-instance managed exports"
else
    fail_ "T5 host-exports.txt misses a per-instance managed export"
fi
if grep -q 'int ohos_host_accessibility_begin_for(const char\* instance, int count);' "$HOST/openharmony_host.h" &&
    grep -q 'int ohos_host_accessibility_get_for(const char\* instance, int index' "$HOST/openharmony_host.h" &&
    grep -q 'void ohos_host_accessibility_set_window_action_listener(void\* callback);' "$HOST/openharmony_host.h"; then
    pass_ "T5 openharmony_host.h declares the per-instance exports (C linkage)"
else
    fail_ "T5 openharmony_host.h misses a per-instance export declaration"
fi
if grep -q 'OH_ArkUI_AccessibilityProviderRegisterCallbackWithInstance' "$HOST/host_napi.cpp" &&
    grep -q 'AttachAccessibilityValueFor' "$HOST/host_napi.cpp" &&
    grep -q '"attachAccessibilityNodeFor"' "$HOST/host_napi.cpp" &&
    grep -q 'ohos_host_accessibility_count_for' "$HOST/host_napi.cpp" &&
    grep -q 'g_a11y_window_action_listener' "$HOST/host_napi.cpp"; then
    pass_ "T5 host_napi.cpp registers the WithInstance callbacks and routes them per instance"
else
    fail_ "T5 host_napi.cpp misses the per-instance provider wiring"
fi
SHELL_OK=1
for v in 1.0.0-preview.22 1.0.0-preview.23 1.0.0-preview.24 1.0.0-preview.28; do
    page="$W/packs/Microsoft.OpenHarmony.Sdk/$v/templates/ets/pages/SubWindow.ets"
    [ -f "$page" ] || { SHELL_OK=0; break; }
    grep -q 'ContentSlot(this.content)' "$page" || SHELL_OK=0
    grep -q "attachAccessibilityNodeFor(this.surfaceId, this.content)" "$page" || SHELL_OK=0
    grep -q 'onPageShow(): void' "$page" || SHELL_OK=0
    grep -q "host.attachAccessibilityNodeFor" "$page" || SHELL_OK=0
done
if [ "$SHELL_OK" = 1 ]; then
    pass_ "T5 all four shell packs mount the child ContentSlot and report it to the host"
else
    fail_ "T5 a shell pack misses the per-instance ContentSlot wiring"
fi
SLICE_OK=1
MAUI_SLICE="${MAUI_SLICE_DIR:-$W/../maui-ohos/src/Core/src/Platform/OpenHarmony}"
if [ -f "$MAUI_SLICE/OpenHarmonyAccessibility.cs" ]; then
    grep -q 'TryFindNode(string windowId, int id' "$MAUI_SLICE/OpenHarmonyAccessibility.cs" || SLICE_OK=0
    grep -q 'TryFindView(string windowId, int id' "$MAUI_SLICE/OpenHarmonyAccessibility.cs" || SLICE_OK=0
    grep -q 'PublishSecondary' "$MAUI_SLICE/OpenHarmonyAccessibility.cs" || SLICE_OK=0
    grep -q 'WindowProviderAttached' "$MAUI_SLICE/OpenHarmonyAccessibility.cs" || SLICE_OK=0
else
    SLICE_OK=0
fi
if [ "$SLICE_OK" = 1 ]; then
    pass_ "T5 the maui slice carries the window-parameterized frame/action path"
else
    fail_ "T5 the maui slice misses the window-parameterized frame/action path (set MAUI_SLICE_DIR)"
fi

printf '\nselftest-host-a11y-table: checks: %d, failed: %d\n' "$CHECKS" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
