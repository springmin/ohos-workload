#!/bin/sh
# selftest-device-round.sh - fully local selftest for scripts/device-round.sh.
#
# Drives device-round.sh end to end against stubs (hdc / tester-run.sh / sign-for-device.sh)
# in a temp dir: no device, no real hdc, no network, no SDK. Covers:
#   T0 syntax      `sh -n` on device-round.sh and this selftest
#   T1 usage       missing --kit, unknown flag, bad --mode/--capture/--soak-min -> exit 2
#   T2 dry-run     plan printed, kit verified locally, stub hdc/device never touched
#   T3 full round  --suite --soak-min 1: lock acquire/release, signing (main + 2 Blazor
#                  variants), tester-run core/blazor/a11y/dry-run probes, hilog 16M->restore,
#                  step summary, and the evidence tar.gz (summary/steps/log/screenshots)
#   T4 lock busy   a live foreign lock + attempts=1 -> exit 1, no device commands, archive kept
#   T5 stale lock  ownerless lock with old mtime -> reclaimed, round runs
#   T6 jit no hap  --mode jit on an AOT-only kit -> install_start failed, archive still produced
# Env: SELFTEST_TMPDIR work base, SELFTEST_KEEP=1 keep the work dir, SELFTEST_DEVICE_ROUND=<path>.
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="1 (2026-10-05)"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

