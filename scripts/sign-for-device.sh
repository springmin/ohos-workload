#!/bin/sh
# Re-signs a hap for specific device(s).
#
# Two modes:
#   device (default): builds a debug profile from the SDK's UnsgnedDebugProfileTemplate.json
#                     (device-ids replaced with the given UDID(s)) and signs with the SDK
#                     test keystore; the profile's bundle-name is taken from --bundle.
#   --huawei:         delegates to scripts/sign-huawei.sh, which signs with DevEco Studio's
#                     auto-signing material (Huawei p12/cer/p7b under <configDir>) and
#                     decrypts the Studio-encrypted password via the hvigor plugin.
#                     The hap's module.json bundleName must already match the p7b's
#                     bundle-name (rebuild with -p:OpenHarmonyBundleName=<name>); this is
#                     checked before signing.
#
# Usage:
#   scripts/sign-for-device.sh <udid[,udid...]> [--version <packVer>] [--bundle <name>]
#                              [--unsigned <hap>] [--out <hap>]
#   scripts/sign-for-device.sh --huawei [configDir] [encryptedPassword]
#                              [--unsigned <hap>] [--out <hap>]
#   scripts/sign-for-device.sh --show-profile-devices [<p7b>|--config <dir>]
#                              [--huawei [configDir]]
# Env:
#   OHOS_SDK_ROOT   OpenHarmony SDK root (default: the harmonybrew 26.0.0.18_2 install)
#   OHOS_ENC_PWD    Studio-encrypted password for --huawei, as an alternative to the positional
#                   encryptedPassword (preferred: argv is world-readable); it is forwarded to
#                   sign-huawei.sh through the environment
set -e

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

W="$(cd "$(dirname "$0")/.." && pwd)"
VER="$(ls "$W/packs/Microsoft.OpenHarmony.Sdk" | tail -1)"
UNSIGNED="$W/test/hello-maui-app/bin/Release/net11.0-openharmony26.0/openharmony-arm64/hello-maui-app-unsigned.hap"
BUNDLE="com.example.hello-maui-app"
OUT=""
MODE=device
UDID=""
CFG=""
HEX=""
SHOW=0
P7B=""
VER_SET=0
BUNDLE_SET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --huawei) MODE=huawei; shift ;;
    --show-profile-devices) SHOW=1; shift ;;
    --config)   CFG="$2";  shift 2 ;;
    --password) HEX="$2";  shift 2 ;;
    --profile)  P7B="$2";  shift 2 ;;
    --version)  VER="$2"; VER_SET=1; shift 2 ;;
    --bundle)   BUNDLE="$2"; BUNDLE_SET=1; shift 2 ;;
    --unsigned) UNSIGNED="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    --*) warn "unknown option: $1"; exit 2 ;;
    *)
      if [ "$MODE" = huawei ]; then
        if [ -z "$CFG" ]; then CFG="$1"
        elif [ -z "$HEX" ]; then HEX="$1"
        else warn "unexpected argument: $1"; exit 2
        fi
      elif [ "$SHOW" = 1 ]; then
        if [ -d "$1" ]; then
          [ -z "$CFG" ] || { warn "unexpected argument: $1"; exit 2; }
          CFG="$1"
        else
          [ -z "$P7B" ] || { warn "unexpected argument: $1"; exit 2; }
          P7B="$1"
        fi
      else
        [ -z "$UDID" ] || { warn "unexpected argument: $1"; exit 2; }
        UDID="$1"
      fi
      shift ;;
  esac
done

SDK="${OHOS_SDK_ROOT:-$HOME/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_2}"
TOOLCHAIN="$SDK/toolchains/lib"
SIGN="$W/packs/Microsoft.OpenHarmony.Sdk/$VER/templates/scripts/sign-hap.sh"

# Print the value of the first "<field>":"..." string embedded in a profile (.p7b). The p7b
# carries the plaintext profile JSON, so no openssl/ASN.1 parsing is needed.
p7b_field() {
  python3 - "$1" "$2" <<'PY'
import re, sys
raw = open(sys.argv[1], 'rb').read()
m = re.search(rb'"' + sys.argv[2].encode() + rb'"\s*:\s*"([^"]*)"', raw)
if not m:
    sys.exit(3)
sys.stdout.write(m.group(1).decode('utf-8', 'replace'))
PY
}

# Print one UDID per line from debug-info.device-ids in a profile (.p7b) or in the raw
# UnsgnedDebugProfileTemplate.json. Exit 3 when the list cannot be found.
p7b_device_ids() {
  python3 - "$1" <<'PY'
import re, sys
raw = open(sys.argv[1], 'rb').read()
m = re.search(rb'"device-ids"\s*:\s*\[(.*?)\]', raw, re.S)
if not m:
    sys.exit(3)
ids = re.findall(rb'"([^"]*)"', m.group(1))
if not ids:
    sys.exit(3)
for i in ids:
    sys.stdout.write(i.decode('utf-8', 'replace') + '\n')
PY
}

# Print app.bundleName from module.json inside a hap. Exit 3 when it cannot be read.
hap_bundle_name() {
  python3 - "$1" <<'PY'
import json, sys, zipfile
try:
    with zipfile.ZipFile(sys.argv[1]) as z:
        d = json.loads(z.read('module.json'))
except Exception:
    sys.exit(3)
name = (d.get('app') or {}).get('bundleName') or (d.get('module') or {}).get('bundleName') or ''
if not name:
    sys.exit(3)
sys.stdout.write(name)
PY
}

