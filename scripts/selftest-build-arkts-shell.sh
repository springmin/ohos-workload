#!/bin/sh
# selftest-build-arkts-shell.sh - repeatable, fully local selftest for the hvigor tarball gate in
# scripts/build-arkts-shell.sh (the A2/residual "tar `../` members" review item).
#
# The build script pins the two hvigor tarballs by sha256 and additionally refuses to unpack any
# tarball whose member list carries an absolute path or a `..` component (tar-slip). This selftest
# drives that gate through `build-arkts-shell.sh --check-tgz <file>`, which runs the exact
# verify_tgz_members check used on the install path and never unpacks anything:
#
#   T1 safe       a normal npm-style tarball (package/... members) passes, exit 0
#   T2 traversal  a tarball with a `../escape.txt` member fails, the error names it, and no file
#                 is created outside the fixture directory (nothing is extracted)
#   T3 absolute   a `/abs/escape.txt` member fails
#   T4 mixed      a tarball with safe members *and* one nested `package/../../escape.txt` fails
#                 (the check does not stop at the first safe member)
#   T5 spelling   `package/a/../../b.txt` fails; `package/a/..b/c.txt`, `..foo` and `a/b..` pass
#                 (no over-blocking of legal names)
#   T6 notgz      a plain file fails as "cannot list as a gzip tarball", an empty tar as "no
#                 members"; a missing argument fails
#   T7 wiring     the install path runs the sha256 check, then the member check, then `tar xzf`
#                 (source pin: the gate sits before the first extraction on both the cached and
#                 the downloaded tarball)
#
# No network, no node, no SDK, no real unpack: the malicious tarballs are created with python3's
# tarfile into a temp dir and only ever listed (`tar tzf`). A fixture is deliberately kept
# malicious and the test proves that with `tar tzf` (so the negative cases cannot silently stop
# matching the guard), while asserting the would-be escape target never appears.
#
# Env: SELFTEST_TMPDIR=<dir>  work dir base (default: the approved opencode tmp dir)
#      SELFTEST_KEEP=1       keep the work dir even when all checks pass
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="1 (2026-09-23)"

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

# ---- paths ---------------------------------------------------------------------------
SELFTEST_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_SCRIPT="${SELFTEST_BUILD_SCRIPT:-$SELFTEST_DIR/build-arkts-shell.sh}"
WORK_BASE="${SELFTEST_TMPDIR:-/data/storage/el2/base/tmp/opencode}"
KEEP="${SELFTEST_KEEP:-0}"

if [ ! -f "$BUILD_SCRIPT" ]; then
    printf 'FATAL: build-arkts-shell.sh not found: %s\n' "$BUILD_SCRIPT" >&2
    exit 1
fi
for _t in python3 tar grep sed mktemp head cut; do
    if ! command -v "$_t" >/dev/null 2>&1; then
        printf 'FATAL: required command not found: %s\n' "$_t" >&2
        exit 1
    fi
done

WORK="$(mktemp -d "$WORK_BASE/selftest-build-arkts-shell.XXXXXX")" || {
    printf 'FATAL: cannot create a work dir under %s\n' "$WORK_BASE" >&2
    exit 1
}
LOG_FILE="$WORK/check.log"
CHECKS=0
FAILED=0

pass_() { CHECKS=$((CHECKS + 1)); printf '  [PASS] %s\n' "$*"; }
fail_() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$*" >&2; }
assert_rc() { # <expected> <actual> <label>
    if [ "$2" -eq "$1" ]; then pass_ "$3 (exit $2)"; else fail_ "$3 (expected exit $1, got $2)"; fi
}
assert_contains() { # <label> <needle> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then pass_ "$1"; else fail_ "$1 (missing: $2)"; fi
}
assert_not_exists() { # <label> <path>
    if [ ! -e "$2" ]; then pass_ "$1"; else fail_ "$1 ($2 exists)"; fi
}

