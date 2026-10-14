#!/bin/sh
# selftest-host-status.sh - off-device unit tests for the host status-file helpers
# (DEVICE-ROUND-57 follow-up: src/OpenHarmonyHost/host_status.c).
#
# The helpers ship inside libopenharmonyhost.so but are pure C (POSIX file API only, no NAPI and
# no OpenHarmony headers), so this selftest compiles the shipped source with the development
# host's compiler and runs the unit cases without a device, an SDK or a network: the
# missing/unwritable directory semantics (silent, never fatal), create + append + newline, the
# control-character flattening and the 600-character cap, and the exact mode-line shape with the
# interp=/runtime-mode=/xwe= token forms the tester-run exec-mem readers match. T4 keeps the same
# file wired into the device build (CMakeLists + build-host.sh) and pins the openharmony_host.c
# call sites; T5 is the mutation red control: a scratch copy with the flattening disabled must
# make the unit binary fail.
#
# Env: CC=<compiler>          compiler probe override (default: cc, clang, gcc)
#      SELFTEST_TMPDIR=<dir>  work dir base (default: the approved opencode dir, else TMPDIR,
#                             else /tmp)
#      SELFTEST_KEEP=1        keep the work dir even when all checks pass
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="1 (2026-10-15)"
# The unit binary's check count must stay at or above this floor; declared next to the suite
# contract so deleting/reducing cases fails the gate instead of silently shrinking coverage.
HOST_STATUS_FLOOR=30

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

W="$(cd "$(dirname "$0")/.." && pwd)"
HOST="$W/src/OpenHarmonyHost"
STATUS="$HOST/host_status.c"
HEADER="$HOST/host_status.h"
TEST="$HOST/host_status_test.c"
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

for f in "$STATUS" "$HEADER" "$TEST"; do
    [ -f "$f" ] || { printf 'FATAL: missing %s\n' "$f" >&2; exit 1; }
done

