#!/bin/sh
# selftest-cut-kit.sh - local selftest for scripts/cut-kit.sh (the five-round kit-cutting
# automation with the fail-closed tester-docs gate). Everything runs against synthetic fixture
# repos/artifacts: no real build, no network, no release, no device.
#
#   T0 usage      sh -n passes; --help lists the phases; an unknown option exits 2;
#                 --print-docs-list prints the 18 wave + 8 packed docs contract
#   T1 p0-pass    a fixture whose pins/packs/EXPECT/suite/exports/docs all match and whose
#                 build-use install pack (--dotnet fixture root) mirrors the repo pack (SDK + the
#                 six Ref/Runtime/BCL families) -> P0 PASS, state.env records P0_rc=0, and
#                 nothing outside --scratch is written
#   T1b install   the build-use install pack gate is fail-closed: a drifted install pack file
#                 (abc) and a missing install pack both fail P0 and name the group; T1d-T1f: a
#                 drifted Ref payload, a missing BCL key file and a missing repo Ref/Runtime key
#                 file fail closed too (KIT54 full-sync follow-up coverage)
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
#   T9 p1-hosts   P1 prep materializes the git-ignored SDK pack hosts/*.so (KIT54 finding 3):
#                 the dry run prints the plan and writes nothing; an execute run copies it from
#                 the main checkout (T9b) or from the build-use installed pack (T9c) into the
#                 fresh worktree before any build; missing in every source fails closed with an
#                 explicit message and no build attempt (T9d)
#   T10 p4-notes  P4 appends the Integrity block to the published release bodies (KIT55 notes
#                 fix): a full --execute P4 against fixture artifacts, with a PATH curl stub for
#                 the API GETs and a PYTHONPATH urllib.request stub recording every PATCH (no
#                 network); each of the four fixture bodies keeps its published text and gains
#                 the "## Integrity (kit #99)" block after it
#   T11 p3-payload P3 materializes the known pack payloads a fresh worktree lacks (KIT57: the
#                 AspNetCore pack DLLs are git-ignored, so the pack was a 14,862 B stub): the
#                 dry run prints the plan and writes nothing; an execute run fills the payload
#                 from the main checkout (T11b) or the build-use installed pack (T11c) before
#                 prepare-packs; missing in every source fails closed with rc=4, explains all
#                 three sources and runs no pack step (T11d); the release mirror source is
#                 exercised offline through a file:// mirror + a CUT_KIT_PAYLOAD_PINS row (T11e)
#
# Env: SELFTEST_TMPDIR=<dir>  work dir base (default: the approved opencode tmp dir)
#      SELFTEST_KEEP=1       keep the work dir even when all checks pass
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="9 (2026-10-15; 238 checks, was 217)"

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

