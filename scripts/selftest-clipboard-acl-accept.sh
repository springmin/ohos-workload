#!/bin/sh
# selftest-clipboard-acl-accept.sh - fully local selftest for scripts/clipboard-acl-accept.sh.
# Drives the whole acceptance flow against stubs (hdc, dotnet, sign-for-device, hap-sign-tool in
# a stub SDK): no device, no real SDK, no real signer, no network. Scenarios:
#   stub contract  the stubs themselves (hdc call recording + install/hilog/bm fixtures, the
#                  dotnet publish stub, the sign stub, the verify-profile stub)
#   T1 usage       no --sign / unknown --sign / no --build|--hap / bad marker / missing
#                  profile+key+alias / missing files: exit 2 or 1, and no stub was called
#   T2 ACL gate    a profile without READ_PASTEBOARD is refused before signing/installing
#                  (fail closed), a profile with only restricted-permissions passes
#   T3 happy path  --sign release with --hap: sign stub argv (--release --profile --key --cert),
#                  install, bm dump ACL evidence, write+read probes, report.md PASS, verdict
#   T4 external    --sign external: the UDID is read from the device (bm get -u) and forwarded
#                  as --expect-udid; --expect-udid wins when given
#   T5 red controls bm dump without the ACL / present but not granted, install 9568289, sign
#                  failure, runtime read null (with and without the service denial), no read
#                  line, and a probe hap that does not declare READ_PASTEBOARD
#   T6 build       --build runs the publish stub with -p:OpenHarmonyFeatures=clipboard
#                  -p:ClipboardProbe=true and accepts the produced hap (CSC_WATCHDOG=0)
#   T7 dry-run     prints the plan and never calls hdc/dotnet/sign
#   T8 lock        the shared .device-lock: a stale lock is reclaimed + released, a live lock
#                  times out (CLIPBOARD_ACL_LOCK_ATTEMPTS=1, INTERVAL=0)
# Env: SELFTEST_TMPDIR=<dir> work dir base (default: the approved opencode tmp dir),
#      SELFTEST_KEEP=1 keep the work dir even when all checks pass,
#      SELFTEST_ACCEPT=<path> clipboard-acl-accept.sh under test (default: next to this script).
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="1 (2026-10-15)"

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

SELFTEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SELFTEST_DIR/.." && pwd)"
ACCEPT="${SELFTEST_ACCEPT:-$SELFTEST_DIR/clipboard-acl-accept.sh}"
[ -f "$ACCEPT" ] || { printf 'FATAL: clipboard-acl-accept.sh not found: %s\n' "$ACCEPT" >&2; exit 1; }
for _t in python3 awk grep sed cut tr sha256sum mktemp head tail cat wc basename dirname find cp mkdir rm chmod; do
    command -v "$_t" >/dev/null 2>&1 || { printf 'FATAL: required command not found: %s\n' "$_t" >&2; exit 1; }
done

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
WORK="$(mktemp -d "$WORK_BASE/selftest-clipboard-acl.XXXXXX" 2>/dev/null || true)"
if [ -z "$WORK" ]; then
    WORK="${TMPDIR:-/tmp}/selftest-clipboard-acl.$$"
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
FIX="$WORK/fixtures"
mkdir -p "$CWD" "$TMPD" "$LOGS" "$STATE_DIR" "$STUB_BIN" "$STUB_TOOLCHAIN" "$FIX"

