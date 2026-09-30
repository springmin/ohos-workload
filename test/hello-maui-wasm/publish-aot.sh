#!/bin/sh
# publish-aot.sh - NativeAOT publish of test/hello-maui-wasm (B2: MAUI WebView + Blazor WASM)
# into installable haps.
#
# Same rc.2 recipe as test/hello-maui-app/publish-aot.sh (see that file and
# docs/openharmony-hap-packaging.md "NativeAOT HAP variant"), with the B2 site staged into the
# payload: -p:OpenHarmonyWasmSiteDir=<publish/wwwroot of the Blazor WebAssembly app> makes the
# pack target _OpenHarmonyStageWasmSite copy the site under <payload>/wasmsite, which
# App.cs registers as the WebView's wasm site root.
#
# Usage: [WASM_SITE=<dir>] sh test/hello-maui-wasm/publish-aot.sh
# Env:
#   WASM_SITE      published Blazor WebAssembly wwwroot (default
#                  test/hello-blazorwasm/out/publish/wwwroot; run test/hello-blazorwasm/run-smoke.sh first)
#   AOT_WORKDIR    scratch dir for the log + offline feed (default /data/storage/el2/base/tmp/opencode/w9a/aot)
#   OHOS_SDK / OpenHarmonySdkRoot / OHOS_SDK_ROOT   SDK root holding toolchains/
#   OHOS_AOT_HOOKS optional CustomAfterMicrosoftCommonTargets file (rc.2 Exec quirk, see the
#                  local runbook); OhosTaskHostOverride=true is exported with it
#   MAUI_SLICE_DIR platform slice sources (default ../maui-ohos/src/Core/src/Platform/OpenHarmony)
#   WASM_ABC       ArkTS shell abc for this app's bundle name. The device resolves the ability
#                  entry as <bundleName>/entry/ets/entryability/EntryAbility against the abc
#                  record names, and the pack's prebuilt modules.ui.abc carries
#                  com.example.hellomauiapp; an app with another bundle must compile the shell
#                  with ARKTS_SHELL_BUNDLE_NAME=<bundle> (scripts/build-arkts-shell.sh) and pass
#                  that abc here (OpenHarmonyArktsModulesAbc). Unset -> the pack's prebuilt abc.
#   HOSTING_DLL / OPENHARMONY_GRAPHICS_DLL  pinned first-party assemblies (else ProjectReference)
#
# Memory discipline (this box OOMs under parallel builds): refuse to start below 2 GB
# MemAvailable, wait out heavy builds for up to 30 min. One publish at a time. AOT_SKIP_GUARD=1
# skips only the heavy-build wait (a known-idle box / a stale process from another session) and
# keeps the memory gate.
set -u

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

W="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="${AOT_WORKDIR:-/data/storage/el2/base/tmp/opencode/w9a/aot}"
LOG="$BASE/publish-aot.log"
TFM="${AOT_TFM:-net11.0-openharmony26.0}"
RID=openharmony-arm64
DOTNET="${DOTNET:-$HOME/.dotnet.rc2-fix/dotnet}"
SLICE="${MAUI_SLICE_DIR:-$W/../maui-ohos/src/Core/src/Platform/OpenHarmony}"
SITE="${WASM_SITE:-$W/test/hello-blazorwasm/out/publish/wwwroot}"
PUB="$W/test/hello-maui-wasm/bin/Release/$TFM/$RID/publish"

[ -f "$W/test/hello-maui-wasm/hello-maui-wasm.csproj" ] || die "run from the ohos-workload checkout (project not found: $W/test/hello-maui-wasm)"
[ -d "$SLICE" ] || die "platform slice not found: $SLICE (set MAUI_SLICE_DIR)"
[ -f "$SITE/index.html" ] || die "the Blazor WebAssembly site is missing at $SITE (run test/hello-blazorwasm/run-smoke.sh, or set WASM_SITE)"

