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
#   T8 diagnose+  a log carrying hvigor 00302013 / "The root node is not yet available for build"
#                 is attributed by `--diagnose-log`: exit 0 and the official handling steps
#                 (ide-hvigor-errorcode-00302), the duplicate-plugin/cache commands and the
#                 DevEco-Studio fallback are all printed
#   T9 diagnose-  an ordinary hvigor log has no such signature: exit 1, no handling steps
#   T10 scaffold  `--scaffold-only` writes the real hvigor-config.json5 / oh-package.json5 /
#                 build-profile.json5 without node or an SDK; assert the empty dependencies, the
#                 modelVersion agreement (a mismatch makes hvigor exit with
#                 INCONSISTENT_MODEL_VERSION) and the strictMode/runtimeOS/compatibleSdkVersion
#                 values; `--check-project-deps` accepts the generated project
#   T11 deps gate a project whose hvigor-config lists @ohos/hvigor-ohos-plugin (or @ohos/hvigor) is
#                 rejected by `--check-project-deps` with the official pointer, while the same
#                 names inside a // comment stay accepted (the guard strips comments)
#   T12 wiring    source pin for the new pieces: the generated modelVersion default, the dependency
#                 guard running after scaffold generation and before hvigor starts, and the
#                 diagnosis hook sitting on the failure path just before the final die
#   T13 abc       `--check-abc` accepts an abc carrying the payload-in-libs probe
#                 (dotnet-payload/bundleCodeDir/payload-in-libs) and the dotnet.zip fallback
#                 (dotnet.marker); each missing literal fails with its name, an unreadable file
#                 is exit 2 and a missing argument is refused
#   T15 sources   `--check-sources` accepts the shipped packs (token gate + cross-pack source
#                 identity) and rejects an injected @ohos import, getContext() call,
#                 decodeWithStream() call or focusControl call, naming the pattern
#   T16 provenance `--check-pack-abc` accepts the shipped packs (size/sha/abc-version/literal/
#                 source-hash provenance) and, on a self-contained pack copy, rejects a corrupted
#                 abc, a source edit without a rebuild, a missing provenance record and a stale
#                 rebuilt artifact against the installed pack
#   T14 flavor    `ARKTS_SDK_FLAVOR=harmony` scaffolding: a fake DevEco-style HarmonyOS SDK
#                 fixture (default/openharmony/ets + default/hms/ets with metadata) makes
#                 `--scaffold-only` emit runtimeOS HarmonyOS with compatibleSdkVersion/target
#                 6.1.0(23) and a clean `--check-project-deps`; a missing SDK root or a root
#                 without hms/ets is refused with the documented message; the default flavor
#                 stays OpenHarmony/18 and the abc ceiling stays 13.0.1.0 (source pins)
#
# No network, no node, no SDK, no real unpack: the malicious tarballs are created with python3's
# tarfile into a temp dir and only ever listed (`tar tzf`), the scaffold is written by the script's
# own generator (python3 only), and the hvigor logs are fixtures. A fixture is deliberately kept
# malicious and the test proves that with `tar tzf` (so the negative cases cannot silently stop
# matching the guard), while asserting the would-be escape target never appears.
#
# Env: SELFTEST_TMPDIR=<dir>  work dir base (default: the approved opencode tmp dir)
#      SELFTEST_KEEP=1       keep the work dir even when all checks pass
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="3 (2026-09-25)"
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
assert_not_contains() { # <label> <needle> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then fail_ "$1 (unexpected: $2)"; else pass_ "$1"; fi
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

# ---- T8: the 00302013 diagnosis on a real-shaped log ----------------------------------
section "T8 hvigor 00302013 log is attributed"
cat > "$WORK/hvigor-00302013.log" <<'EOF'
> hvigor ERROR: 00302013 Script Error
Error Message: The root node is not yet available for build. At file: hvigorfile.ts or hvigorconfig.ts
> hvigor ERROR: BUILD FAILED in 4 s 118 ms
EOF
( cd "$SELFTEST_DIR/.." && sh "$BUILD_SCRIPT" --diagnose-log "$WORK/hvigor-00302013.log" ) > "$LOG_FILE" 2>&1
assert_rc 0 $? "T8 --diagnose-log exits 0 on the 00302013 signature"
for needle in "00302013" "root node" "ide-hvigor-errorcode-00302" "hvigorconfig.ts" \
              "hvigor-config.json5" "devDependencies" "DevEco Studio" "useNormalizedOHMUrl" \
              "rm -rf" ".hvigor" "--check-project-deps"; do
    assert_contains "T8 output mentions '$needle'" "$needle" "$LOG_FILE"
done
assert_contains "T8 output names the generated scaffold" "hvigor/project" "$LOG_FILE"

# ---- T9: an ordinary hvigor failure must not be mis-attributed ------------------------
section "T9 ordinary hvigor log is not diagnosed"
{
    printf '> hvigor Finished :entry:default@CompileArkTS... after 12 s\n'
    printf '> hvigor ERROR: Failed :entry:default@PackageHap...\n'
} > "$WORK/hvigor-ordinary.log"
( cd "$SELFTEST_DIR/.." && sh "$BUILD_SCRIPT" --diagnose-log "$WORK/hvigor-ordinary.log" ) > "$LOG_FILE" 2>&1
RC=$?
assert_rc 1 "$RC" "T9 --diagnose-log exits 1 without the signature"
assert_contains "T9 says no signature was found" "no 00302013" "$LOG_FILE"
assert_not_contains "T9 prints no 00302013 handling steps" "ide-hvigor-errorcode-00302" "$LOG_FILE"

# ---- T10: the generated scaffold configuration ----------------------------------------
section "T10 generated scaffold configuration"
SCAFFOLD="$WORK/scaffold"
( cd "$SELFTEST_DIR/.." && sh "$BUILD_SCRIPT" --scaffold-only "$SCAFFOLD" ) > "$LOG_FILE" 2>&1
assert_rc 0 $? "T10 --scaffold-only exits 0"
HCFG="$SCAFFOLD/hvigor/hvigor-config.json5"
OPKG="$SCAFFOLD/oh-package.json5"
BPROF="$SCAFFOLD/build-profile.json5"
assert_contains "T10 hvigor-config keeps dependencies empty" "dependencies: {}" "$HCFG"
assert_contains "T10 hvigor-config typeCheck defaults to false" "typeCheck: false" "$HCFG"
assert_contains "T10 build-profile keeps runtimeOS OpenHarmony" "runtimeOS: 'OpenHarmony'" "$BPROF"
assert_contains "T10 build-profile keeps useNormalizedOHMUrl false" "useNormalizedOHMUrl: false" "$BPROF"
assert_contains "T10 build-profile keeps caseSensitiveCheck true" "caseSensitiveCheck: true" "$BPROF"
assert_contains "T10 build-profile keeps compatibleSdkVersion 18" "compatibleSdkVersion: '18'" "$BPROF"
# hvigor exits with INCONSISTENT_MODEL_VERSION when hvigor-config.json5 and oh-package.json5
# disagree, so the two generated values must stay in lockstep.
HC_MV="$(sed -n "s/.*modelVersion: '\([^']*\)'.*/\1/p" "$HCFG" | head -1)"
OP_MV="$(sed -n "s/.*modelVersion: '\([^']*\)'.*/\1/p" "$OPKG" | head -1)"
if [ -n "$HC_MV" ] && [ "$HC_MV" = "$OP_MV" ]; then
    pass_ "T10 hvigor-config and oh-package modelVersion agree ($HC_MV)"
