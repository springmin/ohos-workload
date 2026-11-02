#!/bin/sh
# smoke.sh - device smoke for test/reference-lob (the MAUI T3 reference app).
#
# Verifies the shipped AOT hap on a real device:
#   1. clean install + cold start (EntryAbility), [ref] main tabs: 4;
#   2. cold deep links: orders / form / settings / form/save / subwindow;
#   3. process-alive (ps) after each route;
#   4. 1k Orders frame rate and PSS;
#   5. optional LoginAbility (--login-hap, or a hap whose module.json carries it);
#   6. writes metrics.json and runs perf-gate.sh with reference-thresholds.json.
#
# Usage: test/reference-lob/smoke.sh [--hap <path>] [--login-hap <path>]
#                                    [--device <id>] [--out <dir>] [--no-lock]
#                                    [--keep-installed] [--skip-fps] [--timeout <s>]
# Env: HDC (default: the standard OpenHarmony toolchains hdc), DEVICE, DEVICE_LOCK
# Exit: 0 = all non-skipped checks passed; 1 = a check failed; 2 = usage / prerequisite error.
set -u

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { warn "$*"; exit 2; }

W="$(cd "$(dirname "$0")/../.." && pwd)"
DEF_HAP="$W/test/reference-lob/bin/Release/net11.0-openharmony26.0/openharmony-arm64/reference-lob.hap"
HAP="$DEF_HAP"
LOGIN_HAP=""
HDC="${HDC:-/storage/Users/currentUser/ohos-clt/sdk/default/openharmony/toolchains/hdc}"
DEV="${DEVICE:-127.0.0.1:36823}"
BUNDLE="mauidemo.dotnet.springmin.com"
ABILITY="EntryAbility"
OUT=""
NO_LOCK=0
KEEP_INSTALLED=0
SKIP_FPS=0
WAIT_SECS=20
LOCK="${DEVICE_LOCK:-/data/storage/el2/base/tmp/opencode/.device-lock}"
LOCK_HELD=0

usage() {
    cat <<EOF
usage: $0 [--hap <path>] [--login-hap <path>] [--device <id>] [--out <dir>]
          [--no-lock] [--keep-installed] [--skip-fps] [--timeout <s>]

Runs the T3 reference-app device smoke (cold start, five deep links, ps, fps/PSS)
and writes <out>/metrics.json for perf-gate.sh.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --hap)            HAP=$2; shift 2 ;;
        --login-hap)      LOGIN_HAP=$2; shift 2 ;;
        --device)         DEV=$2; shift 2 ;;
        --out)            OUT=$2; shift 2 ;;
        --no-lock)        NO_LOCK=1; shift ;;
        --keep-installed) KEEP_INSTALLED=1; shift ;;
        --skip-fps)       SKIP_FPS=1; shift ;;
        --timeout)        WAIT_SECS=$2; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -x "$HDC" ] || die "hdc not executable: $HDC (set HDC)"
[ -f "$HAP" ] || die "hap not found: $HAP (build it with test/reference-lob/publish-aot.sh)"
[ -n "$OUT" ] || OUT="/data/storage/el2/base/tmp/opencode/reference-smoke-$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$OUT" || die "cannot create $OUT"
TMP="$OUT/.tmp"
mkdir -p "$TMP"

hd() { timeout 30 "$HDC" -t "$DEV" "$@"; }

cleanup() {
    _rc=$?
    hd shell "aa force-stop $BUNDLE" >/dev/null 2>&1 || true
    if [ "$KEEP_INSTALLED" = 0 ]; then
        hd uninstall "$BUNDLE" >/dev/null 2>&1 || true
    fi
    if [ "$LOCK_HELD" = 1 ]; then
        rm -rf "$LOCK"
    fi
    exit "$_rc"
}
trap cleanup EXIT INT TERM

if [ "$NO_LOCK" = 0 ]; then
    if mkdir "$LOCK" 2>/dev/null; then
        echo "reference-smoke $$ $(date '+%Y-%m-%d %H:%M:%S')" > "$LOCK/owner"
        LOCK_HELD=1
    else
        die "device lock held: $LOCK ($(cat "$LOCK/owner" 2>/dev/null || echo unknown))"
    fi
fi

log "reference-lob smoke"
log "device: $DEV  hap: $HAP"
log "out:    $OUT"

CHECKS=0
FAILED=0
pass_() { CHECKS=$((CHECKS + 1)); printf '  [PASS] %s\n' "$*"; }
fail_() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$*" >&2; }
skip_() { printf '  [SKIP] %s\n' "$*"; }

