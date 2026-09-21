#!/bin/sh
# Signs a hap with DevEco Studio's auto-signing materials (Huawei-issued certificate + debug profile).
# The Studio-encrypted password (00000020...) is decrypted locally through the hvigor plugin's own
# DecipherUtil and the signing material in <config>/material/{fd,ac,ce}.
#
# Usage: sign-huawei.sh [--pwd-input-mode] <unsigned.hap> <out.hap> [configDir] [encryptedPassword]
#   configDir default: $HOME/Documents/ohos/config     (Studio writes the material there)
#   encryptedPassword: the storePassword/keyPassword value from build-profile.json5; can also be
#                      supplied through OHOS_ENC_PWD (preferred: argv is world-readable)
#   --pwd-input-mode (or OHOS_PWD_INPUT_MODE=1): pass -pwdInputMode 1 and omit -keyPwd/-keystorePwd,
#                      so hap-sign-tool prompts for the p12 password on the controlling terminal. In
#                      this mode no encryptedPassword / hvigor plugin is needed and the password never
#                      enters any argv. Without a tty (CI/build scripts) the call is wrapped in
#                      script(1) automatically, so the password can be fed through stdin to the pty;
#                      if script(1) is not installed, the mode fails with a clear error.
# Requires: node + the extracted hvigor-ohos-plugin (ARKTS_PLUGIN_DIR or ~/arkts-build/node_modules/@ohos/hvigor-ohos-plugin)
#           in the default mode only, and hap-sign-tool (SDK toolchains/lib) in both modes.
#
# Secrets: the decrypt helper is generated into a private mktemp -d (0700, removed on exit/signal)
# and the encrypted/decrypted passwords travel via the environment, never argv. The decrypted p12
# password is kept in this shell only - it is not cached and never written to a predictable path.
# In the default (non-tty/CI) mode hap-sign-tool still needs the p12 password on argv
# (-keyPwd/-keystorePwd), so it is visible in that child's argv for the duration of the call; it is
# not persisted and disappears with the process. --pwd-input-mode (pwdInputMode=1) removes that
# residual entirely: the password is read at the tty/pty prompt (fed through stdin when there is no
# tty) and no password argument is passed.
set -e
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
usage: sign-huawei.sh [--pwd-input-mode] <unsigned.hap> <out.hap> [configDir] [encryptedPassword]
  --pwd-input-mode (or OHOS_PWD_INPUT_MODE=1): prompt for the p12 password on the terminal
  (-pwdInputMode 1, no -keyPwd/-keystorePwd); no encryptedPassword / hvigor plugin needed and the
  password never enters argv. Without a tty the call is wrapped in script(1) automatically (feed the
  password on stdin); without tty and without script(1) this mode fails.
EOF
  exit 2
}

MODE="${OHOS_PWD_INPUT_MODE:-0}"
case "$MODE" in
  1) MODE=1 ;;
  ""|0) MODE=0 ;;
  *) die "OHOS_PWD_INPUT_MODE must be 0 or 1 (got: $MODE)" ;;
esac

IN=""; OUT=""; CFG=""; HEX=""; N=0
pos() {
  N=$((N + 1))
  case $N in
    1) IN="$1" ;;
    2) OUT="$1" ;;
    3) CFG="$1" ;;
    4) HEX="$1" ;;
    *) usage ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pwd-input-mode) MODE=1 ;;
    --) shift; while [ $# -gt 0 ]; do pos "$1"; shift; done; break ;;
    --*) printf 'sign-huawei.sh: unknown option: %s\n' "$1" >&2; usage ;;
    *) pos "$1" ;;
  esac
  shift
done

[ -n "$IN" ] && [ -n "$OUT" ] || usage
CFG="${CFG:-$HOME/Documents/ohos/config}"
PLUGIN="${ARKTS_PLUGIN_DIR:-$HOME/arkts-build/node_modules/@ohos/hvigor-ohos-plugin}"
SDK="${OHOS_SDK_ROOT:-$HOME/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_2}"
TOOL="$SDK/toolchains/lib/hap-sign-tool"

