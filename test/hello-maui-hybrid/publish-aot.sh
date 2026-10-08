#!/bin/sh
# publish-aot.sh - NativeAOT publish of test/hello-maui-hybrid into installable haps.
#
# Same recipe as test/hello-maui-app/publish-aot.sh: the one non-negotiable flag is
# -p:OpenHarmonyUIPage=pages/Index (it makes the hap pack stage the UI ArkTS shell: XComponent +
# loadContent), and -p:PublishAot=true switches the project to OutputType=Library + NativeLib=Shared
# with its own openharmony_app_main export (AotEntry.cs). One publish produces
# hello-maui-hybrid.hap (workload-signed) and hello-maui-hybrid-unsigned.hap (re-sign for a device).
#
# Usage: sh test/hello-maui-hybrid/publish-aot.sh
# Env:
#   AOT_WORKDIR     scratch dir for the log + offline feed (default /data/storage/el2/base/tmp/opencode/hybrid-sample/aot)
#   DOTNET          dotnet host (default $HOME/.dotnet/dotnet)
#   OHOS_SDK_ROOT / OpenHarmonySdkRoot   SDK root holding toolchains/ (default: harmonybrew Cellar)
#   OHOS_AOT_HOOKS  optional CustomAfterMicrosoftCommonTargets hook (rc.2 Exec workaround; same as
#                   the demo's publish-aot.sh)
#   OpenHarmonyMauiPlatformDir   platform slice sources (default <repo>/../maui-ohos/...; pass
#                   explicitly when running from a git worktree elsewhere)
set -u

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

W="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="${AOT_WORKDIR:-/data/storage/el2/base/tmp/opencode/hybrid-sample/aot}"
LOG="$BASE/publish-aot.log"
TFM="${AOT_TFM:-net11.0-openharmony26.0}"
RID=openharmony-arm64
DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"
SLICE="${OpenHarmonyMauiPlatformDir:-$W/../maui-ohos/src/Core/src/Platform/OpenHarmony}"
PUB="$W/test/hello-maui-hybrid/bin/Release/$TFM/$RID/publish"
PROJ="$W/test/hello-maui-hybrid/hello-maui-hybrid.csproj"

[ -f "$PROJ" ] || die "project not found: $PROJ"
[ -d "$SLICE" ] || die "platform slice not found: $SLICE (set OpenHarmonyMauiPlatformDir)"

SDK="${OpenHarmonySdkRoot:-${OHOS_SDK_ROOT:-}}"
if [ -z "$SDK" ]; then
    for _d in "$HOME"/.harmonybrew/Cellar/ohos-sdk/*/; do
        [ -x "${_d}toolchains/lib/ohos_packing_tool" ] && SDK="${_d%/}"
    done
fi
[ -n "$SDK" ] || die "no OpenHarmony SDK root: set OpenHarmonySdkRoot (or OHOS_SDK_ROOT)"
[ -x "$SDK/toolchains/lib/ohos_packing_tool" ] || die "not an SDK root (no toolchains/lib/ohos_packing_tool): $SDK"

mkdir -p "$BASE/feed"
exec >"$LOG" 2>&1
date
awk '/MemTotal|MemAvailable|SwapFree/{print}' /proc/meminfo
log "workload HEAD: $(git -C "$W" rev-parse --short HEAD 2>/dev/null) $(git -C "$W" log --oneline -1 2>/dev/null)"
log "maui-ohos HEAD: $(git -C "$W/../maui-ohos" rev-parse --short HEAD 2>/dev/null || echo unknown)"
log "dotnet: $DOTNET ($("$DOTNET" --version 2>/dev/null))"
log "SDK: $SDK"
log "slice: $SLICE"

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
[ "$i" -lt 30 ] || die "GUARD-TIMEOUT: heavy build still running after 30 min"

# stale symbol file from an earlier publish would be staged again
rm -f "$PUB/libhello-maui-hybrid.so.dbg"
cd "$W" || die "cd $W failed"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_CLI_USE_MSBUILD_SERVER=0
. "$W/scripts/lib-dotnet-env.sh" "$W" || die "lib-dotnet-env.sh failed"
export DOTNETSDK_WORKLOAD_MANIFEST_ROOTS="$W/manifests"
export DOTNETSDK_WORKLOAD_PACK_ROOTS="$W/packs"

log "== publish (NativeAOT, UI shell) =="
# InvariantGlobalization: this image's AOT runtime cannot resolve an ICU provider and the first
# culture-sensitive call aborts before Main; invariant mode compiles the ICU lookup out.
"$DOTNET" publish "$PROJ" \
    -f "$TFM" -r "$RID" -c Release -m:1 \
    -p:PublishAot=true -p:PublishAotUsingRuntimePack=true -p:CompressSymbols=false \
    -p:CopyOutputSymbolsToPublishDirectory=false \
    -p:InvariantGlobalization=true \
    -p:OpenHarmonyHapPackage=true -p:OpenHarmonySdkRoot="$SDK" \
    -p:OpenHarmonyUIPage=pages/Index \
    -p:OpenHarmonyRuntimeMode=aot \
    -p:OpenHarmonyMauiPlatformDir="$SLICE" \
    --source "$BASE/feed"
RC=$?
echo "EXIT=$RC"
[ "$RC" -eq 0 ] || die "publish failed (rc=$RC); log: $LOG"
echo "== haps =="
ls -la "$W/test/hello-maui-hybrid/bin/Release/$TFM/$RID/"*.hap
echo "== publish so =="
stat -c '%s %n' "$PUB"/*.so 2>/dev/null
sha256sum "$PUB/libhello-maui-hybrid.so" 2>/dev/null
echo "== IL gate lines =="
for w in IL2026 IL3050 IL3051; do printf '%s %s\n' "$w" "$(grep -c "$w" "$LOG" || true)"; done
date
