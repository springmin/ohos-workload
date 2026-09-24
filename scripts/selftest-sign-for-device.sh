#!/bin/sh
# selftest-sign-for-device.sh - repeatable, fully local selftest for scripts/sign-for-device.sh.
# Drives the --external path end-to-end against a stub `hap-sign-tool` and a stub `openssl` in a
# temp dir: no device, no SDK, no real signing material, no network. The stub profile JSON is the
# input the script parses (its `verify-profile -inFile <p7b> -outFile <json>` result), so the fake
# .p7b only has to exist; device-ids, bundle-name and the development certificate come from the
# injected JSON.
# Scenarios:
#   stub contract  the stubs themselves (argv recording, verify-profile JSON, sign-app copy,
#                  verify-app marker, configurable failure, openssl chain output)
#   T1 usage       --help / no args / unknown option; missing --profile/--key/--key-alias/
#                  --expect-udid; --out + --out-dir; mode-only options; no tool call at all
#   T2 fail closed --expect-udid not listed in the profile's device-ids -> die before sign-app
#                  (stub recorded only verify-profile); no output hap
#   T3 external    --key-pwd-file default password mode: full sign-app argv (-keyAlias, -signAlg
#                  SHA256withECDSA, -mode localSign, -signCode 1, chain/profile/in/out paths),
#                  verify-app on the file sign-app wrote, output at the expected path, sha line,
#                  no password in the log, strict password-file warning is silent
#   T3b perms      a group/other-readable password file warns but still signs
#   T4 pwd mode    --pwd-input-mode --key-pwd-file: -pwdInputMode 1 and NO -keyPwd/-keystorePwd
#                  anywhere in argv; the password never appears in argv or the log
#   T5 pty         --pwd-input-mode with no tty and no file: script(1) gets the two prompt lines
#                  on stdin, still no password in argv (skipped/failed differently without script)
#   T6 sign fail   stub sign-app rc!=0 -> whole script non-zero, no verify-app, no output, no
#                  .tmp leftovers
#   T7 verify fail two haps: the first verify-app fails -> the second is never signed, no output
#   T8 bundle      hap bundleName != profile bundle-name -> die before sign-app
#   T9 cert        missing --cert; no matching sibling .cer; exactly one matching sibling .cer
#                  (auto-picked, chain still normalized in temp); profile without a development
#                  certificate; a 1-cert chain; a chain without the leaf; openssl failure
#   T10 multi      2 haps + --out-dir; --out with 2 haps refused before any tool call; --out with
#                  one hap lands exactly there
#   T11 idempotent the same command twice -> same rc, same argv shape, byte-identical output
#   T12 device     device mode through the shipped sign-hap.sh with a stub toolchain (smoke):
#                  sign-profile -> sign-app (-signCode 1) -> verify-app, output at --out
#   T13 show       --show-profile-devices prints bundle-name/type and one UDID per line; a
#                  profile without device-ids fails
#   T14 source     pins: the UDID check and the password setup sit before the sign-app call,
#                  sign-app before verify-app, the script never logs $PWS and has no set -x
# Env: SELFTEST_TMPDIR=<dir> work dir base (default: the approved opencode tmp dir),
#      SELFTEST_KEEP=1 keep the work dir even when all checks pass,
#      SELFTEST_SIGN=<path> sign-for-device.sh under test (default: next to this script).
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="1 (2026-09-23)"

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

# ---- paths ---------------------------------------------------------------------------
SELFTEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SELFTEST_DIR/.." && pwd)"
SIGN="${SELFTEST_SIGN:-$SELFTEST_DIR/sign-for-device.sh}"

if [ ! -f "$SIGN" ]; then
    printf 'FATAL: sign-for-device.sh not found: %s\n' "$SIGN" >&2
    exit 1
fi
for _t in python3 awk grep sed cut tr sha256sum mktemp head tail cat wc basename dirname find; do
    if ! command -v "$_t" >/dev/null 2>&1; then
        printf 'FATAL: required command not found: %s\n' "$_t" >&2
        exit 1
    fi
done

# ---- work dir ------------------------------------------------------------------------
if [ -n "${SELFTEST_TMPDIR:-}" ]; then
    WORK_BASE="$SELFTEST_TMPDIR"
elif [ -d /data/storage/el2/base/tmp/opencode ]; then
    WORK_BASE="/data/storage/el2/base/tmp/opencode"
elif [ -n "${TMPDIR:-}" ]; then
    WORK_BASE="$TMPDIR"
else
    WORK_BASE="/tmp"
fi
mkdir -p "$WORK_BASE" 2>/dev/null || WORK_BASE="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$WORK_BASE/selftest-sign-for-device.XXXXXX" 2>/dev/null || true)"
if [ -z "$WORK" ]; then
    WORK="${TMPDIR:-/tmp}/selftest-sign-for-device.$$"
    mkdir -p "$WORK" || { printf 'FATAL: cannot create a work dir\n' >&2; exit 1; }
fi

