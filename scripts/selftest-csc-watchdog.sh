#!/bin/sh
# selftest-csc-watchdog.sh - selftest for scripts/run-with-csc-watchdog.sh (the csc livelock
# watchdog wrapper used by preflight.sh).
#
#   T0 usage      sh -n; --help rc=0 and documents the DOTNET_PROCESSOR_COUNT=1 respawn;
#                 no command -> rc=2
#   T1 disable    CSC_WATCHDOG=0 execs the command directly (rc preserved, stub never called)
#   T2 stub-kill  a fixture watchdog reports one stall kill -> the wrapper reruns once with
#                 DOTNET_PROCESSOR_COUNT=1; the command succeeds, both attempt logs exist
#   T3 stub-twice a fixture watchdog kills both attempts -> fail-closed, exactly 2 attempts
#   T4 no-kill    a plain failure of the fixture command is not retried
#   T5 no-rescue  without a resolvable watchdog script the wrapper warns and execs directly
#   T6 real-kill  (when the runtime-ohos watchdog exists) a real spun `csc` is killed, the
#                 DOTNET_PROCESSOR_COUNT=1 rerun succeeds, evidence lands in attempt1/
#   T7 real-twice (when the runtime-ohos watchdog exists) a second real stall fails closed
#
# The T2/T3/T4/T5 fixtures are scripted stand-ins; T6/T7 exercise the real watchdog with a
# fixture build that spawns a spun process whose comm is `csc`.
#
# Env: SELFTEST_TMPDIR=<dir>  work dir base (default: the approved opencode tmp dir)
#      SELFTEST_KEEP=1       keep the work dir even when all checks pass
#      CSC_WATCHDOG_REAL=<path>  real watchdog to exercise (default: sibling runtime-ohos)
# Exit: 0 = all checks passed (real-watchdog scenarios may be SKIPped when it is absent);
#       1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="1 (2026-10-10; 34 checks)"

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

W="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$W/scripts/run-with-csc-watchdog.sh"
REAL="${CSC_WATCHDOG_REAL:-$W/../runtime-ohos/scripts/ohos-csc-watchdog.sh}"
BASE="${SELFTEST_TMPDIR:-/data/storage/el2/base/tmp/opencode}"
KEEP="${SELFTEST_KEEP:-0}"
T="$BASE/selftest-csc-watchdog.$$"
mkdir -p "$T" || { echo "cannot create $T" >&2; exit 1; }

CHECKS=0
FAILED=0
pass_()  { CHECKS=$((CHECKS + 1)); printf '  [PASS] %s\n' "$*"; }
fail_()  { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$*" >&2; }
skip_()  { printf '  [SKIP] %s\n' "$*"; }
check_rc() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then pass_ "$1 (rc=$2)"; else fail_ "$1 (rc=$2, want $3)"; fi
}
check_nonzero() { # <label> <got>
    if [ "$2" != 0 ]; then pass_ "$1 (rc=$2)"; else fail_ "$1 (rc=0, want non-zero)"; fi
}
assert_contains() { # <label> <needle> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then pass_ "$1"; else fail_ "$1 (missing: $2)"; fi
}
assert_file() { # <label> <path>
    if [ -f "$2" ]; then pass_ "$1"; else fail_ "$1 (no file: $2)"; fi
}
assert_count() { # <label> <path> <want>
    if [ "$(cat "$2" 2>/dev/null || echo none)" = "$3" ]; then pass_ "$1 (= $3)"; else fail_ "$1 (= $(cat "$2" 2>/dev/null || echo none), want $3)"; fi
}

cleanup() {
    _rc=$?
    for _f in "$T"/state*/csc.pid; do
        [ -f "$_f" ] || continue
        _p="$(cat "$_f" 2>/dev/null || true)"
        [ -n "$_p" ] && kill -9 "$_p" 2>/dev/null || true
    done
    if [ "$FAILED" -eq 0 ] && [ "$KEEP" != 1 ]; then
        rm -rf "$T"
    else
        log "work dir kept: $T"
    fi
    exit "$_rc"
}
trap cleanup EXIT

