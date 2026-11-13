#!/bin/sh
# Prepare the servicing workload pack layout and manifest from the GA 1.0.0
# layout. The 11.0.1 servicing release keeps the same pack contents but moves
# the internal Ref/Runtime packs to a stable 1.0.0 version, the Sdk pack to
# 1.0.1, and the runtime/aspnetcore framework references to 11.0.1.
#
# This script only rewrites the checkout; run pack-workload-bundle.sh after it.
#
# Usage:
#   sh scripts/prepare-servicing-packs.sh
#
# Env:
#   SDK_BAND               manifest band (default 11.0.100)
#   NEW_WORKLOAD_VERSION   manifest version (default 1.0.1)
#   NEW_SDK_PACK           Sdk pack version (default 1.0.1)
#   NEW_INTERNAL_PACK      Ref/Runtime pack version (default 1.0.0)
#   NEW_RUNTIME_VERSION    Microsoft.NETCore.App/AspNetCore version (default 11.0.1)
#   OLD_SDK_PACK           source Sdk pack version (default 1.0.0)
#   OLD_INTERNAL_PACK      source Ref/Runtime version (default 1.0.0-preview.32)
set -eu

W="$(cd "$(dirname "$0")/.." && pwd)"
BAND="${SDK_BAND:-11.0.100}"
NEW_WORKLOAD_VERSION="${NEW_WORKLOAD_VERSION:-1.0.1}"
NEW_SDK_PACK="${NEW_SDK_PACK:-1.0.1}"
NEW_INTERNAL_PACK="${NEW_INTERNAL_PACK:-1.0.0}"
NEW_RUNTIME_VERSION="${NEW_RUNTIME_VERSION:-11.0.1}"
NEW_ASPNETCORE_REF_VERSION="${NEW_ASPNETCORE_REF_VERSION:-11.0.0}"
OLD_SDK_PACK="${OLD_SDK_PACK:-1.0.0}"
OLD_INTERNAL_PACK="${OLD_INTERNAL_PACK:-1.0.0-preview.32}"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[ -d "$W/packs/Microsoft.OpenHarmony.Sdk/$OLD_SDK_PACK" ] \
    || die "missing source Sdk pack: packs/Microsoft.OpenHarmony.Sdk/$OLD_SDK_PACK"
for api in 20.0 26.0; do
    [ -d "$W/packs/Microsoft.OpenHarmony.Ref.$api/$OLD_INTERNAL_PACK" ] \
        || die "missing source Ref pack: packs/Microsoft.OpenHarmony.Ref.$api/$OLD_INTERNAL_PACK"
    [ -d "$W/packs/Microsoft.OpenHarmony.Runtime.$api.openharmony-arm64/$OLD_INTERNAL_PACK" ] \
        || die "missing source Runtime pack: packs/Microsoft.OpenHarmony.Runtime.$api.openharmony-arm64/$OLD_INTERNAL_PACK"
done

log "copying Sdk pack $OLD_SDK_PACK -> $NEW_SDK_PACK"
rm -rf "$W/packs/Microsoft.OpenHarmony.Sdk/$NEW_SDK_PACK"
cp -a "$W/packs/Microsoft.OpenHarmony.Sdk/$OLD_SDK_PACK" "$W/packs/Microsoft.OpenHarmony.Sdk/$NEW_SDK_PACK"

for api in 20.0 26.0; do
    log "copying Ref.$api $OLD_INTERNAL_PACK -> $NEW_INTERNAL_PACK"
    rm -rf "$W/packs/Microsoft.OpenHarmony.Ref.$api/$NEW_INTERNAL_PACK"
    cp -a "$W/packs/Microsoft.OpenHarmony.Ref.$api/$OLD_INTERNAL_PACK" \
          "$W/packs/Microsoft.OpenHarmony.Ref.$api/$NEW_INTERNAL_PACK"
    log "copying Runtime.$api $OLD_INTERNAL_PACK -> $NEW_INTERNAL_PACK"
    rm -rf "$W/packs/Microsoft.OpenHarmony.Runtime.$api.openharmony-arm64/$NEW_INTERNAL_PACK"
    cp -a "$W/packs/Microsoft.OpenHarmony.Runtime.$api.openharmony-arm64/$OLD_INTERNAL_PACK" \
          "$W/packs/Microsoft.OpenHarmony.Runtime.$api.openharmony-arm64/$NEW_INTERNAL_PACK"
