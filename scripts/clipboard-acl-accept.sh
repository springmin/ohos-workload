#!/bin/sh
# clipboard-acl-accept.sh - on-device acceptance for the ACL-gated clipboard read (ACL-PROFILE).
#
# The clipboard feature only becomes usable with an ACL-bearing profile
# (ohos.permission.READ_PASTEBOARD, availableLevel system_basic); a plain signature domain is
# refused at install time with 9568289. This script drives the whole acceptance round:
#
#   1 build   (--build): dotnet publish the hello-maui-app probe with the ACL-gated feature and
#             the clipboard device probe: -p:OpenHarmonyFeatures=clipboard -p:ClipboardProbe=true
#   2 preflight (fail-closed, before signing): hap-sign-tool verify-profile + the profile must
#             carry ohos.permission.READ_PASTEBOARD in acls.allowed-acls (or the restricted
#             permissions list). No ACL -> nothing is signed or installed.
#   3 sign    --sign release  -> sign-for-device.sh --release (AGC release cert/profile)
#             --sign external -> sign-for-device.sh --external --expect-udid <device UDID>
#             (a debug/trial profile carrying the ACL; the UDID is read from the device when
#             --expect-udid is omitted)
#   4 install hdc install -r; 9568289 -> the profile did not carry the ACL to the device
#   5 bm dump the installed bundle must report READ_PASTEBOARD (ACL list or granted request)
#   6 runtime write a marker through the shell pasteboard path
#             (aa start -U app://clipboard/write/<marker>), then read it through the host NDK
#             probe (aa start -U app://clipboard/read); the [clipboard-probe] hilog line must
#             carry the marker back. "clipboard: read null" is the ACL-denied signature
#             (service-side GetPasteDataAPI denial) and fails the acceptance.
#   7 report  evidence (build/sign/install logs, profile JSON, bm dump, hilog window) and a
#             PASS/FAIL report.md land in <out>/.
#
# Usage:
#   sh scripts/clipboard-acl-accept.sh --build --sign release
#     --profile <p7b> --key <p12> --cert <cer> [--key-alias <alias>]
#     [--key-pwd-file <file>|--pwd-input-mode] [--marker <text>] [--out <dir>] [--dry-run]
#   sh scripts/clipboard-acl-accept.sh --build --sign external
#     --profile <p7b> --key <p12> --key-alias <alias> [--cert <cer>] [--expect-udid <UDID>]
#     [--key-pwd-file <file>|--pwd-input-mode] [--marker <text>] [--out <dir>] [--dry-run]
#   sh scripts/clipboard-acl-accept.sh --hap <unsigned.hap> ... (skip the build)
#   sh scripts/clipboard-acl-accept.sh -h
#
# Env: OHOS_SDK_ROOT (hap-sign-tool for the ACL preflight and for the sign script),
#   DOTNET (default dotnet), HDC (default hdc; the sandbox's stock hdc may answer no targets),
#   OHOS_HDC_PATCHED / OHOS_HDC_NO_FALLBACK (patched-hdc fallback, the device-round.sh
#   contract; the default candidate is $HOME/.ohos-tools/hdcp4),
#   OHOS_PWD_INPUT_MODE (1 = --pwd-input-mode), OHOS_RELEASE_P7B / OHOS_RELEASE_DIR (--sign
#   release profile defaults, same contract as sign-for-device.sh),
#   CLIPBOARD_ACL_SIGN_TOOL (default scripts/sign-for-device.sh; the selftest injects a stub),
#   CLIPBOARD_ACL_LOCK (device-lock dir; default the shared /data/.../opencode/.device-lock),
#   CLIPBOARD_ACL_LOCK_ATTEMPTS / _INTERVAL / _STALE (lock protocol knobs),
#   CLIPBOARD_ACL_SLEEP (seconds per activation window, default 5),
#   CSC_WATCHDOG=0 disables the csc-livelock wrapper for the build.
# Exit: 0 = acceptance passed; 1 = acceptance failed (evidence kept); 2 = usage;
#       3 = no device / hdc.
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
W="$(cd "$SELF_DIR/.." && pwd)"

