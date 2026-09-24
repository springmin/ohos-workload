#!/bin/sh
# selftest-tester-run.sh - repeatable, fully local selftest for scripts/tester-run.sh (the
# primary tester path). Drives it end-to-end against a stub `hdc` in a temp dir: no device, no
# real hdc, no network; asserts exit codes, report-archive contents, and that nothing outside
# the temp dir is touched.
# Scenarios:
#   stub contract  the stub itself (list targets, install ok/fail, pidof alive->dead,
#                  hilog -r/stream, "hilog -t kmsg", app-lib ls, /proc/sys evidence cats)
#   S1 dry-run     no action flags, device reachable -> plan only, exit 0, no report
#   S2 success     --uninstall --install --start --capture 1 (+ --device, --expect-tree-digest,
#                  --compare-lib) -> kmsg + ELF-signing + app-lib path evidence assertions
#   S3 install     a hap named *fail* -> code:9568297, exit 1, archive still produced
#   S4 probes      --uninstall --probes <dir> --capture 1 (4 probe haps, PROBE1..PROBE4)
#   S5 crash       pidof alive then dead -> process_alive=no, exit 1
#   S6 missing     missing /proc evidence paths + --compare-lib file + bundle libs dir tolerated
#   S7 extra       --extra-probes <dir> (comma + repeated, deduped): one importprobe-a hap is
#                  installed, started, captured and archived like P1-P4
#   S8 extra-fail  an extra probe whose install fails is recorded as install_failed and skipped;
#                  the round still produces its archive
#   S9 injection   11 malicious bundleName payloads (;, &&, $(), backticks, newline, space,
#                  quotes, backslashes, traversal) in module.json are rejected before any hdc
#                  command; traversal writes no file outside $OUT
#   S9b valid      control group: dotted/underscore/uppercase names still install, start and
#                  record their joined device-side command
#   S10 env        KIT_BUNDLE_NAME with a payload is rejected; a valid one still drives the
#                  fallback path
#   S11 bootstrap  FAKE_HDC_BOOTSTRAP_ERRORS=1: hilog-bootstrap.txt keeps the reference failure
#                  signatures and summary counts them (bootstrap_errors/rawfile_errors/libload_errors)
#   S12 payload    FAKE_HDC_MISSING_PAYLOAD=1: missing files dir + marker tolerated
#                  (payload_present=no, payload_marker=empty, failures=0)
#   S13 no index   a kit hap without resources.index -> meta/kit-selfcheck.txt shows index=missing,
#                  summary kit_index_ok=no; no capture window -> bootstrap_errors=<unavailable>
# Stub hdc surface (every subcommand tester-run.sh invokes): list targets | install -r <hap> |
#   uninstall <bundle> | shell aa start -a EntryAbility -b <b> | shell pidof <b> | shell ps -ef
#   | shell param get <key> | shell bm get -u | shell hilog -r | hilog | shell "hilog -t kmsg"
#   | shell "cat /proc/sys/..." | shell "ls -l /data/storage/el1/bundle/libs/arm64/ 2>/dev/null"
#   | shell "ls -l /data/storage/el2/base/haps/entry/files/ 2>/dev/null"
#   | shell "cat /data/storage/el2/base/haps/entry/files/dotnet.marker 2>/dev/null"
#   `hdc -t <id>` prefixes are accepted. Every `shell` invocation is appended, joined the way
#   hdc joins its argv, to <state>/device-shell.log (never executed): the S9 tests fail if a
#   payload ever reaches that line. A hap whose basename contains `fail` is rejected with
#   `code:9568297` on stderr. pidof answers a pid for the first FAKE_HDC_PIDOF_ALIVE_CALLS calls
#   per bundle (default 1), then nothing. FAKE_HDC_MISSING_PROC=1 fails both /proc/sys cats;
#   FAKE_HDC_MISSING_APPLIBS=1 fails the bundle libs ls; FAKE_HDC_MISSING_PAYLOAD=1 fails the
#   files dir ls and the marker cat; FAKE_HDC_BOOTSTRAP_ERRORS=1 adds the device report §4/§7
#   failure lines to the hilog stream. A stub `binary-sign-tool` in $WORK/bin (prepended to
#   PATH) answers `display-sign` with `code signature is not found`.
# Kit under test: SELFTEST_KIT_DIR if set; else the local approved device-test-kit dir when it
#   looks complete; else a synthetic minimal kit (module.json + dummy haps + minimal
#   verify-kit.sh) in the temp dir. SELFTEST_FORCE_SYNTHETIC=1 forces the synthetic kit.
# Env: SELFTEST_TMPDIR=<dir> work dir base (default: the approved opencode tmp dir),
#      SELFTEST_KEEP=1 keep the work dir even when all checks pass,
#      SELFTEST_TESTER=<path> tester-run.sh under test (default: next to this script).
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="6 (2026-09-24)"

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

