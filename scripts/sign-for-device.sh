#!/bin/sh
# Re-signs a hap for specific device(s).
#
# Modes:
#   device (default): builds a debug profile from the SDK's UnsgnedDebugProfileTemplate.json
#                     (device-ids replaced with the given UDID(s)) and signs with the SDK
#                     test keystore; the profile's bundle-name is taken from --bundle
#                     (default: the demo bundle com.example.hellomauiapp - override for a
#                     differently packed hap).
#   --huawei:         delegates to scripts/sign-huawei.sh, which signs with DevEco Studio's
#                     auto-signing material (Huawei p12/cer/p7b under <configDir>) and
#                     decrypts the Studio-encrypted password via the hvigor plugin.
#                     The hap's module.json bundleName must already match the p7b's
#                     bundle-name (rebuild with -p:OpenHarmonyBundleName=<name>); this is
#                     checked before signing.
#   --external:       signs with signing material supplied by another party (e.g. a tester
#                     who obtained a Huawei-issued debug profile with their own locally
#                     generated key): --profile <p7b>, --key <p12>, --key-alias <alias>,
#                     --expect-udid <UDID>. The p7b must list the UDID in
#                     debug-info.device-ids or the run fails before signing (fail closed);
#                     each hap's module.json bundleName must match the p7b's bundle-name,
#                     and the app cert chain (--cert <cer>, or a *.cer next to the p7b)
#                     must contain the profile's development-certificate (the p7b carries
#                     only the leaf; hap-sign-tool needs the chain). Every signed hap is
#                     checked with verify-app before it is kept.
#
# Usage:
#   scripts/sign-for-device.sh <udid[,udid...]> [--version <packVer>] [--bundle <name>]
#                              [--unsigned <hap>] [--out <hap>]
#   scripts/sign-for-device.sh --huawei [configDir] [encryptedPassword]
#                              [--pwd-input-mode] [--unsigned <hap>] [--out <hap>]
#   scripts/sign-for-device.sh --external --profile <p7b> --key <p12> --key-alias <alias>
#                              --expect-udid <UDID> [--cert <cer>] [--pwd-input-mode]
#                              [--key-pwd-file <file>] [--unsigned <hap>]... [--out <hap>]
#                              [--out-dir <dir>]
#   scripts/sign-for-device.sh --show-profile-devices [<p7b>|--config <dir>]
#                              [--huawei [configDir]]
# Env:
#   OHOS_SDK_ROOT   OpenHarmony SDK root (default: the harmonybrew 26.0.0.18_2 install)
#   OHOS_ENC_PWD    Studio-encrypted password for --huawei, as an alternative to the positional
#                   encryptedPassword (preferred: argv is world-readable); it is forwarded to
#                   sign-huawei.sh through the environment
#   OHOS_PWD_INPUT_MODE  same as --pwd-input-mode (1 = interactive prompt; 0 = argv, default)
# --pwd-input-mode (--huawei or --external): in --huawei mode it is forwarded to
#                   sign-huawei.sh; in --external mode hap-sign-tool reads keystorePwd and
#                   keyPwd from the terminal (-pwdInputMode 1, no -keyPwd/-keystorePwd).
#                   Without a tty, script(1) provides a pty automatically (feed the two
#                   prompts on stdin; with --key-pwd-file the file is fed twice) and the
#                   mode fails when script(1) is not installed. The password never enters
#                   argv and is never logged.
# --key-pwd-file <file> (--external only): read the p12 password from the first line of
#                   <file>. With --pwd-input-mode the file is fed through script(1) (still
#                   no argv); without it the password is passed to hap-sign-tool on argv
#                   for the duration of the call (same residual as --huawei's default mode).
set -e

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