SDK="${OHOS_SDK_ROOT:-$HOME/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_2}"
TOOLCHAIN="$SDK/toolchains/lib"
DOTNET="${DOTNET:-dotnet}"
HDC="${HDC:-hdc}"
SIGN_TOOL="${CLIPBOARD_ACL_SIGN_TOOL:-$SELF_DIR/sign-for-device.sh}"
CSPROJ="$W/test/hello-maui-app/hello-maui-app.csproj"
TFM="net11.0-openharmony26.0"
RID="openharmony-arm64"
SLEEP="${CLIPBOARD_ACL_SLEEP:-5}"
WATCHDOG="$W/scripts/run-with-csc-watchdog.sh"

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }
die_no_device() { warn "$*"; exit 3; }

usage() {
    cat <<'EOF'
usage: sh scripts/clipboard-acl-accept.sh (--build|--hap <unsigned.hap>) --sign release|external
         --profile <p7b> --key <p12> [--cert <cer>] [--key-alias <alias>] [--expect-udid <UDID>]
         [--key-pwd-file <file>|--pwd-input-mode] [--marker <text>] [--out <dir>] [--dry-run]
       sh scripts/clipboard-acl-accept.sh -h

  --build                dotnet publish the probe with
                         -p:OpenHarmonyFeatures=clipboard -p:ClipboardProbe=true
  --hap <hap>            use a prebuilt unsigned hap instead of building (its module.json must
                         declare ohos.permission.READ_PASTEBOARD)
  --sign release         sign via sign-for-device.sh --release (AGC release material)
  --sign external        sign via sign-for-device.sh --external (debug/ACL profile + UDID)
  --profile/--key/--cert/--key-alias/--key-pwd-file/--pwd-input-mode, --expect-udid
                         forwarded to sign-for-device.sh; for --sign release the profile can
                         also come from OHOS_RELEASE_P7B / OHOS_RELEASE_DIR
  --marker <text>        clipboard text to write+read (default ACLCHK-<pid>; [A-Za-z0-9._-]+)
  --out <dir>            evidence dir (default ./clipboard-acl-<stamp>)
  --dry-run              validate the profile ACL and print the plan; never builds/signs/installs
EOF
}

PROFILE=""; KEY=""; CERT=""; ALIAS=""; PWD_FILE=""; EXPECT_UDID=""
HAP=""; BUILD=0; SIGN_MODE=""; MARKER=""; OUT=""; DRY=0
UDID=""; SIGNED=""; BM_EVIDENCE=""
MARKER="ACLCHK-$$"

while [ $# -gt 0 ]; do
    case "$1" in
        --build) BUILD=1; shift ;;
        --hap) HAP="$2"; shift 2 ;;
        --sign) SIGN_MODE="$2"; shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --key) KEY="$2"; shift 2 ;;
        --cert) CERT="$2"; shift 2 ;;
        --key-alias) ALIAS="$2"; shift 2 ;;
        --key-pwd-file) PWD_FILE="$2"; shift 2 ;;
        --pwd-input-mode) PWD_INPUT_MODE=1; shift ;;
        --expect-udid) EXPECT_UDID="$2"; shift 2 ;;
        --marker) MARKER="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --*) warn "unknown option: $1"; usage >&2; exit 2 ;;
        *) warn "unexpected argument: $1"; usage >&2; exit 2 ;;
    esac
done

case "${PWD_INPUT_MODE:-${OHOS_PWD_INPUT_MODE:-0}}" in
    1) PWD_INPUT_MODE=1 ;;
    ""|0) PWD_INPUT_MODE=0 ;;
    *) die "OHOS_PWD_INPUT_MODE must be 0 or 1" ;;
esac

# ---- argument contract (fail closed before anything runs) -----------------------------------
case "$SIGN_MODE" in
    release) ;;
    external|debug) SIGN_MODE=external ;;
    "") warn "--sign release|external is required"; usage >&2; exit 2 ;;
    *) warn "unknown --sign mode: $SIGN_MODE (release|external)"; usage >&2; exit 2 ;;
esac
[ "$BUILD" = 1 ] || [ -n "$HAP" ] || { warn "pass --build or --hap <unsigned.hap>"; usage >&2; exit 2; }
case "$MARKER" in
    ""|*[!A-Za-z0-9._-]*) warn "--marker must be [A-Za-z0-9._-]+ (got: $MARKER)"; exit 2 ;;