# Creates the fixture tarballs; only tarfile creates member names this way (GNU tar strips
# leading `../` on creation), which is exactly the poisoned-artifact shape the gate defends
# against.
make_tgz() { # <path> <kind>
    python3 - "$1" "$2" <<'PY'
import io, sys, tarfile
path, kind = sys.argv[1], sys.argv[2]
entries = {
    "safe":      [("package/package.json", b"{}\n"), ("package/index.js", b"ok\n")],
    "traversal": [("package/package.json", b"{}\n"), ("../escape.txt", b"pwned\n")],
    "absolute":  [("/abs/escape.txt", b"pwned\n")],
    "mixed":     [("package/index.js", b"ok\n"), ("package/../../escape.txt", b"pwned\n")],
    "dotdot_in": [("package/a/../../b.txt", b"pwned\n")],
    "nearly":    [("package/a/..b/c.txt", b"ok\n"), ("..foo", b"ok\n"), ("a/b..", b"ok\n")],
    "empty":     [],
}[kind]
with tarfile.open(path, "w:gz") as tf:
    for name, data in entries:
        info = tarfile.TarInfo(name)
        info.size = len(data)
        tf.addfile(info, io.BytesIO(data))
PY
}

# Runs the check mode; stdout+stderr land in $LOG_FILE, the exit code is echoed.
run_check() { # <tgz>
    ( cd "$SELFTEST_DIR/.." && sh "$BUILD_SCRIPT" --check-tgz "$1" ) > "$LOG_FILE" 2>&1
    echo $?
}

log "selftest-build-arkts-shell v$SELFTEST_VERSION"
log "script: $BUILD_SCRIPT"
log "work:   $WORK"

# ---- fixtures ------------------------------------------------------------------------
section "fixtures"
for kind in safe traversal absolute mixed dotdot_in nearly empty; do
    make_tgz "$WORK/$kind.tgz" "$kind"
done
printf 'not a tarball\n' > "$WORK/notgz.bin"

# Prove the fixtures really carry what the negative tests claim (member names only, no unpack).
TRAVERSAL_MEMBERS="$(tar tzf "$WORK/traversal.tgz" 2>/dev/null)"
case "$TRAVERSAL_MEMBERS" in
    *"../escape.txt"*) pass_ "T2 fixture contains a ../escape.txt member" ;;
    *) fail_ "T2 fixture is not malicious: tar tzf printed '$TRAVERSAL_MEMBERS'" ;;
esac
MIXED_MEMBERS="$(tar tzf "$WORK/mixed.tgz" 2>/dev/null)"
case "$MIXED_MEMBERS" in
    *"package/../../escape.txt"*) pass_ "T4 fixture contains the nested traversal member" ;;
    *) fail_ "T4 fixture is not malicious: tar tzf printed '$MIXED_MEMBERS'" ;;
esac

# ---- T1: the gate accepts a normal tarball -------------------------------------------
section "T1 safe tarball accepted"
RC="$(run_check "$WORK/safe.tgz")"
assert_rc 0 "$RC" "T1 safe package tarball"
assert_contains "T1 reports the safe member list" "member list is safe" "$LOG_FILE"
# Sanity: the fixture is readable as a tar and has the expected shape (listed only, never unpacked).
tar tzf "$WORK/safe.tgz" > "$WORK/t1.list" 2>/dev/null
assert_contains "T1 fixture lists package/package.json" "package/package.json" "$WORK/t1.list"

# ---- T2: `../` member rejected before any unpack -------------------------------------
section "T2 traversal member rejected"
RC="$(run_check "$WORK/traversal.tgz")"
assert_rc 1 "$RC" "T2 ../escape.txt member"
assert_contains "T2 error names the offending member" "../escape.txt" "$LOG_FILE"
assert_contains "T2 reports the traversal reason" "unsafe member names" "$LOG_FILE"
assert_not_exists "T2 nothing was extracted next to the fixture" "$WORK/escape.txt"
# The check mode must not modify the tarball it is asked about.
tar tzf "$WORK/traversal.tgz" >/dev/null 2>&1
assert_rc 0 $? "T2 fixture still a readable tarball after the check"

# ---- T3: absolute member rejected ----------------------------------------------------
section "T3 absolute member rejected"
RC="$(run_check "$WORK/absolute.tgz")"
assert_rc 1 "$RC" "T3 /abs/escape.txt member"
assert_contains "T3 error names the offending member" "/abs/escape.txt" "$LOG_FILE"
assert_not_exists "T3 nothing was extracted" "$WORK/abs"