else
    fail_ "T10 modelVersion mismatch (hvigor-config='$HC_MV' oh-package='$OP_MV')"
fi
if [ "$HC_MV" = "6.0.2" ]; then
    pass_ "T10 modelVersion is the DevEco-created value 6.0.2"
else
    fail_ "T10 modelVersion is '$HC_MV', expected 6.0.2"
fi
( cd "$SELFTEST_DIR/.." && sh "$BUILD_SCRIPT" --check-project-deps "$SCAFFOLD" ) > "$LOG_FILE" 2>&1
assert_rc 0 $? "T10 --check-project-deps accepts the generated project"
assert_contains "T10 the guard reports the clean dependencies" "dependencies clean" "$LOG_FILE"

# ---- T11: the hvigor plugin dependency guard ------------------------------------------
section "T11 hvigor plugin dependency guard"
POISONED="$WORK/scaffold-poisoned"
cp -r "$SCAFFOLD" "$POISONED"
sed "s|dependencies: {}|dependencies: { '@ohos/hvigor-ohos-plugin': '6.26.4', '@ohos/hvigor': '6.26.4' }|" \
    "$POISONED/hvigor/hvigor-config.json5" > "$POISONED/hvigor/hvigor-config.json5.new"
mv "$POISONED/hvigor/hvigor-config.json5.new" "$POISONED/hvigor/hvigor-config.json5"
( cd "$SELFTEST_DIR/.." && sh "$BUILD_SCRIPT" --check-project-deps "$POISONED" ) > "$LOG_FILE" 2>&1
RC=$?
assert_rc 1 "$RC" "T11 a listed hvigor plugin is rejected"
assert_contains "T11 names the offending plugin" "@ohos/hvigor-ohos-plugin" "$LOG_FILE"
assert_contains "T11 points at the official error code" "00302013" "$LOG_FILE"
assert_contains "T11 points at the official handling step" "handling step 2" "$LOG_FILE"
# The guard strips // comments, so an explanatory comment naming the packages stays legal.
COMMENTED="$WORK/scaffold-commented"
cp -r "$SCAFFOLD" "$COMMENTED"
python3 - "$COMMENTED/hvigor/hvigor-config.json5" <<'PY'
import sys
path = sys.argv[1]
lines = open(path).read().split('\n')
lines.insert(1, '  // keep @ohos/hvigor and @ohos/hvigor-ohos-plugin out of dependencies')
open(path, 'w').write('\n'.join(lines))
PY
( cd "$SELFTEST_DIR/.." && sh "$BUILD_SCRIPT" --check-project-deps "$COMMENTED" ) > "$LOG_FILE" 2>&1
assert_rc 0 $? "T11 a // comment naming the plugins stays accepted"