esac

# --sign release: fall back to the same material defaults as sign-for-device.sh.
if [ "$SIGN_MODE" = release ]; then
    [ -n "$PROFILE" ] || PROFILE="${OHOS_RELEASE_P7B:-}"
    if [ -z "$PROFILE" ]; then
        _rel_dir="${OHOS_RELEASE_DIR:-$HOME/Documents/ohos/release}"
        _rel_match="$(ls "$_rel_dir"/*.p7b 2>/dev/null | head -2)"
        _rel_n="$(printf '%s' "$_rel_match" | grep -c . || true)"
        if [ "$_rel_n" = 1 ]; then
            PROFILE="$_rel_match"
        elif [ "$_rel_n" -gt 1 ]; then
            warn "several *.p7b under $_rel_dir; pass --profile (or set OHOS_RELEASE_P7B)"
            exit 2
        fi
    fi
else
    [ -n "$PROFILE" ] || die "--sign external requires --profile <p7b>"
    [ -n "$KEY" ] || die "--sign external requires --key <p12>"
    [ -n "$ALIAS" ] || die "--sign external requires --key-alias <alias>"
fi
[ -n "$PROFILE" ] || die "no ACL profile: pass --profile <p7b> (or OHOS_RELEASE_P7B / OHOS_RELEASE_DIR)"
[ -f "$PROFILE" ] || die "profile not found: $PROFILE"
[ -n "$KEY" ] || die "no keystore: pass --key <p12>"
[ -f "$KEY" ] || die "keystore not found: $KEY"
if [ -n "$CERT" ]; then [ -f "$CERT" ] || die "app cert chain not found: $CERT"; fi
[ -n "$PWD_FILE" ] || PWD_FILE="${OHOS_RELEASE_PWD_FILE:-}"
[ -z "$PWD_FILE" ] || [ -f "$PWD_FILE" ] || die "password file not found: $PWD_FILE"
[ -f "$SIGN_TOOL" ] || die "sign script not found: $SIGN_TOOL (CLIPBOARD_ACL_SIGN_TOOL)"

STAMP="$(date '+%Y%m%d-%H%M%S')"
[ -n "$OUT" ] || OUT="./clipboard-acl-$STAMP"
mkdir -p "$OUT" || die "cannot create the evidence dir: $OUT"

die_with_log() { # <log> <message>
    [ -s "$1" ] && tail -n 30 "$1" | sed 's/^/    /' >&2
    die "$2"
}

# ---- step 2a: ACL preflight (read-only; before any signing or installing) -------------------
# Fail closed: the profile must carry ohos.permission.READ_PASTEBOARD, otherwise the round is
# pointless (install would answer 9568289 on a plain domain) and nothing is signed/installed.
ACL_EVIDENCE="not-run"
acl_preflight() {
    if [ ! -x "$TOOLCHAIN/hap-sign-tool" ]; then
        if [ "$DRY" = 1 ]; then
            warn "hap-sign-tool not found in $TOOLCHAIN (set OHOS_SDK_ROOT); ACL preflight skipped in --dry-run"
            ACL_EVIDENCE="skipped (dry-run, no hap-sign-tool)"
            return 0
        fi
        die "hap-sign-tool not found in $TOOLCHAIN (set OHOS_SDK_ROOT); needed for the ACL preflight"
    fi
    if ! "$TOOLCHAIN/hap-sign-tool" verify-profile -inFile "$PROFILE" -outFile "$OUT/profile-verify.json" \
        > "$OUT/verify-profile.log" 2>&1; then
        die_with_log "$OUT/verify-profile.log" "cannot verify the signed profile: $PROFILE (hap-sign-tool verify-profile failed; is this the ACL p7b?)"
    fi
    if ! python3 - "$OUT/profile-verify.json" > "$OUT/acl-check.txt" 2>&1 <<'PY'
import json, sys
PERM = 'ohos.permission.READ_PASTEBOARD'
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print('unreadable profile JSON: %s' % e)
    sys.exit(1)
where = []
if PERM in ((d.get('acls') or {}).get('allowed-acls') or []):
    where.append('acls.allowed-acls')
if PERM in ((d.get('permissions') or {}).get('restricted-permissions') or []):
    where.append('permissions.restricted-permissions')
if not where:
    ac = ((d.get('acls') or {}).get('allowed-acls') or [])
    print('MISSING (%s carries %d acl entr%s)' % (
        (d.get('bundle-info') or {}).get('bundle-name', '?'), len(ac), 'y' if len(ac) == 1 else 'ies'))
    sys.exit(1)
print('FOUND ' + ','.join(where))
PY
    then
        ACMSG="$(cat "$OUT/acl-check.txt" 2>/dev/null)"
        ACL_EVIDENCE="missing"
        die "the profile has no ohos.permission.READ_PASTEBOARD ACL ($ACMSG): the ACL application is not approved for this bundle, or this is the wrong p7b. Refusing before signing (an ACL-declaring hap installs only in the ACL signing domain)"
    fi
    ACL_EVIDENCE="$(cat "$OUT/acl-check.txt")"
    log "ACL preflight OK: $ACL_EVIDENCE ($(basename "$PROFILE"))"
}

