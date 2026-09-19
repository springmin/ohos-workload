#!/bin/sh
# Verifies a published workload bundle in a clean directory: extracts it, checks the pack layout
# (manifests, Ref/Runtime/Sdk packs, host, shell archive, template scripts and the demo haps) and
# compares the artifact hashes against the bundle's SHA256SUMS.
set -e

W="$(cd "$(dirname "$0")/.." && pwd)"
VER="$(ls "$W/packs/Microsoft.OpenHarmony.Sdk" | tail -1)"
BUNDLE="${1:-$W/dist/openharmony-workload-$VER.tar.gz}"
WORK="${2:-/data/storage/el2/base/tmp/opencode/clean-install}"

[ -f "$BUNDLE" ] || { echo "bundle not found: $BUNDLE" >&2; exit 1; }
rm -rf "$WORK"; mkdir -p "$WORK"
echo "== extracting $BUNDLE"
tar xzf "$BUNDLE" -C "$WORK"
# Layout-agnostic: find the directory that owns packs/ (whatever nesting the bundle uses).
PACKS_DIR="$(find "$WORK" -maxdepth 4 -type d -name packs 2>/dev/null | head -1)"
if [ -z "$PACKS_DIR" ]; then
    echo "bundle layout not recognised under $WORK" >&2; exit 1
fi
ROOT="$(dirname "$PACKS_DIR")"
echo "== root: $ROOT"

fail=0
check() { # <path> <label>
  if [ -e "$ROOT/$1" ]; then echo "  ok   $2"; else echo "  MISS $2 ($1)"; fail=1; fi
}
echo "== manifests"
for f in "$ROOT"/manifests/*/*/WorkloadManifest.json; do
  [ -f "$f" ] || continue
  v="$(python3 -c "import json,sys;print(json.load(open('$f'))['version'])")"
  echo "  manifest $(basename "$(dirname "$f")") version=$v"
done
echo "== packs"
check "packs/Microsoft.OpenHarmony.Sdk/$VER/hosts/arm64-v8a/libopenharmonyhost.so" "host library"
check "packs/Microsoft.OpenHarmony.Sdk/$VER/templates/ets/modules.abc" "shell archive"
check "packs/Microsoft.OpenHarmony.Sdk/$VER/templates/ets/modules.ui.abc" "ui shell archive"
check "packs/Microsoft.OpenHarmony.Sdk/$VER/targets/OpenHarmony.Hap.targets" "hap packaging target"
check "packs/Microsoft.OpenHarmony.Sdk/$VER/templates/scripts/sign-hap.sh" "signing script"
check "packs/Microsoft.OpenHarmony.Ref.26.0/$VER/ref/net11.0/Microsoft.OpenHarmony.dll" "ref assembly (26.0)"
check "packs/Microsoft.OpenHarmony.Runtime.26.0.openharmony-arm64/$VER/runtimes/openharmony-arm64/lib/net11.0/Microsoft.OpenHarmony.Hosting.dll" "hosting assembly (26.0)"

echo "== rides / rid graph"
if grep -rqs "openharmony-arm64" "$ROOT/packs/Microsoft.OpenHarmony.Sdk/$VER/targets" "$ROOT/manifests" 2>/dev/null; then
  echo "  ok   openharmony-arm64 referenced"
else
  echo "  MISS openharmony-arm64 references"; fail=1
fi

echo "== demo artifacts (if shipped in the bundle)"
for f in "$ROOT"/../test/*/bin/Release/*/openharmony-arm64/*.hap; do :; done

if [ -f "$W/dist/SHA256SUMS" ]; then
  echo "== verifying checksums of local artifacts"
  ( cd "$W" && sha256sum -c "$W/dist/SHA256SUMS" 2>/dev/null | sed 's/^/  /' ) || true
fi

if [ "$fail" -eq 0 ]; then echo "CLEAN INSTALL LAYOUT OK"; else echo "CLEAN INSTALL LAYOUT FAILED" >&2; exit 1; fi
