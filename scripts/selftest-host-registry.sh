#!/bin/sh
# selftest-host-registry.sh - off-device unit tests for the host's per-window XComponent surface
# registry (MULTIWINDOW-L M1: src/OpenHarmonyHost/host_window_registry.c).
#
# The registry ships inside libopenharmonyhost.so but is pure C (no NAPI or OpenHarmony
# headers), so this selftest compiles the shipped source with the development host's compiler and
# runs the unit cases without a device, an SDK or a network. Cases: dual-surface register/
# unregister, duplicate ids/components, capacity, surface lifecycle and out-of-order events, and
# per-owner teardown, plus the source-wiring pins that keep the same file in the device build.
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
HOST_REGISTRY_FLOOR=40

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

W="$(cd "$(dirname "$0")/.." && pwd)"
HOST="$W/src/OpenHarmonyHost"
REGISTRY="$HOST/host_window_registry.c"
TEST="$HOST/host_window_registry_test.c"
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

for f in "$REGISTRY" "$TEST"; do
    [ -f "$f" ] || { printf 'FATAL: missing %s\n' "$f" >&2; exit 1; }
done

WORK="$(mktemp -d "$WORK_BASE/selftest-host-registry.XXXXXX")" || {
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

log "selftest-host-registry v$SELFTEST_VERSION"
log "repo: $W"
log "work: $WORK"

# ---- T1: compiler probe ---------------------------------------------------------------
# The development host's clang (and the SDK's lld) fail to start when LD_LIBRARY_PATH leaks a
# foreign libxml2 into the process; clear it for every probe/build below. A candidate must also
# produce a *runnable* binary: the llvm@21 toolchain that CC may point at emits ELF files this
# host refuses to exec (EACCES), so compile-only probing is not enough.
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

# ---- T2: build the shipped registry + unit tests ----------------------------------------
section "T2 build"
if [ -n "$CC_BIN" ]; then
    if env -u LD_LIBRARY_PATH "$CC_BIN" -O2 -Wall -I"$HOST" \
        "$REGISTRY" "$TEST" -o "$WORK/host-window-registry-test" > "$WORK/build.log" 2>&1; then
        if [ -s "$WORK/build.log" ]; then
            sed 's/^/   /' "$WORK/build.log"
        fi
        pass_ "T2 host_window_registry.c + test compile cleanly"
    else
        sed 's/^/   /' "$WORK/build.log" >&2
        fail_ "T2 the registry unit test does not compile"
    fi
else
    fail_ "T2 skipped (no compiler)"
fi

# ---- T3: run the unit cases ---------------------------------------------------------------
section "T3 unit cases"
if [ -n "$CC_BIN" ] && [ -x "$WORK/host-window-registry-test" ]; then
    if "$WORK/host-window-registry-test" > "$WORK/test.log" 2>&1; then
        RC=0
    else
        RC=$?
    fi
    sed 's/^/   /' "$WORK/test.log"
    SUMMARY="$(sed -n 's/^host-window-registry: \([0-9][0-9]*\) checks, \([0-9][0-9]*\) failure(s)$/\1 \2/p' "$WORK/test.log" | tail -1)"
    CASES="${SUMMARY%% *}"
    FAILS="${SUMMARY##* }"
    if [ "$RC" -eq 0 ] && [ -n "$SUMMARY" ] && [ "$FAILS" = "0" ]; then
        pass_ "T3 unit binary exits 0 with $CASES/$CASES checks"
    else
        fail_ "T3 unit binary failed (exit $RC, summary '$SUMMARY')"
    fi
    if [ -n "$CASES" ] && [ "$CASES" -ge "$HOST_REGISTRY_FLOOR" ] 2>/dev/null; then
        pass_ "T3 check count $CASES >= floor $HOST_REGISTRY_FLOOR"
    else
        fail_ "T3 check count '$CASES' is below the floor $HOST_REGISTRY_FLOOR"
    fi
else
    fail_ "T3 skipped (no unit binary)"
fi

# ---- T4: the same sources are wired into the device host build -----------------------------
section "T4 device build wiring"
if grep -q 'host_window_registry\.c' "$HOST/CMakeLists.txt"; then
    pass_ "T4 CMakeLists.txt compiles host_window_registry.c"
else
    fail_ "T4 CMakeLists.txt does not compile host_window_registry.c"
fi
if grep -q 'host_window_registry\.c' "$W/scripts/build-host.sh"; then
    pass_ "T4 build-host.sh compiles host_window_registry.c"
else
    fail_ "T4 build-host.sh does not compile host_window_registry.c"
fi

printf '\nselftest-host-registry: checks: %d, failed: %d\n' "$CHECKS" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
