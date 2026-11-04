#!/bin/sh
# selftest-host-trust.sh - off-device tests for the host OpenSSL trust policy.
#
# host_trust.c is pure POSIX C; no NAPI, OpenHarmony headers, SDK or device. The cases pin the
# three modes (system/app/both), the app-only no-system fallback, missing-CA failure semantics,
# status lines and the device-build wiring. The payload plumbing (trust.json + trust-ca.pem)
# is exercised by selftest-hap-targets.sh.
#
# Env: CC=<compiler>          compiler override (default: cc, clang, gcc)
#      SELFTEST_TMPDIR=<dir>  work dir base
#      SELFTEST_KEEP=1        keep the work dir
# Exit: 0 = all checks passed; 1 = at least one check failed.
set -u

SELFTEST_VERSION="1 (2026-11-04)"
HOST_TRUST_FLOOR=20

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

W="$(cd "$(dirname "$0")/.." && pwd)"
HOST="$W/src/OpenHarmonyHost"
TRUST="$HOST/host_trust.c"
HEADER="$HOST/host_trust.h"
TEST="$HOST/host_trust_test.c"
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

for f in "$TRUST" "$HEADER" "$TEST"; do
    [ -f "$f" ] || { printf 'FATAL: missing %s\n' "$f" >&2; exit 1; }
done

WORK="$(mktemp -d "$WORK_BASE/selftest-host-trust.XXXXXX")" || {
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

log "selftest-host-trust v$SELFTEST_VERSION"
log "repo: $W"
log "work: $WORK"

# ---- T1: compiler probe -----------------------------------------------------------------
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

# ---- T2: compile the shipped helper + unit tests ------------------------------------------
section "T2 build"
if [ -n "$CC_BIN" ]; then
    if env -u LD_LIBRARY_PATH "$CC_BIN" -O2 -Wall -Wextra -I"$HOST" "$TRUST" "$TEST" \
        -o "$WORK/host-trust-test" > "$WORK/build.log" 2>&1; then
        pass_ "T2 host_trust.c + test compile cleanly"
    else
        sed 's/^/   /' "$WORK/build.log" >&2
        fail_ "T2 the trust helper unit test does not compile"
    fi
else
    fail_ "T2 skipped (no compiler)"
fi

# ---- T3: unit cases -----------------------------------------------------------------------
section "T3 unit cases"
if [ -n "$CC_BIN" ] && [ -x "$WORK/host-trust-test" ]; then
    if TMPDIR="$WORK" "$WORK/host-trust-test" > "$WORK/test.log" 2>&1; then
        RC=0
    else
        RC=$?
    fi
    sed 's/^/   /' "$WORK/test.log"
    SUMMARY="$(sed -n 's/^host-trust: \([0-9][0-9]*\) checks, \([0-9][0-9]*\) failure(s)$/\1 \2/p' "$WORK/test.log" | tail -1)"
    CASES="${SUMMARY%% *}"
    FAILS="${SUMMARY##* }"
    if [ "$RC" -eq 0 ] && [ -n "$SUMMARY" ] && [ "$FAILS" = "0" ]; then
        pass_ "T3 unit binary exits 0 with $CASES/$CASES checks"
    else
        fail_ "T3 unit binary failed (exit $RC, summary '$SUMMARY')"
    fi
    if [ -n "$CASES" ] && [ "$CASES" -ge "$HOST_TRUST_FLOOR" ] 2>/dev/null; then
        pass_ "T3 check count $CASES >= floor $HOST_TRUST_FLOOR"
    else
        fail_ "T3 check count '$CASES' is below the floor $HOST_TRUST_FLOOR"
    fi
else
    fail_ "T3 skipped (no unit binary)"
fi

# ---- T4: device-build and payload wiring --------------------------------------------------
section "T4 device build wiring"
if grep -q 'host_trust\.c' "$HOST/CMakeLists.txt"; then
    pass_ "T4 CMakeLists.txt compiles host_trust.c"
else
    fail_ "T4 CMakeLists.txt does not compile host_trust.c"
fi
if grep -q 'host_trust\.c' "$W/scripts/build-host.sh"; then
    pass_ "T4 build-host.sh compiles host_trust.c"
else
    fail_ "T4 build-host.sh does not compile host_trust.c"
fi
if grep -q 'OhosHostApplyTrustPolicyFromPayload' "$HOST/openharmony_host.c" &&
    grep -q 'trust\.json' "$HOST/openharmony_host.c"; then
    pass_ "T4 openharmony_host.c reads trust.json and applies the policy"
else
    fail_ "T4 openharmony_host.c does not apply trust.json"
fi
if grep -q 'OpenHarmonyTrustMode' "$W/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.24/targets/OpenHarmony.Hap.targets"; then
    pass_ "T4 the HAP target exposes OpenHarmonyTrustMode"
else
    fail_ "T4 the HAP target has no trust-mode properties"
fi
if grep -q 'trust-ca\.pem' "$W/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.24/targets/OpenHarmony.Hap.targets"; then
    pass_ "T4 the HAP target stages trust-ca.pem"
else
    fail_ "T4 the HAP target does not stage trust-ca.pem"
fi

printf '\nselftest-host-trust: checks: %d, failed: %d\n' "$CHECKS" "$FAILED"
[ "$FAILED" -eq 0 ]