# fixture_packs_rrb <ow>: the six Ref/Runtime/BCL pack payload fixtures the extended P0
# install-pack gate compares, plus the workload manifest that pins every family version (the
# real repo carries the same manifest shape under manifests/<band>/microsoft.net.sdk.openharmony).
fixture_packs_rrb() {
    _ow="$1"
    for _api in 20.0 26.0; do
        _p="$_ow/packs/Microsoft.OpenHarmony.Ref.$_api/1.0.0-preview.28"
        mkdir -p "$_p/ref/net11.0" "$_p/data"
        printf 'fixture ref dll %s\n' "$_api" > "$_p/ref/net11.0/Microsoft.OpenHarmony.dll"
        printf 'fixture ref hosting %s\n' "$_api" > "$_p/ref/net11.0/Microsoft.OpenHarmony.Hosting.dll"
        printf 'fixture framework list %s\n' "$_api" > "$_p/data/FrameworkList.xml"
        _p="$_ow/packs/Microsoft.OpenHarmony.Runtime.$_api.openharmony-arm64/1.0.0-preview.28"
        mkdir -p "$_p/runtimes/openharmony-arm64/lib/net11.0" "$_p/data"
        for _f in Microsoft.OpenHarmony.dll Microsoft.OpenHarmony.Hosting.dll Microsoft.OpenHarmony.Maui.Graphics.dll; do
            printf 'fixture runtime %s %s\n' "$_api" "$_f" > "$_p/runtimes/openharmony-arm64/lib/net11.0/$_f"
        done
        printf 'fixture runtime list %s\n' "$_api" > "$_p/data/RuntimeList.xml"
    done
    _p="$_ow/packs/Microsoft.NETCore.App.Runtime.openharmony-arm64/11.0.0-rc.2.26451.112"
    mkdir -p "$_p/runtimes/openharmony-arm64/lib/net11.0" "$_p/data"
    printf 'fixture corelib\n' > "$_p/runtimes/openharmony-arm64/lib/net11.0/System.Private.CoreLib.dll"
    printf 'fixture netcore versions\n' > "$_p/Microsoft.NETCore.App.versions.txt"
    printf 'fixture netcore runtime list\n' > "$_p/data/RuntimeList.xml"
    _p="$_ow/packs/Microsoft.AspNetCore.App.Runtime.openharmony-arm64/11.0.0-rc.1.26451.112"
    mkdir -p "$_p/runtimes/openharmony-arm64/lib/net11.0" "$_p/data"
    printf 'fixture aspnet web\n' > "$_p/runtimes/openharmony-arm64/lib/net11.0/Microsoft.AspNetCore.Components.Web.dll"
    printf 'fixture aspnet versions\n' > "$_p/Microsoft.AspNetCore.App.versions.txt"
    printf 'fixture aspnet runtime list\n' > "$_p/data/RuntimeList.xml"
    for _band in 11.0.100-rc.1 11.0.100; do
        _m="$_ow/manifests/$_band/microsoft.net.sdk.openharmony"
        mkdir -p "$_m"
        cat > "$_m/WorkloadManifest.json" <<'EOF'
{
  "version": "1.0.0-preview.28",
  "workloads": {
    "openharmony": {
      "description": ".NET SDK for OpenHarmony (fixture)",
      "packs": [
        "Microsoft.OpenHarmony.Sdk",
        "Microsoft.OpenHarmony.Ref.20.0",
        "Microsoft.OpenHarmony.Runtime.20.0.openharmony-arm64",
        "Microsoft.NETCore.App.Runtime.openharmony-arm64",
        "Microsoft.AspNetCore.App.Runtime.openharmony-arm64",
        "Microsoft.OpenHarmony.Ref.26.0",
        "Microsoft.OpenHarmony.Runtime.26.0.openharmony-arm64"
      ]
    }
  },
  "packs": {
    "Microsoft.OpenHarmony.Sdk": { "kind": "sdk", "version": "1.0.0-preview.28" },
    "Microsoft.OpenHarmony.Ref.20.0": { "kind": "framework", "version": "1.0.0-preview.28" },
    "Microsoft.OpenHarmony.Runtime.20.0.openharmony-arm64": { "kind": "framework", "version": "1.0.0-preview.28" },
    "Microsoft.NETCore.App.Runtime.openharmony-arm64": { "kind": "framework", "version": "11.0.0-rc.2.26451.112" },
    "Microsoft.AspNetCore.App.Runtime.openharmony-arm64": { "kind": "framework", "version": "11.0.0-rc.1.26451.112" },
    "Microsoft.OpenHarmony.Ref.26.0": { "kind": "framework", "version": "1.0.0-preview.28" },
    "Microsoft.OpenHarmony.Runtime.26.0.openharmony-arm64": { "kind": "framework", "version": "1.0.0-preview.28" }
  }
}
EOF
    done
    return 0
}

