#!/bin/sh
# selftest-repo-hygiene.sh - repeatable selftest for the build-input hygiene gates (audit V3).
#
#   T1 clean       scripts/check-no-absolute-paths.sh accepts the current tree
#   T2 home path   a build fixture carrying /storage/Users/<user>/... is rejected and named
#   T3 linux home  a fixture carrying /home/<user>/springsources/... is rejected
#   T4 windows     a fixture carrying C:\Users\... is rejected
#   T5 rel roots   test/Directory.Build.props chains the repository props and defines the
#                  sibling-repo relative MauiSliceDir default (no absolute fallback)
#   T6 test projs  both suite projects reference the first-party assemblies through
#                  ProjectReferences, carry Exists fast-fail errors and no absolute source path
#   T7 CI wiring   the interaction/pixel workflows pass MAUI_SLICE_DIR and run the path gate
#
# The fixtures never touch the repository: the gate runs in explicit-file mode on scratch copies.
#
# Env: SELFTEST_TMPDIR=<dir>  work dir base (default: the approved opencode tmp dir)
#      SELFTEST_KEEP=1       keep the work dir even when all checks pass
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="1 (2026-09-25)"

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

W="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$W/scripts/check-no-absolute-paths.sh"
WORK_BASE="${SELFTEST_TMPDIR:-/data/storage/el2/base/tmp/opencode}"
KEEP="${SELFTEST_KEEP:-0}"

[ -f "$GATE" ] || { printf 'FATAL: check-no-absolute-paths.sh not found: %s\n' "$GATE" >&2; exit 1; }
for _t in grep sed mktemp; do
    command -v "$_t" >/dev/null 2>&1 || { printf 'FATAL: required command not found: %s\n' "$_t" >&2; exit 1; }
done

WORK="$(mktemp -d "$WORK_BASE/selftest-repo-hygiene.XXXXXX")" || {
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
    if grep -qF -- "$2" "$3" 2>/dev/null; then pass_ "$1"; else fail_ "$1 (missing: $2)"; fi
}

log "selftest-repo-hygiene v$SELFTEST_VERSION"
log "work: $WORK"

# ---- T1: the repository is clean -------------------------------------------------------
section "T1 repository build inputs"
sh "$GATE" > "$WORK/T1.log" 2>&1
assert_rc 0 $? "T1 check-no-absolute-paths.sh accepts the repository"
assert_contains "T1 reports the scanned file count" "absolute-path check OK" "$WORK/T1.log"

# ---- T2/T3/T4: the gate rejects home paths --------------------------------------------
section "T2/T3/T4 home-path rejection"
printf '<Project>\n  <PropertyGroup>\n    <MauiSliceDir>/storage/Users/someone/springsources/maui-ohos/src/Core/src/Platform/OpenHarmony</MauiSliceDir>\n  </PropertyGroup>\n</Project>\n' > "$WORK/abs-storage.csproj"
sh "$GATE" "$WORK/abs-storage.csproj" > "$WORK/T2.log" 2>&1
assert_rc 1 $? "T2 a /storage/Users path is rejected"
assert_contains "T2 names the offending file" "abs-storage.csproj" "$WORK/T2.log"

printf '<Project>\n  <PropertyGroup>\n    <MauiSliceDir>/home/someone/springsources/maui-ohos/src</MauiSliceDir>\n  </PropertyGroup>\n</Project>\n' > "$WORK/abs-home.csproj"
sh "$GATE" "$WORK/abs-home.csproj" > "$WORK/T3.log" 2>&1
assert_rc 1 $? "T3 a /home/.../springsources path is rejected"

printf '<Project>\n  <PropertyGroup>\n    <MauiSliceDir>C:\\Users\\someone\\springsources\\maui-ohos</MauiSliceDir>\n  </PropertyGroup>\n</Project>\n' > "$WORK/abs-win.csproj"
sh "$GATE" "$WORK/abs-win.csproj" > "$WORK/T4.log" 2>&1
assert_rc 1 $? "T4 a C:\\Users\\... path is rejected"

# ---- T5: the shared test roots ----------------------------------------------------------
section "T5 test/Directory.Build.props"
if [ -f "$W/test/Directory.Build.props" ]; then
    pass_ "T5 test/Directory.Build.props exists"
    assert_contains "T5 chains the repository Directory.Build.props" "GetPathOfFileAbove('Directory.Build.props'" "$W/test/Directory.Build.props"
    assert_contains "T5 defines OhosWorkloadRoot relatively" "NormalizeDirectory('\$(MSBuildThisFileDirectory)', '..')" "$W/test/Directory.Build.props"
    assert_contains "T5 defaults MauiSliceDir to the sibling checkout" "'..', 'maui-ohos', 'src', 'Core', 'src', 'Platform', 'OpenHarmony'" "$W/test/Directory.Build.props"
    if grep -qE '/storage/Users|/home/|C:\\\\Users' "$W/test/Directory.Build.props"; then
        fail_ "T5 test/Directory.Build.props carries an absolute home path"
    else
        pass_ "T5 test/Directory.Build.props carries no absolute home path"
    fi
else
    fail_ "T5 test/Directory.Build.props is missing"
fi

# ---- T6: the suite projects -------------------------------------------------------------
section "T6 suite projects"
for proj in test/headless-render/headless-render.csproj test/maui-platform-verify/verify.csproj; do
    if [ ! -f "$W/$proj" ]; then
        fail_ "T6 $proj is missing"
        continue
    fi
    assert_contains "T6 $proj uses the shared HostingProject" '$(HostingProject)' "$W/$proj"
    assert_contains "T6 $proj uses the shared GraphicsProject" '$(GraphicsProject)' "$W/$proj"
    assert_contains "T6 $proj fails fast on a missing slice" "The maui-ohos slice directory" "$W/$proj"
    if grep -qE '/storage/Users|/home/|C:\\\\Users' "$W/$proj"; then
        fail_ "T6 $proj carries an absolute home path"
    else
        pass_ "T6 $proj carries no absolute home path"
    fi
done

# ---- T7: CI wiring ----------------------------------------------------------------------
section "T7 workflow wiring"
for wf in .github/workflows/interaction-regression.yml .github/workflows/pixel-regression.yml; do
    if [ ! -f "$W/$wf" ]; then
        fail_ "T7 $wf is missing"
        continue
    fi
    assert_contains "T7 $wf runs the path gate" "sh scripts/check-no-absolute-paths.sh" "$W/$wf"
    assert_contains "T7 $wf passes MAUI_SLICE_DIR" "MAUI_SLICE_DIR:" "$W/$wf"
    if grep -q 'HOSTING_DLL:' "$W/$wf"; then
        fail_ "T7 $wf still requires HOSTING_DLL instead of the ProjectReference"
    else
        pass_ "T7 $wf no longer requires HOSTING_DLL"
    fi
done

# ---- summary ---------------------------------------------------------------------------
section "summary"
log "checks: $CHECKS, failed: $FAILED"
if [ "$FAILED" -gt 0 ]; then
    log "SELFTEST FAILED - work dir kept: $WORK"
    exit 1
fi
log "SELFTEST OK - build inputs are relative, the path gate rejects home paths and the workflows wire it"
if [ "$KEEP" = "1" ]; then
    log "work dir kept (SELFTEST_KEEP=1): $WORK"
else
    rm -rf "$WORK"
fi
exit 0