# --show-profile-devices: print the profile that a target device must be whitelisted in.
if [ "$SHOW" = 1 ]; then
  if [ -z "$P7B" ]; then
    if [ -n "$CFG" ] || [ "$MODE" = huawei ]; then
      [ -n "$CFG" ] || CFG="$HOME/Documents/ohos/config"
      P7B="$(ls "$CFG"/*.p7b 2>/dev/null | head -1)"
      [ -n "$P7B" ] || die "no .p7b found under $CFG"
    else
      PROFILE_WORK="$(dirname "$UNSIGNED")/profile-work"
      if [ -f "$PROFILE_WORK/out.p7b" ]; then P7B="$PROFILE_WORK/out.p7b"
      elif [ -f "$PROFILE_WORK/debug.p7b" ]; then P7B="$PROFILE_WORK/debug.p7b"
      else
        P7B="$TOOLCHAIN/UnsgnedDebugProfileTemplate.json"
        warn "no signed profile under $PROFILE_WORK; showing the SDK template's example device-ids"
      fi
    fi
  fi
  [ -f "$P7B" ] || die "profile not found: $P7B"
  log "profile: $P7B"
  PF="$(p7b_field "$P7B" bundle-name)" || die "cannot read bundle-name from $P7B (not a profile?)"
  log "bundle-name: $PF"
  log "type: $(p7b_field "$P7B" type || echo unknown)"
  IDS="$(p7b_device_ids "$P7B")" || die "no debug-info.device-ids in $P7B (release profile or invalid p7b?)"
  log "device-ids ($(printf '%s\n' "$IDS" | grep -c .)):"
  printf '%s\n' "$IDS"
  exit 0
fi

# --huawei: sign with the Studio auto-signing material through sign-huawei.sh.
if [ "$MODE" = huawei ]; then
  [ "$BUNDLE_SET" = 0 ] || die "--bundle is not available in --huawei mode; the hap must be rebuilt with -p:OpenHarmonyBundleName=<name> so module.json matches the profile"
  [ "$VER_SET" = 0 ] || warn "--version is ignored in --huawei mode (the SDK comes from OHOS_SDK_ROOT)"
  [ -n "$CFG" ] || CFG="$HOME/Documents/ohos/config"
  [ -n "$HEX" ] || HEX="${OHOS_ENC_PWD:-}"
  HUAWEI="$W/scripts/sign-huawei.sh"
  [ -f "$HUAWEI" ] || die "sign-huawei.sh not found: $HUAWEI"
  [ -f "$UNSIGNED" ] || die "unsigned hap not found: $UNSIGNED"
  P7B="$(ls "$CFG"/*.p7b 2>/dev/null | head -1)"
  [ -n "$P7B" ] || die "no .p7b found under $CFG (auto-sign the project in DevEco Studio first)"
  HB="$(hap_bundle_name "$UNSIGNED")" || die "cannot read app.bundleName from module.json in $UNSIGNED"
  PF="$(p7b_field "$P7B" bundle-name)" || die "cannot read bundle-name from $P7B"
  [ "$HB" = "$PF" ] || die "bundle-name mismatch: $UNSIGNED is '$HB' but the Huawei profile $P7B is bound to '$PF'. Rebuild the hap with -p:OpenHarmonyBundleName=$PF (or pass --unsigned with a matching hap), then re-run"
  log "bundle-name check OK: $HB"
  [ -n "$OUT" ] || OUT="$(dirname "$UNSIGNED")/hello-maui-app-huawei.hap"
  # Hand the encrypted password over in the environment, not in sign-huawei.sh's argv.
  OHOS_ENC_PWD="$HEX" sh "$HUAWEI" "$UNSIGNED" "$OUT" "$CFG"
  log "Huawei-signed hap: $OUT"
  exit 0
fi

# Device mode: build an SDK debug profile with the requested UDID(s).
[ -n "$UDID" ] || { warn "usage: sign-for-device.sh <udid[,udid...]> [options] | --huawei [configDir] [encryptedPassword] [--unsigned <hap>] [--out <hap>] | --show-profile-devices [<p7b>]"; exit 2; }
[ -x "$TOOLCHAIN/hap-sign-tool" ] || { warn "hap-sign-tool not found in $TOOLCHAIN (set OHOS_SDK_ROOT)"; exit 1; }
[ -f "$UNSIGNED" ] || { warn "unsigned hap not found: $UNSIGNED"; exit 1; }
[ -f "$SIGN" ] || { warn "sign-hap.sh not found: $SIGN (wrong --version?)"; exit 1; }

HB="$(hap_bundle_name "$UNSIGNED" 2>/dev/null)" || HB=""
if [ -n "$HB" ] && [ "$HB" != "$BUNDLE" ]; then
  warn "module.json bundleName is '$HB' but the profile will use '$BUNDLE' - install fails with 9568344; pass --bundle $HB or rebuild with -p:OpenHarmonyBundleName=$HB"
fi

[ -n "$OUT" ] || OUT="$(dirname "$UNSIGNED")/hello-maui-app-$(echo "$UDID" | cut -c1-8).hap"

sh "$SIGN" "$TOOLCHAIN" "$UNSIGNED" "$OUT" "$BUNDLE" "$UDID"
sha256sum "$OUT"
log "device-bound hap: $OUT"
