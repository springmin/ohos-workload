#!/bin/sh
# Builds libopenharmonyhost.so (arm64-v8a) with the OpenHarmony NDK and places it
# into the SDK pack. The library is signed with the OpenHarmony test material
# because the device refuses to dlopen unsigned libraries (and refuses to exec
# unsigned ELF files). Set SKIP_SIGN=1 to keep it unsigned.
set -e
W="$(cd "$(dirname "$0")/.." && pwd)"
VER=1.0.0-preview.24
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
    -lace_napi.z -lace_ndk.z -lhilog_ndk.z -lnative_window -lnative_drawing -limage_source -lpixelmap \
    -lohvibrator.z -lnet_connection -lability_access_control -llocation_ndk -lohsensor -ldl
ls -l "$OUT/libopenharmonyhost.so"

# Load-time surface check: the host must carry NO DT_NEEDED on libhostfxr.so. hostfxr lives in
# the app payload (dotnet.zip, extracted by EntryAbility at start_app time) and is resolved
# through the dlopen handle in openharmony_host.c, never at link time. A NEEDED entry would be
# resolved by the HAP loader when the ArkTS module imports libopenharmonyhost.so at ability
# load - before dotnet.zip is extracted - so the import would fail, `host` would be undefined
# and the shell's guarded calls would report unavailability. Fail the build instead of shipping
# such a host; the printed list is the load-time surface that must stay SDK/system-provided.
READELF="${READELF:-$NATIVE/llvm/bin/llvm-readelf}"
if [ ! -x "$READELF" ]; then
    READELF="$(command -v readelf || true)"
fi
[ -n "$READELF" ] || { echo "ERROR: no llvm-readelf/readelf found to audit DT_NEEDED" >&2; exit 1; }
if "$READELF" -d "$OUT/libopenharmonyhost.so" 2>/dev/null | grep -q 'libhostfxr'; then
    echo "ERROR: libopenharmonyhost.so has DT_NEEDED libhostfxr.so; drop the -lhostfxr link flag" >&2
    echo "       and route every hostfxr_* call through the existing dlopen/dlsym handle" >&2
    exit 1
fi
echo "== DT_NEEDED (libhostfxr must be absent; all others SDK/system-provided) =="
"$READELF" -d "$OUT/libopenharmonyhost.so" | sed -n 's/.*(NEEDED).*Shared library: \[\(.*\)\]/    \1/p'

if [ "${SKIP_SIGN:-0}" = "1" ]; then
    echo "== signing skipped (SKIP_SIGN=1) =="
    exit 0
fi

echo "== signing libopenharmonyhost.so (SDK selfsign algorithm) =="
sh "$W/scripts/selfsign.sh" "$OUT/libopenharmonyhost.so"
ls -l "$OUT/libopenharmonyhost.so"
