#!/bin/sh
# Builds libopenharmonyhost.so (arm64-v8a) with the OpenHarmony NDK and places it
# into the SDK pack. The library is signed with the OpenHarmony test material
# because the device refuses to dlopen unsigned libraries (and refuses to exec
# unsigned ELF files). Set SKIP_SIGN=1 to keep it unsigned.
set -e
W="$(cd "$(dirname "$0")/.." && pwd)"
VER=1.0.0-preview.13
NATIVE="${OHOS_NDK:-}"
if [ -z "$NATIVE" ]; then
    ROOT="${OHOS_SDK:-$HOME/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_2}"
    if [ -x "$ROOT/native/llvm/bin/clang++" ]; then NATIVE="$ROOT/native";
    elif [ -x "$ROOT/llvm/bin/clang++" ]; then NATIVE="$ROOT";
    else NATIVE="$ROOT/native"; fi
fi
LLD="${LLD:-$HOME/.harmonybrew/opt/llvm@21/bin/ld.lld}"
SRC="$W/src/OpenHarmonyHost"
OUT="$W/packs/Microsoft.OpenHarmony.Sdk/$VER/hosts/arm64-v8a"

echo "== building libopenharmonyhost.so =="
mkdir -p "$OUT"
"$NATIVE/llvm/bin/clang++" --target=aarch64-linux-ohos --sysroot="$NATIVE/sysroot" \
    -fPIC -shared -O2 -std=c++17 -Wall \
    -I"$NATIVE/sysroot/usr/include" \
    --ld-path="$LLD" \
    -Wl,-soname,libopenharmonyhost.so \
    -o "$OUT/libopenharmonyhost.so" \
    "$SRC/host_napi.cpp" "$SRC/openharmony_host.c" \
    -lace_napi.z -lace_ndk.z -lhilog_ndk.z -lnative_window -lnative_drawing -limage_source -lpixelmap -ldl
ls -l "$OUT/libopenharmonyhost.so"

if [ "${SKIP_SIGN:-0}" = "1" ]; then
    echo "== signing skipped (SKIP_SIGN=1) =="
    exit 0
fi

echo "== signing libopenharmonyhost.so (SDK selfsign algorithm) =="
sh "$W/scripts/selfsign.sh" "$OUT/libopenharmonyhost.so"
ls -l "$OUT/libopenharmonyhost.so"