# Interactive mode: hap-sign-tool reads the password from the controlling terminal. With a real tty
# it runs directly; without one (CI/build scripts) script(1) provides a pty, and the password can be
# fed through stdin to that pty - it never reaches any argv. No script(1): keep the clear error.
PTY=0
if [ "$MODE" = 1 ] && ! [ -t 0 ]; then
  command -v script >/dev/null 2>&1 \
    || die "interactive password mode requested but stdin is not a tty and script(1) is not available to provide a pty; install util-linux (or busybox) script, or run in a terminal"
  PTY=1
fi

[ -f "$IN" ]   || die "unsigned hap not found: $IN"
[ -d "$CFG/material/fd" ] || die "signing material not found under $CFG/material (was the project auto-signed?)"
if [ "$MODE" = 0 ]; then
  [ -f "$PLUGIN/src/utils/decipher-util.js" ] || die "hvigor plugin not found: $PLUGIN (set ARKTS_PLUGIN_DIR)"
fi
[ -x "$TOOL" ] || die "hap-sign-tool not found: $TOOL (set OHOS_SDK_ROOT)"

P12=$(ls "$CFG"/*.p12 2>/dev/null | head -1); CER=$(ls "$CFG"/*.cer 2>/dev/null | head -1); P7B=$(ls "$CFG"/*.p7b 2>/dev/null | head -1)
[ -n "$P12" ] && [ -n "$CER" ] && [ -n "$P7B" ] || die "p12/cer/p7b not all present under $CFG"

if [ "$MODE" = 0 ]; then
  HEX="${HEX:-${OHOS_ENC_PWD:-}}"
  [ -n "$HEX" ] || die "no encryptedPassword argument (OHOS_ENC_PWD is empty or unset); pass the build-profile storePassword value, or use --pwd-input-mode and type the password at the hap-sign-tool prompt"

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
fi

# Single-quote one word for sh -c. Every character becomes literal; an embedded ' becomes '\''.
# Only used to rebuild the hap-sign-tool command line for script(1) (interactive mode: no password
# in any argv), and the result is never logged.
shquote() {
  _q="'"; _r=$1
  while :; do
    case $_r in
      *\'*) _q="$_q${_r%%\'*}'\''"; _r=${_r#*\'} ;;
      *) printf '%s' "$_q$_r'"; return 0 ;;
    esac
  done
}

# Run hap-sign-tool. Directly with a tty (and always in default mode), exactly as before; when
# PTY=1, script(1) gives it a pty so it can prompt, and the caller feeds the password through
# stdin - it stays out of every argv. The tool's stdout is dropped as in the direct path.
run_tool() {
  if [ "$PTY" = 0 ]; then
    "$TOOL" "$@" >/dev/null
    return
  fi
  CMD="$(shquote "$TOOL")"
  for a in "$@"; do
    CMD="$CMD $(shquote "$a")"
  done
  script -qec "$CMD >/dev/null" /dev/null
}

log "signing $(basename "$IN") with the Huawei material (alias debugKey)"
if [ "$MODE" = 1 ]; then
  if [ "$PTY" = 1 ]; then
    log "interactive mode: no tty, running hap-sign-tool under script(1); feed the password on stdin"
  else
    log "interactive mode: hap-sign-tool will prompt for keystorePwd/keyPwd on the terminal"
  fi
  set -- -pwdInputMode 1
else
  set -- -keyPwd "$PW" -keystorePwd "$PW"
fi
run_tool sign-app -keyAlias debugKey -signAlg SHA256withECDSA -mode localSign \
  -appCertFile "$CER" -profileFile "$P7B" -inFile "$IN" -outFile "$OUT" \
  -keystoreFile "$P12" "$@"
T=$(dirname "$OUT")
"$TOOL" verify-app -inFile "$OUT" -outCertChain "$T/.verify-cert.cer" -outProfile "$T/.verify-profile.p7b" 2>&1 | grep -q "verify-app success" \
  || die "verify-app failed for $OUT"
rm -f "$T/.verify-cert.cer" "$T/.verify-profile.p7b"
log "signed + verified: $OUT"
sha256sum "$OUT"