[ -f "$WRAPPER" ] || { echo "FATAL: wrapper not found: $WRAPPER" >&2; exit 1; }

# ---------------------------------------------------------------- fixtures
# fixture-build: the "command" under test; FIX_MODE drives it, FIX_STATE collects evidence.
cat > "$T/fixture-build" <<'EOF'
#!/bin/sh
set -u
D="${FIX_STATE:?}"
mkdir -p "$D" 2>/dev/null
n=0
[ -f "$D/count" ] && n="$(cat "$D/count")"
n=$((n + 1))
printf '%s\n' "$n" > "$D/count"
printf 'attempt=%s DOTNET_PROCESSOR_COUNT=%s\n' "$n" "${DOTNET_PROCESSOR_COUNT:-<unset>}" > "$D/env.$n"
case "${FIX_MODE:?}" in
    clean|exit7|exit5)
        echo "fixture build attempt $n: ${FIX_MODE}"
        [ "$FIX_MODE" = exit7 ] && exit 7
        [ "$FIX_MODE" = exit5 ] && exit 5
        exit 0 ;;
    stall-first)
        if [ "$n" -gt 1 ]; then echo "fixture build attempt $n: clean"; exit 0; fi ;;
    stall-always) : ;;
    *) echo "fixture: unknown FIX_MODE $FIX_MODE" >&2; exit 2 ;;
esac
echo "fixture build attempt $n: spawning a spun csc"
"$FIX_BIN/csc" -c 'while :; do :; done' &
cpid=$!
printf '%s\n' "$cpid" > "$D/csc.pid"
wait "$cpid"
rc=$?
printf 'csc exited rc=%s\n' "$rc" > "$D/csc.rc"
exit "$rc"
EOF
chmod +x "$T/fixture-build"

# stub-watchdog: a deterministic stand-in for the runtime-ohos watchdog (T2..T5).
cat > "$T/stub-watchdog" <<'EOF'
#!/bin/sh
set -u
LOGDIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --log-dir) LOGDIR="$2"; shift 2 ;;
        --quiet)   shift ;;
        --)        shift; break ;;
        *)         break ;;
    esac
done
[ -n "$LOGDIR" ] && mkdir -p "$LOGDIR" 2>/dev/null
D="${FIX_STATE:?}"
mkdir -p "$D" 2>/dev/null
n=0
[ -f "$D/stub.count" ] && n="$(cat "$D/stub.count")"
n=$((n + 1))
printf '%s\n' "$n" > "$D/stub.count"
case "${STUB_MODE:?}:$n" in
    kill-once:1|kill-always:1|kill-always:2)
        echo "[csc-watchdog] csc stall pid=424242 (dt=471s cpu=99%) -> SIGKILL process tree; evidence: $LOGDIR/event-stub"
        exit 137 ;;
esac
"$@"
rc=$?
printf '[stub-watchdog] command exited rc=%s\n' "$rc"
exit "$rc"
EOF
chmod +x "$T/stub-watchdog"

# The real-watchdog fixtures need a spun process whose comm is `csc`: a symlink keeps the
# comm name while the ELF behind it stays the trusted /bin/sh (a copied ELF is not execable
# on this host's CLI domain).
mkdir -p "$T/bin"
ln -sf /bin/sh "$T/bin/csc"

# ---------------------------------------------------------------- T0: usage
section "T0 usage"
if /bin/sh -n "$WRAPPER"; then pass_ "T0 wrapper parses (sh -n)"; else fail_ "T0 wrapper does not parse (sh -n)"; fi
"$WRAPPER" --help > "$T/t0-help.out" 2>&1
check_rc "T0 --help" "$?" 0
assert_contains "T0 --help documents DOTNET_PROCESSOR_COUNT=1" "DOTNET_PROCESSOR_COUNT=1" "$T/t0-help.out"
"$WRAPPER" > "$T/t0-noargs.out" 2>&1
check_rc "T0 no command is a usage error" "$?" 2