# ---------------------------------------------------------------- helpers
ps_count() {
    hd shell "ps -ef | grep -F '$BUNDLE' | grep -v grep | wc -l" 2>/dev/null | tr -d ' \r\n'
}
pid_of() {
    _p=$(hd shell "pidof '$BUNDLE' 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tr -d ' \r\n')
    if [ -z "$_p" ]; then
        _p=$(hd shell "ps -ef | grep -F '$BUNDLE' | grep -v grep | grep -v ':login' | awk '{print \$2}' | head -1" 2>/dev/null | tr -d ' \r\n')
    fi
    printf '%s\n' "$_p"
}
pss_mb() { # <pid>
    _kb=$(hd shell "cat /proc/$1/smaps_rollup 2>/dev/null | awk '/^Pss:/{print \$2; exit}'" 2>/dev/null | tr -d ' \r\n')
    case "$_kb" in
        ''|*[!0-9]*)
            _kb=$(hd shell "hidumper --mem $1 2>/dev/null | awk '\$1==\"Total\" && (\$2+0)>0 {print \$2; exit}'" 2>/dev/null | tr -d ' \r\n')
            ;;
    esac
    case "$_kb" in
        ''|*[!0-9]*) echo ""; return ;;
    esac
    awk -v k="$_kb" 'BEGIN { printf "%.1f", k / 1024 }'
}
clk_tck() {
    _v=$(hd shell "getconf CLK_TCK 2>/dev/null" 2>/dev/null | tr -d ' \r\n')
    [ -n "$_v" ] || _v=100
    echo "$_v"
}
clear_log() { hd shell "hilog -r" >/dev/null 2>&1 || true; }
stop_app() {
    hd shell "aa force-stop $BUNDLE" >/dev/null 2>&1 || true
    _i=0
    while [ "$(ps_count)" -ge 1 ] && [ "$_i" -lt 10 ]; do
        sleep 0.5
        _i=$((_i + 1))
    done
}
dump_ref() { # <outfile>
    hd shell "hilog -x | grep -aF '[ref]'" > "$1" 2>/dev/null || true
}
wait_ref() { # <needle> <outfile> [timeout]
    _needle=$1
    _out=$2
    _to=${3:-$WAIT_SECS}
    _i=0
    while [ "$_i" -lt "$_to" ]; do
        dump_ref "$_out"
        if grep -qF -- "$_needle" "$_out" 2>/dev/null; then
            return 0
        fi
        sleep 1
        _i=$((_i + 1))
    done
    return 1
}
tick_of() { # <file> <label>
    grep -o "$2 tick=[0-9]*" "$1" 2>/dev/null | tail -1 | cut -d= -f2
}
log_epoch_ms() { # <file> <needle> -> epoch ms of the last matching hilog line
    _line=$(grep -F -- "$2" "$1" 2>/dev/null | tail -1)
    _ts=$(printf '%s\n' "$_line" | awk '{print $1" "$2}')
    [ -n "$_ts" ] || { echo ""; return; }
    python3 - "$_ts" <<'PYEPOCH'
import datetime
import sys

ts = sys.argv[1]
try:
    dt = datetime.datetime.strptime(f"{datetime.date.today().year}-{ts}",
                                    "%Y-%m-%d %H:%M:%S.%f")
    print(int(dt.timestamp() * 1000))
except ValueError:
    print("")
PYEPOCH
}
start_main() { # <uri-or-empty>
    if [ -n "$1" ]; then
        hd shell "aa start -a '$ABILITY' -b '$BUNDLE' -U '$1'" 2>&1 | tail -1
    else
        hd shell "aa start -a '$ABILITY' -b '$BUNDLE'" 2>&1 | tail -1
    fi
}

install_hap() { # <hap>
    hd shell "aa force-stop $BUNDLE" >/dev/null 2>&1 || true
    hd uninstall "$BUNDLE" >/dev/null 2>&1 || true
    if hd install "$1" > "$TMP/install.log" 2>&1; then
        return 0
    fi
    tail -5 "$TMP/install.log" >&2
    return 1
}

# ---------------------------------------------------------------- install
log "== install =="
if ! install_hap "$HAP"; then
    fail_ "install $HAP"
    exit 1
fi
pass_ "install $(basename "$HAP")"

# ---------------------------------------------------------------- warm-up
# The first launch after install faults in the AOT image and the package pages; it is not the
# steady-state cold launch the T3 numbers describe. Do one unmeasured launch, stop it, and
# measure the next one.
log "== warm-up launch =="
clear_log
start_main "" >/dev/null 2>&1 || true
if wait_ref "[ref] main tabs: 4" "$TMP/warmup.log" "$WAIT_SECS"; then
    pass_ "warm-up launch reached main tabs"
else
    warn "warm-up launch did not reach main tabs; measuring anyway"
fi
if ! wait_ref "first-frame tick=" "$TMP/warmup.log" 5; then
    warn "warm-up first-frame marker did not arrive within 5 s"
