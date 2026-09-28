#!/bin/sh
# selftest-devloop.sh - repeatable, fully local selftest for scripts/devloop.sh (the one-command
# incremental deploy loop that stands in for the restricted Hot Reload path). Drives devloop.sh
# end-to-end against a stub `hdc`, a stub `dotnet` and a stub sign-for-device.sh in a temp dir:
# no device, no real toolchain, no network.
# Scenarios:
#   stub contract  the three stubs themselves (list targets, install ok/fail, aa start, bm get -u,
#                  hilog stream, dotnet arg log, sign copy)
#   env hardening  lib-dotnet-env.sh: the MSBuild server/node-reuse opt-outs, TMPDIR defaulting
#                  with the preferred/.tmp fallback, the >100-char server-socket guard, caller
#                  overrides kept (a short caller TMPDIR wins; an over-limit one falls back to a
#                  shorter candidate), and the exact environment the stub dotnet receives
#   S1 usage       --help -> exit 0, usage text
#   S2 build       publish command, TFM/RID/config, -p: pass-through (values with spaces stay one
#                  argument)
#   S3 dry-run     --dry-run all --sign: plan printed, nothing executed, no password leak
#   S4 all         build -> install newest signed hap -> start (bundle from module.json) -> filtered
#                  hilog; the sign stub must not be called without --sign
#   S5 sign        --sign -> sign-for-device.sh --external args (profile/key/alias/udid/cert/pwd
#                  file), the signed hap is installed
#   S6 whitelist   a hap whose module.json bundleName carries shell metacharacters is refused
#                  before any hdc command; a --bundle payload is refused too
#   S7 install     a *fail* hap -> readable code:9568297 hint, exit 1
#   S8 logs        bounded capture keeps only FILTER_RE lines; --filter narrows; --follow streams
#   S9 watch       --watch --interval 1 reruns the chain once after a source touch
#   S10 spaces     project dir and --hap paths with spaces survive build/install
#   S11 no hdc     missing hdc -> exit 3 with a readable message; --dry-run still plans
# Stub surface: hdc (list targets | install -r <hap> | shell aa start ... | shell bm get -u |
#   shell hilog), dotnet (prints ARG| lines), sign-for-device.sh stub (copies --unsigned to --out).
# Env: SELFTEST_TMPDIR=<dir> work dir base (default: the approved opencode tmp dir),
#      SELFTEST_KEEP=1 keep the work dir even when all checks pass,
#      SELFTEST_DEVLOOP=<path> devloop.sh under test (default: next to this script).
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="3 (2026-09-28)"

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

