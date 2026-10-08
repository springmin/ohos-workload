#!/bin/sh
# selftest-cut-kit.sh - local selftest for scripts/cut-kit.sh (the five-round kit-cutting
# automation with the fail-closed tester-docs gate). Everything runs against synthetic fixture
# repos/artifacts: no real build, no network, no release, no device.
#
#   T0 usage      sh -n passes; --help lists the phases; an unknown option exits 2;
#                 --print-docs-list prints the 18 wave + 8 packed docs contract
#   T1 p0-pass    a fixture whose pins/packs/EXPECT/suite/exports/docs all match -> P0 PASS,
#                 state.env records P0_rc=0, and nothing outside --scratch is written
#   T2 p0-fail    one pack abc drifts from EXPECT_ABC -> P0 FAIL (packs abc group)
#   T3 docs       stale docs fail closed: the block still marks kit #98 current (T3a) or the
#                 block is #99 but the current abc is missing (T3b) -> P0 rc=3 + --bump-docs hint;
#                 a direct `--phase P1` also refuses (no build command printed)
#   T4 resume     state.env with P0_rc=0/P1_rc=0 -> `--phase P0,P1,P2 --execute` prints skip P0/
#                 skip P1, runs P2 against the fixture verifier (strict gate passes) and creates
#                 the transfer sidecar; P2_rc=0 lands in state.env
#   T5 f4-gate    `--phase P4 --execute --i-know` with the confirmation declined ("no"):
#                 prints the clobber plan, exits 3, performs no API snapshot and never calls curl
#                 (a PATH stub records any call)
#   T6 bump-docs  bump-tester-docs.sh on a #98 fixture: --dry-run writes nothing; the real run
#                 lifts the 18 docs + README to #99; a second run is a byte-identical no-op;
#                 a doc back at #98 plus a missing doc refuses with rc!=0 and zero partial writes
#
# Env: SELFTEST_TMPDIR=<dir>  work dir base (default: the approved opencode tmp dir)
#      SELFTEST_KEEP=1       keep the work dir even when all checks pass
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="2 (2026-10-08)"

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

W="$(cd "$(dirname "$0")/.." && pwd)"
CUT="$W/scripts/cut-kit.sh"
BASE="${SELFTEST_TMPDIR:-/data/storage/el2/base/tmp/opencode}"
T="$BASE/selftest-cut-kit.$$"
mkdir -p "$T" || { echo "cannot create $T" >&2; exit 1; }

CHECKS=0
FAILED=0
check() { # <name> <rc>
    CHECKS=$((CHECKS + 1))
    if [ "$2" = 0 ]; then
        printf '   PASS %s\n' "$1"
    else
        printf '   FAIL %s\n' "$1" >&2
        FAILED=$((FAILED + 1))
    fi
}
check_rc() { # <name> <got> <want>
    CHECKS=$((CHECKS + 1))
    if [ "$2" = "$3" ]; then
        printf '   PASS %s (rc=%s)\n' "$1" "$2"
    else
        printf '   FAIL %s (rc=%s, want %s)\n' "$1" "$2" "$3" >&2
        FAILED=$((FAILED + 1))
    fi
}
check_neg() { # <name> <got>; want got != 0
    CHECKS=$((CHECKS + 1))
    if [ "$2" != 0 ]; then
        printf '   PASS %s (rc=%s)\n' "$1" "$2"
    else
        printf '   FAIL %s (rc=0, want non-zero)\n' "$1" >&2
        FAILED=$((FAILED + 1))
    fi
}
assert_contains() { # <name> <file> <pattern>
    if grep -qE "$3" "$2" 2>/dev/null; then check "$1" 0; else check "$1 (missing: $3)" 1; fi
}
assert_not_contains() {
    if grep -qE "$3" "$2" 2>/dev/null; then check "$1 (unexpected: $3)" 1; else check "$1" 0; fi
}

# ------------------------------------------------------------------ fixture builders
new_repo() {
    _d="$1"; mkdir -p "$_d"; git init -q "$_d" 2>/dev/null || return 1
    git -C "$_d" config user.email selftest@example.com
    git -C "$_d" config user.name selftest
}
commit_repo() { git -C "$1" add -A 2>/dev/null; git -C "$1" commit -qm init >/dev/null 2>&1; }