# fixture_install_sync <fx>: mirror the fixture repo's pinned pack payload (SDK + the six
# Ref/Runtime/BCL families, versions mirroring the fixture manifest) into the fixture install
# root (the --dotnet root the P0 install-pack gate resolves).
fixture_install_sync() {
    _fx="$1"
    _srcp="$_fx/ow/packs"; _dst="$_fx/installroot/packs"
    rm -rf "$_dst"
    for _p in \
        Microsoft.OpenHarmony.Sdk/1.0.0-preview.28 \
        Microsoft.OpenHarmony.Ref.20.0/1.0.0-preview.28 \
        Microsoft.OpenHarmony.Ref.26.0/1.0.0-preview.28 \
        Microsoft.OpenHarmony.Runtime.20.0.openharmony-arm64/1.0.0-preview.28 \
        Microsoft.OpenHarmony.Runtime.26.0.openharmony-arm64/1.0.0-preview.28 \
        Microsoft.NETCore.App.Runtime.openharmony-arm64/11.0.0-rc.2.26451.112 \
        Microsoft.AspNetCore.App.Runtime.openharmony-arm64/11.0.0-rc.1.26451.112; do
        mkdir -p "$_dst/$(dirname "$_p")"
        cp -R "$_srcp/$_p" "$_dst/$_p" || return 1
    done
    return 0
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
    fixture_packs_rrb "$_ow" || return 1
    # build-use install root (the P0 install-pack gate compares against this; mirrors the
    # fixture manifest's pinned families: SDK + six Ref/Runtime/BCL packs)
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
# $PWD/.p3-calls), a deterministic "fixed" bundle the pack-workload-bundle stub copies, and
# the manifest-pinned SDK native host payload P3 materializes when a target worktree lacks
# it (materialize_sdk_hosts; the fresh worktrees the P3 payload tests build from copy this).
p3_ow_fixture() {
    _fx="$1"
    make_fixture "$_fx" 99 987654 54321 || return 1
    _ow="$_fx/ow"
    mkdir -p "$_ow/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.28/hosts/arm64-v8a"
    printf 'fixture sdk host payload\n' > \
        "$_ow/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.28/hosts/arm64-v8a/libopenharmonyhost.so"
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
grep -q '^install_pack_rrb_files=20$' "$S1/state.env" 2>/dev/null
check "T1 state install_pack_rrb_files recorded (20)" $?
assert_contains "T1 Ref/Runtime/BCL key-file check ran" "$OUT1" 'install pack rrb +PASS'

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

# T1d: the extended gate covers the Ref/Runtime/BCL key files - a drifted Ref payload fails
# closed and names the family/rel (KIT54 full-sync follow-up); T1e: a missing BCL key file in
# the install; T1f: a missing repo key file (both flag the missing side explicitly)
F1D="$T/fixture-ref-drift"; make_fixture "$F1D" 99 987654 54321 || exit 1
printf 'drifted ref dll\n' > "$F1D/installroot/packs/Microsoft.OpenHarmony.Ref.20.0/1.0.0-preview.28/ref/net11.0/Microsoft.OpenHarmony.dll"
S1D="$T/scratch-ref-drift"
OUT1D="$T/t1d.out"
sh "$CUT" --kit 99 --phase P0 --skip-selftests --execute --scratch "$S1D" \
    --ow-repo "$F1D/ow" --maui-repo "$F1D/maui" --runtime-repo "$F1D/runtime" --docs-dir "$F1D/docs" \
    --dotnet "$F1D/installroot/dotnet" > "$OUT1D" 2>&1
check_neg "T1d drifted Ref payload rc!=0" "$?"
assert_contains "T1d gate names the Ref family/file" "$OUT1D" 'install pack FAIL Microsoft.OpenHarmony.Ref.20.0/ref/net11.0/Microsoft.OpenHarmony.dll: repo'
assert_contains "T1d P0 FAIL" "$OUT1D" 'P0 FAIL'
F1E="$T/fixture-bcl-missing"; make_fixture "$F1E" 99 987654 54321 || exit 1
rm -f "$F1E/installroot/packs/Microsoft.NETCore.App.Runtime.openharmony-arm64/11.0.0-rc.2.26451.112/runtimes/openharmony-arm64/lib/net11.0/System.Private.CoreLib.dll"
S1E="$T/scratch-bcl-missing"
OUT1E="$T/t1e.out"
sh "$CUT" --kit 99 --phase P0 --skip-selftests --execute --scratch "$S1E" \
    --ow-repo "$F1E/ow" --maui-repo "$F1E/maui" --runtime-repo "$F1E/runtime" --docs-dir "$F1E/docs" \
    --dotnet "$F1E/installroot/dotnet" > "$OUT1E" 2>&1
check_neg "T1e missing BCL install file rc!=0" "$?"
assert_contains "T1e names the missing install file" "$OUT1E" 'install pack FAIL Microsoft.NETCore.App.Runtime.openharmony-arm64/runtimes/openharmony-arm64/lib/net11.0/System.Private.CoreLib.dll: install missing'
F1F="$T/fixture-repo-missing"; make_fixture "$F1F" 99 987654 54321 || exit 1
rm -f "$F1F/ow/packs/Microsoft.OpenHarmony.Runtime.20.0.openharmony-arm64/1.0.0-preview.28/runtimes/openharmony-arm64/lib/net11.0/Microsoft.OpenHarmony.Maui.Graphics.dll"
S1F="$T/scratch-repo-missing"
OUT1F="$T/t1f.out"
sh "$CUT" --kit 99 --phase P0 --skip-selftests --execute --scratch "$S1F" \
    --ow-repo "$F1F/ow" --maui-repo "$F1F/maui" --runtime-repo "$F1F/runtime" --docs-dir "$F1F/docs" \
    --dotnet "$F1F/installroot/dotnet" > "$OUT1F" 2>&1
check_neg "T1f missing repo key file rc!=0" "$?"
assert_contains "T1f names the missing repo file" "$OUT1F" 'install pack FAIL Microsoft.OpenHarmony.Runtime.20.0.openharmony-arm64/runtimes/openharmony-arm64/lib/net11.0/Microsoft.OpenHarmony.Maui.Graphics.dll: repo missing'

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

# ------------------------------------------------------------------ T9 P1 SDK host payload
# KIT54 finding 3: a fresh worktree misses the git-ignored packs/**/hosts/**/*.so, so the P3
# Sdk nupkg silently lost the native host. P1 prep now materializes it (main checkout first,
# the build-use installed pack as fallback) and fails closed when no source carries it.
section "T9 P1 SDK host payload materialization"
F9="$T/fixture-hosts"; make_fixture "$F9" 99 987654 54321 || exit 1
HOST_REL="packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.28/hosts/arm64-v8a/libopenharmonyhost.so"
# the other two git-ignored P1 inputs (dist/ets + .arkts-build) live in the main checkout only
mkdir -p "$F9/ow/dist/ets" "$F9/ow/.arkts-build"
printf 'fixture shell abc\n' > "$F9/ow/dist/ets/modules.abc"
printf 'fixture hvigor\n' > "$F9/ow/.arkts-build/tool.txt"
mkdir -p "$(dirname "$F9/ow/$HOST_REL")"
printf 'fixture host from main checkout\n' > "$F9/ow/$HOST_REL"

# T9a: the dry run prints the hosts plan and writes nothing (no worktree)
S9A="$T/scratch-hosts-dry"; OUT9A="$T/t9a.out"
sh "$CUT" --kit 99 --phase P1 --skip-selftests --dry-run --scratch "$S9A" \
    --ow-repo "$F9/ow" --maui-repo "$F9/maui" --runtime-repo "$F9/runtime" --docs-dir "$F9/docs" \
    --dotnet "$F9/installroot/dotnet" > "$OUT9A" 2>&1
check_rc "T9a P1 dry-run rc=0" "$?" 0
assert_contains "T9a prints the hosts plan" "$OUT9A" 'materialize packs/Microsoft.OpenHarmony.Sdk/\*/hosts/\*\.so from the main checkout'
[ ! -e "$S9A/ow" ]; check "T9a dry-run created no worktree" $?

# T9b: an execute run materializes the host from the main checkout into the fresh worktree
# before the builds (the fixture dotnet stub fails the hosting build right after, rc!=0)
S9B="$T/scratch-hosts-main"; OUT9B="$T/t9b.out"
sh "$CUT" --kit 99 --phase P1 --skip-selftests --execute --scratch "$S9B" \
    --ow-repo "$F9/ow" --maui-repo "$F9/maui" --runtime-repo "$F9/runtime" --docs-dir "$F9/docs" \
    --dotnet "$F9/installroot/dotnet" > "$OUT9B" 2>&1
check_neg "T9b P1 stops at the fixture build (rc!=0)" "$?"
assert_contains "T9b logs the main-checkout materialization" "$OUT9B" 'materialize SDK host payload'
[ -f "$S9B/ow/$HOST_REL" ]; check "T9b host landed in the worktree" $?
cmp -s "$F9/ow/$HOST_REL" "$S9B/ow/$HOST_REL"; check "T9b host bytes match the main checkout" $?

# T9c: without a main-checkout host the installed pack is the fallback
F9C="$T/fixture-hosts-install"; make_fixture "$F9C" 99 987654 54321 || exit 1
mkdir -p "$F9C/ow/dist/ets" "$F9C/ow/.arkts-build"
printf 'fixture shell abc\n' > "$F9C/ow/dist/ets/modules.abc"
printf 'fixture hvigor\n' > "$F9C/ow/.arkts-build/tool.txt"
mkdir -p "$(dirname "$F9C/installroot/$HOST_REL")"
printf 'fixture host from the installed pack\n' > "$F9C/installroot/$HOST_REL"
S9C="$T/scratch-hosts-install"; OUT9C="$T/t9c.out"
sh "$CUT" --kit 99 --phase P1 --skip-selftests --execute --scratch "$S9C" \
    --ow-repo "$F9C/ow" --maui-repo "$F9C/maui" --runtime-repo "$F9C/runtime" --docs-dir "$F9C/docs" \
    --dotnet "$F9C/installroot/dotnet" > "$OUT9C" 2>&1
check_neg "T9c P1 stops at the fixture build (rc!=0)" "$?"
assert_contains "T9c materializes from the installed pack" "$OUT9C" 'installroot/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.28/hosts'
cmp -s "$F9C/installroot/$HOST_REL" "$S9C/ow/$HOST_REL"; check "T9c host bytes match the installed pack" $?

# T9d: missing in every source fails closed with an explicit message and no build attempt
F9D="$T/fixture-hosts-missing"; make_fixture "$F9D" 99 987654 54321 || exit 1
mkdir -p "$F9D/ow/dist/ets" "$F9D/ow/.arkts-build"
printf 'fixture shell abc\n' > "$F9D/ow/dist/ets/modules.abc"
printf 'fixture hvigor\n' > "$F9D/ow/.arkts-build/tool.txt"
rm -rf "$F9D/installroot/packs"
S9D="$T/scratch-hosts-missing"; OUT9D="$T/t9d.out"
sh "$CUT" --kit 99 --phase P1 --skip-selftests --execute --scratch "$S9D" \
    --ow-repo "$F9D/ow" --maui-repo "$F9D/maui" --runtime-repo "$F9D/runtime" --docs-dir "$F9D/docs" \
    --dotnet "$F9D/installroot/dotnet" > "$OUT9D" 2>&1
check_neg "T9d missing host rc!=0" "$?"
assert_contains "T9d names the missing host payload" "$OUT9D" 'SDK host payload missing: packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.28/hosts/arm64-v8a/libopenharmonyhost.so'
assert_contains "T9d names both sources" "$OUT9D" 'not in .* or the build-use install either'
[ ! -e "$S9D/logs" ]; check "T9d no build attempt (no logs dir)" $?

# ------------------------------------------------------------------ T10 P4 notes append
# KIT55 (a4071cb): p4_notes used to PATCH {"body": <Integrity block>} alone, which would have
# replaced the whole published release body with the few-line block; the fetched body must be
# kept and the block appended. Full --execute P4 against fixture artifacts: a PATH curl stub
# serves the asset snapshots + release bodies and a PYTHONPATH urllib.request stub records every
# PATCH instead of hitting api.github.com (no network).
section "T10 P4 notes append (published body kept)"
F10="$T/fixture-p4notes"; make_fixture "$F10" 99 987654 54321 || exit 1
S10="$T/scratch-p4notes"; mkdir -p "$S10"
printf 'fixture kit payload\n' > "$S10/device-test-kit.tar.gz"
( cd "$S10" && sha256sum device-test-kit.tar.gz > device-test-kit.tar.gz.sha256 )
# the bundle name mirrors the preview.28 key the P4 by-id verifier's local map carries
BUNDLE10="$F10/ow/dist/openharmony-workload-1.0.0-preview.28.tar.gz"
printf 'fixture bundle payload\n' > "$BUNDLE10"
printf 'fixture sums\n' > "$F10/ow/dist/SHA256SUMS"
printf 'bundle_path=%s\n' "$BUNDLE10" > "$S10/state.env"
T10STUB="$T/p4notes-stub"; mkdir -p "$T10STUB/pylib/urllib"
rm -f "$T10STUB"/rid-*.n "$T10STUB/curl-calls.log" "$T10STUB/patches.jsonl"
: > "$T10STUB/pylib/urllib/__init__.py"
cat > "$T10STUB/pylib/urllib/request.py" <<'EOF'
# selftest stub: record the PATCH this code sends instead of hitting api.github.com
import json, os


class Request:
    def __init__(self, url, data=None, method=None, headers=None):
        self.full_url = url
        self.data = data
        self.method = method
        self.headers = headers or {}


class _Response:
    status = 200


def urlopen(req, timeout=None):
    with open(os.environ["CUT_KIT_STUB_PATCH_LOG"], "a", encoding="utf-8") as f:
        f.write(json.dumps({"url": req.full_url, "method": req.method,
                            "body": json.loads(req.data.decode("utf-8"))}) + "\n")
    return _Response()
EOF
cat > "$T10STUB/curl" <<'EOF'
#!/bin/sh
_dir="$(cd "$(dirname "$0")" && pwd)"
_url=""
for _a in "$@"; do _url="$_a"; done
printf '%s\n' "$_url" >> "$_dir/curl-calls.log"
case "$_url" in
    *assets*per_page=100*)
        _rid="$(printf '%s' "$_url" | sed -n 's#.*/releases/\([0-9]*\)/assets.*#\1#p')"
        _n="$(cat "$_dir/rid-$_rid.n" 2>/dev/null || echo 0)"
        _n=$((_n + 1)); printf '%s\n' "$_n" > "$_dir/rid-$_rid.n"
        _f="after-$_rid.json"; [ "$_n" = 1 ] && _f="before-$_rid.json"
        cat "$_dir/$_f" ;;
    */releases/[0-9]*)
        _rid="$(printf '%s' "$_url" | sed -n 's#.*/releases/\([0-9]*\)$#\1#p')"
        cat "$_dir/body-$_rid.json" ;;
    *) printf '[]\n' ;;
