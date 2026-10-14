#!/bin/sh
# selftest-run-upstream-tests.sh - fully offline stub selftest for scripts/run-upstream-tests.sh.
#
# Drives the runner against a stub dotnet, a stub maui checkout, a stub xunit runner dir and a
# scratch log base: no network, no device, no real SDK or test tree.
#
# Scenarios:
#   T1 usage        --help exits 0; an unknown suite and a non-numeric timebox are usage errors (2)
#   T2 essentials   one suite end to end: exit 0, the parseable suite= line, build/test logs teed
#                   into the log dir, the summary parsed from the stub xunit line
#   T3 all          the three suites run in order and each reports PASS
#   T4 fail         a stub xunit run reporting Failed: 2 and exiting 1 -> suite FAIL, exit 1
#   T5 build-fail   a failing build marks BUILD-FAIL and never invokes the xunit runner
#   T6 no-build     --no-build reuses the pre-created test dlls (no build invocation) and fails a
#                   suite whose output is missing (NO-OUTPUT)
#   T7 timebox      a stalling xunit run is killed at the budget: TIMEOUT, the remaining suites
#                   are SKIP(timebox), exit 1, and the run stays bounded by the budget
#   T8 red control  Failed: 1 with exit 0 and Failed: 0 with exit 1 both fail the runner
#   T9 xunit        a missing xunit runner dir / a missing maui checkout fail with a readable
#                   message before any build
#
# Env: SELFTEST_TMPDIR=<dir>  work dir base (default: the approved opencode tmp dir, else TMPDIR,
#                             else /tmp)
#      SELFTEST_KEEP=1        keep the work dir even when all checks pass
#      SELFTEST_RUNNER=<path> run-upstream-tests.sh under test (default: next to this script)
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="1 (2026-10-15)"

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