# ---- check helpers ---------------------------------------------------------------------------
ok()   { CHECKS=$((CHECKS + 1)); printf '  [PASS] %s\n' "$1"; }
bad()  { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$1" >&2; }
skip() { printf '  [SKIP] %s\n' "$1"; }
assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
assert_rc() {
    if [ "$RC" -eq "$1" ]; then ok "$2 (exit $RC)"; else bad "$2 (expected exit $1, got $RC)"; fi
}
assert_file() { if [ -f "$2" ]; then ok "$1"; else bad "$1 (missing file: ${2:-<empty>})"; fi }
assert_not_exists() { if [ ! -e "$2" ]; then ok "$1"; else bad "$1 (unexpected path: $2)"; fi }
assert_log_contains() {
    if [ -n "${LOG:-}" ] && [ -f "$LOG" ] && grep -qF -- "$2" "$LOG"; then ok "$1"
    else bad "$1 (missing '$2' in ${LOG:-<no log>})"; fi
}
assert_log_not_contains() {
    if [ -n "${LOG:-}" ] && [ -f "$LOG" ] && ! grep -qF -- "$2" "$LOG"; then ok "$1"
    else bad "$1 (unexpected '$2' in ${LOG:-<no log>})"; fi
}
calls_has() { # <calls-file> <needle>
    [ -f "$1" ] && grep -qF -- "$2" "$1"
}
assert_calls_has() {
    if calls_has "$2" "$3"; then ok "$1"; else bad "$1 (no '$3' in ${2:-<no calls>})"; fi
}
assert_no_calls() { # <label> <calls-file>
    if [ ! -f "$2" ] || [ ! -s "$2" ]; then ok "$1"
    else bad "$1 (stub was called: $(head -n1 "$2" 2>/dev/null))"; fi
}
file_contains() {
    [ -f "$1" ] || return 1
    python3 - "$1" "$2" <<'PY'
import sys
sys.exit(0 if sys.argv[2].encode() in open(sys.argv[1], 'rb').read() else 1)
PY
}

# ---- fixtures --------------------------------------------------------------------------------
BUNDLE="com.example.hellomauiapp"
UDID_A="0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
MARKER="ACLFIX-77"

make_hap() { # <dst> <bundle> <with-perm 0|1>
    python3 - "$1" "$2" "$3" <<'PY'
import json, sys, zipfile
dst, bundle, want = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
mod = {"app": {"bundleName": bundle, "versionName": "1.0.0-selftest",
               "minAPIVersion": 60000020, "targetAPIVersion": 60000020},
       "module": {"name": "entry", "type": "entry", "mainElement": "EntryAbility",
                  "requestPermissions": ([{"name": "ohos.permission.READ_PASTEBOARD",
                                           "reason": "$string:permission_reason_clipboard",
                                           "usedScene": {"abilities": ["EntryAbility"], "when": "inuse"}}]
                                         if want else [])}}
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("module.json", json.dumps(mod))
PY
}

make_profile_json() { # <out> <with-acl 0|1>
    python3 - "$1" "$2" <<'PY'
import json, sys
out, want = sys.argv[1], sys.argv[2] == '1'
acl = ["ohos.permission.READ_PASTEBOARD"] if want else []
prof = {"type": "release", "version-name": "2.0.0",
        "bundle-info": {"bundle-name": "com.example.hellomauiapp"},
        "acls": {"allowed-acls": acl}}
if want:
    prof["permissions"] = {"restricted-permissions": ["ohos.permission.READ_PASTEBOARD"]}
json.dump(prof, open(out, "w"), indent=1)
PY
}

ACL_HAP="$FIX/acl-probe-unsigned.hap"
PLAIN_HAP="$FIX/plain-unsigned.hap"
make_hap "$ACL_HAP" "$BUNDLE" 1
make_hap "$PLAIN_HAP" "$BUNDLE" 0
PROFILE_ACL="$FIX/acl.p7b"
PROFILE_NOACL="$FIX/noacl.p7b"
PROFILE_RESTRICTED="$FIX/restricted-only.p7b"
PROFILE_ACL_JSON="$FIX/acl-profile.json"
PROFILE_NOACL_JSON="$FIX/noacl-profile.json"
PROFILE_RESTRICTED_JSON="$FIX/restricted-only-profile.json"
make_profile_json "$PROFILE_ACL_JSON" 1
make_profile_json "$PROFILE_NOACL_JSON" 0
python3 - "$PROFILE_RESTRICTED_JSON" <<'PY'
import json, sys
prof = {"type": "release", "version-name": "2.0.0",
        "bundle-info": {"bundle-name": "com.example.hellomauiapp"},
        "permissions": {"restricted-permissions": ["ohos.permission.READ_PASTEBOARD"]}}
json.dump(prof, open(sys.argv[1], "w"), indent=1)
PY
printf '{"type":"release","bundle-info":{"bundle-name":"com.example.hellomauiapp"}}\n' > "$PROFILE_ACL"
printf '{"type":"release","bundle-info":{"bundle-name":"com.example.hellomauiapp"}}\n' > "$PROFILE_NOACL"
printf '{"type":"release","bundle-info":{"bundle-name":"com.example.hellomauiapp"}}\n' > "$PROFILE_RESTRICTED"
KEY="$FIX/selftest.p12"
CERT="$FIX/selftest.cer"
printf 'stub p12\n' > "$KEY"
printf -- '-----BEGIN CERTIFICATE-----\nQUJD\n-----END CERTIFICATE-----\n' > "$CERT"
PW_FILE="$FIX/pw.txt"
printf 'selftest-pw\n' > "$PW_FILE"

# bm dump fixtures: acl list, granted request, ungranted request, absent (with a noise prefix).
cat > "$FIX/bm-acl.json" <<JSON
bm dump:
{"bundleName":"$BUNDLE","acls":{"allowed-acls":["ohos.permission.READ_PASTEBOARD"]}}
JSON
cat > "$FIX/bm-granted.json" <<JSON
{"bundleName":"$BUNDLE","moduleInfos":[{"moduleInfo":{"requestPermissions":[{"name":"ohos.permission.READ_PASTEBOARD","granted":true}]}}]}
JSON
cat > "$FIX/bm-ungranted.json" <<JSON
{"bundleName":"$BUNDLE","moduleInfos":[{"moduleInfo":{"requestPermissions":[{"name":"ohos.permission.READ_PASTEBOARD","granted":false}]}}]}
JSON
cat > "$FIX/bm-absent.json" <<JSON
{"bundleName":"$BUNDLE","moduleInfos":[{"moduleInfo":{"requestPermissions":[{"name":"ohos.permission.INTERNET","granted":true}]}}]}
JSON
cat > "$FIX/hilog-ok.txt" <<EOF
10-15 09:00:00.000  1000  1000 I C00000 [clipboard-probe] clipboard: wrote 9B text='$MARKER'
10-15 09:00:01.000  1000  1000 I C00000 [clipboard-probe] clipboard: read 9B text='$MARKER'
EOF
cat > "$FIX/hilog-null.txt" <<EOF
10-15 09:00:00.000  1000  1000 I C00000 [clipboard-probe] clipboard: wrote 9B text='$MARKER'
10-15 09:00:01.000  1000  1000 I C00000 [clipboard-probe] clipboard: read null
EOF
cat > "$FIX/hilog-null-denied.txt" <<EOF
10-15 09:00:00.000  1000  1000 I C00000 [clipboard-probe] clipboard: read null
10-15 09:00:00.500  1000  1000 E C00000 pasteboard_service: GetPasteDataInner# check permission failed
EOF
cat > "$FIX/hilog-noread.txt" <<EOF
10-15 09:00:00.000  1000  1000 I C00000 [clipboard-probe] clipboard: wrote 9B text='$MARKER'
EOF

# ---- stub hdc --------------------------------------------------------------------------------
cat > "$STUB_BIN/hdc" <<'STUB_HDC_EOF'
#!/bin/sh
# Stub hdc for selftest-clipboard-acl-accept.sh. Never a real device tool.
set -u
if [ -n "${FAKE_HDC_STATE:-}" ]; then
    mkdir -p "$FAKE_HDC_STATE"
    printf '%s\n' "$*" >> "$FAKE_HDC_STATE/calls.log"
fi
case "${1:-}" in
    list)
        [ "${FAKE_HDC_NO_DEVICE:-0}" = 1 ] || printf 'FAKE-DEVICE-1234\n'
        exit 0
        ;;
    install)
        if [ -n "${FAKE_HDC_INSTALL_MSG:-}" ]; then printf '%s\n' "$FAKE_HDC_INSTALL_MSG"; fi
        exit "${FAKE_HDC_INSTALL_RC:-0}"
        ;;
    shell)
        shift
        case "$*" in
            "bm get -u") printf 'udid: %s\n' "${FAKE_HDC_UDID:-0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF}"; exit 0 ;;
            "bm dump"*) cat "${FAKE_HDC_BM:-/dev/null}"; exit 0 ;;
            "hilog -r") exit 0 ;;
            "hilog -x") cat "${FAKE_HDC_HILOG:-/dev/null}"; exit 0 ;;
            "aa start"*) printf 'start ability successfully\n'; exit 0 ;;
        esac
        exit 0
        ;;