CHECKS=0
FAILED=0
KEEP="${SELFTEST_KEEP:-0}"
cleanup() {
    if [ "$FAILED" -gt 0 ] || [ "$KEEP" = 1 ]; then
        return 0
    fi
    rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup 0 1 2 15

CWD="$WORK/cwd"
TMPD="$WORK/tmp"
LOGS="$WORK/logs"
STATE_DIR="$WORK/state"
STUB_BIN="$WORK/bin"
STUB_SDK="$WORK/sdk"
STUB_TOOLCHAIN="$STUB_SDK/toolchains/lib"
STUB_TOOL="$STUB_TOOLCHAIN/hap-sign-tool"
IN_DIR="$WORK/in"
PROF_DIR="$WORK/profiles"
MAT_DIR="$WORK/material"
PW_DIR="$WORK/pw"
mkdir -p "$CWD" "$TMPD" "$LOGS" "$STATE_DIR" "$STUB_BIN" "$STUB_TOOLCHAIN" \
    "$IN_DIR/main" "$IN_DIR/multi" "$IN_DIR/wrong" "$IN_DIR/device" "$IN_DIR/idem" \
    "$PROF_DIR/main" "$PROF_DIR/nocertmatch" "$PROF_DIR/sib" "$PROF_DIR/noleaf" "$MAT_DIR" "$PW_DIR"

HAVE_SCRIPT=0
command -v script >/dev/null 2>&1 && HAVE_SCRIPT=1

# ---- fixtures ------------------------------------------------------------------------
UDID_A="0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
UDID_B="FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210"
UDID_OTHER="1111111122222222333333334444444455555555666666667777777788888888"
UDID_A8="01234567"
UDID_OTHER8="11111111"
BUNDLE="com.example.selftest"
ALIAS="selftest-key-alias"
PW_VALUE="S3LF-T3ST-PWD"
PW_VALUE2="L00SE-F1LE-PWD"
PW_FEED_1="TTY-F3ED-PWD-1"
PW_FEED_2="TTY-F3ED-PWD-2"
LEAF_B64="TEVBRi1DRVJULUE="
ROOT_B64="Uk9PVC1DRVJULUI="
OTHER_B64="T1RIRVItQ0VSVC1D"
DIST_B64="RElTVC1DRVJULUQ="

make_hap() { # <dst> <bundle>
    python3 - "$1" "$2" <<'PY'
import json, sys, zipfile
dst, bundle = sys.argv[1], sys.argv[2]
mod = {"app": {"bundleName": bundle, "versionName": "1.0.0-selftest",
               "minAPIVersion": 60000020, "targetAPIVersion": 60000020},
       "module": {"name": "entry", "type": "entry", "mainElement": "EntryAbility"}}
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("module.json", json.dumps(mod))
PY
}

make_profile_json() { # <out> <bundle> <udids-comma-separated> <leaf-b64|NONE>
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
out, bundle, udids, leaf = sys.argv[1:5]
def pem(b64):
    return "-----BEGIN CERTIFICATE-----\n%s\n-----END CERTIFICATE-----\n" % b64
prof = {"version-name": "2.0.0", "type": "debug",
        "bundle-info": {"bundle-name": bundle, "distribution-certificate": pem("RElTVC1DRVJULUQ=")},
        "debug-info": {"device-ids": [u for u in udids.split(",") if u], "device-id-type": "udid"}}
if leaf != "NONE":
    prof["bundle-info"]["development-certificate"] = pem(leaf)
json.dump(prof, open(out, "w"), indent=1)
PY
}

make_p7b() { # <out> <bundle> <udids-comma-separated|NONE>
    if [ "$3" = "NONE" ]; then
        printf '{"type":"debug","bundle-info":{"bundle-name":"%s"},"validity":{"not-after":1}}\n' "$2" > "$1"
    else
        _ids="$(printf '%s' "$3" | tr ',' '\n' | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')"
        printf '{"type":"debug","bundle-info":{"bundle-name":"%s"},"debug-info":{"device-ids":[%s]}}\n' "$2" "$_ids" > "$1"
    fi
}

make_cer() { # <out> <b64> [<b64>...]
    _out="$1"; shift
    : > "$_out"
    for _b in "$@"; do
        printf -- '-----BEGIN CERTIFICATE-----\n%s\n-----END CERTIFICATE-----\n' "$_b" >> "$_out"
    done
}

MAIN_HAP="$IN_DIR/main/hello-selftest-unsigned.hap"
TWO_HAP="$IN_DIR/multi/hello-selftest-two.hap"
WRONG_HAP="$IN_DIR/wrong/hello-selftest-other.hap"
DEV_HAP="$IN_DIR/device/hello-mauiapp-unsigned.hap"
IDEM_HAP="$IN_DIR/idem/hello-idem-unsigned.hap"
make_hap "$MAIN_HAP" "$BUNDLE"
make_hap "$TWO_HAP" "$BUNDLE"
make_hap "$WRONG_HAP" "com.example.other"
make_hap "$DEV_HAP" "com.example.hellomauiapp"
make_hap "$IDEM_HAP" "$BUNDLE"

PROFILE_MAIN_JSON="$PROF_DIR/main/profile.json"
PROFILE_MAIN_P7B="$PROF_DIR/main/selftest-debug.p7b"
make_profile_json "$PROFILE_MAIN_JSON" "$BUNDLE" "$UDID_A,$UDID_B" "$LEAF_B64"
make_p7b "$PROFILE_MAIN_P7B" "$BUNDLE" "$UDID_A,$UDID_B"
# A release-style profile: bundle-name but no device-ids (used by --show-profile-devices).
PROFILE_NODEV_P7B="$PROF_DIR/main/release.p7b"
make_p7b "$PROFILE_NODEV_P7B" "$BUNDLE" NONE
# Sibling .cer auto-discovery: one that does not contain the leaf, one that does.
PROFILE_NOMATCH_P7B="$PROF_DIR/nocertmatch/selftest.p7b"
make_p7b "$PROFILE_NOMATCH_P7B" "$BUNDLE" "$UDID_A"
make_cer "$PROF_DIR/nocertmatch/other.cer" "$OTHER_B64" "$ROOT_B64"
PROFILE_SIB_P7B="$PROF_DIR/sib/selftest.p7b"
make_p7b "$PROFILE_SIB_P7B" "$BUNDLE" "$UDID_A"
make_cer "$PROF_DIR/sib/default_selftest.cer" "$LEAF_B64" "$ROOT_B64"
# A profile whose verify-profile JSON carries no development-certificate at all.
PROFILE_NOLEAF_JSON="$PROF_DIR/noleaf/profile.json"
PROFILE_NOLEAF_P7B="$PROF_DIR/noleaf/selftest.p7b"
make_profile_json "$PROFILE_NOLEAF_JSON" "$BUNDLE" "$UDID_A" NONE
make_p7b "$PROFILE_NOLEAF_P7B" "$BUNDLE" "$UDID_A"
make_cer "$PROF_DIR/noleaf/only.cer" "$OTHER_B64" "$ROOT_B64"
KEY_P12="$MAT_DIR/selftest.p12"
CERT_CHAIN="$MAT_DIR/selftest-chain.cer"
CERT_MISSING="$MAT_DIR/does-not-exist.cer"
printf 'stub p12 (not a real keystore)\n' > "$KEY_P12"
make_cer "$CERT_CHAIN" "$LEAF_B64" "$ROOT_B64"
PWD_FILE="$PW_DIR/key.pwd"
PWD_FILE_LOOSE="$PW_DIR/loose.pwd"
PWD_STDIN="$PW_DIR/stdin.txt"
printf '%s\n' "$PW_VALUE" > "$PWD_FILE"
chmod 600 "$PWD_FILE"
printf '%s\n' "$PW_VALUE2" > "$PWD_FILE_LOOSE"
chmod 644 "$PWD_FILE_LOOSE"
printf '%s\n%s\n' "$PW_FEED_1" "$PW_FEED_2" > "$PWD_STDIN"

# ---- stub hap-sign-tool --------------------------------------------------------------
# Every invocation is recorded before any behaviour: $FAKE_SIGN_STATE/argv.log carries
# "<n>|<arg>" per argv element (n = invocation number) and argv-<n>.txt one "arg=<arg>" per
# line, so the tests can assert argument pairs, absence of passwords and invocation counts.
cat > "$STUB_TOOL" <<'STUB_TOOL_EOF'
#!/bin/sh
# Stub hap-sign-tool for selftest-sign-for-device.sh. Never a real tool.
set -u
STATE="${FAKE_SIGN_STATE:?FAKE_SIGN_STATE not set}"
mkdir -p "$STATE"
N=0
if [ -f "$STATE/n" ]; then N="$(cat "$STATE/n")"; fi
N=$((N + 1))
printf '%s' "$N" > "$STATE/n"
CMD="${1:-}"
{
    printf '%s|%s\n' "$N" "$CMD"
    for _a in "$@"; do printf '%s|%s\n' "$N" "$_a"; done
} >> "$STATE/argv.log"
{
    printf 'cmd=%s\n' "$CMD"
    for _a in "$@"; do printf 'arg=%s\n' "$_a"; done
} > "$STATE/argv-$N.txt"

arg_of() { # <flag> <args...>  (the flag itself is consumed first, or it would match the next arg)
    _flag="$1"
    shift
    _prev=""
    for _a in "$@"; do
        if [ "$_prev" = "$_flag" ]; then printf '%s' "$_a"; return 0; fi
        _prev="$_a"
    done
    return 1
}

case "$CMD" in
    verify-profile)
        OUT="$(arg_of -outFile "$@" || true)"
        [ -n "$OUT" ] || { printf 'stub hap-sign-tool: verify-profile needs -outFile\n' >&2; exit 2; }
        cp "${FAKE_SIGN_PROFILE_JSON:?FAKE_SIGN_PROFILE_JSON not set}" "$OUT"
        ;;
    sign-profile)
        OUT="$(arg_of -outFile "$@" || true)"
        [ -n "$OUT" ] || { printf 'stub hap-sign-tool: sign-profile needs -outFile\n' >&2; exit 2; }
        printf 'stub-signed-profile\n' > "$OUT"
        ;;
    sign-app)
        IN="$(arg_of -inFile "$@" || true)"
        OUT="$(arg_of -outFile "$@" || true)"
        if [ -z "$IN" ] || [ -z "$OUT" ]; then
            printf 'stub hap-sign-tool: sign-app needs -inFile and -outFile\n' >&2
            exit 2
        fi
        cp "$IN" "$OUT"
        printf 'signed-by-stub\n' >> "$OUT"
        ;;
    verify-app)
        printf 'verify-app success\n'
        ;;
esac

if [ "${FAKE_SIGN_FAIL_ON:-}" = "$CMD" ]; then
    printf 'stub hap-sign-tool: simulated %s failure\n' "$CMD" >&2
    exit "${FAKE_SIGN_FAIL_RC:-1}"
fi
exit 0
STUB_TOOL_EOF
chmod 755 "$STUB_TOOL"

