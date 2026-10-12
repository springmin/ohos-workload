#!/bin/sh
# selftest-cut-kit.sh - local selftest for scripts/cut-kit.sh (the five-round kit-cutting
# automation with the fail-closed tester-docs gate). Everything runs against synthetic fixture
# repos/artifacts: no real build, no network, no release, no device.
#
#   T0 usage      sh -n passes; --help lists the phases; an unknown option exits 2;
#                 --print-docs-list prints the 18 wave + 8 packed docs contract
#   T1 p0-pass    a fixture whose pins/packs/EXPECT/suite/exports/docs all match and whose
#                 build-use install pack (--dotnet fixture root) mirrors the repo pack -> P0 PASS,
#                 state.env records P0_rc=0, and nothing outside --scratch is written
#   T1b install   the build-use install pack gate is fail-closed: a drifted install pack file
#                 (abc) and a missing install pack both fail P0 and name the group
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
#                 lifts the 18 docs + README to #99 and refreshes the abc references on the
#                 bumped blocks (plain 576664 and grouped 576,664 kept per value; pairs incl.
#                 the headless, zh `）**/H（` and en `headless H` slots) while historical
#                 references stay; a second run is a byte-identical no-op; a #99/old-abc
#                 fixture gets an abc-only refresh; a missing doc or a doc without any current
#                 abc refuses with rc!=0 and zero partial writes; a mid-apply write failure
#                 (read-only README) rolls the already-written docs back; the bumped docs pass
#                 a fixture P0 docs gate. --abc-sha refreshes the sha adjacent to the grouped
#                 ui abc in the zh `（`sha…`）` and the en ` / `sha…`` styles (target lines
#                 only; headless + historical shas stay), a doc without an adjacent ui sha
#                 refuses with zero writes, an invalid --abc-sha is a usage error, and the
#                 sha refresh is idempotent (checked count: 101)
#   T7 p3-anchor  P3 with synthetic pack stubs + sdk fixtures: the dry run prints the seed plan
#                 and writes nothing; the `=`, `:=` and JSON anchor spellings are each replaced
#                 with the freshly built bundle sha end to end; the cumulative seed is
#                 auto-resolved from the sdk versions.env anchor via a local candidate and
#                 staged into .feed; a missing anchor, an ambiguous file (two anchors), a
#                 missing seed and an explicit --seed-bundle (with the mismatch warning) all
#                 follow the documented fail-closed / explicit paths; a resumed anchor is a
#                 no-op with no extra commit
#   T8 p4-p6-dry  `--phase P4,P5,P6 --dry-run`: prints the upload clobber plan and the Integrity
#                 notes template, previews RELEASE-VALUES, parses the upload/presign/manifest
#                 hooks (a syntax-broken hook fails closed) and asserts zero writes: no scratch
#                 dir, no curl call, no hook run, byte-identical fixture tree
#
# Env: SELFTEST_TMPDIR=<dir>  work dir base (default: the approved opencode tmp dir)
#      SELFTEST_KEEP=1       keep the work dir even when all checks pass
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="6 (2026-10-12; 185 checks, was 109)"

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

group_fixture() { # 987654 -> 987,654 (keeps the bump fixture abc texts realistic)
    printf '%s' "$1" | sed -e 's/^\([0-9]\{1,\}\)\([0-9][0-9][0-9]\)$/\1,\2/'
}

fixture_docs() { # <docs-dir> <kit#> <ui-plain> <hl-plain> [<style:zh|en>]
    _dd="$1"; _k="$2"; _ui="$3"; _hl="$4"; _style="${5:-zh}"
    _uig="$(group_fixture "$_ui")"; _hlg="$(group_fixture "$_hl")"; _prev=$((_k - 1))
    mkdir -p "$_dd"
    for _f in $(sed -n '/^docs_wave_list()/,/^EOF/p' "$CUT" | sed -n '/^[0-9]/p'); do
        if [ "$_f" = "2026-09-18-ohos-device-validation-checklist.md" ] && [ "$_style" = en ]; then
            printf '# fixture\n\n> **2026-10-08 update (kit #%s — current):** fixture; unified parameter: `sh verify-kit.sh` green as-is (shipped default re-anchored %s,%s) / `--expected-abc %s` (#%s=123456 old values FAIL by design); shell abc **%s / `deadbeef…`**, headless %s / `feedbeef…`.\n' \
                "$_k" "$_ui" "$_hl" "$_ui" "$_prev" "$_uig" "$_hlg" > "$_dd/$_f"
        else
            printf '> **2026-10-08 更新（kit #%s，当前）**：fixture；**统一参数**：`sh verify-kit.sh` 裸跑即绿（包内默认重锚 **%s,%s**）/ `--expected-abc %s`（#%s=123456 旧值 FAIL 属预期）；壳 abc **%s（`deadbeef…`）**/%s（`feedbeef…`）。\n' \
                "$_k" "$_ui" "$_hl" "$_ui" "$_prev" "$_uig" "$_hlg" > "$_dd/$_f"
        fi
    done
    printf '> kit #%s 日期口径：fixture abc **%s（`deadbeef…`）**/%s（`feedbeef…`）\n' "$_k" "$_uig" "$_hlg" > "$_dd/README.md"
    printf '# signing guide fixture\n' > "$_dd/2026-09-19-ohos-signing-and-udid-guide.md"
    printf '# final status fixture\n' > "$_dd/2026-09-21-ohos-final-status.md"
}

# fixture_install_sync <fx>: mirror the fixture repo's .28 SDK pack into the fixture install
# root (the --dotnet root the P0 install-pack gate resolves). The gate checks the last
# PACK_VERSIONS entry (.28) - the fixture has no manifests dir, so the fallback applies.
fixture_install_sync() {
    _fx="$1"
    _dst="$_fx/installroot/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.28"
    rm -rf "$_dst"
    mkdir -p "$(dirname "$_dst")"
    cp -R "$_fx/ow/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.28" "$_dst"
}