esac
exit 0
STUB_HDC_EOF
chmod 755 "$STUB_BIN/hdc"

# ---- stub dotnet -----------------------------------------------------------------------------
cat > "$STUB_BIN/dotnet" <<'STUB_DOTNET_EOF'
#!/bin/sh
# Stub dotnet for selftest-clipboard-acl-accept.sh: the publish writes a fixture hap.
set -u
if [ -n "${FAKE_DOTNET_STATE:-}" ]; then
    mkdir -p "$FAKE_DOTNET_STATE"
    printf '%s\n' "$*" >> "$FAKE_DOTNET_STATE/calls.log"
fi
case "${1:-}" in
    publish)
        [ -n "${FAKE_DOTNET_HAPDIR:-}" ] || exit 3
        mkdir -p "$FAKE_DOTNET_HAPDIR"
        python3 - "${FAKE_DOTNET_HAPDIR}/hello-selftest-acl-unsigned.hap" "${FAKE_DOTNET_PERMS:-1}" <<'PY'
import json, sys, zipfile
dst, want = sys.argv[1], sys.argv[2] == '1'
mod = {"app": {"bundleName": "com.example.hellomauiapp", "versionName": "1.0.0"},
       "module": {"name": "entry", "type": "entry",
                  "requestPermissions": ([{"name": "ohos.permission.READ_PASTEBOARD"}] if want else [])}}
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("module.json", json.dumps(mod))
PY
        printf 'publish ok\n'
        ;;
esac
exit 0
STUB_DOTNET_EOF
chmod 755 "$STUB_BIN/dotnet"

# ---- stub sign-for-device.sh -----------------------------------------------------------------
cat > "$STUB_BIN/sign-for-device.sh" <<'STUB_SIGN_EOF'
#!/bin/sh
# Stub sign-for-device.sh for selftest-clipboard-acl-accept.sh.
set -u
if [ -n "${FAKE_SIGN_STATE:-}" ]; then
    mkdir -p "$FAKE_SIGN_STATE"
    printf '%s\n' "$*" >> "$FAKE_SIGN_STATE/calls.log"
fi
if [ "${FAKE_SIGN_FAIL:-0}" = 1 ]; then
    printf 'stub sign failure\n' >&2
    exit 1
fi
IN=""; OUT=""; prev=""
for a in "$@"; do
    [ "$prev" = "--unsigned" ] && IN="$a"
    [ "$prev" = "--out" ] && OUT="$a"
    prev="$a"
done
[ -n "$IN" ] && [ -n "$OUT" ] || exit 2
cp "$IN" "$OUT"
printf 'signed-by-stub\n' >> "$OUT"
printf 'verify-app OK\n[selftest] release-signed 1 hap(s)\n'
exit 0
STUB_SIGN_EOF
chmod 755 "$STUB_BIN/sign-for-device.sh"