# ---- stub openssl --------------------------------------------------------------------
# sign-for-device.sh only runs `openssl crl2pkcs7 -nocrl -certfile <cer> | openssl pkcs7
# -print_certs -out <pem>`; the stub answers both without touching a real certificate.
cat > "$STUB_BIN/openssl" <<'STUB_OPENSSL_EOF'
#!/bin/sh
# Stub openssl for selftest-sign-for-device.sh. Never a real tool.
set -u
case "${1:-}" in
    crl2pkcs7)
        if [ "${FAKE_OPENSSL_FAIL:-0}" = 1 ]; then
            printf 'stub openssl: simulated crl2pkcs7 failure\n' >&2
            exit 1
        fi
        _in=""; _prev=""
        for _a in "$@"; do
            if [ "$_prev" = "-certfile" ]; then _in="$_a"; fi
            _prev="$_a"
        done
        [ -f "$_in" ] || { printf 'stub openssl: cannot read %s\n' "$_in" >&2; exit 1; }
        printf 'STUB-PKCS7\n'
        ;;
    pkcs7)
        _out=""; _prev=""
        for _a in "$@"; do
            if [ "$_prev" = "-out" ]; then _out="$_a"; fi
            _prev="$_a"
        done
        [ -n "$_out" ] || { printf 'stub openssl: pkcs7 needs -out\n' >&2; exit 2; }
        # Real openssl fails when the crl2pkcs7 side of the pipe produced nothing (its failure
        # must stay fatal in sign-for-device.sh), so refuse an empty PKCS7 input.
        _in="$(cat)"
        [ -n "$_in" ] || { printf 'stub openssl: pkcs7 cannot load the (empty) input PKCS7 object\n' >&2; exit 1; }
        {
            printf -- '-----BEGIN CERTIFICATE-----\n%s\n-----END CERTIFICATE-----\n' "${FAKE_OPENSSL_LEAF:-TEVBRi1DRVJULUE=}"
            _i=2
            while [ "$_i" -le "${FAKE_OPENSSL_CERTS:-2}" ]; do
                printf -- '-----BEGIN CERTIFICATE-----\n%s\n-----END CERTIFICATE-----\n' "Uk9PVC1DRVJULUI="
                _i=$((_i + 1))
            done
        } > "$_out"
        ;;
    *)
        printf 'stub openssl: UNHANDLED %s\n' "$*" >&2
        exit 1
        ;;
esac
exit 0
STUB_OPENSSL_EOF
chmod 755 "$STUB_BIN/openssl"

# Device-mode material the shipped sign-hap.sh expects under <toolchain>/ (names only; the stub
# tool never reads them, but the template JSON is parsed by sign-hap.sh's python).
cat > "$STUB_TOOLCHAIN/UnsgnedDebugProfileTemplate.json" <<'JSON'
{"version-name":"2.0.0","type":"debug","bundle-info":{"bundle-name":"com.example.template"},"validity":{"not-before":0,"not-after":1},"debug-info":{"device-ids":["TEMPLATE"]}}
JSON
: > "$STUB_TOOLCHAIN/OpenHarmonyProfileDebug.pem"
: > "$STUB_TOOLCHAIN/OpenHarmonyApplication.pem"
: > "$STUB_TOOLCHAIN/OpenHarmony.p12"

