#!/bin/sh
# Produces a self-contained OpenHarmony workload bundle:
#   dist/openharmony-workload-<version>.tar.gz
#     manifests/microsoft.net.sdk.openharmony/...
#     feed/*.nupkg
#     install-ohos-workload.sh
#     README.md
# Usage: scripts/pack-workload-bundle.sh [output-dir]
set -e

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

W="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$W/dist}"
BAND="${SDK_BAND:-11.0.100-rc.1}"
VER="$(python3 -c "import json;print(json.load(open('$W/manifests/$BAND/microsoft.net.sdk.openharmony/WorkloadManifest.json'))['version'])")"
NAME="openharmony-workload-$VER"
STAGE="$OUT/$NAME"

log "== packing the workload feed =="
sh "$W/scripts/pack-local-workload.sh" "$W/.feed"

log "== assembling $NAME =="
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
- `feed/*.nupkg` — the workload packs (Sdk/Ref/Runtime + the BCL runtime pack alias).
  The Sdk pack also carries the prebuilt ArkTS shells (`templates/ets/modules.abc`
  headless and `templates/ets/modules.ui.abc` UI) and the native host
  (`hosts/arm64-v8a/libopenharmonyhost.so`, self-signed with the SDK's ElfSigner).
- `install-ohos-workload.sh` — installer

Install into a .NET SDK root:

```sh
./install-ohos-workload.sh                 # uses `dotnet` from PATH
./install-ohos-workload.sh --dry-run       # show what would happen
./install-ohos-workload.sh --dotnet ~/.dotnet/dotnet .
```

Afterwards `net11.0-openharmony<api>` projects build and publish without any
`DOTNETSDK_WORKLOAD_*` environment variables.

## UI builds

`-p:OpenHarmonyUIPage=pages/Index` selects the prebuilt UI shell automatically (an ArkUI
page with an `XComponent` surface + `ContentSlot`, compiled with the official ArkTS
toolchain). Supply your own shell with
`-p:OpenHarmonyArktsModulesAbc=<path to modules.abc>`
(see `scripts/build-arkts-shell.sh` in the workload repo to rebuild it without DevEco).

At runtime the shell starts the managed app, forwards lifecycle events and hands over:
- `OpenHarmonyBridge.NodeContent` — native ArkUI nodes attached by managed code,
- `OpenHarmonyBridge.SurfaceChanged` — the `OHNativeWindow*` (XComponent surface) for the
  managed renderer (Skia/MAUI).

## Signing

- ELF binaries/libraries: the SDK's own algorithm (ElfSigner / `selfsign`).
- The `.hap`: `templates/scripts/sign-hap.sh` (POSIX) or `sign-hap.ps1` (Windows), both
  driven automatically by `dotnet publish -p:OpenHarmonyHapPackage=true`.
MD

log "== creating the tarball =="
mkdir -p "$OUT"
tar -czf "$OUT/$NAME.tar.gz" -C "$OUT" "$NAME"
ls -l "$OUT/$NAME.tar.gz"
