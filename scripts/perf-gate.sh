#!/bin/sh
# perf-gate.sh - compare a MAUI-on-OpenHarmony metrics JSON against the kit thresholds.
#
# Usage:
#   scripts/perf-gate.sh [--report-only] <metrics.json> [thresholds.json]
#
# Defaults to test/perf-gate/thresholds.json next to this script's repository root.
# Exit: 0 = all metrics within bounds (or --report-only), 1 = at least one regression,
#       2 = usage / input error.
#
# The metrics file is the output of a device round; keep the shape:
#   { "kit": 58, "metrics": { "first_frame_ms": 534, "cold_start_ms": 3200,
#     "scroll_fps": 60.0, "rss_mb": 363, "kit_tar_bytes": 70449999,
#     "suite_pass": 826, "suite_total": 829 } }
set -u

report_only=0
if [ "${1:-}" = "--report-only" ]; then
    report_only=1
    shift
fi

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    sed -n '2,14p' "$0"
    exit 2
fi

metrics=$1
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
thresholds=${2:-"$here/../test/perf-gate/thresholds.json"}

[ -f "$metrics" ] || { echo "perf-gate: no metrics file: $metrics" >&2; exit 2; }
[ -f "$thresholds" ] || { echo "perf-gate: no thresholds file: $thresholds" >&2; exit 2; }

python3 - "$metrics" "$thresholds" "$report_only" <<'PY'
import json
import sys

metrics_path, thresholds_path, report_only = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
try:
    doc = json.load(open(metrics_path))
    metrics = doc.get("metrics", doc)
    thresholds = json.load(open(thresholds_path))
except (OSError, ValueError) as exc:
    print(f"perf-gate: cannot read input: {exc}", file=sys.stderr)
    sys.exit(2)

checks = [
    ("first_frame_ms", "max_first_frame_ms", "max", "ms"),
    ("cold_start_ms", "max_cold_start_ms", "max", "ms"),
    ("scroll_fps", "min_scroll_fps", "min", "fps"),
    ("rss_mb", "max_rss_mb", "max", "MB"),
    ("kit_tar_bytes", "max_kit_tar_bytes", "max", "B"),
    ("suite_pass", "min_suite_pass", "min", ""),
]

kit = doc.get("kit", "?")
print(f"perf-gate: kit {kit} ({metrics_path})")
failed = 0
for key, limit_key, mode, unit in checks:
    if key not in metrics or limit_key not in thresholds:
        print(f"  SKIP {key:<15} (missing metric or threshold)")
        continue
    actual = metrics[key]
    limit = thresholds[limit_key]
    ok = actual <= limit if mode == "max" else actual >= limit
    status = "PASS" if ok else "FAIL"
    if not ok:
        failed += 1
    print(f"  {status} {key:<15} actual={actual}{unit} {mode}={limit}{unit}")

if failed:
    print(f"perf-gate: {failed} regression(s)")
    sys.exit(0 if report_only else 1)
print("perf-gate: PASS")
PY