# ---- check helpers -------------------------------------------------------------------
ok()   { CHECKS=$((CHECKS + 1)); printf '  [PASS] %s\n' "$1"; }
bad()  { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$1" >&2; }
skip() { printf '  [SKIP] %s\n' "$1"; }

assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"
    else bad "$1 (expected '$2', got '$3')"; fi
}
assert_file() {
    if [ -f "$2" ]; then ok "$1"; else bad "$1 (missing file: ${2:-<empty>})"; fi
}
assert_not_exists() {
    if [ ! -e "$2" ]; then ok "$1"; else bad "$1 (unexpected path: $2)"; fi
}
assert_log_contains() { # <label> <needle>  (uses $LOG)
    if [ -n "${LOG:-}" ] && [ -f "$LOG" ] && grep -qF -- "$2" "$LOG"; then ok "$1"
    else bad "$1 (missing '$2' in ${LOG:-<no log>})"; fi
}
assert_log_not_contains() { # <label> <needle>  (uses $LOG)
    if [ -n "${LOG:-}" ] && [ -f "$LOG" ] && ! grep -qF -- "$2" "$LOG"; then ok "$1"
    else bad "$1 (unexpected '$2' in ${LOG:-<no log>})"; fi
}
file_contains() { # <file> <needle>: binary-safe (toybox grep stops matching at NUL bytes in a hap)
    [ -f "$1" ] || return 1
    python3 - "$1" "$2" <<'PY'
import sys
sys.exit(0 if sys.argv[2].encode() in open(sys.argv[1], 'rb').read() else 1)
PY
}
argv_has() { awk -F'|' -v a="$2" '$2==a{f=1} END{exit(f?0:1)}' "$1"; }
argv_pair_check() { awk -F'|' -v flag="$2" -v val="$3" '
    { if ($1 != cur) { cur=$1; prev="" }
      if (prev==flag && pn==$1 && $2==val) { f=1 }
      prev=$2; pn=$1 }
    END { exit(f?0:1) }' "$1"; }
argv_count() { awk -F'|' -v a="$2" '$2==a{n++} END{print n+0}' "$1"; }
argv_cmd_count() { awk -F'|' -v want="$2" '
    { if ($1 != cur) { cur=$1; first=$2; if (first==want) n++ } }
    END { print n+0 }' "$1"; }
argv_cmd_value() { awk -F'|' -v want="$2" -v flag="$3" '
    { if ($1 != cur) { cur=$1; first=$2; prev="" }
      if (first==want && prev==flag && pn==$1) { print $2; exit }
      prev=$2; pn=$1 }' "$1"; }

assert_argv_has() { # <label> <arg>  (uses $AV)
    if [ -n "${AV:-}" ] && [ -f "$AV" ] && argv_has "$AV" "$2"; then ok "$1"
    else bad "$1 (no argv element '$2' in ${AV:-<no state>})"; fi
}
assert_argv_absent() { # <label> <arg>
    if [ -z "${AV:-}" ] || [ ! -f "$AV" ] || ! argv_has "$AV" "$2"; then ok "$1"
    else bad "$1 (unexpected argv element '$2')"; fi
}
assert_argv_pair() { # <label> <flag> <value>
    if [ -n "${AV:-}" ] && [ -f "$AV" ] && argv_pair_check "$AV" "$2" "$3"; then ok "$1"
    else bad "$1 (missing argv pair '$2 $3' in ${AV:-<no state>})"; fi
}
assert_cmd_count() { # <label> <cmd> <expected>
    _c=0
    if [ -n "${AV:-}" ] && [ -f "$AV" ]; then _c="$(argv_cmd_count "$AV" "$2")"; fi
    if [ "$_c" -eq "$3" ]; then ok "$1"
    else bad "$1 ($2 invocations: $_c, want $3)"; fi
}
assert_no_tool_call() { # <label> <state-dir>
    if [ ! -e "$2/argv.log" ]; then ok "$1"
    else bad "$1 (stub was invoked: $(head -c 120 "$2/argv.log" 2>/dev/null | tr '\n' ' '))"; fi
}
assert_no_glob_match() { # <label> <dir> <find-name-pattern>
    _m="$(find "$2" -maxdepth 1 -name "$3" -print 2>/dev/null)"
    if [ -z "$_m" ]; then ok "$1"; else bad "$1 (found: $_m)"; fi
}
assert_rc() { # <expected> <label>
    if [ "$RC" -eq "$1" ]; then ok "$2 (exit $RC)"
    else bad "$2 (expected exit $1, got $RC)"; fi
}
assert_path_under() { # <label> <path> <dir>
    case "$2" in
        "$3"/*) ok "$1" ;;
        *) bad "$1 (path '$2' is not under '$3')" ;;
    esac
}

# Runs sign-for-device.sh with the stub SDK/stubs and a fixed temp TMPDIR.
# $_extra is intentionally unquoted: it carries zero or more `VAR=value` assignments.
RC=0
AV=""
LOG=""
run_sign() { # <tag> <extra-env> [args...]
    _tag="$1"; _extra="$2"; shift 2
    RC=0
    ( cd "$CWD" && env OHOS_SDK_ROOT="$STUB_SDK" TMPDIR="$TMPD" \
        FAKE_SIGN_STATE="$STATE_DIR/$_tag" PATH="$STUB_BIN:$PATH" $_extra \
        sh "$SIGN" "$@" ) < /dev/null > "$LOGS/$_tag.log" 2>&1 || RC=$?
    AV="$STATE_DIR/$_tag/argv.log"
    LOG="$LOGS/$_tag.log"
}

run_sign_stdin() { # <tag> <extra-env> <stdin-file> [args...]
    _tag="$1"; _extra="$2"; _stdin="$3"; shift 3
    RC=0
    ( cd "$CWD" && env OHOS_SDK_ROOT="$STUB_SDK" TMPDIR="$TMPD" \
        FAKE_SIGN_STATE="$STATE_DIR/$_tag" PATH="$STUB_BIN:$PATH" $_extra \
        sh "$SIGN" "$@" ) < "$_stdin" > "$LOGS/$_tag.log" 2>&1 || RC=$?
    AV="$STATE_DIR/$_tag/argv.log"
    LOG="$LOGS/$_tag.log"
}

# ---- environment ---------------------------------------------------------------------
section "environment (selftest $SELFTEST_VERSION)"
log "script: $SIGN"
log "work:   $WORK"
log "stub:   $STUB_TOOL (+ stub openssl in $STUB_BIN)"
log "script(1): $([ "$HAVE_SCRIPT" = 1 ] && echo available || echo MISSING)"

if sh -n "$SIGN" 2> "$LOGS/sign-syntax.log"; then
    ok "sign-for-device.sh passes sh -n"
else
    bad "sign-for-device.sh fails sh -n (see $LOGS/sign-syntax.log)"
fi
if sh -n "$SELFTEST_DIR/selftest-sign-for-device.sh" 2> "$LOGS/selftest-syntax.log"; then
    ok "selftest-sign-for-device.sh passes sh -n"
else
    bad "selftest-sign-for-device.sh fails sh -n (see $LOGS/selftest-syntax.log)"
fi

GIT_OK=0
GIT_BEFORE=""
if command -v git >/dev/null 2>&1 && git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    GIT_OK=1
    GIT_BEFORE="$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null || true)"
fi

# ---- stub contract -------------------------------------------------------------------
section "stub contract"
RC=0
FAKE_SIGN_STATE="$STATE_DIR/contract" FAKE_SIGN_PROFILE_JSON="$PROFILE_MAIN_JSON" \
    "$STUB_TOOL" verify-profile -inFile "$PROFILE_MAIN_P7B" -outFile "$LOGS/contract-profile.json" \
    > "$LOGS/contract-profile.out" 2>&1 || RC=$?
assert_rc 0 "stub verify-profile succeeds"
assert_file "stub verify-profile wrote the injected JSON" "$LOGS/contract-profile.json"
LOG="$LOGS/contract-profile.json"
assert_log_contains "stub verify-profile JSON carries the profile bundle" "com.example.selftest"
RC=0
FAKE_SIGN_STATE="$STATE_DIR/contract" FAKE_SIGN_PROFILE_JSON="$PROFILE_MAIN_JSON" \
    "$STUB_TOOL" sign-app -inFile "$MAIN_HAP" -outFile "$LOGS/contract-signed.hap" > "$LOGS/contract-sign.out" 2>&1 || RC=$?
assert_rc 0 "stub sign-app succeeds"
LOG="$LOGS/contract-signed.hap"
if file_contains "$LOGS/contract-signed.hap" "signed-by-stub"; then
    ok "stub sign-app output carries its marker"
else
    bad "stub sign-app output carries its marker"
fi
FAKE_SIGN_STATE="$STATE_DIR/contract" FAKE_SIGN_PROFILE_JSON="$PROFILE_MAIN_JSON" \
    "$STUB_TOOL" verify-app -inFile "$LOGS/contract-signed.hap" > "$LOGS/contract-verify.out" 2>&1
LOG="$LOGS/contract-verify.out"
assert_log_contains "stub verify-app prints the success marker" "verify-app success"
RC=0
FAKE_SIGN_STATE="$STATE_DIR/contract" FAKE_SIGN_PROFILE_JSON="$PROFILE_MAIN_JSON" FAKE_SIGN_FAIL_ON=sign-app \
    "$STUB_TOOL" sign-app -inFile "$MAIN_HAP" -outFile "$LOGS/contract-fail.hap" > /dev/null 2>&1 || RC=$?
assert_rc 1 "stub sign-app failure rc propagates"
RC=0
FAKE_SIGN_STATE="$STATE_DIR/contract-openssl" "$STUB_BIN/openssl" crl2pkcs7 -nocrl -certfile "$CERT_CHAIN" \
    > "$LOGS/contract-pkcs7.out" 2>&1 || RC=$?
assert_rc 0 "stub openssl crl2pkcs7 succeeds"
printf 'STUB-PKCS7\n' | "$STUB_BIN/openssl" pkcs7 -print_certs -out "$LOGS/contract-chain.pem" 2>/dev/null
assert_eq "stub openssl pkcs7 writes 2 certificates" "2" "$(grep -c 'BEGIN CERTIFICATE' "$LOGS/contract-chain.pem" 2>/dev/null)"
assert_eq "stub recorded 4 contract invocations" "4" "$(cat "$STATE_DIR/contract/n" 2>/dev/null)"
AV=""
LOG=""

# ---- T1: usage and missing arguments (no tool call) ----------------------------------
section "T1 usage, missing arguments and mode-only options"
run_sign T1-help "" --help
assert_rc 2 "T1 --help is refused as an unknown option (no usage() in the script)"
assert_log_contains "T1 --help names the option" "unknown option: --help"
assert_no_tool_call "T1 --help never reaches the tool" "$STATE_DIR/T1-help"

run_sign T1-noargs ""
assert_rc 2 "T1 no arguments"
assert_log_contains "T1 no arguments prints usage" "usage: sign-for-device.sh"
assert_no_tool_call "T1 no arguments never reaches the tool" "$STATE_DIR/T1-noargs"

run_sign T1-unknown "" --nope
assert_rc 2 "T1 unknown option"
assert_log_contains "T1 unknown option is named" "unknown option: --nope"
assert_no_tool_call "T1 unknown option never reaches the tool" "$STATE_DIR/T1-unknown"

run_sign T1-profile "" --external
assert_rc 1 "T1 --external without --profile"
assert_log_contains "T1 missing --profile is named" "--external requires --profile"
assert_no_tool_call "T1 missing --profile never reaches the tool" "$STATE_DIR/T1-profile"

run_sign T1-key "" --external --profile "$PROFILE_MAIN_P7B"
assert_rc 1 "T1 --external without --key"
assert_log_contains "T1 missing --key is named" "--external requires --key"
assert_no_tool_call "T1 missing --key never reaches the tool" "$STATE_DIR/T1-key"

run_sign T1-alias "" --external --profile "$PROFILE_MAIN_P7B" --key "$KEY_P12"
assert_rc 1 "T1 --external without --key-alias"
assert_log_contains "T1 missing --key-alias is named" "--external requires --key-alias"
assert_no_tool_call "T1 missing --key-alias never reaches the tool" "$STATE_DIR/T1-alias"

run_sign T1-expect "" --external --profile "$PROFILE_MAIN_P7B" --key "$KEY_P12" --key-alias "$ALIAS"
assert_rc 1 "T1 --external without --expect-udid"
assert_log_contains "T1 missing --expect-udid is named" "--external requires --expect-udid"
assert_no_tool_call "T1 missing --expect-udid never reaches the tool" "$STATE_DIR/T1-expect"

run_sign T1-noprofile "" --external --profile "$WORK/nope.p7b" --key "$KEY_P12" \
    --key-alias "$ALIAS" --expect-udid "$UDID_A"
assert_rc 1 "T1 nonexistent profile"
assert_log_contains "T1 nonexistent profile is named" "profile not found:"
assert_no_tool_call "T1 nonexistent profile never reaches the tool" "$STATE_DIR/T1-noprofile"

run_sign T1-nokey "" --external --profile "$PROFILE_MAIN_P7B" --key "$WORK/nope.p12" \
    --key-alias "$ALIAS" --expect-udid "$UDID_A"
assert_rc 1 "T1 nonexistent keystore"
assert_log_contains "T1 nonexistent keystore is named" "keystore not found:"
assert_no_tool_call "T1 nonexistent keystore never reaches the tool" "$STATE_DIR/T1-nokey"

run_sign T1-bothout "" --external --profile "$PROFILE_MAIN_P7B" --key "$KEY_P12" \
    --key-alias "$ALIAS" --expect-udid "$UDID_A" --out "$WORK/out-both.hap" --out-dir "$WORK/out-both"
assert_rc 1 "T1 --out with --out-dir"
assert_log_contains "T1 --out/--out-dir conflict is named" "--out and --out-dir are mutually exclusive"
assert_no_tool_call "T1 --out/--out-dir conflict never reaches the tool" "$STATE_DIR/T1-bothout"

run_sign T1-keymode "" --key "$KEY_P12"
assert_rc 1 "T1 --key outside --external"
assert_log_contains "T1 mode-only --key is named" "--key is only available with --external"
assert_no_tool_call "T1 --key outside --external never reaches the tool" "$STATE_DIR/T1-keymode"

run_sign T1-pwdmode "" --pwd-input-mode
assert_rc 1 "T1 --pwd-input-mode outside --huawei/--external"
assert_log_contains "T1 --pwd-input-mode restriction is named" "only available with --huawei or --external"
assert_no_tool_call "T1 --pwd-input-mode outside --huawei/--external never reaches the tool" "$STATE_DIR/T1-pwdmode"

run_sign T1-pwdfile "" --key-pwd-file "$PWD_FILE"
assert_rc 1 "T1 --key-pwd-file outside --external"
assert_log_contains "T1 --key-pwd-file restriction is named" "--key-pwd-file is only available with --external"
assert_no_tool_call "T1 --key-pwd-file outside --external never reaches the tool" "$STATE_DIR/T1-pwdfile"

# ---- T2: fail closed on an unexpected UDID -------------------------------------------
section "T2 fail closed: --expect-udid not in the profile device-ids"
run_sign T2 "FAKE_SIGN_PROFILE_JSON=$PROFILE_MAIN_JSON" \
    --external --profile "$PROFILE_MAIN_P7B" --key "$KEY_P12" --key-alias "$ALIAS" \
    --expect-udid "$UDID_OTHER" --cert "$CERT_CHAIN" --key-pwd-file "$PWD_FILE" \
    --unsigned "$MAIN_HAP"
assert_rc 1 "T2 unexpected UDID is refused"
assert_log_contains "T2 failure names the mismatch" "UDID mismatch"
assert_log_contains "T2 shows the expected UDID" "$UDID_OTHER"
assert_log_contains "T2 lists the profile's UDIDs" "$UDID_A"
assert_cmd_count "T2 verify-profile ran (the read-only check)" verify-profile 1
assert_cmd_count "T2 no sign-app ran" sign-app 0
assert_cmd_count "T2 no verify-app ran" verify-app 0
assert_not_exists "T2 no output hap" "$IN_DIR/main/hello-selftest-unsigned-$UDID_OTHER8.hap"
# ---- T3: external path, default password mode ----------------------------------------
section "T3 external sign: full argv, verify-app, output path, sha"
T3_OUT="$IN_DIR/main/hello-selftest-unsigned-$UDID_A8.hap"
rm -f "$T3_OUT"
run_sign T3 "FAKE_SIGN_PROFILE_JSON=$PROFILE_MAIN_JSON" \
    --external --profile "$PROFILE_MAIN_P7B" --key "$KEY_P12" --key-alias "$ALIAS" \
    --expect-udid "$UDID_A" --cert "$CERT_CHAIN" --key-pwd-file "$PWD_FILE" \
    --unsigned "$MAIN_HAP"
assert_rc 0 "T3 external sign succeeds"
assert_cmd_count "T3 one verify-profile call" verify-profile 1
assert_cmd_count "T3 one sign-app call" sign-app 1
assert_cmd_count "T3 one verify-app call" verify-app 1
assert_argv_pair "T3 sign-app key alias" -keyAlias "$ALIAS"
assert_argv_pair "T3 sign-app algorithm" -signAlg SHA256withECDSA
assert_argv_pair "T3 sign-app mode" -mode localSign
assert_argv_pair "T3 sign-app requests the code-signing block" -signCode 1
assert_argv_pair "T3 sign-app keystore" -keystoreFile "$KEY_P12"
assert_argv_pair "T3 sign-app profile" -profileFile "$PROFILE_MAIN_P7B"
assert_argv_pair "T3 sign-app input hap" -inFile "$MAIN_HAP"
assert_argv_pair "T3 sign-app key password comes from --key-pwd-file" -keyPwd "$PW_VALUE"
assert_argv_pair "T3 sign-app keystore password comes from --key-pwd-file" -keystorePwd "$PW_VALUE"
assert_argv_absent "T3 sign-app does not ask for -pwdInputMode" -pwdInputMode
T3_TMP_OUT="$(argv_cmd_value "$AV" sign-app -outFile)"
T3_VERIFY_IN="$(argv_cmd_value "$AV" verify-app -inFile)"
assert_eq "T3 verify-app checks the file sign-app wrote" "$T3_TMP_OUT" "$T3_VERIFY_IN"
case "$T3_TMP_OUT" in
    "$IN_DIR"/main/*.tmp.*.hap) ok "T3 sign-app stages the output next to the destination" ;;
    *) bad "T3 sign-app stages the output next to the destination (got '$T3_TMP_OUT')" ;;
esac
T3_CHAIN="$(argv_cmd_value "$AV" sign-app -appCertFile)"
assert_path_under "T3 the normalized chain lives in the private temp dir" "$T3_CHAIN" "$TMPD"
case "$T3_CHAIN" in
    "$TMPD"/ohos-ext.*/chain.pem) ok "T3 the chain is the temp-dir chain.pem" ;;
    *) bad "T3 the chain is the temp-dir chain.pem (got '$T3_CHAIN')" ;;
esac
assert_path_under "T3 verify-app cert chain output stays in temp" "$(argv_cmd_value "$AV" verify-app -outCertChain)" "$TMPD"
assert_log_contains "T3 profile check logged" "profile check OK"
assert_log_contains "T3 cert chain logged" "app cert chain OK"
assert_log_contains "T3 verify-app success logged" "verify-app OK"
assert_log_contains "T3 final summary logged" "externally signed 1 hap(s)"
assert_log_not_contains "T3 password never reaches the log" "$PW_VALUE"
assert_file "T3 output hap at the expected path" "$T3_OUT"
assert_log_contains "T3 output hap sha256 is logged" "$(sha256sum "$T3_OUT" | cut -d' ' -f1)  $T3_OUT"
if file_contains "$T3_OUT" 'signed-by-stub'; then
    ok "T3 output hap carries the stub signature marker"
else
    bad "T3 output hap carries the stub signature marker"
fi
assert_log_not_contains "T3 strict password file produces no permission warning" "is group/other accessible"

# ---- T3b: loose password file warns but still signs ----------------------------------
section "T3b group/other-readable password file"
T3B_OUT="$IN_DIR/main/hello-selftest-unsigned-$UDID_A8.hap"
run_sign T3b "FAKE_SIGN_PROFILE_JSON=$PROFILE_MAIN_JSON" \
    --external --profile "$PROFILE_MAIN_P7B" --key "$KEY_P12" --key-alias "$ALIAS" \
    --expect-udid "$UDID_A" --cert "$CERT_CHAIN" --key-pwd-file "$PWD_FILE_LOOSE" \
    --unsigned "$MAIN_HAP"
assert_rc 0 "T3b loose password file still signs"
assert_log_contains "T3b permission warning is printed" "is group/other accessible"
assert_argv_pair "T3b sign-app uses the loose file's password" -keyPwd "$PW_VALUE2"
assert_file "T3b output hap produced" "$T3B_OUT"

# ---- T4: --pwd-input-mode with --key-pwd-file (pty) ----------------------------------
section "T4 --pwd-input-mode --key-pwd-file: no password in argv"
T4_OUT="$IN_DIR/main/hello-selftest-unsigned-$UDID_A8.hap"
rm -f "$T4_OUT"
run_sign T4 "FAKE_SIGN_PROFILE_JSON=$PROFILE_MAIN_JSON" \
    --external --profile "$PROFILE_MAIN_P7B" --key "$KEY_P12" --key-alias "$ALIAS" \
    --expect-udid "$UDID_A" --cert "$CERT_CHAIN" --key-pwd-file "$PWD_FILE" --pwd-input-mode \
    --unsigned "$MAIN_HAP"
assert_rc 0 "T4 interactive password mode succeeds"
assert_argv_pair "T4 sign-app asks hap-sign-tool to prompt" -pwdInputMode 1
assert_argv_absent "T4 no -keyPwd on argv" -keyPwd
assert_argv_absent "T4 no -keystorePwd on argv" -keystorePwd
if [ -f "$AV" ] && ! grep -qF -- "$PW_VALUE" "$AV"; then
    ok "T4 password never appears in any argv"
else
    bad "T4 password never appears in any argv"
fi
assert_argv_pair "T4 the code-signing block is still requested" -signCode 1
assert_cmd_count "T4 sign-app still runs once" sign-app 1
assert_cmd_count "T4 verify-app still runs once" verify-app 1
assert_log_contains "T4 log says the file is fed through script(1)" "password file fed through script(1); no password in argv"
assert_log_not_contains "T4 password never reaches the log" "$PW_VALUE"
assert_file "T4 output hap produced" "$T4_OUT"

# ---- T5: --pwd-input-mode with a pty and stdin prompts -------------------------------
section "T5 --pwd-input-mode: two prompt lines on stdin, still no argv"
T5_OUT="$IN_DIR/main/hello-selftest-unsigned-$UDID_A8.hap"
rm -f "$T5_OUT"
if [ "$HAVE_SCRIPT" = 1 ]; then
    run_sign_stdin T5 "FAKE_SIGN_PROFILE_JSON=$PROFILE_MAIN_JSON" "$PWD_STDIN" \
        --external --profile "$PROFILE_MAIN_P7B" --key "$KEY_P12" --key-alias "$ALIAS" \
        --expect-udid "$UDID_A" --cert "$CERT_CHAIN" --pwd-input-mode \
        --unsigned "$MAIN_HAP"
    assert_rc 0 "T5 pty-fed interactive mode succeeds"
    assert_argv_pair "T5 sign-app asks hap-sign-tool to prompt" -pwdInputMode 1
    assert_argv_absent "T5 no -keyPwd on argv" -keyPwd
    assert_argv_absent "T5 no -keystorePwd on argv" -keystorePwd
    if [ -f "$AV" ] && ! grep -qF -- "$PW_FEED_1" "$AV" && ! grep -qF -- "$PW_FEED_2" "$AV"; then
        ok "T5 both fed passwords stay out of argv"
    else
        bad "T5 both fed passwords stay out of argv"
    fi
    assert_log_contains "T5 log explains the pty fallback" "running hap-sign-tool under script(1)"
    assert_log_not_contains "T5 fed password never reaches the log" "$PW_FEED_1"
    assert_file "T5 output hap produced" "$T5_OUT"
else
    skip "T5 pty-fed interactive mode (script(1) not available)"
    run_sign T5 "FAKE_SIGN_PROFILE_JSON=$PROFILE_MAIN_JSON" \
        --external --profile "$PROFILE_MAIN_P7B" --key "$KEY_P12" --key-alias "$ALIAS" \
        --expect-udid "$UDID_A" --cert "$CERT_CHAIN" --pwd-input-mode \
        --unsigned "$MAIN_HAP"
    assert_rc 1 "T5 without script(1) the mode fails closed"
    assert_log_contains "T5 names the missing script(1)" "script(1) is not available"
    assert_cmd_count "T5 no sign-app without a pty" sign-app 0
fi

# ---- T6: sign-app failure stops everything -------------------------------------------
section "T6 sign-app failure: non-zero, no verify-app, no output, no leftovers"
T6_OUT="$IN_DIR/main/hello-selftest-unsigned-$UDID_A8.hap"
rm -f "$T6_OUT"
run_sign T6 "FAKE_SIGN_PROFILE_JSON=$PROFILE_MAIN_JSON FAKE_SIGN_FAIL_ON=sign-app" \
    --external --profile "$PROFILE_MAIN_P7B" --key "$KEY_P12" --key-alias "$ALIAS" \
    --expect-udid "$UDID_A" --cert "$CERT_CHAIN" --key-pwd-file "$PWD_FILE" \
    --unsigned "$MAIN_HAP"
assert_rc 1 "T6 sign-app failure fails the whole script"
assert_log_contains "T6 names the failing step" "hap-sign-tool sign-app failed"
assert_log_contains "T6 shows the tool output" "simulated sign-app failure"
assert_cmd_count "T6 sign-app ran once" sign-app 1
assert_cmd_count "T6 verify-app never ran" verify-app 0
assert_not_exists "T6 no output hap is kept" "$T6_OUT"
assert_no_glob_match "T6 staged output was cleaned up" "$IN_DIR/main" 'hello-selftest-unsigned-*.tmp.*.hap'

# ---- T7: verify-app failure is not continued into the next hap -----------------------
section "T7 verify-app failure: non-zero, second hap not signed, no output kept"
T7A="$IN_DIR/multi/hello-selftest-unsigned-$UDID_A8.hap"
T7B="$IN_DIR/multi/hello-selftest-two-$UDID_A8.hap"
rm -f "$T7A" "$T7B"
run_sign T7 "FAKE_SIGN_PROFILE_JSON=$PROFILE_MAIN_JSON FAKE_SIGN_FAIL_ON=verify-app" \
    --external --profile "$PROFILE_MAIN_P7B" --key "$KEY_P12" --key-alias "$ALIAS" \
    --expect-udid "$UDID_A" --cert "$CERT_CHAIN" --key-pwd-file "$PWD_FILE" \
    --unsigned "$MAIN_HAP" --unsigned "$TWO_HAP"
assert_rc 1 "T7 verify-app failure fails the whole script"
assert_log_contains "T7 names the unverified hap" "verify-app failed for"
assert_log_contains "T7 never keeps an unverified hap" "not keeping an unverified hap"
assert_log_contains "T7 shows the tool output" "simulated verify-app failure"
assert_cmd_count "T7 sign-app ran only for the first hap" sign-app 1
assert_cmd_count "T7 verify-app ran once" verify-app 1
assert_not_exists "T7 first output not kept" "$T7A"
assert_not_exists "T7 second output not kept" "$T7B"
assert_no_glob_match "T7 no staged hap left behind" "$IN_DIR/multi" '*.tmp.*.hap'
assert_log_not_contains "T7 never reports success" "externally signed"

# ---- T8: bundle-name mismatch fails closed -------------------------------------------
section "T8 bundle-name mismatch fails before signing"
run_sign T8 "FAKE_SIGN_PROFILE_JSON=$PROFILE_MAIN_JSON" \
    --external --profile "$PROFILE_MAIN_P7B" --key "$KEY_P12" --key-alias "$ALIAS" \
    --expect-udid "$UDID_A" --cert "$CERT_CHAIN" --key-pwd-file "$PWD_FILE" \
    --unsigned "$WRONG_HAP"
assert_rc 1 "T8 mismatched hap bundle is refused"
assert_log_contains "T8 names the mismatch" "bundle-name mismatch"
assert_log_contains "T8 shows the profile bundle" "$BUNDLE"
assert_cmd_count "T8 sign-app never ran" sign-app 0
assert_cmd_count "T8 verify-app never ran" verify-app 0
assert_not_exists "T8 no output hap" "$IN_DIR/wrong/hello-selftest-other-$UDID_A8.hap"

# ---- T9: certificate chain selection and failure modes -------------------------------
section "T9 app cert chain: missing, sibling discovery, bad chains"
run_sign T9a "FAKE_SIGN_PROFILE_JSON=$PROFILE_MAIN_JSON" \
    --external --profile "$PROFILE_MAIN_P7B" --key "$KEY_P12" --key-alias "$ALIAS" \
    --expect-udid "$UDID_A" --cert "$CERT_MISSING" --key-pwd-file "$PWD_FILE" \
    --unsigned "$MAIN_HAP"
assert_rc 1 "T9a --cert pointing nowhere is refused"
assert_log_contains "T9a names the missing chain" "app cert chain not found"
assert_cmd_count "T9a sign-app never ran" sign-app 0

run_sign T9b "FAKE_SIGN_PROFILE_JSON=$PROFILE_MAIN_JSON" \
    --external --profile "$PROFILE_NOMATCH_P7B" --key "$KEY_P12" --key-alias "$ALIAS" \
    --expect-udid "$UDID_A" --key-pwd-file "$PWD_FILE" --unsigned "$MAIN_HAP"
assert_rc 1 "T9b a sibling .cer without the profile leaf is refused"
assert_log_contains "T9b explains the sibling search" "no *.cer next to"
assert_cmd_count "T9b sign-app never ran" sign-app 0

T9C_OUT="$IN_DIR/main/hello-selftest-unsigned-$UDID_A8.hap"
rm -f "$T9C_OUT"
run_sign T9c "FAKE_SIGN_PROFILE_JSON=$PROFILE_MAIN_JSON" \
    --external --profile "$PROFILE_SIB_P7B" --key "$KEY_P12" --key-alias "$ALIAS" \
    --expect-udid "$UDID_A" --key-pwd-file "$PWD_FILE" --unsigned "$MAIN_HAP"
assert_rc 0 "T9c the one matching sibling .cer is picked automatically"
assert_log_contains "T9c logs the sibling discovery" "app cert chain (sibling .cer):"
assert_cmd_count "T9c sign-app ran" sign-app 1
if [ -f "$AV" ]; then
    case "$(argv_cmd_value "$AV" sign-app -appCertFile)" in
        "$TMPD"/ohos-ext.*/chain.pem) ok "T9c the sibling .cer is still normalized into temp" ;;
        *) bad "T9c the sibling .cer is still normalized into temp (got '$(argv_cmd_value "$AV" sign-app -appCertFile)')" ;;
    esac