# ---- T12: source pins for the guard and the diagnosis hook ----------------------------
section "T12 source pins: modelVersion, generation guard, failure diagnosis"
MV_LINE="$(grep -nF 'MODEL_VERSION="${ARKTS_MODEL_VERSION:-6.0.2}"' "$BUILD_SCRIPT" | head -1 | cut -d: -f1)"
GEN_LINE="$(grep -n '^write_project_configs$' "$BUILD_SCRIPT" | head -1 | cut -d: -f1)"
GUARD_LINE="$(grep -nF 'check_hvigor_config_deps "$PROJ" && _grc=0' "$BUILD_SCRIPT" | head -1 | cut -d: -f1)"
HVIGOR_LINE="$(grep -nF 'info "running hvigor assembleHap"' "$BUILD_SCRIPT" | head -1 | cut -d: -f1)"
DIAG_LINE="$(grep -nF 'diagnose_hvigor_log "$LOG"' "$BUILD_SCRIPT" | head -1 | cut -d: -f1)"
DIE_LINE="$(grep -nF 'die "hvigor failed (full log: $LOG)"' "$BUILD_SCRIPT" | head -1 | cut -d: -f1)"
for pair in "modelVersion:$MV_LINE" "scaffold generation:$GEN_LINE" "dependency guard:$GUARD_LINE" \
            "hvigor start:$HVIGOR_LINE" "diagnosis hook:$DIAG_LINE" "failure die:$DIE_LINE"; do
    label="${pair%%:*}"; line="${pair#*:}"
    if [ -n "$line" ]; then pass_ "T12 marker '$label' exists (line $line)"; else fail_ "T12 marker '$label' is missing"; fi
done
if [ -n "$GEN_LINE" ] && [ -n "$GUARD_LINE" ] && [ "$GEN_LINE" -lt "$GUARD_LINE" ]; then
    pass_ "T12 the dependency guard runs after the scaffold is generated"
else
    fail_ "T12 ordering: scaffold=$GEN_LINE guard=$GUARD_LINE"
