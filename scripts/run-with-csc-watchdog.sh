#!/bin/sh
# ============================================================================
# run-with-csc-watchdog.sh - run a command under the csc livelock watchdog and
# respawn it once with DOTNET_PROCESSOR_COUNT=1 after a watchdog kill.
#
# On this OHOS host Roslyn `csc` sometimes livelocks: one core spinning with
# frozen I/O for 15-20 min with no csc output. The rescue watchdog in the
# runtime-ohos checkout (scripts/ohos-csc-watchdog.sh) detects that no-progress
# spin and SIGKILLs the compiler. This wrapper adds the known-good recovery:
# when the watchdog had to kill a compiler in attempt 1, the whole command is
# rerun once with DOTNET_PROCESSOR_COUNT=1 (measured green on this host) and
# with the shared compiler server disabled. A second watchdog kill is a hard
# failure (fail-closed, no further retries), so a wedged host is bounded by the
# watchdog thresholds, never by an unbounded retry loop.
#
# Integration: scripts/preflight.sh runs the interaction build and both pixel
# builds through this wrapper. Default is on; CSC_WATCHDOG=0 disables it.
#
# Usage: scripts/run-with-csc-watchdog.sh <command> [args...]
#
# Env (all optional):
#   CSC_WATCHDOG=0                  run the command directly, no watchdog
#   CSC_WATCHDOG_SCRIPT=<path>      rescue script; default resolution order:
#                                   $RUNTIME_REPO/scripts/ohos-csc-watchdog.sh,
#                                   <repo>/../runtime-ohos/scripts/ohos-csc-watchdog.sh,
#                                   <repo>/scripts/ohos-csc-watchdog.sh
#   CSC_WATCHDOG_SPIN_TIMEOUT=<s>   no-progress budget while csc spins (default 480)
#   CSC_WATCHDOG_IDLE_TIMEOUT=<s>   no-progress budget while csc idles (default 300)
#   CSC_WATCHDOG_POLL=<s>           watchdog sample interval (default 10)
#   CSC_WATCHDOG_RETRY_DELAY=<s>    pause before the DOTNET_PROCESSOR_COUNT=1
#                                   rerun (default 2)
#   CSC_WATCHDOG_LOG_DIR=<dir>      log base (default ./artifacts/log/csc-watchdog
#                                   when ./artifacts exists, else
#                                   ${TMPDIR:-/tmp}/csc-watchdog). Each invocation
#                                   gets a run-<stamp>-<pid> directory holding
#                                   attempt1.log, attempt2.log and the per-attempt
#                                   watchdog dirs (evidence/).
#
# Exit: the command's exit code; 0 when either attempt succeeded; 2 = usage error.
#       When both attempts were killed by the watchdog the exit is the second
#       attempt's code (non-zero) and the run directory is named on stderr.
# ============================================================================
set -u

PROG="csc-watchdog-wrap"
log()  { printf '[%s] %s\n' "$PROG" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$PROG" "$*" >&2; }

usage() {
    cat <<'EOF'
usage: run-with-csc-watchdog.sh <command> [args...]

Runs <command> under the csc livelock watchdog (default: the runtime-ohos
scripts/ohos-csc-watchdog.sh). If the watchdog kills a stalled compiler, the
command is rerun once with DOTNET_PROCESSOR_COUNT=1; a second kill fails.

Env: CSC_WATCHDOG=0 disables the wrapper; CSC_WATCHDOG_SCRIPT points at the
watchdog script; CSC_WATCHDOG_SPIN_TIMEOUT (default 480) / IDLE_TIMEOUT
(default 300) / POLL (default 10) / RETRY_DELAY (default 2) / LOG_DIR configure
thresholds and logs. Exit: command rc; 2 usage; non-zero on a double kill.
EOF
}

die_usage() { warn "$*"; printf 'usage: %s <command> [args...]\n' "$PROG" >&2; exit 2; }

[ $# -gt 0 ] || die_usage "no command given"
case "$1" in
    -h|--help) usage; exit 0 ;;
esac

if [ "${CSC_WATCHDOG:-1}" = 0 ]; then
    log "CSC_WATCHDOG=0: running without the watchdog"
    exec "$@"
fi

SELF="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SELF/.." && pwd)"
WATCHDOG="${CSC_WATCHDOG_SCRIPT:-}"
if [ -n "$WATCHDOG" ] && [ ! -f "$WATCHDOG" ]; then
    warn "CSC_WATCHDOG_SCRIPT=$WATCHDOG does not exist; using the default resolution"
    WATCHDOG=""
fi
if [ -z "$WATCHDOG" ]; then
    for _cand in \
        "${RUNTIME_REPO:-}/scripts/ohos-csc-watchdog.sh" \
        "$REPO/../runtime-ohos/scripts/ohos-csc-watchdog.sh" \
        "$REPO/scripts/ohos-csc-watchdog.sh"; do
        if [ -n "$_cand" ] && [ -f "$_cand" ]; then
            WATCHDOG="$_cand"
            break
        fi
    done