# ---- hdc resolution (stock hdc first, patched fallback) -------------------------------------
HDC_TARGETS=""
hdc_answers() { # <hdc>
    case "$1" in
        */*) [ -x "$1" ] || return 1 ;;
        *) command -v "$1" >/dev/null 2>&1 || return 1 ;;
    esac
    HDC_TARGETS="$("$1" list targets 2>/dev/null | tr -d '\r' | grep -v -e '^[[:space:]]*$' -e '^\[Empty\]$' || true)"
    [ -n "$HDC_TARGETS" ]
}
hdc_patched_candidate() {
    if [ -n "${OHOS_HDC_PATCHED:-}" ]; then printf '%s\n' "$OHOS_HDC_PATCHED"; return 0; fi
    if [ -n "${HOME:-}" ] && [ -x "$HOME/.ohos-tools/hdcp4" ]; then printf '%s\n' "$HOME/.ohos-tools/hdcp4"; return 0; fi
    return 1
}
resolve_device_hdc() {
    [ "${OHOS_HDC_NO_FALLBACK:-0}" = 1 ] && return 0
    hdc_answers "$HDC" && return 0
    HDC_TARGETS=""
    _fb="$(hdc_patched_candidate)" || return 0
    [ "$_fb" = "$HDC" ] && return 0
    if hdc_answers "$_fb"; then
        log "hdc fallback: $HDC sees no device, using the patched hdc $_fb (OHOS_HDC_PATCHED / default \$HOME/.ohos-tools/hdcp4)"
        HDC="$_fb"
    fi
}
require_device() {
    [ "$DRY" = 1 ] && return 0
    resolve_device_hdc
    if ! hdc_answers "$HDC"; then
        die_no_device "hdc list targets is empty (device offline?): HDC=$HDC; connect the device (USB debugging on) or use --dry-run"
    fi
    log "device: $(printf '%s' "$HDC_TARGETS" | tr '\n' ' ')"
}

# ---- device lock (the shared .device-lock protocol, device-round.sh) ------------------------
LOCK_PATH="${CLIPBOARD_ACL_LOCK:-}"
if [ -z "$LOCK_PATH" ] && [ "$DRY" != 1 ]; then
    if [ -d /data/storage/el2/base/tmp/opencode ] && [ -w /data/storage/el2/base/tmp/opencode ]; then
        LOCK_PATH="/data/storage/el2/base/tmp/opencode/.device-lock"
    else
        LOCK_PATH="${TMPDIR:-/tmp}/.device-lock"
    fi
fi
LOCK_HELD=0
lock_release() {
    [ "$LOCK_HELD" = 1 ] || return 0
    if { cat "$LOCK_PATH/owner" 2>/dev/null | grep -q "clipboard-acl-accept.sh $$ "; } || [ ! -f "$LOCK_PATH/owner" ]; then
        rm -rf "$LOCK_PATH" 2>/dev/null || true
        log "device lock released: $LOCK_PATH"
    else
        warn "lock owner changed ($(cat "$LOCK_PATH/owner" 2>/dev/null)); not releasing $LOCK_PATH"
    fi
    LOCK_HELD=0
}
lock_acquire() {
    [ "$DRY" = 1 ] && return 0
    _attempts="${CLIPBOARD_ACL_LOCK_ATTEMPTS:-180}"
    _interval="${CLIPBOARD_ACL_LOCK_INTERVAL:-10}"
    _stale="${CLIPBOARD_ACL_LOCK_STALE:-1200}"
    _i=0
    while ! mkdir "$LOCK_PATH" 2>/dev/null; do
        if [ ! -f "$LOCK_PATH/owner" ]; then
            _mt="$(stat -c %Y "$LOCK_PATH" 2>/dev/null || stat -f %m "$LOCK_PATH" 2>/dev/null || printf '0')"
            _now="$(date '+%s')"
            if [ "${_mt:-0}" -gt 0 ] 2>/dev/null && [ $((_now - _mt)) -gt "$_stale" ]; then
                warn "reclaiming a stale lock (no owner, mtime older than ${_stale}s): $LOCK_PATH"
                rm -rf "$LOCK_PATH" 2>/dev/null || true
                continue
            fi
        fi
        _i=$((_i + 1))
        if [ "$_i" -gt "$_attempts" ]; then
            die "device lock timeout (${_attempts}x${_interval}s): $LOCK_PATH owner=$(cat "$LOCK_PATH/owner" 2>/dev/null)"
        fi
        [ $((_i % 12)) -eq 0 ] && log "   waiting for the device lock #$_i owner=$(cat "$LOCK_PATH/owner" 2>/dev/null)"
        sleep "$_interval"
    done
    printf 'clipboard-acl-accept.sh %s %s\n' "$$" "$(date '+%F %T')" > "$LOCK_PATH/owner" 2>/dev/null || true
    LOCK_HELD=1
    log "device lock acquired: $LOCK_PATH"
}

# ---- steps 1/3/4/5/6 -------------------------------------------------------------------------
do_build() {
    [ "$BUILD" = 1 ] || return 0
    [ -f "$CSPROJ" ] || die "probe project not found: $CSPROJ"
    _cmd="$DOTNET publish $CSPROJ -f $TFM -r $RID -c Release -p:OpenHarmonyFeatures=clipboard -p:ClipboardProbe=true"
    if [ "$DRY" = 1 ]; then
        log "[dry-run] build: $_cmd"
        return 0
    fi
    command -v "$DOTNET" >/dev/null 2>&1 || die "dotnet not found (DOTNET=$DOTNET)"
    # Same dotnet/scratch defaults as the other build-driving scripts.
    . "$W/scripts/lib-dotnet-env.sh" "$W"
    log "== build: probe with -p:OpenHarmonyFeatures=clipboard -p:ClipboardProbe=true =="
    if [ -x "$WATCHDOG" ] && [ "${CSC_WATCHDOG:-1}" != 0 ]; then
        CSC_WATCHDOG_LOG_DIR="$OUT" sh "$WATCHDOG" "$DOTNET" publish "$CSPROJ" -f "$TFM" -r "$RID" -c Release \
            -p:OpenHarmonyFeatures=clipboard -p:ClipboardProbe=true > "$OUT/build.log" 2>&1 \
            || die_with_log "$OUT/build.log" "probe publish failed (see $OUT/build.log)"
    else
        "$DOTNET" publish "$CSPROJ" -f "$TFM" -r "$RID" -c Release \
            -p:OpenHarmonyFeatures=clipboard -p:ClipboardProbe=true > "$OUT/build.log" 2>&1 \
            || die_with_log "$OUT/build.log" "probe publish failed (see $OUT/build.log)"
    fi
    _hapdir="$W/test/hello-maui-app/bin/Release/$TFM/$RID"
    HAP="$(ls -1t "$_hapdir"/*-unsigned.hap 2>/dev/null | head -1)"
    [ -n "$HAP" ] || die "the publish produced no *-unsigned.hap under $_hapdir (see $OUT/build.log)"
    log "probe hap: $HAP"
}

hap_identity() { # <hap> -> "bundle<TAB>perms-space-separated" via python; exit 3 on failure
    python3 - "$1" <<'PY'
import json, sys, zipfile
try:
    with zipfile.ZipFile(sys.argv[1]) as z:
        d = json.loads(z.read('module.json'))
except Exception:
    sys.exit(3)
app = (d.get('app') or {}).get('bundleName') or (d.get('module') or {}).get('bundleName') or ''
if not app:
    sys.exit(3)
perms = [p.get('name') for p in ((d.get('module') or {}).get('requestPermissions') or [])]
sys.stdout.write(app + '\t' + ' '.join(str(p) for p in perms if p))
PY
}

BUNDLE=""
prepare_hap() {
    [ -n "$HAP" ] || die "no hap: pass --build or --hap <unsigned.hap>"
    [ -f "$HAP" ] || die "unsigned hap not found: $HAP"
    _id="$(hap_identity "$HAP")" || die "cannot read module.json from $HAP (not a hap?)"
    BUNDLE="$(printf '%s' "$_id" | cut -f1)"
    _perms="$(printf '%s' "$_id" | cut -f2)"
    case "$BUNDLE" in
        ''|*[!A-Za-z0-9_.]*) die "refusing a non-whitelisted bundleName: $BUNDLE (dotted [A-Za-z0-9_.] only)" ;;
    esac
    printf '%s\n' "$_perms" | grep -Fq 'ohos.permission.READ_PASTEBOARD' \
        || die "$HAP does not declare ohos.permission.READ_PASTEBOARD; build the probe with -p:OpenHarmonyFeatures=clipboard (module.json requestPermissions: '${_perms:-none}')"
    log "probe identity: bundle $BUNDLE, READ_PASTEBOARD declared"
}

read_udid() {
    _u="$("$HDC" shell bm get -u 2>/dev/null | tr -d '\r' | sed -n 's/.*[Uu][Dd][Ii][Dd][^:]*:[[:space:]]*//p' | head -n1)"
    if [ -z "$_u" ]; then
        _u="$("$HDC" shell bm get -u 2>/dev/null | tr -d '\r' | grep -E -e '^[0-9A-Fa-f]{16,}$' | head -n1)"
    fi
    printf '%s' "$_u"
}

