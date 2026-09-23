#!/bin/sh
# Signs OpenHarmony ELF files with the SDK's own signing algorithm (ElfSigner, shared
# with the OpenHarmonyCodesign MSBuild task and the `dotnet selfsign` command).
# Preference order:
#   1. `selfsign` on PATH (or next to the dotnet muxer / in DOTNET_ROOT)
#   2. `dotnet <selfsign.dll>` built from a sdk-ohos checkout (SDK_REPO, default
#      ~/springsources/sdk-ohos) into .signing/
#   3. `binary-sign-tool ... -selfSign 1` (last resort; older toolchains only)
# Usage: selfsign.sh <file> [file...]
set -e
W="$(cd "$(dirname "$0")/.." && pwd)"
DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"
DOTNET_ROOT_DIR="$(dirname "$DOTNET")"

find_selfsign_bin() {
    for cand in "$DOTNET_ROOT_DIR/selfsign" "$(command -v selfsign 2>/dev/null || true)"; do
        [ -n "$cand" ] && [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
    done
    return 1
}

ensure_selfsign_dll() {
    WORK="$W/.signing/selfsign"
    DLL="$WORK/bin/Release/net11.0/selfsign.dll"
    [ -f "$DLL" ] && { printf '%s\n' "$DLL"; return 0; }
    REPO="${SDK_REPO:-$HOME/springsources/sdk-ohos}"
    SRC="$REPO/eng/ohos-install/selfsign.cs"
    SIGNER="$REPO/src/Tasks/Microsoft.NET.Build.Tasks/ElfSigner.cs"
    [ -f "$SRC" ] && [ -f "$SIGNER" ] || return 1
    mkdir -p "$WORK"
    cp "$SRC" "$WORK/selfsign.cs"
    cp "$SIGNER" "$WORK/ElfSigner.cs"
    cat > "$WORK/selfsign.csproj" <<'PROJ'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net11.0</TargetFramework>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
    <Nullable>disable</Nullable>
    <AssemblyName>selfsign</AssemblyName>
    <InvariantGlobalization>true</InvariantGlobalization>
    <EnforceCodeStyleInBuild>false</EnforceCodeStyleInBuild>
    <BaseOutputPath>bin/</BaseOutputPath>
    <BaseIntermediateOutputPath>obj/</BaseIntermediateOutputPath>
    <RestoreOutputPath>obj/</RestoreOutputPath>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="selfsign.cs" />
    <Compile Include="ElfSigner.cs" />
  </ItemGroup>
</Project>
PROJ
    "$DOTNET" build "$WORK/selfsign.csproj" -c Release -v:q --nologo >/dev/null 2>&1 || return 1
    [ -f "$DLL" ] && printf '%s\n' "$DLL"
}

SIGNER_BIN="$(find_selfsign_bin || true)"
SIGNER_DLL="$(ensure_selfsign_dll || true)"

for file in "$@"; do
    if [ -n "$SIGNER_BIN" ]; then
        "$SIGNER_BIN" "$file"
    elif [ -n "$SIGNER_DLL" ]; then
        "$DOTNET" "$SIGNER_DLL" "$file"
    else
        TOOLCHAIN="${OHOS_TOOLCHAIN:-}"
        if [ -n "$TOOLCHAIN" ] && [ -x "$TOOLCHAIN/binary-sign-tool" ]; then
            "$TOOLCHAIN/binary-sign-tool" sign -keyAlias "openharmony application release" \
                -signAlg SHA256withECDSA -appCertFile "$TOOLCHAIN/OpenHarmonyApplication.pem" \
                -profileFile "$W/.signing/debug.p7b" -inFile "$file" -outFile "$file.signed" \
                -keystoreFile "$TOOLCHAIN/OpenHarmony.p12" -keystorePwd 123456 -keyPwd 123456 \
                -profileSigned 1 -selfSign 1
            cat "$file.signed" > "$file"
        else
            echo "selfsign: no signer available (set SDK_REPO or install selfsign/binary-sign-tool)" >&2
            exit 1
        fi
    fi
done