fi
if [ -n "$GUARD_LINE" ] && [ -n "$HVIGOR_LINE" ] && [ "$GUARD_LINE" -lt "$HVIGOR_LINE" ]; then
    pass_ "T12 the dependency guard runs before hvigor starts"
else
    fail_ "T12 ordering: guard=$GUARD_LINE hvigor=$HVIGOR_LINE"
fi
if [ -n "$DIAG_LINE" ] && [ -n "$DIE_LINE" ] && [ "$DIAG_LINE" -lt "$DIE_LINE" ]; then
    pass_ "T12 the 00302013 diagnosis runs on the failure path before the final die"
else
    fail_ "T12 ordering: diagnosis=$DIAG_LINE die=$DIE_LINE"
fi

# ---- T13: the compiled-abc contract gate -----------------------------------------------
section "T13 compiled-shell abc gate (--check-abc)"
# The abc the build ships must carry the payload-in-libs probe and the dotnet.zip fallback
# literals; --check-abc exposes the same check without node/hvigor/SDK.
ABC_FIXTURE="$WORK/abc-good.bin"
printf 'PANDA\0\0\0\0\0\0\0\0\0\0\0\0dotnet-payload bundleCodeDir payload-in-libs dotnet.marker' > "$ABC_FIXTURE"
if sh "$BUILD_SCRIPT" --check-abc "$ABC_FIXTURE" > "$WORK/T13-good.log" 2>&1; then
    pass_ "T13 a complete abc passes (exit 0)"
else
    fail_ "T13 the complete abc fixture was rejected (see $WORK/T13-good.log)"
fi
assert_contains "T13 reports the probe as present" "payload-in-libs probe" "$WORK/T13-good.log"
for _lit in dotnet-payload bundleCodeDir payload-in-libs dotnet.marker; do
    python3 - "$ABC_FIXTURE" "$WORK/abc-missing-$_lit.bin" "$_lit" <<'PY'
import sys
src, dst, drop = sys.argv[1:4]
data = open(src, 'rb').read().replace(drop.encode(), b'x' * len(drop))
open(dst, 'wb').write(data)
PY
    sh "$BUILD_SCRIPT" --check-abc "$WORK/abc-missing-$_lit.bin" > "$WORK/T13-$_lit.log" 2>&1 && _rc=0 || _rc=$?
    assert_rc 1 "$_rc" "T13 an abc without '$_lit' fails"
    assert_contains "T13 names the missing literal '$_lit'" "$_lit" "$WORK/T13-$_lit.log"
done
sh "$BUILD_SCRIPT" --check-abc "$WORK/does-not-exist.abc" > "$WORK/T13-missing.log" 2>&1 && _rc=0 || _rc=$?
assert_rc 2 "$_rc" "T13 an unreadable abc is bad input (exit 2)"
sh "$BUILD_SCRIPT" --check-abc > "$WORK/T13-usage.log" 2>&1 && _rc=0 || _rc=$?
assert_rc 1 "$_rc" "T13 --check-abc without a file is refused"

# ---- T15: the shell source contract gate ------------------------------------------------
section "T15 shell source contract (--check-sources)"
( cd "$SELFTEST_DIR/.." && sh "$BUILD_SCRIPT" --check-sources ) > "$WORK/T15-clean.log" 2>&1
assert_rc 0 $? "T15 the shipped packs pass the source contract"
assert_contains "T15 reports the sources byte-identical" "byte-identical across preview.22/23/24" "$WORK/T15-clean.log"
SRC_FAKE="$WORK/source-fake"
mkdir -p "$SRC_FAKE/ets/pages"
REAL_SOURCE="$SELFTEST_DIR/../packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.24/templates/ets/pages/Index.ets"
cp "$REAL_SOURCE" "$SRC_FAKE/ets/pages/Index.ets"
sh "$BUILD_SCRIPT" --check-sources "$SRC_FAKE" > "$WORK/T15-copy.log" 2>&1
assert_rc 0 $? "T15 an unmodified source copy passes the token gate"
# Each case is <label>|<snippet>; the split uses sed because this host's shell does not expand
# the %%|* parameter forms reliably.
for _case in "getContext():|getContext(this)" "kit import:|from '@ohos.file.fs'" \
             "dynamic kit import:|import('@ohos.file.fs')" "decodeWithStream():|decodeWithStream(raw)" \
             "focusControl:|focusControl.requestFocus('x')"; do
    _re="$(printf '%s' "$_case" | sed 's/|.*//')"
    _snippet="$(printf '%s' "$_case" | sed 's/^[^|]*|//')"
    cp "$REAL_SOURCE" "$SRC_FAKE/ets/pages/Index.ets"
    printf '\nconst injectedProbe: string = "%s";\n' "$_snippet" >> "$SRC_FAKE/ets/pages/Index.ets"
    sh "$BUILD_SCRIPT" --check-sources "$SRC_FAKE" > "$WORK/T15-case.log" 2>&1 && _rc=0 || _rc=$?
    assert_rc 1 "$_rc" "T15 the gate rejects $_re"
    if grep -qF "$_snippet" "$WORK/T15-case.log"; then
        pass_ "T15 the rejection names $_re"
    else
        fail_ "T15 the rejection does not name $_re (see $WORK/T15-case.log)"
    fi