do_sign() {
    SIGNED="$(dirname "$HAP")/$(basename "$HAP" .hap)-acl-signed.hap"
    set -- --unsigned "$HAP" --out "$SIGNED"
    if [ "$SIGN_MODE" = release ]; then
        set -- "$@" --release --profile "$PROFILE" --key "$KEY" --cert "$CERT"
        [ -z "$ALIAS" ] || set -- "$@" --key-alias "$ALIAS"
    else
        [ -n "$UDID" ] || UDID="$EXPECT_UDID"
        if [ -z "$UDID" ]; then
            if [ "$DRY" = 1 ]; then
                UDID="<from-device>"
            else
                die "cannot read the device UDID (hdc shell bm get -u); pass --expect-udid <UDID>"
            fi
        fi
        set -- "$@" --external --profile "$PROFILE" --key "$KEY" --key-alias "$ALIAS" --expect-udid "$UDID"
        [ -z "$CERT" ] || set -- "$@" --cert "$CERT"
    fi
    [ -z "$PWD_FILE" ] || set -- "$@" --key-pwd-file "$PWD_FILE"
    [ "$PWD_INPUT_MODE" = 1 ] && set -- "$@" --pwd-input-mode
    if [ "$DRY" = 1 ]; then
        log "[dry-run] sign: sh $SIGN_TOOL $*"
        return 0
    fi
    log "== sign ($SIGN_MODE): $(basename "$HAP") -> $(basename "$SIGNED") =="
    sh "$SIGN_TOOL" "$@" > "$OUT/sign.log" 2>&1 || die_with_log "$OUT/sign.log" "signing failed (see $OUT/sign.log)"
    [ -f "$SIGNED" ] || die "the sign script produced no hap at $SIGNED"
    log "signed hap: $SIGNED"
}