esac
exit 0
EOF
chmod +x "$T10STUB/curl"
python3 - "$T10STUB" "$S10/device-test-kit.tar.gz" "$S10/device-test-kit.tar.gz.sha256" \
    "$BUNDLE10" "$F10/ow/dist/SHA256SUMS" <<'PY'
import hashlib, json, os, sys
stub, kit, side, bundle, sums = sys.argv[1:6]
names = {
    "11": ["device-test-kit.tar.gz", "device-test-kit.tar.gz.sha256"],
    "22": ["openharmony-workload-latest.tar.gz", "SHA256SUMS",
           "device-test-kit.tar.gz", "device-test-kit.tar.gz.sha256"],
    "33": ["openharmony-workload-1.0.0-preview.28.tar.gz", "SHA256SUMS"],
    "44": ["openharmony-workload-1.0.0-preview.28.tar.gz", "SHA256SUMS"],
}
files = {"device-test-kit.tar.gz": kit, "device-test-kit.tar.gz.sha256": side,
         "openharmony-workload-1.0.0-preview.28.tar.gz": bundle,
         "openharmony-workload-latest.tar.gz": bundle, "SHA256SUMS": sums}
def record(name, path):
    data = open(path, "rb").read()
    return {"name": name, "size": len(data),
            "digest": "sha256:" + hashlib.sha256(data).hexdigest()}