# ---- paths ---------------------------------------------------------------------------
_self_path="$0"
case "$_self_path" in
    */*) ;;
    *) _self_path="$(command -v "$_self_path" 2>/dev/null || printf '%s' "$_self_path")" ;;
esac
SELF_DIR="$(cd "$(dirname "$_self_path")" && pwd -P)" || { printf 'FATAL: cannot resolve the selftest directory\n' >&2; exit 1; }
REPO_DIR="$(cd "$SELF_DIR/.." && pwd -P)" || REPO_DIR="$SELF_DIR"
DEVLOOP="${SELFTEST_DEVLOOP:-$SELF_DIR/devloop.sh}"
case "$DEVLOOP" in
    /*) ;;
    *) DEVLOOP="$PWD/$DEVLOOP" ;;
esac
[ -f "$DEVLOOP" ] || { printf 'FATAL: devloop.sh not found: %s\n' "$DEVLOOP" >&2; exit 1; }
for _t in sh mktemp find grep sed head cut tr sleep kill ls; do
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
case "$WORK_BASE" in
    /*) ;;
    *) WORK_BASE="$PWD/$WORK_BASE" ;;
esac
mkdir -p "$WORK_BASE" 2>/dev/null || true
WORK_BASE="$(cd "$WORK_BASE" 2>/dev/null && pwd -P)" || WORK_BASE="/tmp"
WORK="$(mktemp -d "$WORK_BASE/selftest-devloop.XXXXXX" 2>/dev/null || true)"
if [ -z "$WORK" ]; then
    WORK="$WORK_BASE/selftest-devloop.$$"
    mkdir -p "$WORK" 2>/dev/null || { printf 'FATAL: cannot create a work dir under %s\n' "$WORK_BASE" >&2; exit 1; }
fi
WORK="$(cd "$WORK" && pwd -P)" || exit 1
WORK_OWNER="$WORK/.selftest-owner"
printf '%s\n' "$$" > "$WORK_OWNER" 2>/dev/null || true

# A genuinely short scratch dir for the TMPDIR length-guard checks: the guard refuses a TMPDIR
# whose estimated MSBuild-server socket path ($TMPDIR + 58 chars) exceeds 100, and the work dir
# under the approved tmp root is already longer than that. Try a sibling of the work base
# (/data/storage/el2/base/tmp/sdt.$$ is 36 chars -> 94 estimated), then the base itself. A path
# with whitespace cannot pass through the run helper's word-split env assignment, so drop it
# there; removed in cleanup() via its owner marker (it lives outside $WORK).
SHORT_TMP=""
_short_parent="$(dirname "$WORK_BASE")"
for _short_cand in "$_short_parent/sdt.$$" "$WORK_BASE/sdt.$$"; do
    [ -d "$(dirname "$_short_cand")" ] || continue
    [ $(( ${#_short_cand} + 58 )) -le 100 ] || continue
    mkdir -p "$_short_cand" 2>/dev/null || continue
    SHORT_TMP="$(cd "$_short_cand" && pwd -P)" || continue
    break
done
case "$SHORT_TMP" in
    *[[:space:]]*) SHORT_TMP="" ;;
esac
if [ -n "$SHORT_TMP" ]; then
    printf '%s\n' "$$" > "$SHORT_TMP/.selftest-owner" 2>/dev/null || SHORT_TMP=""
fi

CHECKS=0
FAILED=0
KEEP="${SELFTEST_KEEP:-0}"
INTERRUPTED=0
WATCH_JOB=""
WATCH_STATE=""

cleanup() {
    trap - 0 1 2 15
    if [ -n "$WATCH_JOB" ]; then
        kill "$WATCH_JOB" >/dev/null 2>&1 || true
        kill -0 "$WATCH_JOB" >/dev/null 2>&1 && kill -9 "$WATCH_JOB" >/dev/null 2>&1 || true
        wait "$WATCH_JOB" >/dev/null 2>&1 || true
        WATCH_JOB=""
    fi
    if [ "$FAILED" -gt 0 ] || [ "$KEEP" = 1 ] || [ "$INTERRUPTED" = 1 ]; then
        return 0
    fi
    case "$WORK" in
        ''|/|.) return 0 ;;
    esac
    if [ -f "$WORK_OWNER" ] && [ "$(cat "$WORK_OWNER" 2>/dev/null)" = "$$" ]; then
        rm -rf "$WORK" 2>/dev/null || true
    fi
    if [ -n "$SHORT_TMP" ] && [ -f "$SHORT_TMP/.selftest-owner" ] \
        && [ "$(cat "$SHORT_TMP/.selftest-owner" 2>/dev/null)" = "$$" ]; then
        rm -rf "$SHORT_TMP" 2>/dev/null || true
    fi
}
trap cleanup 0
trap 'INTERRUPTED=1; exit 1' 1 2 15

CWD="$WORK/cwd"
TMPD="$WORK/tmp"
LOGS="$WORK/logs"
STATE_DIR="$WORK/state"
PROJ="$WORK/proj/hello-maui-app"
OUT="$PROJ/bin/Release/net11.0-openharmony26.0/openharmony-arm64"
HAPS_EXTRA="$WORK/haps"
SECRET="SEKRIT-must-never-be-logged"
ensure_dirs() {
    mkdir -p "$CWD" "$TMPD" "$LOGS" "$STATE_DIR" "$WORK/bin" "$OUT" "$HAPS_EXTRA" 2>/dev/null || true
}
ensure_dirs

# ---- check helpers -------------------------------------------------------------------
ok()   { CHECKS=$((CHECKS + 1)); printf '  [PASS] %s\n' "$1"; }
bad()  { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$1"; }
skip() { printf '  [SKIP] %s\n' "$1"; }
assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
assert_file() {
    if [ -f "$2" ]; then ok "$1"; else bad "$1 (missing file: ${2:-<empty>})"; fi
}
assert_not_exists() {
    if [ ! -e "$2" ]; then ok "$1"; else bad "$1 (unexpected path: $2)"; fi
}
assert_contains() {
    if [ -f "$3" ] && grep -Fq -- "$2" "$3"; then ok "$1"
    else bad "$1 (missing '$2' in ${3:-<empty>})"; fi
}
assert_not_contains() {
    if [ -f "$3" ] && ! grep -Fq -- "$2" "$3"; then ok "$1"
    else bad "$1 (unexpected '$2' in ${3:-<empty>})"; fi
}
assert_matches() {
    if [ -f "$3" ] && grep -Eq -- "$2" "$3"; then ok "$1"
    else bad "$1 (no match for '$2' in ${3:-<empty>})"; fi
}
assert_gt() {
    case "$3" in
        ''|*[!0-9]*) bad "$1 (not a number: '$3')" ;;
        *) if [ "$3" -gt "$2" ]; then ok "$1"; else bad "$1 (got $3, want > $2)"; fi ;;
    esac
}

# ---- hap fixture ---------------------------------------------------------------------
HAVE_ZIPTOOL=0
if command -v python3 >/dev/null 2>&1; then HAVE_ZIPTOOL=1; fi
if [ "$HAVE_ZIPTOOL" != 1 ] && command -v zip >/dev/null 2>&1; then HAVE_ZIPTOOL=2; fi

# make_hap <dst> <bundle> [module-name]
make_hap() {
    _mh_dst="$1"; _mh_bundle="$2"; _mh_name="${3:-entry}"
    if [ "$HAVE_ZIPTOOL" = 1 ]; then
        python3 - "$_mh_dst" "$_mh_bundle" "$_mh_name" <<'PY'
import json, os, sys, tempfile, zipfile
dst, bundle, name = sys.argv[1], sys.argv[2], sys.argv[3]
mod = {"app": {"bundleName": bundle, "versionName": "1.0.0-selftest",
               "minAPIVersion": 60001021, "targetAPIVersion": 60101024, "apiReleaseType": "Beta1"},
       "module": {"name": name, "type": "entry", "mainElement": "EntryAbility"}}
with tempfile.TemporaryDirectory() as d:
    path = os.path.join(d, "module.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(mod, handle)
    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(path, "module.json")
PY
    elif [ "$HAVE_ZIPTOOL" = 2 ]; then
        _mh_tmp="$(mktemp -d "$TMPD/mkhap.XXXXXX")"
        printf '{"app":{"bundleName":"%s"},"module":{"name":"%s","type":"entry"}}' "$_mh_bundle" "$_mh_name" > "$_mh_tmp/module.json"
        ( cd "$_mh_tmp" && zip -q "$_mh_dst" module.json )
        rm -rf "$_mh_tmp"
    else
        printf 'flat selftest hap (no python3/zip): %s\n' "$_mh_bundle" > "$_mh_dst"
    fi
}

# ---- stubs ---------------------------------------------------------------------------
STUB="$WORK/bin/hdc"
STUB_DOTNET="$WORK/bin/dotnet"
SIGN_STUB="$WORK/bin/sign-for-device-stub.sh"
STUB_DEVICE="FAKE-DEVICE-1"
FAKE_UDID="0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"

cat > "$STUB" <<'STUB_HDC_EOF'
#!/bin/sh
# Stub hdc for selftest-devloop.sh. Simulates one OpenHarmony device. Not a real tool.
set -u
STATE="${FAKE_HDC_STATE:?FAKE_HDC_STATE not set}"
mkdir -p "$STATE"
printf '%s\n' "$*" >> "$STATE/calls.log"
DEVICE="${FAKE_HDC_DEVICE:-FAKE-DEVICE-1}"
if [ "${1:-}" = "-t" ] && [ $# -ge 2 ]; then
    shift 2
fi
case "${1:-}" in
    list)
        if [ "${2:-}" = targets ]; then printf '%s\n' "$DEVICE"; exit 0; fi
        printf 'stub hdc: UNHANDLED list %s\n' "$*" >&2; exit 1 ;;
    install)
        _hap=""
        for _a in "$@"; do
            case "$_a" in -*) ;; *) _hap="$_a" ;; esac
        done
        case "$(basename "$_hap")" in
            *fail*)
                printf '[Error]Install failed due to error: code:9568297 device apiCompatibleVersion less than minAPIVersion\n' >&2
                exit 1 ;;
            *)
                printf 'install bundle successfully.\n'; exit 0 ;;
        esac ;;
    shell)
        shift
        _cmd="$*"
        printf '%s\n' "$_cmd" >> "$STATE/device-shell.log"
        case "$_cmd" in
            *"aa start"*)
                printf 'start ability successfully.\n'; exit 0 ;;
            *"bm get -u"*)
                printf 'UDID: %s\n' "${FAKE_HDC_UDID:?}"; exit 0 ;;
            *"hilog"*)
                cat <<'HILOG_EOF'
09-27 10:00:00.000 1 1 I A00000/com.example.hellomauiapp/MainAbility: [maui] managed host started
09-27 10:00:00.100 1 1 I A00000/com.example.hellomauiapp/MainAbility: appLibPathKey: com.example.hellomauiapp/entry
09-27 10:00:00.200 1 1 I A00000/com.example.other/MainAbility: [noise] unrelated device chatter
09-27 10:00:00.300 1 1 E A00000/com.example.hellomauiapp/MainAbility: JsError: boom
HILOG_EOF
                exit 0 ;;
        esac
        printf 'stub hdc: UNHANDLED shell %s\n' "$*" >&2; exit 1 ;;
esac
printf 'stub hdc: UNHANDLED %s\n' "$*" >&2
exit 1
STUB_HDC_EOF
chmod +x "$STUB"

cat > "$STUB_DOTNET" <<'STUB_DOTNET_EOF'
#!/bin/sh
# Stub dotnet for selftest-devloop.sh: records every argument (one per line) and succeeds.
# A "FAILBUILD" argument makes it fail (exit 1) so the build-failure path stays covered.
set -u
STATE="${FAKE_DOTNET_STATE:?FAKE_DOTNET_STATE not set}"
mkdir -p "$STATE"
printf 'CALL|%s\n' "$*" >> "$STATE/dotnet.log"
# ENV| lines pin the environment a real dotnet would inherit from the hardened launcher;
# <unset> is recorded verbatim when a variable is missing (see the "env hardening" section).
printf 'ENV|TMPDIR|%s\n' "${TMPDIR:-<unset>}" >> "$STATE/dotnet.log"
printf 'ENV|TMP|%s\n' "${TMP:-<unset>}" >> "$STATE/dotnet.log"
printf 'ENV|TEMP|%s\n' "${TEMP:-<unset>}" >> "$STATE/dotnet.log"
printf 'ENV|DOTNET_CLI_USE_MSBUILD_SERVER|%s\n' "${DOTNET_CLI_USE_MSBUILD_SERVER:-<unset>}" >> "$STATE/dotnet.log"
printf 'ENV|DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER|%s\n' "${DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER:-<unset>}" >> "$STATE/dotnet.log"
printf 'ENV|MSBUILDDISABLENODEREUSE|%s\n' "${MSBUILDDISABLENODEREUSE:-<unset>}" >> "$STATE/dotnet.log"
printf 'ENV|DOTNET_CLI_TELEMETRY_OPTOUT|%s\n' "${DOTNET_CLI_TELEMETRY_OPTOUT:-<unset>}" >> "$STATE/dotnet.log"
printf 'ENV|DOTNET_NOLOGO|%s\n' "${DOTNET_NOLOGO:-<unset>}" >> "$STATE/dotnet.log"
for _a in "$@"; do
    printf 'ARG|%s\n' "$_a" >> "$STATE/dotnet.log"
    [ "$_a" = "FAILBUILD" ] && exit 1
done
exit 0
STUB_DOTNET_EOF
chmod +x "$STUB_DOTNET"

cat > "$SIGN_STUB" <<'SIGN_STUB_EOF'
#!/bin/sh
# Stub sign-for-device.sh for selftest-devloop.sh: records the --external argv and copies
# --unsigned to --out (a real signer would produce a signed hap there). A profile path naming
# "fail" makes it fail. Never reads --key-pwd-file (the selftest asserts the password is not
# passed by value anywhere).
set -u
STATE="${FAKE_HDC_STATE:?FAKE_HDC_STATE not set}"
mkdir -p "$STATE"
printf '%s\n' "$*" >> "$STATE/sign.log"
_prev=""; _in=""; _out=""; _profile=""
for _a in "$@"; do
    [ "$_prev" = "--unsigned" ] && _in="$_a"
    [ "$_prev" = "--out" ] && _out="$_a"
    [ "$_prev" = "--profile" ] && _profile="$_a"
    _prev="$_a"
done
case "$_profile" in *fail*) printf 'stub sign-for-device: profile failure\n' >&2; exit 1 ;; esac
[ -n "$_in" ] && [ -n "$_out" ] || { printf 'stub sign-for-device: missing --unsigned/--out\n' >&2; exit 1; }
cp "$_in" "$_out" || exit 1
exit 0
SIGN_STUB_EOF
chmod +x "$SIGN_STUB"

# ---- fixtures ------------------------------------------------------------------------
# When the host can make a real zip (python3/zip), module.json inside the hap drives the start
# bundle name. Without one, every run that starts the app passes --bundle explicitly.
BUNDLE_FALLBACK=""
[ "$HAVE_ZIPTOOL" = 0 ] && BUNDLE_FALLBACK="--bundle com.example.hellomauiapp"
printf 'class App { }\n' > "$PROJ/App.cs"
mkdir -p "$PROJ/obj/Release"
printf 'build junk that must not retrigger watch\n' > "$PROJ/obj/Release/junk.txt"
make_hap "$OUT/hello-maui-app.hap" "com.example.hellomauiapp"
make_hap "$OUT/hello-maui-app-unsigned.hap" "com.example.hellomauiapp"
make_hap "$HAPS_EXTRA/evil.hap" "com.example.bad;rm -rf /"
make_hap "$HAPS_EXTRA/hello-maui-app-fail.hap" "com.example.hellomauiapp"
printf '%s\n' "$SECRET" > "$WORK/pwd.txt"
printf 'dummy profile\n' > "$WORK/dev.p7b"
printf 'dummy keystore\n' > "$WORK/dev.p12"
printf 'dummy chain\n' > "$WORK/dev.cer"

# ---- run helper ----------------------------------------------------------------------
RC=0
run_devloop() {
    _tag="$1"; _extra="$2"; shift 2
    ensure_dirs
    _log="$LOGS/$_tag.log"
    RC=0
    # $_extra is intentionally unquoted: it carries zero or more `VAR=value` assignments.
    # TMP/TEMP are passed empty so the lib has to default them to the caller's TMPDIR (the
    # assertion that it does is part of S2), independent of the developer's own environment.
    ( cd "$CWD" && exec env TMP= TEMP= TMPDIR="$TMPD" PATH="$WORK/bin:$PATH" \
        HDC="$STUB" DOTNET="$STUB_DOTNET" DEVLOOP_SIGN_TOOL="$SIGN_STUB" \
        FAKE_HDC_STATE="$STATE_DIR/$_tag" FAKE_DOTNET_STATE="$STATE_DIR/$_tag" \
        FAKE_HDC_UDID="$FAKE_UDID" $_extra sh "$DEVLOOP" "$@" ) > "$_log" 2>&1
    RC=$?
    return 0
}

state_file() { printf '%s/%s' "$STATE_DIR/$1" "$2"; }

count_lines() {
    if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else printf '0'; fi
}

# wait_lines <file> <grep-pattern> <min> <ticks>; 0 when the count reaches min.
wait_lines() {
    _wl_file="$1"; _wl_pat="$2"; _wl_min="$3"; _wl_ticks="$4"
    _wl_i=0
    while [ "$_wl_i" -lt "$_wl_ticks" ]; do
        _wl_n="$(grep -c -E -e "$_wl_pat" "$_wl_file" 2>/dev/null || true)"
        case "$_wl_n" in ''|*[!0-9]*) _wl_n=0 ;; esac
        if [ "$_wl_n" -ge "$_wl_min" ]; then return 0; fi
        sleep 0.5
        _wl_i=$((_wl_i + 1))
    done
    return 1
}

# ---- environment ---------------------------------------------------------------------
section "environment (selftest $SELFTEST_VERSION)"
log "devloop: $DEVLOOP"
log "work   : $WORK"
[ -z "$SHORT_TMP" ] || log "short  : $SHORT_TMP (TMPDIR length-guard scratch)"
log "stub   : $STUB / $STUB_DOTNET / $SIGN_STUB"
log "ziptool: $HAVE_ZIPTOOL (1=python3 2=zip 0=none)"

if sh -n "$DEVLOOP" 2> "$LOGS/devloop-syntax.log"; then
    ok "devloop.sh passes sh -n"
else
    bad "devloop.sh fails sh -n (see $LOGS/devloop-syntax.log)"
fi
if sh -n "$SELF_DIR/selftest-devloop.sh" 2> "$LOGS/selftest-syntax.log"; then
    ok "selftest-devloop.sh passes sh -n"
else
    bad "selftest-devloop.sh fails sh -n"
fi

GIT_OK=0
GIT_BEFORE=""
if command -v git >/dev/null 2>&1 && git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    GIT_OK=1
    # Only this feature's files: the repository may carry other work-in-progress branches from
    # concurrent work, which must not fail the selftest.
    GIT_BEFORE="$(git -C "$REPO_DIR" status --porcelain 2>/dev/null | grep -E -e 'scripts/devloop\.sh' -e 'scripts/selftest-devloop\.sh' -e 'scripts/lib-dotnet-env\.sh' || true)"
fi

# ---- stub contract -------------------------------------------------------------------
section "stub contract"
FAKE_HDC_STATE="$STATE_DIR/contract" "$STUB" list targets > "$LOGS/stub-list.out" 2>&1 || true
assert_contains "stub: lists one device" "$STUB_DEVICE" "$LOGS/stub-list.out"
FAKE_HDC_STATE="$STATE_DIR/contract" FAKE_HDC_UDID="$FAKE_UDID" "$STUB" -t "$STUB_DEVICE" shell bm get -u > "$LOGS/stub-udid.out" 2>&1 || true
assert_contains "stub: bm get -u answers a UDID" "$FAKE_UDID" "$LOGS/stub-udid.out"
( FAKE_HDC_STATE="$STATE_DIR/contract" "$SIGN_STUB" --external --profile "$WORK/dev.p7b" \
    --key "$WORK/dev.p12" --key-alias k0 --expect-udid "$FAKE_UDID" \
    --unsigned "$OUT/hello-maui-app-unsigned.hap" --out "$WORK/sign-contract.hap" ) > "$LOGS/stub-sign.log" 2>&1 || true
assert_eq "stub: sign stub copies the input to --out" "equal" "$(cmp -s "$OUT/hello-maui-app-unsigned.hap" "$WORK/sign-contract.hap" && printf 'equal' || printf 'differ')"

# ---- env hardening: lib-dotnet-env.sh -------------------------------------------------
section "env hardening (lib-dotnet-env.sh)"
LIB_DOTNET_ENV="$SELF_DIR/lib-dotnet-env.sh"
ENV_WORK="$WORK/env"
FAKE_ENV_REPO="$WORK/fake-repo"
mkdir -p "$ENV_WORK" "$FAKE_ENV_REPO" 2>/dev/null || true
if [ ! -f "$LIB_DOTNET_ENV" ]; then
    bad "lib-dotnet-env.sh exists next to devloop.sh"
else
    ok "lib-dotnet-env.sh exists next to devloop.sh"
    cat > "$WORK/lib-probe.sh" <<'LIB_PROBE_EOF'
#!/bin/sh
# Probe for the env hardening checks: source the lib exactly like the scripts do and print the
# environment a dotnet child would inherit; DIRY reports whether DOTNET_ENV_TMPDIR exists.
. "$2" "$1"
printf 'TMPDIR=%s TMP=%s TEMP=%s SERVER=%s NOSERVER=%s NODEREUSE=%s TELE=%s LOGO=%s DIRY=%s\n' \
    "$TMPDIR" "$TMP" "$TEMP" \
    "$DOTNET_CLI_USE_MSBUILD_SERVER" "$DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER" \
    "$MSBUILDDISABLENODEREUSE" "$DOTNET_CLI_TELEMETRY_OPTOUT" "$DOTNET_NOLOGO" \
    "$([ -d "${DOTNET_ENV_TMPDIR:-.}" ] && printf yes || printf no)"
LIB_PROBE_EOF
    # run_lib_probe <tag> <repo-root> [VAR=value ...]: a clean env (only PATH) so the lib's
    # defaults are visible, plus the requested overrides. The environment line goes to .env
    # (exact-match assertions); lib warnings (stderr) to .err, so a warned run still yields the
    # same single-line .env.
    run_lib_probe() {
        _lb_tag="$1"; _lb_repo="$2"; shift 2
        ( cd "$CWD" && exec env -i PATH="$PATH" "$@" sh "$WORK/lib-probe.sh" "$_lb_repo" "$LIB_DOTNET_ENV" ) \
            > "$LOGS/lib-$_lb_tag.env" 2> "$LOGS/lib-$_lb_tag.err"
    }
    run_lib_probe defaults "$FAKE_ENV_REPO" DOTNET_ENV_TMPDIR="$ENV_WORK/default" TMPDIR="" TMP="" TEMP=""
    assert_eq "hardening defaults: server/node reuse/telemetry/logo off, TMPDIR defaulted" \
        "TMPDIR=$ENV_WORK/default TMP=$ENV_WORK/default TEMP=$ENV_WORK/default SERVER=0 NOSERVER=1 NODEREUSE=1 TELE=1 LOGO=1 DIRY=yes" \
        "$(cat "$LOGS/lib-defaults.env")"
    assert_eq "hardening defaults: the preferred TMPDIR is created" "yes" \
        "$([ -d "$ENV_WORK/default" ] && printf yes || printf no)"
    mkdir -p "$ENV_WORK/override"
    run_lib_probe override "$FAKE_ENV_REPO" DOTNET_ENV_TMPDIR="$ENV_WORK/other" TMPDIR="$ENV_WORK/override" \
        TMP="" TEMP="" DOTNET_NOLOGO=0 DOTNET_CLI_USE_MSBUILD_SERVER=1
    assert_eq "hardening overrides: caller TMPDIR and switches win" \
        "TMPDIR=$ENV_WORK/override TMP=$ENV_WORK/override TEMP=$ENV_WORK/override SERVER=1 NOSERVER=1 NODEREUSE=1 TELE=1 LOGO=0 DIRY=no" \
        "$(cat "$LOGS/lib-override.env")"
    : > "$ENV_WORK/not-a-dir"
    run_lib_probe fallback "$FAKE_ENV_REPO" DOTNET_ENV_TMPDIR="$ENV_WORK/fallback" TMPDIR="$ENV_WORK/not-a-dir" TMP="" TEMP=""
    assert_eq "hardening fallback: an unusable TMPDIR falls back to the preferred dir" \
        "TMPDIR=$ENV_WORK/fallback TMP=$ENV_WORK/fallback TEMP=$ENV_WORK/fallback SERVER=0 NOSERVER=1 NODEREUSE=1 TELE=1 LOGO=1 DIRY=yes" \
        "$(cat "$LOGS/lib-fallback.env")"
    REPO_TMP_PROBE="$WORK/repo-tmp-probe"
    mkdir -p "$REPO_TMP_PROBE"
    run_lib_probe repo-tmp "$REPO_TMP_PROBE" DOTNET_ENV_TMPDIR="$ENV_WORK/not-a-dir" TMPDIR="" TMP="" TEMP=""
    assert_eq "hardening fallback: the last resort is <repo>/.tmp" \
        "TMPDIR=$REPO_TMP_PROBE/.tmp TMP=$REPO_TMP_PROBE/.tmp TEMP=$REPO_TMP_PROBE/.tmp SERVER=0 NOSERVER=1 NODEREUSE=1 TELE=1 LOGO=1 DIRY=no" \
        "$(cat "$LOGS/lib-repo-tmp.env")"
    assert_eq "hardening fallback: <repo>/.tmp carries its own .gitignore" "*" \
        "$(cat "$REPO_TMP_PROBE/.tmp/.gitignore" 2>/dev/null || true)"
    assert_contains "lib: the built-in TMPDIR default is the short path" \
        '_ODE_DEFAULT_TMP=/data/storage/el2/base/tmp/opencode/t' "$LIB_DOTNET_ENV"

    if [ -n "$SHORT_TMP" ]; then
        # G1: an over-limit caller TMPDIR loses to a usable short DOTNET_ENV_TMPDIR, and the
        # warning names both the refused path and its estimated socket length.
        run_lib_probe guard-fallback "$FAKE_ENV_REPO" DOTNET_ENV_TMPDIR="$SHORT_TMP" \
            TMPDIR="$ENV_WORK/guard-long" TMP="" TEMP=""
        assert_eq "guard: an over-limit caller TMPDIR falls back to the short DOTNET_ENV_TMPDIR" \
            "TMPDIR=$SHORT_TMP TMP=$SHORT_TMP TEMP=$SHORT_TMP SERVER=0 NOSERVER=1 NODEREUSE=1 TELE=1 LOGO=1 DIRY=yes" \
            "$(cat "$LOGS/lib-guard-fallback.env")"
        assert_contains "guard: the warning names the refused TMPDIR and its estimate" \
            "too long for the MSBuild server socket" "$LOGS/lib-guard-fallback.err"
        assert_contains "guard: the warning names the chosen short dir" \
            "using '$SHORT_TMP' instead" "$LOGS/lib-guard-fallback.err"

        # G2: with no usable short candidate the highest-priority one is kept (warned, not
        # dropped: a too-long TMPDIR still beats none).
        : > "$ENV_WORK/not-a-dir-2"
        run_lib_probe guard-keep "$FAKE_ENV_REPO" DOTNET_ENV_TMPDIR="$ENV_WORK/not-a-dir-2" \
            TMPDIR="$ENV_WORK/guard-keep" TMP="" TEMP=""
        assert_eq "guard: with no short candidate the caller TMPDIR is kept" \
            "TMPDIR=$ENV_WORK/guard-keep TMP=$ENV_WORK/guard-keep TEMP=$ENV_WORK/guard-keep SERVER=0 NOSERVER=1 NODEREUSE=1 TELE=1 LOGO=1 DIRY=no" \
            "$(cat "$LOGS/lib-guard-keep.env")"
        assert_contains "guard: the kept over-limit dir is reported" \
            "no usable scratch dir stays under" "$LOGS/lib-guard-keep.err"
    else
        skip "lib TMPDIR length-guard checks (no short scratch base on this host)"
    fi
fi

# ---- S1 usage ------------------------------------------------------------------------
section "S1 --help"
run_devloop S1 "" --help
assert_eq "S1 exit code 0 (log: $LOGS/S1.log)" "0" "$RC"
assert_contains "S1 prints the usage header" "用法: sh devloop.sh" "$LOGS/S1.log"
assert_contains "S1 documents the sign material" "--sign-profile" "$LOGS/S1.log"

# ---- S2 build ------------------------------------------------------------------------
section "S2 build (publish + -p: pass-through)"
# The work tmp dir is over the guard's soft limit. With a short DOTNET_ENV_TMPDIR the caller
# TMPDIR is refused and the short dir is what dotnet sees; without a short scratch base the
# last-resort rule keeps the caller TMPDIR (host-dependent), so those checks are skipped.
S2_TMP_ENV=""
if [ -n "$SHORT_TMP" ]; then S2_TMP_ENV="DOTNET_ENV_TMPDIR=$SHORT_TMP"; fi
run_devloop S2 "$S2_TMP_ENV" build --project "$PROJ" -p:Foo=bar --property "MyProp=a b"
assert_eq "S2 exit code 0 (log: $LOGS/S2.log)" "0" "$RC"
D2="$(state_file S2 dotnet.log)"
assert_file "S2 dotnet stub called" "$D2"
assert_contains "S2 publishes the project" "ARG|publish" "$D2"
assert_contains "S2 uses the project dir" "ARG|$PROJ" "$D2"
assert_contains "S2 uses -f net11.0-openharmony26.0" "ARG|-f" "$D2"
assert_contains "S2 uses the 26.0 TFM value" "ARG|net11.0-openharmony26.0" "$D2"
assert_contains "S2 uses -r openharmony-arm64" "ARG|-r" "$D2"
assert_contains "S2 uses -c Release" "ARG|-c" "$D2"
assert_contains "S2 passes -p:Foo=bar verbatim" "ARG|-p:Foo=bar" "$D2"
assert_contains "S2 passes --property as -p: with the space kept" "ARG|-p:MyProp=a b" "$D2"
assert_eq "S2 build does not touch hdc" "no-call" "$([ ! -f "$(state_file S2 calls.log)" ] && printf 'no-call' || printf 'called')"
assert_contains "S2 disables the MSBuild server (the switch this SDK reads)" "ENV|DOTNET_CLI_USE_MSBUILD_SERVER|0" "$D2"
assert_contains "S2 sets the documented MSBuild server opt-out" "ENV|DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER|1" "$D2"
assert_contains "S2 disables MSBuild node reuse" "ENV|MSBUILDDISABLENODEREUSE|1" "$D2"
assert_contains "S2 opts out of telemetry" "ENV|DOTNET_CLI_TELEMETRY_OPTOUT|1" "$D2"
assert_contains "S2 sets DOTNET_NOLOGO" "ENV|DOTNET_NOLOGO|1" "$D2"
if [ -n "$SHORT_TMP" ]; then
    assert_contains "S2 refuses the over-limit caller TMPDIR" \
        "too long for the MSBuild server socket" "$LOGS/S2.log"
    assert_contains "S2 falls back to the short TMPDIR" "ENV|TMPDIR|$SHORT_TMP" "$D2"
    assert_contains "S2 defaults TMP to the short dir" "ENV|TMP|$SHORT_TMP" "$D2"
    assert_contains "S2 defaults TEMP to the short dir" "ENV|TEMP|$SHORT_TMP" "$D2"
    assert_not_contains "S2 does not hand the over-limit TMPDIR to dotnet" "ENV|TMPDIR|$TMPD" "$D2"
else
    skip "S2 TMPDIR guard checks (no short scratch base on this host)"
fi

# ---- S3 dry-run ----------------------------------------------------------------------
section "S3 --dry-run (plan only, no execution, no password leak)"
run_devloop S3 "" --dry-run all --project "$PROJ" --log-seconds 1 \
    --sign --sign-profile "$WORK/dev.p7b" --sign-key "$WORK/dev.p12" --sign-alias k0 \
    --sign-cert "$WORK/dev.cer" --sign-pwd-file "$WORK/pwd.txt" --expect-udid ABCDEF0123456789
assert_eq "S3 exit code 0 (log: $LOGS/S3.log)" "0" "$RC"
assert_contains "S3 plan shows the publish command" "dotnet publish" "$LOGS/S3.log"
assert_contains "S3 plan shows install" "install -r" "$LOGS/S3.log"
assert_contains "S3 plan shows the start" "aa start -a EntryAbility -b" "$LOGS/S3.log"
assert_contains "S3 plan shows the hilog filter" "grep -E" "$LOGS/S3.log"
assert_contains "S3 plan shows the sign stub invocation" "--profile" "$LOGS/S3.log"
assert_contains "S3 plan shows the pwd file path (not its content)" "--key-pwd-file" "$LOGS/S3.log"
assert_not_contains "S3 never prints the password" "$SECRET" "$LOGS/S3.log"
assert_not_exists "S3 dry-run runs no dotnet" "$(state_file S3 dotnet.log)"
assert_not_exists "S3 dry-run runs no hdc" "$(state_file S3 calls.log)"
assert_not_exists "S3 dry-run runs no signer" "$(state_file S3 sign.log)"

# ---- S4 all (no sign) ----------------------------------------------------------------
section "S4 all without --sign (build -> install -> start -> logs)"
run_devloop S4 "" all --project "$PROJ" --log-seconds 1 $BUNDLE_FALLBACK
assert_eq "S4 exit code 0 (log: $LOGS/S4.log)" "0" "$RC"
C4="$(state_file S4 calls.log)"
D4="$(state_file S4 dotnet.log)"
assert_contains "S4 builds first" "ARG|publish" "$D4"
assert_contains "S4 installs the newest signed hap" "install -r $OUT/hello-maui-app.hap" "$C4"
if [ "$HAVE_ZIPTOOL" = 0 ]; then
    skip "S4 bundle from module.json (no python3/zip on this host)"
else
    assert_contains "S4 starts the bundle from module.json" "shell aa start -a EntryAbility -b com.example.hellomauiapp" "$C4"
fi
assert_contains "S4 streams hilog" "shell hilog" "$C4"
assert_not_exists "S4 sign stub not called without --sign" "$(state_file S4 sign.log)"
assert_contains "S4 keeps the filtered line" "[maui] managed host started" "$LOGS/S4.log"
assert_contains "S4 keeps the JsError line" "JsError" "$LOGS/S4.log"
assert_not_contains "S4 drops the noise line" "unrelated device chatter" "$LOGS/S4.log"
assert_not_contains "S4 no unhandled stub subcommand" "UNHANDLED" "$C4"

# ---- S5 all with --sign --------------------------------------------------------------
section "S5 all with --sign (external signer args + signed hap installed)"
run_devloop S5 "" all --project "$PROJ" --log-seconds 1 $BUNDLE_FALLBACK \
    --sign --sign-profile "$WORK/dev.p7b" --sign-key "$WORK/dev.p12" --sign-alias k0 \
    --sign-cert "$WORK/dev.cer" --sign-pwd-file "$WORK/pwd.txt" --expect-udid ABCDEF0123456789
assert_eq "S5 exit code 0 (log: $LOGS/S5.log)" "0" "$RC"
G5="$(state_file S5 sign.log)"
C5="$(state_file S5 calls.log)"
assert_file "S5 signer called" "$G5"
assert_contains "S5 signer uses --external" "--external" "$G5"
assert_contains "S5 signer gets the profile" "--profile $WORK/dev.p7b" "$G5"
assert_contains "S5 signer gets the keystore" "--key $WORK/dev.p12" "$G5"
assert_contains "S5 signer gets the alias" "--key-alias k0" "$G5"
assert_contains "S5 signer gets the UDID" "--expect-udid ABCDEF0123456789" "$G5"
assert_contains "S5 signer gets the cert chain" "--cert $WORK/dev.cer" "$G5"
assert_contains "S5 signer gets the pwd file (path only)" "--key-pwd-file $WORK/pwd.txt" "$G5"
assert_contains "S5 signer input is the unsigned hap" "--unsigned $OUT/hello-maui-app-unsigned.hap" "$G5"
assert_contains "S5 signer output uses the udid8 suffix" "--out $OUT/hello-maui-app-ABCDEF01.hap" "$G5"
assert_contains "S5 installs the signed hap" "install -r $OUT/hello-maui-app-ABCDEF01.hap" "$C5"
assert_not_contains "S5 never prints the password" "$SECRET" "$LOGS/S5.log"

# ---- S6 bundle-name whitelist --------------------------------------------------------
section "S6 bundleName whitelist (malicious hap + --bundle payload)"
run_devloop S6a "" start --project "$PROJ" --hap "$HAPS_EXTRA/evil.hap"
assert_eq "S6a malicious module.json bundleName -> exit 1 (log: $LOGS/S6a.log)" "1" "$RC"
assert_contains "S6a refusal mentions the whitelist" "白名单校验" "$LOGS/S6a.log"
assert_not_exists "S6a no hdc shell reached the device" "$(state_file S6a device-shell.log)"
run_devloop S6b "" start --project "$PROJ" --bundle 'com.example.bad;rm -rf /'
assert_eq "S6b malicious --bundle -> exit 1 (log: $LOGS/S6b.log)" "1" "$RC"
assert_contains "S6b refusal mentions the whitelist" "白名单校验" "$LOGS/S6b.log"
assert_not_exists "S6b no hdc shell reached the device" "$(state_file S6b device-shell.log)"

# ---- S7 install failure --------------------------------------------------------------
section "S7 install failure (readable error)"
run_devloop S7 "" install --project "$PROJ" --hap "$HAPS_EXTRA/hello-maui-app-fail.hap"
assert_eq "S7 exit code 1 (log: $LOGS/S7.log)" "1" "$RC"
assert_contains "S7 names the code" "code:9568297" "$LOGS/S7.log"
assert_contains "S7 explains the API band fix" "minAPIVersion" "$LOGS/S7.log"

# ---- S8 logs -------------------------------------------------------------------------
section "S8 logs (default filter, --filter, --follow)"
run_devloop S8a "" logs --project "$PROJ" --log-seconds 1
assert_eq "S8a exit code 0 (log: $LOGS/S8a.log)" "0" "$RC"
assert_contains "S8a keeps a dotnet line" "appLibPathKey" "$LOGS/S8a.log"
assert_not_contains "S8a drops noise" "unrelated device chatter" "$LOGS/S8a.log"
run_devloop S8b "" logs --project "$PROJ" --filter 'JsError'
assert_eq "S8b exit code 0 (log: $LOGS/S8b.log)" "0" "$RC"
assert_contains "S8b custom filter keeps its line" "JsError" "$LOGS/S8b.log"
assert_not_contains "S8b custom filter drops everything else" "[maui]" "$LOGS/S8b.log"
run_devloop S8c "" logs --project "$PROJ" --follow
assert_eq "S8c --follow exit code 0 (log: $LOGS/S8c.log)" "0" "$RC"
assert_contains "S8c follow streams the filter" "[maui]" "$LOGS/S8c.log"

# ---- S9 watch ------------------------------------------------------------------------
section "S9 --watch (one change -> one rerun)"
rm -rf "$STATE_DIR/S9"
: > "$LOGS/S9.log"
( cd "$CWD" && exec env TMPDIR="$TMPD" PATH="$WORK/bin:$PATH" HDC="$STUB" DOTNET="$STUB_DOTNET" \
    DEVLOOP_SIGN_TOOL="$SIGN_STUB" FAKE_HDC_STATE="$STATE_DIR/S9" FAKE_DOTNET_STATE="$STATE_DIR/S9" \
    FAKE_HDC_UDID="$FAKE_UDID" sh "$DEVLOOP" --watch --interval 1 all --project "$PROJ" --log-seconds 1 $BUNDLE_FALLBACK ) \
    >> "$LOGS/S9.log" 2>&1 &
WATCH_JOB=$!
if wait_lines "$(state_file S9 dotnet.log)" '^CALL[|]publish' 1 40; then
    ok "S9 first round ran (publish seen)"
else
    bad "S9 first round did not run (see $LOGS/S9.log)"
fi
printf 'class App { /* touched for watch */ }\n' >> "$PROJ/App.cs"
if wait_lines "$(state_file S9 dotnet.log)" '^CALL[|]publish' 2 60; then
    ok "S9 change retriggered the chain (second publish)"
