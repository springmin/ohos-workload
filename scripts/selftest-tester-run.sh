#!/bin/sh
# selftest-tester-run.sh - repeatable, fully local selftest for scripts/tester-run.sh.
#
# tester-run.sh is the primary tester path (one-command on-device round). This selftest
# drives it end-to-end against a stub `hdc` created in a temp dir: no device, no real hdc,
# no network. It covers the documented paths and asserts exit codes, the report archive
# contents, and that nothing outside the temp dir is touched.
#
# Scenarios:
#   stub contract  the stub itself (list targets, install ok/fail, pidof alive->dead)
#   S1  dry-run    no action flags, device reachable -> plan only, exit 0, no report
#   S2  success    --uninstall --install --start --capture 1 (+ --device, --expect-tree-digest)
#   S3  install    a hap named *fail* -> code:9568297, exit 1, archive still produced
#   S4  probes     --uninstall --probes <dir> --capture 1 (4 probe haps, PROBE1..PROBE4)
#   S5  crash      pidof alive then dead -> process_alive=no, exit 1
#
# Stub hdc surface (every subcommand tester-run.sh invokes):
#   list targets | install -r <hap> | uninstall <bundle> | shell aa start -a EntryAbility -b <b>
#   shell pidof <b> | shell ps -ef | shell param get <key> | shell bm get -u
#   shell hilog -r | hilog
# `hdc -t <id>` prefixes are accepted. A hap whose basename contains `fail` is rejected
# with `code:9568297` on stderr. pidof answers a pid for the first
# FAKE_HDC_PIDOF_ALIVE_CALLS calls per bundle (default 1), then nothing.
#
# Kit under test: SELFTEST_KIT_DIR if set; else the local
# /data/storage/el2/base/tmp/opencode/device-test-kit when it looks complete; else a
# synthetic minimal kit (module.json + dummy haps + minimal verify-kit.sh) is built in
# the temp dir. SELFTEST_FORCE_SYNTHETIC=1 forces the synthetic kit.
#
# Env: SELFTEST_TMPDIR=<dir>   work dir base (default: the approved opencode tmp dir)
#      SELFTEST_KEEP=1        keep the work dir even when all checks pass
#      SELFTEST_TESTER=<path> tester-run.sh under test (default: next to this script)
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="1 (2026-09-22)"

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

# ---- paths ---------------------------------------------------------------------------
SELFTEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SELFTEST_DIR/.." && pwd)"
TESTER="${SELFTEST_TESTER:-$SELFTEST_DIR/tester-run.sh}"
DEFAULT_KIT="/data/storage/el2/base/tmp/opencode/device-test-kit"

if [ ! -f "$TESTER" ]; then
    printf 'FATAL: tester-run.sh not found: %s\n' "$TESTER" >&2
    exit 1
fi
for _t in sha256sum tar find grep sed wc mktemp env sh; do
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
WORK="$(mktemp -d "$WORK_BASE/selftest-tester-run.XXXXXX" 2>/dev/null || true)"
if [ -z "$WORK" ]; then
    WORK="${TMPDIR:-/tmp}/selftest-tester-run.$$"
    mkdir -p "$WORK"
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
mkdir -p "$CWD" "$TMPD" "$LOGS" "$STATE_DIR" "$WORK/bin" "$WORK/haps" "$WORK/probes"

# ---- check helpers -------------------------------------------------------------------
ok()   { CHECKS=$((CHECKS + 1)); printf '  [PASS] %s\n' "$1"; }
bad()  { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$1"; }
skip() { printf '  [SKIP] %s\n' "$1"; }

assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"
    else bad "$1 (expected '$2', got '$3')"; fi
}
assert_gt() {
    case "$3" in
        ''|*[!0-9]*) bad "$1 (not a number: '$3')" ;;
        *) if [ "$3" -gt "$2" ]; then ok "$1"; else bad "$1 (got $3, want > $2)"; fi ;;
    esac
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
assert_dir_empty() {
    if [ -d "$2" ] && [ -z "$(ls -A "$2" 2>/dev/null)" ]; then ok "$1"
    else bad "$1 (not empty: $2)"; fi
}

sum_val() { sed -n "s/^$2=//p" "$1" | head -n1; }

kit_tree_digest() {
    (
        cd "$1" || exit 1
        find . -type f -print | LC_ALL=C sort | while IFS= read -r _f; do
            printf '%s  %s\n' "$(sha256sum -- "$_f" | cut -d' ' -f1)" "${_f#./}"
        done
    ) | sha256sum | cut -d' ' -f1
}

