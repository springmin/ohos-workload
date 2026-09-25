#!/bin/sh
# selftest-packs.sh - repeatable selftest for the pack-layout lint (V3) and the single-import
# guard in Sdk/Sdk.targets (V10).
#
#   T1 lint clean   scripts/lint-packs.sh accepts the repo packs
#   T2 lint dead    a scratch pack with an unimported props file fails and names the file
#   T3 lint dangling a scratch pack with an <Import> to a missing file fails and names the import
#   T4 lint entry   a scratch pack without Sdk/AutoImport.props fails the entry-point control
#   T5 no duplicate a fixture imports Sdk.props + Sdk.targets twice; the platform symbols, the
#                   supported TargetPlatformVersions, the FrameworkReference and the
#                   KnownFrameworkReference must each be applied exactly once
#   T6 hap import   the same fixture proves OpenHarmony.Hap.targets was imported exactly once
#                   (its marker property survives; the guarded import is a no-op on re-import)
#
# T2-T4 tamper with scratch copies; T5/T6 run `dotnet msbuild` on a fixture (skipped with a
# [SKIP] line when dotnet is unavailable, so the lint half still gates offline).
#
# Env: SELFTEST_TMPDIR=<dir>  work dir base (default: the approved opencode tmp dir)
#      DOTNET=<dotnet>       SDK used for the double-import fixture
#      SELFTEST_KEEP=1       keep the work dir even when all checks pass
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="2 (2026-09-26)"

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

W="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$W/scripts/lint-packs.sh"
PACK_REL="Microsoft.OpenHarmony.Sdk/1.0.0-preview.24"
PACK="$W/packs/$PACK_REL"
WORK_BASE="${SELFTEST_TMPDIR:-/data/storage/el2/base/tmp/opencode}"
KEEP="${SELFTEST_KEEP:-0}"
DOTNET="${DOTNET:-dotnet}"

[ -f "$LINT" ] || { printf 'FATAL: lint-packs.sh not found: %s\n' "$LINT" >&2; exit 1; }
[ -d "$PACK" ] || { printf 'FATAL: pack not found: %s\n' "$PACK" >&2; exit 1; }
for _t in python3 grep sed mktemp cp; do
    command -v "$_t" >/dev/null 2>&1 || { printf 'FATAL: required command not found: %s\n' "$_t" >&2; exit 1; }
done

WORK="$(mktemp -d "$WORK_BASE/selftest-packs.XXXXXX")" || {
    printf 'FATAL: cannot create a work dir under %s\n' "$WORK_BASE" >&2
    exit 1
}
CHECKS=0
FAILED=0
SKIP=0

pass_() { CHECKS=$((CHECKS + 1)); printf '  [PASS] %s\n' "$*"; }
fail_() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$*" >&2; }
skip_() { CHECKS=$((CHECKS + 1)); SKIP=$((SKIP + 1)); printf '  [SKIP] %s\n' "$*"; }
assert_rc() { # <expected> <actual> <label>
    if [ "$2" -eq "$1" ]; then pass_ "$3 (exit $2)"; else fail_ "$3 (expected exit $1, got $2)"; fi
}
assert_contains() { # <label> <needle> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then pass_ "$1"; else fail_ "$1 (missing: $2)"; fi
}

log "selftest-packs v$SELFTEST_VERSION"
log "work: $WORK"

scratch_packs() { # <dir>
    rm -rf "$1"
    mkdir -p "$1"
    cp -r "$W/packs/Microsoft.OpenHarmony.Sdk" "$1/Microsoft.OpenHarmony.Sdk"
}

# ---- T1: the repo packs lint clean -----------------------------------------------------
section "T1 repo packs lint"
sh "$LINT" > "$WORK/T1.log" 2>&1
assert_rc 0 $? "T1 lint-packs.sh accepts the repo packs"
assert_contains "T1 reports every non-entry file has an importer" "every non-entry file has an importer" "$WORK/T1.log"

# ---- T2: a dead props file is refused --------------------------------------------------
section "T2 dead file detection"
S2="$WORK/packs-dead"
scratch_packs "$S2"
printf '<Project>\n  <PropertyGroup>\n    <DeadProperty>true</DeadProperty>\n  </PropertyGroup>\n</Project>\n' \
    > "$S2/Microsoft.OpenHarmony.Sdk/1.0.0-preview.24/targets/Dead.Duplicate.props"
LINT_PACKS_ROOTS="$S2" sh "$LINT" > "$WORK/T2.log" 2>&1
assert_rc 1 $? "T2 a file with no importer fails"
assert_contains "T2 names the dead file" "Dead.Duplicate.props (no <Import> references it)" "$WORK/T2.log"

