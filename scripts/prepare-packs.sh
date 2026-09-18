#!/bin/sh
# Build the thin platform ref assembly and lay out every local workload pack.
#   scripts/prepare-packs.sh [path-to-Microsoft.NETCore.App.Runtime.openharmony-arm64.nupkg]
# Without an argument the released runtime pack is downloaded from the fork's
# -openharmony release and verified by sha256.
set -e
W="$(cd "$(dirname "$0")/.." && pwd)"
VER=1.0.0-preview.23
DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"
RTV=11.0.0-rc.1.26451.109
SHA=b9fff88aadd4bbfc73964d0fdb05dc551755fd956332cd7d44cf06556f51
URL="https://github.com/springmin/runtime-ohos/releases/download/v11.0.0-rc.1.26451.109-openharmony/Microsoft.NETCore.App.Runtime.openharmony-arm64.$RTV.nupkg"
BCL="$W/packs/Microsoft.NETCore.App.Runtime.openharmony-arm64/$RTV"

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
NPKG="$1"
if [ -z "$NPKG" ]; then
  NPKG=/data/storage/el2/base/tmp/opencode/ohos-runtime-pack.nupkg
  i=0
  while [ $i -lt 60 ]; do
    i=$((i+1))
    [ -s "$NPKG" ] && [ "$(sha256sum "$NPKG" | cut -d' ' -f1)" = "$SHA" ] && break
    curl -sL -C - --retry 2 --retry-delay 3 --speed-limit 2048 --speed-time 30 -o "$NPKG" "$URL" 2>/dev/null || true
  done
  [ "$(sha256sum "$NPKG" | cut -d' ' -f1)" = "$SHA" ] || { echo "download failed or sha mismatch" >&2; exit 1; }
fi
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