fixture_docs() { # <docs-dir> <kit#> <abc> [<style:zh|en>]
    _dd="$1"; _k="$2"; _abc="$3"; _style="${4:-zh}"
    mkdir -p "$_dd"
    for _f in $(sed -n '/^docs_wave_list()/,/^EOF/p' "$CUT" | sed -n '/^[0-9]/p'); do
        if [ "$_f" = "2026-09-18-ohos-device-validation-checklist.md" ] && [ "$_style" = en ]; then
            printf '# fixture\n\n> **2026-10-08 update (kit #%s — current):** fixture abc %s\n' "$_k" "$_abc" > "$_dd/$_f"
        else
            printf '> **2026-10-08 更新（kit #%s，当前）**：fixture abc %s\n' "$_k" "$_abc" > "$_dd/$_f"
        fi
    done
    printf '> kit #%s 日期口径：fixture\n' "$_k" > "$_dd/README.md"
    printf '# signing guide fixture\n' > "$_dd/2026-09-19-ohos-signing-and-udid-guide.md"
    printf '# final status fixture\n' > "$_dd/2026-09-21-ohos-final-status.md"
}

make_fixture() { # <dir> <docs-kit> <docs-abc>
    _fx="$1"; _dkit="$2"; _dabc="$3"
    rm -rf "$_fx"; mkdir -p "$_fx"
    # ow repo
    _ow="$_fx/ow"
    new_repo "$_ow" || return 1
    mkdir -p "$_ow/scripts" "$_ow/packs" "$_ow/test/maui-platform-verify" "$_ow/src/OpenHarmonyHost" "$_ow/.github/workflows" "$_ow/dist"
    cat > "$_ow/scripts/verify-kit.sh" <<'EOF'
#!/bin/sh
# fixture stub of the shipped verifier: prints the strict-gate shape and exits 0
EXPECT_ABC="${KIT_EXPECTED_ABC:-987654,54321}"
echo "KIT fixture stub (abc=$EXPECT_ABC)"
echo "tree sha256=0000000000000000000000000000000000000000000000000000000000000000"
exit 0
EOF
    for _v in 22 23 24 28; do
        _pd="$_ow/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.$_v/templates/ets"
        mkdir -p "$_pd"
        head -c 987654 /dev/zero > "$_pd/modules.ui.abc" 2>/dev/null || return 1
        head -c 54321 /dev/zero > "$_pd/modules.abc" 2>/dev/null || return 1
    done
    cat > "$_ow/test/maui-platform-verify/Program.cs" <<'EOF'
class Program {
    private const int verifyCheckTotal = 100;
    private const int verifyCheckFloor = 80;
}
EOF
    printf 'sym_a\nsym_b\nsym_c\n' > "$_ow/src/OpenHarmonyHost/host-exports.txt"
    commit_repo "$_ow"
    # maui repo (feature/openharmony tip + remote ref)
    _m="$_fx/maui"
    new_repo "$_m" || return 1
    printf 'fixture maui\n' > "$_m/README.md"
    commit_repo "$_m"
    git -C "$_m" branch -q feature/openharmony 2>/dev/null || true
    _msha="$(git -C "$_m" rev-parse HEAD)"
    git -C "$_m" update-ref refs/remotes/origin/feature/openharmony "$_msha"
    # runtime repo
    _r="$_fx/runtime"
    new_repo "$_r" || return 1
    printf 'fixture runtime\n' > "$_r/README.md"
    commit_repo "$_r"
    # workflow pins -> the maui tip
    for _wf in interaction-regression pixel-regression host-export-contract; do
        printf "env:\n  MAUI_OHOS_REF: \${{ github.event.inputs.x || '%s' }}\n" "$_msha" > "$_ow/.github/workflows/$_wf.yml"
    done
    commit_repo "$_ow"
    # docs
    fixture_docs "$_fx/docs" "$_dkit" "$_dabc"
    # release assets snapshot for the F4 gate fixture
    mkdir -p "$_fx/assets"
    for _rid in 11 22 33 44; do printf '[]\n' > "$_fx/assets/assets-$_rid.json"; done
    printf 'fixture-token\n' > "$_fx/token"
    return 0
}