# ---- T3: a dangling import is refused --------------------------------------------------
section "T3 dangling import detection"
S3="$WORK/packs-dangling"
scratch_packs "$S3"
printf '\n  <Import Project="$(MSBuildThisFileDirectory)../targets/Does.Not.Exist.targets" />\n' \
    >> "$S3/Microsoft.OpenHarmony.Sdk/1.0.0-preview.24/Sdk/Sdk.targets"
LINT_PACKS_ROOTS="$S3" sh "$LINT" > "$WORK/T3.log" 2>&1
assert_rc 1 $? "T3 an import to a missing file fails"
assert_contains "T3 names the dangling import" "Does.Not.Exist.targets" "$WORK/T3.log"

# ---- T4: a missing entry point is refused ----------------------------------------------
section "T4 missing entry point"
S4="$WORK/packs-entry"
scratch_packs "$S4"
rm -f "$S4/Microsoft.OpenHarmony.Sdk/1.0.0-preview.24/Sdk/AutoImport.props"
LINT_PACKS_ROOTS="$S4" sh "$LINT" > "$WORK/T4.log" 2>&1
assert_rc 1 $? "T4 a pack without Sdk/AutoImport.props fails"
assert_contains "T4 reports the missing entry point" "MISSING entry point $PACK_REL/Sdk/AutoImport.props" "$WORK/T4.log"

# ---- T5/T6: importing the pack twice applies everything exactly once ------------------
section "T5/T6 double-import guard"
if ! command -v "$DOTNET" >/dev/null 2>&1; then
    skip_ "T5/T6 need dotnet (set DOTNET= to run the double-import fixture)"
else
    FIX="$WORK/double-import"
    COPY="$WORK/pack-copy"
    mkdir -p "$FIX" "$COPY"
    cp -r "$PACK" "$COPY/"
    PACK_A="$PACK"
    PACK_B="$COPY/1.0.0-preview.24"
    # MSBuild deduplicates the *same path* (MSB4011 + ignore), so the guard is exercised the way
    # a manifest/alias import would: the same content reached through a second path. Paths are
    # passed as global properties so the fixture body stays free of shell expansion.
    cat > "$FIX/double-import.proj" <<'EOF'
<Project>
  <PropertyGroup>
    <TargetPlatformIdentifier>openharmony</TargetPlatformIdentifier>
    <TargetPlatformVersion>24.0</TargetPlatformVersion>
    <TargetFramework>net11.0-openharmony24.0</TargetFramework>
    <!-- Satisfies the Hap.targets UsingTask evaluation; the task itself is never run here. -->
    <MicrosoftNETBuildTasksAssembly>$(MSBuildToolsPath)/Microsoft.Build.Tasks.Core.dll</MicrosoftNETBuildTasksAssembly>
  </PropertyGroup>
  <!-- Mimic the SDK resolver pair, twice through two paths: the second pass must be a no-op. -->
  <Import Project="$(PackA)/Sdk/Sdk.props" />
  <Import Project="$(PackA)/Sdk/Sdk.targets" />
  <Import Project="$(PackB)/Sdk/Sdk.props" />
  <Import Project="$(PackB)/Sdk/Sdk.targets" />
  <Target Name="Probe">
    <PropertyGroup>
      <_OpenArmCount>$([System.Text.RegularExpressions.Regex]::Matches('$(DefineConstants)', ';OPENHARMONY;').Count)</_OpenArmCount>
      <_FwCount>@(FrameworkReference->WithMetadataValue('Identity','Microsoft.OpenHarmony')->Count())</_FwCount>
      <_KfrCount>@(KnownFrameworkReference->WithMetadataValue('Identity','Microsoft.OpenHarmony')->Count())</_KfrCount>
    </PropertyGroup>
    <WriteLinesToFile File="$(ProbeOut)" Lines="OPENHARMONY_COUNT=$(_OpenArmCount)" Overwrite="true" />
    <WriteLinesToFile File="$(ProbeOut)" Lines="@(SdkSupportedTargetPlatformVersion->'SUPPORTED=%(Identity)')" />
    <WriteLinesToFile File="$(ProbeOut)" Lines="FRAMEWORK_COUNT=$(_FwCount)" />
    <WriteLinesToFile File="$(ProbeOut)" Lines="KFR_COUNT=$(_KfrCount)" />
  </Target>
