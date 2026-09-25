#!/bin/sh
# Builds libopenharmonyhost.so (arm64-v8a) with the OpenHarmony NDK and places it
# into the SDK pack. The library is signed with the OpenHarmony test material
# because the device refuses to dlopen unsigned libraries (and refuses to exec
# unsigned ELF files). Set SKIP_SIGN=1 to keep it unsigned.
#
# Two load-time gates run after the link; both fail the build instead of shipping a host
# that would not dlopen on a reduced system image:
#   1. DT_NEEDED whitelist  - only the sonames in src/OpenHarmonyHost/host-deps.conf
#      [needed] may appear; everything else must go through host_optional.c (dlopen/dlsym).
#   2. UND denylist         - nm -D -u must not reference the [undefined] API namespaces
#      (IME, NativeWindow, Vibrator, Sensor, Location, NetConn, AT, ImageSource/Pixelmap,
#      hilog), which are resolved at runtime and may be missing on the device.
# libhostfxr.so has its own dedicated check below (it lives in the app payload and must
# never become a DT_NEEDED entry).
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
POLICY="$SRC/host-deps.conf"

[ -f "$POLICY" ] || { echo "ERROR: missing link policy $POLICY" >&2; exit 1; }
# [needed]: allowed DT_NEEDED sonames. [undefined]: API prefixes banned from nm -D -u.
needed_allow="$(awk '/^\[needed\]/{in_section=1; next} /^\[/{in_section=0} in_section && $0 !~ /^[[:space:]]*#/ && NF {print $1}' "$POLICY")"
undefined_deny="$(awk '/^\[undefined\]/{in_section=1; next} /^\[/{in_section=0} in_section && $0 !~ /^[[:space:]]*#/ && NF {print $1}' "$POLICY")"
[ -n "$needed_allow" ] || { echo "ERROR: $POLICY has no [needed] entries" >&2; exit 1; }
[ -n "$undefined_deny" ] || { echo "ERROR: $POLICY has no [undefined] entries" >&2; exit 1; }

echo "== building libopenharmonyhost.so =="
mkdir -p "$OUT"
# The link line carries only the guaranteed libraries (see host-deps.conf [needed]); every
# optional system library is resolved at runtime in host_optional.c. -lhilog_ndk.z,
# -lnative_window, -limage_source, -lpixelmap, -lohvibrator.z, -lnet_connection,
# -lability_access_control, -llocation_ndk and -lohsensor must NOT come back here.
"$NATIVE/llvm/bin/clang++" --target=aarch64-linux-ohos --sysroot="$NATIVE/sysroot" \
    -fPIC -shared -O2 -std=c++17 -Wall \
    -I"$NATIVE/sysroot/usr/include" \
    --ld-path="$LLD" \
    -Wl,-soname,libopenharmonyhost.so \
    -o "$OUT/libopenharmonyhost.so" \
    "$SRC/host_napi.cpp" "$SRC/openharmony_host.c" "$SRC/host_optional.c" \
    -lace_napi.z -lace_ndk.z -lnative_drawing -ldl
ls -l "$OUT/libopenharmonyhost.so"

READELF="${READELF:-$NATIVE/llvm/bin/llvm-readelf}"
if [ ! -x "$READELF" ]; then
    READELF="$(command -v readelf || true)"
fi
[ -n "$READELF" ] || { echo "ERROR: no llvm-readelf/readelf found to audit DT_NEEDED" >&2; exit 1; }
NM="${NM:-$NATIVE/llvm/bin/llvm-nm}"
if [ ! -x "$NM" ]; then
    NM="$(command -v nm || true)"
fi
[ -n "$NM" ] || { echo "ERROR: no llvm-nm/nm found to audit undefined symbols" >&2; exit 1; }

# Load-time surface check: the host must carry NO DT_NEEDED on libhostfxr.so. hostfxr lives in
# the app payload (dotnet.zip, extracted by EntryAbility at start_app time) and is resolved
# through the dlopen handle in openharmony_host.c, never at link time. A NEEDED entry would be
# resolved by the HAP loader when the ArkTS module imports libopenharmonyhost.so at ability
# load - before dotnet.zip is extracted - so the import would fail, `host` would be undefined
# and the shell's guarded calls would report unavailability. Fail the build instead of shipping
# such a host; the printed list is the load-time surface that must stay SDK/system-provided.
if "$READELF" -d "$OUT/libopenharmonyhost.so" 2>/dev/null | grep -q 'libhostfxr'; then
    echo "ERROR: libopenharmonyhost.so has DT_NEEDED libhostfxr.so; drop the -lhostfxr link flag" >&2
    echo "       and route every hostfxr_* call through the existing dlopen/dlsym handle" >&2
    exit 1
