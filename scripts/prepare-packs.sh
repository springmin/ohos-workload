#!/bin/sh
# Build the thin platform ref assembly and lay out every local workload pack.
#   scripts/prepare-packs.sh [--sha256 <hex>] [--record-sha256] [path-to-Microsoft.NETCore.App.Runtime.openharmony-arm64.nupkg]
#
# The BCL runtime pack artifact is verified against an expected sha256 *before* it is
# unpacked. The expectation is (in order): RUNTIME_PACK_SHA256 / --sha256, the
# <artifact>.sha256 sidecar recorded by a previous run, then the fixed digest of the
# released artifact below. A locally built artifact is admitted once with --record-sha256
# (which writes <artifact>.sha256); every later run must match that record. There is no
# path that unpacks an artifact without a matching expected digest.
#
# Without an argument the released runtime pack is downloaded from the fork's
# -openharmony release and verified against the expected digest.
set -e
W="$(cd "$(dirname "$0")/.." && pwd)"
VER=1.0.0-preview.24
DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"
RTV=11.0.0-rc.1.26451.109
# sha256 (64 hex chars) of Microsoft.NETCore.App.Runtime.openharmony-arm64.11.0.0-rc.1.26451.109.nupkg
# on the v11.0.0-rc.1.26451.109-openharmony release; cross-check with
#   gh api repos/springmin/runtime-ohos/releases/tags/v11.0.0-rc.1.26451.109-openharmony \
#     --jq '.assets[] | select(.name=="Microsoft.NETCore.App.Runtime.openharmony-arm64.'$RTV'.nupkg") | .digest'
SHA=b9fff88aadd4bbfc73964d0fdb05dc551755fd956332cd7d44cf297e06556f51
URL="https://github.com/springmin/runtime-ohos/releases/download/v11.0.0-rc.1.26451.109-openharmony/Microsoft.NETCore.App.Runtime.openharmony-arm64.$RTV.nupkg"
BCL="$W/packs/Microsoft.NETCore.App.Runtime.openharmony-arm64/$RTV"

# Expected digest of whatever artifact gets unpacked (env/flag override; --sha256 wins).
EXPECT_SHA="${RUNTIME_PACK_SHA256:-}"
RECORD_SHA256=0
NPKG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --sha256)
            shift
            [ $# -gt 0 ] || { echo "--sha256 needs a sha256 digest" >&2; exit 2; }
            EXPECT_SHA="$1"
            ;;
        --record-sha256) RECORD_SHA256=1 ;;
        -h|--help)
            echo "usage: $0 [--sha256 <hex>] [--record-sha256] [path-to-runtime-pack.nupkg]"
            exit 0
            ;;
        -*)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
        *)
            [ -z "$NPKG" ] || { echo "unexpected extra argument: $1" >&2; exit 2; }
            NPKG="$1"
            ;;
    esac
    shift
done

digest_artifact() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"
    fi
}

# Fail closed unless the artifact matches EXPECT_SHA (which must not be empty).
check_artifact() {
    _file="$1"; _label="$2"
    [ -f "$_file" ] || { echo "$_label not found: $_file" >&2; exit 1; }
    if [ -z "$EXPECT_SHA" ]; then
        echo "refusing to unpack $_file without an expected sha256" >&2
        echo "  pass --sha256 <hex> / RUNTIME_PACK_SHA256=<hex>  (released artifact: $SHA)" >&2
        echo "  a locally built artifact is admitted once with --record-sha256" >&2
        exit 1
    fi
    _got="$(digest_artifact "$_file")"
    if [ "$_got" != "$EXPECT_SHA" ]; then
        echo "sha256 mismatch for $_file" >&2
        echo "  expected $EXPECT_SHA" >&2
        echo "  actual   $_got" >&2
        exit 1
    fi
    echo "   sha256 OK ($_label) $_got"
}

echo "== 1/2 platform ref assembly =="
"$DOTNET" build "$W/src/Microsoft.OpenHarmony.Ref/Microsoft.OpenHarmony.Ref.csproj" -c Release -v:q --nologo
REFDLL="$W/src/Microsoft.OpenHarmony.Ref/bin/Release/net11.0/Microsoft.OpenHarmony.dll"
for API in 20.0 26.0; do
  mkdir -p "$W/packs/Microsoft.OpenHarmony.Ref.$API/$VER/ref/net11.0"
  mkdir -p "$W/packs/Microsoft.OpenHarmony.Runtime.$API.openharmony-arm64/$VER/runtimes/openharmony-arm64/lib/net11.0"
  cp "$REFDLL" "$W/packs/Microsoft.OpenHarmony.Ref.$API/$VER/ref/net11.0/"
  cp "$REFDLL" "$W/packs/Microsoft.OpenHarmony.Runtime.$API.openharmony-arm64/$VER/runtimes/openharmony-arm64/lib/net11.0/"