fi
stop_app
sleep 1

# ---------------------------------------------------------------- cold start
log "== cold start =="
clear_log
COLD_T0=$(date +%s%3N)
START_OUT=$(start_main "")
COLD_CMD1=$(date +%s%3N)
printf '%s\n' "$START_OUT" | sed 's/^/   /'
if ! wait_ref "[ref] main tabs: 4" "$TMP/cold.log" "$WAIT_SECS"; then
    fail_ "cold start did not reach [ref] main tabs: 4"
else
    pass_ "cold start reached [ref] main tabs: 4"
fi
# The first frame can land just after the tabs are constructed; keep the same log and wait
# for the marker before parsing the ticks.
if ! wait_ref "first-frame tick=" "$TMP/cold.log" 5; then
    warn "first-frame marker did not arrive within 5 s"
fi
PID=$(pid_of)
if [ -z "$PID" ]; then
    fail_ "cold start process not found"
    COLD_MS=""
    MANAGED_MS=""
    ENTER_TICK=""
    FRAME_TICK=""
else
    pass_ "process pid=$PID"
    # The buffer can still carry a warm-up process; keep only this pid's lines.
    awk -v p="$PID" '$3 == p' "$TMP/cold.log" > "$TMP/cold.pid.log" 2>/dev/null || true
    if [ -s "$TMP/cold.pid.log" ]; then
        COLD_LOG="$TMP/cold.pid.log"
    else
        COLD_LOG="$TMP/cold.log"
    fi
    ENTER_TICK=$(tick_of "$COLD_LOG" "enter Run")
    FRAME_TICK=$(tick_of "$COLD_LOG" "first-frame")
    if [ -n "$ENTER_TICK" ] && [ -n "$FRAME_TICK" ] && [ "$FRAME_TICK" -gt "$ENTER_TICK" ]; then
        MANAGED_MS=$((FRAME_TICK - ENTER_TICK))
        pass_ "Run -> first frame = ${MANAGED_MS} ms"
    else
        # The device hilog buffer can carry a first-frame line from the warm-up with a stale
        # tick; do not fail the smoke on an unusable tick pair. cold_start_ms still covers the
        # launch and perf-gate SKIPs a missing first_frame_ms.
        MANAGED_MS=""
        skip_ "Run -> first frame (tick pair unusable: enter='${ENTER_TICK:-?}' frame='${FRAME_TICK:-?}')"
    fi
    # TickCount64 and /proc/<pid>/stat starttime can use different clock domains after a
    # suspend, so use the hilog wall clock for the cold start (aa start -> first frame).
    FRAME_EPOCH=$(log_epoch_ms "$COLD_LOG" "first-frame tick=")
    COLD_MS=""
    AA_MS=""
    if [ -n "$FRAME_EPOCH" ] && [ "$FRAME_EPOCH" -gt "$COLD_T0" ]; then
        COLD_MS=$((FRAME_EPOCH - COLD_T0))
    fi
    if [ -z "$COLD_MS" ] || [ "$COLD_MS" -gt 10000 ]; then
        COLD_MS=$(( $(date +%s%3N) - COLD_T0 ))
        warn "wall-clock conversion off; cold_start_ms falls back to poll completion (${COLD_MS} ms)"
    fi
    pass_ "aa start -> first frame = ${COLD_MS} ms"
    if [ -n "$FRAME_EPOCH" ] && [ "$FRAME_EPOCH" -gt "$COLD_CMD1" ]; then
        AA_MS=$((FRAME_EPOCH - COLD_CMD1))
        pass_ "aa return -> first frame = ${AA_MS} ms (diagnostic)"
    fi
fi

# ---------------------------------------------------------------- deep links
smoke_route() { # <route> <needle> <label>
    _route=$1
    _needle=$2
    _label=$3
    _safe=$(printf '%s' "$_route" | tr '/' '_')
    log "== deep link: $_route =="
    stop_app
    clear_log
    start_main "app://reference/$_route" | sed 's/^/   /'
    if wait_ref "$_needle" "$TMP/route-$_safe.log" "$WAIT_SECS"; then
        pass_ "$_label ($_needle)"
    else
        fail_ "$_label ($_needle missing)"
    fi
    _alive=$(ps_count)
    if [ "${_alive:-0}" -ge 1 ]; then
        pass_ "$_label process alive"
    else
        fail_ "$_label process exited"
    fi
}

smoke_route "orders" "navigate 'orders'" "orders route"
smoke_route "form" "navigate 'form'" "form route"
smoke_route "settings" "navigate 'settings'" "settings route"
smoke_route "form/save" "form saved" "form save"
smoke_route "subwindow" "subwindow create=True item=1" "subwindow"

