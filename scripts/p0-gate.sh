#!/bin/sh
# p0-gate.sh - host-side regression gate for the MAUI on OpenHarmony P0 workstreams.
#
# Quick (default):
#   * perf-gate comparator fixture (selftest-perf-gate.sh; no device needed)
#   * upstream delta drift (check-upstream-delta.sh; skipped when maui-ohos/baseline is absent)
#   * compat source pins (CommunityToolkit.Maui 15.0.1 + the five probe cases + handler hook)
#   * reference-app source pins (MainTabs/pending route/deep links/form save/subwindow/login shell)
#   * optional real device metrics: --metrics <json> runs perf-gate.sh in strict mode
#
# Full (--full):
#   * everything above
#   * NativeAOT publish of test/maui-compat-app, then test/reference-lob, with the IL gate
#     (IL2026/IL3050/IL3051 checked against test/p0-gate/il-budget.json) and a hap check
#   The publishes are host-only but heavy; when MemAvailable is below 2 GB they are SKIPped
#   (the publish scripts would refuse to start anyway). A device round is still manual:
#   see runtime-ohos docs/plans/2026-10-30-ohos-maui-reference-app.md.
#
# Usage: scripts/p0-gate.sh [--quick|--full] [--skip-perf] [--skip-delta]
#                           [--skip-compat] [--skip-reference] [--metrics <json>]
# Env: MAUI_SLICE_REPO, DOTNET, P0_GATE_LOG_DIR
# Exit: 0 = every non-skipped step passed; 1 = at least one step failed; 2 = usage error.
set -u

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

W="$(cd "$(dirname "$0")/.." && pwd)"
MODE=quick
SKIP_PERF=0
SKIP_DELTA=0
SKIP_COMPAT=0
SKIP_REFERENCE=0
AOT_COMPAT=0
AOT_REFERENCE=0
METRICS=""

usage() {
    cat <<EOF
usage: $0 [--quick|--full] [--skip-perf] [--skip-delta] [--skip-compat]
          [--skip-reference] [--metrics <json>]

  --quick (default)  perf fixture + delta drift + compat/reference source pins
  --full             also NativeAOT-publish compat and reference (IL gate must be 0)
  --metrics <json>   compare a real device-round metrics JSON with the perf thresholds

Exit: 0 = every non-skipped step passed; 1 = at least one failed; 2 = usage error.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --quick)          MODE=quick; AOT_COMPAT=0; AOT_REFERENCE=0; shift ;;
        --full)           MODE=full; AOT_COMPAT=1; AOT_REFERENCE=1; shift ;;
        --skip-perf)      SKIP_PERF=1; shift ;;
        --skip-delta)     SKIP_DELTA=1; shift ;;
        --skip-compat)    SKIP_COMPAT=1; AOT_COMPAT=0; shift ;;
        --skip-reference) SKIP_REFERENCE=1; AOT_REFERENCE=0; shift ;;
        --metrics)        METRICS=$2; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *) warn "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
done

LOG_DIR="${P0_GATE_LOG_DIR:-/data/storage/el2/base/tmp/opencode/p0-gate-$(date '+%Y%m%d-%H%M%S')}"
mkdir -p "$LOG_DIR" || { warn "cannot create log dir: $LOG_DIR"; exit 1; }

# The rc.2 line is the supported build for this tree; keep an explicit DOTNET override.
if [ -z "${DOTNET:-}" ] && [ -x "$HOME/.dotnet.rc2-105/dotnet" ]; then
    DOTNET="$HOME/.dotnet.rc2-105/dotnet"
fi
[ -n "${DOTNET:-}" ] && export DOTNET

ST_PERF="SKIP"
ST_DELTA="SKIP"
ST_COMPAT="SKIP"
ST_REFERENCE="SKIP"
ST_METRICS="SKIP"
FAILED=0

log "P0 gate ($MODE)"
log "repo: $W"
log "logs: $LOG_DIR"

# ---------------------------------------------------------------- perf comparator fixture
if [ "$SKIP_PERF" = 1 ]; then
    ST_PERF="SKIP (--skip-perf)"
elif [ ! -f "$W/scripts/selftest-perf-gate.sh" ]; then
    warn "missing scripts/selftest-perf-gate.sh"
    ST_PERF="FAIL (missing selftest)"
    FAILED=$((FAILED + 1))
else
    log "== perf-gate fixture =="
    if sh "$W/scripts/selftest-perf-gate.sh" > "$LOG_DIR/selftest-perf-gate.log" 2>&1; then
        tail -2 "$LOG_DIR/selftest-perf-gate.log" | sed 's/^/   /'
        ST_PERF="PASS ($(grep -c '\[PASS\]' "$LOG_DIR/selftest-perf-gate.log" || true) checks)"
    else
        sed 's/^/   /' "$LOG_DIR/selftest-perf-gate.log" | tail -20 >&2
        ST_PERF="FAIL (fixture)"
        FAILED=$((FAILED + 1))
    fi
fi