# ---------------------------------------------------------------- T1: disable switch
section "T1 CSC_WATCHDOG=0"
env FIX_STATE="$T/state-t1" FIX_MODE=exit7 FIX_BIN="$T/bin" STUB_MODE=kill-once \
    CSC_WATCHDOG=0 CSC_WATCHDOG_SCRIPT="$T/stub-watchdog" CSC_WATCHDOG_LOG_DIR="$T/logs-t1" \
    "$WRAPPER" "$T/fixture-build" > "$T/t1.out" 2>&1
check_rc "T1 command rc is preserved" "$?" 7
assert_contains "T1 reports the disabled switch" "CSC_WATCHDOG=0" "$T/t1.out"
assert_count "T1 command ran exactly once" "$T/state-t1/count" "1"
if [ -f "$T/state-t1/stub.count" ]; then fail_ "T1 stub watchdog was not called"; else pass_ "T1 stub watchdog was not called"; fi

# ---------------------------------------------------------------- T2: one kill -> rerun succeeds
section "T2 one stall kill, DOTNET_PROCESSOR_COUNT=1 rerun succeeds"
env FIX_STATE="$T/state-t2" FIX_MODE=clean FIX_BIN="$T/bin" STUB_MODE=kill-once \
    CSC_WATCHDOG_SCRIPT="$T/stub-watchdog" CSC_WATCHDOG_LOG_DIR="$T/logs-t2" CSC_WATCHDOG_RETRY_DELAY=0 \
    "$WRAPPER" "$T/fixture-build" > "$T/t2.out" 2>&1
check_rc "T2 wrapper rc" "$?" 0
assert_contains "T2 announces the DOTNET_PROCESSOR_COUNT=1 rerun" "re-running with DOTNET_PROCESSOR_COUNT=1" "$T/t2.out"
assert_file "T2 attempt1 log exists" "$T/logs-t2/run-"*/attempt1.log
assert_file "T2 attempt2 log exists" "$T/logs-t2/run-"*/attempt2.log
assert_count "T2 watchdog ran twice" "$T/state-t2/stub.count" "2"
assert_count "T2 command ran once (on the rerun)" "$T/state-t2/count" "1"
assert_contains "T2 rerun got DOTNET_PROCESSOR_COUNT=1" "DOTNET_PROCESSOR_COUNT=1" "$T/state-t2/env.1"

# ---------------------------------------------------------------- T3: two kills -> fail closed
section "T3 second stall fails closed"
env FIX_STATE="$T/state-t3" FIX_MODE=clean FIX_BIN="$T/bin" STUB_MODE=kill-always \
    CSC_WATCHDOG_SCRIPT="$T/stub-watchdog" CSC_WATCHDOG_LOG_DIR="$T/logs-t3" CSC_WATCHDOG_RETRY_DELAY=0 \
    "$WRAPPER" "$T/fixture-build" > "$T/t3.out" 2>&1
check_nonzero "T3 wrapper fails" "$?"
assert_contains "T3 says fail-closed" "failing fail-closed" "$T/t3.out"
assert_count "T3 watchdog ran exactly twice" "$T/state-t3/stub.count" "2"
assert_file "T3 attempt2 log exists" "$T/logs-t3/run-"*/attempt2.log

# ---------------------------------------------------------------- T4: plain failure is not retried
section "T4 failure without a kill is not retried"
env FIX_STATE="$T/state-t4" FIX_MODE=exit5 FIX_BIN="$T/bin" STUB_MODE=pass \
    CSC_WATCHDOG_SCRIPT="$T/stub-watchdog" CSC_WATCHDOG_LOG_DIR="$T/logs-t4" CSC_WATCHDOG_RETRY_DELAY=0 \
    "$WRAPPER" "$T/fixture-build" > "$T/t4.out" 2>&1
check_rc "T4 wrapper rc is the command rc" "$?" 5
assert_contains "T4 reports no retry" "without a csc watchdog kill; not retrying" "$T/t4.out"
assert_count "T4 watchdog ran once" "$T/state-t4/stub.count" "1"
assert_count "T4 command ran once" "$T/state-t4/count" "1"

