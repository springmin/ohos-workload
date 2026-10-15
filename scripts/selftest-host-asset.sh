#!/bin/sh
# selftest-host-asset.sh - off-device unit tests for the host's Asset Store NDK wrapper
# (SECURE-STORAGE-ASSET: src/OpenHarmonyHost/host_asset.c).
#
# The wrapper ships inside libopenharmonyhost.so but is pure C (no NAPI and no OpenHarmony
# headers; the OH_Asset_* entry points arrive as an injected table), so this selftest compiles
# the shipped source with the development host's compiler and runs the unit cases without a
# device, an SDK or a network: the six access-policy attributes of a put, the service rejection
# codes with their raw status, the local 256/1024-byte bounds check (reject before any NDK
# call), whole-or-nothing gets with exactly one FreeResultSet, NOT_FOUND/absent shapes without
# a free, the incomplete-table UNAVAILABLE paths and the base64 bridge protocol (put/get/remove
# round trip, malformed base64, unknown op). T4 keeps the same file wired into the device build
# (CMakeLists + build-host.sh) and pins the optional-library resolution, the request dispatch,
# the [undefined] denylist entry and the three managed EntryPoints. T5 is the mutation red
# control: a scratch copy with the too-small-buffer guard disabled must make the unit binary
# fail.
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
HOST_ASSET_FLOOR=45

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

W="$(cd "$(dirname "$0")/.." && pwd)"
HOST="$W/src/OpenHarmonyHost"
ASSET="$HOST/host_asset.c"
HEADER="$HOST/host_asset.h"
TEST="$HOST/host_asset_test.c"
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

for f in "$ASSET" "$HEADER" "$TEST"; do
    [ -f "$f" ] || { printf 'FATAL: missing %s\n' "$f" >&2; exit 1; }
done