fi
if [ -z "$WATCHDOG" ]; then
    warn "csc watchdog not found (tried \$CSC_WATCHDOG_SCRIPT, \$RUNTIME_REPO, ../runtime-ohos); running without it. Set CSC_WATCHDOG=0 to silence."
    exec "$@"
fi
if ! command -v bash >/dev/null 2>&1; then
    warn "bash not found (the watchdog needs it); running without the watchdog"
    exec "$@"
fi

export CSC_WATCHDOG_SPIN_TIMEOUT="${CSC_WATCHDOG_SPIN_TIMEOUT:-480}"
export CSC_WATCHDOG_IDLE_TIMEOUT="${CSC_WATCHDOG_IDLE_TIMEOUT:-300}"
export CSC_WATCHDOG_POLL="${CSC_WATCHDOG_POLL:-10}"
# The wrapper owns the retry protocol; the watchdog must not retry on its own.
export CSC_WATCHDOG_RETRIES=0
RETRY_DELAY="${CSC_WATCHDOG_RETRY_DELAY:-2}"
case "$RETRY_DELAY" in ''|*[!0-9]*) RETRY_DELAY=2 ;; esac

LOG_BASE="${CSC_WATCHDOG_LOG_DIR:-}"
if [ -z "$LOG_BASE" ]; then
    if [ -d "./artifacts" ]; then
        LOG_BASE="./artifacts/log/csc-watchdog"
    else
        LOG_BASE="${TMPDIR:-/tmp}/csc-watchdog"
    fi
fi
RUN_DIR="$LOG_BASE/run-$(date +%Y%m%d-%H%M%S)-$$"
if ! mkdir -p "$RUN_DIR"; then
    warn "cannot create log dir $RUN_DIR; running without the watchdog"
    exec "$@"
fi

ATTEMPT_RC=""
run_attempt() { # <n> <command...>; sets ATTEMPT_RC from the command
    _n="$1"
    shift
    _log="$RUN_DIR/attempt$_n.log"
    _rcf="$RUN_DIR/.rc$_n"
    rm -f "$_rcf"
    # POSIX sh sees only tee's status after the pipe, so the command writes its
    # own rc to a file before the pipeline ends; tee keeps the console live and
    # leaves one log per attempt (the two segments this wrapper must preserve).
    ( "$@" ; printf '%s\n' "$?" > "$_rcf" ) 2>&1 | tee "$_log"
    ATTEMPT_RC="$(cat "$_rcf" 2>/dev/null || true)"
    [ -n "$ATTEMPT_RC" ] || ATTEMPT_RC=1
}

log "command: $*"
log "watchdog: $WATCHDOG (spin ${CSC_WATCHDOG_SPIN_TIMEOUT}s, idle ${CSC_WATCHDOG_IDLE_TIMEOUT}s, poll ${CSC_WATCHDOG_POLL}s)"
log "run logs: $RUN_DIR"

log "attempt 1/2: watching for csc stalls"
run_attempt 1 bash "$WATCHDOG" --log-dir "$RUN_DIR/attempt1" -- "$@"
rc1="$ATTEMPT_RC"

if [ "$rc1" -eq 0 ]; then
    log "attempt 1 succeeded"
    exit 0
fi

if ! grep -q 'SIGKILL process tree' "$RUN_DIR/attempt1.log" 2>/dev/null; then
    log "attempt 1 failed rc=$rc1 without a csc watchdog kill; not retrying (logs: $RUN_DIR)"
    exit "$rc1"
fi

log "attempt 1 rc=$rc1 after a csc watchdog kill; re-running with DOTNET_PROCESSOR_COUNT=1"
export DOTNET_PROCESSOR_COUNT=1
# Never let the rerun reuse a compiler server the first attempt may have wedged.
export UseSharedCompilation=false
if [ "$RETRY_DELAY" -gt 0 ]; then
    sleep "$RETRY_DELAY"
fi

log "attempt 2/2: DOTNET_PROCESSOR_COUNT=1, watching again"
run_attempt 2 bash "$WATCHDOG" --log-dir "$RUN_DIR/attempt2" -- "$@"
rc2="$ATTEMPT_RC"

if [ "$rc2" -eq 0 ]; then
    log "attempt 2 succeeded with DOTNET_PROCESSOR_COUNT=1 (logs: $RUN_DIR)"
    exit 0
fi
if grep -q 'SIGKILL process tree' "$RUN_DIR/attempt2.log" 2>/dev/null; then
    warn "attempt 2 was also killed by the csc watchdog even with DOTNET_PROCESSOR_COUNT=1; failing fail-closed, no further retries (logs: $RUN_DIR)"
else
    warn "attempt 2 failed rc=$rc2 without a csc watchdog kill (logs: $RUN_DIR)"
fi
exit "$rc2"
