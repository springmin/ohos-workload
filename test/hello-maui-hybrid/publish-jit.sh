#!/bin/sh
# publish-jit.sh - JIT publish of test/hello-maui-hybrid into installable haps.
#
# The JIT route is the fast device-round recipe: no ILC/AOT step, output
# bin/Release/<tfm>/openharmony-arm64/hello-maui-hybrid[-unsigned].hap. It is the same recipe the
# L3/M4 device rounds used for test/hello-maui-app (pack root, offline feed, memory gate).
#
# Usage: sh test/hello-maui-hybrid/publish-jit.sh
# Env:
#   PUB_WORKDIR     scratch dir for the log + offline feed (default /data/storage/el2/base/tmp/opencode/hybrid-sample/jit)
#   DOTNET          dotnet host (default $HOME/.dotnet/dotnet)
#   OHOS_SDK_ROOT / OpenHarmonySdkRoot   SDK root holding toolchains/ (default: harmonybrew Cellar)
#   OHOS_AOT_HOOKS  optional CustomAfterMicrosoftCommonTargets hook. The rc.2 SDK on HarmonyOS
#                   hosts writes the built-in Exec as a Windows batch wrapper (restool/packing/sign
#                   fail with "exit: bad number: %errorlevel%"); the local hook replaces it. Known
#                   scratch copy: /data/storage/el2/base/tmp/opencode/mw-l/m2exit-aot/aot-local-hooks.targets
#                   (see docs/openharmony-hap-packaging.md, "Known environment quirks").
#   OpenHarmonyMauiPlatformDir   platform slice sources (default <repo>/../maui-ohos/src/Core/src/Platform/OpenHarmony;
#                   pass explicitly when running from a git worktree elsewhere)
#
# Memory discipline (this box OOMs under parallel builds): refuse below 2 GB MemAvailable and wait
# out heavy builds (ninja/cmake/clang/hvigor/dotnet build|publish|restore). One publish at a time.
set -u

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

W="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="${PUB_WORKDIR:-/data/storage/el2/base/tmp/opencode/hybrid-sample/jit}"
LOG="$BASE/publish-jit.log"
TFM="${PUB_TFM:-net11.0-openharmony26.0}"
RID=openharmony-arm64
DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"
SLICE="${OpenHarmonyMauiPlatformDir:-$W/../maui-ohos/src/Core/src/Platform/OpenHarmony}"
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

cd "$W" || die "cd $W failed"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_CLI_USE_MSBUILD_SERVER=0
. "$W/scripts/lib-dotnet-env.sh" "$W" || die "lib-dotnet-env.sh failed"
export DOTNETSDK_WORKLOAD_MANIFEST_ROOTS="$W/manifests"
export DOTNETSDK_WORKLOAD_PACK_ROOTS="$W/packs"

log "== publish (JIT, UI shell) =="
"$DOTNET" publish "$PROJ" \
    -f "$TFM" -r "$RID" -c Release -m:1 \
    -p:OpenHarmonyHapPackage=true -p:OpenHarmonySdkRoot="$SDK" \
    -p:OpenHarmonyUIPage=pages/Index \
    -p:OpenHarmonyRuntimeMode=jit \
    -p:OpenHarmonyMauiPlatformDir="$SLICE" \
    -p:DisableTransitiveFrameworkReferenceDownloads=true \
    --source "$BASE/feed"
RC=$?
echo "EXIT=$RC"
[ "$RC" -eq 0 ] || die "publish failed (rc=$RC); log: $LOG"
echo "== haps =="
ls -la "$W/test/hello-maui-hybrid/bin/Release/$TFM/$RID/"*.hap
echo "== runtime-mode evidence =="
python3 - "$W/test/hello-maui-hybrid/bin/Release/$TFM/$RID/hello-maui-hybrid.hap" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    for name in z.namelist():
        if name.endswith('runtime-mode.txt'):
            print(name, '=', z.read(name).decode('utf-8', 'replace').strip())
PY
date
