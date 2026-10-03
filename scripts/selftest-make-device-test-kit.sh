#!/bin/sh
# selftest-make-device-test-kit.sh - local selftest for the make-device-test-kit.sh runtime-mode
# switch (AOT-DEFAULT, 2026-10-03). No publish, no SDK, no device: every case is --dry-run,
# which prints the four publish commands and exits before any environment check.
#
#   T1 usage      sh -n passes; --help lists --runtime-mode/aot/jit/interp; an unknown mode and
#                 the interp mode exit 2 (interp points at the independent pack + make-mode-kit)
#   T2 aot        the default is aot: four publish commands, every one carries the NativeAOT
#                 recipe (PublishAot/PublishAotUsingRuntimePack/NativeLib=Shared/
#                 OpenHarmonyRuntimeMode=aot/InvariantGlobalization) plus the mandatory
#                 OpenHarmonyUIPage; the 20.0 band uses the TargetFrameworks override and the
#                 permissions variant carries OpenHarmonyExtraPermissions
#   T3 jit        --runtime-mode jit keeps the JIT publish (-p:OpenHarmonyRuntimeMode=jit, no
#                 PublishAot), appends -jit to the default kit dir/out, and --kit-dir/--out
#                 win verbatim
#   T4 env        DEVICE_TEST_KIT_RUNTIME_MODE=jit selects jit when no flag is given
#   T5 dry-only   --dry-run touches nothing: no stage dir / kit dir appears next to --kit-dir
#
# Env: SELFTEST_TMPDIR=<dir>  work dir base (default: the approved opencode tmp dir, else TMPDIR)
#      SELFTEST_KEEP=1       keep the work dir even when all checks pass
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="1 (2026-10-03)"

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

W="$(cd "$(dirname "$0")/.." && pwd)"
MK="$W/scripts/make-device-test-kit.sh"
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

[ -f "$MK" ] || { printf 'FATAL: make-device-test-kit.sh not found: %s\n' "$MK" >&2; exit 1; }
for _t in sh grep mktemp; do
    command -v "$_t" >/dev/null 2>&1 || { printf 'FATAL: required command not found: %s\n' "$_t" >&2; exit 1; }
done

WORK="$(mktemp -d "$WORK_BASE/selftest-make-device-test-kit.XXXXXX")" || {
    printf 'FATAL: cannot create a work dir under %s\n' "$WORK_BASE" >&2
    exit 1
}
CHECKS=0
FAILED=0

pass_() { CHECKS=$((CHECKS + 1)); printf '  [PASS] %s\n' "$*"; }
fail_() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$*" >&2; }
assert_rc() { # <expected> <actual> <label>
    if [ "$2" -eq "$1" ]; then pass_ "$3 (exit $2)"; else fail_ "$3 (expected exit $1, got $2)"; fi
}
assert_contains() { # <label> <needle> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then pass_ "$1"; else fail_ "$1 (missing '$2' in $3)"; fi
}
assert_not_contains() { # <label> <needle> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then fail_ "$1 (unexpected '$2' in $3)"; else pass_ "$1"; fi
}
count_contains() { # <needle> <file>
    grep -cF -- "$1" "$2" 2>/dev/null || true
}

log "selftest-make-device-test-kit v$SELFTEST_VERSION"
log "work: $WORK"

run_kit() { # <logfile> [args...]
    _log="$1"
    shift
    sh "$MK" "$@" > "$_log" 2>&1
}

# ---- T1: usage / mode validation -------------------------------------------------------
section "T1 usage and mode validation"
run_kit "$WORK/help.log" --help
assert_rc 0 $? "T1 --help exits 0"
assert_contains "T1 help lists --runtime-mode" "--runtime-mode aot|jit|interp" "$WORK/help.log"
assert_contains "T1 help documents the AOT default" "default aot" "$WORK/help.log"
assert_contains "T1 help documents the interp policy" "independent pack" "$WORK/help.log"

run_kit "$WORK/badmode.log" --runtime-mode nope
assert_rc 2 $? "T1 unknown --runtime-mode exits 2"
assert_contains "T1 names the accepted modes" "use aot, jit or interp" "$WORK/badmode.log"

run_kit "$WORK/interp.log" --runtime-mode interp
assert_rc 2 $? "T1 --runtime-mode interp exits 2 (independent pack)"
assert_contains "T1 interp points at make-mode-kit" "make-mode-kit.sh" "$WORK/interp.log"
assert_contains "T1 interp names the pack asset" "ohos-interpreter-pack" "$WORK/interp.log"