_self_path="$0"
case "$_self_path" in
    */*) ;;
    *) _self_path="$(command -v "$_self_path" 2>/dev/null || printf '%s' "$_self_path")" ;;
esac
SELF_DIR="$(cd "$(dirname "$_self_path")" && pwd -P)" || { printf 'FATAL: cannot resolve the selftest directory\n' >&2; exit 1; }
RUNNER="${SELFTEST_RUNNER:-$SELF_DIR/run-upstream-tests.sh}"
case "$RUNNER" in
    /*) ;;
    *) RUNNER="$PWD/$RUNNER" ;;
esac
[ -f "$RUNNER" ] || { printf 'FATAL: run-upstream-tests.sh not found: %s\n' "$RUNNER" >&2; exit 1; }
for _t in sh mktemp grep sed head tail cut date mkdir rm; do
    command -v "$_t" >/dev/null 2>&1 || { printf 'FATAL: required command not found: %s\n' "$_t" >&2; exit 1; }
done

if [ -n "${SELFTEST_TMPDIR:-}" ]; then
    WORK_BASE="$SELFTEST_TMPDIR"
elif [ -d /data/storage/el2/base/tmp/opencode ]; then
    WORK_BASE="/data/storage/el2/base/tmp/opencode"
elif [ -n "${TMPDIR:-}" ]; then
    WORK_BASE="$TMPDIR"
else
    WORK_BASE="/tmp"
fi
WORK="$(mktemp -d "$WORK_BASE/selftest-run-upstream-tests.XXXXXX")" || {
    printf 'FATAL: cannot create a work dir under %s\n' "$WORK_BASE" >&2
    exit 1
}
KEEP="${SELFTEST_KEEP:-0}"
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
check() { # <label> <grep -F pattern> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then pass_ "$1"; else fail_ "$1 (missing '$2' in $3)"; fi
}
check_not() { # <label> <grep -F pattern> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then fail_ "$1 (unexpected '$2' in $3)"; else pass_ "$1"; fi
}

log "selftest-run-upstream-tests v$SELFTEST_VERSION"
log "runner: $RUNNER"
log "work:   $WORK"

# ---- fixtures: stub maui checkout, stub dotnet, stub xunit runner dir ---------------------
FAKE_MAUI="$WORK/maui"
STUB="$WORK/bin/dotnet"
STUB_LOG="$WORK/stub.log"
XUNIT="$WORK/xunit"
LOG_BASE="$WORK/logs"
for _proj in src/Core/tests/UnitTests/Core.UnitTests.csproj \
             src/Essentials/test/UnitTests/Essentials.UnitTests.csproj \
             src/Controls/tests/Core.UnitTests/Controls.Core.UnitTests.csproj; do
    mkdir -p "$FAKE_MAUI/$(dirname "$_proj")"
    : > "$FAKE_MAUI/$_proj"
done
mkdir -p "$WORK/bin" "$XUNIT" "$LOG_BASE" "$WORK/results"
: > "$XUNIT/xunit.console.dll"
: > "$XUNIT/xunit.console.deps.json"
: > "$XUNIT/xunit.console.runtimeconfig.json"
for _out in Core.UnitTests:Microsoft.Maui.UnitTests.dll \
            Essentials.UnitTests:Microsoft.Maui.Essentials.UnitTests.dll \
            Controls.Core.UnitTests:Microsoft.Maui.Controls.Core.UnitTests.dll; do
    mkdir -p "$FAKE_MAUI/artifacts/bin/${_out%%:*}/Debug/net11.0"
    : > "$FAKE_MAUI/artifacts/bin/${_out%%:*}/Debug/net11.0/${_out##*:}"
done

cat > "$STUB" <<'STUB'
#!/bin/sh
# stub dotnet for selftest-run-upstream-tests.sh: logs every invocation, fails the build with
# STUB_BUILD_EXIT, prints an xunit summary line for `exec` (STUB_TOTAL/STUB_FAILED), can stall
# (STUB_XUNIT_SLEEP) and exits with STUB_XUNIT_EXIT.
{
    printf 'dotnet'
    for _a in "$@"; do printf ' %s' "$_a"; done
    printf ' (cwd=%s)\n' "$PWD"
} >> "${STUB_LOG:-/dev/null}"
case "${1:-}" in
    --version) printf '11.0.100-rc.2.stub\n'; exit 0 ;;
    build)
        printf 'stub: build %s\n' "${2:-}"
        exit "${STUB_BUILD_EXIT:-0}"
        ;;
    exec)
        _dll=unknown
        for _a in "$@"; do
            case "$_a" in
                */xunit.console.dll) ;;
                *.dll) _dll="$_a" ;;
            esac
        done
        printf 'xUnit.net Console Runner v2.9.3 (stub)\n'
        printf '=== TEST EXECUTION SUMMARY ===\n'
        printf '   %s  Total: %s, Errors: 0, Failed: %s, Skipped: 0, Time: 0.001s\n' \
            "$_dll" "${STUB_TOTAL:-7}" "${STUB_FAILED:-0}"
        if [ -n "${STUB_XUNIT_SLEEP:-}" ]; then
            case "${STUB_XUNIT_SLEEP_MATCH:-}" in
                '') exec sleep "$STUB_XUNIT_SLEEP" ;;
                *) case "$_dll" in
                       *"$STUB_XUNIT_SLEEP_MATCH"*) exec sleep "$STUB_XUNIT_SLEEP" ;;
                   esac ;;
            esac
        fi
        exit "${STUB_XUNIT_EXIT:-0}"
        ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$STUB"

# run_runner_env <logfile> <env...> -- <args...>; base env always applied first
run_runner() { # <logfile> <extra env assignments...> -- <args...>
    _rf="$1"; shift
    _envs=""
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do _envs="$_envs $1"; shift; done
    [ "${1:-}" = "--" ] && shift
    # shellcheck disable=SC2086
    env MAUI_REPO="$FAKE_MAUI" DOTNET="$STUB" \
        UPSTREAM_TESTS_LOG_BASE="$LOG_BASE" UPSTREAM_TESTS_XUNIT_RUNNER="$XUNIT" \
        STUB_LOG="$STUB_LOG" $_envs sh "$RUNNER" "$@" > "$_rf" 2>&1
    return $?
}
fresh_log() { : > "$STUB_LOG"; }

# ---- T1 usage -----------------------------------------------------------------------------
section "T1 usage"
run_runner "$WORK/T1-help.log" -- --help
[ $? -eq 0 ] && pass_ "T1 --help exits 0" || fail_ "T1 --help did not exit 0"
check "T1 --help prints the usage" "usage: scripts/run-upstream-tests.sh" "$WORK/T1-help.log"
run_runner "$WORK/T1-suite.log" -- --suite bogus
[ $? -eq 2 ] && pass_ "T1 an unknown suite is a usage error (2)" || fail_ "T1 unknown suite did not exit 2"
run_runner "$WORK/T1-timebox.log" -- --timebox abc
[ $? -eq 2 ] && pass_ "T1 a non-numeric timebox is a usage error (2)" || fail_ "T1 bad timebox did not exit 2"