# ------------------------------------------------------------------ T0 usage
section "T0 usage"
sh -n "$CUT"
check "sh -n scripts/cut-kit.sh" $?
sh "$CUT" --help > "$T/help.txt" 2>&1
check "--help exits 0" $?
assert_contains "--help lists P0..P6" "$T/help.txt" 'P0 preflight'
assert_contains "--help lists P6" "$T/help.txt" 'P6 ci'
sh "$CUT" --nope > "$T/usage.txt" 2>&1
check_rc "unknown option exits 2" "$?" 2
sh "$CUT" --print-docs-list > "$T/docs-list.txt" 2>&1
check "--print-docs-list exits 0" $?
assert_contains "docs list has 18 wave docs" "$T/docs-list.txt" 'wave \(18'
assert_contains "docs list has 8 packed docs" "$T/docs-list.txt" 'packed docs \(8'

# ------------------------------------------------------------------ T1 P0 pass
section "T1 P0 pass (fixture kit #99)"
F1="$T/fixture-pass"; make_fixture "$F1" 99 987,654 || { echo "fixture failed" >&2; exit 1; }
S1="$T/scratch-pass"
OUT1="$T/t1.out"
sh "$CUT" --kit 99 --phase P0 --skip-selftests --execute --scratch "$S1" \
    --ow-repo "$F1/ow" --maui-repo "$F1/maui" --runtime-repo "$F1/runtime" --docs-dir "$F1/docs" > "$OUT1" 2>&1
check_rc "T1 rc=0" "$?" 0
assert_contains "T1 P0 PASS" "$OUT1" 'P0 PASS'
assert_contains "T1 pins check" "$OUT1" 'pins +PASS'
assert_contains "T1 docs check" "$OUT1" 'docs kit #99 +PASS'
grep -q '^P0_rc=0$' "$S1/state.env" 2>/dev/null
check "T1 state P0_rc=0" $?

# ------------------------------------------------------------------ T2 P0 fail (pack drift)
section "T2 P0 fail on pack abc drift"
F2="$T/fixture-drift"; make_fixture "$F2" 99 987,654 || exit 1
head -c 111111 /dev/zero > "$F2/ow/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.23/templates/ets/modules.ui.abc"
S2="$T/scratch-drift"
OUT2="$T/t2.out"
sh "$CUT" --kit 99 --phase P0 --skip-selftests --execute --scratch "$S2" \
    --ow-repo "$F2/ow" --maui-repo "$F2/maui" --runtime-repo "$F2/runtime" --docs-dir "$F2/docs" > "$OUT2" 2>&1
check_neg "T2 rc!=0" "$?"
assert_contains "T2 packs abc FAIL" "$OUT2" 'packs abc +FAIL preview\.23'
assert_contains "T2 P0 FAIL" "$OUT2" 'P0 FAIL'

# ------------------------------------------------------------------ T3 docs stale (fail-closed)
section "T3 docs stale -> fail closed"
F3="$T/fixture-stale"; make_fixture "$F3" 98 987,654 || exit 1
S3="$T/scratch-stale"
OUT3="$T/t3.out"
sh "$CUT" --kit 99 --phase P0 --skip-selftests --execute --scratch "$S3" \
    --ow-repo "$F3/ow" --maui-repo "$F3/maui" --runtime-repo "$F3/runtime" --docs-dir "$F3/docs" > "$OUT3" 2>&1
check_rc "T3a stale docs rc=3" "$?" 3
assert_contains "T3a bump-docs hint" "$OUT3" 'bump-docs'
assert_contains "T3a current block mismatch" "$OUT3" 'current kit block is \[98\]'
# T3b: right block, wrong abc
F3B="$T/fixture-abc"; make_fixture "$F3B" 99 111,111 || exit 1
S3B="$T/scratch-abc"
OUT3B="$T/t3b.out"
sh "$CUT" --kit 99 --phase P0 --skip-selftests --execute --scratch "$S3B" \
    --ow-repo "$F3B/ow" --maui-repo "$F3B/maui" --runtime-repo "$F3B/runtime" --docs-dir "$F3B/docs" > "$OUT3B" 2>&1
