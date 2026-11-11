#!/bin/sh
# Signs OpenHarmony ELF files with the workload's own signing algorithm (ElfSigner, shared
# with the OpenHarmonyCodesign MSBuild task and the selfsign CLI).
# Preference order:
#   1. `selfsign` on PATH (or next to the dotnet muxer / in DOTNET_ROOT)
#   2. `dotnet src/selfsign/bin/Release/net11.0/selfsign.dll` built from this workload
#   3. `binary-sign-tool ... -selfSign 1` (last resort; older toolchains only)
# Usage: selfsign.sh <file> [file...]
set -e
W="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${DOTNET:-}" ]; then
    if [ -x "$HOME/.dotnet.11.0.100/dotnet" ]; then DOTNET="$HOME/.dotnet.11.0.100/dotnet"; else DOTNET=dotnet; fi
fi
DOTNET_ROOT_DIR="$(dirname "$DOTNET")"

find_selfsign_bin() {
    for cand in "$DOTNET_ROOT_DIR/selfsign" "$(command -v selfsign 2>/dev/null || true)"; do
        [ -n "$cand" ] && [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
    done
    return 1
}

ensure_selfsign_dll() {
    DLL="$W/src/selfsign/bin/Release/net11.0/selfsign.dll"
    [ -f "$DLL" ] && { printf '%s\n' "$DLL"; return 0; }
    [ -f "$W/src/selfsign/SelfSign.csproj" ] || return 1
    "$DOTNET" build "$W/src/selfsign/SelfSign.csproj" -c Release -v:q --nologo >/dev/null 2>&1 || return 1
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
            echo "selfsign: no signer available (build src/selfsign or install selfsign/binary-sign-tool)" >&2
            exit 1
        fi
    fi
done