done
cp "$REAL_SOURCE" "$SRC_FAKE/ets/pages/Index.ets"

# ---- T16: the abc provenance gate ---------------------------------------------------------
section "T16 abc provenance gate (--check-pack-abc)"
( cd "$SELFTEST_DIR/.." && sh "$BUILD_SCRIPT" --check-pack-abc ) > "$WORK/T16-clean.log" 2>&1
assert_rc 0 $? "T16 the shipped packs pass the abc provenance gate"
assert_contains "T16 reports the ui variant" "ui" "$WORK/T16-clean.log"
assert_contains "T16 reports the headless variant" "headless" "$WORK/T16-clean.log"
# A self-contained copy of the packs: the negative cases mutate only the copy (ARKTS_PACK_ROOT).
FAKE_REPO="$WORK/fake-repo"
for _v in 22 23 24; do
    mkdir -p "$FAKE_REPO/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.$_v"
    cp -R "$SELFTEST_DIR/../packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.$_v/templates" \
          "$FAKE_REPO/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.$_v/templates"
done
run_pack_gate() { ( cd "$SELFTEST_DIR/.." && ARKTS_PACK_ROOT="$FAKE_REPO" sh "$BUILD_SCRIPT" --check-pack-abc ) > "$WORK/T16-case.log" 2>&1; }
run_pack_gate
assert_rc 0 $? "T16 the copied packs pass"
FAKE_UI="$FAKE_REPO/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.23/templates/ets/modules.ui.abc"
python3 - "$FAKE_UI" <<'PY'
import sys
path = sys.argv[1]
data = bytearray(open(path, 'rb').read())
data[-1] ^= 0xFF
open(path, 'wb').write(bytes(data))
PY
run_pack_gate && _rc=0 || _rc=$?
assert_rc 1 "$_rc" "T16 a corrupted abc fails"
assert_contains "T16 names the sha mismatch" "sha256 does not match" "$WORK/T16-case.log"
python3 - "$FAKE_UI" <<'PY'
import sys
path = sys.argv[1]
data = bytearray(open(path, 'rb').read())
data[-1] ^= 0xFF
open(path, 'wb').write(bytes(data))
PY
printf '\n// source drift probe\n' >> "$FAKE_REPO/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.24/templates/ets/pages/Index.ets"
run_pack_gate && _rc=0 || _rc=$?
assert_rc 1 "$_rc" "T16 a source edit without a rebuild fails"
assert_contains "T16 names the source drift" "source drift" "$WORK/T16-case.log"
rm -f "$FAKE_REPO/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.24/templates/ets/abc-provenance.json"
run_pack_gate && _rc=0 || _rc=$?
assert_rc 1 "$_rc" "T16 a missing provenance record fails"
assert_contains "T16 names the missing record" "missing abc-provenance.json" "$WORK/T16-case.log"
rm -rf "$FAKE_REPO"
# The freshly built dist must match the installed packs (both variants required).
if [ -f "$SELFTEST_DIR/../dist/ets/modules.abc" ] && [ -f "$SELFTEST_DIR/../dist/ets/modules.headless.abc" ]; then
    ( cd "$SELFTEST_DIR/.." && sh "$BUILD_SCRIPT" --check-pack-abc "$SELFTEST_DIR/../dist/ets" ) > "$WORK/T16-dist.log" 2>&1
    assert_rc 0 $? "T16 the built dist matches the installed packs"
    mkdir -p "$WORK/dist-mismatch"
    cp "$SELFTEST_DIR/../dist/ets/modules.abc" "$WORK/dist-mismatch/modules.abc"
    python3 - "$WORK/dist-mismatch/modules.abc" <<'PY'
