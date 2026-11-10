#!/bin/sh
# selftest-sdk-defaults.sh - shipped-behavior gate for the OpenHarmony SDK pack defaults.
#
# Evaluates a real net11.0-openharmony20.0 executable with the INSTALLED Microsoft.OpenHarmony.Sdk
# (the pack the workload resolver imports) and asserts:
#   - UseAppHost=false, SelfContained=true, RuntimeIdentifier=openharmony-arm64
#   - GenerateDependencyFile=false, CopyLocalLockFileAssemblies=true
#   - EnableAppHostPackDownload=false, AllowSelfContainedWithoutRuntimeIdentifier=true
#   - SupportedOSPlatformVersion=20.0, TargetPlatformSupported=true
#   - PublishReadyToRun / PublishAot are not enabled by the platform targets
#   - the shipped manifest declares no Crossgen2 pack (the current JIT/self-contained stack does
#     not publish one; KnownCrossgen2Pack is deferred until R2R is enabled)
#
# This is the shipped-behavior complement to the static text pins in selftest-hap-targets.sh.
#
# Env: DOTNET=<dotnet>            SDK with the OpenHarmony workload installed
#      SELFTEST_TMPDIR=<dir>      work dir base
#      SELFTEST_KEEP=1            keep the work dir
# Exit: 0 = all checks passed (or [SKIP] when no workload is installed); 1 = a check failed.
set -u

SELFTEST_VERSION="1 (2026-11-10)"
log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

W="$(cd "$(dirname "$0")/.." && pwd)"
DOTNET="${DOTNET:-dotnet}"
WORK_BASE="${SELFTEST_TMPDIR:-/data/storage/el2/base/tmp/opencode}"
KEEP="${SELFTEST_KEEP:-0}"

for _t in python3 grep find mktemp; do
    command -v "$_t" >/dev/null 2>&1 || { printf 'FATAL: required command not found: %s\n' "$_t" >&2; exit 1; }
done

DOTNET_BIN="$(command -v "$DOTNET" 2>/dev/null || true)"
[ -n "$DOTNET_BIN" ] || { printf 'FATAL: dotnet not found: %s\n' "$DOTNET" >&2; exit 1; }
DOTNET_ROOT_DIR="${DOTNET_ROOT:-$(dirname "$DOTNET_BIN")}"

WORK="$(mktemp -d "$WORK_BASE/selftest-sdk-defaults.XXXXXX")" || exit 1
CHECKS=0
FAILED=0
SKIP=0
pass_() { CHECKS=$((CHECKS + 1)); printf '  [PASS] %s\n' "$*"; }
fail_() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$*" >&2; }
skip_() { CHECKS=$((CHECKS + 1)); SKIP=$((SKIP + 1)); printf '  [SKIP] %s\n' "$*"; }
cleanup() {
    if [ "$KEEP" = "1" ] || [ "$FAILED" -ne 0 ]; then printf 'work dir kept: %s\n' "$WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

log "selftest-sdk-defaults v$SELFTEST_VERSION"
log "work: $WORK"

MANIFEST="$(find "$DOTNET_ROOT_DIR/sdk-manifests" -path '*/microsoft.net.sdk.openharmony/WorkloadManifest.json' 2>/dev/null | sort | tail -1)"
if [ -z "$MANIFEST" ]; then
    section "S0 workload"
    skip_ "S0 the OpenHarmony workload is installed (no sdk-manifests entry under $DOTNET_ROOT_DIR)"
    printf '\n=== summary ===\n[%s] checks: %s, failed: %s, skipped: %s\n' "$(date '+%H:%M:%S')" "$CHECKS" "$FAILED" "$SKIP"
    exit 0
fi
VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$MANIFEST")"
SDK_TARGETS="$DOTNET_ROOT_DIR/packs/Microsoft.OpenHarmony.Sdk/$VERSION/Sdk/Sdk.targets"
section "S0 workload"
pass_ "S0 the installed manifest is $MANIFEST"
[ -f "$SDK_TARGETS" ] && pass_ "S0 the installed Sdk.targets is $SDK_TARGETS" || fail_ "S0 the installed Sdk.targets is missing: $SDK_TARGETS"

section "S1 project evaluation"
FIXTURE="$WORK/probe"
mkdir -p "$FIXTURE"
cat > "$FIXTURE/global.json" <<'EOF'
{
  "sdk": {
    "paths": [".dotnet", "$host$"]
  }
}
EOF
cat > "$FIXTURE/probe.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net11.0-openharmony20.0</TargetFramework>
    <OutputType>Exe</OutputType>
    <Nullable>enable</Nullable>
  </PropertyGroup>
</Project>
EOF
JSON="$WORK/properties.json"
if "$DOTNET_BIN" msbuild "$FIXTURE/probe.csproj" -nologo \
    -getProperty:UseAppHost,SelfContained,RuntimeIdentifier,GenerateDependencyFile,CopyLocalLockFileAssemblies,EnableAppHostPackDownload,AllowSelfContainedWithoutRuntimeIdentifier,SupportedOSPlatformVersion,PublishReadyToRun,PublishAot,TargetPlatformSupported \
    > "$JSON" 2>"$WORK/evaluate.log"; then
    pass_ "S1 dotnet msbuild evaluates the OpenHarmony TFM"
else
    fail_ "S1 dotnet msbuild evaluates the OpenHarmony TFM (see $WORK/evaluate.log)"
fi

get() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Properties"].get(sys.argv[2], ""))' "$JSON" "$1" 2>/dev/null || true
}
expect() { # <property> <expected>
    _got="$(get "$1")"
    if [ "$_got" = "$2" ]; then pass_ "S1 $1=$2"; else fail_ "S1 $1 expected '$2', got '$_got'"; fi
}
expect UseAppHost false
expect SelfContained true
expect RuntimeIdentifier openharmony-arm64
expect GenerateDependencyFile false
expect CopyLocalLockFileAssemblies true
expect EnableAppHostPackDownload false
expect AllowSelfContainedWithoutRuntimeIdentifier true
expect SupportedOSPlatformVersion 20.0
expect TargetPlatformSupported true
case "$(get PublishReadyToRun)" in true) fail_ "S1 PublishReadyToRun must stay off by default" ;; *) pass_ "S1 PublishReadyToRun is not enabled" ;; esac
case "$(get PublishAot)" in true) fail_ "S1 PublishAot must stay off by default" ;; *) pass_ "S1 PublishAot is not enabled" ;; esac

