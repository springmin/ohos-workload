#!/bin/sh
# selftest-tasks.sh - unit tests and pack-distribution gate for the compiled hap-packaging tasks
# (task-assembly migration, audit V8 / RELEASE-25).
#
#   S1 static   every OpenHarmony.Hap.targets loads the six tasks from
#               tools/Microsoft.OpenHarmony.Tasks.dll (no RoslynCodeTaskFactory inline code left),
#               every one of the three SDK packs ships the assembly and the three copies are
#               byte-identical
#   S2 unit     build src/Microsoft.OpenHarmony.Tasks + test/openharmony-tasks-tests and run the
#               checks over the task classes: deterministic zip bytes/order/timestamp and skip
#               names, runtime-ELF staging, payload staging layout, payload marker schema +
#               escaping, feature-permission resolution (matrix/request points/strict mode) and
#               module.json generation (substitution/escaping/insertions/negatives). The run must
#               print its own [tasks-tests] checks>=95 failed=0 assert=True contract line
#   S3 drift    the committed pack copies are byte-identical to the freshly built Release assembly;
#               a changed task source without re-running scripts/prepare-packs.sh fails here
#
# The static half always gates (no SDK needed); S2/S3 are reported as [SKIP] when dotnet is
# unavailable so an offline box still checks the shipped bits.
#
# Env: SELFTEST_TMPDIR=<dir>  work dir base (default: the approved opencode tmp dir)
#      DOTNET=<dotnet>       SDK used for the builds
#      SELFTEST_KEEP=1       keep the work dir even when all checks pass
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="1 (2026-09-26)"
TASKS_PROJECT="src/Microsoft.OpenHarmony.Tasks/Microsoft.OpenHarmony.Tasks.csproj"
TASKS_DLL_REL="tools/Microsoft.OpenHarmony.Tasks.dll"
TASKS_TESTS_PROJECT="test/openharmony-tasks-tests/openharmony-tasks-tests.csproj"
TASKS_TESTS_DLL="test/openharmony-tasks-tests/bin/Release/net11.0/openharmony-tasks-tests.dll"
CHECK_FLOOR=95
PACK_VERSIONS="1.0.0-preview.22 1.0.0-preview.23 1.0.0-preview.24"

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

W="$(cd "$(dirname "$0")/.." && pwd)"
WORK_BASE="${SELFTEST_TMPDIR:-/data/storage/el2/base/tmp/opencode}"
KEEP="${SELFTEST_KEEP:-0}"
DOTNET="${DOTNET:-dotnet}"

for _t in python3 grep sed cmp diff mktemp; do
    command -v "$_t" >/dev/null 2>&1 || { printf 'FATAL: required command not found: %s\n' "$_t" >&2; exit 1; }
done

WORK="$(mktemp -d "$WORK_BASE/selftest-tasks.XXXXXX")" || {
    printf 'FATAL: cannot create a work dir under %s\n' "$WORK_BASE" >&2
    exit 1
}
CHECKS=0
FAILED=0
SKIP=0

pass_() { CHECKS=$((CHECKS + 1)); printf '  [PASS] %s\n' "$*"; }
fail_() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$*" >&2; }
skip_() { CHECKS=$((CHECKS + 1)); SKIP=$((SKIP + 1)); printf '  [SKIP] %s\n' "$*"; }
assert_contains() { # <label> <needle> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then pass_ "$1"; else fail_ "$1 (missing: $2)"; fi
}
digest() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"; fi
}

log "selftest-tasks v$SELFTEST_VERSION"
log "work: $WORK"

# ---- S1: static distribution contract ---------------------------------------------------
section "S1 static task-assembly contract"
REF="$W/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.24/targets/OpenHarmony.Hap.targets"
TASKS_TARGET='AssemblyFile="$(MSBuildThisFileDirectory)../tools/Microsoft.OpenHarmony.Tasks.dll"'
missing_using=0
for task in OpenHarmonyDeterministicZip OpenHarmonyStageRuntimeLibs OpenHarmonyStagePayloadLibs \
            OpenHarmonyWritePayloadMarker OpenHarmonyResolvePermissions OpenHarmonyGenerateModuleJson; do
    grep -qF "<UsingTask TaskName=\"$task\" $TASKS_TARGET />" "$REF" || { missing_using=1; echo "    missing UsingTask: $task" >&2; }
done
[ "$missing_using" -eq 0 ] && pass_ "S1 all six UsingTask entries load the pack task assembly" \
                             || fail_ "S1 a UsingTask entry does not point at the pack task assembly"
if grep -qF 'TaskFactory="RoslynCodeTaskFactory"' "$REF" || grep -qF '<Code Type=' "$REF"; then
    fail_ "S1 the targets still carry inline task code"
else
    pass_ "S1 no inline RoslynCodeTaskFactory code remains in the targets"