check_rc "T3b stale abc rc=3" "$?" 3
assert_contains "T3b abc mismatch named" "$OUT3B" 'missing the current shell abc 987654'
# P1 alone must also refuse (fail-closed) and print no build command
OUT3P="$T/t3p.out"
sh "$CUT" --kit 99 --phase P1 --skip-selftests --dry-run --scratch "$S3" \
    --ow-repo "$F3/ow" --maui-repo "$F3/maui" --runtime-repo "$F3/runtime" --docs-dir "$F3/docs" > "$OUT3P" 2>&1
check_rc "T3c P1 refuses stale docs rc=3" "$?" 3
assert_contains "T3c P1 refuses message" "$OUT3P" 'refusing to build'
assert_not_contains "T3c no build command" "$OUT3P" 'make-device-test-kit'

# ------------------------------------------------------------------ T4 resume
section "T4 resume (P0/P1 recorded -> P2 runs)"
F4="$T/fixture-resume"; make_fixture "$F4" 99 987,654 || exit 1
S4="$T/scratch-resume"; mkdir -p "$S4/device-test-kit"
printf 'P0_rc=0\nP1_rc=0\n' > "$S4/state.env"
printf 'fixture sums\n' > "$S4/device-test-kit/SHA256SUMS"
tar -czf "$S4/device-test-kit.tar.gz" -C "$S4/device-test-kit" . 2>/dev/null
OUT4="$T/t4.out"
sh "$CUT" --kit 99 --phase P0,P1,P2 --skip-selftests --execute --scratch "$S4" \
    --ow-repo "$F4/ow" --maui-repo "$F4/maui" --runtime-repo "$F4/runtime" --docs-dir "$F4/docs" > "$OUT4" 2>&1
check_rc "T4 rc=0" "$?" 0
assert_contains "T4 skip P0" "$OUT4" 'skip P0'
assert_contains "T4 skip P1" "$OUT4" 'skip P1'
assert_contains "T4 P2 PASS" "$OUT4" 'P2 PASS'
grep -q '^P2_rc=0$' "$S4/state.env" 2>/dev/null
check "T4 state P2_rc=0" $?
[ -f "$S4/device-test-kit.tar.gz.sha256" ]
check "T4 sidecar created" $?

# ------------------------------------------------------------------ T5 F4 confirmation gate
section "T5 F4 gate declined -> no writes"
F5="$T/fixture-f4"; make_fixture "$F5" 99 987,654 || exit 1
S5="$T/scratch-f4"
mkdir -p "$T/pathstub"
cat > "$T/pathstub/curl" <<EOF
#!/bin/sh
echo "curl \$*" >> "$T/curl-calls.log"
exit 77
EOF
chmod +x "$T/pathstub/curl"
OUT5="$T/t5.out"
printf 'no\n' | PATH="$T/pathstub:$PATH" sh "$CUT" --kit 99 --phase P4 --execute --i-know --skip-selftests \
    --scratch "$S5" --ow-repo "$F5/ow" --maui-repo "$F5/maui" --runtime-repo "$F5/runtime" --docs-dir "$F5/docs" \
    --release-ids "dtk=11 latest=22 versioned=33 sdkrc2=44" --assets-dir "$F5/assets" --token-file "$F5/token" > "$OUT5" 2>&1
check_rc "T5 declined rc=3" "$?" 3
assert_contains "T5 clobber plan printed" "$OUT5" 'clobber plan'
assert_contains "T5 plan names the kit asset" "$OUT5" 'device-test-kit.tar.gz'
assert_contains "T5 declined message" "$OUT5" 'confirmation declined'
ls "$S5"/assets-*-before.json >/dev/null 2>&1
check_neg "T5 no release snapshots written" "$?"
[ ! -s "$T/curl-calls.log" ]
check "T5 no curl call" $?
# T5b: execute without --i-know refuses
OUT5B="$T/t5b.out"
sh "$CUT" --kit 99 --phase P4 --execute --skip-selftests --scratch "$S5" \
    --ow-repo "$F5/ow" --maui-repo "$F5/maui" --runtime-repo "$F5/runtime" --docs-dir "$F5/docs" \
    --release-ids "dtk=11 latest=22 versioned=33 sdkrc2=44" --assets-dir "$F5/assets" --token-file "$F5/token" > "$OUT5B" 2>&1