# ---- T4: mixed safe + traversal rejected ---------------------------------------------
section "T4 mixed members rejected"
RC="$(run_check "$WORK/mixed.tgz")"
assert_rc 1 "$RC" "T4 nested package/../../escape.txt member"
assert_contains "T4 error names the nested member" "package/../../escape.txt" "$LOG_FILE"

# ---- T5: spelling boundaries ---------------------------------------------------------
section "T5 traversal spellings and legal look-alikes"
RC="$(run_check "$WORK/dotdot_in.tgz")"
assert_rc 1 "$RC" "T5 package/a/../../b.txt member"
RC="$(run_check "$WORK/nearly.tgz")"
assert_rc 0 "$RC" "T5 ./..b, ..foo and a/b.. are legal names"

# ---- T6: not a tarball / empty / missing argument ------------------------------------
section "T6 invalid inputs"
RC="$(run_check "$WORK/notgz.bin")"
assert_rc 1 "$RC" "T6 plain file is not a tarball"
assert_contains "T6 reports the listing failure" "cannot list" "$LOG_FILE"
RC="$(run_check "$WORK/empty.tgz")"
assert_rc 1 "$RC" "T6 empty tarball is refused"
assert_contains "T6 reports the empty member list" "has no members" "$LOG_FILE"
( cd "$SELFTEST_DIR/.." && sh "$BUILD_SCRIPT" --check-tgz ) > "$LOG_FILE" 2>&1
assert_rc 1 $? "T6 missing file argument"
assert_contains "T6 prints usage" "usage:" "$LOG_FILE"

# ---- T7: the install path reaches the gate before the first extraction ---------------
section "T7 source pin: sha256 -> members -> tar xzf"
SHA_LINE="$(grep -nF 'verify_hvigor_tgz "$part" "$want"' "$BUILD_SCRIPT" | head -1 | cut -d: -f1)"
MEM_LINE="$(grep -nF 'if verify_tgz_members "$tgz"; then' "$BUILD_SCRIPT" | head -1 | cut -d: -f1)"
TAR_LINE="$(grep -nF 'tar xzf "$tgz" -C' "$BUILD_SCRIPT" | head -1 | cut -d: -f1)"
if [ -n "$SHA_LINE" ] && [ -n "$MEM_LINE" ] && [ -n "$TAR_LINE" ]; then
    pass_ "T7 the three install-path markers exist (sha=$SHA_LINE members=$MEM_LINE tar=$TAR_LINE)"
else
    fail_ "T7 a marker is missing (sha='$SHA_LINE' members='$MEM_LINE' tar='$TAR_LINE')"
fi
if [ -n "$SHA_LINE" ] && [ -n "$MEM_LINE" ] && [ "$SHA_LINE" -lt "$MEM_LINE" ]; then
    pass_ "T7 sha256 verification runs before the member gate"
else
    fail_ "T7 ordering: sha=$SHA_LINE members=$MEM_LINE"
fi
if [ -n "$MEM_LINE" ] && [ -n "$TAR_LINE" ] && [ "$MEM_LINE" -lt "$TAR_LINE" ]; then
    pass_ "T7 the member gate runs before the first tar xzf"
else
    fail_ "T7 ordering: members=$MEM_LINE tar=$TAR_LINE"
fi
# The gate covers both provenance paths: the cached tarball (verified in place) and the freshly
# downloaded one (verified before it is moved into the cache), then one gate before the unpack.
if grep -qF 'verify_hvigor_tgz "$tgz" "$want"' "$BUILD_SCRIPT" \
   && grep -qF 'verify_hvigor_tgz "$part" "$want"' "$BUILD_SCRIPT"; then
    pass_ "T7 both the cached and the downloaded tarball keep their sha256 check"
else
    fail_ "T7 cached/downloaded sha256 checks changed"
fi

# ---- summary -------------------------------------------------------------------------
section "summary"
log "checks: $CHECKS, failed: $FAILED"
if [ "$FAILED" -gt 0 ]; then
    log "SELFTEST FAILED - work dir kept: $WORK"
    exit 1
fi
log "SELFTEST OK - tarball member gate rejects ../ and absolute members before unpacking"
if [ "$KEEP" = "1" ]; then
    log "work dir kept (SELFTEST_KEEP=1): $WORK"
else
    rm -rf "$WORK"
fi
exit 0