# ---- stub SDK hap-sign-tool (the ACL preflight verify-profile) -------------------------------
cat > "$STUB_TOOLCHAIN/hap-sign-tool" <<'STUB_TOOL_EOF'
#!/bin/sh
# Stub hap-sign-tool for selftest-clipboard-acl-accept.sh: verify-profile copies the fixture.
set -u
case "${1:-}" in
    verify-profile)
        OUT=""; prev=""
        for a in "$@"; do
            [ "$prev" = "-outFile" ] && OUT="$a"
            prev="$a"
        done
        [ -n "$OUT" ] || exit 2
        cp "${FAKE_SIGN_PROFILE_JSON:?FAKE_SIGN_PROFILE_JSON not set}" "$OUT"
        ;;
esac
exit 0
STUB_TOOL_EOF
chmod 755 "$STUB_TOOLCHAIN/hap-sign-tool"

# ---- run helper ------------------------------------------------------------------------------
RC=0
LOG=""
run_accept() { # <tag> <extra-env> [args...]
    _tag="$1"; _extra="$2"; shift 2
    RC=0
    ( cd "$CWD" && env \
        FAKE_HDC_STATE="$STATE_DIR/$_tag/hdc" FAKE_SIGN_STATE="$STATE_DIR/$_tag/sign" \
        FAKE_DOTNET_STATE="$STATE_DIR/$_tag/dotnet" \
        HDC="$STUB_BIN/hdc" DOTNET="$STUB_BIN/dotnet" OHOS_SDK_ROOT="$STUB_SDK" \
        CLIPBOARD_ACL_SIGN_TOOL="$STUB_BIN/sign-for-device.sh" OHOS_HDC_NO_FALLBACK=1 \
        CLIPBOARD_ACL_LOCK="$WORK/lock" CLIPBOARD_ACL_SLEEP=0 CSC_WATCHDOG=0 \
        $_extra \
        sh "$ACCEPT" "$@" ) < /dev/null > "$LOGS/$_tag.log" 2>&1 || RC=$?
    LOG="$LOGS/$_tag.log"
}
hdc_calls()  { printf '%s' "$STATE_DIR/$1/hdc/calls.log"; }
sign_calls() { printf '%s' "$STATE_DIR/$1/sign/calls.log"; }
dotnet_calls() { printf '%s' "$STATE_DIR/$1/dotnet/calls.log"; }

# ---- environment -----------------------------------------------------------------------------
section "environment (selftest $SELFTEST_VERSION)"
log "accept: $ACCEPT"
log "work:   $WORK"
if sh -n "$ACCEPT" 2> "$LOGS/accept-syntax.log"; then
    ok "clipboard-acl-accept.sh passes sh -n"
else
    bad "clipboard-acl-accept.sh fails sh -n (see $LOGS/accept-syntax.log)"
fi
if sh -n "$SELFTEST_DIR/selftest-clipboard-acl-accept.sh" 2> "$LOGS/selftest-syntax.log"; then
    ok "selftest-clipboard-acl-accept.sh passes sh -n"
else
    bad "selftest-clipboard-acl-accept.sh fails sh -n (see $LOGS/selftest-syntax.log)"
fi

GIT_BEFORE=""
if command -v git >/dev/null 2>&1 && git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    GIT_BEFORE="$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null || true)"
fi

# ---- stub contract ---------------------------------------------------------------------------
section "stub contract"
RC=0
FAKE_HDC_STATE="$STATE_DIR/contract-hdc" "$STUB_BIN/hdc" list targets > "$LOGS/contract-hdc.log" 2>&1 || RC=$?
assert_rc 0 "stub hdc list targets succeeds"
LOG="$LOGS/contract-hdc.log"
assert_log_contains "stub hdc reports a device" "FAKE-DEVICE-1234"
FAKE_HDC_STATE="$STATE_DIR/contract-hdc" FAKE_HDC_INSTALL_MSG="install failed: 9568289" FAKE_HDC_INSTALL_RC=1 \
    "$STUB_BIN/hdc" install -r "$ACL_HAP" > "$LOGS/contract-install.log" 2>&1 || RC=$?
assert_rc 1 "stub hdc install failure rc propagates"
LOG="$STATE_DIR/contract-hdc/calls.log"
assert_log_contains "stub hdc recorded both calls" "install -r"
RC=0
FAKE_SIGN_PROFILE_JSON="$PROFILE_ACL_JSON" "$STUB_TOOLCHAIN/hap-sign-tool" verify-profile \
    -inFile "$PROFILE_ACL" -outFile "$LOGS/contract-profile.json" > /dev/null 2>&1 || RC=$?
assert_rc 0 "stub hap-sign-tool verify-profile succeeds"
LOG="$LOGS/contract-profile.json"
assert_log_contains "stub verify-profile wrote the ACL fixture" "READ_PASTEBOARD"
RC=0
FAKE_SIGN_STATE="$STATE_DIR/contract-sign" "$STUB_BIN/sign-for-device.sh" --release --profile "$PROFILE_ACL" \
    --unsigned "$ACL_HAP" --out "$LOGS/contract-signed.hap" > /dev/null 2>&1 || RC=$?
assert_rc 0 "stub sign-for-device succeeds"
LOG=""
if file_contains "$LOGS/contract-signed.hap" 'signed-by-stub'; then
    ok "stub sign output carries its marker"
