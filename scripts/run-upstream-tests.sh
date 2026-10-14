#!/bin/sh
# run-upstream-tests.sh - re-run the upstream MAUI unit test suites against a local maui-ohos
# checkout with the environment bypasses recorded by UPSTREAM-TESTS (2026-10-13; see
# docs/plans/2026-10-15-ohos-upstream-tests-runner.md in the runtime-ohos docs):
#
#   core       src/Core/tests/UnitTests/Core.UnitTests.csproj
#   essentials src/Essentials/test/UnitTests/Essentials.UnitTests.csproj
#   controls   src/Controls/tests/Core.UnitTests/Controls.Core.UnitTests.csproj
#
# Per suite: `dotnet build` the project (platform TFMs off, scratch RestoreConfigFile,
# RestoreDisableParallel, NuGetAudit off, DOTNET_PROCESSOR_COUNT=1) and then run the built test
# assembly through the xunit console runner with CWD = the build output dir (Core's
# LocalizationTests resolve the repo root as five ".." from CWD). Controls additionally builds
# with -p:RunAnalyzers=false (the merged snapshot carries a stale BannedSymbols RS0030) and runs
# with `-parallel none` (upstream isolation race: CssDisabledTests flips a global AppContext
# switch out from under IStylableTest). The maui checkout is never modified; every knob is a
# command-line parameter or an environment variable.
#
# usage: scripts/run-upstream-tests.sh [--suite core|essentials|controls|all] [--timebox <secs>]
#                                      [--no-build] [--log-dir <dir>] [-h]
#   --suite   which suites to run (default: all, in the order core essentials controls)
#   --timebox an overall wall-clock budget in seconds; when it runs out the current command is
#             killed (TERM, then KILL after 10 s), the suite is marked TIMEOUT, the remaining
#             suites are SKIPped and the exit code is 1 (0 = no budget)
#   --no-build reuse the existing build output (fails a suite whose test dll is missing)
#   --log-dir where the tee logs + xunit xml/html go (default:
#             <UPSTREAM_TESTS_LOG_BASE>/upstream-tests-<timestamp>)
#
# Env: MAUI_REPO=<dir>       maui checkout (default: the sibling ../maui-ohos of this repo)
#      DOTNET=<dotnet>       SDK to use (default: $HOME/.dotnet.rc2-fix/dotnet when present,
#                            else `dotnet` from PATH)
#      UPSTREAM_TESTS_LOG_BASE=<dir>      log base dir (default: the approved opencode tmp dir,
#                                         else $TMPDIR, else /tmp)
#      UPSTREAM_TESTS_NUGET_CONFIG=<file> use this NuGet config instead of the generated one
#                                         (generated default: nuget.org + dnceng dotnet11)
#      UPSTREAM_TESTS_XUNIT_RUNNER=<dir>  xunit.runner.console 2.9.3 tools/net6.0 dir
#                                         (default: $HOME/.nuget/packages/xunit.runner.console/
#                                         2.9.3/tools/net6.0)
# Exit: 0 = every selected suite built, ran and reported 0 errors/0 failures
#       1 = at least one suite failed (build, tests, timeout) or a prerequisite is missing
#       2 = usage error
set -u

VERSION="1 (2026-10-15)"
SUITE_ARG=all
TIMEBOX=0
NO_BUILD=0
LOG_DIR_ARG=""

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }
die_usage() { printf 'run-upstream-tests: %s\n' "$*" >&2; usage >&2; exit 2; }
die()     { printf 'run-upstream-tests: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
usage: scripts/run-upstream-tests.sh [--suite core|essentials|controls|all] [--timebox <secs>]
                                     [--no-build] [--log-dir <dir>] [-h]

Re-runs the upstream MAUI unit test suites (Core / Essentials / Controls.Core) against the
local maui-ohos checkout with the recorded environment bypasses. --timebox bounds the whole
run; --no-build reuses existing test output; every phase is teed into --log-dir.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --suite)
            [ $# -ge 2 ] || die_usage "missing value after --suite"
            SUITE_ARG="$2"
            shift 2
            ;;
        --timebox)
            [ $# -ge 2 ] || die_usage "missing value after --timebox"
            TIMEBOX="$2"
            shift 2
            ;;
        --no-build) NO_BUILD=1; shift ;;
        --log-dir)
            [ $# -ge 2 ] || die_usage "missing value after --log-dir"
            LOG_DIR_ARG="$2"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) die_usage "unknown argument: $1" ;;
    esac