_self="$0"
case "$_self" in
    */*) ;;
    *) _self="$(command -v "$_self" 2>/dev/null || printf '%s' "$_self")" ;;
esac
SELF_DIR="$(cd "$(dirname "$_self")" && pwd -P)" || { printf 'FATAL: cannot resolve selftest dir\n' >&2; exit 1; }
DR="${SELFTEST_DEVICE_ROUND:-$SELF_DIR/device-round.sh}"
case "$DR" in
    /*) ;;
    *) DR="$PWD/$DR" ;;
esac
[ -f "$DR" ] || { printf 'FATAL: device-round.sh not found: %s\n' "$DR" >&2; exit 1; }
for _t in sha256sum tar grep sed awk mktemp sh python3 zip; do
    command -v "$_t" >/dev/null 2>&1 || { printf 'FATAL: missing command: %s\n' "$_t" >&2; exit 1; }
done

if [ -n "${SELFTEST_TMPDIR:-}" ]; then
    BASE="$SELFTEST_TMPDIR"
elif [ -d /data/storage/el2/base/tmp/opencode ] && [ -w /data/storage/el2/base/tmp/opencode ]; then
    BASE="/data/storage/el2/base/tmp/opencode"
else
    BASE="${TMPDIR:-/tmp}"
fi
mkdir -p "$BASE" 2>/dev/null || BASE="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$BASE/selftest-device-round.XXXXXX" 2>/dev/null || true)"
[ -n "$WORK" ] || { WORK="$BASE/selftest-device-round.$$"; mkdir -p "$WORK"; }
WORK="$(cd "$WORK" && pwd -P)"
KEEP="${SELFTEST_KEEP:-0}"
CHECKS=0
FAILED=0

cleanup() {
    trap - 0 1 2 15
    [ "$FAILED" -gt 0 ] || [ "$KEEP" = 1 ] || rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup 0

check() { # <name> <expected-rc> <actual-rc>
    CHECKS=$((CHECKS + 1))
    if [ "$2" = "$3" ]; then
        printf '  PASS  %s (rc=%s)\n' "$1" "$3"
    else
        FAILED=$((FAILED + 1))
        printf '  FAIL  %s (expected rc=%s, got %s)\n' "$1" "$2" "$3"
    fi
}
check_true() {
    CHECKS=$((CHECKS + 1))
    if [ "$2" = "$3" ]; then
        printf '  PASS  %s (%s)\n' "$1" "$3"
    else
        FAILED=$((FAILED + 1))
        printf '  FAIL  %s (expected %s, got %s)\n' "$1" "$2" "$3"
    fi
}
check_grep() { # <name> <pattern> <file>
    CHECKS=$((CHECKS + 1))
    if grep -Eq -- "$2" "$3" 2>/dev/null; then
        printf '  PASS  %s\n' "$1"
    else
        FAILED=$((FAILED + 1))
        printf '  FAIL  %s (pattern %s not in %s)\n' "$1" "$2" "$3"
    fi
}
check_no_grep() { # <name> <pattern> <file>
    CHECKS=$((CHECKS + 1))
    if grep -Eq -- "$2" "$3" 2>/dev/null; then
        FAILED=$((FAILED + 1))
        printf '  FAIL  %s (unexpected %s in %s)\n' "$1" "$2" "$3"
    else
        printf '  PASS  %s\n' "$1"
    fi
}

# ---- synthetic kit -------------------------------------------------------------------
KIT="$WORK/kit"
BIN="$WORK/bin"
STATE="$WORK/state"
mkdir -p "$KIT" "$BIN" "$STATE"

make_hap() { # <path> <bundle> <mode> [extra-so]
    _p="$1"; _b="$2"; _m="$3"
    _d="$(mktemp -d "$WORK/hap.XXXXXX")"
    printf '{"app":{"bundleName":"%s"},"module":{"name":"entry"}}' "$_b" > "$_d/module.json"
    mkdir -p "$_d/libs/arm64-v8a"
    printf '%s' "$_m" > "$_d/libs/arm64-v8a/runtime-mode.txt"
    printf 'host' > "$_d/libs/arm64-v8a/libopenharmonyhost.so"
    { printf 'PANDA'; printf '\000\000\000\000\000\000\000'; printf '\015\000\001\000'; } > "$_d/ets-modules.abc" 2>/dev/null || true
    mkdir -p "$_d/ets"; mv "$_d/ets-modules.abc" "$_d/ets/modules.abc"
    if [ -n "${4:-}" ]; then printf 'app' > "$_d/libs/arm64-v8a/$4"; fi
    (cd "$_d" && zip -q -r "$_p" .)
    rm -rf "$_d"
}
make_hap "$KIT/hello-maui-app.hap" com.example.hellomauiapp aot libhello-maui-app.so
make_hap "$KIT/hello-maui-app-unsigned.hap" com.example.hellomauiapp aot libhello-maui-app.so
make_hap "$KIT/hello-blazorwasm-host-unsigned.hap" com.example.opendotnet aot
make_hap "$KIT/hello-blazorwasm-host-nocsp-unsigned.hap" com.example.opendotnet aot
printf 'aot\n' > "$KIT/runtime-mode.txt"

cat > "$KIT/verify-kit.sh" <<'EOF'
#!/bin/sh
# synthetic verify-kit stub used by selftest-device-round.sh
for a in "$@"; do
  case "$a" in
    --expect-tree-digest)
      # next arg is the digest; expected value pinned by the selftest
      shift
      [ "${1:-}" = "deadbeef" ] || { echo "tree digest mismatch"; exit 1; }
      ;;
    --anchor-file) shift ;;
  esac
done
echo "tree sha256=deadbeef"
echo "KIT OK"
exit 0
EOF
chmod +x "$KIT/verify-kit.sh"
( cd "$KIT" && sha256sum ./*.hap verify-kit.sh runtime-mode.txt > SHA256SUMS )

# ---- stub tester-run.sh --------------------------------------------------------------
TR="$BIN/tester-run.sh"
cat > "$TR" <<'EOF'
#!/bin/sh
# stub tester-run.sh: records argv, fabricates the summary device-round.sh reads
set -u
STATE="${SELFTEST_STATE:?}"
echo "tester-run $*" >> "$STATE/tester-run.log"
OUT=""
MODE_CORE=0; MODE_BZ=0; MODE_A11Y=0; MODE_DRY=0; MODE_PROBES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift ;;
    --install) MODE_CORE=1 ;;
    --blazor-probe) MODE_BZ=1 ;;
    --a11y-probe) MODE_A11Y=1 ;;
    --dry-run) MODE_DRY=1 ;;
    --probes) MODE_PROBES=1 ;;
  esac
  shift
done
[ -n "$OUT" ] || exit 0
if [ "$MODE_DRY" = 1 ]; then
  echo "完整一轮示例: sh tester-run.sh --kit-dir <kit> --install --start --capture 30"
  exit 0
fi
mkdir -p "$OUT"
if [ "$MODE_CORE" = 1 ]; then
  mkdir -p "$OUT/hilog"
  printf '[1.0] canvas presented (100x100) n=1\n' > "$OUT/hilog/hilog-full.txt"
  {
    echo "start_result=ok"
    echo "process_alive=yes"
    echo "process_pid=4242"
    echo "runtime_mode=aot(hap)"
    echo "kit_sidecar_check=ok"
    echo "verify_kit=ok"
    echo "failures=0"
  } > "$OUT/summary.txt"
fi
if [ "$MODE_BZ" = 1 ]; then
  {
    echo "blazor_install=ok"
    echo "blazor_boot=yes"
    echo "blazor_rendered=yes"
    echo "failures=0"
  } > "$OUT/summary.txt"
fi
if [ "$MODE_A11Y" = 1 ]; then
  mkdir -p "$OUT/a11y"
  {
    echo "a11y_selfcheck=ok"
    echo "a11y_provider_status=1"
    echo "a11y_node_count=70"
    echo "failures=0"
  } > "$OUT/summary.txt"
  printf 'accessibilityStatus: 1 (attached - expected)\naccessibilityNodeCount: 70\n' > "$OUT/a11y/selfcheck.txt"
fi
if [ "$MODE_PROBES" = 1 ]; then
  echo "probes=ok" > "$OUT/summary.txt"
fi
exit 0
EOF
chmod +x "$TR"

# ---- stub sign-for-device.sh ---------------------------------------------------------
SIGN="$BIN/sign-for-device.sh"
cat > "$SIGN" <<'EOF'
#!/bin/sh
set -u
STATE="${SELFTEST_STATE:?}"
OUT=""; UNS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift ;;
    --unsigned) UNS="$2"; shift ;;
  esac
  shift
done
echo "sign $UNS -> $OUT" >> "$STATE/sign.log"
[ -n "$OUT" ] && [ -n "$UNS" ] && cp "$UNS" "$OUT"
exit 0
EOF
chmod +x "$SIGN"

# ---- stub hdc ------------------------------------------------------------------------
HDC="$BIN/hdc"
cat > "$HDC" <<'EOF'
#!/bin/sh
# stub hdc: list/install/file + a small shell command table; every shell call is logged
set -u
STATE="${SELFTEST_STATE:?}"
[ "$1" = "-t" ] && shift 2
CMD="$1"; shift
case "$CMD" in
  list)
    echo "127.0.0.1:35111"
    exit 0 ;;
  install)
    echo "install bundle successfully"
    exit 0 ;;
  file)
    # file recv <remote> <local>; local dirs already exist
    SRC="$2"; DST="$3"
    if [ -f "$STATE/recv-image" ] && case "$SRC" in *.jpeg) true ;; *) false ;; esac; then
      cp "$STATE/recv-image" "$DST"
    elif [ -f "$STATE/recv-override" ]; then
      cp "$STATE/recv-override" "$DST"
    else
      : > "$DST"
    fi
    exit 0 ;;
  shell)
    C="$*"
    printf '%s\n' "$C" >> "$STATE/device-shell.log"
    case "$C" in
      "bm get --udid"*) echo "60CF7B27C58898C4CFE966087EFAACD9365B783F7328B2DBB8252919AE1F8A19" ;;
      "param get const.product.model"*) echo "STUB-MODEL" ;;
      "param get const.ohos.fullname"*) echo "Stub-OS-1.0" ;;
      "power-shell"*) : ;;
      "hilog -g"*) echo "Log type app buffer size is 512.0K" ;;
      "hilog -r"*|"hilog -G"*) : ;;
      "hilog -x"*)
        echo "10-05 09:00:00.000  4242  4242 I A00002 [shell] activation hot seq=3 uri='app://media/probe?from=dr-hot' delivered=1"
        echo "10-05 09:00:00.100  4242  4242 I A00002 [shell] canvas presented (100x100) n=1" ;;
      "hilog"*)
        echo "10-05 09:00:00.000  4242  4242 I A00002 [shell] canvas presented (100x100) n=1"
        echo "10-05 09:00:00.100  4242  4242 I A00002 [host] web slot create: 2"
        echo "10-05 09:00:00.200  4242  4242 I A00002 [shell] web capacity: 4"
        echo "10-05 09:00:00.300  4242  4242 I A00002 [host] web slot destroy: 2"
        echo "10-05 09:00:00.400  4242  4242 I A00002 [host] [maui-capacity] preempted: slot 0" ;;
      "pidof"*) echo "4242" ;;
      "ps -ef"*) echo "root 4242 1 com.example.hellomauiapp" ;;
      "cat /proc/4242/status"*)
        printf 'Name:\tstub\nVmRSS:\t100000 kB\nThreads:\t42\n' ;;
      "ls /proc/4242/fd"*) printf '0\n1\n2\n' ;;
      "ls /data/storage"*) : ;;
      "aa force-stop"*) : ;;
      "aa start"*) echo "start ability successfully." ;;
      "bm dump -n"*) echo '"updateTime": 1700000000' ;;
      "hidumper -e --list"*) : ;;
      "hidumper -s PowerManagerService"*) echo "Current State: AWAKE" ;;
      "hidumper --mem-smaps"*) printf '1000 kB: entry/libs/arm64/libhello-maui-app.so\n' ;;
      "uitest dumpLayout"*) : ;;
      "uitest uiInput click"*) echo "" ;;
      *) : ;;
    esac
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$HDC"

# Synthetic screenshot for the slots green-button detector: three narrow buttons on row 1
# (A/B/C) plus one wide button (Blazor) and no D/E -- exactly the shipped kit sample's shape.
# Without PIL the slots step degrades to skipped and T3 asserts that instead.
HAVE_PIL=0
if python3 -c 'import PIL' >/dev/null 2>&1; then
    HAVE_PIL=1
    python3 - "$STATE/recv-image" <<'PY'
import sys
from PIL import Image, ImageDraw
im = Image.new('RGB', (3120, 2080), (0, 0, 0))
d = ImageDraw.Draw(im)
for x in (692, 1090, 1488):
    d.rectangle([x, 454, x + 388, 512], fill=(60, 170, 100))
d.rectangle([692, 534, 2716, 590], fill=(60, 170, 100))
im.save(sys.argv[1], 'JPEG')
PY
fi

export SELFTEST_STATE="$STATE"
export HDC="$HDC"
export TESTER_RUN="$TR"
export SIGN_FOR_DEVICE="$SIGN"
export DEVICE_ROUND_LOCK="$WORK/.device-lock"
export DEVICE_ROUND_LOCK_ATTEMPTS=2
export DEVICE_ROUND_LOCK_INTERVAL=1
export DEVICE_ROUND_LOCK_STALE=1200
export DEVICE_ROUND_SOAK_TICK=1

run_dr() { # <outdir> <args...>
    _out="$1"; shift
    sh "$DR" "$@" --out "$_out" > "$_out.log" 2>&1
}

# ---- T0 syntax -----------------------------------------------------------------------
section "T0 syntax"
sh -n "$DR"; check "sh -n device-round.sh" 0 $?
sh -n "$SELF_DIR/selftest-device-round.sh"; check "sh -n selftest-device-round.sh" 0 $?

# ---- T1 usage ------------------------------------------------------------------------
section "T1 usage"
run_dr "$WORK/o1"; check "missing --kit -> 2" 2 $?
run_dr "$WORK/o2" --kit "$KIT" --bogus; check "unknown flag -> 2" 2 $?
run_dr "$WORK/o3" --kit "$KIT" --mode fast; check "bad --mode -> 2" 2 $?
run_dr "$WORK/o4" --kit "$KIT" --capture x; check "bad --capture -> 2" 2 $?
run_dr "$WORK/o5" --kit "$KIT" --soak-min x; check "bad --soak-min -> 2" 2 $?

# ---- T2 dry-run ----------------------------------------------------------------------
section "T2 dry-run"
: > "$STATE/device-shell.log"
run_dr "$WORK/o6" --kit "$KIT" --suite --dry-run; check "dry-run -> 0" 0 $?
check_grep "dry-run plan printed" "dry-run 完成" "$WORK/o6.log"
check_true "no device command in dry-run" "0" "$(grep -c . "$STATE/device-shell.log" 2>/dev/null || true)"
[ -d "$WORK/o6/verify" ]; check "dry-run wrote verify log" 0 $?

# ---- T3 full round -------------------------------------------------------------------
section "T3 full round (suite)"
: > "$STATE/device-shell.log"
rm -rf "$WORK/.device-lock"
run_dr "$WORK/o7" --kit "$KIT" --suite --soak-min 1 --capture 1
_rc=$?; check "suite round -> 0" 0 "$_rc"
check_grep "verify ok" "step_verify=ok" "$WORK/o7/summary.txt"
check_grep "core ok" "step_install_start=ok" "$WORK/o7/summary.txt"
check_grep "first frame ok" "step_first_frame=ok" "$WORK/o7/summary.txt"
check_grep "blazor default ok" "step_blazor=ok" "$WORK/o7/summary.txt"
check_grep "a11y ok" "step_a11y=ok" "$WORK/o7/summary.txt"
check_grep "deeplink ok" "step_deeplink=ok" "$WORK/o7/summary.txt"
check_grep "tester-run probe ok" "step_tester_run_probe=ok" "$WORK/o7/summary.txt"
check_grep "soak ok" "step_soak=ok" "$WORK/o7/summary.txt"
check_grep "sidecar reported" "kit_sidecar=(ok|n/a)" "$WORK/o7/summary.txt"
if [ "$HAVE_PIL" = 1 ]; then
    check_grep "slots ok (C add + destroy)" "step_slots=ok" "$WORK/o7/summary.txt"
    check_grep "capacity raw marker archived" "capacity_raw=1" "$WORK/o7/steps.tsv"
else
    check_grep "slots skipped without PIL" "step_slots=skipped" "$WORK/o7/summary.txt"
fi
check_grep "hilog restored" "hilog -G 512K" "$STATE/device-shell.log"
check_grep "core tester-run flags" "--install --start --capture 1" "$STATE/tester-run.log"
check_grep "blazor default signed" "sign .*hello-blazorwasm-host-unsigned.hap" "$STATE/sign.log"
check_grep "blazor nocsp signed" "sign .*hello-blazorwasm-host-nocsp-unsigned.hap" "$STATE/sign.log"
check_grep "main hap signed" "sign .*hello-maui-app-unsigned.hap" "$STATE/sign.log"
check_grep "blazor probe ran twice" "blazor-probe" "$STATE/tester-run.log"
_bz="$(grep -c 'blazor-probe' "$STATE/tester-run.log" 2>/dev/null || true)"
check_true "blazor probe count=2" "2" "$_bz"
_locks="$(find "$WORK" -maxdepth 2 -name '.device-lock' -type d 2>/dev/null | wc -l | tr -d ' ')"
check_true "lock released" "0" "$_locks"
_arch="$(find "$WORK" -maxdepth 1 -name 'o7-*.tar.gz' 2>/dev/null | head -n1)"
CHECKS=$((CHECKS + 1))
if [ -n "$_arch" ] && tar tzf "$_arch" 2>/dev/null | grep -q 'summary.txt'; then
    printf '  PASS  archive contains summary.txt\n'
else
    FAILED=$((FAILED + 1)); printf '  FAIL  archive missing or has no summary.txt\n'
fi
CHECKS=$((CHECKS + 1))
if [ -n "$_arch" ] && tar tzf "$_arch" 2>/dev/null | grep -q 'blazor/default/probe/summary.txt'; then
    printf '  PASS  archive contains nested blazor probe evidence\n'
else
    FAILED=$((FAILED + 1)); printf '  FAIL  archive missing nested blazor evidence\n'
fi

# ---- T4 live foreign lock ------------------------------------------------------------
section "T4 lock busy"
rm -rf "$WORK/.device-lock"
mkdir -p "$WORK/.device-lock"
echo "other-agent.sh 999" > "$WORK/.device-lock/owner"
: > "$STATE/device-shell.log"
run_dr "$WORK/o8" --kit "$KIT" --capture 1
check "live foreign lock -> 1" 1 $?
check_grep "lock timeout recorded" "step_lock=timeout" "$WORK/o8/summary.txt"
check_true "no device command while locked" "0" "$(grep -c 'shell' "$STATE/device-shell.log" 2>/dev/null || true)"
rm -rf "$WORK/.device-lock"

# ---- T5 stale lock reclaim -----------------------------------------------------------
section "T5 stale lock reclaim"
rm -rf "$WORK/.device-lock"
mkdir -p "$WORK/.device-lock"
# ownerless + old mtime -> reclaim path; age via touch -t (portable enough for the selftest)
touch -t 202001010000 "$WORK/.device-lock" 2>/dev/null || sleep 0
run_dr "$WORK/o9" --kit "$KIT" --capture 1 --soak-min 0
check "stale lock reclaimed -> 0" 0 $?
check_grep "lock acquired" "step_lock=ok" "$WORK/o9/summary.txt"
_locks="$(find "$WORK" -maxdepth 2 -name '.device-lock' -type d 2>/dev/null | wc -l | tr -d ' ')"
check_true "stale lock released again" "0" "$_locks"

# ---- T6 jit without a jit hap --------------------------------------------------------
section "T6 jit missing hap"
run_dr "$WORK/o10" --kit "$KIT" --mode jit --capture 1 --soak-min 0
check "jit without hap -> 1" 1 $?
check_grep "install_start failed" "step_install_start=failed" "$WORK/o10/summary.txt"

# ---- T7 quiet edge: soak 0 + no lock -------------------------------------------------
section "T7 no-lock / soak 0"
run_dr "$WORK/o11" --kit "$KIT" --soak-min 0 --no-lock --capture 1
check "no-lock soak0 -> 0" 0 $?
check_grep "soak skipped" "step_soak=skipped" "$WORK/o11/summary.txt"
check_grep "lock skipped" "step_lock=skipped" "$WORK/o11/summary.txt"

# ---- final ---------------------------------------------------------------------------
section "result"
printf 'checks=%s failed=%s work=%s\n' "$CHECKS" "$FAILED" "$WORK"
if [ "$FAILED" -gt 0 ]; then
    printf 'selftest-device-round.sh v%s: FAIL (%s/%s)\n' "$SELFTEST_VERSION" "$FAILED" "$CHECKS"
    exit 1
fi
printf 'selftest-device-round.sh v%s: all %s checks passed\n' "$SELFTEST_VERSION" "$CHECKS"
exit 0