do_install() {
    "$HDC" install -r "$SIGNED" > "$OUT/install.log" 2>&1
    _rc=$?
    if [ "$_rc" -ne 0 ] || grep -qi 'fail' "$OUT/install.log"; then
        if grep -q '9568289' "$OUT/install.log"; then
            die "install refused (9568289: grant request permissions failed) - the profile did not carry READ_PASTEBOARD to the device (wrong signing domain or unapproved ACL); see $OUT/install.log"
        fi
        if grep -q '9568344' "$OUT/install.log"; then
            die "install refused (9568344: profile prop check) - profile/bundle or profile/device binding mismatch; see $OUT/install.log"
        fi
        die_with_log "$OUT/install.log" "hdc install failed (rc=$_rc); see $OUT/install.log"
    fi
    log "installed: $(tail -n 1 "$OUT/install.log" 2>/dev/null | tr -d '\r')"
}

do_bm_dump() {
    "$HDC" shell bm dump -n "$BUNDLE" > "$OUT/bm-dump.json" 2>&1 \
        || die_with_log "$OUT/bm-dump.json" "bm dump failed for $BUNDLE"
    BM_RC=0
    python3 - "$OUT/bm-dump.json" > "$OUT/bm-acl-check.txt" 2>&1 <<'PY' || BM_RC=$?
import json, sys
PERM = 'ohos.permission.READ_PASTEBOARD'
text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
i = text.find('{')
j = text.find('[')
if i < 0 and j < 0:
    print('NOJSON')
    sys.exit(2)
if i < 0 or (0 <= j < i):
    i = j
try:
    data = json.loads(text[i:])
except Exception as e:
    print('BADJSON: %s' % e)
    sys.exit(2)
acl_hits, perm_hits, ungranted = [], [], []
def walk(x, path):
    if isinstance(x, dict):
        for k, v in x.items():
            if k in ('allowed-acls', 'allowedAcls') and isinstance(v, list) and PERM in v:
                acl_hits.append(path + '/' + k)
            if k == 'name' and v == PERM:
                granted = x.get('granted')
                if granted is None:
                    granted = x.get('grantStatus')
                if granted is True:
                    perm_hits.append(path)
                else:
                    ungranted.append('%s (granted=%s)' % (path, granted))
            walk(v, path + '/' + str(k))
    elif isinstance(x, list):
        for n, v in enumerate(x):
            walk(v, path + '/' + str(n))
walk(data, '')
if acl_hits or perm_hits:
    print('FOUND acl=%s perm=%s' % (','.join(acl_hits) or '-', ','.join(perm_hits) or '-'))
    sys.exit(0)
if ungranted or PERM in text:
    print('PRESENT-BUT-NOT-GRANTED %s' % ('; '.join(ungranted) or 'text-only hit'))
    sys.exit(1)
print('ABSENT')
sys.exit(1)
PY
    if [ "$BM_RC" -ne 0 ]; then
        BM_MSG="$(cat "$OUT/bm-acl-check.txt" 2>/dev/null)"
        die "bm dump for $BUNDLE does not report READ_PASTEBOARD as an ACL/granted permission ($BM_MSG); dump kept at $OUT/bm-dump.json"
    fi
    BM_EVIDENCE="$(cat "$OUT/bm-acl-check.txt")"
    log "bm dump ACL evidence: $BM_EVIDENCE"
}