done

# The workload manifest also references the BCL runtime packs. The repo only
# carries the GA 11.0.0 copies, so fetch the matching servicing nupkgs from the
# runtime/aspnetcore releases and lay them out as packs/<id>/<version>.
fetch_bcl_pack() { # <repo> <pack-id>
    repo="$1"; id="$2"
    url="https://github.com/springmin/$repo/releases/download/v${NEW_RUNTIME_VERSION}-ohos/${id}.${NEW_RUNTIME_VERSION}.nupkg"
    nupkg="$W/.feed/.$id.$NEW_RUNTIME_VERSION.nupkg"
    log "fetching $id $NEW_RUNTIME_VERSION from $repo"
    mkdir -p "$W/.feed"
    curl -fL --retry 3 --connect-timeout 20 -o "$nupkg" "$url" \
        || die "failed to download $url"
    rm -rf "$W/packs/$id/$NEW_RUNTIME_VERSION"
    mkdir -p "$W/packs/$id/$NEW_RUNTIME_VERSION"
    python3 - "$nupkg" "$W/packs/$id/$NEW_RUNTIME_VERSION" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
    rm -f "$nupkg"
}
fetch_bcl_pack runtime-ohos Microsoft.NETCore.App.Runtime.openharmony-arm64
fetch_bcl_pack aspnetcore-ohos Microsoft.AspNetCore.App.Runtime.openharmony-arm64

log "patching the Sdk pack framework versions"
python3 - "$W/packs/Microsoft.OpenHarmony.Sdk/$NEW_SDK_PACK" "$OLD_INTERNAL_PACK" "$NEW_INTERNAL_PACK" "$NEW_RUNTIME_VERSION" "$NEW_ASPNETCORE_REF_VERSION" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
old_internal, new_internal, new_runtime, new_aspnetcore_ref = sys.argv[2:6]
platform = root / "targets" / "OpenHarmony.PlatformItems.targets"
text = platform.read_text(encoding="utf-8")
for old, new in [
    (f'DefaultRuntimeFrameworkVersion="{old_internal}"', f'DefaultRuntimeFrameworkVersion="{new_internal}"'),
    (f'LatestRuntimeFrameworkVersion="{old_internal}"', f'LatestRuntimeFrameworkVersion="{new_internal}"'),
    (f'TargetingPackVersion="{old_internal}"', f'TargetingPackVersion="{new_internal}"'),
    ('TargetingPackVersion="11.0.0"', f'TargetingPackVersion="{new_aspnetcore_ref}"'),
    ('DefaultRuntimeFrameworkVersion="11.0.0"', f'DefaultRuntimeFrameworkVersion="{new_runtime}"'),
    ('LatestRuntimeFrameworkVersion="11.0.0"', f'LatestRuntimeFrameworkVersion="{new_runtime}"'),
]:
    if text.count(old) == 0:
        raise SystemExit(f"missing version token: {old}")
    text = text.replace(old, new)
platform.write_text(text, encoding="utf-8")
print(f"patched {platform}")
PY

log "patching the workload manifest"
python3 - "$W/manifests/$BAND/microsoft.net.sdk.openharmony/WorkloadManifest.json" \
    "$NEW_WORKLOAD_VERSION" "$NEW_SDK_PACK" "$NEW_INTERNAL_PACK" "$NEW_RUNTIME_VERSION" <<'PY'
import json, sys
path, workload_version, sdk_pack, internal_pack, runtime_version = sys.argv[1:6]
with open(path, encoding="utf-8") as f:
    manifest = json.load(f)
manifest["version"] = workload_version
manifest["packs"]["Microsoft.OpenHarmony.Sdk"]["version"] = sdk_pack
for pack in (
    "Microsoft.OpenHarmony.Ref.20.0",
    "Microsoft.OpenHarmony.Runtime.20.0.openharmony-arm64",
    "Microsoft.OpenHarmony.Ref.26.0",
    "Microsoft.OpenHarmony.Runtime.26.0.openharmony-arm64",
):
    manifest["packs"][pack]["version"] = internal_pack
for pack in (
    "Microsoft.NETCore.App.Runtime.openharmony-arm64",
    "Microsoft.AspNetCore.App.Runtime.openharmony-arm64",
):
    manifest["packs"][pack]["version"] = runtime_version
with open(path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
print(f"patched {path}")
PY

log "servicing pack layout ready"