fi

run_sign T9d "FAKE_SIGN_PROFILE_JSON=$PROFILE_NOLEAF_JSON" \
    --external --profile "$PROFILE_NOLEAF_P7B" --key "$KEY_P12" --key-alias "$ALIAS" \
    --expect-udid "$UDID_A" --key-pwd-file "$PWD_FILE" --unsigned "$MAIN_HAP"
assert_rc 0 "T9d profile without a development certificate still signs"
assert_log_contains "T9d warns that the leaf check was skipped" "using a sibling .cer without the leaf check"

run_sign T9e "FAKE_SIGN_PROFILE_JSON=$PROFILE_MAIN_JSON FAKE_OPENSSL_CERTS=1" \
    --external --profile "$PROFILE_MAIN_P7B" --key "$KEY_P12" --key-alias "$ALIAS" \
    --expect-udid "$UDID_A" --cert "$CERT_CHAIN" --key-pwd-file "$PWD_FILE" \
    --unsigned "$MAIN_HAP"
assert_rc 1 "T9e a one-certificate chain is refused"
assert_log_contains "T9e asks for the full chain" "needs the full chain"
assert_cmd_count "T9e sign-app never ran" sign-app 0

run_sign T9f "FAKE_SIGN_PROFILE_JSON=$PROFILE_MAIN_JSON FAKE_OPENSSL_LEAF=$OTHER_B64" \
    --external --profile "$PROFILE_MAIN_P7B" --key "$KEY_P12" --key-alias "$ALIAS" \
    --expect-udid "$UDID_A" --cert "$CERT_CHAIN" --key-pwd-file "$PWD_FILE" \
    --unsigned "$MAIN_HAP"