W="$(cd "$(dirname "$0")/.." && pwd)"
VER="$(ls "$W/packs/Microsoft.OpenHarmony.Sdk" | tail -1)"
UNSIGNED="$W/test/hello-maui-app/bin/Release/net11.0-openharmony26.0/openharmony-arm64/hello-maui-app-unsigned.hap"
# Demo default; hyphens are illegal in app.bundleName (ohos-workload bbfa03c). Override with
# --bundle <name> (device mode), or rebuild with -p:OpenHarmonyBundleName=<name> when a profile
# fixes another identity. Device mode warns when the hap's module.json disagrees.
BUNDLE="com.example.hellomauiapp"
OUT=""
MODE=device
UDID=""
CFG=""
HEX=""
SHOW=0
P7B=""
VER_SET=0
BUNDLE_SET=0
PWD_INTERACTIVE="${OHOS_PWD_INPUT_MODE:-0}"
KEY=""
ALIAS=""
EXPECT=""
CERT=""
OUT_DIR=""
PWD_FILE=""
UNSIGNED_LIST=""
case "$PWD_INTERACTIVE" in
  1) PWD_INTERACTIVE=1 ;;
  ""|0) PWD_INTERACTIVE=0 ;;
  *) die "OHOS_PWD_INPUT_MODE must be 0 or 1 (got: $PWD_INTERACTIVE)" ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --huawei) MODE=huawei; shift ;;
    --external) MODE=external; shift ;;
    --pwd-input-mode) PWD_INTERACTIVE=1; shift ;;
    --show-profile-devices) SHOW=1; shift ;;
    --config)   CFG="$2";  shift 2 ;;
    --password) HEX="$2";  shift 2 ;;
    --profile)  P7B="$2";  shift 2 ;;
    --key)      KEY="$2";  shift 2 ;;
    --key-alias) ALIAS="$2"; shift 2 ;;
    --expect-udid) EXPECT="$2"; shift 2 ;;
    --cert)     CERT="$2"; shift 2 ;;
    --out-dir)  OUT_DIR="$2"; shift 2 ;;
    --key-pwd-file) PWD_FILE="$2"; shift 2 ;;
    --version)  VER="$2"; VER_SET=1; shift 2 ;;
    --bundle)   BUNDLE="$2"; BUNDLE_SET=1; shift 2 ;;
    --unsigned)
      UNSIGNED="$2"
      if [ -n "$UNSIGNED_LIST" ]; then
        UNSIGNED_LIST="$UNSIGNED_LIST
$2"
      else
        UNSIGNED_LIST="$2"
      fi
      shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    --*) warn "unknown option: $1"; exit 2 ;;
    *)
      if [ "$MODE" = huawei ]; then
        if [ -z "$CFG" ]; then CFG="$1"
        elif [ -z "$HEX" ]; then HEX="$1"
        else warn "unexpected argument: $1"; exit 2
        fi
      elif [ "$MODE" = external ]; then
        warn "unexpected argument: $1 (use --profile/--key/--key-alias/--expect-udid)"
        exit 2
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

# --pwd-input-mode selects hap-sign-tool's interactive prompt, which --huawei and
# --external drive.
if [ "$PWD_INTERACTIVE" = 1 ] && [ "$MODE" != huawei ] && [ "$MODE" != external ]; then
  die "--pwd-input-mode / OHOS_PWD_INPUT_MODE=1 is only available with --huawei or --external"
fi

# Options that only make sense for --external.
if [ "$MODE" != external ]; then
  [ -z "$KEY" ]     || die "--key is only available with --external"
  [ -z "$ALIAS" ]   || die "--key-alias is only available with --external"
  [ -z "$EXPECT" ]  || die "--expect-udid is only available with --external"
  [ -z "$CERT" ]    || die "--cert is only available with --external"
  [ -z "$OUT_DIR" ] || die "--out-dir is only available with --external"
  [ -z "$PWD_FILE" ] || die "--key-pwd-file is only available with --external"
fi

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

# Print a dotted field (e.g. bundle-info.bundle-name) from the JSON produced by
# `hap-sign-tool verify-profile`. Exit 3 when the field is missing/empty.
profile_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split('.'):
    if not isinstance(d, dict) or k not in d:
        sys.exit(3)
    d = d[k]