# ---- paths ---------------------------------------------------------------------------
# Resolve the script/repo root before anything else. Everything the selftest later uses
# (work dir, logs, stub, kit, tester script) is anchored to these absolute roots, so the
# run is identical no matter which cwd `sh selftest-tester-run.sh` is launched from.
_self_path="$0"
case "$_self_path" in
    */*) ;;
    *) _self_path="$(command -v "$_self_path" 2>/dev/null || printf '%s' "$_self_path")" ;;
esac
SELF_DIR="$(cd "$(dirname "$_self_path")" && pwd -P)" || { printf 'FATAL: cannot resolve the selftest directory\n' >&2; exit 1; }
SELFTEST_DIR="$SELF_DIR"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd -P)" || REPO_DIR="$SELF_DIR"
ROOT_DIR="$REPO_DIR"
TESTER="${SELFTEST_TESTER:-$SELF_DIR/tester-run.sh}"
# SELFTEST_TESTER may be relative: anchor it to the launch cwd, not to the work dir.
case "$TESTER" in
    /*) ;;
    *) TESTER="$PWD/$TESTER" ;;
esac
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
# SELFTEST_TMPDIR/TMPDIR can be relative: anchor them to the launch cwd first, then
# canonicalize, so WORK and every path under it are absolute whatever the cwd does later.
case "$WORK_BASE" in
    /*) ;;
    *) WORK_BASE="$PWD/$WORK_BASE" ;;
esac
if ! mkdir -p "$WORK_BASE" 2>/dev/null; then
    WORK_BASE="${TMPDIR:-/tmp}"
    case "$WORK_BASE" in
        /*) ;;
        *) WORK_BASE="$PWD/$WORK_BASE" ;;
    esac
    mkdir -p "$WORK_BASE" 2>/dev/null || true
fi
WORK_BASE="$(cd "$WORK_BASE" 2>/dev/null && pwd -P)" || WORK_BASE="/tmp"
WORK="$(mktemp -d "$WORK_BASE/selftest-tester-run.XXXXXX" 2>/dev/null || true)"
if [ -z "$WORK" ]; then
    WORK="$WORK_BASE/selftest-tester-run.$$"
    mkdir -p "$WORK" 2>/dev/null || { printf 'FATAL: cannot create a work dir under %s\n' "$WORK_BASE" >&2; exit 1; }
fi
WORK="$(cd "$WORK" && pwd -P)" || exit 1
# Ownership marker: cleanup removes the work dir only while it is still this run's dir.
WORK_OWNER="$WORK/.selftest-owner"
printf '%s\n' "$$" > "$WORK_OWNER" 2>/dev/null || true

CHECKS=0
FAILED=0
KEEP="${SELFTEST_KEEP:-0}"
INTERRUPTED=0
TESTER_JOB=""

# Keep the work dir when a check failed, when asked to, or when the run was interrupted
# (evidence for triage), and remove it only if this run still owns it: a cleanup that
# fired mid-run (or belongs to another process) must never pull logs/state/cwd out from
# under the scenarios that are still executing.
cleanup() {
    trap - 0 1 2 15
    # Converge first: stop the in-flight tester-run.sh (TERM, then KILL, then reap) so no
    # background work survives the selftest.
    if [ -n "$TESTER_JOB" ]; then
        kill "$TESTER_JOB" >/dev/null 2>&1 || true
        kill -0 "$TESTER_JOB" >/dev/null 2>&1 && kill -9 "$TESTER_JOB" >/dev/null 2>&1 || true
        wait "$TESTER_JOB" >/dev/null 2>&1 || true
        TESTER_JOB=""
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
}
trap cleanup 0
# A signal must terminate the selftest. The old `trap cleanup 0 1 2 15` ran cleanup and
# then kept executing: the removed work dir made the remaining scenarios cascade
# (S9b..S13 "can't create .../logs" and "not empty" failures) and the run outlived a
# caller's timeout.
trap 'INTERRUPTED=1; exit 1' 1 2 15

CWD="$WORK/cwd"
TMPD="$WORK/tmp"
LOGS="$WORK/logs"
STATE_DIR="$WORK/state"

# Recreate the key dirs before each scenario: if an external cleanup removes one
# mid-run, the next scenario recovers instead of failing with "can't create .../logs".
ensure_work_dirs() {
    mkdir -p "$CWD" "$TMPD" "$LOGS" "$STATE_DIR" "$WORK/bin" "$WORK/haps" "$WORK/probes" 2>/dev/null || true
}
ensure_work_dirs

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
assert_matches() {
    if [ -f "$3" ] && grep -Eq -- "$2" "$3"; then ok "$1"
    else bad "$1 (no match for '$2' in ${3:-<empty>})"; fi
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
    _dst="$1"; _bundle="$2"; _name="${3:-entry}"; _with_index="${4:-1}"
    _src="$WORK/hapsrc.$$"
    rm -rf "$_src"
    mkdir -p "$_src/ets"
    cat > "$_src/module.json" <<EOF
{"app":{"bundleName":"$_bundle","versionName":"1.0.0-selftest","minAPIVersion":60000020,"targetAPIVersion":60000020,"apiReleaseType":"Release"},"module":{"name":"$_name","type":"entry","mainElement":"EntryAbility"}}
EOF
    if [ "$_with_index" = 1 ]; then
        # kit #22 contract the tester-run self-check reads back: resources.index + an abc with
        # the fixed 16-byte header (magic "PANDA", adler placeholder, version 13.0.1.0 at 0x0c).
        printf 'IDX:selftest' > "$_src/resources.index"
        printf 'PANDA\000\000\000\000\000\000\000\015\000\001\000' > "$_src/ets/modules.abc"
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$_src" "$_dst" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _dirs, files in os.walk(src):
        for fname in sorted(files):
            path = os.path.join(root, fname)
            z.write(path, os.path.relpath(path, src))
PY
    elif command -v zip >/dev/null 2>&1; then
        ( cd "$_src" && zip -q -r "$_dst" . )
    else
        cp "$_src/module.json" "$_dst"
    fi
    rm -rf "$_src"
}

# Like make_hap, but the bundle name goes through json.dumps: needed for the S9 payloads
# (quotes, backslashes, control characters) that make_hap's raw heredoc cannot carry.
make_hap_json() {
    _dst="$1"; _bundle="$2"; _name="${3:-entry}"
    python3 - "$_dst" "$_bundle" "$_name" <<'PY'
import json, os, sys, tempfile, zipfile
dst, bundle, name = sys.argv[1], sys.argv[2], sys.argv[3]
mod = {"app": {"bundleName": bundle, "versionName": "1.0.0-selftest",
               "minAPIVersion": 60000020, "targetAPIVersion": 60000020, "apiReleaseType": "Release"},
       "module": {"name": name, "type": "entry", "mainElement": "EntryAbility"}}
with tempfile.TemporaryDirectory() as d:
    path = os.path.join(d, "module.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(mod, handle)
    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(path, "module.json")
PY
}

make_synthetic_kit() {
    _k="${1:-$WORK/kit-synth}"
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
        _cmd="$*"
        # hdc joins `shell` argv into one device-side command line; record that line so the
        # tests can prove no bundle-name payload ever reaches it (stub-only, not executed).
        printf '%s\n' "$_cmd" >> "$STATE/device-shell.log"
        case "$_cmd" in
            "hilog -t kmsg")
                cat <<'KMSG_EOF'
09-22 10:00:01.000 0 0 I [xpm]: /data/app/el1/bundle/public/com.example.hellomauiapp/libs/arm64-v8a/libopenharmonyhost.so is not protected by dmverity
09-22 10:00:01.100 0 0 I [xpm]: xpm get signature info failed, etype: 1
09-22 10:00:01.200 0 0 I [xpm]: {"event_type":"unsigned file","filename":"libopenharmonyhost.so"}
09-22 10:00:01.300 0 0 I [fs_security_verity]: lib_no_signed event waken: -9(E_HM_PERM)
09-22 10:00:01.400 0 0 I [kernel]: unrelated kmsg line must be filtered out
KMSG_EOF
                exit 0
                ;;
            "hilog -r")
                printf 'hilog clear done\n'
                exit 0
                ;;
            "ls -l /data/storage/el1/bundle/libs/arm64/ 2>/dev/null")
                if [ "${FAKE_HDC_MISSING_APPLIBS:-0}" = 1 ]; then
                    printf 'ls: /data/storage/el1/bundle/libs/arm64/: No such file or directory\n' >&2
                    exit 1
                fi
                printf 'total 12880\n'
                printf '%s\n' '-rwxr-xr-x 1 0 0 195488 /data/storage/el1/bundle/libs/arm64/libopenharmonyhost.so'
                printf '%s\n' '-rwxr-xr-x 1 0 0 1246328 /data/storage/el1/bundle/libs/arm64/libc++_shared.so'
                exit 0
                ;;
            "ls -l /data/storage/el2/base/haps/entry/files/ 2>/dev/null")
                if [ "${FAKE_HDC_MISSING_PAYLOAD:-0}" = 1 ]; then
                    printf 'ls: /data/storage/el2/base/haps/entry/files/: No such file or directory\n' >&2
                    exit 1
                fi
                printf 'total 32\n'
                printf '%s\n' 'drwxr-xr-x 2 0 0 4096 /data/storage/el2/base/haps/entry/files/dotnet'
                printf '%s\n' '-rw-r--r-- 1 0 0 123 /data/storage/el2/base/haps/entry/files/dotnet.marker'
                printf '%s\n' '-rw-r--r-- 1 0 0 456 /data/storage/el2/base/haps/entry/files/note.txt'
                exit 0
                ;;
            "cat /data/storage/el2/base/haps/entry/files/dotnet.marker 2>/dev/null")
                if [ "${FAKE_HDC_MISSING_PAYLOAD:-0}" = 1 ]; then
                    exit 1
                fi
                printf '%s\n' '{"zipSize":15974604,"mtime":1758600000,"fileCount":253}'
                exit 0
                ;;
            "cat /proc/sys/kernel/xpm/xpm_mode")
                if [ "${FAKE_HDC_MISSING_PROC:-0}" = 1 ]; then
                    printf 'cat: %s: No such file or directory\n' "$_cmd" >&2
                    exit 1
                fi
                printf '2\n'
                exit 0
                ;;
            "cat /proc/sys/fs/verity/require_signatures")
                if [ "${FAKE_HDC_MISSING_PROC:-0}" = 1 ]; then
                    printf 'cat: %s: No such file or directory\n' "$_cmd" >&2
                    exit 1
                fi
                printf '1\n'
                exit 0
                ;;
        esac
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
09-22 10:00:00.550 12345 12345 I A00000/IMPORTPROBE: ABILITY_ON_CREATE
09-22 10:00:00.560 12345 12345 I A00000/IMPORTPROBE_A: A PAGE_ABOUT_TO_APPEAR
09-22 10:00:00.600 12345 12345 I A00000/AppKilledReporter: app killed reporter selftest line
09-22 10:00:00.700 12345 12345 I A00000/unrelated: must be filtered out
09-22 10:00:00.800 12345 12345 I A00000/ets_runtime: SetAppLibPath appLibPathKey: com.example.hellomauiapp/entry, lib path: /data/storage/el1/bundle/libs/arm64
09-22 10:00:00.810 12345 12345 I A00000/NAPI: dlopen libopenharmonyhost.so from /data/storage/el1/bundle/libs/arm64
HILOG_EOF
        # Device report §4/§7 failure signatures (opt-in so the default stream stays clean:
        # the empty-result tolerance of hilog-bootstrap.txt is asserted on the default stream).
        if [ "${FAKE_HDC_BOOTSTRAP_ERRORS:-0}" = 1 ]; then
            cat <<'BOOT_EOF'
09-22 10:00:01.000 12345 12345 E A00000/OHOS_DOTNET: bootstrap failed: GetRawFileContent failed, name is empty
09-22 10:00:04.000 12345 12345 E A00000/OHOS_DOTNET: bootstrap retry failed: GetRawFileContent failed, name is empty
09-22 10:00:07.000 12345 12345 E A00000/OHOS_DOTNET: bootstrap final retry failed: GetRawFileContent failed, name is empty
09-22 10:00:07.100 12345 12345 E A00000/OHOS_DOTNET: bootstrap failed: BusinessError 900002: destination path is not an existing directory
09-22 10:00:07.200 12345 12345 E A00000/OHOS_DOTNET: bootstrap failed: BusinessError 900003: ZIP entry data extraction failed, source file may be damaged
09-22 10:00:07.300 12345 12345 I A00000/MMG: [NMM:1439]load module default/openharmonyhost failed: Error relocating libopenharmonyhost.so: symbol not found
09-22 10:00:07.400 12345 12345 E A00000/MUSL-LDSO: load /data/storage/el2/base/haps/entry/files/dotnet/libhostfxr.so failed: check ns accessible failed namespace=moduleNs_default
09-22 10:00:07.500 12345 12345 W A00000/Museum: Museum bootstrap diagnostics captured
BOOT_EOF
        fi
        exit 0
        ;;
    *)
        printf 'stub hdc: UNHANDLED %s\n' "$*" >&2
        exit 1
        ;;
esac
STUB_HDC_EOF
chmod 755 "$STUB"

# ---- stub binary-sign-tool ------------------------------------------------------------
BINTOOL="$WORK/bin/binary-sign-tool"
cat > "$BINTOOL" <<'STUB_BINTOOL_EOF'
#!/bin/sh
# Stub binary-sign-tool for selftest-tester-run.sh: simulates the SDK tool's display-sign
# on a third-party lib. Not a real tool.
set -u
case "${1:-}" in
    display-sign)
        printf 'code signature is not found\n'
        exit 0
        ;;
    *)
        printf 'stub binary-sign-tool: UNHANDLED %s\n' "$*" >&2
        exit 1
        ;;
esac
STUB_BINTOOL_EOF
chmod 755 "$BINTOOL"

# ---- fixtures ------------------------------------------------------------------------
FAIL_HAP="$WORK/haps/hello-maui-app-fail.hap"
make_hap "$FAIL_HAP" "com.example.hellomauiapp" "entry"
_i=1
while [ "$_i" -le 4 ]; do
    make_hap "$WORK/probes/hello-mauiapp-probe$_i-unsigned.hap" "com.example.hellomauiapp.probe$_i" "entry"
    _i=$((_i + 1))
done
# extra probes (--extra-probes): the shipping importprobe-a hap plus one whose install fails
EXTRA_PROBE_DIR="$WORK/extra-probes"
EXTRA_PROBE_HAP="$EXTRA_PROBE_DIR/hello-mauiapp-importprobe-a-unsigned.hap"
mkdir -p "$EXTRA_PROBE_DIR"
make_hap "$EXTRA_PROBE_HAP" "com.example.hellomauiapp.importprobea" "entry"
EXTRA_FAIL_DIR="$WORK/extra-probes-fail"
EXTRA_FAIL_HAP="$EXTRA_FAIL_DIR/hello-mauiapp-importprobe-fail-unsigned.hap"
mkdir -p "$EXTRA_FAIL_DIR"
make_hap "$EXTRA_FAIL_HAP" "com.example.hellomauiapp.importprobefail" "entry"
COMPARE_LIB="$WORK/compare/cc-switch-lib.so"
mkdir -p "$(dirname "$COMPARE_LIB")"
printf 'stub third-party lib for --compare-lib (not a real ELF)\n' > "$COMPARE_LIB"

HAVE_PY3=0
MAIN_HAP_MAGIC=""
FAIL_HAP_MAGIC=""
if command -v python3 >/dev/null 2>&1; then
    HAVE_PY3=1
    MAIN_HAP_MAGIC="$(python3 -c 'import re,sys; d=open(sys.argv[1],"rb").read(); print(len(re.findall(bytes.fromhex("20e7d20e"), d)))' "$MAIN_HAP" 2>/dev/null || true)"
    FAIL_HAP_MAGIC="$(python3 -c 'import re,sys; d=open(sys.argv[1],"rb").read(); print(len(re.findall(bytes.fromhex("20e7d20e"), d)))' "$FAIL_HAP" 2>/dev/null || true)"
fi
# kit-selfcheck values are numeric/versioned only when the tester side has python3 or unzip
SELFCHECK_OK=0
if [ "$HAVE_PY3" = 1 ] || command -v unzip >/dev/null 2>&1; then SELFCHECK_OK=1; fi

KIT_TREE="$(kit_tree_digest "$KIT")"
MAIN_HAP_SHA="$(sha256sum "$MAIN_HAP" | cut -d' ' -f1)"
FAIL_HAP_SHA="$(sha256sum "$FAIL_HAP" | cut -d' ' -f1)"
( cd "$KIT" && sha256sum ./*.hap ) > "$WORK/expected-kit-hap-sha.txt" 2>/dev/null || true

# Sandbox: everything tester-run.sh writes must land in $WORK (+ its TMPDIR, which it cleans).
RC=0
run_tester() {
    _tag="$1"; _extra="$2"; shift 2
    ensure_work_dirs
    _log="$LOGS/$_tag.log"
    RC=0
    # $_extra is intentionally unquoted: it carries zero or more `VAR=value` assignments.
    # exec keeps $TESTER_JOB pointing at tester-run.sh itself, so an interrupt can stop it
    # (cleanup kills it and waits) instead of leaving a tester grandchild behind.
    ( cd "$CWD" && exec env HDC="$STUB" TMPDIR="$TMPD" FAKE_HDC_STATE="$STATE_DIR/$_tag" \
        FAKE_HDC_DEVICE="$STUB_DEVICE" PATH="$WORK/bin:$PATH" $_extra sh "$TESTER" "$@" ) > "$_log" 2>&1 &
    TESTER_JOB=$!
    wait "$TESTER_JOB" || RC=$?
    TESTER_JOB=""
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
assert_contains "stub: hilog streams IMPORTPROBE ability line" "IMPORTPROBE: ABILITY_ON_CREATE" "$HILOG_OUT"
assert_contains "stub: hilog streams IMPORTPROBE_A page line" "IMPORTPROBE_A: A PAGE_ABOUT_TO_APPEAR" "$HILOG_OUT"
assert_contains "stub: hilog streams AppKilledReporter" "AppKilledReporter" "$HILOG_OUT"
assert_contains "stub: hilog streams appLibPathKey" "appLibPathKey: com.example.hellomauiapp/entry" "$HILOG_OUT"
assert_contains "stub: hilog streams appLibPathKey lib path" "lib path: /data/storage/el1/bundle/libs/arm64" "$HILOG_OUT"
assert_contains "stub: hilog streams dlopen host line" "dlopen libopenharmonyhost.so" "$HILOG_OUT"

KMSG_OUT="$LOGS/stub-kmsg.out"
FAKE_HDC_STATE="$STATE_DIR/contract-kmsg" "$STUB" shell "hilog -t kmsg" > "$KMSG_OUT" 2>&1 || true
assert_contains "stub: kmsg has xpm unsigned file event" "unsigned file" "$KMSG_OUT"
assert_contains "stub: kmsg has fs_security_verity line" "fs_security_verity" "$KMSG_OUT"

APP_LIBS_OUT="$LOGS/stub-app-libs.out"
FAKE_HDC_STATE="$STATE_DIR/contract-app-libs" "$STUB" shell "ls -l /data/storage/el1/bundle/libs/arm64/ 2>/dev/null" > "$APP_LIBS_OUT" 2>&1 || true
assert_contains "stub: app libs listing has the host lib" "libopenharmonyhost.so" "$APP_LIBS_OUT"
STUB_RC=0
FAKE_HDC_STATE="$STATE_DIR/contract-app-libs-missing" FAKE_HDC_MISSING_APPLIBS=1 \
    "$STUB" shell "ls -l /data/storage/el1/bundle/libs/arm64/ 2>/dev/null" > "$LOGS/stub-app-libs-missing.out" 2>&1 || STUB_RC=$?
assert_eq "stub: missing app libs dir rc=1" "1" "$STUB_RC"

PAYLOAD_LS_OUT="$LOGS/stub-payload-files.out"
FAKE_HDC_STATE="$STATE_DIR/contract-payload" "$STUB" shell "ls -l /data/storage/el2/base/haps/entry/files/ 2>/dev/null" > "$PAYLOAD_LS_OUT" 2>&1 || true
assert_contains "stub: payload listing has the dotnet dir" "files/dotnet" "$PAYLOAD_LS_OUT"
assert_contains "stub: payload listing has dotnet.marker" "dotnet.marker" "$PAYLOAD_LS_OUT"
STUB_RC=0
FAKE_HDC_STATE="$STATE_DIR/contract-payload-missing" FAKE_HDC_MISSING_PAYLOAD=1 \
    "$STUB" shell "ls -l /data/storage/el2/base/haps/entry/files/ 2>/dev/null" > "$LOGS/stub-payload-missing.out" 2>&1 || STUB_RC=$?
assert_eq "stub: missing payload dir rc=1" "1" "$STUB_RC"
MARKER_OUT="$LOGS/stub-payload-marker.out"
FAKE_HDC_STATE="$STATE_DIR/contract-marker" "$STUB" shell "cat /data/storage/el2/base/haps/entry/files/dotnet.marker 2>/dev/null" > "$MARKER_OUT" 2>&1 || true
assert_contains "stub: payload marker has zipSize" "zipSize" "$MARKER_OUT"

BOOT_OUT="$LOGS/stub-bootstrap-hilog.out"
FAKE_HDC_STATE="$STATE_DIR/contract-bootstrap" FAKE_HDC_BOOTSTRAP_ERRORS=1 "$STUB" hilog > "$BOOT_OUT" 2>&1 || true
assert_contains "stub: bootstrap hilog has GetRawFileContent failed" "GetRawFileContent failed" "$BOOT_OUT"
assert_contains "stub: bootstrap hilog has BusinessError 900003" "900003" "$BOOT_OUT"
assert_contains "stub: bootstrap hilog has MUSL-LDSO line" "MUSL-LDSO" "$BOOT_OUT"
assert_not_contains "stub: default hilog stays free of bootstrap failures" "bootstrap failed" "$HILOG_OUT"

FAKE_HDC_STATE="$STATE_DIR/contract-proc" "$STUB" shell "cat /proc/sys/kernel/xpm/xpm_mode" > "$LOGS/stub-xpm-mode.out" 2>&1 || true
assert_eq "stub: xpm_mode answers 2" "2" "$(tr -d '\r\n' < "$LOGS/stub-xpm-mode.out")"
FAKE_HDC_STATE="$STATE_DIR/contract-proc" "$STUB" shell "cat /proc/sys/fs/verity/require_signatures" > "$LOGS/stub-verity.out" 2>&1 || true
assert_eq "stub: require_signatures answers 1" "1" "$(tr -d '\r\n' < "$LOGS/stub-verity.out")"

STUB_RC=0
FAKE_HDC_STATE="$STATE_DIR/contract-proc-missing" FAKE_HDC_MISSING_PROC=1 \
    "$STUB" shell "cat /proc/sys/kernel/xpm/xpm_mode" > "$LOGS/stub-xpm-missing.out" 2>&1 || STUB_RC=$?
assert_eq "stub: missing /proc path rc=1" "1" "$STUB_RC"

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
    --uninstall --install --start --capture 1 --compare-lib "$COMPARE_LIB" --out "$WORK/out-success"
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

    # ELF-signing evidence (research doc §6)
    assert_file "S2 kmsg/kmsg.log in archive" "$REPORT/kmsg/kmsg.log"
    assert_file "S2 kmsg/kmsg-filtered.log in archive" "$REPORT/kmsg/kmsg-filtered.log"
    assert_contains "S2 kmsg raw has unsigned file event" "unsigned file" "$REPORT/kmsg/kmsg.log"
    assert_contains "S2 kmsg raw has fs_security_verity line" "fs_security_verity" "$REPORT/kmsg/kmsg.log"
    assert_contains "S2 kmsg filtered keeps [xpm]" "[xpm]" "$REPORT/kmsg/kmsg-filtered.log"
    assert_contains "S2 kmsg filtered keeps libopenharmonyhost" "libopenharmonyhost.so" "$REPORT/kmsg/kmsg-filtered.log"
    assert_not_contains "S2 kmsg filtered drops unrelated kernel line" "unrelated kmsg line" "$REPORT/kmsg/kmsg-filtered.log"
    assert_eq "S2 summary kmsg_capture=ok" "ok" "$(sum_val "$S" kmsg_capture)"
    assert_gt "S2 summary kmsg_lines > 0" 0 "$(sum_val "$S" kmsg_lines)"
    assert_gt "S2 summary kmsg_filtered_lines > 0" 0 "$(sum_val "$S" kmsg_filtered_lines)"

    # app-lib path evidence (RM1, research doc §8.4)
    assert_file "S2 hilog applib filtered in archive" "$REPORT/hilog/hilog-applib.txt"
    assert_contains "S2 applib filtered has appLibPathKey" "appLibPathKey: com.example.hellomauiapp/entry" "$REPORT/hilog/hilog-applib.txt"
    assert_contains "S2 applib filtered has the lib path" "lib path: /data/storage/el1/bundle/libs/arm64" "$REPORT/hilog/hilog-applib.txt"
    assert_file "S2 hilog dlopen filtered in archive" "$REPORT/hilog/hilog-dlopen.txt"
    assert_contains "S2 dlopen filtered has the host load" "dlopen libopenharmonyhost.so" "$REPORT/hilog/hilog-dlopen.txt"
    assert_eq "S2 summary applib_path_capture=ok" "ok" "$(sum_val "$S" applib_path_capture)"
    assert_gt "S2 summary applib_path_lines > 0" 0 "$(sum_val "$S" applib_path_lines)"
    assert_eq "S2 summary dlopen_capture=ok" "ok" "$(sum_val "$S" dlopen_capture)"
    assert_gt "S2 summary dlopen_lines > 0" 0 "$(sum_val "$S" dlopen_lines)"
    assert_file "S2 device app-libs-arm64.txt in archive" "$REPORT/device/app-libs-arm64.txt"
    assert_contains "S2 app libs listing has the host lib" "libopenharmonyhost.so" "$REPORT/device/app-libs-arm64.txt"
    assert_eq "S2 summary app_libs_arm64=ok" "ok" "$(sum_val "$S" app_libs_arm64)"
    assert_gt "S2 summary app_libs_arm64_lines > 0" 0 "$(sum_val "$S" app_libs_arm64_lines)"

    # kit hap self-check + payload + bootstrap/rawfile evidence (kit #22 findings)
    assert_file "S2 meta/kit-selfcheck.txt in archive" "$REPORT/meta/kit-selfcheck.txt"
    assert_contains "S2 kit-selfcheck names the main hap" "$(basename "$MAIN_HAP")" "$REPORT/meta/kit-selfcheck.txt"
    if [ "$SELFCHECK_OK" = 1 ]; then
        assert_eq "S2 summary kit_index_ok=yes" "yes" "$(sum_val "$S" kit_index_ok)"
        assert_matches "S2 kit-selfcheck reads resources.index size" 'index=[0-9]+ libs=[0-9]+ abc=' "$REPORT/meta/kit-selfcheck.txt"
        assert_matches "S2 kit-selfcheck reads a PANDA abc version" 'abc=[^ :]+:[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$REPORT/meta/kit-selfcheck.txt"
    else
        skip "S2 kit-selfcheck values (no python3/unzip on this host)"
    fi
    assert_file "S2 device payload-files.txt in archive" "$REPORT/device/payload-files.txt"
    assert_contains "S2 payload listing keeps the dotnet dir" "files/dotnet" "$REPORT/device/payload-files.txt"
    assert_contains "S2 payload listing keeps dotnet.marker" "dotnet.marker" "$REPORT/device/payload-files.txt"
    assert_not_contains "S2 payload listing filters unrelated files" "note.txt" "$REPORT/device/payload-files.txt"
    assert_eq "S2 summary payload_present=yes" "yes" "$(sum_val "$S" payload_present)"
    assert_gt "S2 summary payload_files > 0" 0 "$(sum_val "$S" payload_files)"
    assert_eq "S2 summary payload_marker=ok" "ok" "$(sum_val "$S" payload_marker)"
    assert_file "S2 device payload-marker.txt in archive" "$REPORT/device/payload-marker.txt"
    assert_contains "S2 payload marker has zipSize" "zipSize" "$REPORT/device/payload-marker.txt"
    assert_file "S2 hilog-bootstrap.txt in archive" "$REPORT/hilog/hilog-bootstrap.txt"
    assert_eq "S2 summary bootstrap_capture=ok" "ok" "$(sum_val "$S" bootstrap_capture)"
    assert_eq "S2 summary bootstrap_lines=0 (empty tolerated)" "0" "$(sum_val "$S" bootstrap_lines)"
    assert_eq "S2 summary bootstrap_errors=0" "0" "$(sum_val "$S" bootstrap_errors)"
    assert_eq "S2 summary rawfile_errors=0" "0" "$(sum_val "$S" rawfile_errors)"
    assert_eq "S2 summary libload_errors=0" "0" "$(sum_val "$S" libload_errors)"

    assert_eq "S2 summary xpm_mode=2" "2" "$(sum_val "$S" xpm_mode)"
    assert_eq "S2 summary verity_require_signatures=1" "1" "$(sum_val "$S" verity_require_signatures)"
    assert_file "S2 device xpm_mode.txt in archive" "$REPORT/device/xpm_mode.txt"
    assert_file "S2 device require_signatures.txt in archive" "$REPORT/device/require_signatures.txt"
    assert_eq "S2 device xpm_mode.txt content" "2" "$(cat "$REPORT/device/xpm_mode.txt" 2>/dev/null)"
    assert_eq "S2 summary soinfosegment_hap = main hap" "$MAIN_HAP" "$(sum_val "$S" soinfosegment_hap)"
    if [ "$HAVE_PY3" = 1 ]; then
        assert_eq "S2 summary soinfosegment_magic_hits = computed" "$MAIN_HAP_MAGIC" "$(sum_val "$S" soinfosegment_magic_hits)"
    else
        skip "S2 soinfosegment_magic_hits (python3 not available)"
    fi
    assert_file "S2 compare-lib display-sign output in archive" "$REPORT/meta/compare-lib-display-sign.txt"
    assert_contains "S2 compare-lib output says not found" "code signature is not found" "$REPORT/meta/compare-lib-display-sign.txt"
    assert_eq "S2 summary compare_lib path" "$COMPARE_LIB" "$(sum_val "$S" compare_lib)"
    assert_eq "S2 summary compare_lib_display_sign" "code signature is not found" "$(sum_val "$S" compare_lib_display_sign)"

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
assert_contains "S2 stub joined device command for aa start" "aa start -a EntryAbility -b com.example.hellomauiapp" "$STATE_DIR/S2/device-shell.log"
assert_contains "S2 stub called hilog -r" "shell hilog -r" "$CALLS_S2"
assert_contains "S2 stub called param get" "shell param get const.product.model" "$CALLS_S2"
assert_contains "S2 stub called bm get -u" "shell bm get -u" "$CALLS_S2"
assert_contains "S2 stub called kmsg stream" "shell hilog -t kmsg" "$CALLS_S2"
assert_contains "S2 stub called xpm_mode cat" "shell cat /proc/sys/kernel/xpm/xpm_mode" "$CALLS_S2"
assert_contains "S2 stub called require_signatures cat" "shell cat /proc/sys/fs/verity/require_signatures" "$CALLS_S2"
assert_contains "S2 stub called app libs ls" "shell ls -l /data/storage/el1/bundle/libs/arm64/" "$CALLS_S2"
assert_contains "S2 stub called payload files ls" "shell ls -l /data/storage/el2/base/haps/entry/files/" "$CALLS_S2"
assert_contains "S2 stub called payload marker cat" "shell cat /data/storage/el2/base/haps/entry/files/dotnet.marker" "$CALLS_S2"
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
    assert_file "S3 kmsg evidence file present" "$REPORT/kmsg/kmsg.log"
    assert_file "S3 kmsg filtered file present" "$REPORT/kmsg/kmsg-filtered.log"
    assert_eq "S3 summary soinfosegment_hap = --hap file" "$FAIL_HAP" "$(sum_val "$S" soinfosegment_hap)"
    if [ "$HAVE_PY3" = 1 ]; then
        assert_eq "S3 summary soinfosegment_magic_hits = --hap count" "$FAIL_HAP_MAGIC" "$(sum_val "$S" soinfosegment_magic_hits)"
    else
        skip "S3 soinfosegment_magic_hits (python3 not available)"
    fi
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
    assert_file "S4 kmsg evidence file present" "$REPORT/kmsg/kmsg.log"
    assert_file "S4 kmsg filtered file present" "$REPORT/kmsg/kmsg-filtered.log"
    assert_gt "S4 summary kmsg_lines > 0" 0 "$(sum_val "$S" kmsg_lines)"
    assert_eq "S4 summary kmsg_capture=ok" "ok" "$(sum_val "$S" kmsg_capture)"
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
    assert_file "S5 kmsg evidence file present" "$REPORT/kmsg/kmsg.log"
    assert_gt "S5 summary kmsg_filtered_lines > 0" 0 "$(sum_val "$S" kmsg_filtered_lines)"
else
    bad "S5 report archive could not be extracted ($ARCHIVE_S5)"
fi
assert_scenario_sandbox "S5"

# ---- S6: missing evidence paths tolerated --------------------------------------------
section "S6 missing /proc paths + missing --compare-lib file + missing app libs dir tolerated"
run_tester S6 "FAKE_HDC_MISSING_PROC=1 FAKE_HDC_MISSING_APPLIBS=1" --kit-dir "$KIT" --install --capture 1 \
    --compare-lib "$WORK/compare/does-not-exist.so" --out "$WORK/out-missing"
assert_eq "S6 exit code 0 (log: $LOGS/S6.log)" "0" "$RC"

ARCHIVE_S6="$(report_archive out-missing)"
assert_file "S6 report archive produced" "$ARCHIVE_S6"
if prepare_report "$ARCHIVE_S6" "$WORK/x-missing" out-missing; then
    S="$REPORT/summary.txt"
    assert_eq "S6 summary xpm_mode <unavailable>" "<unavailable>" "$(sum_val "$S" xpm_mode)"
    assert_eq "S6 summary verity_require_signatures <unavailable>" "<unavailable>" "$(sum_val "$S" verity_require_signatures)"
    assert_eq "S6 device xpm_mode.txt <unavailable>" "<unavailable>" "$(cat "$REPORT/device/xpm_mode.txt" 2>/dev/null)"
    assert_eq "S6 device require_signatures.txt <unavailable>" "<unavailable>" "$(cat "$REPORT/device/require_signatures.txt" 2>/dev/null)"
    assert_eq "S6 summary compare_lib path recorded" "$WORK/compare/does-not-exist.so" "$(sum_val "$S" compare_lib)"
    assert_eq "S6 summary compare_lib_display_sign skipped" "skipped(file not found)" "$(sum_val "$S" compare_lib_display_sign)"
    assert_eq "S6 summary kmsg_capture=ok" "ok" "$(sum_val "$S" kmsg_capture)"
    assert_file "S6 kmsg evidence file present" "$REPORT/kmsg/kmsg.log"
    assert_file "S6 kmsg filtered file present" "$REPORT/kmsg/kmsg-filtered.log"
    assert_eq "S6 missing app libs dir tolerated (empty)" "empty" "$(sum_val "$S" app_libs_arm64)"
    assert_eq "S6 summary app_libs_arm64_lines=0" "0" "$(sum_val "$S" app_libs_arm64_lines)"
    assert_file "S6 device app-libs-arm64.txt kept (empty)" "$REPORT/device/app-libs-arm64.txt"
    assert_eq "S6 summary failures=0 (missing paths tolerated)" "0" "$(sum_val "$S" failures)"
    assert_eq "S6 applib evidence still collected" "ok" "$(sum_val "$S" applib_path_capture)"
    assert_gt "S6 applib path lines > 0" 0 "$(sum_val "$S" applib_path_lines)"
else
    bad "S6 report archive could not be extracted ($ARCHIVE_S6)"
fi
assert_scenario_sandbox "S6"

# ---- S7: extra probes path -----------------------------------------------------------
section "S7 extra probes path (--extra-probes <dir>, comma + repeated forms)"
run_tester S7 "" --kit-dir "$KIT" --uninstall --capture 1 \
    --extra-probes "$EXTRA_PROBE_DIR,$EXTRA_PROBE_DIR" \
    --extra-probes "$EXTRA_PROBE_DIR" --out "$WORK/out-extra"
assert_eq "S7 exit code 0 (log: $LOGS/S7.log)" "0" "$RC"

ARCHIVE_S7="$(report_archive out-extra)"
assert_file "S7 report archive produced" "$ARCHIVE_S7"
if prepare_report "$ARCHIVE_S7" "$WORK/x-extra" out-extra; then
    S="$REPORT/summary.txt"
    assert_eq "S7 summary main bundle unchanged" "com.example.hellomauiapp" "$(sum_val "$S" bundle)"
    assert_eq "S7 summary extra_probes_dirs deduped" "$EXTRA_PROBE_DIR" "$(sum_val "$S" extra_probes_dirs)"
    assert_eq "S7 summary uninstall_extraprobe_importprobe-a=ok" "ok" "$(sum_val "$S" uninstall_extraprobe_importprobe-a)"
    assert_eq "S7 summary extraprobe bundle" "com.example.hellomauiapp.importprobea" "$(sum_val "$S" extraprobe_importprobe-a_bundle)"
    assert_eq "S7 summary extraprobe install=ok" "ok" "$(sum_val "$S" extraprobe_importprobe-a_install)"
    assert_eq "S7 summary extraprobe alive=yes" "yes" "$(sum_val "$S" extraprobe_importprobe-a_alive)"
    assert_eq "S7 summary extraprobe match=marker" "marker" "$(sum_val "$S" extraprobe_importprobe-a_match)"
    assert_gt "S7 summary extraprobe lines > 0" 0 "$(sum_val "$S" extraprobe_importprobe-a_lines)"
    assert_gt "S7 summary extraprobe capture_lines > 0" 0 "$(sum_val "$S" extraprobe_importprobe-a_capture_lines)"
    assert_eq "S7 summary extraprobe result=ok" "ok" "$(sum_val "$S" extraprobe_importprobe-a_result)"
    assert_file "S7 extra probe raw capture in archive" "$REPORT/probes/extra-importprobe-a-hilog.txt"
    assert_contains "S7 extra probe capture has IMPORTPROBE_A" "IMPORTPROBE_A" "$REPORT/probes/extra-importprobe-a-hilog.txt"
    assert_contains "S7 extra probe capture has IMPORTPROBE ability line" "IMPORTPROBE: ABILITY_ON_CREATE" "$REPORT/probes/extra-importprobe-a-hilog.txt"
    assert_file "S7 extra probe lines file in archive" "$REPORT/probes/extra-importprobe-a-lines.txt"
    assert_contains "S7 extra probe lines has the page line" "IMPORTPROBE_A: A PAGE_ABOUT_TO_APPEAR" "$REPORT/probes/extra-importprobe-a-lines.txt"
    assert_contains "S7 probe-all-lines has extra probe line" "IMPORTPROBE_A: A PAGE_ABOUT_TO_APPEAR" "$REPORT/probes/probe-all-lines.txt"
    assert_contains "S7 extra probe install log success" "install bundle successfully" "$REPORT/probes/extra-importprobe-a-install.txt"
    assert_file "S7 extra probe start log in archive" "$REPORT/probes/extra-importprobe-a-start.txt"
    assert_file "S7 kmsg evidence file present" "$REPORT/kmsg/kmsg.log"
    assert_file "S7 hilog applib filtered in archive" "$REPORT/hilog/hilog-applib.txt"
    assert_contains "S7 applib filtered has appLibPathKey" "appLibPathKey" "$REPORT/hilog/hilog-applib.txt"
    assert_eq "S7 summary applib_path_capture=ok" "ok" "$(sum_val "$S" applib_path_capture)"
    assert_gt "S7 summary applib_path_lines > 0" 0 "$(sum_val "$S" applib_path_lines)"
    assert_file "S7 device app-libs-arm64.txt in archive" "$REPORT/device/app-libs-arm64.txt"
else
    bad "S7 report archive could not be extracted ($ARCHIVE_S7)"
fi
assert_eq "S7 extra-probe dir deduped to one install" "1" "$(grep -c -F "install -r $EXTRA_PROBE_HAP" "$STATE_DIR/S7/calls.log" | tr -d ' ')"
assert_contains "S7 stub called extra probe aa start" "shell aa start -a EntryAbility -b com.example.hellomauiapp.importprobea" "$STATE_DIR/S7/calls.log"
assert_contains "S7 stub called extra probe uninstall" "uninstall com.example.hellomauiapp.importprobea" "$STATE_DIR/S7/calls.log"
assert_scenario_sandbox "S7"

# ---- S8: extra probe install failure -------------------------------------------------
section "S8 extra probe install failure recorded and skipped"
run_tester S8 "" --kit-dir "$KIT" --extra-probes "$EXTRA_FAIL_DIR" --out "$WORK/out-extra-fail"
assert_eq "S8 exit code 1 (log: $LOGS/S8.log)" "1" "$RC"

ARCHIVE_S8="$(report_archive out-extra-fail)"
assert_file "S8 archive still produced" "$ARCHIVE_S8"
assert_contains "S8 install failure mentions code:9568297" "code:9568297" "$LOGS/S8.log"
assert_contains "S8 stub rejected extra *fail* hap (rc=1)" "hello-mauiapp-importprobe-fail-unsigned.hap | rc=1" "$STATE_DIR/S8/calls.log"
if prepare_report "$ARCHIVE_S8" "$WORK/x-extra-fail" out-extra-fail; then
    S="$REPORT/summary.txt"
    assert_eq "S8 summary extraprobe result=install_failed" "install_failed" "$(sum_val "$S" extraprobe_importprobe-fail_result)"
    assert_eq "S8 summary extraprobe install=missing (run skipped)" "" "$(sum_val "$S" extraprobe_importprobe-fail_install)"
    assert_gt "S8 summary failures >= 1" 0 "$(sum_val "$S" failures)"
    assert_file "S8 extra probe install log in archive" "$REPORT/probes/extra-importprobe-fail-install.txt"
    assert_contains "S8 extra probe install log has code" "code:9568297" "$REPORT/probes/extra-importprobe-fail-install.txt"
    assert_not_exists "S8 no hilog capture for failed extra probe" "$REPORT/probes/extra-importprobe-fail-hilog.txt"
    assert_eq "S8 main bundle unchanged" "com.example.hellomauiapp" "$(sum_val "$S" bundle)"
else
    bad "S8 report archive could not be extracted ($ARCHIVE_S8)"
fi
assert_scenario_sandbox "S8"

# ---- S9: malicious bundleName payloads are rejected (A1) ------------------------------
# Every payload below is a bundleName read from a hap's module.json (--hap path) or from
# KIT_BUNDLE_NAME. hdc joins argv into one device-side command line, so any of these could
# run on the device if it reached `aa start -b` / `pidof` / uninstall. The script must die
# during kit/step-0 validation, before the first device action; the stub records the
# joined device-side line in <state>/device-shell.log to make a regression visible.
section "S9 malicious bundleName payloads (--hap) rejected before any device command"
S9_TOTAL=0
S9_REJECTED=0
_i=1
while [ "$_i" -le 11 ]; do
    case "$_i" in
        1)  P='com.example.legit; touch PWNED' ;;
        2)  P='com.example.legit && touch PWNED' ;;
        3)  P='com.example.legit$(touch PWNED)' ;;
        4)  P='com.example.legit`touch PWNED`' ;;
        5)  P="com.example.legit$(printf '\n')touch PWNED" ;;
        6)  P='com.example.legit touch PWNED' ;;
        7)  P='com.example.legit"; touch PWNED;"' ;;
        8)  P="com.example.legit'; touch PWNED;'" ;;
        9)  P='com.example.legit\; touch PWNED' ;;
        10) P='com.example.legit\ touch PWNED' ;;
        11) P='../ESCAPED' ;;
    esac
    if [ "$HAVE_PY3" != 1 ]; then
        skip "S9 payload $_i needs python3 for a JSON-safe module.json"
        continue
    fi
    S9_TOTAL=$((S9_TOTAL + 1))
    EVIL_HAP="$WORK/haps/evil-$_i.hap"
    make_hap_json "$EVIL_HAP" "$P" "entry"
    run_tester "S9-$_i" "" --kit-dir "$KIT" --hap "$EVIL_HAP" --install --start --uninstall \
        --out "$WORK/out-evil-$_i"
    _bad=0
    [ "$RC" -ne 0 ] || _bad=1
    grep -Fq -- "bundleName 未通过安全校验" "$LOGS/S9-$_i.log" || _bad=1
    _dev="$(grep -c -e 'install -r' -e 'aa start' -e 'uninstall ' "$STATE_DIR/S9-$_i/calls.log" 2>/dev/null || true)"
    [ "$_dev" = "0" ] || _bad=1
    [ ! -e "$STATE_DIR/S9-$_i/device-shell.log" ] || _bad=1
    if [ "$_bad" = 0 ]; then
        S9_REJECTED=$((S9_REJECTED + 1))
        ok "S9 payload $_i rejected before any device command"
    else
        bad "S9 payload $_i NOT rejected (rc=$RC; see $LOGS/S9-$_i.log and $STATE_DIR/S9-$_i/calls.log)"
    fi
    assert_not_exists "S9 payload $_i creates no PWNED file" "$CWD/PWNED"
    _i=$((_i + 1))
done
assert_eq "S9 all ${S9_TOTAL} malicious payloads rejected" "$S9_TOTAL" "$S9_REJECTED"
S9_ESCAPED="$(find "$WORK" -name 'ESCAPED*' -print 2>/dev/null)"
assert_eq "S9 traversal payload leaves no ESCAPED file" "" "$S9_ESCAPED"

# ---- S9b: valid bundle names still pass (control group) -------------------------------
section "S9b valid bundle names still pass (--hap control group)"
if [ "$HAVE_PY3" = 1 ]; then
    VALID_UNDERSCORE_HAP="$WORK/haps/valid-underscore.hap"
    make_hap_json "$VALID_UNDERSCORE_HAP" "com.example.hello_mauiapp_2" "entry"
    run_tester S9b "" --kit-dir "$KIT" --hap "$VALID_UNDERSCORE_HAP" --install --start --capture 1 \
        --out "$WORK/out-valid-underscore"
    assert_eq "S9b underscore bundle accepted (rc, log: $LOGS/S9b.log)" "0" "$RC"
    assert_contains "S9b stub called aa start with the underscore bundle" \
        "shell aa start -a EntryAbility -b com.example.hello_mauiapp_2" "$STATE_DIR/S9b/calls.log"
    assert_contains "S9b joined device command carries the underscore bundle" \
        "aa start -a EntryAbility -b com.example.hello_mauiapp_2" "$STATE_DIR/S9b/device-shell.log"

    VALID_UPPER_HAP="$WORK/haps/valid-uppercase.hap"
    make_hap_json "$VALID_UPPER_HAP" "com.example.Upper2Case" "entry"
    run_tester S9c "" --kit-dir "$KIT" --hap "$VALID_UPPER_HAP" --install --start --capture 1 \
        --out "$WORK/out-valid-upper"
    assert_eq "S9c uppercase bundle accepted (rc, log: $LOGS/S9c.log)" "0" "$RC"
    assert_contains "S9c stub called aa start with the uppercase bundle" \
        "shell aa start -a EntryAbility -b com.example.Upper2Case" "$STATE_DIR/S9c/calls.log"
    assert_scenario_sandbox "S9b"
    assert_scenario_sandbox "S9c"
else
    skip "S9b/S9c valid-bundle controls need python3"
fi

# ---- S10: KIT_BUNDLE_NAME source validation ------------------------------------------
section "S10 KIT_BUNDLE_NAME payload rejected; valid fallback accepted"
ensure_work_dirs
RC=0
( cd "$CWD" && env HDC="$STUB" TMPDIR="$TMPD" FAKE_HDC_STATE="$STATE_DIR/S10" \
    FAKE_HDC_DEVICE="$STUB_DEVICE" PATH="$WORK/bin:$PATH" \
    KIT_BUNDLE_NAME='com.example.legit; touch PWNED' \
    sh "$TESTER" --kit-dir "$KIT" --install --out "$WORK/out-env" ) > "$LOGS/S10.log" 2>&1 || RC=$?
assert_eq "S10 KIT_BUNDLE_NAME payload rejected (rc, log: $LOGS/S10.log)" "1" "$RC"
assert_contains "S10 rejection names the bundle-name check" "bundleName 未通过安全校验" "$LOGS/S10.log"
assert_not_exists "S10 rejected before any hdc call" "$STATE_DIR/S10/calls.log"
assert_not_exists "S10 creates no PWNED file" "$CWD/PWNED"

if [ "$HAVE_PY3" = 1 ]; then
    # A hap without module.json falls back to KIT_BUNDLE_NAME; a valid one must still work.
    # Use a dedicated minimal kit: the real kit's verify-kit.sh cross-checks KIT_BUNDLE_NAME
    # against its own haps, which would reject the custom fallback for an unrelated reason.
    make_synthetic_kit "$WORK/kit-env"
    NOMOD_HAP="$WORK/haps/no-module.hap"
    python3 - "$NOMOD_HAP" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("not-module.txt", "no module.json here")
PY
    run_tester S10b "KIT_BUNDLE_NAME=com.example.custom.fallback" --kit-dir "$WORK/kit-env" \
        --hap "$NOMOD_HAP" --out "$WORK/out-env-ok"
    assert_eq "S10b valid KIT_BUNDLE_NAME fallback accepted (rc, log: $LOGS/S10b.log)" "0" "$RC"
    assert_contains "S10b fallback bundle used for the plan" "bundle:  com.example.custom.fallback" "$LOGS/S10b.log"
else
    skip "S10b valid fallback control needs python3"
fi
assert_not_exists "S10 creates no ESCAPED file" "$WORK/ESCAPED.txt"

# ---- S11: bootstrap/rawfile failure signatures ---------------------------------------
# The stub switches on the reference failure lines of the device report §4/§7; the archiver must
# keep them verbatim and count them (bootstrap/rawfile/libload) without failing the round.
section "S11 bootstrap/rawfile failure signatures (FAKE_HDC_BOOTSTRAP_ERRORS=1)"
run_tester S11 "FAKE_HDC_BOOTSTRAP_ERRORS=1" --kit-dir "$KIT" --install --capture 1 --out "$WORK/out-bootstrap"
assert_eq "S11 exit code 0 (evidence-only, log: $LOGS/S11.log)" "0" "$RC"

ARCHIVE_S11="$(report_archive out-bootstrap)"
assert_file "S11 report archive produced" "$ARCHIVE_S11"
if prepare_report "$ARCHIVE_S11" "$WORK/x-bootstrap" out-bootstrap; then
    S="$REPORT/summary.txt"
    B="$REPORT/hilog/hilog-bootstrap.txt"
    assert_file "S11 hilog-bootstrap.txt in archive" "$B"
    assert_contains "S11 keeps bootstrap failed line" "bootstrap failed" "$B"
    assert_contains "S11 keeps GetRawFileContent line" "GetRawFileContent failed" "$B"
    assert_contains "S11 keeps BusinessError 900002 line" "900002" "$B"
    assert_contains "S11 keeps ZIP entry 900003 line" "900003" "$B"
    assert_contains "S11 keeps symbol not found line" "symbol not found" "$B"
    assert_contains "S11 keeps MUSL-LDSO namespace line" "check ns accessible failed" "$B"
    assert_contains "S11 keeps Museum line" "Museum" "$B"
    assert_eq "S11 summary bootstrap_capture=ok" "ok" "$(sum_val "$S" bootstrap_capture)"
    assert_eq "S11 summary bootstrap_lines=8" "8" "$(sum_val "$S" bootstrap_lines)"
    assert_eq "S11 summary bootstrap_errors=5" "5" "$(sum_val "$S" bootstrap_errors)"
    assert_eq "S11 summary rawfile_errors=5" "5" "$(sum_val "$S" rawfile_errors)"
    assert_eq "S11 summary libload_errors=2" "2" "$(sum_val "$S" libload_errors)"
    assert_eq "S11 summary failures=0 (signatures are evidence, not a step failure)" "0" "$(sum_val "$S" failures)"
else
    bad "S11 report archive could not be extracted ($ARCHIVE_S11)"
fi
assert_scenario_sandbox "S11"

# ---- S12: missing payload dir + marker tolerated -------------------------------------
section "S12 missing payload dir + marker tolerated (FAKE_HDC_MISSING_PAYLOAD=1)"
run_tester S12 "FAKE_HDC_MISSING_PAYLOAD=1" --kit-dir "$KIT" --install --capture 1 --out "$WORK/out-nopayload"
assert_eq "S12 exit code 0 (log: $LOGS/S12.log)" "0" "$RC"

ARCHIVE_S12="$(report_archive out-nopayload)"
assert_file "S12 report archive produced" "$ARCHIVE_S12"
if prepare_report "$ARCHIVE_S12" "$WORK/x-nopayload" out-nopayload; then
    S="$REPORT/summary.txt"
    assert_file "S12 payload-files.txt kept (empty)" "$REPORT/device/payload-files.txt"
    assert_eq "S12 payload-files.txt is empty" "0" "$(wc -l < "$REPORT/device/payload-files.txt" | tr -d ' ')"
    assert_file "S12 payload-marker.txt kept (empty)" "$REPORT/device/payload-marker.txt"
    assert_eq "S12 payload-marker.txt is empty" "" "$(cat "$REPORT/device/payload-marker.txt" 2>/dev/null)"
    assert_eq "S12 summary payload_present=no" "no" "$(sum_val "$S" payload_present)"
    assert_eq "S12 summary payload_files=0" "0" "$(sum_val "$S" payload_files)"
    assert_eq "S12 summary payload_marker=empty" "empty" "$(sum_val "$S" payload_marker)"
    assert_eq "S12 summary bootstrap_capture=ok (hilog still captured)" "ok" "$(sum_val "$S" bootstrap_capture)"
    assert_eq "S12 summary failures=0 (missing payload tolerated)" "0" "$(sum_val "$S" failures)"
else
    bad "S12 report archive could not be extracted ($ARCHIVE_S12)"
fi
assert_scenario_sandbox "S12"

# ---- S13: kit hap without resources.index + no capture window ------------------------
# Two degradations at once: kit_index_ok=no (the resource-manager root cause of §4.2) and a
# device round without a hilog window (bootstrap counts become <unavailable>, not a fake 0).
section "S13 kit without resources.index -> kit_index_ok=no; no capture -> counts <unavailable>"
make_synthetic_kit "$WORK/kit-noindex"
make_hap "$WORK/kit-noindex/hello-maui-app.hap" "com.example.hellomauiapp" "entry" 0
( cd "$WORK/kit-noindex" && sha256sum hello-maui-app.hap hello-maui-app-api20.hap verify-kit.sh > SHA256SUMS )
run_tester S13 "" --kit-dir "$WORK/kit-noindex" --install --out "$WORK/out-noindex"
assert_eq "S13 exit code 0 (log: $LOGS/S13.log)" "0" "$RC"

ARCHIVE_S13="$(report_archive out-noindex)"
assert_file "S13 report archive produced" "$ARCHIVE_S13"
if prepare_report "$ARCHIVE_S13" "$WORK/x-noindex" out-noindex; then
    S="$REPORT/summary.txt"
    assert_file "S13 meta/kit-selfcheck.txt in archive" "$REPORT/meta/kit-selfcheck.txt"
    if [ "$SELFCHECK_OK" = 1 ]; then
        assert_contains "S13 selfcheck shows index=missing" "index=missing" "$REPORT/meta/kit-selfcheck.txt"
        assert_eq "S13 summary kit_index_ok=no" "no" "$(sum_val "$S" kit_index_ok)"
    else
        skip "S13 kit-selfcheck values (no python3/unzip on this host)"
    fi
    assert_eq "S13 summary bootstrap_capture=not_captured" "not_captured" "$(sum_val "$S" bootstrap_capture)"
    assert_eq "S13 summary bootstrap_errors=<unavailable>" "<unavailable>" "$(sum_val "$S" bootstrap_errors)"
    assert_eq "S13 summary rawfile_errors=<unavailable>" "<unavailable>" "$(sum_val "$S" rawfile_errors)"
    assert_eq "S13 summary payload_present=yes (stub device has a payload)" "yes" "$(sum_val "$S" payload_present)"
    assert_eq "S13 summary failures=0" "0" "$(sum_val "$S" failures)"
else
    bad "S13 report archive could not be extracted ($ARCHIVE_S13)"
fi
assert_scenario_sandbox "S13"

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