# ---- T2 essentials end to end --------------------------------------------------------------
section "T2 essentials"
fresh_log
run_runner "$WORK/T2.log" -- --suite essentials
RC=$?
[ "$RC" -eq 0 ] && pass_ "T2 essentials exits 0" || fail_ "T2 essentials exited $RC"
check "T2 reports the suite result" "suite=essentials result=PASS" "$WORK/T2.log"
check "T2 reports the parsed totals" "total=7 errors=0 failed=0 skipped=0" "$WORK/T2.log"
check "T2 the final summary line" "summary: essentials=PASS ; failed=0 - OK" "$WORK/T2.log"
LOGDIR="$(ls -d "$LOG_BASE"/upstream-tests-* 2>/dev/null | head -1)"
if [ -n "$LOGDIR" ] && [ -f "$LOGDIR/essentials.build.log" ] && [ -f "$LOGDIR/essentials.log" ]; then
    pass_ "T2 the build and test logs are teed into the log dir"
else
    fail_ "T2 the log files are missing (log dir: ${LOGDIR:-none})"
fi
check "T2 the build log carries the build output" "stub: build src/Essentials/test/UnitTests/Essentials.UnitTests.csproj" "$LOGDIR/essentials.build.log"
check "T2 the runner passes the scratch NuGet config" "RestoreConfigFile=$LOGDIR/nuget.tests.config" "$STUB_LOG"
check "T2 the runner passes the platform-TFM off knobs" "-p:IncludeAndroidTargetFrameworks=false" "$STUB_LOG"
check "T2 the xunit run happens on the built dll" "Microsoft.Maui.Essentials.UnitTests.dll" "$STUB_LOG"
check "T2 the build runs from the maui checkout" "(cwd=$FAKE_MAUI)" "$STUB_LOG"
check "T2 the xunit run happens in the output dir" "(cwd=$FAKE_MAUI/artifacts/bin/Essentials.UnitTests/Debug/net11.0)" "$STUB_LOG"

# a custom --log-dir is honored
run_runner "$WORK/T2b.log" -- --suite essentials --log-dir "$WORK/customlogs"
[ $? -eq 0 ] && [ -f "$WORK/customlogs/essentials.log" ] && pass_ "T2 --log-dir is honored" \
    || fail_ "T2 --log-dir was not honored"

# ---- T3 all suites -------------------------------------------------------------------------
section "T3 all suites"
fresh_log
run_runner "$WORK/T3.log" -- --suite all
RC=$?
[ "$RC" -eq 0 ] && pass_ "T3 all exits 0" || fail_ "T3 all exited $RC"
check "T3 core ran" "suite=core result=PASS" "$WORK/T3.log"
check "T3 essentials ran" "suite=essentials result=PASS" "$WORK/T3.log"
check "T3 controls ran" "suite=controls result=PASS" "$WORK/T3.log"
check "T3 the summary counts three suites" "failed=0 - OK" "$WORK/T3.log"
check "T3 controls builds with analyzers off" "-p:RunAnalyzers=false" "$STUB_LOG"
check "T3 controls runs with -parallel none" "-parallel none" "$STUB_LOG"

# ---- T4 failing tests ----------------------------------------------------------------------
section "T4 failing tests"
run_runner "$WORK/T4.log" STUB_FAILED=2 STUB_XUNIT_EXIT=1 -- --suite core
RC=$?
[ "$RC" -eq 1 ] && pass_ "T4 a failed suite exits 1" || fail_ "T4 exited $RC"
check "T4 names the failure and the totals" "suite=core result=FAIL(exit=1) total=7 errors=0 failed=2" "$WORK/T4.log"

# ---- T5 build failure ----------------------------------------------------------------------
section "T5 build failure"
fresh_log
run_runner "$WORK/T5.log" STUB_BUILD_EXIT=1 -- --suite controls
RC=$?
[ "$RC" -eq 1 ] && pass_ "T5 a failed build exits 1" || fail_ "T5 exited $RC"
check "T5 marks BUILD-FAIL" "suite=controls result=BUILD-FAIL" "$WORK/T5.log"
check "T5 names the build log" "controls.build.log" "$WORK/T5.log"
check_not "T5 does not invoke the xunit runner after a failed build" "exec --depsfile" "$STUB_LOG"