make_fixture() { # <dir> <docs-kit> <docs-ui> <docs-hl>
    _fx="$1"; _dkit="$2"; _dui="$3"; _dhl="$4"
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
        mkdir -p "$_ow/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.$_v/targets" \
                 "$_ow/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.$_v/tools" \
                 "$_ow/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.$_v/templates/resources/rawfile"
        printf 'fixture hap targets %s\n' "$_v" > "$_ow/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.$_v/targets/OpenHarmony.Hap.targets"
        printf 'fixture tasks %s\n' "$_v" > "$_ow/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.$_v/tools/Microsoft.OpenHarmony.Tasks.dll"
        for _rf in media.html hls.min.js hls.LICENSE.txt; do
            printf 'fixture rawfile %s %s\n' "$_v" "$_rf" > "$_ow/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.$_v/templates/resources/rawfile/$_rf"
        done
    done
    # build-use install root (the P0 install-pack gate compares against this; the manifest is
    # absent in the fixture so the gate falls back to the last PACK_VERSIONS entry = .28)
    mkdir -p "$_fx/installroot"
    printf '#!/bin/sh\nexit 1\n' > "$_fx/installroot/dotnet"
    chmod +x "$_fx/installroot/dotnet"
    fixture_install_sync "$_fx"
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
    fixture_docs "$_fx/docs" "$_dkit" "$_dui" "$_dhl"
    # release assets snapshot for the F4 gate fixture
    mkdir -p "$_fx/assets"
    for _rid in 11 22 33 44; do printf '[]\n' > "$_fx/assets/assets-$_rid.json"; done
    printf 'fixture-token\n' > "$_fx/token"
    return 0
}