make_hap() {
    _dst="$1"; _bundle="$2"; _name="${3:-entry}"
    _src="$WORK/hapsrc.$$"
    rm -rf "$_src"
    mkdir -p "$_src"
    cat > "$_src/module.json" <<EOF
{"app":{"bundleName":"$_bundle","versionName":"1.0.0-selftest","minAPIVersion":60000020,"targetAPIVersion":60000020,"apiReleaseType":"Release"},"module":{"name":"$_name","type":"entry","mainElement":"EntryAbility"}}
EOF
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$_src" "$_dst" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    z.write(os.path.join(src, "module.json"), "module.json")
PY
    elif command -v zip >/dev/null 2>&1; then
        ( cd "$_src" && zip -q "$_dst" module.json )
    else
        cp "$_src/module.json" "$_dst"
    fi
    rm -rf "$_src"
}

make_synthetic_kit() {
    _k="$WORK/kit-synth"
    rm -rf "$_k"
    mkdir -p "$_k"
    make_hap "$_k/hello-maui-app.hap" "com.example.hellomauiapp" "entry"
    make_hap "$_k/hello-maui-app-api20.hap" "com.example.hellomauiapp" "entry"
    cat > "$_k/verify-kit.sh" <<'VK_EOF'
#!/bin/sh
# Minimal verify-kit.sh for the synthetic selftest kit; same tree-digest algorithm as the
# real kit's verify-kit.sh (sorted "<file sha256>  <relative path>" lines, hashed again).
set -e
TREE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --tree-digest) TREE=1 ;;
        --expect-tree-digest) shift ;;
    esac
    shift
done
KIT="$(cd "$(dirname "$0")" && pwd)"
cd "$KIT"
if [ "$TREE" = 1 ]; then
    D="$( (find . -type f -print | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r _rel; do
        printf '%s  %s\n' "$(sha256sum -- "$_rel" | cut -d' ' -f1)" "$_rel"
    done) | sha256sum | cut -d' ' -f1)"
    printf '   tree sha256=%s\n' "$D"
fi
sha256sum -c SHA256SUMS >/dev/null
printf 'KIT OK (synthetic selftest kit)\n'
VK_EOF
    chmod +x "$_k/verify-kit.sh"
    ( cd "$_k" && sha256sum hello-maui-app.hap hello-maui-app-api20.hap verify-kit.sh > SHA256SUMS )
}

# ---- kit selection -------------------------------------------------------------------
KIT="${SELFTEST_KIT_DIR:-}"
KIT_ORIGIN=""
if [ -z "$KIT" ] && [ "${SELFTEST_FORCE_SYNTHETIC:-0}" != 1 ] \
   && [ -d "$DEFAULT_KIT" ] && [ -f "$DEFAULT_KIT/SHA256SUMS" ] \
   && [ -f "$DEFAULT_KIT/verify-kit.sh" ] && [ -f "$DEFAULT_KIT/hello-maui-app.hap" ]; then
    KIT="$DEFAULT_KIT"
fi

if [ -n "$KIT" ]; then
    if [ ! -d "$KIT" ] || [ ! -f "$KIT/SHA256SUMS" ] || [ ! -f "$KIT/verify-kit.sh" ]; then
        printf 'FATAL: SELFTEST_KIT_DIR is not a usable kit: %s\n' "$KIT" >&2
        exit 1
    fi
    KIT="$(cd "$KIT" && pwd)"
    KIT_ORIGIN="real kit"
else
    make_synthetic_kit
    KIT="$WORK/kit-synth"
    KIT_ORIGIN="synthetic (real kit not found)"
fi
MAIN_HAP="$KIT/hello-maui-app.hap"
if [ ! -f "$MAIN_HAP" ]; then
    printf 'FATAL: kit has no hello-maui-app.hap: %s\n' "$KIT" >&2
    exit 1
fi

# ---- stub hdc ------------------------------------------------------------------------
STUB="$WORK/bin/hdc"
STUB_DEVICE="FAKE-DEVICE-1"
FAKE_MODEL="OHOS-TEST-DEVICE"
FAKE_BRAND="OpenHarmony"
FAKE_NAME="selftest"
FAKE_DEVTYPE="default"
FAKE_SOFT="OpenHarmony-6.0.0.1(Canary1)"
FAKE_API="20"
FAKE_FULLNAME="OpenHarmony-6.0.0.1"
FAKE_ABI="arm64-v8a"
FAKE_CHARS="default"
FAKE_UDID="0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
FAKE_PID="4242"