stable = {"name": "stable.bin", "size": 7, "digest": "sha256:" + "9" * 64}
for rid, rnames in names.items():
    before = [{"name": n, "size": 1, "digest": "sha256:" + "0" * 64} for n in rnames]
    after = [record(n, files[n]) for n in rnames]
    json.dump(before + [dict(stable)], open(os.path.join(stub, "before-%s.json" % rid), "w"))
    json.dump(after + [dict(stable)], open(os.path.join(stub, "after-%s.json" % rid), "w"))
    json.dump({"body": "FIXTURE-RELEASE-%s body: keep me.\n\n## Notes\n- old line\n" % rid},
              open(os.path.join(stub, "body-%s.json" % rid), "w"))
PY
printf '#!/bin/sh\necho "upload hook $*" >> "%s/upload-hook.log"\n' "$T10STUB" > "$T10STUB/upload-hook.sh"
chmod +x "$T10STUB/upload-hook.sh"
OUT10="$T/t10.out"
CUT_KIT_STUB_PATCH_LOG="$T10STUB/patches.jsonl" PYTHONPATH="$T10STUB/pylib" \
https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 \
PATH="$T10STUB:$PATH" sh "$CUT" --kit 99 --phase P4 --execute --i-know --yes --skip-selftests \
    --scratch "$S10" --ow-repo "$F10/ow" --maui-repo "$F10/maui" --runtime-repo "$F10/runtime" \
    --docs-dir "$F10/docs" --release-ids "dtk=11 latest=22 versioned=33 sdkrc2=44" \
    --token-file "$F10/token" --upload-hook "$T10STUB/upload-hook.sh" > "$OUT10" 2>&1