else
    bad "stub sign output carries its marker"
fi
RC=0

# ---- T1: usage and missing material ----------------------------------------------------------
section "T1 usage and material contract (no stub calls)"
run_accept T1-noargs ""
assert_rc 2 "T1 no arguments"
assert_log_contains "T1 prints usage" "usage: sh scripts/clipboard-acl-accept.sh"
assert_no_calls "T1 noargs: no hdc call" "$(hdc_calls T1-noargs)"

run_accept T1-nosign "" --hap "$ACL_HAP" --profile "$PROFILE_ACL" --key "$KEY"
assert_rc 2 "T1 --sign is required"
assert_log_contains "T1 names --sign" "--sign release|external is required"

run_accept T1-badsign "" --hap "$ACL_HAP" --sign sideways --profile "$PROFILE_ACL" --key "$KEY"
assert_rc 2 "T1 unknown --sign mode"
assert_log_contains "T1 names the unknown mode" "unknown --sign mode: sideways"

run_accept T1-nohap "" --sign release --profile "$PROFILE_ACL" --key "$KEY"
assert_rc 2 "T1 --build or --hap is required"
assert_log_contains "T1 names both" "pass --build or --hap"

run_accept T1-badmarker "" --hap "$ACL_HAP" --sign release --profile "$PROFILE_ACL" --key "$KEY" --marker 'bad marker!'
assert_rc 2 "T1 a bad marker is refused"
assert_log_contains "T1 names the marker rule" "must be [A-Za-z0-9._-]+"

run_accept T1-extmissing "" --hap "$ACL_HAP" --sign external
assert_rc 1 "T1 external without material"
assert_log_contains "T1 names the missing profile" "--sign external requires --profile"

run_accept T1-extnoalias "" --hap "$ACL_HAP" --sign external --profile "$PROFILE_ACL" --key "$KEY"
assert_rc 1 "T1 external without --key-alias"
assert_log_contains "T1 names --key-alias" "--sign external requires --key-alias"

run_accept T1-noprofile "" --hap "$ACL_HAP" --sign release --profile "$WORK/nope.p7b" --key "$KEY"
assert_rc 1 "T1 a nonexistent profile is refused"
assert_log_contains "T1 names the missing profile file" "profile not found:"

run_accept T1-nokey "" --hap "$ACL_HAP" --sign release --profile "$PROFILE_ACL" --key "$WORK/nope.p12"
assert_rc 1 "T1 a nonexistent keystore is refused"
assert_log_contains "T1 names the missing keystore file" "keystore not found:"

run_accept T1-pwdfile "" --hap "$ACL_HAP" --sign release --profile "$PROFILE_ACL" --key "$KEY" \
    --key-pwd-file "$WORK/nope.txt"
assert_rc 1 "T1 a nonexistent password file is refused"
assert_log_contains "T1 names the missing password file" "password file not found:"
assert_no_calls "T1 pwdfile: no hdc call" "$(hdc_calls T1-pwdfile)"

# ---- T2: the ACL gate (fail closed) ----------------------------------------------------------
section "T2 ACL preflight fail-closed"
run_accept T2-noacl "FAKE_SIGN_PROFILE_JSON=$PROFILE_NOACL_JSON" \
    --hap "$ACL_HAP" --sign release --profile "$PROFILE_NOACL" --key "$KEY" --cert "$CERT" \
    --key-pwd-file "$PW_FILE" --out "$WORK/out-T2-noacl"
assert_rc 1 "T2 a profile without READ_PASTEBOARD is refused"
assert_log_contains "T2 names the missing ACL" "no ohos.permission.READ_PASTEBOARD ACL"
assert_log_contains "T2 says why it matters" "Refusing before signing"
assert_no_calls "T2 nothing was signed" "$(sign_calls T2-noacl)"
assert_no_calls "T2 nothing was installed" "$(hdc_calls T2-noacl)"
assert_not_exists "T2 no report" "$WORK/out-T2-noacl/report.md"

run_accept T2-restricted "FAKE_SIGN_PROFILE_JSON=$PROFILE_RESTRICTED_JSON" \
    --hap "$ACL_HAP" --sign release --profile "$PROFILE_RESTRICTED" --key "$KEY" --cert "$CERT" \
    --key-pwd-file "$PW_FILE" --out "$WORK/out-T2-restricted" --dry-run
assert_rc 0 "T2 the restricted-permissions spelling also passes the ACL gate"
assert_log_contains "T2 names where the ACL was found" "permissions.restricted-permissions"

# ---- T3: happy path (release) ----------------------------------------------------------------
section "T3 happy path: sign -> install -> bm dump -> write/read probe -> report"
run_accept T3 "FAKE_SIGN_PROFILE_JSON=$PROFILE_ACL_JSON FAKE_HDC_BM=$FIX/bm-acl.json FAKE_HDC_HILOG=$FIX/hilog-ok.txt" \
    --hap "$ACL_HAP" --sign release --profile "$PROFILE_ACL" --key "$KEY" --cert "$CERT" \
    --key-pwd-file "$PW_FILE" --marker "$MARKER" --out "$WORK/out-T3"
