#!/bin/sh
# Packs the local workload packs into nupkgs (a local NuGet feed) so the workload can be
# installed with `dotnet workload install openharmony --skip-manifest-update --source <feed>`.
# Usage: scripts/pack-local-workload.sh [output-feed-dir]
set -e
W="$(cd "$(dirname "$0")/.." && pwd)"
FEED="${1:-$W/.feed}"
BAND="${SDK_BAND:-11.0.100-rc.1}"
MANIFEST="$W/manifests/$BAND/microsoft.net.sdk.openharmony/WorkloadManifest.json"
[ -f "$MANIFEST" ] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }

mkdir -p "$FEED"
python3 - "$W" "$FEED" "$MANIFEST" <<'PY'
import json, os, sys, zipfile

root, feed, manifest_path = sys.argv[1:4]
manifest = json.load(open(manifest_path))
packs = manifest["packs"]

for pack_id, info in packs.items():
    version = info["version"]
    src = os.path.join(root, "packs", pack_id, version)
    if not os.path.isdir(src):
        print(f"  skipped (missing pack dir): {pack_id} {version}")
        continue
    out = os.path.join(feed, f"{pack_id}.{version}.nupkg")
    nuspec = f'''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2012/06/nuspec.xsd">
  <metadata>
    <id>{pack_id}</id>
    <version>{version}</version>
    <authors>dotnet-ohos</authors>
    <description>{info.get("kind", "framework")} workload pack generated from the ohos-workload repo</description>
  </metadata>
</package>
'''
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        z.writestr(f"{pack_id}.nuspec", nuspec)
        # Skip NuGet metadata carried over from packages the pack directory was
        # extracted from (a nupkg may only contain a single .nuspec).
        skip_dirs = {"_rels", "package"}
        for dirpath, dirs, files in os.walk(src):
            dirs[:] = [d for d in dirs if d not in skip_dirs]
            for f in files:
                if f.endswith((".nuspec", ".p7s", ".psmdcp")) or f == "[Content_Types].xml":
                    continue
                full = os.path.join(dirpath, f)
                rel = os.path.relpath(full, src).replace(os.sep, "/")
                z.write(full, rel)
    print(f"  packed {pack_id} {version} -> {out} ({os.path.getsize(out)//1024} KB)")
PY
echo "feed: $FEED"