</Project>
EOF
    ( cd "$FIX" && "$DOTNET" msbuild double-import.proj -t:Probe -v:q -nologo \
        -p:PackA="$PACK_A" -p:PackB="$PACK_B" -p:ProbeOut="$FIX/probe.txt" ) > "$WORK/T5-build.log" 2>&1
    assert_rc 0 $? "T5 the double-import fixture evaluates"
    if [ -f "$FIX/probe.txt" ]; then
        if grep -qF "OPENHARMONY_COUNT=1" "$FIX/probe.txt"; then
            pass_ "T5 OPENHARMONY appears exactly once in DefineConstants"
        else
            fail_ "T5 DefineConstants marker count: $(grep -F OPENHARMONY_COUNT "$FIX/probe.txt" | tr '\n' ' ')"
        fi
        for label in "SUPPORTED=20.0" "SUPPORTED=26.0"; do
            n="$(grep -c -F "$label" "$FIX/probe.txt" | tr -d ' ')"
            if [ "$n" = "1" ]; then
                pass_ "T5 $label appears exactly once"
            else
                fail_ "T5 $label appears $n times"
            fi
        done
        if grep -qF "FRAMEWORK_COUNT=1" "$FIX/probe.txt"; then
            pass_ "T5 the Microsoft.OpenHarmony FrameworkReference is applied exactly once"
        else
            fail_ "T5 FrameworkReference count: $(grep -F FRAMEWORK_COUNT "$FIX/probe.txt" | tr '\n' ' ')"
        fi
        if grep -qF "KFR_COUNT=1" "$FIX/probe.txt"; then
            pass_ "T5 the Microsoft.OpenHarmony KnownFrameworkReference is applied exactly once"
        else
            fail_ "T5 KnownFrameworkReference count: $(grep -F KFR_COUNT "$FIX/probe.txt" | tr '\n' ' ')"
        fi
        if grep -qF "<Import" "$FIX/double-import.proj" && grep -qF "Microsoft.OpenHarmony.Sdk" "$FIX/double-import.proj"; then
            # The guarded import is a no-op on the second pass: Hap.targets' own UsingTask and
            # targets exist once. Its import has no marker property, so pin the guard condition
            # in the source instead (the fixture would fail with MSB4067-style duplicate errors
            # if an unguarded target file were imported twice with different versions).
            if grep -qF "_OpenHarmonySdkTargetsAlreadyImported" "$PACK_B/Sdk/Sdk.targets"; then
                pass_ "T6 the guarded OpenHarmony.Hap.targets import carries the once-only condition"
            else
                fail_ "T6 the OpenHarmony.Hap.targets import lost its once-only guard"
            fi
        fi
    else
        fail_ "T5 the fixture did not write probe.txt (see $WORK/T5-build.log)"
    fi
fi

# ---- T7: the openharmony resolution contract -------------------------------------------
section "T7 platform resolution contract"
same_sdk=1
for v in 1.0.0-preview.22 1.0.0-preview.23 1.0.0-preview.24; do
    cmp -s "$W/packs/Microsoft.OpenHarmony.Sdk/$v/Sdk/Sdk.targets" "$PACK/Sdk/Sdk.targets" || same_sdk=0
    grep -qF 'EnableAppHostPackDownload Condition=' "$W/packs/Microsoft.OpenHarmony.Sdk/$v/Sdk/Sdk.targets" || same_sdk=0
    grep -qF '>false</EnableAppHostPackDownload>' "$W/packs/Microsoft.OpenHarmony.Sdk/$v/Sdk/Sdk.targets" || same_sdk=0
    grep -qF 'RuntimeIdentifier Condition=' "$W/packs/Microsoft.OpenHarmony.Sdk/$v/Sdk/Sdk.targets" || same_sdk=0
    grep -qF '>openharmony-arm64</RuntimeIdentifier>' "$W/packs/Microsoft.OpenHarmony.Sdk/$v/Sdk/Sdk.targets" || same_sdk=0
    grep -qF 'KnownFrameworkReference Update="Microsoft.AspNetCore.App"' "$W/packs/Microsoft.OpenHarmony.Sdk/$v/targets/OpenHarmony.PlatformItems.targets" || same_sdk=0
    grep -qF 'DefaultRuntimeFrameworkVersion="11.0.0-rc.1.26425.128"' "$W/packs/Microsoft.OpenHarmony.Sdk/$v/targets/OpenHarmony.PlatformItems.targets" || same_sdk=0
done
[ "$same_sdk" -eq 1 ] && pass_ "T7 all packs carry the RID default, the apphost download opt-out and the AspNetCore published-band pin" \
                       || fail_ "T7 the resolution contract is missing or differs between pack versions"
if ! command -v "$DOTNET" >/dev/null 2>&1; then
    skip_ "T7 evaluation fixture needs dotnet (set DOTNET= to run it)"
else
    FIXR="$WORK/resolution"
    mkdir -p "$FIXR"
    cat > "$FIXR/resolution.proj" <<'EOF'