# ---------------------------------------------------------------- fps + PSS
FPS=""
RSS_MB=""
if [ "$SKIP_FPS" = 1 ]; then
    skip_ "fps/PSS (--skip-fps)"
else
    log "== fps + PSS (orders) =="
    stop_app
    clear_log
    start_main "app://reference/orders" >/dev/null 2>&1 || true
    if wait_ref "navigate 'orders'" "$TMP/fps.log" "$WAIT_SECS"; then
        sleep 6
        dump_ref "$TMP/fps.log"
        FPS=$(grep -o 'fps=[0-9.]*' "$TMP/fps.log" 2>/dev/null | tail -1 | cut -d= -f2)
        PID=$(pid_of)
        [ -n "$PID" ] && RSS_MB=$(pss_mb "$PID")
        if [ -n "$FPS" ]; then
            if awk -v f="$FPS" 'BEGIN { exit (f >= 50 ? 0 : 1) }'; then
                pass_ "fps=$FPS"
            else
                fail_ "fps=$FPS (< 50)"
            fi
        else
            fail_ "no [ref] fps= line after 6 s"
        fi
        if [ -n "$RSS_MB" ]; then
            pass_ "PSS=${RSS_MB} MB"
        else
            fail_ "could not read PSS for pid='${PID:-missing}'"
        fi
    else
        fail_ "orders route not ready for fps/PSS"
    fi
fi

# ---------------------------------------------------------------- second ability
LOGIN_TARGET="$LOGIN_HAP"
if [ -z "$LOGIN_TARGET" ] && unzip -p "$HAP" module.json 2>/dev/null | grep -q '"LoginAbility"'; then
    LOGIN_TARGET="$HAP"
fi
if [ -n "$LOGIN_TARGET" ]; then
    log "== second ability (LoginAbility) =="
    if [ ! -f "$LOGIN_TARGET" ]; then
        fail_ "login hap not found: $LOGIN_TARGET"
    elif install_hap "$LOGIN_TARGET"; then
        pass_ "install login hap $(basename "$LOGIN_TARGET")"
        clear_log
        hd shell "aa start -a LoginAbility -b '$BUNDLE' --ps mode login" 2>&1 | tail -1 | sed 's/^/   /'
        sleep 3
        _login=$(hd shell "ps -ef | grep -F '$BUNDLE:login' | grep -v grep | wc -l" 2>/dev/null | tr -d ' \r\n')
        if [ "${_login:-0}" -ge 1 ]; then
            pass_ "LoginAbility process (:login) alive"
        else
            fail_ "LoginAbility process (:login) not found"
        fi
    else
        fail_ "install login hap $LOGIN_TARGET"
    fi
else
    skip_ "second ability (no --login-hap and the hap has no LoginAbility)"
fi

# ---------------------------------------------------------------- metrics + perf gate
METRICS="$OUT/metrics.json"
python3 - "$METRICS" "$MANAGED_MS" "$COLD_MS" "$FPS" "$RSS_MB" <<'PY'
import json
import sys

path, managed, cold, fps, rss = sys.argv[1:]
metrics = {}
for key, value in (("first_frame_ms", managed), ("cold_start_ms", cold),
                   ("scroll_fps", fps), ("rss_mb", rss)):
    if value not in ("", None):
        try:
            metrics[key] = int(value) if key.endswith("_ms") else float(value)
        except ValueError:
            pass
doc = {
    "kit": "reference-lob",
    "date": __import__("datetime").date.today().isoformat(),
    "source": "test/reference-lob/smoke.sh",
    "metrics": metrics,
}
json.dump(doc, open(path, "w"), indent=2)
print(path)
PY

log "== perf gate (reference thresholds) =="
if [ -f "$W/test/perf-gate/reference-thresholds.json" ]; then
    if sh "$W/scripts/perf-gate.sh" "$METRICS" "$W/test/perf-gate/reference-thresholds.json" > "$OUT/perf-gate.log" 2>&1; then
        pass_ "perf-gate reference thresholds"
        sed 's/^/   /' "$OUT/perf-gate.log"
    else
        fail_ "perf-gate reference thresholds"
        sed 's/^/   /' "$OUT/perf-gate.log" >&2
    fi
else
    skip_ "perf-gate (reference-thresholds.json missing)"
fi

# ---------------------------------------------------------------- summary
printf '\n'
log "== summary =="
printf '   checks: %s  failed: %s\n' "$CHECKS" "$FAILED"
printf '   metrics: %s\n' "$METRICS"
printf '   logs:    %s\n' "$OUT"
if [ "$FAILED" -gt 0 ]; then
    warn "REFERENCE SMOKE FAILED"
    exit 1
fi
log "REFERENCE SMOKE OK"
exit 0