cat > "$STUB" <<'STUB_HDC_EOF'
#!/bin/sh
# Stub hdc for selftest-tester-run.sh. Simulates one OpenHarmony device. Not a real tool.
set -u
STATE="${FAKE_HDC_STATE:?FAKE_HDC_STATE not set}"
mkdir -p "$STATE"
ALIVE_CALLS="${FAKE_HDC_PIDOF_ALIVE_CALLS:-1}"
DEVICE="${FAKE_HDC_DEVICE:-FAKE-DEVICE-1}"

LOG_ARGS="$*"
log_call() {
    _rc=$?
    printf '%s | rc=%s\n' "$LOG_ARGS" "$_rc" >> "$STATE/calls.log"
}
trap log_call 0

# tester-run.sh may prefix every command with `-t <device>`.
if [ "${1:-}" = "-t" ] && [ $# -ge 2 ]; then
    shift 2
fi

cmd="${1:-}"
case "$cmd" in
    list)
        if [ "${2:-}" = "targets" ]; then
            printf '%s\n' "$DEVICE"
            exit 0
        fi
        printf 'stub hdc: UNHANDLED list %s\n' "$*" >&2
        exit 1
        ;;
    install)
        _hap=""
        for _a in "$@"; do
            case "$_a" in
                -*) ;;
                *) _hap="$_a" ;;
            esac
        done
        case "$(basename "$_hap")" in
            *fail*)
                printf '[Error]Install failed due to error: code:9568297 device apiCompatibleVersion less than minAPIVersion\n' >&2
                exit 1
                ;;
            *)
                printf 'install bundle successfully.\n'
                exit 0
                ;;
        esac
        ;;
    uninstall)
        printf 'uninstall bundle successfully.\n'
        exit 0
        ;;
    shell)
        shift
        _sub="${1:-}"
        case "$_sub" in
            aa)
                printf 'start ability successfully.\n'
                exit 0
                ;;
            pidof)
                _b="${2:-}"
                _key="$(printf '%s' "$_b" | tr -c 'A-Za-z0-9._-' '_')"
                _f="$STATE/pidof-$_key"
                _n=0
                if [ -f "$_f" ]; then _n="$(cat "$_f")"; fi
                _n=$((_n + 1))
                printf '%s\n' "$_n" > "$_f"
                if [ "$_n" -le "$ALIVE_CALLS" ]; then
                    printf '%s\n' "4242"
                fi
                exit 0
                ;;
            ps)
                printf 'UID        PID  PPID  C STIME TTY          TIME CMD\n'
                printf 'root         1     0  0 00:00 ?        00:00:00 init\n'
                exit 0
                ;;
            param)
                _k="${3:-}"
                _v=""
                case "$_k" in
                    const.product.model) _v="OHOS-TEST-DEVICE" ;;
                    const.product.brand) _v="OpenHarmony" ;;
                    const.product.name) _v="selftest" ;;
                    const.product.devicetype) _v="default" ;;
                    const.product.software.version) _v="OpenHarmony-6.0.0.1(Canary1)" ;;
                    const.ohos.apiversion) _v="20" ;;
                    const.ohos.fullname) _v="OpenHarmony-6.0.0.1" ;;
                    const.product.cpu.abilist) _v="arm64-v8a" ;;
                    const.build.characteristics) _v="default" ;;
                esac
                if [ -n "$_v" ]; then printf '%s\n' "$_v"; fi
                exit 0
                ;;
            bm)
                printf 'udid of current device is : 0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF\n'
                exit 0
                ;;
            hilog)
                printf 'hilog clear done\n'
                exit 0
                ;;
            *)
                printf 'stub hdc: UNHANDLED shell %s\n' "$*" >&2
                exit 1
                ;;
        esac
        ;;
    hilog)
        cat <<'HILOG_EOF'
