#!/bin/sh
# Re-signs the demo hap with a debug profile bound to a specific device (UDID list).
# The profile comes from the SDK's UnsgnedDebugProfileTemplate.json; device-ids are replaced.
#
# Usage:
#   scripts/sign-for-device.sh <udid[,udid...]> [--version <packVer>] [--bundle <name>]
#                              [--unsigned <hap>] [--out <hap>]
# Env:
#   OHOS_SDK_ROOT   OpenHarmony SDK root (default: the harmonybrew 26.0.0.18_2 install)
set -e

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

W="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 1 ] || { warn "usage: sign-for-device.sh <udid[,udid...]> [options]"; exit 2; }
UDID="$1"; shift

VER="$(ls "$W/packs/Microsoft.OpenHarmony.Sdk" | tail -1)"
UNSIGNED="$W/test/hello-maui-app/bin/Release/net11.0-openharmony26.0/openharmony-arm64/hello-maui-app-unsigned.hap"
BUNDLE="com.example.hello-maui-app"
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VER="$2"; shift 2 ;;
    --bundle) BUNDLE="$2"; shift 2 ;;
    --unsigned) UNSIGNED="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) warn "unknown option: $1"; exit 2 ;;
  esac
done

SDK="${OHOS_SDK_ROOT:-$HOME/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_2}"
TOOLCHAIN="$SDK/toolchains/lib"
SIGN="$W/packs/Microsoft.OpenHarmony.Sdk/$VER/templates/scripts/sign-hap.sh"

[ -x "$TOOLCHAIN/hap-sign-tool" ] || { warn "hap-sign-tool not found in $TOOLCHAIN (set OHOS_SDK_ROOT)"; exit 1; }
[ -f "$UNSIGNED" ] || { warn "unsigned hap not found: $UNSIGNED"; exit 1; }
[ -f "$SIGN" ] || { warn "sign-hap.sh not found: $SIGN (wrong --version?)"; exit 1; }

[ -n "$OUT" ] || OUT="$(dirname "$UNSIGNED")/hello-maui-app-$(echo "$UDID" | cut -c1-8).hap"

sh "$SIGN" "$TOOLCHAIN" "$UNSIGNED" "$OUT" "$BUNDLE" "$UDID"
sha256sum "$OUT"
log "device-bound hap: $OUT"
