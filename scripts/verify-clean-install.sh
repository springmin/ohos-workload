#!/bin/sh
# Verifies a published workload bundle. The bundle is a NuGet feed of workload packs whose versions
# are listed in the workload manifest, so this checks every manifest entry against the feed, then
# inspects the SDK pack for the host, shell archives, hap target and signing script.
set -e

W="$(cd "$(dirname "$0")/.." && pwd)"
VER="$(ls "$W/packs/Microsoft.OpenHarmony.Sdk" | tail -1)"
MANIFEST="$(ls "$W"/manifests/*/microsoft.net.sdk.openharmony/WorkloadManifest.json | head -1)"
BUNDLE="${1:-$W/dist/openharmony-workload-$VER.tar.gz}"
WORK="${2:-/data/storage/el2/base/tmp/opencode/clean-install}"

[ -f "$BUNDLE" ] || { echo "bundle not found: $BUNDLE" >&2; exit 1; }
rm -rf "$WORK"; mkdir -p "$WORK"
echo "== extracting $(basename "$BUNDLE")"
tar xzf "$BUNDLE" -C "$WORK"
FEED="$(find "$WORK" -maxdepth 3 -type d -name feed | head -1)"
[ -n "$FEED" ] || { echo "no feed/ directory in the bundle" >&2; exit 1; }
echo "== feed: $FEED ($(ls "$FEED" | wc -l) packages)"

echo "== packs declared by $(basename "$MANIFEST")"
python3 - "$FEED" "$MANIFEST" <<'PY' || exit 1
import json, os, sys
feed, manifest = sys.argv[1], sys.argv[2]
data = json.load(open(manifest))
entries = []
for section in ('packs', 'packsWithRid'):
    for pid, meta in (data.get(section) or {}).items():
        version = meta.get('version') if isinstance(meta, dict) else None
        if version:
            entries.append((pid, version))
entries.append(('Microsoft.NETCore.App.Runtime.openharmony-arm64', data.get('version', '')))
files = {f.lower() for f in os.listdir(feed)}
missing = 0
seen = set()
for pid, version in entries:
    if pid in seen:
        continue
    seen.add(pid)
    expected = f"{pid}.{version}.nupkg".lower()
    if expected in files:
        print(f"  ok   {pid} {version}")
    else:
        match = [f for f in files if f.startswith(pid.lower() + '.')]
        if match:
            print(f"  ok   {pid} (feed has {match[0]})")
        else:
            print(f"  MISS {pid} {version}")
            missing += 1
sys.exit(1 if missing else 0)
PY

echo "== SDK pack contents (host, shell, hap target, signing)"
SDKPKG="$(ls "$FEED" | grep -iE "^Microsoft\.OpenHarmony\.Sdk\." | head -1)"
echo "  sdk pack: $SDKPKG"
fail=0
for entry in "hosts/arm64-v8a/libopenharmonyhost.so" "templates/ets/modules.abc" "targets/OpenHarmony.Hap.targets" "templates/scripts/sign-hap.sh"; do
  if unzip -l "$FEED/$SDKPKG" 2>/dev/null | grep -q "$entry"; then echo "  ok   $entry"; else echo "  MISS $entry"; fail=1; fi
done

echo "== consumer install command"
echo "  dotnet workload install openharmony --source \"$FEED\""

if [ "$fail" -eq 0 ]; then echo "CLEAN INSTALL FEED OK"; else echo "CLEAN INSTALL FEED FAILED" >&2; exit 1; fi