assert_rc 1 "T9f a chain without the profile leaf is refused"
assert_log_contains "T9f names the leaf mismatch" "does not contain the profile's development-certificate"
assert_cmd_count "T9f sign-app never ran" sign-app 0

run_sign T9g "FAKE_SIGN_PROFILE_JSON=$PROFILE_MAIN_JSON FAKE_OPENSSL_FAIL=1" \
    --external --profile "$PROFILE_MAIN_P7B" --key "$KEY_P12" --key-alias "$ALIAS" \
    --expect-udid "$UDID_A" --cert "$CERT_CHAIN" --key-pwd-file "$PWD_FILE" \
    --unsigned "$MAIN_HAP"
assert_rc 1 "T9g openssl failure is fatal"
assert_log_contains "T9g names the conversion failure" "cannot convert the app cert chain"
assert_cmd_count "T9g sign-app never ran" sign-app 0

# ---- T10: several haps, --out-dir and --out rules ------------------------------------
section "T10 multiple haps, --out-dir, --out rules"
rm -rf "$WORK/out-multi"
run_sign T10a "FAKE_SIGN_PROFILE_JSON=$PROFILE_MAIN_JSON" \
    --external --profile "$PROFILE_MAIN_P7B" --key "$KEY_P12" --key-alias "$ALIAS" \
    --expect-udid "$UDID_A" --cert "$CERT_CHAIN" --key-pwd-file "$PWD_FILE" \
    --out-dir "$WORK/out-multi" --unsigned "$MAIN_HAP" --unsigned "$TWO_HAP"