09-22 10:00:00.000 12345 12345 I A00000/HelloMaui: [maui] openharmony build 1.0.0-selftest abi=arm64 provider=1
09-22 10:00:00.100 12345 12345 I A00000/HelloMaui: [maui] accessibility provider status=1
09-22 10:00:00.200 12345 12345 I A00000/PROBE: PROBE1|dotnet|ok
09-22 10:00:00.300 12345 12345 I A00000/PROBE: PROBE2|jni|ok
09-22 10:00:00.400 12345 12345 I A00000/PROBE: PROBE3|arkts|ok
09-22 10:00:00.500 12345 12345 I A00000/PROBE: PROBE4|libc.so|ok
09-22 10:00:00.600 12345 12345 I A00000/AppKilledReporter: app killed reporter selftest line
09-22 10:00:00.700 12345 12345 I A00000/unrelated: must be filtered out
HILOG_EOF
        exit 0
        ;;
    *)
        printf 'stub hdc: UNHANDLED %s\n' "$*" >&2
        exit 1
        ;;
esac
STUB_HDC_EOF
chmod 755 "$STUB"

# ---- fixtures ------------------------------------------------------------------------
FAIL_HAP="$WORK/haps/hello-maui-app-fail.hap"
make_hap "$FAIL_HAP" "com.example.hellomauiapp" "entry"
_i=1
while [ "$_i" -le 4 ]; do
    make_hap "$WORK/probes/hello-mauiapp-probe$_i-unsigned.hap" "com.example.hellomauiapp.probe$_i" "entry"
    _i=$((_i + 1))
done