# ---- T6 --no-build -------------------------------------------------------------------------
section "T6 --no-build"
fresh_log
run_runner "$WORK/T6.log" -- --suite essentials --no-build
RC=$?
[ "$RC" -eq 0 ] && pass_ "T6 --no-build reuses the output" || fail_ "T6 exited $RC"
check_not "T6 does not invoke the build" "build src/" "$STUB_LOG"
rm -f "$FAKE_MAUI/artifacts/bin/Core.UnitTests/Debug/net11.0/Microsoft.Maui.UnitTests.dll"
run_runner "$WORK/T6b.log" -- --suite core --no-build
RC=$?
[ "$RC" -eq 1 ] && pass_ "T6 a missing output fails the suite" || fail_ "T6 exited $RC"
check "T6 marks NO-OUTPUT" "suite=core result=NO-OUTPUT" "$WORK/T6b.log"
: > "$FAKE_MAUI/artifacts/bin/Core.UnitTests/Debug/net11.0/Microsoft.Maui.UnitTests.dll"

# ---- T7 timebox ----------------------------------------------------------------------------
section "T7 timebox"
T7_START="$(date '+%s')"
run_runner "$WORK/T7.log" STUB_XUNIT_SLEEP=20 STUB_XUNIT_SLEEP_MATCH=Essentials -- --suite all --timebox 6
RC=$?
T7_END="$(date '+%s')"
T7_SECS=$(( T7_END - T7_START ))
[ "$RC" -eq 1 ] && pass_ "T7 a timeboxed run exits 1" || fail_ "T7 exited $RC"
check "T7 core passed before the budget ran out" "suite=core result=PASS" "$WORK/T7.log"
check "T7 marks the stalling suite TIMEOUT" "suite=essentials result=TIMEOUT" "$WORK/T7.log"
check "T7 skips the remaining suites" "controls=SKIP(timebox)" "$WORK/T7.log"
[ "$T7_SECS" -lt 60 ] && pass_ "T7 the run stayed bounded (${T7_SECS}s)" || fail_ "T7 took ${T7_SECS}s"
check "T7 the essentials xunit run had started" "run   Microsoft.Maui.Essentials.UnitTests.dll" "$WORK/T7.log"

# ---- T8 red controls -----------------------------------------------------------------------
section "T8 red controls"
run_runner "$WORK/T8a.log" STUB_FAILED=1 STUB_XUNIT_EXIT=0 -- --suite core
[ $? -eq 1 ] && pass_ "T8 red control: Failed: 1 with exit 0 still fails" || fail_ "T8a did not fail"
check "T8a marks the parsed failure" "result=FAIL(exit=0) total=7 errors=0 failed=1" "$WORK/T8a.log"
run_runner "$WORK/T8b.log" STUB_FAILED=0 STUB_XUNIT_EXIT=1 -- --suite core
[ $? -eq 1 ] && pass_ "T8 red control: exit 1 with Failed: 0 still fails" || fail_ "T8b did not fail"
check "T8b marks the exit failure" "result=FAIL(exit=1)" "$WORK/T8b.log"

# ---- T9 missing prerequisites --------------------------------------------------------------
section "T9 missing prerequisites"
run_runner "$WORK/T9a.log" UPSTREAM_TESTS_XUNIT_RUNNER="$WORK/no-xunit" -- --suite core
RC=$?
[ "$RC" -eq 1 ] && pass_ "T9 a missing xunit runner exits 1" || fail_ "T9a exited $RC"
check "T9a names the xunit runner" "xunit.runner.console not found" "$WORK/T9a.log"
run_runner "$WORK/T9b.log" MAUI_REPO="$WORK/no-maui" -- --suite core
RC=$?
[ "$RC" -eq 1 ] && pass_ "T9 a missing maui checkout exits 1" || fail_ "T9b exited $RC"
check "T9b names the maui checkout" "maui checkout not found" "$WORK/T9b.log"

printf '\nselftest-run-upstream-tests: checks: %d, failed: %d\n' "$CHECKS" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