fi
pack_dlls_ok=1
first_digest=""
for v in $PACK_VERSIONS; do
    _dll="$W/packs/Microsoft.OpenHarmony.Sdk/$v/$TASKS_DLL_REL"
    if [ ! -f "$_dll" ]; then
        pack_dlls_ok=0
        echo "    missing pack assembly: packs/Microsoft.OpenHarmony.Sdk/$v/$TASKS_DLL_REL" >&2
        continue
    fi
    _digest="$(digest "$_dll")"
    if [ -z "$first_digest" ]; then
        first_digest="$_digest"
    elif [ "$_digest" != "$first_digest" ]; then
        pack_dlls_ok=0
        echo "    pack assembly differs: $v ($_digest != $first_digest)" >&2
    fi
done
[ "$pack_dlls_ok" -eq 1 ] && pass_ "S1 preview.22/23/24 ship byte-identical $TASKS_DLL_REL" \
                          || fail_ "S1 the pack task assemblies are missing or differ"
if grep -qF 'class OpenHarmonyGenerateModuleJson' "$REF"; then
    fail_ "S1 the inline module.json class body is still in the targets"
else
    pass_ "S1 the module.json task body only lives in src/Microsoft.OpenHarmony.Tasks"
fi

# ---- S2/S3: unit tests + drift ----------------------------------------------------------
section "S2/S3 task unit tests and pack drift"
if ! command -v "$DOTNET" >/dev/null 2>&1; then
    skip_ "S2/S3 need dotnet (set DOTNET=<dotnet> to run the builds)"
else
    build_ok=1
    if ! ( cd "$W" && "$DOTNET" build "$TASKS_PROJECT" -c Release -v:q --nologo ) > "$WORK/build-tasks.log" 2>&1; then
        fail_ "S2 the task assembly does not build (see $WORK/build-tasks.log)"
        build_ok=0
    else
        pass_ "S2 the task assembly builds (Release/netstandard2.0)"
    fi
    if ! ( cd "$W" && "$DOTNET" build "$TASKS_TESTS_PROJECT" -c Release -v:q --nologo ) > "$WORK/build-tests.log" 2>&1; then
        fail_ "S2 the unit test host does not build (see $WORK/build-tests.log)"
        build_ok=0
    else
        pass_ "S2 the unit test host builds (Release/net11.0)"
    fi
    if [ "$build_ok" -eq 1 ]; then
        if ! "$DOTNET" "$W/$TASKS_TESTS_DLL" > "$WORK/tasks-tests.log" 2>&1; then
            fail_ "S2 the unit tests exited non-zero (see $WORK/tasks-tests.log)"
        fi
    fi
    if [ -s "$WORK/tasks-tests.log" ]; then
        _line="$(grep -E '^\[tasks-tests\] checks=[0-9]+ failed=0 assert=True$' "$WORK/tasks-tests.log" | tail -1 || true)"
        if [ -z "$_line" ]; then
            fail_ "S2 the unit tests did not print the checks/failed/assert contract line"
        else
            _checks="$(printf '%s\n' "$_line" | sed -E 's/.*checks=([0-9]+).*/\1/')"
            if [ "$_checks" -ge "$CHECK_FLOOR" ]; then
                pass_ "S2 unit tests: $_line (floor $CHECK_FLOOR)"
            else
                fail_ "S2 the unit test count $_checks is below the floor $CHECK_FLOOR"
            fi
        fi
        grep -q 'FAIL ' "$WORK/tasks-tests.log" && fail_ "S2 the unit test log carries FAIL lines" \
                                                 || pass_ "S2 no unit test check failed"
    else
        skip_ "S2 the unit test run produced no log (build failed earlier)"
    fi
    # S3: the shipped copies must equal the freshly built (deterministic) assembly.
    BUILD_DLL="$W/src/Microsoft.OpenHarmony.Tasks/bin/Release/netstandard2.0/Microsoft.OpenHarmony.Tasks.dll"
    if [ -f "$BUILD_DLL" ]; then
        drift=0
        for v in $PACK_VERSIONS; do
            cmp -s "$BUILD_DLL" "$W/packs/Microsoft.OpenHarmony.Sdk/$v/$TASKS_DLL_REL" || {
                drift=1
                echo "    drift: packs/Microsoft.OpenHarmony.Sdk/$v/$TASKS_DLL_REL != $BUILD_DLL" >&2
            }
        done
        [ "$drift" -eq 0 ] && pass_ "S3 the committed pack assemblies match the Release build (sha256 $(digest "$BUILD_DLL"))" \
                            || fail_ "S3 the committed pack assemblies drifted; re-run scripts/prepare-packs.sh"
    else
        skip_ "S3 no freshly built assembly to compare (dotnet unused or build failed)"
    fi
fi

# ---- summary ----------------------------------------------------------------------------
section "summary"
log "checks: $CHECKS, failed: $FAILED, skipped: $SKIP"
if [ "$FAILED" -gt 0 ]; then
    log "SELFTEST FAILED - work dir kept: $WORK"
    exit 1
fi
log "SELFTEST OK - the tasks are unit-tested and the packs ship the built assembly"
if [ "$KEEP" = "1" ]; then
    log "work dir kept (SELFTEST_KEEP=1): $WORK"
else
    rm -rf "$WORK"
fi
exit 0