# ---- T2: AOT is the default ------------------------------------------------------------
section "T2 default (aot) dry-run"
KD="$WORK/kit-aot"
run_kit "$WORK/aot.log" --dry-run --kit-dir "$KD"
assert_rc 0 $? "T2 aot dry-run exits 0"
assert_contains "T2 announces aot" "runtime-mode=aot" "$WORK/aot.log"
for prop in \
    "-p:PublishAot=true" \
    "-p:PublishAotUsingRuntimePack=true" \
    "-p:NativeLib=Shared" \
    "-p:OpenHarmonyRuntimeMode=aot" \
    "-p:InvariantGlobalization=true" \
    "-p:OpenHarmonyUIPage=pages/Index" \
    "-p:OpenHarmonyHapPackage=true"
do
    _n="$(count_contains "$prop" "$WORK/aot.log")"
    if [ "$_n" = "4" ]; then
        pass_ "T2 all 4 publishes carry $prop"
    else
        fail_ "T2 $prop appears ${_n:-0} times, expected 4"
    fi
done
assert_not_contains "T2 no JIT-mode property in the AOT recipe" "OpenHarmonyRuntimeMode=jit" "$WORK/aot.log"
assert_contains "T2 20.0 band keeps the band override" "-p:TargetFrameworks=net11.0-openharmony20.0" "$WORK/aot.log"
assert_contains "T2 permissions variant carries the permission list" "OpenHarmonyExtraPermissions=" "$WORK/aot.log"
assert_contains "T2 command shape is dotnet publish" "+ dotnet publish" "$WORK/aot.log"
assert_contains "T2 dry-run announces no real publish" "nothing published, nothing assembled" "$WORK/aot.log"
[ ! -d "$KD" ] && pass_ "T2 dry-run created no kit dir" || fail_ "T2 dry-run created $KD"

# ---- T3: the JIT variant stays available ------------------------------------------------
section "T3 jit dry-run"
run_kit "$WORK/jit.log" --dry-run --runtime-mode jit
assert_rc 0 $? "T3 jit dry-run exits 0"
assert_contains "T3 announces jit" "runtime-mode=jit" "$WORK/jit.log"
assert_contains "T3 default kit dir gets the -jit suffix" "kit-dir=$WORK_BASE/device-test-kit-jit" "$WORK/jit.log"
assert_contains "T3 out gets the -jit suffix" "out=$WORK_BASE/device-test-kit-jit.tar.gz" "$WORK/jit.log"
if [ "$(count_contains "-p:OpenHarmonyRuntimeMode=jit" "$WORK/jit.log")" = "4" ]; then
    pass_ "T3 all 4 publishes carry OpenHarmonyRuntimeMode=jit"
else
    fail_ "T3 OpenHarmonyRuntimeMode=jit not on all 4 publishes"
fi
assert_not_contains "T3 JIT recipe carries no PublishAot" "PublishAot=true" "$WORK/jit.log"
run_kit "$WORK/jit-explicit.log" --dry-run --runtime-mode jit --kit-dir "$WORK/custom" --out "$WORK/custom.tar.gz"
assert_contains "T3 explicit --kit-dir wins" "kit-dir=$WORK/custom" "$WORK/jit-explicit.log"
assert_contains "T3 explicit --out wins" "out=$WORK/custom.tar.gz" "$WORK/jit-explicit.log"

# ---- T4: env default --------------------------------------------------------------------
section "T4 DEVICE_TEST_KIT_RUNTIME_MODE"
DEVICE_TEST_KIT_RUNTIME_MODE=jit sh "$MK" --dry-run > "$WORK/env.log" 2>&1
assert_rc 0 $? "T4 env-selected dry-run exits 0"
assert_contains "T4 env selects jit" "runtime-mode=jit" "$WORK/env.log"
assert_contains "T4 env keeps the -jit suffix" "device-test-kit-jit.tar.gz" "$WORK/env.log"

# ---- T5: dry-run leaves the tree alone ---------------------------------------------------
section "T5 dry-run side effects"
[ ! -d "$WORK/device-test-kit-jit" ] && pass_ "T5 no default kit dir created" || fail_ "T5 default kit dir was created"
STAGES="$(find "$WORK" -maxdepth 1 -name '*.stage.*' -print 2>/dev/null | wc -l | tr -d ' ')"
if [ "$STAGES" = "0" ]; then pass_ "T5 no stage dir left behind"; else fail_ "T5 $STAGES stage dir(s) left behind"; fi

# ---- summary -----------------------------------------------------------------------------
section "summary"
log "checks: $CHECKS, failed: $FAILED"
if [ "$FAILED" -gt 0 ]; then
    log "SELFTEST FAILED - work dir kept: $WORK"
    exit 1
fi
log "SELFTEST OK - the runtime-mode switch (aot default / jit variant / interp redirect) prints the documented publish shapes"
if [ "$KEEP" = "1" ]; then
    log "work dir kept (SELFTEST_KEEP=1): $WORK"
else
    rm -rf "$WORK"
fi
exit 0