KIT_TREE="$(kit_tree_digest "$KIT")"
MAIN_HAP_SHA="$(sha256sum "$MAIN_HAP" | cut -d' ' -f1)"
FAIL_HAP_SHA="$(sha256sum "$FAIL_HAP" | cut -d' ' -f1)"
( cd "$KIT" && sha256sum ./*.hap ) > "$WORK/expected-kit-hap-sha.txt" 2>/dev/null || true

# Sandbox: everything tester-run.sh writes must land in $WORK (+ its TMPDIR, which it cleans).
RC=0
run_tester() {
    _tag="$1"; _extra="$2"; shift 2
    _log="$LOGS/$_tag.log"
    RC=0
    # $_extra is intentionally unquoted: it carries zero or more `VAR=value` assignments.
    ( cd "$CWD" && env HDC="$STUB" TMPDIR="$TMPD" FAKE_HDC_STATE="$STATE_DIR/$_tag" \
        FAKE_HDC_DEVICE="$STUB_DEVICE" $_extra sh "$TESTER" "$@" ) > "$_log" 2>&1 || RC=$?
    return 0
}

report_archive() { ls "$WORK"/"$1"-*.tar.gz 2>/dev/null | head -n1; }

prepare_report() {
    if [ ! -f "$1" ]; then return 1; fi
    rm -rf "$2"
    mkdir -p "$2"
    tar xzf "$1" -C "$2" 2>/dev/null || return 1
    REPORT="$2/$3"
    if [ -d "$REPORT" ]; then return 0; fi
    return 1
}

assert_scenario_sandbox() {
    assert_dir_empty "$1 sandbox cwd untouched" "$CWD"
    assert_dir_empty "$1 tester TMPDIR cleaned" "$TMPD"
    assert_not_contains "$1 no unhandled hdc subcommand" "UNHANDLED" "$STATE_DIR/$1/calls.log"
}

# ---- environment ---------------------------------------------------------------------
section "environment (selftest $SELFTEST_VERSION)"
log "tester : $TESTER"
log "kit    : $KIT ($KIT_ORIGIN)"
log "work   : $WORK"
log "stub   : $STUB"

if sh -n "$TESTER" 2> "$LOGS/tester-syntax.log"; then
    ok "tester-run.sh passes sh -n"
else
    bad "tester-run.sh fails sh -n (see $LOGS/tester-syntax.log)"
fi

GIT_OK=0
GIT_BEFORE=""
if command -v git >/dev/null 2>&1 && git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    GIT_OK=1
    GIT_BEFORE="$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null || true)"
fi

# ---- stub contract -------------------------------------------------------------------
section "stub contract"
STUB_RC=0
FAKE_HDC_STATE="$STATE_DIR/contract-list" "$STUB" list targets > "$LOGS/stub-list.out" 2>&1 || STUB_RC=$?
assert_eq "stub: list targets rc=0" "0" "$STUB_RC"
assert_contains "stub: one fake device listed" "$STUB_DEVICE" "$LOGS/stub-list.out"

STUB_RC=0
FAKE_HDC_STATE="$STATE_DIR/contract-install-ok" "$STUB" install -r "$MAIN_HAP" > "$LOGS/stub-install-ok.out" 2>&1 || STUB_RC=$?
assert_eq "stub: kit hap install rc=0" "0" "$STUB_RC"
assert_contains "stub: kit hap install succeeds" "install bundle successfully" "$LOGS/stub-install-ok.out"

STUB_RC=0
FAKE_HDC_STATE="$STATE_DIR/contract-install-fail" "$STUB" install -r "$FAIL_HAP" > "$LOGS/stub-install-fail.out" 2> "$LOGS/stub-install-fail.err" || STUB_RC=$?
assert_eq "stub: *fail* hap install rc=1" "1" "$STUB_RC"
assert_contains "stub: *fail* code:9568297 on stderr" "code:9568297" "$LOGS/stub-install-fail.err"

P1="$(FAKE_HDC_STATE="$STATE_DIR/contract-pidof" "$STUB" shell pidof com.example.hellomauiapp)"
P2="$(FAKE_HDC_STATE="$STATE_DIR/contract-pidof" "$STUB" shell pidof com.example.hellomauiapp)"
assert_eq "stub: pidof alive on 1st call" "$FAKE_PID" "$P1"
assert_eq "stub: pidof dead on 2nd call" "" "$P2"

HILOG_OUT="$LOGS/stub-hilog.out"
FAKE_HDC_STATE="$STATE_DIR/contract-hilog" "$STUB" hilog > "$HILOG_OUT" 2>&1 || true
assert_contains "stub: hilog streams [maui]" "[maui]" "$HILOG_OUT"
assert_contains "stub: hilog streams PROBE4|libc.so|ok" "PROBE4|libc.so|ok" "$HILOG_OUT"
assert_contains "stub: hilog streams AppKilledReporter" "AppKilledReporter" "$HILOG_OUT"

# ---- S1: dry-run plan ----------------------------------------------------------------
section "S1 dry-run plan (no action flags)"
run_tester S1 "" --kit-dir "$KIT" --out "$WORK/out-dry"
assert_eq "S1 exit code 0 (log: $LOGS/S1.log)" "0" "$RC"
assert_not_exists "S1 dry-run creates no report dir" "$WORK/out-dry"
CALLS_S1="$STATE_DIR/S1/calls.log"
assert_file "S1 stub call log" "$CALLS_S1"
assert_eq "S1 stub saw only list targets" "1" "$(wc -l < "$CALLS_S1" | tr -d ' ')"
assert_contains "S1 log is a dry-run install plan" "未加 --install" "$LOGS/S1.log"
assert_scenario_sandbox "S1"

# ---- S2: success path ----------------------------------------------------------------
section "S2 success path (--uninstall --install --start --capture 1)"
run_tester S2 "" --kit-dir "$KIT" --device "$STUB_DEVICE" --expect-tree-digest "$KIT_TREE" \
    --uninstall --install --start --capture 1 --out "$WORK/out-success"
assert_eq "S2 exit code 0 (log: $LOGS/S2.log)" "0" "$RC"

ARCHIVE_S2="$(report_archive out-success)"
assert_file "S2 report archive produced" "$ARCHIVE_S2"
if [ -f "$ARCHIVE_S2.sha256" ]; then
    _rc=0
    ( cd "$WORK" && sha256sum -c "$(basename "$ARCHIVE_S2").sha256" ) > "$LOGS/S2-sidecar.txt" 2>&1 || _rc=$?
    assert_eq "S2 archive sha256 sidecar verifies" "0" "$_rc"
else
    bad "S2 archive sha256 sidecar missing"
fi

if prepare_report "$ARCHIVE_S2" "$WORK/x-success" out-success; then
    S="$REPORT/summary.txt"
    assert_file "S2 summary.txt in archive" "$S"
    assert_eq "S2 summary verify_kit=ok" "ok" "$(sum_val "$S" verify_kit)"
    assert_eq "S2 summary dry_run=no" "no" "$(sum_val "$S" dry_run)"
    assert_eq "S2 summary tree_digest = kit digest" "$KIT_TREE" "$(sum_val "$S" tree_digest)"
    assert_eq "S2 summary expect_tree_digest recorded" "$KIT_TREE" "$(sum_val "$S" expect_tree_digest)"
    assert_eq "S2 summary main_hap_sha256 = kit hash" "$MAIN_HAP_SHA" "$(sum_val "$S" main_hap_sha256)"
    assert_eq "S2 summary kit_source=dir" "dir" "$(sum_val "$S" kit_source)"
    assert_eq "S2 summary kit_dir" "$KIT" "$(sum_val "$S" kit_dir)"
    assert_eq "S2 summary bundle" "com.example.hellomauiapp" "$(sum_val "$S" bundle)"
    assert_eq "S2 summary main_install_result=ok" "ok" "$(sum_val "$S" main_install_result)"
    assert_eq "S2 summary uninstall_main=ok" "ok" "$(sum_val "$S" uninstall_main)"
    assert_eq "S2 summary start_result=ok" "ok" "$(sum_val "$S" start_result)"
    assert_eq "S2 summary process_alive=yes" "yes" "$(sum_val "$S" process_alive)"
    assert_eq "S2 summary process_pid" "$FAKE_PID" "$(sum_val "$S" process_pid)"
    assert_eq "S2 summary capture_result=ok" "ok" "$(sum_val "$S" capture_result)"
    assert_eq "S2 summary failures=0" "0" "$(sum_val "$S" failures)"
    assert_eq "S2 summary device_model" "$FAKE_MODEL" "$(sum_val "$S" device_model)"
    assert_eq "S2 summary device_api" "$FAKE_API" "$(sum_val "$S" device_api)"
    assert_eq "S2 summary udid" "$FAKE_UDID" "$(sum_val "$S" udid)"
    assert_gt "S2 summary hilog_full_lines > 0" 0 "$(sum_val "$S" hilog_full_lines)"
    assert_gt "S2 summary hilog_filtered_lines > 0" 0 "$(sum_val "$S" hilog_filtered_lines)"

    assert_contains "S2 full hilog has [maui]" "[maui]" "$REPORT/hilog/hilog-full.txt"
    assert_contains "S2 full hilog has unrelated line" "A00000/unrelated:" "$REPORT/hilog/hilog-full.txt"
    assert_contains "S2 filtered hilog has [maui]" "[maui]" "$REPORT/hilog/hilog-filtered.txt"
    assert_contains "S2 filtered hilog has AppKilledReporter" "AppKilledReporter" "$REPORT/hilog/hilog-filtered.txt"
    assert_contains "S2 filtered hilog has PROBE4|libc.so|ok" "PROBE4|libc.so|ok" "$REPORT/hilog/hilog-filtered.txt"
    assert_not_contains "S2 filtered hilog drops unmatched line" "A00000/unrelated:" "$REPORT/hilog/hilog-filtered.txt"

    assert_file "S2 meta/module.json in archive" "$REPORT/meta/module.json"
    assert_contains "S2 meta/module.json has bundleName" "com.example.hellomauiapp" "$REPORT/meta/module.json"
    assert_file "S2 meta/SHA256SUMS in archive" "$REPORT/meta/SHA256SUMS"
    assert_file "S2 meta/kit-hap-sha256.txt in archive" "$REPORT/meta/kit-hap-sha256.txt"
    assert_file "S2 meta/verify-kit.log in archive" "$REPORT/meta/verify-kit.log"
    if [ -f "$REPORT/meta/SHA256SUMS" ] && diff -q "$KIT/SHA256SUMS" "$REPORT/meta/SHA256SUMS" >/dev/null 2>&1; then
        ok "S2 meta/SHA256SUMS matches kit"
    else
        bad "S2 meta/SHA256SUMS differs from kit"
    fi
    if [ -f "$REPORT/meta/kit-hap-sha256.txt" ] && diff -q "$WORK/expected-kit-hap-sha.txt" "$REPORT/meta/kit-hap-sha256.txt" >/dev/null 2>&1; then
        ok "S2 kit-hap-sha256.txt matches sha256sum ./$*.hap"
    else
        bad "S2 kit-hap-sha256.txt differs from sha256sum ./*.hap"
    fi

    assert_contains "S2 device param model" "const.product.model=$FAKE_MODEL" "$REPORT/device/param-get.txt"
    assert_contains "S2 device param brand" "const.product.brand=$FAKE_BRAND" "$REPORT/device/param-get.txt"
    assert_contains "S2 device param api" "const.ohos.apiversion=$FAKE_API" "$REPORT/device/param-get.txt"
    assert_contains "S2 device param abilist" "const.product.cpu.abilist=$FAKE_ABI" "$REPORT/device/param-get.txt"
    assert_eq "S2 device param-get has 9 keys" "9" "$(wc -l < "$REPORT/device/param-get.txt" | tr -d ' ')"
    assert_contains "S2 device bm-get-u has udid" "$FAKE_UDID" "$REPORT/device/bm-get-u.txt"
    assert_eq "S2 device udid.txt" "$FAKE_UDID" "$(cat "$REPORT/device/udid.txt" 2>/dev/null)"
else
    bad "S2 report archive could not be extracted ($ARCHIVE_S2)"
fi

CALLS_S2="$STATE_DIR/S2/calls.log"
assert_contains "S2 stub called -t device" "-t $STUB_DEVICE" "$CALLS_S2"
assert_contains "S2 stub called uninstall" "uninstall com.example.hellomauiapp" "$CALLS_S2"
assert_contains "S2 stub called install" "install -r $MAIN_HAP" "$CALLS_S2"
assert_contains "S2 stub called aa start" "shell aa start -a EntryAbility -b com.example.hellomauiapp" "$CALLS_S2"
assert_contains "S2 stub called pidof" "shell pidof com.example.hellomauiapp" "$CALLS_S2"
assert_contains "S2 stub called hilog -r" "shell hilog -r" "$CALLS_S2"
assert_contains "S2 stub called param get" "shell param get const.product.model" "$CALLS_S2"
assert_contains "S2 stub called bm get -u" "shell bm get -u" "$CALLS_S2"
assert_scenario_sandbox "S2"

# ---- S3: install failure path --------------------------------------------------------
section "S3 install-failure path (*fail* hap -> code:9568297)"
run_tester S3 "" --kit-dir "$KIT" --hap "$FAIL_HAP" --install --start --capture 1 --out "$WORK/out-fail"
assert_eq "S3 exit code 1 (log: $LOGS/S3.log)" "1" "$RC"

ARCHIVE_S3="$(report_archive out-fail)"
assert_file "S3 archive still produced on install failure" "$ARCHIVE_S3"
assert_contains "S3 install failure mentions code:9568297" "code:9568297" "$LOGS/S3.log"
assert_contains "S3 stub rejected *fail* hap (rc=1)" "hello-maui-app-fail.hap | rc=1" "$STATE_DIR/S3/calls.log"

if prepare_report "$ARCHIVE_S3" "$WORK/x-fail" out-fail; then
    S="$REPORT/summary.txt"
    assert_eq "S3 summary main_install_result=code:9568297" "code:9568297" "$(sum_val "$S" main_install_result)"
    assert_gt "S3 summary failures >= 1" 0 "$(sum_val "$S" failures)"
    assert_eq "S3 summary main_hap_sha256 = fail hap hash" "$FAIL_HAP_SHA" "$(sum_val "$S" main_hap_sha256)"
    assert_eq "S3 summary bundle read from fail hap" "com.example.hellomauiapp" "$(sum_val "$S" bundle)"
    assert_file "S3 install log in archive" "$REPORT/install/hello-maui-app-fail.hap.log"
    assert_contains "S3 install log has code:9568297" "code:9568297" "$REPORT/install/hello-maui-app-fail.hap.log"
    assert_file "S3 archive still has hilog capture" "$REPORT/hilog/hilog-full.txt"
    assert_contains "S3 hilog still has PROBE lines" "PROBE4|libc.so|ok" "$REPORT/hilog/hilog-full.txt"
    assert_file "S3 meta/module.json of fail hap" "$REPORT/meta/module.json"
else
    bad "S3 report archive could not be extracted ($ARCHIVE_S3)"
fi
assert_scenario_sandbox "S3"

# ---- S4: probes path -----------------------------------------------------------------
section "S4 probes path (--uninstall --probes <dir> --capture 1)"
run_tester S4 "" --kit-dir "$KIT" --uninstall --probes "$WORK/probes" --capture 1 --out "$WORK/out-probes"
assert_eq "S4 exit code 0 (log: $LOGS/S4.log)" "0" "$RC"

ARCHIVE_S4="$(report_archive out-probes)"
assert_file "S4 report archive produced" "$ARCHIVE_S4"
if prepare_report "$ARCHIVE_S4" "$WORK/x-probes" out-probes; then
    S="$REPORT/summary.txt"
    assert_eq "S4 summary main_install_result=skipped(dry-run)" "skipped(dry-run)" "$(sum_val "$S" main_install_result)"
    assert_eq "S4 summary capture_result=ok" "ok" "$(sum_val "$S" capture_result)"
    assert_eq "S4 summary uninstall_main=ok" "ok" "$(sum_val "$S" uninstall_main)"
    _i=1
    while [ "$_i" -le 4 ]; do
        assert_eq "S4 summary uninstall_probe$_i=ok" "ok" "$(sum_val "$S" uninstall_probe$_i)"
        assert_eq "S4 summary probe${_i}_install=ok" "ok" "$(sum_val "$S" "probe${_i}_install")"
        assert_eq "S4 summary probe${_i}_result=ok" "ok" "$(sum_val "$S" "probe${_i}_result")"
        assert_eq "S4 summary probe${_i}_alive=yes" "yes" "$(sum_val "$S" "probe${_i}_alive")"
        assert_gt "S4 summary probe${_i}_lines > 0" 0 "$(sum_val "$S" "probe${_i}_lines")"
        assert_file "S4 probe$_i lines file in archive" "$REPORT/probes/probe$_i-lines.txt"
        assert_contains "S4 probe$_i lines file has PROBE$_i" "PROBE$_i" "$REPORT/probes/probe$_i-lines.txt"
        _i=$((_i + 1))
    done
    assert_contains "S4 probe4 line is PROBE4|libc.so|ok" "PROBE4|libc.so|ok" "$REPORT/probes/probe4-lines.txt"
    assert_contains "S4 probe-all-lines has PROBE1" "PROBE1|dotnet|ok" "$REPORT/probes/probe-all-lines.txt"
    assert_contains "S4 probe-all-lines has PROBE4" "PROBE4|libc.so|ok" "$REPORT/probes/probe-all-lines.txt"
    assert_gt "S4 probe-all-lines has all 4 probes" 3 "$(wc -l < "$REPORT/probes/probe-all-lines.txt" | tr -d ' ' | sed 's/^ *//')"
    assert_contains "S4 probe1 install log success" "install bundle successfully" "$REPORT/probes/probe1-install.txt"
else
    bad "S4 report archive could not be extracted ($ARCHIVE_S4)"
fi
assert_scenario_sandbox "S4"

# ---- S5: crash path ------------------------------------------------------------------
section "S5 crash path (pidof alive -> dead)"
run_tester S5 "FAKE_HDC_PIDOF_ALIVE_CALLS=0" --kit-dir "$KIT" --install --start --capture 1 --out "$WORK/out-dead"
assert_eq "S5 exit code 1 (log: $LOGS/S5.log)" "1" "$RC"

ARCHIVE_S5="$(report_archive out-dead)"
assert_file "S5 report archive produced" "$ARCHIVE_S5"
if prepare_report "$ARCHIVE_S5" "$WORK/x-dead" out-dead; then
    S="$REPORT/summary.txt"
    assert_eq "S5 summary start_result=ok" "ok" "$(sum_val "$S" start_result)"
    assert_eq "S5 summary process_alive=no" "no" "$(sum_val "$S" process_alive)"
    assert_eq "S5 summary process_pid=<none>" "<none>" "$(sum_val "$S" process_pid)"
    assert_gt "S5 summary failures >= 1" 0 "$(sum_val "$S" failures)"
    assert_contains "S5 ps fallback consulted" "shell ps -ef" "$STATE_DIR/S5/calls.log"
else
    bad "S5 report archive could not be extracted ($ARCHIVE_S5)"
fi
assert_scenario_sandbox "S5"

# ---- global: nothing outside the temp dir --------------------------------------------
section "global: no state outside the temp dir"
assert_eq "kit tree digest unchanged after all runs" "$KIT_TREE" "$(kit_tree_digest "$KIT")"
assert_not_exists "no default ./tester-report in sandbox cwd" "$CWD/tester-report"
STRAY="$(find "$WORK" -maxdepth 1 -name 'tester-report*' -print 2>/dev/null)"
assert_eq "no stray tester-report dir in work dir" "" "$STRAY"
if [ "$GIT_OK" = 1 ]; then
    assert_eq "repo working tree unchanged by tester-run.sh" "$GIT_BEFORE" "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null || true)"
else
    skip "repo working tree check (not a git work tree)"
fi

# ---- summary -------------------------------------------------------------------------
section "selftest summary"
printf 'kit:    %s (%s)\n' "$KIT" "$KIT_ORIGIN"
printf 'checks: %s, failed: %s\n' "$CHECKS" "$FAILED"
if [ "$FAILED" -gt 0 ]; then
    printf 'RESULT: FAIL\n'
    printf 'logs and reports kept at: %s\n' "$WORK"
    exit 1
fi
printf 'RESULT: PASS\n'
if [ "$KEEP" = 1 ]; then
    printf 'work dir kept (SELFTEST_KEEP=1): %s\n' "$WORK"
fi
exit 0