do_runtime_probe() {
    "$HDC" shell hilog -r > /dev/null 2>&1 || true
    "$HDC" shell "aa start -b $BUNDLE -a EntryAbility -U 'app://clipboard/write/$MARKER'" \
        > "$OUT/aa-write.log" 2>&1 || warn "aa start (write) returned non-zero; see $OUT/aa-write.log"
    sleep "$SLEEP"
    "$HDC" shell "aa start -b $BUNDLE -a EntryAbility -U 'app://clipboard/read'" \
        > "$OUT/aa-read.log" 2>&1 || warn "aa start (read) returned non-zero; see $OUT/aa-read.log"
    sleep "$SLEEP"
    "$HDC" shell hilog -x > "$OUT/hilog-runtime.txt" 2>&1 || die "hilog -x failed; see $OUT/hilog-runtime.txt"
    grep -F "clipboard: wrote" "$OUT/hilog-runtime.txt" | grep -F "$MARKER" > "$OUT/probe-write.txt" 2>/dev/null || true
    grep -F "clipboard: read" "$OUT/hilog-runtime.txt" > "$OUT/probe-read.txt" 2>/dev/null || true
    if grep -F "clipboard: read" "$OUT/probe-read.txt" | grep -Fq "text='$MARKER"; then
        log "runtime read OK: marker '$MARKER' came back through the host NDK read"
        return 0
    fi
    if grep -Fq "clipboard: read null" "$OUT/probe-read.txt"; then
        if grep -q 'check permission failed' "$OUT/hilog-runtime.txt"; then
            die "runtime read returned null and the service logged 'check permission failed': the ACL is not granted at runtime; evidence in $OUT/hilog-runtime.txt"
        fi
        die "runtime read returned null (ACL denied or the clipboard was empty despite the write); evidence in $OUT/hilog-runtime.txt"
    fi
    if grep -Fq "clipboard: error" "$OUT/probe-read.txt"; then
        die_with_log "$OUT/probe-read.txt" "the clipboard probe reported an error; see $OUT/hilog-runtime.txt"
    fi
    die "no [clipboard-probe] 'clipboard: read' line in the hilog window (is the installed hap the ClipboardProbe build? --build sets -p:ClipboardProbe=true); evidence in $OUT/hilog-runtime.txt"
}