assert_rc 0 "T3 the acceptance passes"
assert_calls_has "T3 the sign stub got --release" "$(sign_calls T3)" " --release "
assert_calls_has "T3 the sign stub got the profile" "$(sign_calls T3)" "--profile $PROFILE_ACL"
assert_calls_has "T3 the sign stub got the cert chain" "$(sign_calls T3)" "--cert $CERT"
assert_calls_has "T3 the sign stub got the password file" "$(sign_calls T3)" "--key-pwd-file $PW_FILE"
assert_calls_has "T3 install ran" "$(hdc_calls T3)" "install -r"
assert_calls_has "T3 bm dump ran for the bundle" "$(hdc_calls T3)" "shell bm dump -n $BUNDLE"
assert_calls_has "T3 the write probe was started" "$(hdc_calls T3)" "app://clipboard/write/$MARKER"
assert_calls_has "T3 the read probe was started" "$(hdc_calls T3)" "app://clipboard/read"
assert_calls_has "T3 the hilog dump was captured" "$(hdc_calls T3)" "hilog -x"
assert_log_contains "T3 ACL evidence logged" "ACL preflight OK: FOUND"
assert_log_contains "T3 bm dump evidence logged" "bm dump ACL evidence: FOUND"
assert_log_contains "T3 runtime read pass logged" "runtime read OK"
assert_log_contains "T3 verdict" "acceptance PASS"
assert_file "T3 report written" "$WORK/out-T3/report.md"
LOG="$WORK/out-T3/report.md"
assert_log_contains "T3 the report verdict is PASS" "- verdict: PASS"
assert_log_contains "T3 the report carries the marker" "marker $MARKER"
assert_file "T3 install evidence kept" "$WORK/out-T3/install.log"
assert_file "T3 hilog evidence kept" "$WORK/out-T3/hilog-runtime.txt"
assert_log_not_contains "T3 the password is not in the report" "selftest-pw"

# ---- T4: external (debug/ACL profile), UDID read from the device ------------------------------
section "T4 --sign external: UDID from the device / --expect-udid wins"
run_accept T4 "FAKE_SIGN_PROFILE_JSON=$PROFILE_ACL_JSON FAKE_HDC_BM=$FIX/bm-granted.json FAKE_HDC_HILOG=$FIX/hilog-ok.txt" \
    --hap "$ACL_HAP" --sign external --profile "$PROFILE_ACL" --key "$KEY" --key-alias debugKey --cert "$CERT" \
    --key-pwd-file "$PW_FILE" --marker "$MARKER" --out "$WORK/out-T4"
assert_rc 0 "T4 the external acceptance passes"
assert_calls_has "T4 the UDID is read from the device" "$(hdc_calls T4)" "shell bm get -u"
assert_calls_has "T4 the sign stub got --external" "$(sign_calls T4)" " --external "
assert_calls_has "T4 the sign stub got the device UDID" "$(sign_calls T4)" "--expect-udid $UDID_A"
assert_log_contains "T4 bm dump granted-permission spelling accepted" "bm dump ACL evidence: FOUND"

run_accept T4b "FAKE_SIGN_PROFILE_JSON=$PROFILE_ACL_JSON FAKE_HDC_BM=$FIX/bm-acl.json FAKE_HDC_HILOG=$FIX/hilog-ok.txt" \
    --hap "$ACL_HAP" --sign external --profile "$PROFILE_ACL" --key "$KEY" --key-alias debugKey \
    --expect-udid FIXED-UDID --cert "$CERT" --key-pwd-file "$PW_FILE" --marker "$MARKER" --out "$WORK/out-T4b"
assert_rc 0 "T4b the explicit UDID run passes"
assert_calls_has "T4b --expect-udid wins over the device read" "$(sign_calls T4b)" "--expect-udid FIXED-UDID"
if calls_has "$(hdc_calls T4b)" "bm get -u"; then
    bad "T4b the device UDID was not read when --expect-udid was given"
else
    ok "T4b the device UDID was not read when --expect-udid was given"
fi

# ---- T5: red controls ------------------------------------------------------------------------
section "T5 red controls"
run_accept T5-absent "FAKE_SIGN_PROFILE_JSON=$PROFILE_ACL_JSON FAKE_HDC_BM=$FIX/bm-absent.json FAKE_HDC_HILOG=$FIX/hilog-ok.txt" \
    --hap "$ACL_HAP" --sign release --profile "$PROFILE_ACL" --key "$KEY" --cert "$CERT" \
    --key-pwd-file "$PW_FILE" --out "$WORK/out-T5-absent"
assert_rc 1 "T5 a bundle without the ACL in bm dump fails"
assert_log_contains "T5 says the dump lacks the ACL" "does not report READ_PASTEBOARD"
assert_log_contains "T5 reports ABSENT" "ABSENT"
assert_not_exists "T5 no report on failure" "$WORK/out-T5-absent/report.md"

run_accept T5-ungranted "FAKE_SIGN_PROFILE_JSON=$PROFILE_ACL_JSON FAKE_HDC_BM=$FIX/bm-ungranted.json FAKE_HDC_HILOG=$FIX/hilog-ok.txt" \
    --hap "$ACL_HAP" --sign release --profile "$PROFILE_ACL" --key "$KEY" --cert "$CERT" \
    --key-pwd-file "$PW_FILE" --out "$WORK/out-T5-ungranted"