done
echo "   placed into Ref.20.0 / Ref.26.0 and the two platform runtime packs"

echo "== 1b/2 managed hosting bootstrap =="
"$DOTNET" build "$W/src/Microsoft.OpenHarmony.Hosting/Microsoft.OpenHarmony.Hosting.csproj" -c Release -v:q --nologo
HOSTING="$W/src/Microsoft.OpenHarmony.Hosting/bin/Release/net11.0/Microsoft.OpenHarmony.Hosting.dll"
for API in 20.0 26.0; do
  P="$W/packs/Microsoft.OpenHarmony.Runtime.$API.openharmony-arm64/$VER"
  mkdir -p "$P/runtimes/openharmony-arm64/lib/net11.0"
  cp "$HOSTING" "$P/runtimes/openharmony-arm64/lib/net11.0/"
  # Compile-time surface: the bridge API ships in the ref pack too.
  R="$W/packs/Microsoft.OpenHarmony.Ref.$API/$VER/ref/net11.0"
  mkdir -p "$R"
  cp "$HOSTING" "$R/"
  mkdir -p "$W/packs/Microsoft.OpenHarmony.Ref.$API/$VER/data"
  cat > "$W/packs/Microsoft.OpenHarmony.Ref.$API/$VER/data/FrameworkList.xml" <<'XML'
<FileList TargetFrameworkIdentifier=".NETCoreApp" TargetFrameworkVersion="11.0" FrameworkName="Microsoft.OpenHarmony" Name="Microsoft OpenHarmony">
  <File Type="Managed" Path="ref/net11.0/Microsoft.OpenHarmony.dll" AssemblyName="Microsoft.OpenHarmony" PublicKeyToken="" AssemblyVersion="1.0.0.0" FileVersion="1.0.0.0" />
  <File Type="Managed" Path="ref/net11.0/Microsoft.OpenHarmony.Hosting.dll" AssemblyName="Microsoft.OpenHarmony.Hosting" PublicKeyToken="" AssemblyVersion="1.0.0.0" FileVersion="1.0.0.0" />
</FileList>
XML
  mkdir -p "$P/data"
  cat > "$P/data/RuntimeList.xml" <<'XML'
<FileList TargetFrameworkIdentifier=".NETCoreApp" TargetFrameworkVersion="11.0" FrameworkName="Microsoft.OpenHarmony" Name="Microsoft OpenHarmony">
  <File Type="Managed" Path="runtimes/openharmony-arm64/lib/net11.0/Microsoft.OpenHarmony.dll" AssemblyName="Microsoft.OpenHarmony" PublicKeyToken="" AssemblyVersion="1.0.0.0" FileVersion="1.0.0.0" />
  <File Type="Managed" Path="runtimes/openharmony-arm64/lib/net11.0/Microsoft.OpenHarmony.Hosting.dll" AssemblyName="Microsoft.OpenHarmony.Hosting" PublicKeyToken="" AssemblyVersion="1.0.0.0" FileVersion="1.0.0.0" />
</FileList>
XML
done
echo "   hosting bootstrap placed into the two platform runtime packs"

echo "== 1c/2 managed MauiGraphics backend =="
"$DOTNET" build "$W/src/Microsoft.OpenHarmony.Maui.Graphics/Microsoft.OpenHarmony.Maui.Graphics.csproj" -c Release -v:q --nologo
MAUI_GFX="$W/src/Microsoft.OpenHarmony.Maui.Graphics/bin/Release/net11.0/Microsoft.OpenHarmony.Maui.Graphics.dll"
for API in 20.0 26.0; do
  P="$W/packs/Microsoft.OpenHarmony.Runtime.$API.openharmony-arm64/$VER"
  mkdir -p "$P/runtimes/openharmony-arm64/lib/net11.0"
  cp "$MAUI_GFX" "$P/runtimes/openharmony-arm64/lib/net11.0/"
  mkdir -p "$P/data"
  cat > "$P/data/RuntimeList.xml" <<'XML'