# ---------------------------------------------------------------- T5: no resolvable watchdog
section "T5 no resolvable watchdog: warn and exec"
mkdir -p "$T/solo/scripts"
cp "$WRAPPER" "$T/solo/scripts/run-with-csc-watchdog.sh"
chmod +x "$T/solo/scripts/run-with-csc-watchdog.sh"
(
    unset RUNTIME_REPO CSC_WATCHDOG_SCRIPT
    FIX_STATE="$T/state-t5" FIX_MODE=clean FIX_BIN="$T/bin" STUB_MODE=kill-once \
        "$T/solo/scripts/run-with-csc-watchdog.sh" "$T/fixture-build" > "$T/t5.out" 2>&1
)
check_rc "T5 command rc is preserved" "$?" 0
assert_contains "T5 warns that the watchdog is missing" "csc watchdog not found" "$T/t5.out"
assert_count "T5 command ran once" "$T/state-t5/count" "1"

# ---------------------------------------------------------------- T6/T7: the real watchdog
section "T6/T7 real watchdog (runtime-ohos scripts/ohos-csc-watchdog.sh)"
if [ ! -f "$REAL" ]; then
    skip_ "real watchdog not found: $REAL (set CSC_WATCHDOG_REAL)"
    skip_ "real T6 kill -> DOTNET_PROCESSOR_COUNT=1 rerun scenario"
    skip_ "real T7 second-stall fail-closed scenario"
else
    env FIX_STATE="$T/state-t6" FIX_MODE=stall-first FIX_BIN="$T/bin" \
        CSC_WATCHDOG_SCRIPT="$REAL" CSC_WATCHDOG_LOG_DIR="$T/logs-t6" CSC_WATCHDOG_RETRY_DELAY=0 \
        CSC_WATCHDOG_SPIN_TIMEOUT=2 CSC_WATCHDOG_IDLE_TIMEOUT=0 CSC_WATCHDOG_POLL=1 \
        CSC_WATCHDOG_SNAP_TIMEOUT=2 CSC_WATCHDOG_DRAIN=5 \
        "$WRAPPER" "$T/fixture-build" > "$T/t6.out" 2>&1
    check_rc "T6 wrapper rc after the stall recovery" "$?" 0
    assert_contains "T6 attempt1 reports the SIGKILL" "SIGKILL process tree" "$T/logs-t6/run-"*/attempt1.log
    assert_count "T6 command ran twice" "$T/state-t6/count" "2"
    assert_contains "T6 rerun got DOTNET_PROCESSOR_COUNT=1" "DOTNET_PROCESSOR_COUNT=1" "$T/state-t6/env.2"
    if ls "$T/logs-t6/run-"*/attempt1/event-*/event.txt >/dev/null 2>&1; then
        pass_ "T6 watchdog wrote the attempt1 evidence"
    else
        fail_ "T6 watchdog evidence missing under attempt1/"
    fi

    env FIX_STATE="$T/state-t7" FIX_MODE=stall-always FIX_BIN="$T/bin" \
        CSC_WATCHDOG_SCRIPT="$REAL" CSC_WATCHDOG_LOG_DIR="$T/logs-t7" CSC_WATCHDOG_RETRY_DELAY=0 \
        CSC_WATCHDOG_SPIN_TIMEOUT=2 CSC_WATCHDOG_IDLE_TIMEOUT=0 CSC_WATCHDOG_POLL=1 \
        CSC_WATCHDOG_SNAP_TIMEOUT=2 CSC_WATCHDOG_DRAIN=5 \
        "$WRAPPER" "$T/fixture-build" > "$T/t7.out" 2>&1
    check_nonzero "T7 wrapper fails after the second real stall" "$?"
    assert_contains "T7 says fail-closed" "failing fail-closed" "$T/t7.out"
    assert_count "T7 command ran exactly twice" "$T/state-t7/count" "2"
fi

# ---------------------------------------------------------------- summary
printf '\n'
log "selftest-csc-watchdog v$SELFTEST_VERSION: $CHECKS checks, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
    printf 'SELFTEST FAILED\n' >&2
    exit 1
fi
printf 'SELFTEST PASSED\n'
exit 0
