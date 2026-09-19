#!/bin/sh
# Verifies a published workload bundle. The bundle is a NuGet feed of workload packs, so this checks
# the feed inventory (every expected pack at the current version), the manifest pack, and prints the
# install command a consumer would use.
set -e

W="$(cd "$(dirname "$0")/.." && pwd)"
VER="$(ls "$W/packs/Microsoft.OpenHarmony.Sdk" | tail -1)"
BUNDLE="${1:-$W/dist/openharmony-workload-$VER.tar.gz}"
WORK="${2:-/data/storage/el2/base/tmp/opencode/clean-install}"

[ -f "$BUNDLE" ] || { echo "bundle not found: $BUNDLE" >&2; exit 1; }
rm -rf "$WORK"; mkdir -p "$WORK"
echo "== extracting $(basename "$BUNDLE")"
tar xzf "$BUNDLE" -C "$WORK"
FEED="$(find "$WORK" -maxdepth 3 -type d -name feed | head -1)"
[ -n "$FEED" ] || { echo "no feed/ directory in the bundle" >&2; exit 1; }
echo "== feed: $FEED ($(ls "$FEED" | wc -l) packages)"

fail=0
expect() { # <glob> <label>
  if ls "$FEED"/$1 >/dev/null 2>&1; then
    echo "  ok   $2"
  else
    echo "  MISS $2 ($1)"; fail=1
  fi
}
echo "== expected packs at $VER"
expect "microsoft.netcore.app.runtime.openharmony-arm64.*.nupkg" "BCL runtime pack"
expect "microsoft.openharmony.sdk.$VER.nupkg" "platform SDK pack"
expect "microsoft.openharmony.ref.20.0.$VER.nupkg" "ref pack (20.0)"
expect "microsoft.openharmony.ref.26.0.$VER.nupkg" "ref pack (26.0)"
expect "microsoft.openharmony.runtime.20.0.openharmony-arm64.$VER.nupkg" "runtime pack (20.0)"
expect "microsoft.openharmony.runtime.26.0.openharmony-arm64.$VER.nupkg" "runtime pack (26.0)"
expect "microsoft.openharmony.maui.graphics.$VER.nupkg" "maui graphics pack"
expect "*manifest*.nupkg" "workload manifest pack"

echo "== host / shell / signing inside the SDK pack"
SDKPKG="$(ls "$FEED"/microsoft.openharmony.sdk.$VER.nupkg | head -1)"
for entry in "hosts/arm64-v8a/libopenharmonyhost.so" "templates/ets/modules.abc" "templates/ets/modules.ui.abc" "targets/OpenHarmony.Hap.targets" "templates/scripts/sign-hap.sh"; do
  if unzip -l "$SDKPKG" 2>/dev/null | grep -q "$entry"; then echo "  ok   $entry"; else echo "  MISS $entry"; fail=1; fi
done

echo "== consumer install command"
echo "  dotnet workload install openharmony --source \"$FEED\" --skip-manifest-update"

if [ "$fail" -eq 0 ]; then echo "CLEAN INSTALL FEED OK"; else echo "CLEAN INSTALL FEED FAILED" >&2; exit 1; fi
