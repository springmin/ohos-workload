#!/bin/sh
# selftest-commit-paths.sh - fixture-repo checks for scripts/commit-paths.sh (concurrent commits).
#
#   T1 usage    missing message / missing paths / a path before -- -> exit 2
#   T2 refusal  a clean tracked path, an unknown path and an absolute path -> exit 1, no commit
#   T3 commit   one modified path commits alone as springmin; a sibling change stays out
#   T4 sweep    a concurrently staged path aborts the run, gets named, and the index is restored
#   T5 dry-run  prints the plan (including the staged conflict) and stages/commits nothing
#
# The fixture repo lives under the selftest work dir; every check runs the script under test
# from inside it, so the repository under test is never touched.
#
# Env: SELFTEST_TMPDIR=<dir>  work dir base (default: the approved opencode tmp dir)
#      SELFTEST_KEEP=1       keep the work dir even when all checks pass
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="1 (2026-09-28)"

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

W="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$W/scripts/commit-paths.sh"
WORK_BASE="${SELFTEST_TMPDIR:-/data/storage/el2/base/tmp/opencode}"
KEEP="${SELFTEST_KEEP:-0}"

[ -f "$SCRIPT" ] || { printf 'FATAL: commit-paths.sh not found: %s\n' "$SCRIPT" >&2; exit 1; }
for _t in git grep sed mktemp; do
    command -v "$_t" >/dev/null 2>&1 || { printf 'FATAL: required command not found: %s\n' "$_t" >&2; exit 1; }
done

WORK="$(mktemp -d "$WORK_BASE/selftest-commit-paths.XXXXXX")" || {
    printf 'FATAL: cannot create a work dir under %s\n' "$WORK_BASE" >&2
    exit 1
}
FIX="$WORK/repo"
CHECKS=0
FAILED=0

pass_() { CHECKS=$((CHECKS + 1)); printf '  [PASS] %s\n' "$*"; }
fail_() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$*" >&2; }
assert_rc() { # <expected> <actual> <label>
    if [ "$2" -eq "$1" ]; then pass_ "$3 (exit $2)"; else fail_ "$3 (expected exit $1, got $2)"; fi
}
check_count() { # <expected> <actual> <label>
    if [ "$2" -eq "$1" ]; then pass_ "$3 ($2 commits)"; else fail_ "$3 (expected $1 commits, got $2)"; fi
}
assert_contains() { # <label> <needle> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then pass_ "$1"; else fail_ "$1 (missing: $2)"; fi
}
assert_not_contains() { # <label> <needle> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then fail_ "$1 (unexpected: $2)"; else pass_ "$1"; fi
}

run() { # <log-file> [args...]
    _run_log="$1"
    shift
    sh "$SCRIPT" "$@" > "$_run_log" 2>&1
}

# ---- fixture ---------------------------------------------------------------------------------
section "fixture repo"
mkdir -p "$FIX" "$WORK/home"
: > "$WORK/home/.gitconfig"
export HOME="$WORK/home"
cd "$FIX" || { printf 'FATAL: cannot enter %s\n' "$FIX" >&2; exit 1; }
git init -q
git config user.name fixture
git config user.email fixture@example.com
git config commit.gpgsign false
printf 'alpha one\n' > alpha.txt
printf 'beta one\n' > beta.txt
git add alpha.txt beta.txt
git commit -qm 'fixture base'
COUNT0="$(git rev-list --count HEAD)"
log "selftest-commit-paths v$SELFTEST_VERSION"
log "work: $WORK (fixture HEAD $COUNT0)"

# ---- T1: usage ------------------------------------------------------------------------------
section "T1 usage"
run "$WORK/T1a.log" -m 'msg'
assert_rc 2 $? "T1a no paths is a usage error"
run "$WORK/T1b.log" -- alpha.txt
assert_rc 2 $? "T1b missing -m is a usage error"
run "$WORK/T1c.log" -m 'msg' alpha.txt
assert_rc 2 $? "T1c a path before -- is a usage error"