# ---------------------------------------------------------------- optional real metrics
if [ -n "$METRICS" ]; then
    log "== device metrics: $METRICS =="
    if sh "$W/scripts/perf-gate.sh" "$METRICS" > "$LOG_DIR/perf-metrics.log" 2>&1; then
        grep -E 'PASS|FAIL|SKIP' "$LOG_DIR/perf-metrics.log" | sed 's/^/   /'
        ST_METRICS="PASS"
    else
        sed 's/^/   /' "$LOG_DIR/perf-metrics.log" | tail -20 >&2
        ST_METRICS="FAIL (regression)"
        FAILED=$((FAILED + 1))
    fi
fi

# ---------------------------------------------------------------- upstream delta drift
if [ "$SKIP_DELTA" = 1 ]; then
    ST_DELTA="SKIP (--skip-delta)"
else
    log "== upstream delta drift =="
    sh "$W/scripts/check-upstream-delta.sh" > "$LOG_DIR/upstream-delta.log" 2>&1
    DELTA_RC=$?
    if [ "$DELTA_RC" -eq 0 ]; then
        grep '^  PASS' "$LOG_DIR/upstream-delta.log" | sed 's/^/   /'
        ST_DELTA="PASS (within tolerance)"
    elif [ "$DELTA_RC" -eq 3 ]; then
        tail -1 "$LOG_DIR/upstream-delta.log" | sed 's/^/   /'
        ST_DELTA="SKIP (maui-ohos or baseline absent)"
    else
        sed 's/^/   /' "$LOG_DIR/upstream-delta.log" | tail -20 >&2
        ST_DELTA="FAIL (drift)"
        FAILED=$((FAILED + 1))
    fi
fi

# ---------------------------------------------------------------- compat source pins
if [ "$SKIP_COMPAT" = 0 ]; then
    log "== compat source pins =="
    python3 - "$W" <<'PY'
import pathlib
import re
import sys

w = pathlib.Path(sys.argv[1])
root = w / "test" / "maui-compat-app"
checks = []


def check(name, ok, detail=""):
    checks.append(ok)
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}{(' — ' + detail) if detail and not ok else ''}")


csproj = (root / "maui-compat-app.csproj").read_text()
app = (root / "App.cs").read_text()
program = (root / "Program.cs").read_text()

check("CommunityToolkit.Maui 15.0.1 pinned",
      bool(re.search(r'Include="CommunityToolkit\.Maui"\s+Version="15\.0\.1"', csproj)))
for case in ("EXPANDER", "AVATAR", "DRAWING", "TOUCH", "POPUP"):
    check(f"compat case {case.lower()}", f"#elif COMPAT_{case}" in app)
check("DrawingView handler registered",
      "OpenHarmonyHandlerConnector.RegisterHandler" in program
      and "CompatDrawingViewHandler" in program)
check("toolkit registered", "UseMauiCommunityToolkit" in program)
check("TouchBehavior compat shim present", (root / "CompatTouchBehavior.cs").is_file())
check("AOT publish script present", (root / "publish-aot.sh").is_file())

sys.exit(0 if all(checks) else 1)
PY
    if [ "$?" -eq 0 ]; then
        ST_COMPAT="PASS (source pins)"
    else
        ST_COMPAT="FAIL (source pins)"
        FAILED=$((FAILED + 1))
    fi
fi

# ---------------------------------------------------------------- reference source pins
if [ "$SKIP_REFERENCE" = 0 ]; then
    log "== reference-app source pins =="
    python3 - "$W" <<'PY'
import pathlib
import sys

w = pathlib.Path(sys.argv[1])
ref = w / "test" / "reference-lob"
checks = []


def check(name, ok):
    checks.append(ok)
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}")


app = (ref / "App.cs").read_text()
pages = (ref / "Pages.cs").read_text()

check("MainTabs root", "class MainTabs" in app)
check("pending deep-link route", "ConsumePendingRoute" in app and '"app://reference/"' in app)
check("deep link orders", '"orders" or "list" =>' in app)
check("deep link form", '"form" =>' in app)
check("deep link settings", '"settings" =>' in app)
check("deep link subwindow", 'case "subwindow":' in app)
check("form save path", "form saved" in pages)
check("subwindow path", "subwindow create=" in pages)
check("1k list path", "new List<Item>(1000)" in app and "i <= 1000" in app)
check("AOT publish script present", (ref / "publish-aot.sh").is_file())
check("device smoke script present", (w / "test" / "reference-lob" / "smoke.sh").is_file())
check("reference thresholds present", (w / "test" / "perf-gate" / "reference-thresholds.json").is_file())
check("second-ability shell sources", (w / "scripts" / "loginability" / "LoginAbility.ets").is_file())
check("second-ability packer", (w / "scripts" / "add-login-ability.sh").is_file())

sys.exit(0 if all(checks) else 1)
PY
    if [ "$?" -eq 0 ]; then
        ST_REFERENCE="PASS (source pins)"
    else
        ST_REFERENCE="FAIL (source pins)"
        FAILED=$((FAILED + 1))
    fi