check_rc "T10 P4 execute rc=0" "$?" 0
assert_contains "T10 P4 PASS" "$OUT10" 'P4 PASS'
[ -f "$T10STUB/upload-hook.log" ]; check "T10 upload hook ran" $?
[ "$(grep -c 'notes patched: release' "$OUT10")" = 4 ]; check "T10 notes patched for the four releases" $?
python3 - "$T10STUB/patches.jsonl" <<'PY'
import json, sys
recs = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
sys.exit(0 if len(recs) == 4 else 1)
PY
check "T10 four PATCH calls recorded (no network)" $?
for _rid in 11 22 33 44; do
    python3 - "$T10STUB/patches.jsonl" "$_rid" <<'PY'
import json, sys
log, rid = sys.argv[1:3]
recs = [json.loads(line) for line in open(log, encoding="utf-8") if line.strip()]
hit = [r for r in recs if r["url"].endswith("/releases/" + rid)]
if len(hit) != 1 or hit[0]["method"] != "PATCH":
    sys.exit(1)
body = hit[0]["body"].get("body", "")
marker = "FIXTURE-RELEASE-%s body: keep me." % rid
ok = (marker in body and "## Notes\n- old line" in body
      and "## Integrity (kit #99)" in body
      and body.index(marker) < body.index("## Integrity (kit #99)"))
sys.exit(0 if ok else 1)
PY
    check "T10 release $_rid body appended (published text kept)" $?
done

