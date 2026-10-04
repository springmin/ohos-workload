#!/bin/sh
# selftest-rc2-official-watch.sh - offline fixture checks for scripts/rc2-official-watch.sh.
#
#   T1 usage    an unknown argument -> exit 2, no poll
#   T2 wait     rc.1-only nuget + GitHub fixtures -> exit 0, "status: WAIT"
#   T3 trigger  one nuget package at rc.2 -> exit 10, TRIGGER block with the adoption doc path
#   T4 stable   a stable 11.0.0 nuget version -> exit 10 (later than rc.2 also triggers)
#   T5 fail     every source down (missing fixture base) -> exit 1
#
# The script under test is pointed at file:// fixture indexes with RC2_WATCH_* env vars, so the
# selftest never touches the network.
#
# Env: SELFTEST_TMPDIR=<dir>  work dir base (default: the approved opencode dir on this host,
#                             else TMPDIR, else /tmp)
#      SELFTEST_KEEP=1       keep the work dir even when all checks pass
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="1 (2026-10-04)"

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

W="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$W/scripts/rc2-official-watch.sh"
WORK_BASE="${SELFTEST_TMPDIR:-}"
if [ -z "$WORK_BASE" ]; then
    # Same portable chain as scripts/selftest-ridgraph.sh: CI runners have neither the
    # approved opencode dir nor (usually) TMPDIR, so the hardcoded host path must not be the
    # only option (a bare `mktemp -d <missing dir>` aborts the whole selftest).
    if [ -d /data/storage/el2/base/tmp/opencode ]; then
        WORK_BASE="/data/storage/el2/base/tmp/opencode"
    elif [ -n "${TMPDIR:-}" ]; then
        WORK_BASE="$TMPDIR"
    else
        WORK_BASE="/tmp"
    fi
fi
KEEP="${SELFTEST_KEEP:-0}"

[ -f "$SCRIPT" ] || { printf 'FATAL: rc2-official-watch.sh not found: %s\n' "$SCRIPT" >&2; exit 1; }
for _t in curl awk grep sed tr mktemp; do
    command -v "$_t" >/dev/null 2>&1 || { printf 'FATAL: required command not found: %s\n' "$_t" >&2; exit 1; }
done

WORK="$(mktemp -d "$WORK_BASE/selftest-rc2-watch.XXXXXX")" || {
    printf 'FATAL: cannot create a work dir under %s\n' "$WORK_BASE" >&2
    exit 1
}
CHECKS=0
FAILED=0
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
trap 'cleanup' 0 1 2 3 15

pass_() { CHECKS=$((CHECKS + 1)); printf '  [PASS] %s\n' "$*"; }
fail_() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$*" >&2; }
assert_rc() { # <expected> <actual> <label>
    if [ "$2" -eq "$1" ]; then pass_ "$3 (exit $2)"; else fail_ "$3 (expected exit $1, got $2)"; fi
}
assert_contains() { # <label> <needle> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then pass_ "$1"; else fail_ "$1 (missing: $2)"; fi
}

PACKAGES="microsoft.maui.controls microsoft.maui.core microsoft.maui.graphics microsoft.aspnetcore.components.webview.maui"

seed_nuget() { # <dir> <controls-index-json>
    _d=$1; _controls=$2
    for _p in $PACKAGES; do
        mkdir -p "$_d/$_p"
        printf '{"versions":["10.0.110","11.0.0-rc.1.26451.6"]}' > "$_d/$_p/index.json"
    done
    printf '%s' "$_controls" > "$_d/microsoft.maui.controls/index.json"
}
seed_gh() { # <dir> <releases-json-lines>
    mkdir -p "$1/repos/dotnet/maui"
    printf '%s' "$2" > "$1/repos/dotnet/maui/releases"
}
run() { # <logfile> <nuget-base> <gh-base>
    RC2_WATCH_NUGET_API="$2" RC2_WATCH_GITHUB_API="$3" \
    RC2_WATCH_ADOPTION_DOC="$WORK/adoption.md" RC2_WATCH_TIMEOUT=5 \
        sh "$SCRIPT" > "$1" 2>&1
}

log "selftest-rc2-official-watch v$SELFTEST_VERSION"
log "work: $WORK"

# ---- T1: usage -------------------------------------------------------------------------
section "T1 usage"
RC2_WATCH_TIMEOUT=5 sh "$SCRIPT" --bogus > "$WORK/T1.log" 2>&1
assert_rc 2 $? "T1 unknown argument is refused"

# ---- T2: rc.1 only -> wait -------------------------------------------------------------
section "T2 rc.1-only fixtures"
seed_nuget "$WORK/nuget" '{"versions":["10.0.110","11.0.0-preview.7.26406.9","11.0.0-rc.1.26451.6"]}'
seed_gh "$WORK/gh" '{"tag_name": "11.0.100-rc.1.26458.5"}
{"tag_name": "10.0.110"}'
run "$WORK/T2.log" "file://$WORK/nuget" "file://$WORK/gh"
assert_rc 0 $? "T2 rc.1 only exits 0"
assert_contains "T2 reports the wait status" "status: WAIT" "$WORK/T2.log"
assert_contains "T2 reports trigger=no for nuget" "trigger=no" "$WORK/T2.log"

# ---- T3: nuget rc.2 -> trigger ---------------------------------------------------------
section "T3 nuget rc.2"
seed_nuget "$WORK/nuget-checks" '{"versions":["11.0.0-rc.1.26451.6","11.0.0-rc.2.26478.12"]}'
run "$WORK/T3.log" "file://$WORK/nuget-checks" "file://$WORK/gh"
assert_rc 10 $? "T3 rc.2 exits 10"
assert_contains "T3 prints the trigger banner" "RC2-WATCH TRIGGER" "$WORK/T3.log"
assert_contains "T3 names the adoption record" "adoption.md" "$WORK/T3.log"

# ---- T4: stable 11.0.0 -> trigger (later than rc.2) ------------------------------------
section "T4 stable 11.0.0"
seed_nuget "$WORK/nuget-stable" '{"versions":["11.0.0-rc.2.26478.12","11.0.0"]}'
run "$WORK/T4.log" "file://$WORK/nuget-stable" "file://$WORK/gh"
assert_rc 10 $? "T4 stable 11.0.0 exits 10"
assert_contains "T4 prints the trigger banner" "RC2-WATCH TRIGGER" "$WORK/T4.log"

# ---- T5: every source down -> unknown --------------------------------------------------
section "T5 every source down"
run "$WORK/T5.log" "file://$WORK/no-such-nuget" "file://$WORK/no-such-gh"
assert_rc 1 $? "T5 all-failed exits 1"
assert_contains "T5 says the result is unknown" "every poll source failed" "$WORK/T5.log"

# ---- summary ---------------------------------------------------------------------------
log "== summary =="
printf '   checks: %s  failed: %s\n' "$CHECKS" "$FAILED"
if [ "$FAILED" -gt 0 ]; then
    printf 'SELFTEST FAILED - work dir kept: %s\n' "$WORK" >&2
    KEEP=1
    exit 1
fi
printf 'SELFTEST OK - %s checks passed\n' "$CHECKS"
exit 0