else
    bad "S9 change did not retrigger (see $LOGS/S9.log)"
fi
kill "$WATCH_JOB" >/dev/null 2>&1 || true
kill -0 "$WATCH_JOB" >/dev/null 2>&1 && kill -9 "$WATCH_JOB" >/dev/null 2>&1 || true
wait "$WATCH_JOB" >/dev/null 2>&1 || true
WATCH_JOB=""
assert_contains "S9 watch log reports the change" "检测到变更: App.cs" "$LOGS/S9.log"
assert_contains "S9 watch reran install" "install -r $OUT/" "$(state_file S9 calls.log)"
assert_not_contains "S9 obj/ output did not retrigger (no infinite loop)" "检测到变更: obj/" "$LOGS/S9.log"

# ---- S10 paths with spaces -----------------------------------------------------------
section "S10 paths with spaces"
SPACED="$WORK/my project/hello-maui-app"
SPACED_OUT="$SPACED/bin/Release/net11.0-openharmony26.0/openharmony-arm64"
mkdir -p "$SPACED_OUT" 2>/dev/null || true
printf 'class App { }\n' > "$SPACED/App.cs"
make_hap "$SPACED_OUT/hello-maui-app.hap" "com.example.hellomauiapp"
run_devloop S10 "" build --project "$SPACED"
assert_eq "S10 build exit code 0 (log: $LOGS/S10.log)" "0" "$RC"
assert_contains "S10 publish got the spaced project path as one argument" "ARG|$SPACED" "$(state_file S10 dotnet.log)"
run_devloop S10b "" install --project "$SPACED" --hap "$SPACED_OUT/hello-maui-app.hap"
assert_eq "S10b install exit code 0 (log: $LOGS/S10b.log)" "0" "$RC"
assert_contains "S10b install got the spaced hap path" "install -r $SPACED_OUT/hello-maui-app.hap" "$(state_file S10b calls.log)"