done

case "$SUITE_ARG" in
    core)       SELECTED="core" ;;
    essentials) SELECTED="essentials" ;;
    controls)   SELECTED="controls" ;;
    all)        SELECTED="core essentials controls" ;;
    *) die_usage "unknown --suite '$SUITE_ARG' (core|essentials|controls|all)" ;;
esac
case "$TIMEBOX" in
    ''|*[!0-9]*) die_usage "--timebox must be a non-negative integer (seconds)" ;;
esac

W="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$W/scripts/lib-dotnet-env.sh" ] || die "scripts/lib-dotnet-env.sh not found next to this script"
# Shared dotnet environment (MSBuild server/node reuse off, short TMPDIR, no Roslyn server).
. "$W/scripts/lib-dotnet-env.sh" "$W"

# ---- dotnet SDK --------------------------------------------------------------------------
if [ -z "${DOTNET:-}" ]; then
    if [ -x "$HOME/.dotnet.rc2-fix/dotnet" ]; then
        DOTNET="$HOME/.dotnet.rc2-fix/dotnet"
    else
        DOTNET=dotnet
    fi
fi
DOTNET_BIN="$(command -v "$DOTNET" 2>/dev/null || true)"
[ -n "$DOTNET_BIN" ] || die "dotnet not found: $DOTNET (set DOTNET=)"
case "$DOTNET_BIN" in
    /*) ;;
    *) DOTNET_BIN="$PWD/$DOTNET_BIN" ;;
esac
DOTNET_CLI_VERSION="$("$DOTNET_BIN" --version 2>/dev/null | head -1 || printf 'unknown')"
export DOTNET_ROOT="$(cd "$(dirname "$DOTNET_BIN")" && pwd -P)"
export DOTNET_HOST_PATH="$DOTNET_BIN"
export DOTNET_ROLL_FORWARD="${DOTNET_ROLL_FORWARD:-LatestMajor}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
# The three recorded host bypasses (see the UPSTREAM-TESTS doc): NuGet PKCS signature
# verification wedges this host, and a highly parallel csc OpenSSL-crashes/livelocks it.
export DOTNET_NUGET_SIGNATURE_VERIFICATION="${DOTNET_NUGET_SIGNATURE_VERIFICATION:-false}"
export DOTNET_PROCESSOR_COUNT="${DOTNET_PROCESSOR_COUNT:-1}"
export DOTNET_SYSTEM_NET_DISABLEIPV6="${DOTNET_SYSTEM_NET_DISABLEIPV6:-1}"

# ---- maui checkout, xunit runner, log dir, NuGet config ----------------------------------
MAUI_REPO="${MAUI_REPO:-$W/../maui-ohos}"
MAUI_REPO_REQ="$MAUI_REPO"
MAUI_REPO="$(cd "$MAUI_REPO" 2>/dev/null && pwd -P)" || die "maui checkout not found: $MAUI_REPO_REQ (set MAUI_REPO=)"
[ -d "$MAUI_REPO/src" ] || die "not a maui checkout (no src/): $MAUI_REPO"
MAUI_SHA="$(git -C "$MAUI_REPO" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
MAUI_DIRTY="$(git -C "$MAUI_REPO" status --porcelain 2>/dev/null | head -1 || true)"
[ -n "$MAUI_DIRTY" ] && MAUI_DIRTY=1 || MAUI_DIRTY=0

XUNIT_RUNNER="${UPSTREAM_TESTS_XUNIT_RUNNER:-$HOME/.nuget/packages/xunit.runner.console/2.9.3/tools/net6.0}"
[ -f "$XUNIT_RUNNER/xunit.console.dll" ] || die "xunit.runner.console not found: $XUNIT_RUNNER (restore the maui repo once, or set UPSTREAM_TESTS_XUNIT_RUNNER=)"

if [ -n "$LOG_DIR_ARG" ]; then
    LOG_DIR="$LOG_DIR_ARG"
else
    LOG_BASE="${UPSTREAM_TESTS_LOG_BASE:-}"
    if [ -z "$LOG_BASE" ]; then
        if [ -d /data/storage/el2/base/tmp/opencode ]; then
            LOG_BASE="/data/storage/el2/base/tmp/opencode"
        elif [ -n "${TMPDIR:-}" ]; then
            LOG_BASE="$TMPDIR"
        else
            LOG_BASE="/tmp"
        fi
    fi
    LOG_DIR="$LOG_BASE/upstream-tests-$(date '+%Y%m%d-%H%M%S')"
fi
mkdir -p "$LOG_DIR/results" || die "cannot create the log dir: $LOG_DIR"

# Reachable feeds only: the maui NuGet.config pulls darc/1ES feeds that stall on this host, so
# the build uses a scratch config with nuget.org + the dnceng dotnet11 feed (recorded bypass).
if [ -n "${UPSTREAM_TESTS_NUGET_CONFIG:-}" ]; then
    NUGET_CONFIG="$UPSTREAM_TESTS_NUGET_CONFIG"
    [ -f "$NUGET_CONFIG" ] || die "UPSTREAM_TESTS_NUGET_CONFIG not found: $NUGET_CONFIG"
else
    NUGET_CONFIG="$LOG_DIR/nuget.tests.config"
    cat > "$NUGET_CONFIG" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />
    <add key="dotnet11" value="https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet11/nuget/v3/index.json" protocolVersion="3" />
  </packageSources>
</configuration>
XML
fi

# `timeout` support: -k (SIGKILL after a grace period) is probed once.
HAVE_TIMEOUT=0
TIMEOUT_K=0
if command -v timeout >/dev/null 2>&1; then
    HAVE_TIMEOUT=1
    if timeout -k 1 1 true >/dev/null 2>&1; then TIMEOUT_K=1; fi
fi

if [ "$TIMEBOX" -gt 0 ]; then
    _now="$(date '+%s')"
    DEADLINE=$(( _now + TIMEBOX ))
else
    DEADLINE=0
fi

log "run-upstream-tests v$VERSION"
log "dotnet: $DOTNET_BIN ($DOTNET_CLI_VERSION)"
log "maui:   $MAUI_REPO @ $MAUI_SHA (dirty=$MAUI_DIRTY)"
log "xunit:  $XUNIT_RUNNER"
log "logs:   $LOG_DIR"
log "suites: $SELECTED (no-build=$NO_BUILD, timebox=$TIMEBOX)"

# ---- phase runner -------------------------------------------------------------------------
# tee_run <logfile> <command...>: run the command with stdout+stderr teed to <logfile> and the
# console, bounded by the remaining --timebox budget. Returns the command's exit status; 124
# when the budget ran out (the command is killed).
tee_run() {
    _log="$1"; shift
    if [ "$TIMEBOX" -gt 0 ]; then
        _now="$(date '+%s')"
        _secs=$(( DEADLINE - _now ))
        if [ "$_secs" -le 0 ]; then
            printf 'run-upstream-tests: timebox exhausted\n' >&2
            return 124
        fi
        if [ "$HAVE_TIMEOUT" = 1 ]; then
            _st="$LOG_DIR/.status.$$"
            if [ "$TIMEOUT_K" = 1 ]; then
                ( timeout -k 10 "$_secs" "$@" 2>&1; printf '%s\n' "$?" > "$_st" ) | tee "$_log"
            else
                ( timeout "$_secs" "$@" 2>&1; printf '%s\n' "$?" > "$_st" ) | tee "$_log"
            fi
            _rc="$(cat "$_st" 2>/dev/null || printf '1')"
            rm -f "$_st"
            return "$_rc"
        fi
        # No `timeout` on this host: background + watchdog; the log is the only capture.
        "$@" > "$_log" 2>&1 &
        _pid=$!
        while kill -0 "$_pid" 2>/dev/null; do
            if [ "$(date '+%s')" -ge "$DEADLINE" ]; then
                kill -TERM "$_pid" 2>/dev/null
                sleep 5
                kill -KILL "$_pid" 2>/dev/null
                wait "$_pid" 2>/dev/null
                tail -n 20 "$_log" 2>/dev/null | sed 's/^/   /'
                return 124
            fi
            sleep 2
        done
        wait "$_pid"
        return $?
    fi
    _st="$LOG_DIR/.status.$$"
    ( "$@" 2>&1; printf '%s\n' "$?" > "$_st" ) | tee "$_log"
    _rc="$(cat "$_st" 2>/dev/null || printf '1')"
    rm -f "$_st"
    return "$_rc"
}

# The xunit console summary line: "  <assembly>  Total: N, Errors: N, Failed: N, Skipped: N".
parse_summary() { # <xunit log> -> "total errors failed skipped"
    sed -n 's/.*Total: \([0-9][0-9]*\), Errors: \([0-9][0-9]*\), Failed: \([0-9][0-9]*\), Skipped: \([0-9][0-9]*\).*/\1 \2 \3 \4/p' "$1" | tail -1
}