check_rc "T5b missing --i-know rc=3" "$?" 3
assert_contains "T5b i-know message" "$OUT5B" 'requires --execute --i-know'

# ------------------------------------------------------------------ T6 bump-tester-docs
section "T6 bump-tester-docs (mechanical kit bump)"
BUMP="$W/scripts/bump-tester-docs.sh"
sh -n "$BUMP"
check "sh -n scripts/bump-tester-docs.sh" $?
F6="$T/fixture-bump"; make_fixture "$F6" 98 987,654 || exit 1
fixture_docs "$F6/docs" 98 987,654 en   # checklist in the en marker style (kit #98 — current))
_sum6() { find "$F6/docs" -name '*.md' -exec sha256sum {} \; | sort; }
_sum6 > "$T/t6-before"
sh "$BUMP" --kit 99 --docs-dir "$F6/docs" --abc 987654 --dry-run > "$T/t6a.out" 2>&1
check_rc "T6a dry-run rc=0" "$?" 0
assert_contains "T6a dry-run plan" "$T/t6a.out" 'would change'
_sum6 > "$T/t6a-after"
cmp -s "$T/t6-before" "$T/t6a-after"
check "T6a dry-run writes nothing" $?
sh "$BUMP" --kit 99 --docs-dir "$F6/docs" --abc 987654 > "$T/t6b.out" 2>&1
check_rc "T6b bump 98->99 rc=0" "$?" 0
grep -qF 'kit #99，当前）' "$F6/docs/2026-09-20-ohos-tester-quickstart.md"
check "T6b zh marker bumped" $?
grep -qF 'kit #99 — current)' "$F6/docs/2026-09-18-ohos-device-validation-checklist.md"
check "T6b en marker bumped" $?
grep -qF 'kit #99 日期口径' "$F6/docs/README.md"
check "T6b README index bumped" $?
_sum6 > "$T/t6b-after"
sh "$BUMP" --kit 99 --docs-dir "$F6/docs" --abc 987654 > "$T/t6c.out" 2>&1
check_rc "T6c idempotent rc=0" "$?" 0
assert_contains "T6c already message" "$T/t6c.out" 'already at kit #99'
_sum6 > "$T/t6c-after"
cmp -s "$T/t6b-after" "$T/t6c-after"
check "T6c idempotent (bytes unchanged)" $?
sed -i 's/kit #99，当前）/kit #98，当前）/' "$F6/docs/2026-09-22-ohos-tester-runner.md"
rm -f "$F6/docs/2026-09-24-ohos-kit-gap-analysis.md"
_sum6 > "$T/t6-before-refuse"
sh "$BUMP" --kit 99 --docs-dir "$F6/docs" --abc 987654 > "$T/t6d.out" 2>&1
check_neg "T6d partial missing rc!=0" "$?"
assert_contains "T6d names the missing doc" "$T/t6d.out" 'kit-gap-analysis.*missing'
_sum6 > "$T/t6d-after"
cmp -s "$T/t6-before-refuse" "$T/t6d-after"
check "T6d rollback (no partial writes)" $?

# ------------------------------------------------------------------ summary
section "summary"
printf 'checks=%s failed=%s\n' "$CHECKS" "$FAILED"
if [ "$FAILED" != 0 ]; then
    printf 'selftest-cut-kit: FAILED (%s/%s); work dir kept: %s\n' "$FAILED" "$CHECKS" "$T" >&2
    exit 1
fi
log "selftest-cut-kit: OK ($CHECKS checks)"
if [ "${SELFTEST_KEEP:-0}" = 1 ]; then
    log "work dir kept (SELFTEST_KEEP=1): $T"
else
    rm -rf "$T"
fi
exit 0