# ------------------------------------------------------------------ T11 P3 payload materialization
# KIT57: a fresh worktree carries only the committed AspNetCore pack skeleton
# (its DLL payload is git-ignored), so P3 packed a 14,862 B stub and the rebuilt
# bundle lost the full feed member. P3 now materializes the known payloads
# before prepare-packs: main checkout -> the build-use installed pack -> the
# release mirror; missing in every source fails closed (rc 4, no pack step).
# The release transport runs against a file:// mirror plus a fixture pin row
# (CUT_KIT_PAYLOAD_PINS), so the whole path is exercised offline.
section "T11 P3 known-payload materialization"
F11="$T/fixture-p11-main"; p3_ow_fixture "$F11" || { echo "p3 payload fixture failed" >&2; exit 1; }
SEED11="$T/p3-seed11.tar.gz"; p3_seed_tar "$SEED11" seed-p11.nupkg || exit 1
SEED11_SHA="$(sha256sum "$SEED11" | cut -d' ' -f1)"
SDK11="$T/p3-sdk-payload"; p3_sdk_fixture "$SDK11" "$SEED11_SHA" colon || exit 1
ASP_FAM="Microsoft.AspNetCore.App.Runtime.openharmony-arm64"
ASP_VER="11.0.0-rc.1.26451.112"
ASP_SENT="$ASP_FAM/$ASP_VER/runtimes/openharmony-arm64/lib/net11.0/Microsoft.AspNetCore.Components.Web.dll"

# p3payload_target <scratch> <fixture-ow> <sentinel-rel>: a fresh-worktree
# stand-in - a copy of the fixture ow without .git and without the payload
# sentinel (the committed-stub state a fresh worktree starts from).
p3payload_target() {
    mkdir -p "$1" || return 1
    cp -R "$2" "$1/ow" || return 1
    rm -rf "$1/ow/.git"
    rm -f "$1/ow/packs/$3"
}

# T11a: the dry run prints the materialization plan and writes nothing
S11A="$T/scratch-p11-dry"; OUT11A="$T/t11a.out"
sh "$CUT" --kit 99 --phase P3 --dry-run --scratch "$S11A" \
    --ow-repo "$F11/ow" --maui-repo "$F11/maui" --runtime-repo "$F11/runtime" --docs-dir "$F11/docs" \
    --sdk-repo "$SDK11" --seed-bundle "$SEED11" --no-push > "$OUT11A" 2>&1
check_rc "T11a P3 dry-run rc=0" "$?" 0
assert_contains "T11a prints the payload plan" "$OUT11A" 'materialize known pack payloads'
[ ! -e "$S11A" ]; check "T11a dry-run created no scratch" $?

# T11b: execute materializes the payload from the main checkout into the worktree
S11B="$T/scratch-p11-main"; OUT11B="$T/t11b.out"
p3payload_target "$S11B" "$F11/ow" "$ASP_SENT" || exit 1
[ ! -f "$S11B/ow/packs/$ASP_SENT" ]; check "T11b target starts as the stub (no payload)" $?
sh "$CUT" --kit 99 --phase P3 --execute --scratch "$S11B" \
    --ow-repo "$F11/ow" --maui-repo "$F11/maui" --runtime-repo "$F11/runtime" --docs-dir "$F11/docs" \
    --sdk-repo "$SDK11" --seed-bundle "$SEED11" --dotnet "$F11/installroot/dotnet" --no-push > "$OUT11B" 2>&1
check_rc "T11b P3 execute rc=0" "$?" 0
assert_contains "T11b logs the main-checkout materialization" "$OUT11B" "materialize $ASP_FAM $ASP_VER payload: $F11/ow"
[ -f "$S11B/ow/packs/$ASP_SENT" ]; check "T11b payload sentinel landed in the worktree" $?
cmp -s "$F11/ow/packs/$ASP_SENT" "$S11B/ow/packs/$ASP_SENT"; check "T11b payload bytes match the main checkout" $?

# T11c: without a main-checkout payload the installed pack is the fallback
F11C="$T/fixture-p11-install"; p3_ow_fixture "$F11C" || exit 1
rm -f "$F11C/ow/packs/$ASP_SENT"
S11C="$T/scratch-p11-install"; OUT11C="$T/t11c.out"
p3payload_target "$S11C" "$F11C/ow" "$ASP_SENT" || exit 1
sh "$CUT" --kit 99 --phase P3 --execute --scratch "$S11C" \
    --ow-repo "$F11C/ow" --maui-repo "$F11C/maui" --runtime-repo "$F11C/runtime" --docs-dir "$F11C/docs" \
    --sdk-repo "$SDK11" --seed-bundle "$SEED11" --dotnet "$F11C/installroot/dotnet" --no-push > "$OUT11C" 2>&1
check_rc "T11c P3 execute rc=0" "$?" 0
assert_contains "T11c materializes from the installed pack" "$OUT11C" "payload: $F11C/installroot"
cmp -s "$F11C/installroot/packs/$ASP_SENT" "$S11C/ow/packs/$ASP_SENT"; check "T11c payload bytes match the installed pack" $?

