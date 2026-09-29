#!/bin/sh
# publish-aot.sh - NativeAOT publish of test/hello-maui-app into installable haps.
#
# The one non-negotiable flag is -p:OpenHarmonyUIPage=pages/Index. It is what makes the hap
# pack stage the UI ArkTS shell (templates/ets/modules.ui.abc: XComponent + loadContent, page
# pages/Index) and write resources/base/profile/main_pages.json. Without it the hap carries
# the headless abc and an empty main_pages.json, so there is no XComponent and the MAUI window
# paints nothing (WMS 'uiContent is null') - the aot-haps v1/v2 blank-window root cause, see
# AOT.md and docs/openharmony-hap-packaging.md "NativeAOT HAP variant".
#
# Usage: sh test/hello-maui-app/publish-aot.sh
# Env:
#   AOT_WORKDIR   scratch dir for the log + offline feed (default /data/storage/el2/base/tmp/opencode/aot-v3;
#                 only the log and an empty feed dir are written there)
#   OHOS_SDK / OpenHarmonySdkRoot / OHOS_SDK_ROOT   SDK root holding toolchains/ (default: the
#                 harmonybrew Cellar install)
#   OHOS_AOT_HOOKS  optional CustomAfterMicrosoftCommonTargets file. The rc.2 SDK on HarmonyOS
#                 hosts writes the built-in Exec task as a Windows batch wrapper; the local hook
#                 replaces it (see "Known environment quirks" in docs/openharmony-hap-packaging.md
#                 and runtime-ohos docs/plans/2026-09-29-ohos-local-device-test-runbook.md). No
#                 repo file changes; scratch copy: <workdir>/aot-local-hooks.targets.
#   OpenHarmonyMauiPlatformDir   platform slice sources (default ../maui-ohos/src/Core/src/Platform/OpenHarmony)
#
# Memory discipline (this box OOMs under parallel builds): refuse to start below 2 GB
# MemAvailable, wait out heavy builds (ninja/cmake/clang/hvigor/dotnet build|publish|restore)
# for up to 30 min. One publish at a time.
set -u

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

W="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="${AOT_WORKDIR:-/data/storage/el2/base/tmp/opencode/aot-v3}"
LOG="$BASE/publish-aot.log"
TFM="${AOT_TFM:-net11.0-openharmony26.0}"
RID=openharmony-arm64
DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"
SLICE="${OpenHarmonyMauiPlatformDir:-$W/../maui-ohos/src/Core/src/Platform/OpenHarmony}"
PUB="$W/test/hello-maui-app/bin/Release/$TFM/$RID/publish"

[ -f "$W/test/hello-maui-app/hello-maui-app.csproj" ] || die "run from the ohos-workload checkout (project not found: $W/test/hello-maui-app)"
[ -d "$SLICE" ] || die "platform slice not found: $SLICE (set OpenHarmonyMauiPlatformDir)"

# SDK root: environment first, else the harmonybrew Cellar layout (same resolution as
# scripts/make-mode-kit.sh); the pack never probes $HOME itself.
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
log "maui-ohos HEAD: $(git -C "$W/../maui-ohos" rev-parse HEAD 2>/dev/null || echo unknown)"
log "SDK root: $OHOS_SDK"
log "slice:    $SLICE"

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
while [ "$i" -lt 30 ]; do
    if ! ps -eo args | grep -E 'ninja|cmake|clang\+\+|hvigor|dotnet (build|publish|restore)|ilc ' | grep -v grep >/dev/null; then
        log "GUARD-CLEAR after ${i} min at $(date '+%H:%M:%S')"
        break
    fi
    log "guard wait ${i}/30: heavy build is running ($(date '+%H:%M:%S'))"
    sleep 60
    i=$((i+1))
done
if [ "$i" -ge 30 ]; then
    die "GUARD-TIMEOUT: heavy build still running after 30 min; rerun when the box is quiet"
fi

# stale symbol file from an earlier publish would be staged again
rm -f "$PUB/libhello-maui-app.so.dbg"
cd "$W" || die "cd $W failed"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
export DOTNET_CLI_USE_MSBUILD_SERVER=0
. "$W/scripts/lib-dotnet-env.sh" "$W"

log "== publish (NativeAOT, UI shell) =="
"$DOTNET" publish test/hello-maui-app/hello-maui-app.csproj \
    -f "$TFM" -r "$RID" -c Release -m:1 \
    -p:PublishAot=true -p:PublishAotUsingRuntimePack=true -p:CompressSymbols=false \
    -p:CopyOutputSymbolsToPublishDirectory=false \
    -p:OpenHarmonyHapPackage=true -p:OpenHarmonySdkRoot="$OHOS_SDK" \
    -p:OpenHarmonyUIPage=pages/Index \
    -p:OpenHarmonyRuntimeMode=aot \
    -p:OpenHarmonyMauiPlatformDir="$SLICE" \
    --source "$BASE/feed"
RC=$?
echo "EXIT=$RC"
if [ "$RC" -ne 0 ]; then
    die "publish failed (rc=$RC); log: $LOG"
fi
echo "== haps =="
ls -la "$W/test/hello-maui-app/bin/Release/$TFM/$RID/"*.hap
echo "== publish so =="
stat -c '%s %n' "$PUB"/*.so 2>/dev/null
sha256sum "$PUB/libhello-maui-app.so" 2>/dev/null
echo "== IL gate lines =="
for w in IL2026 IL3050 IL3051; do printf '%s %s\n' "$w" "$(grep -c "$w" "$LOG" || true)"; done
date