import sys
path = sys.argv[1]
data = bytearray(open(path, 'rb').read())
data[64] ^= 0xFF
open(path, 'wb').write(bytes(data))
PY
    cp "$SELFTEST_DIR/../dist/ets/modules.headless.abc" "$WORK/dist-mismatch/modules.headless.abc"
    ( cd "$SELFTEST_DIR/.." && sh "$BUILD_SCRIPT" --check-pack-abc "$WORK/dist-mismatch" ) > "$WORK/T16-mismatch.log" 2>&1 && _rc=0 || _rc=$?
    assert_rc 1 "$_rc" "T16 a stale rebuilt artifact fails against the installed pack"
    assert_contains "T16 names the dist mismatch" "differs from the installed" "$WORK/T16-mismatch.log"
else
    skip_ "T16 no dist/ets pair to compare against (build both variants to enable the dist check)"
fi
# Source pins for the gate plumbing.
assert_contains "T16 the gate supports a pack-root override" 'ARKTS_PACK_ROOT' "$BUILD_SCRIPT"
assert_contains "T16 the gate records the abc provenance" "abc-provenance.json" "$BUILD_SCRIPT"
assert_contains "T16 the gate can install the packs" "--install-packs" "$BUILD_SCRIPT"

# ---- T14: the SDK flavor branch (ARKTS_SDK_FLAVOR) --------------------------------------
section "T14 harmony SDK flavor scaffolding"
# A fake DevEco-style HarmonyOS SDK: <root>/default/openharmony/ets (toolchain metadata) and
# <root>/default/hms/ets (the HMS kit declarations). No node/hvigor is involved; only the
# generated build-profile and the flavor validation are exercised.
HARMONY_FAKE="$WORK/harmony-sdk"
mkdir -p "$HARMONY_FAKE/default/openharmony/ets" "$HARMONY_FAKE/default/hms/ets"
cat > "$HARMONY_FAKE/default/openharmony/ets/oh-uni-package.json" <<'EOF'
{ "apiVersion": "23", "platformVersion": "6.1.0", "releaseType": "Release", "version": "6.1.0.105" }
EOF
HSCAFFOLD="$WORK/scaffold-harmony"
( cd "$SELFTEST_DIR/.." && ARKTS_SDK_FLAVOR=harmony ARKTS_HARMONY_SDK_ROOT="$HARMONY_FAKE" \
    sh "$BUILD_SCRIPT" --scaffold-only "$HSCAFFOLD" ) > "$LOG_FILE" 2>&1
assert_rc 0 $? "T14 harmony scaffold exits 0 with a DevEco-style SDK"
HBPROF="$HSCAFFOLD/build-profile.json5"
assert_contains "T14 harmony build-profile sets runtimeOS HarmonyOS" "runtimeOS: 'HarmonyOS'" "$HBPROF"
assert_contains "T14 harmony compatibleSdkVersion defaults to 6.1.0(23)" "compatibleSdkVersion: '6.1.0(23)'" "$HBPROF"
assert_contains "T14 harmony targetSdkVersion is the combined 6.1.0(23)" "targetSdkVersion: '6.1.0(23)'" "$HBPROF"
assert_contains "T14 harmony compileSdkVersion is the combined 6.1.0(23)" "compileSdkVersion: '6.1.0(23)'" "$HBPROF"
assert_contains "T14 harmony keeps useNormalizedOHMUrl false" "useNormalizedOHMUrl: false" "$HBPROF"
assert_contains "T14 the flavor info line names harmony" "flavor harmony" "$LOG_FILE"
( cd "$SELFTEST_DIR/.." && sh "$BUILD_SCRIPT" --check-project-deps "$HSCAFFOLD" ) > "$LOG_FILE" 2>&1
assert_rc 0 $? "T14 --check-project-deps accepts the harmony scaffold"
# The compatibleSdkVersion override stays available (the abc gate is the real ceiling guard).
HSCAFFOLD2="$WORK/scaffold-harmony-override"
( cd "$SELFTEST_DIR/.." && ARKTS_SDK_FLAVOR=harmony ARKTS_HARMONY_SDK_ROOT="$HARMONY_FAKE" \
    ARKTS_COMPATIBLE_SDK_VERSION="5.0.5(17)" sh "$BUILD_SCRIPT" --scaffold-only "$HSCAFFOLD2" ) > "$LOG_FILE" 2>&1