# p3_ow_fixture <dir>: make_fixture plus the four P3 pack stubs (each records its call in
# $PWD/.p3-calls) and a deterministic "fixed" bundle the pack-workload-bundle stub copies, so
# every P3 run produces the same bundle sha.
p3_ow_fixture() {
    _fx="$1"
    make_fixture "$_fx" 99 987654 54321 || return 1
    _ow="$_fx/ow"
    mkdir -p "$_fx/bundle-src/openharmony-workload-1.0.0-preview.99/feed"
    printf 'fixture fixed bundle pack\n' > "$_fx/bundle-src/openharmony-workload-1.0.0-preview.99/feed/fixed-fixture.nupkg"
    ( cd "$_fx/bundle-src" && tar -czf "$_ow/bundle-fixed.tar.gz" openharmony-workload-1.0.0-preview.99 ) || return 1
    cat > "$_ow/scripts/prepare-packs.sh" <<'EOF'
#!/bin/sh
echo "prepare-packs" >> "$PWD/.p3-calls"
EOF
    cat > "$_ow/scripts/pack-local-workload.sh" <<'EOF'
#!/bin/sh
echo "pack-local $1" >> "$PWD/.p3-calls"
mkdir -p "$PWD/.feed"
printf 'fixture manifest pack\n' > "$PWD/.feed/local-fixture.nupkg"
EOF
    cat > "$_ow/scripts/pack-workload-bundle.sh" <<'EOF'
#!/bin/sh
echo "pack-workload-bundle" >> "$PWD/.p3-calls"
mkdir -p "$PWD/dist"
rm -f "$PWD"/dist/openharmony-workload-*.tar.gz
cp "$PWD/bundle-fixed.tar.gz" "$PWD/dist/openharmony-workload-1.0.0-preview.99.tar.gz"
EOF
    cat > "$_ow/scripts/release-checksums.sh" <<'EOF'
#!/bin/sh
echo "release-checksums" >> "$PWD/.p3-calls"
( cd "$PWD/dist" && sha256sum openharmony-workload-1.0.0-preview.99.tar.gz > SHA256SUMS )
EOF
    chmod +x "$_ow"/scripts/*.sh
    commit_repo "$_ow"
    return 0
}

# p3_sdk_fixture <dir> <sha> <form>: a minimal sdk-ohos fixture whose versions.env carries the
# anchor in the requested spelling (colon|plain|json|none|double) plus stub installer tests;
# origin/feature/openharmony points at the commit (worktree add resolves it offline).
p3_sdk_fixture() {
    _fx="$1"; _sha="$2"; _form="$3"
    new_repo "$_fx" || return 1
    mkdir -p "$_fx/eng/ohos-install/tests"
    case "$_form" in
        colon)
            {
                printf ': "${WORKLOAD_BUNDLE_VERSION:=1.0.0-preview.99}"\n'
                printf ': "${WORKLOAD_BUNDLE_SHA256:=%s}"\n' "$_sha"
                printf ': "${GH_USER:=springmin}"\n'
            } > "$_fx/eng/ohos-install/versions.env" ;;
        plain)
            {
                printf 'WORKLOAD_BUNDLE_VERSION=1.0.0-preview.99\n'
                printf 'WORKLOAD_BUNDLE_SHA256=%s\n' "$_sha"
            } > "$_fx/eng/ohos-install/versions.env" ;;
        json)
            printf '{\n  "WORKLOAD_BUNDLE_VERSION": "1.0.0-preview.99",\n  "WORKLOAD_BUNDLE_SHA256": "%s"\n}\n' "$_sha" \
                > "$_fx/eng/ohos-install/versions.env" ;;
        none)
            printf '# no bundle anchor in this fixture\nWORKLOAD_BUNDLE_VERSION=1.0.0-preview.99\n' \
                > "$_fx/eng/ohos-install/versions.env" ;;
        double)
            {
                printf 'WORKLOAD_BUNDLE_SHA256=%s\n' "$_sha"
                printf ': "${WORKLOAD_BUNDLE_SHA256:=%s}"\n' "$_sha"
            } > "$_fx/eng/ohos-install/versions.env" ;;
        *) return 1 ;;
    esac
    for _t in test-installer-verification test-hostfeed-verification test-codesign-filewrites; do
        printf '#!/bin/sh\necho %s >> "$PWD/.sdk-tests"\n' "$_t" > "$_fx/eng/ohos-install/tests/$_t.sh"
    done
    commit_repo "$_fx"
    git -C "$_fx" update-ref refs/remotes/origin/feature/openharmony "$(git -C "$_fx" rev-parse HEAD)"
    return 0
}

# p3_seed_tar <out> <nupkg-name>: a previous-bundle seed carrying one feed/*.nupkg member.
p3_seed_tar() {
    _out="$1"; _name="$2"
    mkdir -p "$T/p3-seed-src/feed"
    printf 'fixture seed pack %s\n' "$_name" > "$T/p3-seed-src/feed/$_name"
    tar -czf "$_out" -C "$T/p3-seed-src" feed
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
F1="$T/fixture-pass"; make_fixture "$F1" 99 987654 54321 || { echo "fixture failed" >&2; exit 1; }
S1="$T/scratch-pass"
OUT1="$T/t1.out"
sh "$CUT" --kit 99 --phase P0 --skip-selftests --execute --scratch "$S1" \
    --ow-repo "$F1/ow" --maui-repo "$F1/maui" --runtime-repo "$F1/runtime" --docs-dir "$F1/docs" \
    --dotnet "$F1/installroot/dotnet" > "$OUT1" 2>&1
check_rc "T1 rc=0" "$?" 0
assert_contains "T1 P0 PASS" "$OUT1" 'P0 PASS'
assert_contains "T1 pins check" "$OUT1" 'pins +PASS'
assert_contains "T1 docs check" "$OUT1" 'docs kit #99 +PASS'
assert_contains "T1 install pack check" "$OUT1" 'install pack +PASS'
grep -q '^P0_rc=0$' "$S1/state.env" 2>/dev/null
check "T1 state P0_rc=0" $?
grep -q '^install_pack_ver=1.0.0-preview.28$' "$S1/state.env" 2>/dev/null
check "T1 state install_pack_ver recorded" $?

# T1b: the install-pack gate is fail-closed: a drifted install abc fails P0 and names the file
F1B="$T/fixture-install-drift"; make_fixture "$F1B" 99 987654 54321 || exit 1
head -c 424242 /dev/zero > "$F1B/installroot/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.28/templates/ets/modules.ui.abc"
S1B="$T/scratch-install-drift"
OUT1B="$T/t1b.out"
sh "$CUT" --kit 99 --phase P0 --skip-selftests --execute --scratch "$S1B" \
    --ow-repo "$F1B/ow" --maui-repo "$F1B/maui" --runtime-repo "$F1B/runtime" --docs-dir "$F1B/docs" \
    --dotnet "$F1B/installroot/dotnet" > "$OUT1B" 2>&1
check_neg "T1b drifted install pack rc!=0" "$?"
assert_contains "T1b gate names the drifted file" "$OUT1B" 'install pack +FAIL templates/ets/modules.ui.abc'
assert_contains "T1b P0 FAIL" "$OUT1B" 'P0 FAIL'
# T1c: a missing install pack also fails closed (never silently skipped)
F1C="$T/fixture-install-missing"; make_fixture "$F1C" 99 987654 54321 || exit 1
rm -rf "$F1C/installroot/packs"
S1C="$T/scratch-install-missing"
OUT1C="$T/t1c.out"
sh "$CUT" --kit 99 --phase P0 --skip-selftests --execute --scratch "$S1C" \
    --ow-repo "$F1C/ow" --maui-repo "$F1C/maui" --runtime-repo "$F1C/runtime" --docs-dir "$F1C/docs" \
    --dotnet "$F1C/installroot/dotnet" > "$OUT1C" 2>&1
check_neg "T1c missing install pack rc!=0" "$?"
assert_contains "T1c missing pack named" "$OUT1C" 'install pack FAIL: cannot resolve the build-use dotnet pack root'

# ------------------------------------------------------------------ T2 P0 fail (pack drift)
section "T2 P0 fail on pack abc drift"
F2="$T/fixture-drift"; make_fixture "$F2" 99 987654 54321 || exit 1
head -c 111111 /dev/zero > "$F2/ow/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.23/templates/ets/modules.ui.abc"
S2="$T/scratch-drift"
OUT2="$T/t2.out"
sh "$CUT" --kit 99 --phase P0 --skip-selftests --execute --scratch "$S2" \
    --ow-repo "$F2/ow" --maui-repo "$F2/maui" --runtime-repo "$F2/runtime" --docs-dir "$F2/docs" \
    --dotnet "$F2/installroot/dotnet" > "$OUT2" 2>&1
check_neg "T2 rc!=0" "$?"
assert_contains "T2 packs abc FAIL" "$OUT2" 'packs abc +FAIL preview\.23'
assert_contains "T2 P0 FAIL" "$OUT2" 'P0 FAIL'

# ------------------------------------------------------------------ T3 docs stale (fail-closed)
section "T3 docs stale -> fail closed"
F3="$T/fixture-stale"; make_fixture "$F3" 98 987654 54321 || exit 1
S3="$T/scratch-stale"
OUT3="$T/t3.out"
sh "$CUT" --kit 99 --phase P0 --skip-selftests --execute --scratch "$S3" \
    --ow-repo "$F3/ow" --maui-repo "$F3/maui" --runtime-repo "$F3/runtime" --docs-dir "$F3/docs" \
    --dotnet "$F3/installroot/dotnet" > "$OUT3" 2>&1
check_rc "T3a stale docs rc=3" "$?" 3
assert_contains "T3a bump-docs hint" "$OUT3" 'bump-docs'
assert_contains "T3a current block mismatch" "$OUT3" 'current kit block is \[98\]'
# T3b: right block, wrong abc
F3B="$T/fixture-abc"; make_fixture "$F3B" 99 111111 54321 || exit 1
S3B="$T/scratch-abc"
OUT3B="$T/t3b.out"
sh "$CUT" --kit 99 --phase P0 --skip-selftests --execute --scratch "$S3B" \
    --ow-repo "$F3B/ow" --maui-repo "$F3B/maui" --runtime-repo "$F3B/runtime" --docs-dir "$F3B/docs" \
    --dotnet "$F3B/installroot/dotnet" > "$OUT3B" 2>&1
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
F4="$T/fixture-resume"; make_fixture "$F4" 99 987654 54321 || exit 1
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
F5="$T/fixture-f4"; make_fixture "$F5" 99 987654 54321 || exit 1
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
section "T6 bump-tester-docs (kit + abc refresh)"
BUMP="$W/scripts/bump-tester-docs.sh"
sh -n "$BUMP"
check "sh -n scripts/bump-tester-docs.sh" $?

# F6: kit #98, abc 987654/54321 written in the plain/grouped/pair forms of the real wave
F6="$T/fixture-bump"; make_fixture "$F6" 98 987654 54321 || exit 1
fixture_docs "$F6/docs" 98 987654 54321 en   # checklist in the en marker style (kit #98 — current))
DQ="$F6/docs/2026-09-20-ohos-tester-quickstart.md"
DE="$F6/docs/2026-09-18-ohos-device-validation-checklist.md"
_sum6() { find "$F6/docs" -name '*.md' -exec sha256sum {} \; | sort; }
_sum6 > "$T/t6-before"

# T6a: dry-run prints the full wave plan (abc refresh included) and writes nothing
sh "$BUMP" --kit 99 --docs-dir "$F6/docs" --abc 111111,55555 --dry-run > "$T/t6a.out" 2>&1
check_rc "T6a dry-run rc=0" "$?" 0
assert_contains "T6a dry-run plan (19 files)" "$T/t6a.out" '19 file\(s\) would change'
assert_contains "T6a plan refreshes the abc" "$T/t6a.out" 'abc -> 111111,55555'
_sum6 > "$T/t6a-after"
cmp -s "$T/t6-before" "$T/t6a-after"
check "T6a dry-run writes nothing" $?

# T6b: apply - markers, plain/grouped ui, pairs with the new headless; history stays
sh "$BUMP" --kit 99 --docs-dir "$F6/docs" --abc 111111,55555 > "$T/t6b.out" 2>&1
check_rc "T6b bump 98->99 rc=0" "$?" 0
grep -qF 'kit #99，当前）' "$DQ"; check "T6b zh marker bumped" $?
grep -qF 'kit #99 — current)' "$DE"; check "T6b en marker bumped" $?
grep -qF 'kit #99 日期口径' "$F6/docs/README.md"; check "T6b README index bumped" $?
grep -qF -e '--expected-abc 111111' "$DQ"; check "T6b plain expected-abc refreshed" $?
grep -qF '重锚 **111111,55555**' "$DQ"; check "T6b pair + headless refreshed" $?
grep -qF 'abc **111,111（' "$DQ"; check "T6b grouped abc refreshed" $?
grep -qF '）**/55,555（' "$DQ"; check "T6b zh grouped headless refreshed" $?
grep -qF 're-anchored 111111,55555)' "$DE"; check "T6b en pair refreshed" $?
grep -qF 'headless 55,555' "$DE"; check "T6b en headless refreshed" $?
grep -qF 'abc **111,111' "$F6/docs/README.md"; check "T6b README abc refreshed" $?
grep -qF '#97=123456' "$DQ"; check "T6b historical reference kept" $?
grep -qE '987654|987,654' "$DQ"; check_neg "T6b old abc gone from the block" "$?"
_sum6 > "$T/t6b-after"

# T6c: idempotent - a second run with the same kit/abc is a byte-identical no-op
sh "$BUMP" --kit 99 --docs-dir "$F6/docs" --abc 111111,55555 > "$T/t6c.out" 2>&1
check_rc "T6c idempotent rc=0" "$?" 0
assert_contains "T6c already message" "$T/t6c.out" 'already at kit #99'
_sum6 > "$T/t6c-after"
cmp -s "$T/t6b-after" "$T/t6c-after"
check "T6c idempotent (bytes unchanged)" $?

# T6h: the bumped docs pass the P0 docs gate once the packs carry the new abc
for _v in 22 23 24 28; do
    _pd="$F6/ow/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.$_v/templates/ets"
    head -c 111111 /dev/zero > "$_pd/modules.ui.abc"
    head -c 55555 /dev/zero > "$_pd/modules.abc"
done
sed -i 's/987654,54321/111111,55555/' "$F6/ow/scripts/verify-kit.sh"
fixture_install_sync "$F6"
OUT6H="$T/t6h.out"
sh "$CUT" --kit 99 --phase P0 --dry-run --skip-selftests --scratch "$T/scratch-bump-p0" \
    --ow-repo "$F6/ow" --maui-repo "$F6/maui" --runtime-repo "$F6/runtime" --docs-dir "$F6/docs" \
    --dotnet "$F6/installroot/dotnet" > "$OUT6H" 2>&1
check_rc "T6h P0 rc=0 after the bump" "$?" 0
assert_contains "T6h P0 PASS" "$OUT6H" 'P0 PASS'
assert_contains "T6h docs gate carries the new abc" "$OUT6H" 'docs kit #99 +PASS \(18 wave docs; abc 111111; index ok\)'
assert_contains "T6h install pack check" "$OUT6H" 'install pack +PASS'

# T6d: a missing doc refuses the whole wave with zero partial writes
sed -i 's/kit #99，当前）/kit #98，当前）/' "$F6/docs/2026-09-22-ohos-tester-runner.md"
rm -f "$F6/docs/2026-09-24-ohos-kit-gap-analysis.md"
_sum6 > "$T/t6-before-refuse"
sh "$BUMP" --kit 99 --docs-dir "$F6/docs" --abc 111111,55555 > "$T/t6d.out" 2>&1
check_neg "T6d missing doc refuses" "$?"
assert_contains "T6d names the missing doc" "$T/t6d.out" 'kit-gap-analysis.*missing'
_sum6 > "$T/t6d-after"
cmp -s "$T/t6-before-refuse" "$T/t6d-after"
check "T6d refusal writes nothing (transactional)" $?

# T6e: docs already at kit #99 but with the old abc -> abc-only refresh, no marker churn
F6E="$T/fixture-abc-refresh"; make_fixture "$F6E" 99 987654 54321 || exit 1
sh "$BUMP" --kit 99 --docs-dir "$F6E/docs" --abc 111111,55555 > "$T/t6e.out" 2>&1
check_rc "T6e abc-only refresh rc=0" "$?" 0
assert_contains "T6e refresh message" "$T/t6e.out" 'refresh 2026-09-20-ohos-tester-quickstart.md: abc -> 111111,55555'
assert_not_contains "T6e no false marker bump" "$T/t6e.out" 'bump 2026-09-20-ohos-tester-quickstart.md'
DQE="$F6E/docs/2026-09-20-ohos-tester-quickstart.md"
grep -qF 'kit #99，当前）' "$DQE"; check "T6e marker kept at kit #99" $?
grep -qF 'abc **111,111' "$DQE"; check "T6e abc refreshed in place" $?
grep -qE '987654|987,654' "$DQE"; check_neg "T6e old abc gone" "$?"

# T6f: a doc left without any current abc refuses (fail-closed, zero writes)
F6F="$T/fixture-no-abc"; make_fixture "$F6F" 98 987654 54321 || exit 1
printf '> **2026-10-08 更新（kit #98，当前）**：fixture without any abc\n' \
    > "$F6F/docs/2026-09-20-ohos-tester-quickstart.md"
_sum6f() { find "$F6F/docs" -name '*.md' -exec sha256sum {} \; | sort; }
_sum6f > "$T/t6f-before"
sh "$BUMP" --kit 99 --docs-dir "$F6F/docs" --abc 111111,55555 > "$T/t6f.out" 2>&1
check_neg "T6f missing abc refuses" "$?"
assert_contains "T6f names the missing abc" "$T/t6f.out" 'missing the current shell abc 111111'
_sum6f > "$T/t6f-after"
cmp -s "$T/t6f-before" "$T/t6f-after"
check "T6f refusal writes nothing" $?

# T6g: a mid-apply write failure (read-only README) rolls the written docs back
F6G="$T/fixture-rollback"; make_fixture "$F6G" 98 987654 54321 || exit 1
chmod 444 "$F6G/docs/README.md"
printf 'probe\n' > "$T/rowprobe"; chmod 444 "$T/rowprobe"
if cp /dev/null "$T/rowprobe" 2>/dev/null; then
    check "T6g rollback (skipped: read-only files are writable here)" 0
else
    _sum6g() { find "$F6G/docs" -name '*.md' -exec sha256sum {} \; | sort; }
    _sum6g > "$T/t6g-before"
    sh "$BUMP" --kit 99 --docs-dir "$F6G/docs" --abc 111111,55555 > "$T/t6g.out" 2>&1
    check_neg "T6g write failure rc!=0" "$?"
    assert_contains "T6g rollback message" "$T/t6g.out" 'rolling back'
    _sum6g > "$T/t6g-after"
    cmp -s "$T/t6g-before" "$T/t6g-after"
    check "T6g rollback restores every file" $?
fi
chmod 644 "$F6G/docs/README.md"

# T6i: --abc-sha refreshes the sha adjacent to the grouped ui abc on the bumped blocks and the
# README date line: zh `（`sha…`）` and en ` / `sha…`` styles, dry-run zero writes; the headless
# and historical sha references stay untouched
F6I="$T/fixture-sha"; make_fixture "$F6I" 98 987654 54321 || exit 1
fixture_docs "$F6I/docs" 98 987654 54321 en
DQI="$F6I/docs/2026-09-20-ohos-tester-quickstart.md"
DEI="$F6I/docs/2026-09-18-ohos-device-validation-checklist.md"
printf '> #97 口径：abc **987,654（`0123abcd…`）** historical\n' >> "$DQI"
_sum6i() { find "$F6I/docs" -name '*.md' -exec sha256sum {} \; | sort; }
_sum6i > "$T/t6i-before"
sh "$BUMP" --kit 99 --docs-dir "$F6I/docs" --abc 111111,55555 --abc-sha aabbccdd --dry-run > "$T/t6i-dry.out" 2>&1
check_rc "T6i dry-run rc=0" "$?" 0
assert_contains "T6i dry-run plan (19 files)" "$T/t6i-dry.out" '19 file\(s\) would change'
assert_contains "T6i dry-run names the sha" "$T/t6i-dry.out" 'sha aabbccdd'
_sum6i > "$T/t6i-after-dry"
cmp -s "$T/t6i-before" "$T/t6i-after-dry"
check "T6i dry-run writes nothing" $?
sh "$BUMP" --kit 99 --docs-dir "$F6I/docs" --abc 111111,55555 --abc-sha aabbccdd > "$T/t6i.out" 2>&1
check_rc "T6i apply rc=0" "$?" 0
grep -qF '111,111（`aabbccdd…`）' "$DQI"; check "T6i zh （sha…） refreshed" $?
grep -qF 'abc **111,111 / `aabbccdd…`' "$DEI"; check "T6i en / sha… refreshed" $?
grep -qF '111,111（`aabbccdd…`）' "$F6I/docs/README.md"; check "T6i README date-line sha refreshed" $?
grep -qF 'feedbeef' "$DQI"; check "T6i headless sha kept" $?
grep -qF '0123abcd' "$DQI"; check "T6i historical sha kept" $?
grep -qF '987,654（`0123abcd…`）' "$DQI"; check "T6i historical abc+sha intact" $?

# T6j: --abc-sha with a doc whose current block carries no adjacent ui sha -> refuse, zero writes
F6J="$T/fixture-no-sha"; make_fixture "$F6J" 98 987654 54321 || exit 1
sed -i 's/（`deadbeef…`）//' "$F6J/docs/2026-09-20-ohos-tester-quickstart.md"
_sum6j() { find "$F6J/docs" -name '*.md' -exec sha256sum {} \; | sort; }
_sum6j > "$T/t6j-before"
sh "$BUMP" --kit 99 --docs-dir "$F6J/docs" --abc 111111,55555 --abc-sha aabbccdd > "$T/t6j.out" 2>&1
check_neg "T6j missing sha refuses" "$?"
assert_contains "T6j names the missing sha" "$T/t6j.out" 'missing the current shell abc sha aabbccdd'
_sum6j > "$T/t6j-after"
cmp -s "$T/t6j-before" "$T/t6j-after"
check "T6j refusal writes nothing" $?

# T6k: the sha refresh is idempotent (second run byte-identical)
F6K="$T/fixture-sha-idem"; make_fixture "$F6K" 98 987654 54321 || exit 1
sh "$BUMP" --kit 99 --docs-dir "$F6K/docs" --abc 111111,55555 --abc-sha aabbccdd >/dev/null 2>&1
check_rc "T6k first sha bump rc=0" "$?" 0
_sum6k() { find "$F6K/docs" -name '*.md' -exec sha256sum {} \; | sort; }
_sum6k > "$T/t6k-before"
sh "$BUMP" --kit 99 --docs-dir "$F6K/docs" --abc 111111,55555 --abc-sha aabbccdd > "$T/t6k.out" 2>&1
check_rc "T6k sha idempotent rc=0" "$?" 0
assert_contains "T6k already message" "$T/t6k.out" 'already at kit #99'
_sum6k > "$T/t6k-after"
cmp -s "$T/t6k-before" "$T/t6k-after"
check "T6k sha idempotent (bytes unchanged)" $?

# T6l: an invalid --abc-sha is a usage error (rc=2, nothing runs)
sh "$BUMP" --kit 99 --docs-dir "$F6K/docs" --abc 111111,55555 --abc-sha zz123456 >/dev/null 2>&1
check_rc "T6l bad --abc-sha rc=2" "$?" 2

# T6m: kit already current + old abc/sha -> abc+sha-only refresh, no marker churn
F6M="$T/fixture-sha-refresh"; make_fixture "$F6M" 99 987654 54321 || exit 1
sh "$BUMP" --kit 99 --docs-dir "$F6M/docs" --abc 111111,55555 --abc-sha aabbccdd > "$T/t6m.out" 2>&1
check_rc "T6m abc+sha-only refresh rc=0" "$?" 0
assert_contains "T6m refresh message" "$T/t6m.out" 'refresh 2026-09-20-ohos-tester-quickstart.md: abc -> 111111,55555'
DQIM="$F6M/docs/2026-09-20-ohos-tester-quickstart.md"
grep -qF 'kit #99，当前）' "$DQIM"; check "T6m marker kept at kit #99" $?
grep -qF '111,111（`aabbccdd…`）' "$DQIM"; check "T6m sha refreshed in place" $?
grep -qF 'deadbeef' "$DQIM"; check_neg "T6m old sha gone" "$?"

# ------------------------------------------------------------------ T7 P3 anchor + seed
# KIT54: P3 must match the `:=` anchor spelling, auto-resolve the previous published bundle as
# the cumulative seed (from the sdk versions.env anchor) and refuse when neither is available.
section "T7 P3 anchor forms + cumulative seed"
P3OW="$T/p3-ow"; p3_ow_fixture "$P3OW" || { echo "p3 ow fixture failed" >&2; exit 1; }
NEW_SHA="$(sha256sum "$P3OW/ow/bundle-fixed.tar.gz" | cut -d' ' -f1)"
SEED="$T/p3-seed.tar.gz"; p3_seed_tar "$SEED" seed-old.nupkg || { echo "seed fixture failed" >&2; exit 1; }
SEED_SHA="$(sha256sum "$SEED" | cut -d' ' -f1)"
SEED_ASSET="openharmony-workload-1.0.0-preview.99.tar.gz"
SEEDDIR="$T/p3-seeddir"; mkdir -p "$SEEDDIR"; cp "$SEED" "$SEEDDIR/$SEED_ASSET"
SDK_COLON="$T/p3-sdk-colon"; p3_sdk_fixture "$SDK_COLON" "$SEED_SHA" colon || exit 1

# T7a: P3 dry-run prints the pack steps + the seed plan, zero writes
S7A="$T/p3-scratch-dry"; OUT7A="$T/t7a.out"
CUT_KIT_SEED_DIR="$SEEDDIR" CUT_KIT_SEED_OFFLINE=1 sh "$CUT" --kit 99 --phase P3 --dry-run --scratch "$S7A" \
    --ow-repo "$P3OW/ow" --maui-repo "$P3OW/maui" --runtime-repo "$P3OW/runtime" --docs-dir "$P3OW/docs" \
    --sdk-repo "$SDK_COLON" --no-push > "$OUT7A" 2>&1
check_rc "T7a P3 dry-run rc=0" "$?" 0
assert_contains "T7a prints the pack steps" "$OUT7A" 'pack-workload-bundle'
assert_contains "T7a seed plan names the anchor" "$OUT7A" "auto: anchor $(printf '%s' "$SEED_SHA" | cut -c1-8)"
assert_contains "T7a seed plan picks the local candidate" "$OUT7A" "local $SEEDDIR/$SEED_ASSET"
[ ! -e "$S7A" ]; check "T7a dry-run created no scratch" $?
[ ! -e "$P3OW/ow/.p3-calls" ]; check "T7a dry-run ran no pack script" $?

# T7b: the three anchor spellings (=, :=, JSON) replace exactly the anchor value end to end,
# and the cumulative seed is auto-resolved from the local candidate and staged into .feed
for _form in colon plain json; do
    SDK="$T/p3-sdk-$_form"; p3_sdk_fixture "$SDK" "$SEED_SHA" "$_form" || exit 1
    S="$T/p3-scratch-$_form"; O="$T/t7-$_form.out"
    CUT_KIT_SEED_DIR="$SEEDDIR" CUT_KIT_SEED_OFFLINE=1 sh "$CUT" --kit 99 --phase P3 --execute \
        --scratch "$S" --ow-repo "$P3OW/ow" --maui-repo "$P3OW/maui" --runtime-repo "$P3OW/runtime" \
        --docs-dir "$P3OW/docs" --sdk-repo "$SDK" --no-push > "$O" 2>&1
    check_rc "T7 $_form execute rc=0" "$?" 0
    assert_contains "T7 $_form resolve is auto" "$O" 'seed: auto '
    grep -qF "$NEW_SHA" "$S/sdk-anchor-wt/eng/ohos-install/versions.env" 2>/dev/null
    check "T7 $_form anchor replaced with the built bundle sha" $?
    grep -qF "$SEED_SHA" "$S/sdk-anchor-wt/eng/ohos-install/versions.env" 2>/dev/null
    check_neg "T7 $_form old anchor gone" $?
    [ -f "$P3OW/ow/.feed/seed-old.nupkg" ]; check "T7 $_form seed nupkg staged into .feed" $?
    [ "$(wc -l < "$S/sdk-anchor-wt/.sdk-tests" 2>/dev/null | tr -d ' ')" = 3 ]
    check "T7 $_form installer tests ran (3)" $?
    git -C "$S/sdk-anchor-wt" log -1 --format=%s 2>/dev/null | grep -q "kit #99"
    check "T7 $_form anchor commit created" $?
    grep -q '^P3_rc=0$' "$S/state.env" 2>/dev/null
    check "T7 $_form state P3_rc=0" $?
    grep -q "^bundle_sha256=$NEW_SHA\$" "$S/state.env" 2>/dev/null
    check "T7 $_form state records the built bundle sha" $?
    grep -q '^seed_source=auto$' "$S/state.env" 2>/dev/null
    check "T7 $_form state records the auto seed" $?
done

# T7c: a missing anchor refuses the re-anchor (fail closed, no commit; explicit seed so the
# bundle step itself is satisfied)
SDK_NONE="$T/p3-sdk-none"; p3_sdk_fixture "$SDK_NONE" "$SEED_SHA" none || exit 1
S7C="$T/p3-scratch-none"; OUT7C="$T/t7c.out"
CUT_KIT_SEED_OFFLINE=1 sh "$CUT" --kit 99 --phase P3 --execute --scratch "$S7C" \
    --ow-repo "$P3OW/ow" --maui-repo "$P3OW/maui" --runtime-repo "$P3OW/runtime" --docs-dir "$P3OW/docs" \
    --sdk-repo "$SDK_NONE" --seed-bundle "$SEED" --no-push > "$OUT7C" 2>&1
check_neg "T7c missing anchor rc!=0" "$?"
assert_contains "T7c names the accepted forms" "$OUT7C" 'expected exactly one WORKLOAD_BUNDLE_SHA256 anchor \(=, := or JSON form\), found 0'
[ "$(git -C "$SDK_NONE" rev-list --count HEAD)" = 1 ]
check "T7c no anchor commit created" $?

# T7d: an ambiguous file (two anchors) refuses too and stays untouched
SDK_DOUBLE="$T/p3-sdk-double"; p3_sdk_fixture "$SDK_DOUBLE" "$SEED_SHA" double || exit 1
S7D="$T/p3-scratch-double"; OUT7D="$T/t7d.out"
CUT_KIT_SEED_OFFLINE=1 sh "$CUT" --kit 99 --phase P3 --execute --scratch "$S7D" \
    --ow-repo "$P3OW/ow" --maui-repo "$P3OW/maui" --runtime-repo "$P3OW/runtime" --docs-dir "$P3OW/docs" \
    --sdk-repo "$SDK_DOUBLE" --seed-bundle "$SEED" --no-push > "$OUT7D" 2>&1
check_neg "T7d ambiguous anchor rc!=0" "$?"
assert_contains "T7d reports both matches" "$OUT7D" 'found 2'
[ "$(grep -cF "$SEED_SHA" "$S7D/sdk-anchor-wt/eng/ohos-install/versions.env" 2>/dev/null)" = 2 ]
check "T7d both anchors left untouched" $?

# T7e: a missing seed (no explicit, no local match, offline) fails closed before any pack step
SDK_MISS="$T/p3-sdk-miss"; p3_sdk_fixture "$SDK_MISS" "$SEED_SHA" colon || exit 1
S7E="$T/p3-scratch-miss"; OUT7E="$T/t7e.out"
_calls_before="$(wc -l < "$P3OW/ow/.p3-calls" 2>/dev/null | tr -d ' ')"
CUT_KIT_SEED_OFFLINE=1 sh "$CUT" --kit 99 --phase P3 --execute --scratch "$S7E" \
    --ow-repo "$P3OW/ow" --maui-repo "$P3OW/maui" --runtime-repo "$P3OW/runtime" --docs-dir "$P3OW/docs" \
    --sdk-repo "$SDK_MISS" --no-push > "$OUT7E" 2>&1
check_rc "T7e missing seed rc=4" "$?" 4
assert_contains "T7e names the seed failure" "$OUT7E" 'no cumulative seed'
assert_contains "T7e points at --seed-bundle" "$OUT7E" 'pass --seed-bundle'
_calls_after="$(wc -l < "$P3OW/ow/.p3-calls" 2>/dev/null | tr -d ' ')"
[ "$_calls_before" = "$_calls_after" ]; check "T7e no pack script ran" $?
[ ! -e "$S7E/sdk-anchor-wt" ]; check "T7e no sdk worktree created" $?

# T7f: an explicit --seed-bundle wins over the auto path and warns on an anchor mismatch
SDK_X="$T/p3-sdk-explicit"; p3_sdk_fixture "$SDK_X" "$(python3 -c 'print("c"*64)')" colon || exit 1
S7F="$T/p3-scratch-explicit"; OUT7F="$T/t7f.out"
CUT_KIT_SEED_OFFLINE=1 sh "$CUT" --kit 99 --phase P3 --execute --scratch "$S7F" \
    --ow-repo "$P3OW/ow" --maui-repo "$P3OW/maui" --runtime-repo "$P3OW/runtime" --docs-dir "$P3OW/docs" \
    --sdk-repo "$SDK_X" --seed-bundle "$SEED" --no-push > "$OUT7F" 2>&1
check_rc "T7f explicit seed rc=0" "$?" 0
assert_contains "T7f seed source is explicit" "$OUT7F" 'seed: explicit '
assert_contains "T7f mismatch warning names the anchor" "$OUT7F" '!= versions.env anchor'
grep -qF "$NEW_SHA" "$S7F/sdk-anchor-wt/eng/ohos-install/versions.env" 2>/dev/null
check "T7f anchor replaced" $?
grep -q '^seed_source=explicit$' "$S7F/state.env" 2>/dev/null
check "T7f state records the explicit seed" $?

# T7g: resume - the anchor already current is a no-op (no extra commit, rc=0)
S7G="$T/p3-scratch-colon"
git -C "$T/p3-sdk-colon" update-ref refs/remotes/origin/feature/openharmony "$(git -C "$S7G/sdk-anchor-wt" rev-parse HEAD)"
_count_before="$(git -C "$T/p3-sdk-colon" rev-list --count origin/feature/openharmony)"
OUT7G="$T/t7g.out"
CUT_KIT_SEED_DIR="$SEEDDIR" CUT_KIT_SEED_OFFLINE=1 sh "$CUT" --kit 99 --phase P3 --execute --force \
    --scratch "$S7G" --ow-repo "$P3OW/ow" --maui-repo "$P3OW/maui" --runtime-repo "$P3OW/runtime" \
    --docs-dir "$P3OW/docs" --sdk-repo "$T/p3-sdk-colon" --no-push > "$OUT7G" 2>&1
check_rc "T7g resumed P3 rc=0" "$?" 0
assert_contains "T7g already-current message" "$OUT7G" 'already current'
[ "$(git -C "$T/p3-sdk-colon" rev-list --count origin/feature/openharmony)" = "$_count_before" ]
check "T7g no extra anchor commit" $?

# ------------------------------------------------------------------ T8 P4-P6 dry-run
# KIT54: P4-P6 were never exercised; the dry run must parse/print the upload plan and notes
# template, parse the hooks and still write nothing / call nothing.
section "T8 P4-P6 dry-run previews (zero writes)"
F8="$T/fixture-p456"; make_fixture "$F8" 99 987654 54321 || exit 1
S8="$T/scratch-p456"
mkdir -p "$T/pathstub-p456"
cat > "$T/pathstub-p456/curl" <<EOF
#!/bin/sh
echo "curl \$*" >> "$T/curl-calls-p456.log"
exit 77
EOF
chmod +x "$T/pathstub-p456/curl"
for _h in upload presign manifest; do
    printf '#!/bin/sh\necho "%s hook $*" >> "%s/hook-calls.log"\n' "$_h" "$T" > "$T/hook-$_h.sh"
done
chmod +x "$T"/hook-*.sh
_p456_sum() { find "$F8" -type f -exec sha256sum {} \; | sort; }
_p456_sum > "$T/t8-before"
OUT8="$T/t8.out"
PATH="$T/pathstub-p456:$PATH" sh "$CUT" --kit 99 --phase P4,P5,P6 --dry-run --scratch "$S8" \
    --ow-repo "$F8/ow" --maui-repo "$F8/maui" --runtime-repo "$F8/runtime" --docs-dir "$F8/docs" \
    --release-ids "dtk=11 latest=22 versioned=33 sdkrc2=44" --assets-dir "$F8/assets" \
    --token-file "$F8/token" --upload-hook "$T/hook-upload.sh" --presign-hook "$T/hook-presign.sh" \
    --manifest-hook "$T/hook-manifest.sh" > "$OUT8" 2>&1
check_rc "T8 dry rc=0" "$?" 0
assert_contains "T8 prints the clobber plan" "$OUT8" 'clobber plan'
assert_contains "T8 plan lists the kit asset" "$OUT8" 'device-test-kit.tar.gz'
assert_contains "T8 prints the notes template" "$OUT8" 'notes template'
assert_contains "T8 notes template carries the kit number" "$OUT8" 'Integrity \(kit #99\)'
assert_contains "T8 P5 prints the value block" "$OUT8" 'kit=99'
assert_contains "T8 P5 announces the no-write" "$OUT8" 'RELEASE-VALUES\.txt \+ release-values\.env \(no write in dry-run\)'
assert_contains "T8 upload hook parses" "$OUT8" 'upload hook parses'
assert_contains "T8 presign hook parses" "$OUT8" 'presign hook parses'
assert_contains "T8 manifest hook parses" "$OUT8" 'manifest hook parses'
assert_contains "T8 presign hook preview command" "$OUT8" "sh $T/hook-presign.sh --kit 99"
assert_contains "T8 P6 queries the ow runs" "$OUT8" 'repos/springmin/ohos-workload/actions/runs'
assert_contains "T8 P6 announces the no-API dry-run" "$OUT8" 'no API call, no state write'
[ ! -e "$S8" ]; check "T8 dry created no scratch dir" $?
[ ! -s "$T/curl-calls-p456.log" ]; check "T8 dry made no curl call" $?
[ ! -f "$T/hook-calls.log" ]; check "T8 dry ran no hook" $?
_p456_sum > "$T/t8-after"
cmp -s "$T/t8-before" "$T/t8-after"; check "T8 dry wrote nothing under the fixture" $?

# T8b: a hook with a shell syntax error fails the dry run closed, still zero writes
printf '#!/bin/sh\nif then fi\n' > "$T/hook-broken.sh"; chmod +x "$T/hook-broken.sh"
S8B="$T/scratch-p456-broken"; OUT8B="$T/t8b.out"
sh "$CUT" --kit 99 --phase P4 --dry-run --scratch "$S8B" \
    --ow-repo "$F8/ow" --maui-repo "$F8/maui" --runtime-repo "$F8/runtime" --docs-dir "$F8/docs" \
    --release-ids "dtk=11 latest=22 versioned=33 sdkrc2=44" --assets-dir "$F8/assets" \
    --token-file "$F8/token" --upload-hook "$T/hook-broken.sh" > "$OUT8B" 2>&1
check_neg "T8b broken hook rc!=0" "$?"
assert_contains "T8b names the syntax error" "$OUT8B" 'shell syntax error'
[ ! -e "$S8B" ]; check "T8b zero writes with a broken hook" $?
_p456_sum > "$T/t8b-after"
cmp -s "$T/t8-before" "$T/t8b-after"; check "T8b wrote nothing under the fixture" $?

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