if d is None or d == '':
    sys.exit(3)
sys.stdout.write(str(d))
PY
}

# Print one UDID per line from debug-info.device-ids in a verify-profile JSON.
# Exit 3 when the list is missing (e.g. a release profile).
profile_device_ids() {
  python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(3)
ids = (d.get('debug-info') or {}).get('device-ids') or []
if not ids:
    sys.exit(3)
for i in ids:
    sys.stdout.write(str(i) + '\n')
PY
}

# Print bundle-info.development-certificate (PEM) from a verify-profile JSON.
# Exit 3 when it is missing.
profile_dev_cert() {
  python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(3)
c = (d.get('bundle-info') or {}).get('development-certificate') or ''
if 'BEGIN CERTIFICATE' not in c:
    sys.exit(3)
sys.stdout.write(c if c.endswith('\n') else c + '\n')
PY
}

# 0 when the single certificate in <pem-with-one-cert> is also in <pem-bundle>
# (base64/DER comparison, so line wrapping and line endings do not matter).
cert_contains_pem() {
  python3 - "$1" "$2" <<'PY'
import base64, re, sys
def certs(p):
    return [base64.b64decode(re.sub(rb'\s+', b'', m)) for m in
            re.findall(rb'-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----',
                       open(p, 'rb').read(), re.S)]
leaf = certs(sys.argv[1])
bundle = certs(sys.argv[2])
if not leaf:
    sys.exit(3)
sys.exit(0 if any(c == leaf[0] for c in bundle) else 1)
PY
}

# Single-quote one word for sh -c. Every character becomes literal; an embedded '
# becomes '\''. Only used to rebuild hap-sign-tool's command line for script(1) and
# the result is never logged.
shquote() {
  _q="'"; _r=$1
  while :; do
    case $_r in
      *\'*) _q="$_q${_r%%\'*}'\''"; _r=${_r#*\'} ;;
      *) printf '%s' "$_q$_r'"; return 0 ;;
    esac
  done
}

warn_if_group_other_readable() {
  _p="$(ls -l "$1" 2>/dev/null | cut -c5-10)"
  case "$_p" in *r*|*w*|*x*) warn "password file $1 is group/other accessible; chmod 600 it" ;; esac
}