fi

# ---------------------------------------------------------------- NativeAOT publishes
set_aot_status() { # <name> <value>
    case "$1" in
        compat)    ST_COMPAT_AOT=$2 ;;
        reference) ST_REFERENCE_AOT=$2 ;;
    esac
}

run_aot() { # <name> <project-dir> <budget-key>
    name=$1
    dir=$2
    budget_key=$3
    script="$W/test/$dir/publish-aot.sh"
    if [ ! -f "$script" ]; then
        warn "$name: missing $script"
        set_aot_status "$name" "FAIL (missing publish script)"
        FAILED=$((FAILED + 1))
        return
    fi
    avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    if [ "${avail:-0}" -lt 2097152 ]; then
        warn "$name: MemAvailable=${avail}kB < 2 GB; AOT publish skipped"
        set_aot_status "$name" "SKIP (memory ${avail}kB)"
        return
    fi
    if [ ! -d "${MAUI_SLICE_DIR:-$W/../maui-ohos/src/Core/src/Platform/OpenHarmony}" ]; then
        warn "$name: maui-ohos slice missing; AOT publish skipped"
        set_aot_status "$name" "SKIP (no maui slice)"
        return
    fi
    log "== $name NativeAOT publish =="
    AOT_WORKDIR="$LOG_DIR/$name-aot" sh "$script" > "$LOG_DIR/$name-aot.out" 2>&1
    rc=$?
    plog="$LOG_DIR/$name-aot/publish-aot.log"
    ok=1
    [ "$rc" -eq 0 ] || ok=0
    [ -f "$plog" ] || ok=0
    if [ -f "$plog" ]; then
        grep -qx 'EXIT=0' "$plog" || ok=0
        budget=$(python3 - "$W/test/p0-gate/il-budget.json" "$budget_key" <<'PYBUDGET'
import json, sys
print(" ".join(str(json.load(open(sys.argv[1]))["budgets"][sys.argv[2]][w])
                 for w in ("IL2026", "IL3050", "IL3051")))
PYBUDGET
)
        set -- $budget
        l26=${1:-missing}; l50=${2:-missing}; l51=${3:-missing}
        for pair in "IL2026 $l26" "IL3050 $l50" "IL3051 $l51"; do
            w=${pair% *}
            lim=${pair#* }
            act=$(grep -E "^$w [0-9]+$" "$plog" | tail -1 | awk '{print $2}')
            if [ -n "$act" ] && [ "$lim" != missing ] && [ "$act" -le "$lim" ]; then
                printf '   PASS %-7s actual=%s budget=%s\n' "$w" "$act" "$lim"
            else
                printf '   FAIL %-7s actual=%s budget=%s\n' "$w" "${act:-missing}" "$lim"
                ok=0
            fi
        done
        grep -qx 'EXIT=0' "$plog" || printf '   FAIL EXIT line missing or non-zero\n'
    fi
    haps=$(ls "$W/test/$dir/bin/Release/"*/*/*.hap 2>/dev/null | wc -l)
    [ "$haps" -ge 1 ] || ok=0
    if [ "$ok" -eq 1 ]; then
        ls -la "$W/test/$dir/bin/Release/"*/*/*.hap 2>/dev/null | sed 's/^/   /'
        set_aot_status "$name" "PASS (IL budget, haps=$haps)"
    else
        [ -f "$plog" ] && tail -20 "$plog" | sed 's/^/   /' >&2
        warn "$name: AOT publish failed (rc=$rc, log: $plog)"
        set_aot_status "$name" "FAIL (AOT)"
        FAILED=$((FAILED + 1))
    fi
}

if [ "$AOT_COMPAT" = 1 ] && [ "$SKIP_COMPAT" = 0 ]; then
    run_aot compat maui-compat-app compat
fi
if [ "$AOT_REFERENCE" = 1 ] && [ "$SKIP_REFERENCE" = 0 ]; then
    run_aot reference reference-lob reference
fi

# ---------------------------------------------------------------- summary
log "== summary =="
summary_line() { printf '   %-32s %s\n' "$1" "$2"; }
summary_line "perf-gate fixture" "$ST_PERF"
[ -n "$METRICS" ] && summary_line "device metrics" "$ST_METRICS"
summary_line "upstream delta" "$ST_DELTA"
summary_line "compat pins" "$ST_COMPAT"
summary_line "reference pins" "$ST_REFERENCE"
[ "$AOT_COMPAT" = 1 ] && summary_line "compat AOT" "$ST_COMPAT_AOT"
[ "$AOT_REFERENCE" = 1 ] && summary_line "reference AOT" "$ST_REFERENCE_AOT"
log "   logs: $LOG_DIR"

if [ "$FAILED" -gt 0 ]; then
    warn "P0 GATE FAILED — $FAILED step(s) failed"
    exit 1
fi
log "P0 GATE OK — every non-skipped step is green"
exit 0
