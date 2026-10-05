#!/bin/sh
# Device-side helper for the minimal a11y client build (test/a11y-client). Shows the current
# accessibility state and runs the companion ability probe; it never enables the extension by
# itself (this build of the platform has no third-party enable path - see docs).
#
#   scripts/run-a11y-client.sh [--probe] [--capture <seconds>] [--status] [--out <dir>]
#
#   --probe            start EntryAbility and collect the A11YCLIENT probe lines
#   --capture <sec>    stream hilog for <sec> seconds into <out>/hilog.txt (for manual runs)
#   --status           dump AccessibilityManagerService -u / -c
#   --out <dir>        evidence directory (default: /data/storage/el2/base/tmp/opencode/a11y-client/run)
# Default action (no flags): --status --probe.
set -e
W="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="com.example.a11yclient"
ABILITY="EntryAbility"
HDC="${HDC:-$(command -v hdc 2>/dev/null || printf '%s' "$HOME/ohos-clt/sdk/default/openharmony/toolchains/hdc")}"
OUT="${A11Y_RUN_OUT:-/data/storage/el2/base/tmp/opencode/a11y-client/run}"

PROBE=0
STATUS=0
CAPTURE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --probe) PROBE=1; shift ;;
        --status) STATUS=1; shift ;;
        --capture) CAPTURE="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[ "$PROBE" = 1 ] || [ "$STATUS" = 1 ] || [ "$CAPTURE" != 0 ] || { STATUS=1; PROBE=1; }

info() { printf '==> %s\n' "$*"; }
info "device: $("$HDC" shell 'param get const.product.model' 2>/dev/null | tr -d '\r') / $("$HDC" shell 'param get const.product.software.version' 2>/dev/null | tr -d '\r')"

if [ "$STATUS" = 1 ]; then
    mkdir -p "$OUT"
    "$HDC" shell "hidumper -s AccessibilityManagerService -a '-u'" > "$OUT/ams-user.txt" 2>&1
    "$HDC" shell "hidumper -s AccessibilityManagerService -a '-c'" > "$OUT/ams-clients.txt" 2>&1
    grep -E 'accessible:|touchGuide:|screenMagnification:|shortKey:' "$OUT/ams-user.txt" | sed 's/^/    /' || true
    tail -1 "$OUT/ams-clients.txt" | sed 's/^/    /'
    info "saved $OUT/ams-user.txt, $OUT/ams-clients.txt"
fi

if [ "$PROBE" = 1 ]; then
    mkdir -p "$OUT"
    "$HDC" shell "aa force-stop $BUNDLE >/dev/null 2>&1; hilog -r >/dev/null 2>&1; aa start -a $ABILITY -b $BUNDLE >/dev/null 2>&1; sleep 4; hilog -x 2>/dev/null | grep -F 'A11YCLIENT'" \
        > "$OUT/probe.txt" 2>&1 || true
    if [ -s "$OUT/probe.txt" ]; then
        cat "$OUT/probe.txt" | sed 's/^/    /'
    else
        info "no A11YCLIENT lines captured (is the bundle installed? run: scripts/build-a11y-client.sh --install)"
    fi
    info "saved $OUT/probe.txt"
fi

if [ "$CAPTURE" != 0 ]; then
    mkdir -p "$OUT"
    info "capturing hilog for ${CAPTURE}s into $OUT/hilog-all.txt (run the target app meanwhile)"
    "$HDC" hilog > "$OUT/hilog-all.txt" 2>/dev/null &
    HILOG_PID=$!
    sleep "$CAPTURE"
    kill "$HILOG_PID" 2>/dev/null || true
    wait "$HILOG_PID" 2>/dev/null || true
    grep -E 'A11YCLIENT|A11yClient|\[maui\] accessibility|accessibility provider' "$OUT/hilog-all.txt" > "$OUT/hilog.txt" 2>/dev/null || true
    info "captured $(wc -l < "$OUT/hilog.txt" 2>/dev/null || echo 0) matching line(s): $OUT/hilog.txt"
fi