# ---- T2: refusals ---------------------------------------------------------------------------
section "T2 refusal"
run "$WORK/T2a.log" -m 'msg' -- alpha.txt
assert_rc 1 $? "T2a a clean path is refused"
assert_contains "T2a names the clean path" "no changes for path: alpha.txt" "$WORK/T2a.log"
run "$WORK/T2b.log" -m 'msg' -- does-not-exist.txt
assert_rc 1 $? "T2b an unknown path is refused"
assert_contains "T2b names the unknown path" "no changes for path: does-not-exist.txt" "$WORK/T2b.log"
run "$WORK/T2c.log" -m 'msg' -- /etc/hostname
assert_rc 1 $? "T2c an absolute path is refused"
assert_contains "T2c says the path is absolute" "absolute path refused" "$WORK/T2c.log"
assert_rc "$COUNT0" "$(git rev-list --count HEAD)" "T2 refused runs created no commit"

# ---- T3: a path-scoped commit ---------------------------------------------------------------
section "T3 commit"
printf 'alpha two\n' >> alpha.txt
printf 'beta two\n' >> beta.txt
run "$WORK/T3.log" -m 'commit alpha only' -- alpha.txt
assert_rc 0 $? "T3 commit succeeds"
check_count "$((COUNT0 + 1))" "$(git rev-list --count HEAD)" "T3 created exactly one commit"
git show --name-only --format= HEAD > "$WORK/T3.head"
assert_contains "T3 commits alpha.txt" "alpha.txt" "$WORK/T3.head"
assert_not_contains "T3 leaves beta.txt out of the commit" "beta.txt" "$WORK/T3.head"
git log -1 --format='%an <%ae>' > "$WORK/T3.author"
assert_contains "T3 author is springmin" "springmin <springmin@hotmail.com>" "$WORK/T3.author"
git status --porcelain -- beta.txt > "$WORK/T3.beta"
assert_contains "T3 keeps beta.txt as an unstaged change" " M beta.txt" "$WORK/T3.beta"

# ---- T4: the sweep guard --------------------------------------------------------------------
section "T4 sweep guard"
git add beta.txt
printf 'alpha three\n' >> alpha.txt
run "$WORK/T4.log" -m 'must not sweep' -- alpha.txt
assert_rc 1 $? "T4 aborts when a path outside the list is staged"
assert_contains "T4 names the staged outside path" "beta.txt" "$WORK/T4.log"
assert_contains "T4 reports that nothing was committed" "nothing committed" "$WORK/T4.log"
check_count "$((COUNT0 + 1))" "$(git rev-list --count HEAD)" "T4 created no commit"
git diff --cached --name-only > "$WORK/T4.cached"
assert_contains "T4 leaves the other agent's path staged" "beta.txt" "$WORK/T4.cached"
assert_not_contains "T4 unstaged its own path again" "alpha.txt" "$WORK/T4.cached"
git status --porcelain -- alpha.txt > "$WORK/T4.alpha"
assert_contains "T4 alpha is back to an unstaged change" " M alpha.txt" "$WORK/T4.alpha"

# ---- T5: dry-run ----------------------------------------------------------------------------
section "T5 dry-run"
printf 'alpha four\n' >> alpha.txt
run "$WORK/T5.log" -m 'dry run only' --dry-run -- alpha.txt
assert_rc 0 $? "T5 dry-run exits 0"
assert_contains "T5 prints the plan" "dry-run plan" "$WORK/T5.log"
assert_contains "T5 flags the staged outside path" "beta.txt" "$WORK/T5.log"
assert_contains "T5 stages and commits nothing" "nothing staged, nothing committed" "$WORK/T5.log"
check_count "$((COUNT0 + 1))" "$(git rev-list --count HEAD)" "T5 created no commit"
git diff --cached --name-only > "$WORK/T5.cached"
assert_not_contains "T5 did not stage its own path" "alpha.txt" "$WORK/T5.cached"

# ---- summary --------------------------------------------------------------------------------
section "summary"
log "checks: $CHECKS, failed: $FAILED"
if [ "$FAILED" -gt 0 ]; then
    log "SELFTEST FAILED - work dir kept: $WORK"
    exit 1
fi
log "SELFTEST OK - commit-paths refuses unrelated paths and aborts on concurrent staged work"
if [ "$KEEP" = "1" ]; then
    log "work dir kept (SELFTEST_KEEP=1): $WORK"
else
    rm -rf "$WORK"
fi
exit 0
