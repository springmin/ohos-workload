#!/bin/sh
# selftest-perf-gate.sh - fixture selftest for scripts/perf-gate.sh (the MAUI P0 perf gate).
#
# The device round produces a metrics JSON; perf-gate.sh only compares it with
# test/perf-gate/thresholds.json. This selftest pins the comparator itself so a broken gate
# (wrong direction, swallowed failure, bad report-only) fails in preflight, before a device
# round can be misread.
#
#   T0 syntax     sh -n scripts/perf-gate.sh
#   T1 usage      no arguments -> rc 2
#   T2 baseline   test/perf-gate/baseline-kit58.json -> rc 0, "perf-gate: PASS"
#   T3 regression test/perf-gate/regression.json -> rc 1, exactly 2 regressions reported
#   T4 report     the same regression with --report-only -> rc 0 but still reports 2
#   T5 missing    a missing metrics file -> rc 2
#   T6 bad json   invalid thresholds JSON -> rc 2
#   T7 default    no thresholds argument, run from another cwd -> the repo default is used
#   T8 skip       a threshold key missing from the thresholds file -> SKIP, rc 0
#   T9 custom     a caller-supplied thresholds file is honoured -> rc 0
#   T10 negative  a negative max metric -> rc 1 (a bad measurement cannot pass)
#
# Env: SELFTEST_TMPDIR=<dir>  work dir base (default: the approved opencode tmp dir)
#      SELFTEST_KEEP=1       keep the work dir even when all checks pass
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

W="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$W/scripts/perf-gate.sh"
FIX="$W/test/perf-gate"
BASE="${SELFTEST_TMPDIR:-/data/storage/el2/base/tmp/opencode}"
T="$BASE/selftest-perf-gate.$$"
mkdir -p "$T" || { echo "cannot create $T" >&2; exit 1; }

CHECKS=0
FAILED=0
pass_() { CHECKS=$((CHECKS + 1)); printf '  [PASS] %s\n' "$*"; }
fail_() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$*" >&2; }
assert_rc() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then pass_ "$1 (rc=$2)"; else fail_ "$1 (rc=$2, want $3)"; fi
}
assert_contains() { # <label> <needle> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then pass_ "$1"; else fail_ "$1 (missing: $2)"; fi
}
assert_not_contains() { # <label> <needle> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then fail_ "$1 (unexpected: $2)"; else pass_ "$1"; fi
}
count_lines() { grep -cF -- "$2" "$1" 2>/dev/null || true; }

cleanup() {
    _rc=$?
    if [ "$FAILED" -eq 0 ] && [ "${SELFTEST_KEEP:-0}" != 1 ]; then
        rm -rf "$T"
    else
        log "work dir kept: $T"
    fi
    exit "$_rc"
}
trap cleanup EXIT

[ -f "$GATE" ] || { echo "FATAL: perf-gate.sh not found: $GATE" >&2; exit 1; }
[ -f "$FIX/baseline-kit58.json" ] || { echo "FATAL: fixture missing: $FIX/baseline-kit58.json" >&2; exit 1; }
[ -f "$FIX/regression.json" ] || { echo "FATAL: fixture missing: $FIX/regression.json" >&2; exit 1; }

cp "$FIX/baseline-kit58.json" "$T/baseline.json"
cp "$FIX/regression.json" "$T/regression.json"
cp "$FIX/thresholds.json" "$T/thresholds.json"

log "selftest-perf-gate: comparator fixture checks"

# ---------------------------------------------------------------- T0 syntax
if sh -n "$GATE"; then pass_ "T0 syntax: sh -n perf-gate.sh"; else fail_ "T0 syntax: sh -n perf-gate.sh"; fi

# ---------------------------------------------------------------- T1 usage
sh "$GATE" > "$T/t1.out" 2>&1
assert_rc "T1 usage: no arguments" "$?" 2