# Run hap-sign-tool in --external mode. With PTY=0 (a tty is available, or the default
# password mode) it runs directly; with PTY=1 it runs under script(1) so it can read
# keystorePwd/keyPwd from a pty. With --key-pwd-file the file is fed twice (the tool asks
# for both passwords); without it the caller's stdin is passed through (two lines).
# Output goes to $SIG_LOG; in pty mode the pty echoes the fed password, so that log is
# only used for the exit status and is never printed.
run_external_tool() {
  if [ "$PTY" = 0 ]; then
    "$TOOLCHAIN/hap-sign-tool" "$@" > "$SIG_LOG" 2>&1
    return
  fi
  CMD="$(shquote "$TOOLCHAIN/hap-sign-tool")"
  for a in "$@"; do
    CMD="$CMD $(shquote "$a")"
  done
  if [ -n "$PWD_FILE" ]; then
    cat "$PWD_FILE" "$PWD_FILE" | script -qec "$CMD >/dev/null" /dev/null > "$SIG_LOG" 2>&1
  else
    script -qec "$CMD >/dev/null" /dev/null > "$SIG_LOG" 2>&1
  fi
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
  if [ "$PWD_INTERACTIVE" = 1 ]; then
    # Interactive: hap-sign-tool prompts on the tty (-pwdInputMode 1), so no password is forwarded
    # at all (neither argv nor OHOS_ENC_PWD) and the hvigor decrypt step is skipped by sign-huawei.sh.
    [ -z "$HEX" ] || warn "--pwd-input-mode: the supplied encrypted password is ignored (type it at the hap-sign-tool prompt instead)"
    sh "$HUAWEI" --pwd-input-mode "$UNSIGNED" "$OUT" "$CFG"
  else
    # Hand the encrypted password over in the environment, not in sign-huawei.sh's argv.
    OHOS_ENC_PWD="$HEX" sh "$HUAWEI" "$UNSIGNED" "$OUT" "$CFG"
  fi
  log "Huawei-signed hap: $OUT"
  exit 0
fi

# --external: sign with material supplied by another party (their Huawei debug p7b and the
# p12 holding their locally generated key). Never signs unless the profile lists the
# expected UDID and every hap's bundle-name matches the profile.
if [ "$MODE" = external ]; then
  [ "$BUNDLE_SET" = 0 ] || die "--bundle is not available in --external mode; the profile's bundle-name decides the app identity (rebuild with -p:OpenHarmonyBundleName=<name>)"
  [ "$VER_SET" = 0 ] || warn "--version is ignored in --external mode (the SDK comes from OHOS_SDK_ROOT)"
  [ -n "$P7B" ]    || die "--external requires --profile <p7b>"
  [ -n "$KEY" ]    || die "--external requires --key <p12>"
  [ -n "$ALIAS" ]  || die "--external requires --key-alias <alias>"
  [ -n "$EXPECT" ] || die "--external requires --expect-udid <UDID>"
  [ -f "$P7B" ] || die "profile not found: $P7B"
  [ -f "$KEY" ] || die "keystore not found: $KEY"
  [ -x "$TOOLCHAIN/hap-sign-tool" ] || die "hap-sign-tool not found in $TOOLCHAIN (set OHOS_SDK_ROOT)"
  if [ -n "$OUT" ] && [ -n "$OUT_DIR" ]; then die "--out and --out-dir are mutually exclusive"; fi

  IN_LIST="${UNSIGNED_LIST:-$UNSIGNED}"
  NIN="$(printf '%s\n' "$IN_LIST" | grep -c . || true)"
  if [ -n "$OUT" ] && [ "$NIN" -ne 1 ]; then
    die "--out only works with a single --unsigned hap; use --out-dir <dir> for several"
  fi
  [ -z "$OUT_DIR" ] || mkdir -p "$OUT_DIR"

  WORK=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/ohos-ext.XXXXXX") || die "cannot create a private temp dir"
  TMP_OUT=""
  cleanup() {
    if [ -n "$TMP_OUT" ]; then rm -f "$TMP_OUT"; fi
    if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
  }
  trap cleanup 0
  trap 'cleanup; exit 130' INT
  trap 'cleanup; exit 143' TERM
  trap 'cleanup; exit 129' HUP

  # Authoritative extraction of the signed profile (device-ids, bundle-name, cert).
  if ! "$TOOLCHAIN/hap-sign-tool" verify-profile -inFile "$P7B" -outFile "$WORK/profile.json" > "$WORK/verify-profile.log" 2>&1; then
    sed 's/^/    /' "$WORK/verify-profile.log" >&2
    die "cannot extract/verify the signed profile from $P7B (hap-sign-tool verify-profile failed)"
  fi
  PB="$(profile_field "$WORK/profile.json" bundle-info.bundle-name)" || PB=""
  [ -n "$PB" ] || die "no bundle-info.bundle-name in $P7B"
  PT="$(profile_field "$WORK/profile.json" type)" || PT=unknown
  [ "$PT" = debug ] || warn "profile type is '$PT' (a device-bound debug profile is expected)"
  IDS="$(profile_device_ids "$WORK/profile.json")" || die "no debug-info.device-ids in $P7B (release profile or invalid p7b?): cannot pre-sign for a device UDID"
  printf '%s\n' "$IDS" | grep -Fqix "$EXPECT" \
    || die "UDID mismatch: $P7B is not bound to $EXPECT (profile device-ids: $(printf '%s\n' "$IDS" | tr '\n' ' '))"
  log "profile check OK: bundle-name $PB, type $PT, UDID $(echo "$EXPECT" | cut -c1-8)... listed"

  # hap-sign-tool needs the app cert chain (root/sub CA/leaf); the p7b carries only the
  # leaf, so --cert or a sibling *.cer (DevEco config default_*.cer) supplies the chain.
  profile_dev_cert "$WORK/profile.json" > "$WORK/leaf.pem" 2>/dev/null || rm -f "$WORK/leaf.pem"
  if [ -z "$CERT" ]; then
    if [ -f "$WORK/leaf.pem" ]; then
      _matches=""
      for _c in "$(dirname "$P7B")"/*.cer; do
        [ -f "$_c" ] || continue
        if cert_contains_pem "$WORK/leaf.pem" "$_c" 2>/dev/null; then
          _matches="$_matches$_c
"
        fi
      done
      _nmatches="$(printf '%s' "$_matches" | grep -c . || true)"
      case "$_nmatches" in
        1) CERT="$(printf '%s' "$_matches" | head -n1)"
           log "app cert chain (sibling .cer): $CERT" ;;
        0) die "no *.cer next to $P7B contains the profile's development-certificate; pass --cert <app-cert-chain.cer> (DevEco config default_*.cer)" ;;
        *) die "$_nmatches *.cer files next to $P7B contain the profile certificate; pass --cert to choose one" ;;
      esac
    else
      warn "profile has no bundle-info.development-certificate; using a sibling .cer without the leaf check"
      for _c in "$(dirname "$P7B")"/*.cer; do
        [ -f "$_c" ] || continue
        [ -z "$CERT" ] || die "several sibling *.cer files; pass --cert to choose one"
        CERT="$_c"
      done
      [ -n "$CERT" ] || die "app cert chain missing: pass --cert <app-cert-chain.cer> (DevEco config default_*.cer)"
      log "app cert chain (sibling .cer): $CERT"
    fi
  fi
  [ -f "$CERT" ] || die "app cert chain not found: $CERT"
  command -v openssl >/dev/null 2>&1 || die "openssl not found (needed to normalize the app cert chain)"
  openssl crl2pkcs7 -nocrl -certfile "$CERT" 2>/dev/null | openssl pkcs7 -print_certs -out "$WORK/chain.pem" 2>/dev/null \
    || die "cannot convert the app cert chain with openssl: $CERT"
  NC="$(grep -c 'BEGIN CERTIFICATE' "$WORK/chain.pem" || true)"
  [ "$NC" -ge 2 ] || die "app cert chain $CERT has only $NC certificate(s); hap-sign-tool needs the full chain (root/sub CA/leaf) - pass --cert with the DevEco default_*.cer"
  [ "$NC" -le 3 ] || warn "app cert chain $CERT has $NC certificates (expected 3)"
  if [ -f "$WORK/leaf.pem" ]; then
    cert_contains_pem "$WORK/leaf.pem" "$WORK/chain.pem" 2>/dev/null \
      || die "the app cert chain $CERT does not contain the profile's development-certificate (wrong *.cer for this p7b?)"
  fi
  log "app cert chain OK: $CERT ($NC certificates)"

  # Password handling: --pwd-input-mode prompts (script(1) pty when stdin is not a tty;
  # --key-pwd-file feeds the file twice); the default mode needs --key-pwd-file and passes
  # the password to hap-sign-tool on argv for the duration of the call. Never logged.
  PTY=0
  if [ "$PWD_INTERACTIVE" = 1 ]; then
    if [ -n "$PWD_FILE" ]; then
      [ -f "$PWD_FILE" ] || die "password file not found: $PWD_FILE"
      [ -s "$PWD_FILE" ] || die "password file is empty: $PWD_FILE"
      command -v script >/dev/null 2>&1 \
        || die "--key-pwd-file with --pwd-input-mode needs script(1) to feed the password through a pty; install util-linux (or busybox) script"
      PTY=1
      warn_if_group_other_readable "$PWD_FILE"
      log "interactive password mode: password file fed through script(1); no password in argv"
    elif ! [ -t 0 ]; then
      command -v script >/dev/null 2>&1 \
        || die "interactive password mode requested but stdin is not a tty and script(1) is not available to provide a pty; install util-linux (or busybox) script, or run in a terminal"
      PTY=1
      log "interactive password mode: no tty, running hap-sign-tool under script(1); feed keystorePwd and keyPwd (two lines) on stdin"
    else
      log "interactive password mode: hap-sign-tool will prompt for keystorePwd/keyPwd on the terminal"
    fi
    set -- -pwdInputMode 1
  else
    [ -n "$PWD_FILE" ] || die "--external needs the p12 password: use --pwd-input-mode, or --key-pwd-file <file>"
    [ -f "$PWD_FILE" ] || die "password file not found: $PWD_FILE"
    PWS="$(cat "$PWD_FILE")" || die "cannot read password file: $PWD_FILE"
    [ -n "$PWS" ] || die "password file is empty: $PWD_FILE"
    warn_if_group_other_readable "$PWD_FILE"
    set -- -keyPwd "$PWS" -keystorePwd "$PWS"
  fi

  _n=0
  _old_ifs=$IFS
  IFS='
'
  for IN in $IN_LIST; do
    _n=$((_n + 1))
    [ -f "$IN" ] || die "unsigned hap not found: $IN"
    if [ -n "$OUT_DIR" ]; then
      _out="$OUT_DIR/$(basename "$IN")"
    elif [ -n "$OUT" ]; then
      _out="$OUT"
    else
      _out="$(dirname "$IN")/$(basename "$IN" .hap)-$(echo "$EXPECT" | cut -c1-8).hap"
    fi
    HB="$(hap_bundle_name "$IN")" || die "cannot read app.bundleName from module.json in $IN"
    [ "$HB" = "$PB" ] || die "bundle-name mismatch: $IN is '$HB' but the external profile $P7B is bound to '$PB'. Rebuild the hap with -p:OpenHarmonyBundleName=$PB (or pass --unsigned with a matching hap), then re-run"
    TMP_OUT="$_out.tmp.$$.hap"
    SIG_LOG="$WORK/sign-$_n.log"
    log "external sign: $(basename "$IN") -> $(basename "$_out") (alias $ALIAS)"
    if ! run_external_tool sign-app -keyAlias "$ALIAS" -signAlg SHA256withECDSA -mode localSign \
      -appCertFile "$WORK/chain.pem" -profileFile "$P7B" -inFile "$IN" -outFile "$TMP_OUT" \
      -keystoreFile "$KEY" "$@"; then
      if [ "$PTY" = 0 ]; then sed 's/^/    /' "$SIG_LOG" >&2; fi
      die "hap-sign-tool sign-app failed for $IN (wrong p12 password, or the p12 does not match the profile/alias)"
    fi
    VRC=0
    "$TOOLCHAIN/hap-sign-tool" verify-app -inFile "$TMP_OUT" -outCertChain "$WORK/vc-$_n.cer" \
      -outProfile "$WORK/vp-$_n.p7b" > "$WORK/verify-app-$_n.log" 2>&1 || VRC=$?
    if [ "$VRC" -ne 0 ] || ! grep -q "verify-app success" "$WORK/verify-app-$_n.log"; then
      sed 's/^/    /' "$WORK/verify-app-$_n.log" >&2
      die "verify-app failed for $_out (not keeping an unverified hap)"
    fi
    mv -f "$TMP_OUT" "$_out"
    TMP_OUT=""
    log "verify-app OK: $(basename "$_out")"
    sha256sum "$_out"
  done
  IFS=$_old_ifs
  log "externally signed $_n hap(s) for UDID $(echo "$EXPECT" | cut -c1-8)..., alias $ALIAS"
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