WORK="$(mktemp -d "$WORK_BASE/selftest-host-asset.XXXXXX")" || {
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

log "selftest-host-asset v$SELFTEST_VERSION"
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

# ---- T2: build the shipped wrapper + unit tests ----------------------------------------
section "T2 build"
if [ -n "$CC_BIN" ]; then
    if env -u LD_LIBRARY_PATH "$CC_BIN" -O2 -Wall -Wextra -I"$HOST" \
        "$ASSET" "$TEST" -o "$WORK/host-asset-test" > "$WORK/build.log" 2>&1; then
        if [ -s "$WORK/build.log" ]; then
            sed 's/^/   /' "$WORK/build.log"
        fi
        pass_ "T2 host_asset.c + test compile cleanly"
    else
        sed 's/^/   /' "$WORK/build.log" >&2
        fail_ "T2 the asset wrapper unit test does not compile"
    fi
else
    fail_ "T2 skipped (no compiler)"
fi

# ---- T3: run the unit cases ---------------------------------------------------------------
section "T3 unit cases"
if [ -n "$CC_BIN" ] && [ -x "$WORK/host-asset-test" ]; then
    if "$WORK/host-asset-test" > "$WORK/test.log" 2>&1; then
        RC=0
    else
        RC=$?
    fi
    sed 's/^/   /' "$WORK/test.log"
    SUMMARY="$(sed -n 's/^host-asset: \([0-9][0-9]*\) checks, \([0-9][0-9]*\) failure(s)$/\1 \2/p' "$WORK/test.log" | tail -1)"
    CASES="${SUMMARY%% *}"
    FAILS="${SUMMARY##* }"
    if [ "$RC" -eq 0 ] && [ -n "$SUMMARY" ] && [ "$FAILS" = "0" ]; then
        pass_ "T3 unit binary exits 0 with $CASES/$CASES checks"
    else
        fail_ "T3 unit binary failed (exit $RC, summary '$SUMMARY')"
    fi
    if [ -n "$CASES" ] && [ "$CASES" -ge "$HOST_ASSET_FLOOR" ] 2>/dev/null; then
        pass_ "T3 check count $CASES >= floor $HOST_ASSET_FLOOR"
    else
        fail_ "T3 check count '$CASES' is below the floor $HOST_ASSET_FLOOR"
    fi
else
    fail_ "T3 skipped (no unit binary)"
fi

# ---- T4: the same sources are wired into the device host build ----------------------------
section "T4 device build wiring"
if grep -q 'host_asset\.c' "$HOST/CMakeLists.txt"; then
    pass_ "T4 CMakeLists.txt compiles host_asset.c"
else
    fail_ "T4 CMakeLists.txt does not compile host_asset.c"
fi
if grep -q 'host_asset\.c' "$W/scripts/build-host.sh"; then
    pass_ "T4 build-host.sh compiles host_asset.c"
else
    fail_ "T4 build-host.sh does not compile host_asset.c"
fi
# The request dispatch: the host answers put/get/remove from the NDK wrapper through the
# registered managed result callback.
if grep -q 'ohos_host_asset_execute' "$HOST/openharmony_host.c" &&
    grep -q 'ohos_host_asset_register_result' "$HOST/openharmony_host.c"; then
    pass_ "T4 openharmony_host.c dispatches the asset ops to the NDK wrapper"
else
    fail_ "T4 openharmony_host.c does not dispatch the asset ops"
fi
# The resolution: host_optional.c resolves the five entry points from libasset_ndk.z.so and
# logs the asset group when they are absent.
if grep -q '"OH_Asset_Add"' "$HOST/host_optional.c" &&
    grep -q '"OH_Asset_Query"' "$HOST/host_optional.c" &&
    grep -q '"libasset_ndk.z.so"' "$HOST/host_optional.c" &&
    grep -q '"asset"' "$HOST/host_optional.c"; then
    pass_ "T4 host_optional.c resolves the Asset Store group with its missing-lib label"
else
    fail_ "T4 host_optional.c does not resolve the Asset Store group"
fi
# The link policy: the NDK symbols must never reappear as direct references.
if grep -q '^OH_Asset_' "$HOST/host-deps.conf"; then
    pass_ "T4 host-deps.conf denies direct OH_Asset_ references"
else
    fail_ "T4 host-deps.conf does not deny the Asset Store namespace"
fi
# The managed export contract: the three EntryPoints the slice resolves must be declared (the
# header gives them C linkage) and listed for the built-library gate.
if grep -q 'ohos_host_asset_available' "$HOST/openharmony_host.h" &&
    grep -q 'ohos_host_asset_register_result' "$HOST/openharmony_host.h" &&
    grep -q 'ohos_host_asset_request' "$HOST/openharmony_host.h"; then
    pass_ "T4 openharmony_host.h declares the three asset exports"
else
    fail_ "T4 openharmony_host.h does not declare the asset exports"
fi
if grep -qx 'ohos_host_asset_available' "$HOST/host-exports.txt" &&
    grep -qx 'ohos_host_asset_register_result' "$HOST/host-exports.txt" &&
    grep -qx 'ohos_host_asset_request' "$HOST/host-exports.txt"; then
    pass_ "T4 host-exports.txt lists the three asset exports"
else
    fail_ "T4 host-exports.txt does not list the asset exports"
fi

# ---- T5: mutation red control --------------------------------------------------------------
# Disable the too-small-buffer guard in a scratch copy; the unit binary must then fail on the
# truncation case instead of silently answering the first bytes of the secret.
section "T5 red control (whole-copy guard disabled)"
if [ -n "$CC_BIN" ]; then
    sed 's/} else if (secret->value.blob.size > out_capacity) {/} else if (0) {/' \
        "$ASSET" > "$WORK/host_asset_red.c"
    if ! grep -q '} else if (0) {' "$WORK/host_asset_red.c"; then
        fail_ "T5 mutation anchor not found in host_asset.c (update the red control)"
    else
        if env -u LD_LIBRARY_PATH "$CC_BIN" -O2 -Wall -I"$HOST" \
            "$WORK/host_asset_red.c" "$TEST" -o "$WORK/host-asset-red" > "$WORK/red-build.log" 2>&1; then
            "$WORK/host-asset-red" > "$WORK/red.log" 2>&1 && RED_RC=0 || RED_RC=$?
            if [ "$RED_RC" -ne 0 ] && grep -q '\[FAIL\] get: a too-small buffer answers FAILED and never truncates' "$WORK/red.log"; then
                pass_ "T5 the mutated wrapper fails the truncation case (exit $RED_RC)"
            else
                sed 's/^/   /' "$WORK/red.log" >&2
                fail_ "T5 the mutated wrapper did not fail the expected case (exit $RED_RC)"
            fi
        else
            sed 's/^/   /' "$WORK/red-build.log" >&2
            fail_ "T5 the mutated wrapper does not compile"
        fi
    fi
else
    fail_ "T5 skipped (no compiler)"
fi

printf '\nselftest-host-asset: checks: %d, failed: %d\n' "$CHECKS" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