section "S2 KnownCrossgen2Pack decision"
if [ -f "$SDK_TARGETS" ] && grep -q 'UseAppHost' "$SDK_TARGETS" && grep -q 'SelfContained' "$SDK_TARGETS"; then
    pass_ "S2 the defaults come from the installed Sdk.targets"
else
    fail_ "S2 the defaults come from the installed Sdk.targets"
fi
if grep -q 'KnownCrossgen2Pack' "$SDK_TARGETS" 2>/dev/null; then
    fail_ "S2 Sdk.targets declares KnownCrossgen2Pack while R2R is off"
else
    pass_ "S2 Sdk.targets declares no KnownCrossgen2Pack"
fi
if grep -qE '<PublishReadyToRun>[[:space:]]*true|PublishReadyToRun[[:space:]]*=[[:space:]]*true' "$SDK_TARGETS" 2>/dev/null; then
    fail_ "S2 Sdk.targets enables ReadyToRun"
else
    pass_ "S2 Sdk.targets does not enable ReadyToRun"
fi
if grep -qE '<PublishAot>[[:space:]]*true|PublishAot[[:space:]]*=[[:space:]]*true' "$SDK_TARGETS" 2>/dev/null; then
    fail_ "S2 Sdk.targets enables NativeAOT"
else
    pass_ "S2 Sdk.targets does not enable NativeAOT"
fi
if python3 - "$MANIFEST" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
packs=list(d.get('packs',{}).keys())
bad=[p for p in packs if 'crossgen2' in p.lower()]
print('crossgen2 packs:', bad)
sys.exit(1 if bad else 0)
PY
then
    pass_ "S2 the manifest declares no Crossgen2 pack"
else
    fail_ "S2 the manifest declares no Crossgen2 pack"
fi

printf '\n=== summary ===\n'
printf '[%s] checks: %s, failed: %s, skipped: %s\n' "$(date '+%H:%M:%S')" "$CHECKS" "$FAILED" "$SKIP"
if [ "$FAILED" -ne 0 ]; then
    printf '[%s] SELFTEST FAILED\n' "$(date '+%H:%M:%S')" >&2
    exit 1
fi
printf '[%s] [sdk-defaults] checks=%s failed=0 assert=True\n' "$(date '+%H:%M:%S')" "$CHECKS"
exit 0