# ---- main -------------------------------------------------------------------------------------
log "clipboard-acl-accept.sh: sign=$SIGN_MODE, hap=${HAP:-<build>}, marker=$MARKER"
log "evidence dir: $OUT"
acl_preflight

if [ "$DRY" = 1 ]; then
    if [ -n "$HAP" ]; then
        prepare_hap
        do_sign
    else
        log "probe hap: <publish output of the --build command> (its module.json must declare READ_PASTEBOARD; the real run verifies it)"
        log "[dry-run] sign: sh $SIGN_TOOL $SIGN_MODE <publish hap> with profile $PROFILE"
    fi
    log "[dry-run] install: $HDC install -r <signed>.hap"
    log "[dry-run] bm dump: $HDC shell bm dump -n <bundle>  -> expect READ_PASTEBOARD (ACL: $ACL_EVIDENCE)"
    log "[dry-run] runtime: hilog -r; aa start -U app://clipboard/write/$MARKER; sleep $SLEEP; aa start -U app://clipboard/read; sleep $SLEEP; hilog -x"
    log "[dry-run] report: $OUT/report.md"
    log "dry-run: nothing built, signed, installed or started"
    exit 0
fi

trap 'lock_release' 0
trap 'lock_release; exit 130' INT
trap 'lock_release; exit 143' TERM

require_device
lock_acquire
do_build
prepare_hap
if [ "$SIGN_MODE" = external ]; then
    [ -n "$EXPECT_UDID" ] || UDID="$(read_udid)"
    [ -n "$UDID" ] || [ -n "$EXPECT_UDID" ] || die "cannot read the device UDID (hdc shell bm get -u); pass --expect-udid <UDID>"
fi
do_sign
do_install
do_bm_dump
do_runtime_probe

SIGNED_SHA="$(sha256sum "$SIGNED" 2>/dev/null | cut -d' ' -f1)"
HAP_SHA="$(sha256sum "$HAP" 2>/dev/null | cut -d' ' -f1)"
{
    printf '# CLIPBOARD-ACL acceptance\n\n'
    printf -- '- date: %s\n' "$(date '+%F %T')"
    printf -- '- sign mode: %s\n' "$SIGN_MODE"
    printf -- '- bundle: %s\n' "$BUNDLE"
    printf -- '- unsigned hap: %s (%s)\n' "$HAP" "$HAP_SHA"
    printf -- '- signed hap: %s (%s)\n' "$SIGNED" "$SIGNED_SHA"
    printf -- '- profile: %s\n' "$PROFILE"
    printf -- '- ACL preflight: %s\n' "$ACL_EVIDENCE"
    printf -- '- bm dump: %s\n' "${BM_EVIDENCE:-not-run}"
    printf -- '- runtime read: PASS (marker %s)\n' "$MARKER"
    printf -- '- verdict: PASS\n'
} > "$OUT/report.md"
log "acceptance PASS (report: $OUT/report.md)"
exit 0