# ---- S11 no hdc ----------------------------------------------------------------------
section "S11 missing hdc (refuse device steps, keep --dry-run planning)"
run_devloop S11 "HDC=$WORK/bin/definitely-missing-hdc" install --project "$PROJ" --hap "$OUT/hello-maui-app.hap"
assert_eq "S11 install without hdc -> exit 3 (log: $LOGS/S11.log)" "3" "$RC"
assert_contains "S11 message names the missing hdc" "未找到 hdc" "$LOGS/S11.log"
run_devloop S11b "HDC=$WORK/bin/definitely-missing-hdc" --dry-run install --project "$PROJ" --hap "$OUT/hello-maui-app.hap"
assert_eq "S11b --dry-run without hdc still plans (exit 0)" "0" "$RC"
assert_contains "S11b plan still shows the command" "install -r" "$LOGS/S11b.log"

# ---- global --------------------------------------------------------------------------
section "global: no state outside the work dir"
if [ "$GIT_OK" = 1 ]; then
    assert_eq "devloop scripts unchanged by the selftest" "$GIT_BEFORE" \
        "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null | grep -E -e 'scripts/devloop\.sh' -e 'scripts/selftest-devloop\.sh' -e 'scripts/lib-dotnet-env\.sh' || true)"
else
    skip "devloop scripts unchanged (not a git work tree)"
fi
STRAY="$(find "$WORK" -maxdepth 1 \( -name 'tester-report*' -o -name 'devloop.*' \) -print 2>/dev/null)"
assert_eq "no stray devloop state in the work dir" "" "$STRAY"
assert_eq "no secret in any captured log" "0" "$(grep -r -l -F -- "$SECRET" "$LOGS" 2>/dev/null | wc -l | tr -d ' ')"

# ---- summary -------------------------------------------------------------------------
section "selftest summary"
printf 'devloop: %s\n' "$DEVLOOP"
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