OHOS_SDK="${OpenHarmonySdkRoot:-${OHOS_SDK_ROOT:-}}"
if [ -z "$OHOS_SDK" ]; then
    for _d in "$HOME"/.harmonybrew/Cellar/ohos-sdk/*/; do
        [ -x "${_d}toolchains/lib/ohos_packing_tool" ] && OHOS_SDK="${_d%/}"
    done
fi
[ -n "$OHOS_SDK" ] || die "no OpenHarmony SDK root: set OpenHarmonySdkRoot (or OHOS_SDK_ROOT)"
[ -x "$OHOS_SDK/toolchains/lib/ohos_packing_tool" ] || die "not an SDK root (no toolchains/lib/ohos_packing_tool): $OHOS_SDK"

mkdir -p "$BASE/feed"
exec >"$LOG" 2>&1
date
awk '/MemTotal|MemAvailable|SwapFree/{print}' /proc/meminfo
log "workload HEAD: $(git -C "$W" rev-parse HEAD 2>/dev/null || echo unknown) $(git -C "$W" log --oneline -1 2>/dev/null)"
log "SDK root: $OHOS_SDK"
log "slice:    $SLICE"
log "site:     $SITE"

if [ -n "${OHOS_AOT_HOOKS:-}" ]; then
    [ -f "$OHOS_AOT_HOOKS" ] || die "OHOS_AOT_HOOKS file not found: $OHOS_AOT_HOOKS"
    export CustomAfterMicrosoftCommonTargets="$OHOS_AOT_HOOKS"
    export OhosTaskHostOverride=true
    log "rc.2 Exec hook: $OHOS_AOT_HOOKS"
fi

log "== memory gate (MemAvailable >= 2 GB) =="
AVAIL_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
if [ "$AVAIL_KB" -lt 2097152 ]; then
    die "GATE-FAIL: MemAvailable=${AVAIL_KB}kB; wait for memory pressure to clear and rerun"
fi
log "MemAvailable=${AVAIL_KB}kB ok"

i=0
while [ "${AOT_SKIP_GUARD:-0}" != "1" ] && [ "$i" -lt 30 ]; do
    if ! ps -eo args | grep -E 'ninja|cmake|clang\+\+|hvigor|dotnet (build|publish|restore)|ilc ' | grep -v grep >/dev/null; then
        log "GUARD-CLEAR after ${i} min at $(date '+%H:%M:%S')"
        break
    fi
    log "guard wait ${i}/30: heavy build is running ($(date '+%H:%M:%S'))"
    sleep 60
    i=$((i+1))
done
if [ "${AOT_SKIP_GUARD:-0}" = "1" ]; then
    log "GUARD-SKIPPED (AOT_SKIP_GUARD=1)"
fi
if [ "$i" -ge 30 ] && [ "${AOT_SKIP_GUARD:-0}" != "1" ]; then
    die "GUARD-TIMEOUT: heavy build still running after 30 min; rerun when the box is quiet"
fi

rm -f "$PUB/libhello-maui-wasm.so.dbg"
cd "$W" || die "cd $W failed"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
export DOTNET_CLI_USE_MSBUILD_SERVER=0
export DOTNET_NUGET_SIGNATURE_VERIFICATION=false
if [ -f "$W/scripts/lib-dotnet-env.sh" ]; then
    . "$W/scripts/lib-dotnet-env.sh" "$W"
fi

# Optional pinned first-party assemblies (skip the in-tree ProjectReference builds).
PINNED=""
[ -n "${HOSTING_DLL:-}" ] && PINNED="$PINNED -p:HostingDll=$HOSTING_DLL"
[ -n "${OPENHARMONY_GRAPHICS_DLL:-}" ] && PINNED="$PINNED -p:OpenHarmonyGraphicsDll=$OPENHARMONY_GRAPHICS_DLL"
# Bundle-specific ArkTS shell abc (see the header); the pack's prebuilt abc matches
# com.example.hellomauiapp only.
[ -n "${WASM_ABC:-}" ] && PINNED="$PINNED -p:OpenHarmonyArktsModulesAbc=$WASM_ABC"

log "== publish (NativeAOT, UI shell, wasm site) =="
# InvariantGlobalization: see test/hello-maui-app/publish-aot.sh - the image's AOT runtime
# cannot resolve ICU and aborts in the hosting module initializer before Main.
"$DOTNET" publish test/hello-maui-wasm/hello-maui-wasm.csproj \
    -f "$TFM" -r "$RID" -c Release -m:1 \
    -p:PublishAot=true -p:PublishAotUsingRuntimePack=true -p:CompressSymbols=false \
    -p:CopyOutputSymbolsToPublishDirectory=false \
    -p:InvariantGlobalization=true \
    -p:OpenHarmonyHapPackage=true -p:OpenHarmonySdkRoot="$OHOS_SDK" \
    -p:OpenHarmonyUIPage=pages/Index \
    -p:OpenHarmonyRuntimeMode=aot \
    -p:MauiSliceDir="$SLICE" \
    -p:OpenHarmonyWasmSiteDir="$SITE" \
    -p:UseSharedCompilation=false -p:RestoreDisableParallel=true \
    $PINNED \
    --source "$BASE/feed"
RC=$?
echo "EXIT=$RC"
if [ "$RC" -ne 0 ]; then
    die "publish failed (rc=$RC); log: $LOG"
fi
echo "== haps =="
ls -la "$W/test/hello-maui-wasm/bin/Release/$TFM/$RID/"*.hap
echo "== publish so =="
stat -c '%s %n' "$PUB"/*.so 2>/dev/null
sha256sum "$PUB/libhello-maui-wasm.so" 2>/dev/null
echo "== staged site =="
ls "$PUB/wasmsite" 2>/dev/null | head -5
echo "== IL gate lines =="
for w in IL2026 IL3050 IL3051; do printf '%s %s\n' "$w" "$(grep -c "$w" "$LOG" || true)"; done
date
