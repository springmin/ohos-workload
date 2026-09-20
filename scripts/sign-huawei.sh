#!/bin/sh
# Signs a hap with DevEco Studio's auto-signing materials (Huawei-issued certificate + debug profile).
# The Studio-encrypted password (00000020...) is decrypted locally through the hvigor plugin's own
# DecipherUtil and the signing material in <config>/material/{fd,ac,ce}.
#
# Usage: sign-huawei.sh <unsigned.hap> <out.hap> [configDir] [encryptedPassword]
#   configDir default: $HOME/Documents/ohos/config     (Studio writes the material there)
#   encryptedPassword: the storePassword/keyPassword value from build-profile.json5
# Requires: node, the extracted hvigor-ohos-plugin (ARKTS_PLUGIN_DIR or ~/arkts-build/node_modules/@ohos/hvigor-ohos-plugin),
#           and hap-sign-tool (SDK toolchains/lib).
set -e
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

[ $# -ge 2 ] || { echo "usage: sign-huawei.sh <unsigned.hap> <out.hap> [configDir] [encryptedPassword]" >&2; exit 2; }
IN="$1"; OUT="$2"
CFG="${3:-$HOME/Documents/ohos/config}"
PLUGIN="${ARKTS_PLUGIN_DIR:-$HOME/arkts-build/node_modules/@ohos/hvigor-ohos-plugin}"
SDK="${OHOS_SDK_ROOT:-$HOME/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_2}"
TOOL="$SDK/toolchains/lib/hap-sign-tool"

[ -f "$IN" ]   || die "unsigned hap not found: $IN"
[ -d "$CFG/material/fd" ] || die "signing material not found under $CFG/material (was the project auto-signed?)"
[ -f "$PLUGIN/src/utils/decipher-util.js" ] || die "hvigor plugin not found: $PLUGIN (set ARKTS_PLUGIN_DIR)"
[ -x "$TOOL" ] || die "hap-sign-tool not found: $TOOL (set OHOS_SDK_ROOT)"

P12=$(ls "$CFG"/*.p12 2>/dev/null | head -1); CER=$(ls "$CFG"/*.cer 2>/dev/null | head -1); P7B=$(ls "$CFG"/*.p7b 2>/dev/null | head -1)
[ -n "$P12" ] && [ -n "$CER" ] && [ -n "$P7B" ] || die "p12/cer/p7b not all present under $CFG"
HEX="$4"
if [ -z "$HEX" ]; then
  # Reuse the last decrypted password when present, otherwise require the encrypted value.
  if [ -f /data/storage/el2/base/tmp/opencode/ohos-pwd.txt ]; then
    PW=$(cat /data/storage/el2/base/tmp/opencode/ohos-pwd.txt)
    log "using cached decrypted password"
  else
    die "no encryptedPassword argument and no cached password; pass the build-profile storePassword value"
  fi
else
  DEC=/data/storage/el2/base/tmp/opencode/decrypt.js
  [ -f "$DEC" ] || cat > "$DEC" <<'JS'
const { DecipherUtil } = require(process.argv[2] + '/src/utils/decipher-util.js');
process.stdout.write(DecipherUtil.decryptPwd(process.argv[3], process.argv[4], 'password'));
JS
  PW=$(node "$DEC" "$PLUGIN" "$CFG" "$HEX") || die "password decryption failed"
  printf '%s' "$PW" > /data/storage/el2/base/tmp/opencode/ohos-pwd.txt; chmod 600 /data/storage/el2/base/tmp/opencode/ohos-pwd.txt
  log "password decrypted from the Studio value"
fi

log "signing $(basename "$IN") with the Huawei material (alias debugKey)"
"$TOOL" sign-app -keyAlias debugKey -signAlg SHA256withECDSA -mode localSign \
  -appCertFile "$CER" -profileFile "$P7B" -inFile "$IN" -outFile "$OUT" \
  -keystoreFile "$P12" -keyPwd "$PW" -keystorePwd "$PW" >/dev/null
T=$(dirname "$OUT")
"$TOOL" verify-app -inFile "$OUT" -outCertChain "$T/.verify-cert.cer" -outProfile "$T/.verify-profile.p7b" 2>&1 | grep -q "verify-app success" \
  || die "verify-app failed for $OUT"
rm -f "$T/.verify-cert.cer" "$T/.verify-profile.p7b"
log "signed + verified: $OUT"
sha256sum "$OUT"