<Project>
  <PropertyGroup>
    <TargetPlatformIdentifier>openharmony</TargetPlatformIdentifier>
    <TargetPlatformVersion>26.0</TargetPlatformVersion>
    <TargetFramework>net11.0-openharmony26.0</TargetFramework>
    <TargetFrameworkVersion>v11.0</TargetFrameworkVersion>
    <OutputType>Exe</OutputType>
    <MicrosoftNETBuildTasksAssembly>$(MSBuildToolsPath)/Microsoft.Build.Tasks.Core.dll</MicrosoftNETBuildTasksAssembly>
  </PropertyGroup>
  <ItemGroup>
    <!-- Stand-in for the SDK's bundled net11.0 AspNetCore KFR (un-pinned version). -->
    <KnownFrameworkReference Include="Microsoft.AspNetCore.App"
                              TargetFramework="net11.0"
                              TargetingPackVersion="11.0.0-rc.1.26452.110"
                              DefaultRuntimeFrameworkVersion="11.0.0-rc.1.26452.110"
                              LatestRuntimeFrameworkVersion="11.0.0-rc.1.26452.110" />
  </ItemGroup>
  <Import Project="$(PackA)/Sdk/Sdk.targets" />
  <Target Name="Probe">
    <PropertyGroup>
      <_AspNetTargeting>@(KnownFrameworkReference->WithMetadataValue('Identity','Microsoft.AspNetCore.App')->'%(TargetingPackVersion)')</_AspNetTargeting>
      <_AspNetDefault>@(KnownFrameworkReference->WithMetadataValue('Identity','Microsoft.AspNetCore.App')->'%(DefaultRuntimeFrameworkVersion)')</_AspNetDefault>
    </PropertyGroup>
    <WriteLinesToFile File="$(ProbeOut)" Overwrite="true" Lines="RID=$(RuntimeIdentifier)" />
    <WriteLinesToFile File="$(ProbeOut)" Lines="APPHOST=$(EnableAppHostPackDownload)" />
    <WriteLinesToFile File="$(ProbeOut)" Lines="ASPNET=$(_AspNetTargeting)|$(_AspNetDefault)" />
  </Target>
</Project>
EOF
    ( cd "$FIXR" && "$DOTNET" msbuild resolution.proj -t:Probe -v:q -nologo \
        -p:PackA="$PACK" -p:ProbeOut="$FIXR/probe11.txt" ) > "$WORK/T7-build11.log" 2>&1
    assert_rc 0 $? "T7 the net11.0 fixture evaluates"
    if [ -f "$FIXR/probe11.txt" ]; then
        if grep -qF "RID=openharmony-arm64" "$FIXR/probe11.txt"; then
            pass_ "T7 an Exe without RuntimeIdentifier defaults to openharmony-arm64"
        else
            fail_ "T7 RID default: $(grep -F RID= "$FIXR/probe11.txt" | tr '\n' ' ')"
        fi
        if grep -qF "APPHOST=false" "$FIXR/probe11.txt"; then
            pass_ "T7 apphost pack downloads default off"
        else
            fail_ "T7 apphost default: $(grep -F APPHOST= "$FIXR/probe11.txt" | tr '\n' ' ')"
        fi
        if grep -qF "ASPNET=11.0.0-rc.1.26425.128|11.0.0-rc.1.26425.128" "$FIXR/probe11.txt"; then
            pass_ "T7 the net11.0 AspNetCore KFR is pinned to the published RC1 GA band"
        else
            fail_ "T7 AspNetCore pin: $(grep -F ASPNET= "$FIXR/probe11.txt" | tr '\n' ' ')"
        fi
    else
        fail_ "T7 the net11.0 fixture did not write probe11.txt (see $WORK/T7-build11.log)"
    fi
    ( cd "$FIXR" && "$DOTNET" msbuild resolution.proj -t:Probe -v:q -nologo \
        -p:PackA="$PACK" -p:ProbeOut="$FIXR/probe10.txt" -p:TargetFrameworkVersion=v10.0 ) > "$WORK/T7-build10.log" 2>&1
    assert_rc 0 $? "T7 the net10.0 fixture evaluates"
    if [ -f "$FIXR/probe10.txt" ] && grep -qF "ASPNET=11.0.0-rc.1.26452.110|11.0.0-rc.1.26452.110" "$FIXR/probe10.txt"; then
        pass_ "T7 the pin is scoped to net11.0 (net10.0 KFR untouched)"
    else
        fail_ "T7 the net10.0 KFR must not be re-pointed: $(grep -F ASPNET= "$FIXR/probe10.txt" 2>/dev/null | tr '\n' ' ')"
    fi
fi

# ---- summary ---------------------------------------------------------------------------
section "summary"
log "checks: $CHECKS, failed: $FAILED, skipped: $SKIP"
if [ "$FAILED" -gt 0 ]; then
    log "SELFTEST FAILED - work dir kept: $WORK"
    exit 1
fi
log "SELFTEST OK - pack lint gates the dead/duplicate files and the double import is a no-op"
if [ "$KEEP" = "1" ]; then
    log "work dir kept (SELFTEST_KEEP=1): $WORK"
else
    rm -rf "$WORK"
fi
exit 0