build_one() { # <logfile> <project> <extra build args...>
    _log="$1"; _proj="$2"; shift 2
    # The project path is relative to the maui checkout; build from there (artifact paths in the
    # logs are absolute once the build starts).
    ( cd "$MAUI_REPO" && tee_run "$_log" "$DOTNET_BIN" build "$_proj" -c Debug -m:8 \
        -p:IncludeAndroidTargetFrameworks=false -p:IncludeIosTargetFrameworks=false \
        -p:IncludeMacCatalystTargetFrameworks=false -p:IncludeOpenHarmonyTargetFrameworks=false \
        -p:RestoreConfigFile="$NUGET_CONFIG" -p:RestoreDisableParallel=true -p:NuGetAudit=false \
        "$@" )
}

run_xunit() { # <suite> <logfile> <output dir> <test dll> <extra xunit args...>
    _suite="$1"; _log="$2"; _out="$3"; _dll="$4"; shift 4
    ( cd "$_out" && tee_run "$_log" "$DOTNET_BIN" exec \
        --depsfile "$XUNIT_RUNNER/xunit.console.deps.json" \
        --runtimeconfig "$XUNIT_RUNNER/xunit.console.runtimeconfig.json" \
        "$XUNIT_RUNNER/xunit.console.dll" "$_out/$_dll" -noautoreporters -nocolor \
        -xml "$LOG_DIR/results/$_suite.xml" -html "$LOG_DIR/results/$_suite.html" "$@" )
}