# T11d: missing in every source fails closed (rc 4) before any pack step
F11D="$T/fixture-p11-missing"; p3_ow_fixture "$F11D" || exit 1
rm -f "$F11D/ow/packs/$ASP_SENT" "$F11D/installroot/packs/$ASP_SENT"
S11D="$T/scratch-p11-missing"; OUT11D="$T/t11d.out"
mkdir -p "$T/p11-empty-mirror"
CUT_KIT_PAYLOAD_RELEASE_BASE="file://$T/p11-empty-mirror" sh "$CUT" --kit 99 --phase P3 --execute --scratch "$S11D" \
    --ow-repo "$F11D/ow" --maui-repo "$F11D/maui" --runtime-repo "$F11D/runtime" --docs-dir "$F11D/docs" \
    --sdk-repo "$SDK11" --seed-bundle "$SEED11" --dotnet "$F11D/installroot/dotnet" --no-push > "$OUT11D" 2>&1
check_rc "T11d missing payload rc=4" "$?" 4
assert_contains "T11d names the missing family/version" "$OUT11D" "known payload missing: $ASP_FAM $ASP_VER"
assert_contains "T11d names the release source" "$OUT11D" 'release mirror: springmin/aspnetcore-ohos v11.0.0-rc.2.26451.112-openharmony'
assert_contains "T11d points at the fix" "$OUT11D" 'known_payload_release_tag/sha256'
[ ! -e "$S11D/ow/.p3-calls" ]; check "T11d no pack script ran" $?
[ ! -e "$S11D/sdk-anchor-wt" ]; check "T11d no sdk anchor worktree" $?

# T11e: the release source materializes a payload the dir sources lack; a
# file:// mirror + a fixture pin row exercise download/verify/extract offline
F11E="$T/fixture-p11-release"; p3_ow_fixture "$F11E" || exit 1
VER11E="11.0.0-rc.1.77777.777"
ASP_PACK_REL="packs/$ASP_FAM"
mv "$F11E/ow/$ASP_PACK_REL/$ASP_VER" "$F11E/ow/$ASP_PACK_REL/$VER11E"
for _band in 11.0.100-rc.1 11.0.100; do
    sed -i "s/11\.0\.0-rc\.1\.26451\.112/$VER11E/" \
        "$F11E/ow/manifests/$_band/microsoft.net.sdk.openharmony/WorkloadManifest.json"
done
rm -rf "$F11E/installroot/packs/$ASP_FAM"
ASP_SENT_E="$ASP_FAM/$VER11E/runtimes/openharmony-arm64/lib/net11.0/Microsoft.AspNetCore.Components.Web.dll"
rm -f "$F11E/ow/packs/$ASP_SENT_E"
MIRROR11="$T/p11-mirror/springmin/aspnetcore-ohos/releases/download/fixture-tag"
mkdir -p "$MIRROR11"
python3 - "$MIRROR11/$ASP_FAM.$VER11E.nupkg" "runtimes/openharmony-arm64/lib/net11.0" <<'PY'
import sys, zipfile
nupkg, base = sys.argv[1:3]
with zipfile.ZipFile(nupkg, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr(base + "/Microsoft.AspNetCore.Components.Web.dll", "fixture release payload\n")
    z.writestr(base + "/Microsoft.AspNetCore.App.Runtime.openharmony-arm64.dll", "fixture dll\n")
PY
E_SHA="$(sha256sum "$MIRROR11/$ASP_FAM.$VER11E.nupkg" | cut -d' ' -f1)"
printf '%s|%s|fixture-tag|%s\n' "$ASP_FAM" "$VER11E" "$E_SHA" > "$T/p11-pins.tsv"
S11E="$T/scratch-p11-release"; OUT11E="$T/t11e.out"
p3payload_target "$S11E" "$F11E/ow" "$ASP_SENT_E" || exit 1
CUT_KIT_PAYLOAD_PINS="$T/p11-pins.tsv" CUT_KIT_PAYLOAD_RELEASE_BASE="file://$T/p11-mirror" \
sh "$CUT" --kit 99 --phase P3 --execute --scratch "$S11E" \
    --ow-repo "$F11E/ow" --maui-repo "$F11E/maui" --runtime-repo "$F11E/runtime" --docs-dir "$F11E/docs" \
    --sdk-repo "$SDK11" --seed-bundle "$SEED11" --dotnet "$F11E/installroot/dotnet" --no-push > "$OUT11E" 2>&1
check_rc "T11e P3 execute rc=0" "$?" 0
assert_contains "T11e materializes from the release" "$OUT11E" 'payload: release fixture-tag'
[ -f "$S11E/ow/packs/$ASP_SENT_E" ]; check "T11e sentinel extracted from the release" $?
[ -f "$S11E/ow/$ASP_PACK_REL/$VER11E/runtimes/openharmony-arm64/lib/net11.0/Microsoft.AspNetCore.App.Runtime.openharmony-arm64.dll" ]
check "T11e the second payload file was copied too" $?

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