<FileList TargetFrameworkIdentifier=".NETCoreApp" TargetFrameworkVersion="11.0" FrameworkName="Microsoft.OpenHarmony" Name="Microsoft OpenHarmony">
  <File Type="Managed" Path="runtimes/openharmony-arm64/lib/net11.0/Microsoft.OpenHarmony.dll" AssemblyName="Microsoft.OpenHarmony" PublicKeyToken="" AssemblyVersion="1.0.0.0" FileVersion="1.0.0.0" />
  <File Type="Managed" Path="runtimes/openharmony-arm64/lib/net11.0/Microsoft.OpenHarmony.Hosting.dll" AssemblyName="Microsoft.OpenHarmony.Hosting" PublicKeyToken="" AssemblyVersion="1.0.0.0" FileVersion="1.0.0.0" />
  <File Type="Managed" Path="runtimes/openharmony-arm64/lib/net11.0/Microsoft.OpenHarmony.Maui.Graphics.dll" AssemblyName="Microsoft.OpenHarmony.Maui.Graphics" PublicKeyToken="" AssemblyVersion="1.0.0.0" FileVersion="1.0.0.0" />
</FileList>
XML
done
echo "   MauiGraphics backend placed into the two platform runtime packs"

echo "== 2/2 BCL runtime pack =="
if [ -f "$BCL/data/RuntimeList.xml" ]; then echo "   already laid out"; exit 0; fi
if [ -z "$NPKG" ]; then
  NPKG="${RUNTIME_PACK_PATH:-/data/storage/el2/base/tmp/opencode/ohos-runtime-pack.nupkg}"
  [ -n "$EXPECT_SHA" ] || EXPECT_SHA="$SHA"
  # A full-size stale/corrupt file would defeat `curl -C -`; drop it once before resuming.
  if [ -f "$NPKG" ] && [ "$(digest_artifact "$NPKG")" != "$EXPECT_SHA" ]; then
    echo "   removing stale $NPKG (sha256 mismatch)"
    rm -f "$NPKG"
  fi
  i=0
  while [ $i -lt 60 ]; do
    i=$((i+1))
    [ -s "$NPKG" ] && [ "$(digest_artifact "$NPKG")" = "$EXPECT_SHA" ] && break
    curl -sL -C - --retry 2 --retry-delay 3 --speed-limit 2048 --speed-time 30 -o "$NPKG" "${RUNTIME_PACK_URL:-$URL}" 2>/dev/null || true
  done
else
  # Re-use of a path artifact requires the digest recorded when it was admitted.
  if [ -z "${RUNTIME_PACK_SHA256:-}" ] && [ -f "$NPKG.sha256" ]; then
    EXPECT_SHA="$(cut -d' ' -f1 < "$NPKG.sha256")"
    echo "   recorded digest from $NPKG.sha256: $EXPECT_SHA"
  fi
  if [ -z "$EXPECT_SHA" ] && [ "$RECORD_SHA256" = 1 ]; then
    [ -f "$NPKG" ] || { echo "artifact not found: $NPKG" >&2; exit 1; }
    EXPECT_SHA="$(digest_artifact "$NPKG")"
    printf '%s  %s\n' "$EXPECT_SHA" "$(basename "$NPKG")" > "$NPKG.sha256"
    echo "   recorded sha256 to $NPKG.sha256: $EXPECT_SHA"
  fi
fi
check_artifact "$NPKG" "BCL runtime pack"
mkdir -p "$BCL"
python3 - "$NPKG" "$BCL" <<'PY'
import os, shutil, sys, zipfile
nupkg, dest = sys.argv[1], sys.argv[2]
zipfile.ZipFile(nupkg).extractall(dest)
old, new = os.path.join(dest,'runtimes','ohos-arm64'), os.path.join(dest,'runtimes','openharmony-arm64')
if os.path.isdir(old): shutil.move(old, new)
rl = os.path.join(dest,'data','RuntimeList.xml')
s = open(rl, encoding='utf-8-sig').read().replace('runtimes/ohos-arm64/','runtimes/openharmony-arm64/')
open(rl,'w',encoding='utf-8').write(s)
PY
echo "   laid out $BCL"


echo "== 2/2 normalize the runtime pack deps.json (RID rename) =="
python3 - "$BCL" <<'PY'
import glob, os, sys
root = sys.argv[1]
count = 0
for path in glob.glob(os.path.join(root, '**', '*.deps.json'), recursive=True):
    with open(path, encoding='utf-8-sig') as handle:
        text = handle.read()
    if 'ohos-arm64' in text:
        with open(path, 'w', encoding='utf-8') as handle:
            handle.write(text.replace('ohos-arm64', 'openharmony-arm64'))
        count += 1
print(f"   rewrote {count} deps.json files under {root}")
PY