assert_rc 1 "T5 an ungranted ACL in bm dump fails"
assert_log_contains "T5 names the ungranted state" "PRESENT-BUT-NOT-GRANTED"

run_accept T5-install "FAKE_SIGN_PROFILE_JSON=$PROFILE_ACL_JSON FAKE_HDC_INSTALL_MSG=9568289 FAKE_HDC_INSTALL_RC=1" \
    --hap "$ACL_HAP" --sign release --profile "$PROFILE_ACL" --key "$KEY" --cert "$CERT" \
    --key-pwd-file "$PW_FILE" --out "$WORK/out-T5-install"
assert_rc 1 "T5 an install failure fails the acceptance"
assert_log_contains "T5 explains 9568289" "the profile did not carry READ_PASTEBOARD"
assert_calls_has "T5 the install was attempted" "$(hdc_calls T5-install)" "install -r"
if calls_has "$(hdc_calls T5-install)" "bm dump"; then
    bad "T5 bm dump ran despite the install failure"
else
    ok "T5 bm dump ran despite the install failure"
fi

run_accept T5-signfail "FAKE_SIGN_PROFILE_JSON=$PROFILE_ACL_JSON FAKE_SIGN_FAIL=1" \
    --hap "$ACL_HAP" --sign release --profile "$PROFILE_ACL" --key "$KEY" --cert "$CERT" \
    --key-pwd-file "$PW_FILE" --out "$WORK/out-T5-signfail"
assert_rc 1 "T5 a sign failure fails the acceptance"
assert_log_contains "T5 names the signing failure" "signing failed"
if calls_has "$(hdc_calls T5-signfail)" "install -r"; then
    bad "T5 install ran despite the signing failure"
else
    ok "T5 install ran despite the signing failure"
fi

run_accept T5-null "FAKE_SIGN_PROFILE_JSON=$PROFILE_ACL_JSON FAKE_HDC_BM=$FIX/bm-acl.json FAKE_HDC_HILOG=$FIX/hilog-null.txt" \
    --hap "$ACL_HAP" --sign release --profile "$PROFILE_ACL" --key "$KEY" --cert "$CERT" \
    --key-pwd-file "$PW_FILE" --marker "$MARKER" --out "$WORK/out-T5-null"
assert_rc 1 "T5 a null runtime read fails the acceptance"
assert_log_contains "T5 names the null read" "read returned null"

run_accept T5-denied "FAKE_SIGN_PROFILE_JSON=$PROFILE_ACL_JSON FAKE_HDC_BM=$FIX/bm-acl.json FAKE_HDC_HILOG=$FIX/hilog-null-denied.txt" \
    --hap "$ACL_HAP" --sign release --profile "$PROFILE_ACL" --key "$KEY" --cert "$CERT" \
    --key-pwd-file "$PW_FILE" --marker "$MARKER" --out "$WORK/out-T5-denied"
assert_rc 1 "T5 a null read with the service denial fails"
assert_log_contains "T5 quotes the service denial" "check permission failed"

run_accept T5-noread "FAKE_SIGN_PROFILE_JSON=$PROFILE_ACL_JSON FAKE_HDC_BM=$FIX/bm-acl.json FAKE_HDC_HILOG=$FIX/hilog-noread.txt" \
    --hap "$ACL_HAP" --sign release --profile "$PROFILE_ACL" --key "$KEY" --cert "$CERT" \
    --key-pwd-file "$PW_FILE" --marker "$MARKER" --out "$WORK/out-T5-noread"
assert_rc 1 "T5 a missing read line fails the acceptance"
assert_log_contains "T5 hints at the probe build" "ClipboardProbe build"

run_accept T5-nohapdecl "FAKE_SIGN_PROFILE_JSON=$PROFILE_ACL_JSON" \
    --hap "$PLAIN_HAP" --sign release --profile "$PROFILE_ACL" --key "$KEY" --cert "$CERT" \
    --key-pwd-file "$PW_FILE" --out "$WORK/out-T5-nohapdecl"
assert_rc 1 "T5 a hap without the READ_PASTEBOARD declaration is refused"
assert_log_contains "T5 names the build property" "-p:OpenHarmonyFeatures=clipboard"
assert_no_calls "T5 nohapdecl: nothing was signed" "$(sign_calls T5-nohapdecl)"

# ---- T6: --build through the dotnet stub -----------------------------------------------------
section "T6 --build: publish argv and the produced hap"
# The stub writes into the real (gitignored) publish dir of this checkout, because the accept
# script locates the hap there; the fixture is removed again at the end of the test.
BUILD_HAPDIR="$ROOT_DIR/test/hello-maui-app/bin/Release/net11.0-openharmony26.0/openharmony-arm64"
run_accept T6 "FAKE_SIGN_PROFILE_JSON=$PROFILE_ACL_JSON FAKE_HDC_BM=$FIX/bm-acl.json FAKE_HDC_HILOG=$FIX/hilog-ok.txt FAKE_DOTNET_HAPDIR=$BUILD_HAPDIR FAKE_DOTNET_PERMS=1" \
    --build --sign release --profile "$PROFILE_ACL" --key "$KEY" --cert "$CERT" \
    --key-pwd-file "$PW_FILE" --marker "$MARKER" --out "$WORK/out-T6"
