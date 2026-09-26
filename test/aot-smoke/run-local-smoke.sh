#!/bin/sh
# Local NativeAOT smoke for a running OpenHarmony host (no device, no hdc): both host AOT
# routes (docs/aot-single-entry.md) are exercised in-process with the hand-written stand-in
# application library, exactly like the device instructions in fake-aot-app.c, but using the
# local host's own libopenharmonyhost.so.
#
#   clang --target=aarch64-linux-ohos  ->  libFakeApp.so + test_host
#   binary-sign-tool -selfSign 1       ->  both binaries (see "codesign" below)
#   LD_LIBRARY_PATH=<pack host dir>    ->  ./test_host <dir> FakeApp.dll alpha beta
#   asserts: stdout "managed exit code = 7", payload-received.txt ==
#            "<dir>/FakeApp.dll\nalpha\nbeta"
#   LD_LIBRARY_PATH=<pack host dir>    ->  ./test_host --bridge <dir> FakeApp.dll '{}'
#   asserts (R2-SHELL-EXT): the same payload file == "<dir>/FakeApp.dll" (no args on the
#            bridged command line) and the same exit code, through start_app's aot=1 route
#
# codesign: an OpenHarmony kernel refuses an unsigned ELF twice - execve returns EACCES
# ("Permission denied" from the shell) and dlopen of a library without a .codesign section
# fails the same way. The SDK's binary-sign-tool with -selfSign 1 is what makes the two
# local test binaries loadable; the real published .so already carries a codesign section
# (OpenHarmonyCodesign runs inside the NativeAOT publish).
#
# Env:
#   OPENHARMONY_SDK_ROOT / OHOS_SDK_ROOT   SDK root with bin/binary-sign-tool + native/
#                                          (default: the local homebrew Cellar layout)
#   CC                                     clang with an aarch64-linux-ohos default target
#                                          (default: clang from PATH)
#   HOSTLIB_DIR                            dir with libopenharmonyhost.so
#                                          (default: the local workload pack's hosts/arm64-v8a)
#   OUT                                    work directory (default: a fresh mktemp -d)
#   KEEP=1                                 keep the work directory on success
set -u

W="$(cd "$(dirname "$0")/../.." && pwd)"
CC="${CC:-clang}"
OUT="${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/aot-smoke.XXXXXX")}" || exit 1

if [ -z "${OPENHARMONY_SDK_ROOT:-}" ] && [ -z "${OHOS_SDK_ROOT:-}" ]; then
    for _dir in "$HOME"/.harmonybrew/Cellar/ohos-sdk/*/; do
        [ -x "${_dir}bin/binary-sign-tool" ] && OPENHARMONY_SDK_ROOT="${_dir%/}" && break
    done
fi
SDK="${OPENHARMONY_SDK_ROOT:-${OHOS_SDK_ROOT:-}}"
SIGN="$SDK/bin/binary-sign-tool"
[ -x "$SIGN" ] || {
    echo "SKIP: binary-sign-tool not found; set OPENHARMONY_SDK_ROOT to the SDK root (tried '$SDK')" >&2
    exit 0
}
[ -n "${HOSTLIB_DIR:-}" ] || HOSTLIB_DIR="$W/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.24/hosts/arm64-v8a"
[ -f "$HOSTLIB_DIR/libopenharmonyhost.so" ] || {
    echo "SKIP: libopenharmonyhost.so not found in '$HOSTLIB_DIR' (build it with scripts/build-host.sh)" >&2
    exit 0
}

echo "== build the fake AOT app + the host driver for aarch64-linux-ohos =="
"$CC" -x c --target=aarch64-linux-ohos -fPIC -shared -O1 \
    -o "$OUT/libFakeApp.so.unsigned" "$W/test/aot-smoke/fake-aot-app.c" || exit 1
"$CC" --target=aarch64-linux-ohos -I "$W/src/OpenHarmonyHost" \
    -o "$OUT/test_host.unsigned" "$W/src/OpenHarmonyHost/test_host.c" -ldl || exit 1

echo "== self-sign both (the kernel refuses unsigned ELFs) =="
"$SIGN" sign -inFile "$OUT/libFakeApp.so.unsigned" -outFile "$OUT/libFakeApp.so" -selfSign 1 >/dev/null || exit 1
"$SIGN" sign -inFile "$OUT/test_host.unsigned" -outFile "$OUT/test_host" -selfSign 1 >/dev/null || exit 1
chmod +x "$OUT/test_host"

echo "== run the host's one-shot AOT route =="
cd "$OUT" || exit 1
export LD_LIBRARY_PATH="$HOSTLIB_DIR:$SDK/native/sysroot/usr/lib/aarch64-linux-ohos${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
rm -f payload-received.txt
timeout 60 ./test_host "$OUT" FakeApp.dll alpha beta
rc=$?

expected="$(printf '%s/FakeApp.dll\nalpha\nbeta' "$OUT")"
actual="$(cat payload-received.txt 2>/dev/null)"
if [ "$rc" != "7" ] || [ "$actual" != "$expected" ]; then
    echo "[FAIL] one-shot rc=$rc (expected 7); payload-received.txt:" >&2
    printf '%s\n' "$actual" >&2
    exit 1
fi
echo "[PASS] NativeAOT single-entry route: payload and exit code match (libFakeApp.so)"

echo "== run the host's bridged AOT route (start_app) =="
rm -f payload-received.txt
timeout 60 ./test_host --bridge "$OUT" FakeApp.dll '{}'
rc=$?

expected="$(printf '%s/FakeApp.dll' "$OUT")"
actual="$(cat payload-received.txt 2>/dev/null)"
if [ "$rc" = "7" ] && [ "$actual" = "$expected" ]; then
    echo "[PASS] NativeAOT bridged route (start_app): payload and exit code match (aot=1)"
    [ "${KEEP:-0}" = "1" ] || rm -rf "$OUT"
    exit 0
fi
echo "[FAIL] bridged rc=$rc (expected 7); payload-received.txt:" >&2
printf '%s\n' "$actual" >&2
exit 1