assert_rc 0 $? "T14 the compatibleSdkVersion override is honoured"
assert_contains "T14 override lands in the build-profile" "compatibleSdkVersion: '5.0.5(17)'" "$HSCAFFOLD2/build-profile.json5"
# Missing SDK root / a root without hms: refused with the documented message.
( cd "$SELFTEST_DIR/.." && env -u ARKTS_HARMONY_SDK_ROOT -u DEVECO_SDK_HOME ARKTS_SDK_FLAVOR=harmony \
    sh "$BUILD_SCRIPT" --scaffold-only "$WORK/scaffold-harmony-nosdk" ) > "$LOG_FILE" 2>&1
RC=$?
if [ "$RC" -ne 0 ] && grep -qF "needs a HarmonyOS SDK" "$LOG_FILE"; then
    pass_ "T14 a harmony scaffold without an SDK root is refused clearly"
else
    fail_ "T14 the missing-SDK refusal changed (exit $RC, see $LOG_FILE)"
fi
HARMONY_NOHMS="$WORK/harmony-sdk-nohms"
mkdir -p "$HARMONY_NOHMS/default/openharmony/ets"
cp "$HARMONY_FAKE/default/openharmony/ets/oh-uni-package.json" "$HARMONY_NOHMS/default/openharmony/ets/"
( cd "$SELFTEST_DIR/.." && ARKTS_SDK_FLAVOR=harmony ARKTS_HARMONY_SDK_ROOT="$HARMONY_NOHMS" \
    sh "$BUILD_SCRIPT" --scaffold-only "$WORK/scaffold-harmony-nohms" ) > "$LOG_FILE" 2>&1
RC=$?
if [ "$RC" -ne 0 ] && grep -qF "has no hms/ets" "$LOG_FILE"; then
    pass_ "T14 a HarmonyOS SDK without hms/ets is refused clearly"
else
    fail_ "T14 the no-hms refusal changed (exit $RC, see $LOG_FILE)"
fi
# Source pins: the default flavor and the abc ceiling must not move.
assert_contains "T14 default flavor is openharmony" 'SDK_FLAVOR="${ARKTS_SDK_FLAVOR:-openharmony}"' "$BUILD_SCRIPT"
assert_contains "T14 the harmony branch pins runtimeOS HarmonyOS" "RUNTIME_OS=HarmonyOS" "$BUILD_SCRIPT"
assert_contains "T14 the abc ceiling default stays 13.0.1.0" 'MAX_BC_VERSION="${ARKTS_MAX_BC_VERSION:-13.0.1.0}"' "$BUILD_SCRIPT"
assert_contains "T14 the abc version check reads the header back" "abc version" "$BUILD_SCRIPT"

# ---- summary -------------------------------------------------------------------------
section "summary"
log "checks: $CHECKS, failed: $FAILED"
if [ "$FAILED" -gt 0 ]; then
    log "SELFTEST FAILED - work dir kept: $WORK"
    exit 1
fi
log "SELFTEST OK - tarball member gate, hvigor 00302013 diagnosis and DevEco-aligned scaffold all hold"
if [ "$KEEP" = "1" ]; then
    log "work dir kept (SELFTEST_KEEP=1): $WORK"
else
    rm -rf "$WORK"
fi
exit 0