assert_rc 0 "T6 the build-mode acceptance passes"
assert_calls_has "T6 the publish got the clipboard feature" "$(dotnet_calls T6)" "-p:OpenHarmonyFeatures=clipboard"
assert_calls_has "T6 the publish got the device probe" "$(dotnet_calls T6)" "-p:ClipboardProbe=true"
assert_calls_has "T6 the publish targeted the probe project" "$(dotnet_calls T6)" "hello-maui-app.csproj"
assert_log_contains "T6 the probe identity was read back" "probe identity: bundle $BUNDLE"
assert_file "T6 build evidence kept" "$WORK/out-T6/build.log"
rm -f "$BUILD_HAPDIR/hello-selftest-acl-unsigned.hap" "$BUILD_HAPDIR/hello-selftest-acl-unsigned-acl-signed.hap"

# ---- T7: dry-run ------------------------------------------------------------------------------
section "T7 --dry-run never touches stubs"
run_accept T7 "FAKE_SIGN_PROFILE_JSON=$PROFILE_ACL_JSON" \
    --hap "$ACL_HAP" --sign release --profile "$PROFILE_ACL" --key "$KEY" --cert "$CERT" \
    --key-pwd-file "$PW_FILE" --out "$WORK/out-T7" --dry-run
assert_rc 0 "T7 the dry-run passes"
assert_log_contains "T7 runs the ACL preflight" "ACL preflight OK"
assert_log_contains "T7 prints the plan" "dry-run: nothing built, signed, installed or started"
assert_no_calls "T7 no hdc call" "$(hdc_calls T7)"
assert_no_calls "T7 no sign call" "$(sign_calls T7)"
assert_no_calls "T7 no dotnet call" "$(dotnet_calls T7)"

# ---- T8: device lock --------------------------------------------------------------------------
section "T8 device lock (stale reclaim, live timeout)"
rm -rf "$WORK/lock"
mkdir -p "$WORK/lock"
touch -t 202001010000 "$WORK/lock" 2>/dev/null || ok "mock: touch -t unsupported (mtime set skipped)"
run_accept T8-stale "FAKE_SIGN_PROFILE_JSON=$PROFILE_ACL_JSON FAKE_HDC_BM=$FIX/bm-acl.json FAKE_HDC_HILOG=$FIX/hilog-ok.txt" \
    --hap "$ACL_HAP" --sign release --profile "$PROFILE_ACL" --key "$KEY" --cert "$CERT" \
    --key-pwd-file "$PW_FILE" --marker "$MARKER" --out "$WORK/out-T8-stale"
assert_rc 0 "T8 a stale lock is reclaimed and the round passes"
assert_log_contains "T8 names the stale reclaim" "reclaiming a stale lock"
assert_not_exists "T8 the lock is released afterwards" "$WORK/lock"

rm -rf "$WORK/lock"
mkdir -p "$WORK/lock"
printf 'other-agent 999\n' > "$WORK/lock/owner"
run_accept T8-live "FAKE_SIGN_PROFILE_JSON=$PROFILE_ACL_JSON CLIPBOARD_ACL_LOCK_ATTEMPTS=1 CLIPBOARD_ACL_LOCK_INTERVAL=0" \
    --hap "$ACL_HAP" --sign release --profile "$PROFILE_ACL" --key "$KEY" --cert "$CERT" \
    --key-pwd-file "$PW_FILE" --out "$WORK/out-T8-live"
assert_rc 1 "T8 a live lock times out"
assert_log_contains "T8 names the lock timeout" "device lock timeout"
assert_file "T8 the other owner's lock survives" "$WORK/lock/owner"
rm -rf "$WORK/lock"

# ---- global ------------------------------------------------------------------------------------
section "global: cleanup and repo safety"
assert_eq "global sandbox cwd untouched" "" "$(ls -A "$CWD" 2>/dev/null)"
LEFTOVER_TMP="$(find "$TMPD" -mindepth 1 -print 2>/dev/null)"
assert_eq "global the script's temp files are cleaned up" "" "$LEFTOVER_TMP"
if [ -n "${GIT_BEFORE:-}" ]; then
    GIT_AFTER="$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null || true)"
    if [ "$GIT_BEFORE" = "$GIT_AFTER" ]; then
        ok "global the repo working tree is unchanged by the selftest"
    else
        bad "global the selftest changed the repo working tree"
    fi
else
    skip "global repo working tree check (not a git work tree)"
fi

# ---- summary -----------------------------------------------------------------------------------
section "selftest summary"
printf 'accept: %s\n' "$ACCEPT"
printf 'checks: %s, failed: %s\n' "$CHECKS" "$FAILED"
if [ "$FAILED" -gt 0 ]; then
    printf 'RESULT: FAIL\nlogs kept at: %s\n' "$WORK"
    exit 1
fi
printf 'RESULT: PASS\n'
[ "$KEEP" = 1 ] && printf 'work dir kept (SELFTEST_KEEP=1): %s\n' "$WORK"
exit 0
