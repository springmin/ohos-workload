#!/bin/sh
# Builds libopenharmonyhost.so (arm64-v8a) with the OpenHarmony NDK and places it
# into the SDK pack. Run on a device/host that has the OpenHarmony SDK, or point
# OHOS_SDK at one.
set -e
W="$(cd "$(dirname "$0")/.." && pwd)"
VER=1.0.0-preview.1
# Accept either an SDK root or its native/ dir (the environment may already set OHOS_SDK).
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
    -o "$OUT/libopenharmonyhost.so" \
    "$SRC/host_napi.cpp" "$SRC/openharmony_host.c" \
    -lace_napi.z -lhilog_ndk.z -ldl
ls -l "$OUT/libopenharmonyhost.so"