fi
echo "== DT_NEEDED (libhostfxr must be absent; all others SDK/system-provided) =="
"$READELF" -d "$OUT/libopenharmonyhost.so" | sed -n 's/.*(NEEDED).*Shared library: \[\(.*\)\]/    \1/p'

# --- gate 1: DT_NEEDED must be a subset of [needed] --------------------------------
needed_list="$("$READELF" -d "$OUT/libopenharmonyhost.so" 2>/dev/null | sed -n 's/.*(NEEDED).*Shared library: \[\(.*\)\]/\1/p')"
echo "== DT_NEEDED whitelist: src/OpenHarmonyHost/host-deps.conf =="
bad_needed=""
for lib in $needed_list; do
    printf '%s\n' "$needed_allow" | grep -qxF "$lib" || bad_needed="$bad_needed $lib"
done
if [ -n "$bad_needed" ]; then
    echo "ERROR: DT_NEEDED outside the guaranteed set:$bad_needed" >&2
    echo "       a reduced device image does not ship these; resolve the symbols with" >&2
    echo "       dlopen/dlsym (src/OpenHarmonyHost/host_optional.c) instead of linking" >&2
    exit 1
fi
printf '    allowed: %s\n' "$(printf '%s' "$needed_allow" | tr '\n' ' ')"

# --- gate 2: no direct reference to an optional API namespace ----------------------
und_list="$("$NM" -D -u "$OUT/libopenharmonyhost.so" 2>/dev/null | awk '{print $NF}')"
und_count="$(printf '%s\n' "$und_list" | grep -c . || true)"
echo "== UND denylist (optional APIs must be dlsym-resolved; total UND symbols: $und_count) =="
bad_und=0
for prefix in $undefined_deny; do
    hits="$(printf '%s\n' "$und_list" | grep -F "$prefix" || true)"
    if [ -n "$hits" ]; then
        echo "ERROR: direct reference to '$prefix' (denied by $POLICY):" >&2
        printf '%s\n' "$hits" | sed 's/^/       /' >&2
        bad_und=1
    fi
done
[ "$bad_und" = "0" ] || {
    echo "       route the call through the host_optional.h wrapper instead" >&2
    exit 1
}
echo "    ok: no optional-library symbol in nm -D -u"

# --- gate 3: the managed export contract (FIX-INTEROP #1) ---------------------------
# The library is compiled as C++, so a host function lacking C linkage exports only a _Z...
# mangled symbol and the managed EntryPoint lookup fails at runtime. Every name in
# host-exports.txt (the unique DllImport EntryPoints of the managed slice/hosting) must be a
# plain defined symbol. scripts/check-host-exports.py enforces the static half in CI; this is
# the built-library half.
EXPORTS_CONTRACT="$SRC/host-exports.txt"
[ -f "$EXPORTS_CONTRACT" ] || { echo "ERROR: missing export contract $EXPORTS_CONTRACT" >&2; exit 1; }
export_list="$("$NM" -D "$OUT/libopenharmonyhost.so" 2>/dev/null | awk '$2 ~ /^[TtWw]$/ {print $NF}')"
echo "== managed export contract: $EXPORTS_CONTRACT =="
missing_exports=""
expected_count=0
while IFS= read -r name; do
    case "$name" in ''|'#'*) continue ;; esac
    expected_count=$((expected_count + 1))
    printf '%s\n' "$export_list" | grep -qxF "$name" || missing_exports="$missing_exports $name"
done < "$EXPORTS_CONTRACT"
if [ -n "$missing_exports" ]; then
    echo "ERROR: libopenharmonyhost.so is missing managed EntryPoints:$missing_exports" >&2
    echo "       a symbol that exists only as _Z... means the definition lost its C linkage;" >&2
    echo "       declare it in src/OpenHarmonyHost/openharmony_host.h (extern \"C\" block)." >&2
    echo "       mangled candidates found:" >&2
    for name in $missing_exports; do
        printf '%s\n' "$export_list" | grep -F "_Z" | grep -F "$name" | sed 's/^/         /' >&2
    done
    exit 1
fi
echo "    ok: all $expected_count expected exports present as plain symbols"

if [ "${SKIP_SIGN:-0}" = "1" ]; then
    echo "== signing skipped (SKIP_SIGN=1) =="
    exit 0
fi

echo "== signing libopenharmonyhost.so (SDK selfsign algorithm) =="
sh "$W/scripts/selfsign.sh" "$OUT/libopenharmonyhost.so"
ls -l "$OUT/libopenharmonyhost.so"