assert_rc 0 "T10a two haps sign in one run"
assert_file "T10a first hap in --out-dir" "$WORK/out-multi/hello-selftest-unsigned.hap"
assert_file "T10a second hap in --out-dir" "$WORK/out-multi/hello-selftest-two.hap"
assert_cmd_count "T10a sign-app ran twice" sign-app 2
assert_cmd_count "T10a verify-app ran twice" verify-app 2
assert_log_contains "T10a summary counts both haps" "externally signed 2 hap(s)"

run_sign T10b "FAKE_SIGN_PROFILE_JSON=$PROFILE_MAIN_JSON" \
    --external --profile "$PROFILE_MAIN_P7B" --key "$KEY_P12" --key-alias "$ALIAS" \
    --expect-udid "$UDID_A" --cert "$CERT_CHAIN" --key-pwd-file "$PWD_FILE" \
    --out "$WORK/out-single.hap" --unsigned "$MAIN_HAP" --unsigned "$TWO_HAP"
assert_rc 1 "T10b --out with two haps is refused"
assert_log_contains "T10b points at --out-dir" "use --out-dir <dir> for several"
assert_no_tool_call "T10b fails before any tool call" "$STATE_DIR/T10b"

T10C_OUT="$WORK/out-exact.hap"
rm -f "$T10C_OUT"
run_sign T10c "FAKE_SIGN_PROFILE_JSON=$PROFILE_MAIN_JSON" \
    --external --profile "$PROFILE_MAIN_P7B" --key "$KEY_P12" --key-alias "$ALIAS" \
    --expect-udid "$UDID_A" --cert "$CERT_CHAIN" --key-pwd-file "$PWD_FILE" \
    --out "$T10C_OUT" --unsigned "$MAIN_HAP"
assert_rc 0 "T10c --out with one hap succeeds"
assert_file "T10c output lands exactly at --out" "$T10C_OUT"

# ---- T11: idempotency ----------------------------------------------------------------
section "T11 the same command twice: identical results"
T11_OUT="$IN_DIR/idem/hello-idem-unsigned-$UDID_A8.hap"
rm -f "$T11_OUT"
T11_ARGS="--external --profile $PROFILE_MAIN_P7B --key $KEY_P12 --key-alias $ALIAS --expect-udid $UDID_A --cert $CERT_CHAIN --key-pwd-file $PWD_FILE --unsigned $IDEM_HAP"
run_sign T11a "FAKE_SIGN_PROFILE_JSON=$PROFILE_MAIN_JSON" $T11_ARGS
assert_rc 0 "T11 first run succeeds"
assert_file "T11 first run output" "$T11_OUT"
T11_SHA_1="$(sha256sum "$T11_OUT" | cut -d' ' -f1)"
# The staged name carries the sign script's PID (destination.tmp.$$.hap), so normalize it
# before comparing shapes; the destination part must stay identical.
T11_SIGNOUT_1="$(argv_cmd_value "$AV" sign-app -outFile | sed 's/\.tmp\.[0-9][0-9]*\.hap$/.tmp.PID.hap/')"
run_sign T11b "FAKE_SIGN_PROFILE_JSON=$PROFILE_MAIN_JSON" $T11_ARGS
assert_rc 0 "T11 second run succeeds"
assert_file "T11 second run output" "$T11_OUT"
T11_SHA_2="$(sha256sum "$T11_OUT" | cut -d' ' -f1)"
T11_SIGNOUT_2="$(argv_cmd_value "$AV" sign-app -outFile | sed 's/\.tmp\.[0-9][0-9]*\.hap$/.tmp.PID.hap/')"
assert_eq "T11 output is byte-identical across runs" "$T11_SHA_1" "$T11_SHA_2"
assert_eq "T11 sign-app argument shape is stable" "$T11_SIGNOUT_1" "$T11_SIGNOUT_2"
assert_eq "T11 sign-app stages next to the destination" "$T11_OUT.tmp.PID.hap" "$T11_SIGNOUT_1"
assert_cmd_count "T11 second run signed exactly once" sign-app 1
assert_cmd_count "T11 second run verified exactly once" verify-app 1
assert_log_contains "T11 second run reports the same summary" "externally signed 1 hap(s)"

