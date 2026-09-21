#!/bin/sh
# Signs a hap with DevEco Studio's auto-signing materials (Huawei-issued certificate + debug profile).
# The Studio-encrypted password (00000020...) is decrypted locally through the hvigor plugin's own
# DecipherUtil and the signing material in <config>/material/{fd,ac,ce}.
#
# Usage: sign-huawei.sh <unsigned.hap> <out.hap> [configDir] [encryptedPassword]
#   configDir default: $HOME/Documents/ohos/config     (Studio writes the material there)
#   encryptedPassword: the storePassword/keyPassword value from build-profile.json5; can also be
#                      supplied through OHOS_ENC_PWD (preferred: argv is world-readable)
# Requires: node, the extracted hvigor-ohos-plugin (ARKTS_PLUGIN_DIR or ~/arkts-build/node_modules/@ohos/hvigor-ohos-plugin),
#           and hap-sign-tool (SDK toolchains/lib).
#
# Secrets: the decrypt helper is generated into a private mktemp -d (0700, removed on exit/signal)
# and the encrypted/decrypted passwords travel via the environment, never argv. The decrypted p12
# password is kept in this shell only - it is not cached and never written to a predictable path.
# hap-sign-tool has no stdin/env password input (pwdInputMode=1 requires a real tty), so during the
# signing call the p12 password is still visible in that child's argv (-keyPwd/-keystorePwd); it is
# not persisted and disappears with the process.
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

HEX="${4:-${OHOS_ENC_PWD:-}}"
[ -n "$HEX" ] || die "no encryptedPassword argument (OHOS_ENC_PWD is empty or unset); pass the build-profile storePassword value; the decrypted password is no longer cached in shared scratch"

# Private work dir for the generated decrypt helper: unguessable name, 0700, removed on exit/signal.
WORK=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/ohos-sign.XXXXXX") || die "cannot create a private temp dir for the decrypt helper"
cleanup() { if [ -n "$WORK" ]; then rm -rf "$WORK"; fi; }
trap cleanup 0
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

# The helper is generated fresh inside $WORK - never a fixed shared path that another process could
# replace between runs. Paths go via argv (not secret); the encrypted password goes via the
# environment (same-UID-only readable) instead of argv (world-readable).
DEC="$WORK/decrypt.js"
( umask 077; cat > "$DEC" ) <<'JS'
const { DecipherUtil } = require(process.env.OHOS_PLUGIN_DIR + '/src/utils/decipher-util.js');
process.stdout.write(DecipherUtil.decryptPwd(process.env.OHOS_CONFIG_DIR, process.env.OHOS_ENC_PWD, 'password'));
JS
PW=$(OHOS_PLUGIN_DIR="$PLUGIN" OHOS_CONFIG_DIR="$CFG" OHOS_ENC_PWD="$HEX" node "$DEC") || die "password decryption failed"
log "password decrypted from the Studio value"

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