WORK="$(mktemp -d "$WORK_BASE/selftest-host-status.XXXXXX")" || {
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

log "selftest-host-status v$SELFTEST_VERSION"
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
for candidate in ${CC:-} cc clang gcc; do
    [ -n "$candidate" ] || continue
    command -v "$candidate" >/dev/null 2>&1 || continue
    if env -u LD_LIBRARY_PATH "$candidate" -O2 -o "$WORK/cc_probe" "$WORK/cc_probe.c" > "$WORK/cc_probe.log" 2>&1 &&
        "$WORK/cc_probe" >> "$WORK/cc_probe.log" 2>&1; then
        CC_BIN="$candidate"
        break
    fi
done
if [ -n "$CC_BIN" ]; then
    pass_ "T1 compiler probe succeeded ($CC_BIN)"
else
    fail_ "T1 no working C compiler found (set CC=)"
fi

# ---- T2: build the shipped helpers + unit tests -----------------------------------------
section "T2 build"
if [ -n "$CC_BIN" ]; then
    if env -u LD_LIBRARY_PATH "$CC_BIN" -O2 -Wall -I"$HOST" "$STATUS" "$TEST" \
        -o "$WORK/host-status-test" > "$WORK/build.log" 2>&1; then
        pass_ "T2 host_status.c + test compile cleanly"
    else
        sed 's/^/   /' "$WORK/build.log" >&2
        fail_ "T2 the status helper unit test does not compile"
    fi
else
    fail_ "T2 skipped (no compiler)"
fi

# ---- T3: run the unit cases ---------------------------------------------------------------
section "T3 unit cases"
if [ -n "$CC_BIN" ] && [ -x "$WORK/host-status-test" ]; then
    if "$WORK/host-status-test" > "$WORK/test.log" 2>&1; then
        RC=0
    else
        RC=$?
    fi
    sed 's/^/   /' "$WORK/test.log"
    SUMMARY="$(sed -n 's/^host-status: \([0-9][0-9]*\) checks, \([0-9][0-9]*\) failure(s)$/\1 \2/p' "$WORK/test.log" | tail -1)"
    CASES="${SUMMARY%% *}"
    FAILS="${SUMMARY##* }"
    if [ "$RC" -eq 0 ] && [ -n "$SUMMARY" ] && [ "$FAILS" = "0" ]; then
        pass_ "T3 unit binary exits 0 with $CASES/$CASES checks"
    else
        fail_ "T3 unit binary failed (exit $RC, summary '$SUMMARY')"
    fi
    if [ -n "$CASES" ] && [ "$CASES" -ge "$HOST_STATUS_FLOOR" ] 2>/dev/null; then
        pass_ "T3 check count $CASES >= floor $HOST_STATUS_FLOOR"
    else
        fail_ "T3 check count '$CASES' is below the floor $HOST_STATUS_FLOOR"
    fi
else
    fail_ "T3 skipped (no unit binary)"
fi

# ---- T4: the same sources are wired into the device host build ----------------------------
section "T4 device build wiring"
if grep -q 'host_status\.c' "$HOST/CMakeLists.txt"; then
    pass_ "T4 CMakeLists.txt compiles host_status.c"
else
    fail_ "T4 CMakeLists.txt does not compile host_status.c"
fi
if grep -q 'host_status\.c' "$W/scripts/build-host.sh"; then
    pass_ "T4 build-host.sh compiles host_status.c"
else
    fail_ "T4 build-host.sh does not compile host_status.c"
fi
# The call sites: the mode decision formats and appends through the shipped helpers, and the
# 600-character buffer uses the shared cap.
if grep -q 'OhosHostStatusFormatModeLine' "$HOST/openharmony_host.c" &&
    grep -q 'OhosHostStatusAppendLine' "$HOST/openharmony_host.c" &&
    grep -q 'OHOS_HOST_STATUS_LINE_MAX' "$HOST/openharmony_host.c"; then
    pass_ "T4 openharmony_host.c formats and appends the mode line via host_status.c"
else
    fail_ "T4 openharmony_host.c does not call the status helpers"
fi
# The interp=3 switches are decided once (pure_interp) and re-stated in the appended line.
if grep -q 'int pure_interp = have_interp' "$HOST/openharmony_host.c" &&
    grep -q 'pure_interp ? "off" : "default"' "$HOST/openharmony_host.c"; then
    pass_ "T4 the interp=3 r2r/wbcopy switches are decided once and mirrored"
else
    fail_ "T4 the pure_interp decision is missing from openharmony_host.c"
fi
# The old inline flatten/cap copy is gone: exactly one implementation ships.
if ! grep -q 'OHOS_STATUS_LINE_MAX' "$HOST/openharmony_host.c"; then
    pass_ "T4 the inline flatten/cap copy was replaced by host_status.c"
else
    fail_ "T4 openharmony_host.c still carries the inline status-line copy"
fi
# Packaging doc: the mode line is documented where the other status lines are.
if grep -q 'OHOS_HOST mode' "$W/docs/openharmony-hap-packaging.md"; then
    pass_ "T4 docs/openharmony-hap-packaging.md documents the mode line"
else
    fail_ "T4 the packaging doc does not document the mode line"
fi

# ---- T5: mutation red control --------------------------------------------------------------
# Disable the control-character flattening in a scratch copy; the unit binary must then fail on
# the flattening case instead of silently writing raw control characters.
section "T5 red control (flattening disabled)"
if [ -n "$CC_BIN" ]; then
    sed 's/flat\[i\] = (c < 0x20 || c == 0x7f) ? '\'' '\'' : (char)c;/flat[i] = (char)c;/' \
        "$STATUS" > "$WORK/host_status_red.c"
    if ! grep -q 'flat\[i\] = (char)c;' "$WORK/host_status_red.c"; then
        fail_ "T5 mutation anchor not found in host_status.c (update the red control)"
    else
        if env -u LD_LIBRARY_PATH "$CC_BIN" -O2 -Wall -I"$HOST" \
            "$WORK/host_status_red.c" "$TEST" -o "$WORK/host-status-red" > "$WORK/red-build.log" 2>&1; then
            "$WORK/host-status-red" > "$WORK/red.log" 2>&1 && RED_RC=0 || RED_RC=$?
            if [ "$RED_RC" -ne 0 ] && grep -q '\[FAIL\] append: tab/CR/LF/C0/DEL are flattened to spaces' "$WORK/red.log"; then
                pass_ "T5 the mutated helper fails the flattening case (exit $RED_RC)"
            else
                sed 's/^/   /' "$WORK/red.log" >&2
                fail_ "T5 the mutated helper did not fail the expected case (exit $RED_RC)"
            fi
        else
            sed 's/^/   /' "$WORK/red-build.log" >&2
            fail_ "T5 the mutated helper does not compile"
        fi
    fi
else
    fail_ "T5 skipped (no compiler)"
fi

printf '\nselftest-host-status: checks: %d, failed: %d\n' "$CHECKS" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