# ---- T12: device-mode smoke through the shipped sign-hap.sh --------------------------
section "T12 device mode (shipped sign-hap.sh, stub toolchain)"
REPO_SDK="$ROOT_DIR/packs/Microsoft.OpenHarmony.Sdk"
REPO_VER="$(ls "$REPO_SDK" 2>/dev/null | tail -1)"
REPO_SIGN_HAP="$REPO_SDK/$REPO_VER/templates/scripts/sign-hap.sh"
if [ -f "$REPO_SIGN_HAP" ]; then
    T12_OUT="$WORK/out-device/device-bound.hap"
    rm -rf "$WORK/out-device"
    run_sign T12 "" --unsigned "$DEV_HAP" --out "$T12_OUT" "$UDID_A"
    assert_rc 0 "T12 device-mode sign succeeds"
    assert_file "T12 output hap at --out" "$T12_OUT"
    assert_file "T12 sign-hap.sh wrote its profile work dir" "$WORK/out-device/profile-work/debug.p7b"
    assert_log_contains "T12 device-bound summary" "device-bound hap:"
    assert_log_not_contains "T12 bundle matches, no warning" "9568344"
    assert_cmd_count "T12 sign-profile ran" sign-profile 1
    assert_cmd_count "T12 sign-app ran" sign-app 1
    assert_cmd_count "T12 verify-app ran" verify-app 1
    assert_argv_pair "T12 device path also requests the code-signing block" -signCode 1
    assert_argv_pair "T12 device path signs the fixture" -inFile "$DEV_HAP"
else
    skip "T12 device mode (pack SDK sign-hap.sh not present)"
fi

# ---- T13: --show-profile-devices -----------------------------------------------------
section "T13 --show-profile-devices reads the p7b text"
run_sign T13 "" --show-profile-devices --profile "$PROFILE_MAIN_P7B"
assert_rc 0 "T13 profile summary succeeds"
assert_log_contains "T13 prints the bundle name" "bundle-name: $BUNDLE"
assert_log_contains "T13 prints the type" "type: debug"
assert_log_contains "T13 lists the first device-ids entry" "$UDID_A"
assert_log_contains "T13 lists the second device-ids entry" "$UDID_B"
assert_log_contains "T13 counts the device-ids" "device-ids (2):"
assert_no_tool_call "T13 never reaches the tool" "$STATE_DIR/T13"

run_sign T13-nodev "" --show-profile-devices --profile "$PROFILE_NODEV_P7B"
assert_rc 1 "T13 a profile without device-ids fails"
assert_log_contains "T13 names the missing device-ids" "no debug-info.device-ids"
assert_no_tool_call "T13-nodev never reaches the tool" "$STATE_DIR/T13-nodev"

run_sign T13-missing "" --show-profile-devices --profile "$WORK/nope.p7b"
assert_rc 1 "T13 a missing profile fails"
assert_log_contains "T13 names the missing profile" "profile not found:"

# ---- T14: source pins ----------------------------------------------------------------
section "T14 source pins (ordering and password handling)"
grep_line() { grep -nF -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1; }
UDID_LINE="$(grep_line "$SIGN" 'grep -Fqix "$EXPECT"')"
SIGNAPP_LINE="$(grep_line "$SIGN" 'run_external_tool sign-app')"
SIGNCODE_LINE="$(grep_line "$SIGN" '-signCode 1 -appCertFile')"
PWDINPUT_LINE="$(grep_line "$SIGN" 'set -- -pwdInputMode 1')"
KEYPWD_LINE="$(grep_line "$SIGN" 'set -- -keyPwd "$PWS" -keystorePwd "$PWS"')"
VERIFYAPP_LINE="$(grep_line "$SIGN" '"$TOOLCHAIN/hap-sign-tool" verify-app')"
if [ -n "$UDID_LINE" ] && [ -n "$SIGNAPP_LINE" ] && [ "$UDID_LINE" -lt "$SIGNAPP_LINE" ]; then
    ok "T14 the UDID check ($UDID_LINE) runs before sign-app ($SIGNAPP_LINE)"
else
    bad "T14 ordering: UDID check='$UDID_LINE' sign-app='$SIGNAPP_LINE'"
fi
if [ -n "$PWDINPUT_LINE" ] && [ -n "$SIGNAPP_LINE" ] && [ "$PWDINPUT_LINE" -lt "$SIGNAPP_LINE" ]; then
    ok "T14 the password mode ($PWDINPUT_LINE) is set before sign-app ($SIGNAPP_LINE)"
else
    bad "T14 ordering: pwd mode='$PWDINPUT_LINE' sign-app='$SIGNAPP_LINE'"
fi
if [ -n "$SIGNCODE_LINE" ] && [ -n "$SIGNAPP_LINE" ] && [ "$SIGNAPP_LINE" -lt "$SIGNCODE_LINE" ] \
   && [ "$SIGNCODE_LINE" -lt "$((SIGNAPP_LINE + 6))" ]; then
    ok "T14 -signCode 1 ($SIGNCODE_LINE) belongs to the sign-app call ($SIGNAPP_LINE)"
else
    bad "T14 -signCode line: sign-app='$SIGNAPP_LINE' signCode='$SIGNCODE_LINE'"
fi
if [ -n "$SIGNAPP_LINE" ] && [ -n "$VERIFYAPP_LINE" ] && [ "$SIGNAPP_LINE" -lt "$VERIFYAPP_LINE" ]; then
    ok "T14 sign-app ($SIGNAPP_LINE) runs before verify-app ($VERIFYAPP_LINE)"
else
    bad "T14 ordering: sign-app='$SIGNAPP_LINE' verify-app='$VERIFYAPP_LINE'"
fi
if [ -f "$REPO_SIGN_HAP" ] && grep -qF -- '-signCode 1' "$REPO_SIGN_HAP"; then
    ok "T14 the shipped sign-hap.sh also pins -signCode 1"
else
    bad "T14 the shipped sign-hap.sh lost its -signCode 1"
fi
if grep -q '^set -x' "$SIGN"; then
    bad "T14 the script must not run with set -x"
else
    ok "T14 the script does not use set -x"
fi
if grep -n 'PWS' "$SIGN" | grep -qE 'log |warn |printf'; then
    bad "T14 no log/printf line may reference \$PWS"
else
    ok "T14 no log/printf line references \$PWS (password never logged)"
fi

# ---- global: sandbox and cleanliness -------------------------------------------------
section "global: nothing outside the temp dir, no leftovers"
assert_eq "global sandbox cwd untouched" "" "$(ls -A "$CWD" 2>/dev/null)"
LEFTOVER_TMP="$(find "$TMPD" -mindepth 1 -print 2>/dev/null)"
assert_eq "global the script's private temp dirs are cleaned up" "" "$LEFTOVER_TMP"
LEFTOVER_HAP="$(find "$WORK" -name '*.tmp.*.hap' -print 2>/dev/null)"
assert_eq "global no staged .tmp hap left behind" "" "$LEFTOVER_HAP"
assert_eq "global the password file was not modified" "$PW_VALUE" "$(cat "$PWD_FILE")"
if [ "$GIT_OK" = 1 ]; then
    assert_eq "global repo working tree unchanged" "$GIT_BEFORE" "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null || true)"
else
    skip "global repo working tree check (not a git work tree)"
fi

# ---- summary -------------------------------------------------------------------------
section "selftest summary"
printf 'script: %s\n' "$SIGN"
printf 'stub:   %s\n' "$STUB_TOOL"
printf 'checks: %s, failed: %s\n' "$CHECKS" "$FAILED"
if [ "$FAILED" -gt 0 ]; then
    printf 'RESULT: FAIL\n'
    printf 'logs kept at: %s\n' "$WORK"
    exit 1
fi
printf 'RESULT: PASS\n'
if [ "$KEEP" = 1 ]; then
    printf 'work dir kept (SELFTEST_KEEP=1): %s\n' "$WORK"
fi
exit 0
