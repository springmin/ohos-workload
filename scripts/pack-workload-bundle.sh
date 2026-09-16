#!/bin/sh
# Produces a self-contained OpenHarmony workload bundle:
#   dist/ohos-workload-<version>.tar.gz
#     manifests/microsoft.net.sdk.openharmony/...
#     feed/*.nupkg
#     install-ohos-workload.sh
#     README.md
# Usage: scripts/pack-workload-bundle.sh [output-dir]
set -e
W="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$W/dist}"
BAND="${SDK_BAND:-11.0.100-rc.1}"
VER="$(python3 -c "import json;print(json.load(open('$W/manifests/$BAND/microsoft.net.sdk.openharmony/WorkloadManifest.json'))['version'])")"
NAME="ohos-workload-$VER"
STAGE="$OUT/$NAME"

echo "== packing the workload feed =="
sh "$W/scripts/pack-local-workload.sh" "$W/.feed"

echo "== assembling $NAME =="
rm -rf "$STAGE"
mkdir -p "$STAGE/feed" "$STAGE/manifests"
cp -r "$W/manifests/$BAND/microsoft.net.sdk.openharmony" "$STAGE/manifests/"
cp "$W/.feed"/*.nupkg "$STAGE/feed/"
cp "$W/templates/install-ohos-workload.sh" "$STAGE/"
chmod +x "$STAGE/install-ohos-workload.sh"
cat > "$STAGE/README.md" <<'MD'
# OpenHarmony platform workload bundle

Contents:
- `manifests/microsoft.net.sdk.openharmony/` — the workload manifest (workload ids + packs)
- `feed/*.nupkg` — the workload packs (Sdk/Ref/Runtime + the BCL runtime pack alias)
- `install-ohos-workload.sh` — installer

Install into a .NET SDK root:

```sh
./install-ohos-workload.sh                 # uses `dotnet` from PATH
./install-ohos-workload.sh --dry-run       # show what would happen
./install-ohos-workload.sh --dotnet ~/.dotnet/dotnet .
```

Afterwards `net11.0-openharmony<api>` projects build and publish without any
`DOTNETSDK_WORKLOAD_*` environment variables. Uninstall with
`dotnet workload uninstall openharmony` and by removing
`<root>/sdk-manifests/<band>/microsoft.net.sdk.openharmony`.
MD

echo "== creating the tarball =="
mkdir -p "$OUT"
tar -czf "$OUT/$NAME.tar.gz" -C "$OUT" "$NAME"
ls -l "$OUT/$NAME.tar.gz"