# ---------------------------------------------------------------- T2 baseline
sh "$GATE" "$T/baseline.json" > "$T/t2.out" 2>&1
assert_rc "T2 baseline: kit 58 passes" "$?" 0
assert_contains "T2 baseline: PASS summary" "perf-gate: PASS" "$T/t2.out"
assert_contains "T2 baseline: 6 metrics checked" "PASS first_frame_ms" "$T/t2.out"
if [ "$(count_lines "$T/t2.out" "PASS ")" = 6 ]; then pass_ "T2 baseline: all 6 metrics PASS"; else fail_ "T2 baseline: expected 6 PASS lines, got $(count_lines "$T/t2.out" "PASS ")"; fi

# ---------------------------------------------------------------- T3 regression
sh "$GATE" "$T/regression.json" > "$T/t3.out" 2>&1
assert_rc "T3 regression: exits 1" "$?" 1
assert_contains "T3 regression: FAIL scroll_fps" "FAIL scroll_fps" "$T/t3.out"
assert_contains "T3 regression: FAIL rss_mb" "FAIL rss_mb" "$T/t3.out"
assert_contains "T3 regression: count reported" "2 regression(s)" "$T/t3.out"

# ---------------------------------------------------------------- T4 report-only
sh "$GATE" --report-only "$T/regression.json" > "$T/t4.out" 2>&1
assert_rc "T4 report-only: exits 0" "$?" 0
assert_contains "T4 report-only: still reports 2" "2 regression(s)" "$T/t4.out"
assert_not_contains "T4 report-only: no PASS summary" "perf-gate: PASS" "$T/t4.out"

# ---------------------------------------------------------------- T5 missing file
sh "$GATE" "$T/nope.json" > "$T/t5.out" 2>&1
assert_rc "T5 missing metrics: usage error" "$?" 2
assert_contains "T5 missing metrics: names the file" "no metrics file" "$T/t5.out"

# ---------------------------------------------------------------- T6 invalid JSON
printf '{not json\n' > "$T/bad-thresholds.json"
sh "$GATE" "$T/baseline.json" "$T/bad-thresholds.json" > "$T/t6.out" 2>&1
assert_rc "T6 bad thresholds: usage error" "$?" 2

# ---------------------------------------------------------------- T7 default thresholds path
( cd "$T" && sh "$GATE" "$T/baseline.json" ) > "$T/t7.out" 2>&1
assert_rc "T7 default thresholds: repo default used from another cwd" "$?" 0

# ---------------------------------------------------------------- T8 missing threshold key
python3 - "$T/thresholds.json" "$T/partial-thresholds.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc.pop("min_suite_pass", None)
json.dump(doc, open(sys.argv[2], "w"))
PY
sh "$GATE" "$T/baseline.json" "$T/partial-thresholds.json" > "$T/t8.out" 2>&1
assert_rc "T8 missing threshold: still passes" "$?" 0
assert_contains "T8 missing threshold: SKIP line" "SKIP suite_pass" "$T/t8.out"

# ---------------------------------------------------------------- T9 custom thresholds
python3 - "$T/thresholds.json" "$T/loose-thresholds.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["max_rss_mb"] = 1000
doc["min_scroll_fps"] = 30.0
json.dump(doc, open(sys.argv[2], "w"))
PY
sh "$GATE" "$T/regression.json" "$T/loose-thresholds.json" > "$T/t9.out" 2>&1
assert_rc "T9 custom thresholds: loosened gate passes" "$?" 0
assert_contains "T9 custom thresholds: PASS summary" "perf-gate: PASS" "$T/t9.out"

# ---------------------------------------------------------------- T10 negative
python3 - "$T/baseline.json" "$T/negative.json" <<'PYNEG'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["metrics"]["first_frame_ms"] = -1
json.dump(doc, open(sys.argv[2], "w"))
PYNEG
sh "$GATE" "$T/negative.json" > "$T/t10.out" 2>&1
assert_rc "T10 negative metric: exits 1" "$?" 1
assert_contains "T10 negative metric: FAIL first_frame_ms" "FAIL first_frame_ms" "$T/t10.out"

# ---------------------------------------------------------------- summary
printf '\n'
if [ "$FAILED" -gt 0 ]; then
    printf 'selftest-perf-gate: %d/%d checks failed (work dir: %s)\n' "$FAILED" "$CHECKS" "$T" >&2
    exit 1
fi
printf 'selftest-perf-gate: %d/%d checks passed\n' "$CHECKS" "$CHECKS"
log "perf gate comparator: PASS"