# ---- the suites --------------------------------------------------------------------------
SUITE_RESULTS=""
FAILED=0
STOP=0
for suite in $SELECTED; do
    [ "$STOP" = 0 ] || { SUITE_RESULTS="$SUITE_RESULTS $suite=SKIP(timebox)"; continue; }
    case "$suite" in
        core)
            PROJ="src/Core/tests/UnitTests/Core.UnitTests.csproj"
            OUT="$MAUI_REPO/artifacts/bin/Core.UnitTests/Debug/net11.0"
            DLL="Microsoft.Maui.UnitTests.dll"
            BUILD_EXTRA=""
            XUNIT_EXTRA=""
            ;;
        essentials)
            PROJ="src/Essentials/test/UnitTests/Essentials.UnitTests.csproj"
            OUT="$MAUI_REPO/artifacts/bin/Essentials.UnitTests/Debug/net11.0"
            DLL="Microsoft.Maui.Essentials.UnitTests.dll"
            BUILD_EXTRA=""
            XUNIT_EXTRA=""
            ;;
        controls)
            PROJ="src/Controls/tests/Core.UnitTests/Controls.Core.UnitTests.csproj"
            OUT="$MAUI_REPO/artifacts/bin/Controls.Core.UnitTests/Debug/net11.0"
            DLL="Microsoft.Maui.Controls.Core.UnitTests.dll"
            BUILD_EXTRA="-p:RunAnalyzers=false"
            XUNIT_EXTRA="-parallel none"
            ;;
    esac
    section "suite $suite"
    [ -f "$MAUI_REPO/$PROJ" ] || die "test project not found: $MAUI_REPO/$PROJ"
    RESULT=""
    TOTAL=""; ERRORS=""; XFAILED=""; SKIPPED=""
    T0="$(date '+%s')"
    BUILD_SECS=0
    RUN_SECS=0

    if [ "$NO_BUILD" = 0 ]; then
        log "   build $PROJ"
        build_one "$LOG_DIR/$suite.build.log" "$PROJ" $BUILD_EXTRA
        BRC=$?
        _now="$(date '+%s')"
        BUILD_SECS=$(( _now - T0 ))
        if [ "$BRC" -eq 124 ]; then
            RESULT="TIMEOUT"
        elif [ "$BRC" -ne 0 ]; then
            log "   build FAILED (exit $BRC); tail of $LOG_DIR/$suite.build.log:"
            tail -n 25 "$LOG_DIR/$suite.build.log" | sed 's/^/   /'
            RESULT="BUILD-FAIL"
        fi
    fi
    if [ -z "$RESULT" ]; then
        if [ ! -f "$OUT/$DLL" ]; then
            log "   test output missing: $OUT/$DLL (run without --no-build)"
            RESULT="NO-OUTPUT"
        else
            TR0="$(date '+%s')"
            log "   run   $DLL (cwd = $OUT)"
            run_xunit "$suite" "$LOG_DIR/$suite.log" "$OUT" "$DLL" $XUNIT_EXTRA
            XRC=$?
            _now="$(date '+%s')"
            RUN_SECS=$(( _now - TR0 ))
            SUM="$(parse_summary "$LOG_DIR/$suite.log")"
            TOTAL="${SUM%% *}"; rest="${SUM#* }"; ERRORS="${rest%% *}"; rest="${rest#* }"; XFAILED="${rest%% *}"; SKIPPED="${rest##* }"
            if [ "$XRC" -eq 124 ]; then
                RESULT="TIMEOUT"
            elif [ "$XRC" -eq 0 ] && [ -n "$SUM" ] && [ "$ERRORS" = 0 ] && [ "$XFAILED" = 0 ]; then
                RESULT="PASS"
            else
                RESULT="FAIL(exit=$XRC)"
            fi
        fi
    fi
    log "   suite=$suite result=$RESULT total=${TOTAL:--} errors=${ERRORS:--} failed=${XFAILED:--} skipped=${SKIPPED:--} build=${BUILD_SECS}s run=${RUN_SECS}s log=$LOG_DIR/$suite.log"
    if [ "$RESULT" = TIMEOUT ]; then
        STOP=1
    fi
    case "$RESULT" in
        PASS) ;;
        *) FAILED=$((FAILED + 1)) ;;
    esac
    SUITE_RESULTS="$SUITE_RESULTS $suite=$RESULT"
done

if [ "$FAILED" -eq 0 ]; then
    printf '\n[upstream-tests] summary:%s ; failed=0 - OK (logs: %s)\n' "$SUITE_RESULTS" "$LOG_DIR"
    exit 0
fi
printf '\n[upstream-tests] summary:%s ; failed=%s - FAIL (logs: %s)\n' "$SUITE_RESULTS" "$FAILED" "$LOG_DIR"
exit 1
