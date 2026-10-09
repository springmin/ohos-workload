#!/bin/sh
# cut-kit.sh - scripted cut of the OpenHarmony device-test kit (the kit #49..#53 five-round flow)
# with a fail-closed tester-docs pre-check.
#
# Phases (each one can run alone; a run without --phase resumes at the first phase whose rc is
# not yet 0 in <scratch>/state.env):
#   P0 preflight  repos + pins (worktrees/workflow MAUI_OHOS_REF) + four-pack abc + verify-kit
#                 EXPECT_ABC + suite/host-export counts + worktree cleanliness + repo selftests
#                 + the tester-docs gate (kit #N current block + current abc, fail-closed)
#   P1 build      release worktrees at the pin (git-ignored dist/ets + .arkts-build materialized
#                 from the main checkout) + hosting/graphics Release prep +
#                 make-device-test-kit.sh --runtime-mode aot --with-blazor (7 haps, no --publish);
#                 the docs gate runs again first and refuses to build on stale docs
#   P2 verify     the shipped verify-kit.sh in strict mode (rc=0, 0 FAIL, 0 WARN) on the built
#                 kit, the transfer sidecar, and the tree digest anchor
#   P3 bundle     prepare-packs / pack-local-workload / pack-workload-bundle / release-checksums
#                 then the sdk-ohos WORKLOAD_BUNDLE_SHA256 re-anchor + installer tests (+ push)
#   P4 release    F4 controlled clobber: prints the asset list it will replace, requires the typed
#                 confirmation, uploads through --upload-hook, re-checks by id and prints the
#                 zero-change list per release, then patches the Integrity notes on four releases
#   P5 values     RELEASE-VALUES + release-values.env + the presign/manifest hooks
#   P6 ci         CI re-check for the ow pin (five workflows) and the sdk anchor commit
#
# Safety: DRY-RUN IS THE DEFAULT - nothing is written or executed without --execute.
# P4/P5/P6 additionally require --execute --i-know. P4 asks for the confirmation line
# "clobber kit <N>" on stdin before any upload; --yes skips it and is for rehearsals only.
# This script never publishes or clobbers anything in a dry run; P1 is guarded by the docs gate
# (stale tester docs fail closed) and by the one-build discipline (--force-build to override).
#
# Usage:
#   scripts/cut-kit.sh --kit <N> [--phase P0..P6|all] [--scratch <dir>] [--dry-run|--execute]
#                      [--i-know] [--force] [--force-build] [--skip-selftests] [--full-selftests]
#                      [--bump-docs] [--ow-repo <dir>] [--maui-repo <dir>] [--runtime-repo <dir>]
#                      [--sdk-repo <dir>] [--docs-dir <dir>] [--dotnet <path>]
#                      [--build-env <file>] [--kit-dir <dir>] [--kit-out <file>]
#                      [--expect-abc <a,b>] [--pack-versions "22 23 24 28"]
#                      [--seed-bundle <tar.gz>] [--release-ids "dtk=ID latest=ID versioned=ID sdkrc2=ID"]
#                      [--sdk-release-tag <tag>] [--upload-hook <file>] [--assets-dir <dir>]
#                      [--token-file <file>] [--api-repo <owner/name>] [--no-push]
#                      [--presign-hook <file>] [--manifest-hook <file>] [--yes]
#                      [--print-docs-list] [-h|--help]
#
# Examples:
#   # whole plan, no writes (P0 really runs its checks; P1..P6 print their commands)
#   scripts/cut-kit.sh --kit 54 --dry-run
#   # phase P0 only, store the resume state
#   scripts/cut-kit.sh --kit 54 --phase P0 --execute --scratch /data/.../cut-kit54
#   # resume at the first unfinished phase, build and verify
#   scripts/cut-kit.sh --kit 54 --phase P0,P1,P2 --execute
#   # rehearsal of the release phase (prints the clobber plan, no writes)
#   scripts/cut-kit.sh --kit 54 --phase P4 --dry-run --release-ids "..."
#
# Exit code: 0 = every requested phase passed (dry-run plans count as passed); 1 = a check or
# step failed; 2 = usage error; 3 = a safety gate refused (docs stale / confirmation declined /
# missing --i-know); 4 = a prerequisite artifact is missing (execute only).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
err()  { printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { err "$*"; exit "${2:-2}"; }

usage() {
    sed -n '2,/^set -u$/p' "$0" | sed '/^set -u$/d' | sed 's/^# \{0,1\}//'
}

# ------------------------------------------------------------------------- defaults / options
KIT=""
PHASE_SEL=""
SCRATCH=""
DRY=1
IKNOW=0
FORCE=0
FORCE_BUILD=0
SKIP_SELFTESTS=0
FULL_SELFTESTS=0
BUMP_DOCS=0
OW_REPO="$REPO_ROOT"
MAUI_REPO="$REPO_ROOT/../maui-ohos"
RUNTIME_REPO="$REPO_ROOT/../runtime-ohos"
SDK_REPO="$REPO_ROOT/../sdk-ohos"
DOCS_DIR=""
DOTNET="${CUT_KIT_DOTNET:-}"
BUILD_ENV="${CUT_KIT_BUILD_ENV:-/data/storage/el2/base/tmp/opencode/kit-build-env.sh}"
KIT_DIR=""
KIT_OUT=""
EXPECT_ABC_OPT=""
PACK_VERSIONS="${CUT_KIT_PACK_VERSIONS:-22 23 24 28}"
SEED_BUNDLE=""
RELEASE_IDS="${CUT_KIT_RELEASE_IDS:-dtk=392356147 latest=392077166 versioned=398936638 sdkrc2=398739326}"
SDK_RELEASE_TAG=""
UPLOAD_HOOK=""
ASSETS_DIR=""
TOKEN_FILE="${GH_TOKEN_FILE:-}"
API_REPO="${CUT_KIT_API_REPO:-springmin/sdk-ohos}"
NO_PUSH=0
PRESIGN_HOOK=""
MANIFEST_HOOK=""
YES=0
PRINT_DOCS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --kit) shift; [ $# -ge 1 ] || die "--kit needs a value"; KIT="$1" ;;
        --phase) shift; [ $# -ge 1 ] || die "--phase needs P0..P6 or all"; PHASE_SEL="$PHASE_SEL $1" ;;
        --scratch) shift; [ $# -ge 1 ] || die "--scratch needs a dir"; SCRATCH="$1" ;;
        --dry-run) DRY=1 ;;
        --execute) DRY=0 ;;
        --i-know) IKNOW=1 ;;
        --force) FORCE=1 ;;
        --force-build) FORCE_BUILD=1 ;;
        --skip-selftests) SKIP_SELFTESTS=1 ;;
        --full-selftests) FULL_SELFTESTS=1 ;;
        --bump-docs) BUMP_DOCS=1 ;;
        --ow-repo) shift; OW_REPO="$1" ;;
        --maui-repo) shift; MAUI_REPO="$1"; MAUI_REPO_SET=1 ;;
        --runtime-repo) shift; RUNTIME_REPO="$1"; RUNTIME_REPO_SET=1 ;;
        --sdk-repo) shift; SDK_REPO="$1"; SDK_REPO_SET=1 ;;
        --docs-dir) shift; DOCS_DIR="$1" ;;
        --dotnet) shift; DOTNET="$1" ;;
        --build-env) shift; BUILD_ENV="$1" ;;
        --kit-dir) shift; KIT_DIR="$1" ;;
        --kit-out) shift; KIT_OUT="$1" ;;
        --expect-abc) shift; EXPECT_ABC_OPT="$1" ;;
        --pack-versions) shift; PACK_VERSIONS="$1" ;;
        --seed-bundle) shift; SEED_BUNDLE="$1" ;;
        --release-ids) shift; RELEASE_IDS="$1" ;;
        --sdk-release-tag) shift; SDK_RELEASE_TAG="$1" ;;
        --upload-hook) shift; UPLOAD_HOOK="$1" ;;
        --assets-dir) shift; ASSETS_DIR="$1" ;;
        --token-file) shift; TOKEN_FILE="$1" ;;
        --api-repo) shift; API_REPO="$1" ;;
        --no-push) NO_PUSH=1 ;;
        --presign-hook) shift; PRESIGN_HOOK="$1" ;;
        --manifest-hook) shift; MANIFEST_HOOK="$1" ;;
        --yes) YES=1 ;;
        --print-docs-list) PRINT_DOCS=1 ;;
        -h|--help) usage; exit 0 ;;
        *) warn "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
    shift
done

# Default sibling repos: when the script runs from a worktree the ../ names do not resolve; fall
# back to the canonical springsources checkout so a plain `--kit N` works from any worktree.
resolve_repo() { # <current> <basename>
    _cur="$1"; _base="$2"
    if [ -d "$_cur" ]; then printf '%s\n' "$_cur"; return 0; fi
    if [ -d "$HOME/springsources/$_base" ]; then printf '%s\n' "$HOME/springsources/$_base"; return 0; fi
    printf '%s\n' "$_cur"
}
[ "${MAUI_REPO_SET:-0}" = 1 ] || MAUI_REPO="$(resolve_repo "$MAUI_REPO" maui-ohos)"
[ "${RUNTIME_REPO_SET:-0}" = 1 ] || RUNTIME_REPO="$(resolve_repo "$RUNTIME_REPO" runtime-ohos)"
[ "${SDK_REPO_SET:-0}" = 1 ] || SDK_REPO="$(resolve_repo "$SDK_REPO" sdk-ohos)"

# --phase accepts "all", a single phase or a comma/space separated list; validate the tokens.
PHASE_SEL="$(printf '%s' "$PHASE_SEL" | tr ',' ' ')"
[ -n "$(printf '%s' "$PHASE_SEL" | tr -d ' ')" ] || PHASE_SEL="all"
for _tok in $PHASE_SEL; do
    case "$_tok" in
        all|P0|P1|P2|P3|P4|P5|P6) ;;
        *) die "unknown --phase value: $_tok (use P0..P6 or all)" ;;
    esac
done

# ------------------------------------------------------------------------- docs contract
# The 18 tester docs refreshed by every kit round (see the kit #50/#51/#52 waves): each must
# carry the target kit's current block and the current shell abc. Two of them are English.
docs_wave_list() {
    cat <<'EOF'
2026-09-18-ohos-device-validation-checklist.md
2026-09-19-ohos-hap-acceptance-for-testers.md
2026-09-20-ohos-tester-quickstart.md
2026-09-21-ohos-crash-probes.md
2026-09-21-ohos-delivery-kit-readme.md
2026-09-21-ohos-device-crash-diagnostics.md
2026-09-21-ohos-device-report-template.md
2026-09-21-ohos-device-run-playbook.md
2026-09-21-ohos-tester-selfsign.md
2026-09-22-ohos-maui-coverage-matrix.md
2026-09-22-ohos-new-features-device-checklist.md
2026-09-22-ohos-startup-crash-rootcause.md
2026-09-22-ohos-tester-runner.md
2026-09-24-ohos-kit-gap-analysis.md
2026-09-27-ohos-accessibility-device-verification.md
2026-09-27-ohos-runtime-mode-determination.md
2026-09-28-ohos-webview-blazor-device-card.md
2026-09-29-ohos-blazor-resign-one-pager.md
EOF
}

# "packed-name|source-file|contract" - the eight docs make-device-test-kit.sh copies into the
# kit; contract = block (kit #N current block + abc) | index (kit #N date line) | exists.
packed_docs_list() {
    cat <<'EOF'
验收说明.md|2026-09-19-ohos-hap-acceptance-for-testers.md|block
快速开始.md|2026-09-20-ohos-tester-quickstart.md|block
真机操作手册.md|2026-09-21-ohos-device-run-playbook.md|block
文档索引.md|README.md|index
签名与UDID指南.md|2026-09-19-ohos-signing-and-udid-guide.md|exists
自签说明.md|2026-09-21-ohos-tester-selfsign.md|block
最终状态.md|2026-09-21-ohos-final-status.md|exists
README-交付说明.md|2026-09-21-ohos-delivery-kit-readme.md|block
EOF
}

if [ "$PRINT_DOCS" = 1 ]; then
    printf 'docs wave (18; must carry the target kit current block + abc):\n'
    docs_wave_list | sed 's/^/   /'
    printf 'packed docs (8; block|index|exists):\n'
    packed_docs_list | sed 's/^/   /'
    exit 0
fi

[ -n "$KIT" ] || die "--kit <N> is required (or use --print-docs-list)"
case "$KIT" in
    ''|*[!0-9]*) die "--kit must be a number, got: $KIT" ;;
esac
[ "$KIT" -gt 0 ] 2>/dev/null || die "--kit must be > 0"

: "${SCRATCH:=/data/storage/el2/base/tmp/opencode/cut-kit$KIT}"
[ -n "$DOCS_DIR" ] || DOCS_DIR="$RUNTIME_REPO/docs/plans"

# ------------------------------------------------------------------------- run state / helpers
STATE="$SCRATCH/state.env"
LOGDIR="$SCRATCH/logs"
WT_OW="$SCRATCH/ow"
WT_MAUI="$SCRATCH/maui"
WT_RUNTIME="$SCRATCH/runtime"
WT_SDK="$SCRATCH/sdk-anchor-wt"
[ -n "$KIT_DIR" ] || KIT_DIR="$SCRATCH/device-test-kit"
[ -n "$KIT_OUT" ] || KIT_OUT="$SCRATCH/device-test-kit.tar.gz"
FAILED_PHASES=0

run() { # execute a command (dry-run prints it)
    if [ "$DRY" = 1 ]; then
        printf '   [dry-run] %s\n' "$*"
    else
        printf '   [run] %s\n' "$*"
        "$@"
    fi
}

st_get() { # key -> last value, rc 1 when absent
    [ -f "$STATE" ] || return 1
    _v="$(grep -E "^$1=" "$STATE" 2>/dev/null | tail -n 1 | cut -d= -f2-)"
    [ -n "$_v" ] || return 1
    printf '%s\n' "$_v"
}

st_set() { # key value (no-op in dry-run)
    [ "$DRY" = 1 ] && return 0
    mkdir -p "$SCRATCH" || return 1
    if [ -f "$STATE" ]; then
        grep -vE "^$1=" "$STATE" > "$STATE.tmp" 2>/dev/null || : > "$STATE.tmp"
    else
        : > "$STATE.tmp"
    fi
    printf '%s=%s\n' "$1" "$2" >> "$STATE.tmp"
    mv "$STATE.tmp" "$STATE"
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
size_of()   { stat -c%s "$1"; }

is_git_repo() { git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1; }

pick_src() { # <preferred-worktree> <main-repo> -> existing one
    if [ -d "$1" ]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi
}
src_ow()      { pick_src "$WT_OW" "$OW_REPO"; }
src_runtime() { pick_src "$WT_RUNTIME" "$RUNTIME_REPO"; }

pin_ow() {
    if [ -f "$SCRATCH/ow-pin.txt" ]; then cat "$SCRATCH/ow-pin.txt"; return 0; fi
    if git -C "$OW_REPO" rev-parse --verify -q origin/master >/dev/null 2>&1; then
        git -C "$OW_REPO" rev-parse origin/master; return 0
    fi
    git -C "$OW_REPO" rev-parse HEAD 2>/dev/null || true
}
pin_maui() {
    if [ -f "$SCRATCH/maui-tip.txt" ]; then cat "$SCRATCH/maui-tip.txt"; return 0; fi
    if git -C "$MAUI_REPO" rev-parse --verify -q origin/feature/openharmony >/dev/null 2>&1; then
        git -C "$MAUI_REPO" rev-parse origin/feature/openharmony; return 0
    fi
    git -C "$MAUI_REPO" rev-parse HEAD 2>/dev/null || true
}
pin_runtime() {
    if [ -f "$SCRATCH/runtime-tip.txt" ]; then cat "$SCRATCH/runtime-tip.txt"; return 0; fi
    git -C "$RUNTIME_REPO" rev-parse HEAD 2>/dev/null || true
}

expect_abc_from() { # <ow-src> -> "A,B" from verify-kit.sh
    sed -n 's/^EXPECT_ABC="\${KIT_EXPECTED_ABC:-\(.*\)}"/\1/p' "$1/scripts/verify-kit.sh" | head -n 1
}
expect_abc() { # resolved expectation of this run
    if [ -n "$EXPECT_ABC_OPT" ]; then
        printf '%s\n' "$EXPECT_ABC_OPT"
    else
        _a="$(st_get expect_abc || true)"
        if [ -n "$_a" ]; then printf '%s\n' "$_a"; else expect_abc_from "$(src_ow)"; fi
    fi
}

abc_forms() { # 548192 -> "548192 548,192"
    _plain="$1"
    _comma="$(printf '%s' "$_plain" | sed -e 's/^\([0-9]\{1,\}\)\([0-9][0-9][0-9]\)$/\1,\2/')"
    printf '%s %s\n' "$_plain" "$_comma"
}

fetch_pinned() { # <repo> <ref>
    git -C "$1" fetch -q origin "$2" 2>/dev/null && return 0
    for _ip in 140.82.112.3 20.26.156.215 20.27.177.113; do
        git -C "$1" -c http.curloptResolve=github.com:443:$_ip fetch -q origin "$2" 2>/dev/null && return 0
    done
    return 1
}

git_push() { # <worktree> <refspec>
    _d="$1"; _ref="$2"
    if [ "$NO_PUSH" = 1 ]; then
        log "push skipped (--no-push): $_d $_ref"
        return 0
    fi
    if git -C "$_d" push origin "$_ref"; then
        log "pushed: $_d $_ref"
        return 0
    fi
    for _ip in 140.82.112.3 20.26.156.215 20.27.177.113; do
        log "push pinned github.com:443:$_ip"
        if git -C "$_d" -c http.curloptResolve=github.com:443:$_ip push origin "$_ref"; then
            log "pushed (pinned $_ip)"
            return 0
        fi
    done
    err "push failed: $_d $_ref"
    return 1
}

api_token() {
    if [ -n "$TOKEN_FILE" ] && [ -f "$TOKEN_FILE" ]; then
        cat "$TOKEN_FILE"
    elif [ -n "${GH_TOKEN:-}" ]; then
        printf '%s\n' "$GH_TOKEN"
    elif [ -n "${GITHUB_TOKEN:-}" ]; then
        printf '%s\n' "$GITHUB_TOKEN"
    else
        return 1
    fi
}

api_get() { # <path-or-url>
    _tok="$(api_token)" || return 1
    _url="$1"
    case "$_url" in
        http*) ;;
        *) _url="https://api.github.com/$1" ;;
    esac
    curl -sS --http1.1 --max-time 90 -H "Authorization: token $_tok" "$_url"
}

require_execute_iknow() { # <phase>; returns 0 only in --execute --i-know mode, else 3
    if [ "$DRY" = 1 ]; then
        log "$1: dry-run plan only (execute with --execute --i-know to run it)"
        return 3
    fi
    if [ "$IKNOW" != 1 ]; then
        err "$1 requires --execute --i-know (release-affecting phase)"
        return 3
    fi
    return 0
}

# ------------------------------------------------------------------------- P0
docs_gate() { # 0 = docs match the target kit; also prints the check lines
    _d="$DOCS_DIR"
    _abc="$(expect_abc)"
    _ui="${_abc%,*}"
    _dfails=0
    [ -n "$_abc" ] || { err "docs gate: cannot resolve EXPECT_ABC (pass --expect-abc)"; return 1; }
    for _df in $(docs_wave_list); do
        _docpath="$_d/$_df"
        if [ ! -f "$_docpath" ]; then
            printf '   docs FAIL %s: missing\n' "$_df" >&2
            _dfails=$((_dfails + 1))
            continue
        fi
        _cur="$(grep -hoE "kit #[0-9]+，当前[）)]|kit #[0-9]+ — current[）)]" "$_docpath" \
            | sed 's/kit #\([0-9]*\).*/\1/' | sort -u | tr '\n' ' ' | sed 's/ $//')"
        if [ "$_cur" != "$KIT" ]; then
            printf '   docs FAIL %s: current kit block is [%s], expected kit #%s\n' \
                "$_df" "$_cur" "$KIT" >&2
            _dfails=$((_dfails + 1))
        fi
        _have=0
        for _form in $(abc_forms "$_ui"); do
            grep -qF "$_form" "$_docpath" && _have=1
        done
        if [ "$_have" != 1 ]; then
            printf '   docs FAIL %s: missing the current shell abc %s\n' "$_df" "$_ui" >&2
            _dfails=$((_dfails + 1))
        fi
    done
    # the eight packed docs: existence + contract (the wave check covers the block ones)
    _fails_packed="$(packed_docs_list | while IFS='|' read -r _name _src _contract; do
        [ -f "$_d/$_src" ] || printf 'x\n'
    done | wc -l)"
    _dfails=$((_dfails + _fails_packed))
    # index: kit #N date line + no foreign current marker
    _idx="$_d/README.md"
    if [ -f "$_idx" ]; then
        if ! grep -qE "kit #$KIT[ ]*日期口径|当前口径 = kit #$KIT|当前口径=kit #$KIT" "$_idx"; then
            printf '   docs FAIL README.md: no "kit #%s 日期口径" line\n' "$KIT" >&2
            _dfails=$((_dfails + 1))
        fi
        _icur="$(grep -hoE "kit #[0-9]+，当前[）)]|kit #[0-9]+ — current[）)]" "$_idx" \
            | sed 's/kit #\([0-9]*\).*/\1/' | sort -u | tr '\n' ' ' | sed 's/ $//')"
        if [ -n "$_icur" ] && [ "$_icur" != "$KIT" ]; then
            printf '   docs FAIL README.md: current marker [%s]\n' "$_icur" >&2
            _dfails=$((_dfails + 1))
        fi
    else
        printf '   docs FAIL README.md missing\n' >&2
        _dfails=$((_dfails + 1))
    fi
    if [ "$_dfails" != 0 ]; then
        err "tester docs are stale for kit #$KIT ($_dfails doc issue(s)); refusing to build"
        log "hint: update the 18 tester docs (kit #$KIT current block + abc $(abc_forms "$_ui" | tr ' ' '/')) and the index"
        log "hint: commit the docs wave with scripts/commit-paths.sh, or re-run with --bump-docs"
        log "hint: --bump-docs runs scripts/bump-tester-docs.sh --kit $KIT (18 docs + README; idempotent, --dry-run)"
        st_set "docs_gate_kit" "stale"
        return 3
    fi
    printf '   docs kit #%s          PASS (%s wave docs; abc %s; index ok)\n' \
        "$KIT" "$(docs_wave_list | wc -l | tr -d ' ')" "$_ui"
    st_set "docs_gate_kit" "$KIT"
    st_set "docs_gate_abc" "$_abc"
    return 0
}

bump_docs() {
    if [ "$DRY" = 1 ]; then
        die "--bump-docs edits the tester docs; run it with --execute"
    fi
    _helper="$OW_REPO/scripts/bump-tester-docs.sh"
    if [ -f "$_helper" ]; then
        _abc="$(expect_abc)"
        if [ -n "$_abc" ]; then
            run sh "$_helper" --kit "$KIT" --abc "$_abc" --docs-dir "$DOCS_DIR" || return $?
        else
            run sh "$_helper" --kit "$KIT" --docs-dir "$DOCS_DIR" || return $?
        fi
    else
        err "scripts/bump-tester-docs.sh not found under $OW_REPO"
        log "the kit-round docs wave still has to edit the 18 tester docs + README index by hand"
        log "then commit them with scripts/commit-paths.sh and re-run P0/P1 (known gap, see the plan doc)"
        exit 3
    fi
}

p0_repos() {
    _f=0
    for _r in "$OW_REPO" "$MAUI_REPO" "$RUNTIME_REPO"; do
        if is_git_repo "$_r"; then
            : # ok
        else
            printf '   repos FAIL %s: not a git work tree\n' "$_r" >&2
            _f=$((_f + 1))
        fi
    done
    [ "$_f" = 0 ] && printf '   repos                PASS (ow/maui/runtime present)\n'
    return "$_f"
}

p0_pins() {
    _f=0
    _owpin="$(pin_ow)"; _mauitip="$(pin_maui)"; _rttip="$(pin_runtime)"
    [ -n "$_owpin" ] || { printf '   pins FAIL: cannot resolve the ow pin\n' >&2; _f=$((_f + 1)); }
    [ -n "$_mauitip" ] || { printf '   pins FAIL: cannot resolve the maui tip\n' >&2; _f=$((_f + 1)); }
    [ -n "$_rttip" ] || { printf '   pins FAIL: cannot resolve the runtime tip\n' >&2; _f=$((_f + 1)); }
    _src="$(src_ow)"
    _refs=""
    for _wf in interaction-regression pixel-regression host-export-contract; do
        _wf="$_src/.github/workflows/$_wf.yml"
        _r="$(grep -oE '[0-9a-f]{40}' "$_wf" 2>/dev/null | head -n 1)"
        [ -n "$_r" ] || { printf '   pins FAIL %s: no MAUI_OHOS_REF pin\n' "$(basename "$_wf")" >&2; _f=$((_f + 1)); }
        _refs="$_refs $_r"
    done
    _uniq="$(printf '%s\n' $_refs | sort -u | tr '\n' ' ' | sed 's/ $//')"
    _n="$(printf '%s\n' $_refs | sort -u | wc -l | tr -d ' ')"
    if [ "$_n" != 1 ]; then
        printf '   pins FAIL workflow pins disagree: [%s]\n' "$_uniq" >&2
        _f=$((_f + 1))
    elif [ "$_uniq" != "$_mauitip" ]; then
        printf '   pins FAIL workflow pin %s != maui tip %s\n' "$_uniq" "$_mauitip" >&2
        _f=$((_f + 1))
    fi
    if [ -d "$WT_OW" ] && [ "$(git -C "$WT_OW" rev-parse HEAD 2>/dev/null)" != "$_owpin" ]; then
        printf '   pins FAIL ow worktree HEAD != pin %s\n' "$_owpin" >&2
        _f=$((_f + 1))
    fi
    if [ -d "$WT_MAUI" ] && [ "$(git -C "$WT_MAUI" rev-parse HEAD 2>/dev/null)" != "$_mauitip" ]; then
        printf '   pins FAIL maui worktree HEAD != tip %s\n' "$_mauitip" >&2
        _f=$((_f + 1))
    fi
    st_set pin_ow "$_owpin"; st_set pin_maui "$_mauitip"; st_set pin_runtime "$_rttip"
    [ "$_f" = 0 ] && printf '   pins                 PASS (ow %s maui %s runtime %s; workflows %s)\n' \
        "$(printf '%s' "$_owpin" | cut -c1-10)" "$(printf '%s' "$_mauitip" | cut -c1-10)" \
        "$(printf '%s' "$_rttip" | cut -c1-10)" "$(printf '%s' "$_mauitip" | cut -c1-10)"
    return "$_f"
}

p0_packs() {
    _f=0
    _src="$(src_ow)"
    _abc="$(expect_abc)"
    if [ -z "$_abc" ]; then
        printf '   packs abc FAIL: cannot resolve EXPECT_ABC from %s/scripts/verify-kit.sh\n' "$_src" >&2
        return 1
    fi
    _ui="${_abc%,*}"; _hl="${_abc#*,}"
    _ids=""
    for _v in $PACK_VERSIONS; do
        _pkpath="$_src/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.$_v/templates/ets"
        if [ ! -f "$_pkpath/modules.ui.abc" ] || [ ! -f "$_pkpath/modules.abc" ]; then
            printf '   packs abc FAIL preview.%s: modules.ui.abc/modules.abc missing\n' "$_v" >&2
            _f=$((_f + 1))
            continue
        fi
        _usz="$(size_of "$_pkpath/modules.ui.abc")"; _uh="$(sha256_of "$_pkpath/modules.ui.abc" | cut -c1-8)"
        _hsz="$(size_of "$_pkpath/modules.abc")"; _hh="$(sha256_of "$_pkpath/modules.abc" | cut -c1-8)"
        if [ "$_usz" != "$_ui" ] || [ "$_hsz" != "$_hl" ]; then
            printf '   packs abc FAIL preview.%s: ui %s/%s headless %s/%s, EXPECT_ABC %s\n' \
                "$_v" "$_usz" "$_uh" "$_hsz" "$_hh" "$_abc" >&2
            _f=$((_f + 1))
        fi
        _ids="$_ids $_v:$_usz/$_uh,$_hsz/$_hh"
    done
    st_set expect_abc "$_abc"
    if [ "$_f" = 0 ]; then
        printf '   packs abc            PASS (%s ui=%s headless=%s, EXPECT_ABC=%s)\n' \
            "preview.$PACK_VERSIONS" "$_ui" "$_hl" "$_abc"
        printf '   pack fingerprints%s\n' "$_ids"
    fi
    return "$_f"
}

p0_suite() {
    _f=0
    _src="$(src_ow)"
    _prog="$_src/test/maui-platform-verify/Program.cs"
    if [ -f "$_prog" ]; then
        _tot="$(grep -oE 'verifyCheckTotal *= *[0-9]+' "$_prog" | head -n 1 | grep -oE '[0-9]+')"
        _flr="$(grep -oE 'verifyCheckFloor *= *[0-9]+' "$_prog" | head -n 1 | grep -oE '[0-9]+')"
        if [ -z "$_tot" ]; then
            printf '   suite FAIL: no verifyCheckTotal in %s\n' "$_prog" >&2
            _f=$((_f + 1))
        elif [ -n "$_flr" ] && [ "$_flr" != "$((_tot - 20))" ]; then
            printf '   suite FAIL: floor %s != total-20 (%s)\n' "$_flr" "$((_tot - 20))" >&2
            _f=$((_f + 1))
        else
            st_set suite_total "$_tot"; st_set suite_floor "$((_tot - 20))"
            printf '   suite                PASS (verifyCheckTotal=%s floor=%s)\n' "$_tot" "$((_tot - 20))"
        fi
    else
        printf '   suite FAIL: missing %s\n' "$_prog" >&2
        _f=$((_f + 1))
    fi
    _exp="$_src/src/OpenHarmonyHost/host-exports.txt"
    if [ -f "$_exp" ]; then
        _n="$(awk '!/^[[:space:]]*(#|$)/ {n++} END{print n+0}' "$_exp")"
        if [ "$_n" -gt 0 ] 2>/dev/null; then
            st_set host_exports "$_n"
            printf '   host exports         PASS (%s entries)\n' "$_n"
        else
            printf '   host exports FAIL: no entries in %s\n' "$_exp" >&2
            _f=$((_f + 1))
        fi
    else
        printf '   host exports FAIL: missing %s\n' "$_exp" >&2
        _f=$((_f + 1))
    fi
    return "$_f"
}

p0_worktrees() {
    _f=0; _seen=0
    for _wt in "$WT_OW" "$WT_MAUI" "$WT_RUNTIME"; do
        [ -d "$_wt" ] || continue
        _seen=1
        _n="$(git -C "$_wt" status --porcelain | wc -l | tr -d ' ')"
        if [ "$_n" != 0 ]; then
            printf '   worktrees FAIL %s: %s dirty entries\n' "$_wt" "$_n" >&2
            _f=$((_f + 1))
        fi
    done
    if [ "$_seen" = 0 ]; then
        printf '   worktrees            PASS (none yet; a fresh run creates them in P1)\n'
    else
        [ "$_f" = 0 ] && printf '   worktrees            PASS (clean)\n'
    fi
    return "$_f"
}

p0_selftests() {
    if [ "$SKIP_SELFTESTS" = 1 ]; then
        printf '   selftests            SKIP (--skip-selftests)\n'
        return 0
    fi
    _src="$(src_ow)"
    _list="selftest-verify-kit.sh selftest-make-device-test-kit.sh"
    if [ "$FULL_SELFTESTS" = 1 ]; then
        _list="selftest-ridgraph.sh selftest-packs.sh selftest-hap-targets.sh selftest-tasks.sh selftest-repo-hygiene.sh selftest-host-registry.sh selftest-host-window-bridge.sh selftest-host-a11y-table.sh selftest-verify-kit.sh selftest-make-device-test-kit.sh"
    fi
    _f=0; _ok=0
    for _s in $_list; do
        _spath="$_src/scripts/$_s"
        if [ ! -f "$_spath" ]; then
            printf '   selftests FAIL %s: missing\n' "$_s" >&2
            _f=$((_f + 1))
            continue
        fi
        if [ "$DRY" = 1 ]; then
            ( cd "$_src" && sh "scripts/$_s" ) >/dev/null 2>&1
            _rc=$?
        else
            mkdir -p "$LOGDIR"
            ( cd "$_src" && sh "scripts/$_s" ) > "$LOGDIR/$_s.log" 2>&1
            _rc=$?
        fi
        if [ "$_rc" = 0 ]; then
            _ok=$((_ok + 1))
        else
            printf '   selftests FAIL %s (rc=%s; log %s)\n' "$_s" "$_rc" "$LOGDIR/$_s.log" >&2
            _f=$((_f + 1))
        fi
    done
    [ "$_f" = 0 ] && printf '   selftests            PASS (%s/%s)\n' "$_ok" "$((_ok + _f))"
    return "$_f"
}

phase_P0() {
    log "== P0 preflight (kit #$KIT, scratch $SCRATCH) =="
    _pf=0
    p0_repos || _pf=$((_pf + 1))
    p0_pins || _pf=$((_pf + 1))
    p0_packs || _pf=$((_pf + 1))
    p0_suite || _pf=$((_pf + 1))
    p0_worktrees || _pf=$((_pf + 1))
    p0_selftests || _pf=$((_pf + 1))
    if [ "$BUMP_DOCS" = 1 ]; then
        bump_docs
    fi
    docs_gate
    _drc=$?
    if [ "$_drc" != 0 ]; then
        _pf=$((_pf + 1))
    fi
    st_set P0_kit "$KIT"
    if [ "$_pf" = 0 ]; then
        log "P0 PASS"
        return 0
    fi
    err "P0 FAIL ($_pf check group(s) failed)"
    [ "$_drc" != 0 ] && return 3
    return 1
}

# ------------------------------------------------------------------------- P1
ensure_wt() { # <name> <main-repo> <wt> <pin> <fetch-ref>
    _name="$1"; _main="$2"; _wt="$3"; _pin="$4"; _ref="$5"
    if [ "$DRY" = 1 ]; then
        run git -C "$_main" fetch origin "$_ref"
        run git -C "$_main" worktree add --detach "$_wt" "$_pin"
        return 0
    fi
    [ -d "$_main" ] || { err "$_name: main repo missing: $_main"; return 1; }
    if [ ! -d "$_wt" ]; then
        fetch_pinned "$_main" "$_ref" || warn "$_name fetch WARN (using local refs)"
        git -C "$_main" worktree add --detach "$_wt" "$_pin" >/dev/null 2>&1 || \
            { err "$_name: worktree add failed ($_wt @ $_pin)"; return 1; }
    else
        git -C "$_wt" checkout --detach "$_pin" >/dev/null 2>&1 || \
            { err "$_name: checkout failed ($_pin)"; return 1; }
    fi
    _n="$(git -C "$_wt" status --porcelain | wc -l | tr -d ' ')"
    [ "$_n" = 0 ] || { err "$_name: worktree dirty ($_n entries); a writer may be active"; return 1; }
    log "$_name worktree @ $(git -C "$_wt" rev-parse HEAD)"
    return 0
}

p1_worktrees() {
    _f=0
    ensure_wt ow "$OW_REPO" "$WT_OW" "$(pin_ow)" master || _f=$((_f + 1))
    ensure_wt maui "$MAUI_REPO" "$WT_MAUI" "$(pin_maui)" feature/openharmony || _f=$((_f + 1))
    ensure_wt runtime "$RUNTIME_REPO" "$WT_RUNTIME" "$(pin_runtime)" feature/openharmony || _f=$((_f + 1))
    return "$_f"
}

p1_env() {
    [ -f "$BUILD_ENV" ] && . "$BUILD_ENV"
    [ -n "$DOTNET" ] || {
        if [ -x "$HOME/.dotnet.rc2-fix/dotnet" ]; then DOTNET="$HOME/.dotnet.rc2-fix/dotnet"; else DOTNET=dotnet; fi
    }
    export DOTNET
    export MAUI_SLICE_DIR="$WT_MAUI/src/Core/src/Platform/OpenHarmony"
    export OpenHarmonyMauiPlatformDir="$MAUI_SLICE_DIR"
    export RUNTIME_OHOS_PLANS="$RUNTIME_REPO/docs/plans"
    export DOTNET_PROCESSOR_COUNT="${DOTNET_PROCESSOR_COUNT:-1}"
    export OhosTaskHostOverride=true
    [ -f /data/storage/el2/base/tmp/opencode/fixtest/empty-nuget.config ] && \
        export RestoreConfigFile=/data/storage/el2/base/tmp/opencode/fixtest/empty-nuget.config
    [ -s /data/storage/el2/base/tmp/opencode/aot-v3/aot-local-hooks.targets ] && \
        export OHOS_AOT_HOOKS=/data/storage/el2/base/tmp/opencode/aot-v3/aot-local-hooks.targets
    return 0
}

p1_prep() {
    if [ "$DRY" = 1 ]; then
        printf '   [dry-run] (materialize dist/ets + .arkts-build from the main checkout when missing)\n'
        printf '   [dry-run] (cd %s && $DOTNET build src/Microsoft.OpenHarmony.Hosting/... -c Release)\n' "$WT_OW"
        printf '   [dry-run] (cd %s && $DOTNET build src/Microsoft.OpenHarmony.Maui.Graphics/... -c Release)\n' "$WT_OW"
        return 0
    fi
    # A fresh worktree never carries the two git-ignored inputs the kit build needs: the ArkTS
    # shell (dist/ets/modules.abc) and the hvigor toolchain (.arkts-build, for --with-blazor).
    # Copy them from the main checkout; both names are ignored, so the worktree stays clean.
    _p1_ignored() {
        _rel="$1"; _what="$2"
        if [ ! -e "$WT_OW/$_rel" ]; then
            [ -e "$OW_REPO/$_rel" ] || {
                err "P1 prep: $_what missing ($WT_OW/$_rel; not in $OW_REPO either)"; return 1; }
            log "P1 prep: materialize $_what: $OW_REPO/$_rel -> $WT_OW/$_rel"
            mkdir -p "$(dirname "$WT_OW/$_rel")"
            cp -R "$OW_REPO/$_rel" "$WT_OW/$_rel" || {
                err "P1 prep: copy failed: $_what"; return 1; }
        fi
        return 0
    }
    _p1_ignored dist/ets "ArkTS shell" || return 1
    _p1_ignored .arkts-build "hvigor toolchain" || return 1
    mkdir -p "$LOGDIR"
    ( cd "$WT_OW" && "$DOTNET" build src/Microsoft.OpenHarmony.Hosting/Microsoft.OpenHarmony.Hosting.csproj \
        -c Release -v:q --nologo ) >> "$LOGDIR/p1-prep.log" 2>&1 || return 1
    ( cd "$WT_OW" && "$DOTNET" build src/Microsoft.OpenHarmony.Maui.Graphics/Microsoft.OpenHarmony.Maui.Graphics.csproj \
        -c Release -v:q --nologo ) >> "$LOGDIR/p1-prep.log" 2>&1 || return 1
    return 0
}

p1_build() {
    if [ "$DRY" = 1 ]; then
        printf '   [dry-run] (cd %s && sh scripts/make-device-test-kit.sh --runtime-mode aot --with-blazor \\\n' "$WT_OW"
        printf '                --kit-dir %s --out %s)\n' "$KIT_DIR" "$KIT_OUT"
        return 0
    fi
    mkdir -p "$LOGDIR"
    ( cd "$WT_OW" && sh scripts/make-device-test-kit.sh --runtime-mode aot --with-blazor \
        --kit-dir "$KIT_DIR" --out "$KIT_OUT" ) > "$LOGDIR/p1-build.log" 2>&1
    _rc=$?
    [ "$_rc" = 0 ] || { err "kit build failed (rc=$_rc; log $LOGDIR/p1-build.log)"; return 1; }
    [ -f "$KIT_OUT" ] || { err "kit tarball not produced: $KIT_OUT"; return 1; }
    # A (re)built tarball invalidates the previous transport sidecar; P2 recreates it.
    rm -f "$KIT_OUT.sha256"
    st_set kit_size_B "$(size_of "$KIT_OUT")"
    st_set kit_sha256 "$(sha256_of "$KIT_OUT")"
    return 0
}

phase_P1() {
    log "== P1 build (kit #$KIT) =="
    if ! docs_gate; then
        if [ "$BUMP_DOCS" = 1 ]; then
            bump_docs
        fi
        if ! docs_gate >/dev/null 2>&1; then
            err "docs gate failed; refusing to build with stale tester docs (fail-closed)"
            return 3
        fi
    fi
    if [ "$DRY" != 1 ] && [ -f "$KIT_OUT" ] && [ "$FORCE_BUILD" != 1 ]; then
        err "kit tarball already exists: $KIT_OUT (one-build discipline; pass --force-build to rebuild)"
        return 1
    fi
    p1_env
    log "DOTNET=$DOTNET"
    p1_worktrees || return 1
    p1_prep || { err "hosting/graphics Release prep failed"; return 1; }
    p1_build || return 1
    [ "$DRY" = 1 ] || {
        st_set P1_kit "$KIT"
        st_set P1_dotnet "$DOTNET"
    }
    log "P1 PASS"
    return 0
}

# ------------------------------------------------------------------------- P2
phase_P2() {
    log "== P2 verify-kit strict (kit #$KIT) =="
    _src="$(src_ow)"
    _abc="$(expect_abc)"
    if [ "$DRY" = 1 ]; then
        printf '   [dry-run] sh %s/scripts/verify-kit.sh --expected-abc %s --tree-digest %s\n' \
            "$_src" "$_abc" "$KIT_DIR"
        printf '   [dry-run] (cd %s && sha256sum -c %s.sha256)\n' "$SCRATCH" "$(basename "$KIT_OUT")"
        printf '   [dry-run] strict gate: rc=0, 0 FAIL, 0 WARN; record kit sha/size/tree digest\n'
        return 0
    fi
    [ -d "$KIT_DIR" ] || { err "kit dir missing: $KIT_DIR (run P1 first)"; return 4; }
    [ -f "$KIT_OUT" ] || { err "kit tarball missing: $KIT_OUT"; return 4; }
    [ -f "$KIT_OUT.sha256" ] || ( cd "$(dirname "$KIT_OUT")" && sha256sum "$(basename "$KIT_OUT")" > "$(basename "$KIT_OUT").sha256" )
    mkdir -p "$LOGDIR"
    _out="$(sh "$_src/scripts/verify-kit.sh" --expected-abc "$_abc" --tree-digest "$KIT_DIR" 2>&1)"
    _rc=$?
    printf '%s\n' "$_out" > "$LOGDIR/p2-verify.log"
    _fails="$(printf '%s\n' "$_out" | grep -c 'FAIL:')"
    _warns="$(printf '%s\n' "$_out" | grep -c 'WARN:')"
    _tree="$(printf '%s\n' "$_out" | sed -n 's/^.*tree sha256=//p' | head -n 1)"
    ( cd "$(dirname "$KIT_OUT")" && sha256sum -c "$(basename "$KIT_OUT").sha256" >/dev/null 2>&1 ) || {
        err "transfer sidecar check failed: $KIT_OUT.sha256"; return 1; }
    if [ "$_rc" = 0 ] && [ "$_fails" = 0 ] && [ "$_warns" = 0 ] && [ -n "$_tree" ]; then
        st_set kit_sha256 "$(sha256_of "$KIT_OUT")"
        st_set kit_size_B "$(size_of "$KIT_OUT")"
        st_set kit_sidecar_sha256 "$(sha256_of "$KIT_OUT.sha256")"
        st_set kit_tree_digest "$_tree"
        st_set P2_kit "$KIT"
        printf '   verify-kit           PASS (rc=0, 0 FAIL, 0 WARN; tree %s)\n' "$(printf '%s' "$_tree" | cut -c1-16)"
        log "P2 PASS"
        return 0
    fi
    err "verify-kit strict gate failed (rc=$_rc FAIL=$_fails WARN=$_warns; log $LOGDIR/p2-verify.log)"
    return 1
}

# ------------------------------------------------------------------------- P3
p3_bundle() {
    _oww="$(src_ow)"
    _band="${SDK_BAND:-11.0.100-rc.1}"
    if [ "$DRY" = 1 ]; then
        printf '   [dry-run] (cd %s && sh scripts/prepare-packs.sh)\n' "$_oww"
        printf '   [dry-run] (cd %s && sh scripts/pack-local-workload.sh %s/.feed)\n' "$_oww" "$_oww"
        printf '   [dry-run] (cd %s && sh scripts/pack-workload-bundle.sh)\n' "$_oww"
        printf '   [dry-run] (cd %s && sh scripts/release-checksums.sh)\n' "$_oww"
        return 0
    fi
    [ -d "$_oww" ] || { err "ow worktree missing: $_oww"; return 4; }
    mkdir -p "$LOGDIR"
    if [ -n "$SEED_BUNDLE" ] && [ -f "$SEED_BUNDLE" ]; then
        mkdir -p "$SCRATCH/old-bundle"
        tar -xzf "$SEED_BUNDLE" -C "$SCRATCH/old-bundle" 2>/dev/null || true
        _oldfeed="$(find "$SCRATCH/old-bundle" -maxdepth 2 -type d -name feed | head -n 1)"
        [ -n "$_oldfeed" ] && { mkdir -p "$_oww/.feed"; cp -f "$_oldfeed"/*.nupkg "$_oww/.feed/" 2>/dev/null || true; }
    fi
    ( cd "$_oww" && sh scripts/prepare-packs.sh ) >> "$LOGDIR/p3-bundle.log" 2>&1 || \
        { err "prepare-packs failed (log $LOGDIR/p3-bundle.log)"; return 1; }
    ( cd "$_oww" && sh scripts/pack-local-workload.sh "$_oww/.feed" ) >> "$LOGDIR/p3-bundle.log" 2>&1 || \
        { err "pack-local-workload failed"; return 1; }
    ( cd "$_oww" && sh scripts/pack-workload-bundle.sh ) >> "$LOGDIR/p3-bundle.log" 2>&1 || \
        { err "pack-workload-bundle failed"; return 1; }
    ( cd "$_oww" && sh scripts/release-checksums.sh ) >> "$LOGDIR/p3-bundle.log" 2>&1 || \
        { err "release-checksums failed"; return 1; }
    _bundle="$(ls -1 "$_oww"/dist/openharmony-workload-1.0.0-preview.*.tar.gz 2>/dev/null | sort | tail -n 1)"
    [ -n "$_bundle" ] || { err "bundle tarball not found under $_oww/dist"; return 1; }
    st_set bundle_path "$_bundle"
    st_set bundle_size_B "$(size_of "$_bundle")"
    st_set bundle_sha256 "$(sha256_of "$_bundle")"
    st_set bundle_sums_sha256 "$(sha256_of "$_oww/dist/SHA256SUMS")"
    st_set bundle_band "$_band"
    return 0
}

p3_sdk_anchor() {
    _new="$(st_get bundle_sha256 || true)"
    if [ -z "$_new" ]; then
        if [ "$DRY" = 1 ]; then
            printf '   [dry-run] WORKLOAD_BUNDLE_SHA256 -> <just-built bundle sha> in %s/eng/ohos-install/versions.env\n' "$SDK_REPO"
            return 0
        fi
        err "no bundle sha in state (run the bundle step first)"; return 4
    fi
    if [ "$DRY" = 1 ]; then
        printf '   [dry-run] git -C %s worktree add --detach %s origin/feature/openharmony\n' "$SDK_REPO" "$WT_SDK"
        printf '   [dry-run] replace WORKLOAD_BUNDLE_SHA256 ... -> %s (exactly one occurrence)\n' "$(printf '%s' "$_new" | cut -c1-8)"
        printf '   [dry-run] (cd %s && sh eng/ohos-install/tests/test-installer-verification.sh)\n' "$WT_SDK"
        printf '   [dry-run] (cd %s && sh eng/ohos-install/tests/test-hostfeed-verification.sh)\n' "$WT_SDK"
        printf '   [dry-run] (cd %s && sh eng/ohos-install/tests/test-codesign-filewrites.sh)\n' "$WT_SDK"
        printf '   [dry-run] git commit + push origin HEAD:feature/openharmony\n'
        return 0
    fi
    [ -d "$SDK_REPO" ] || { err "sdk-ohos repo missing: $SDK_REPO (pass --sdk-repo)"; return 4; }
    mkdir -p "$LOGDIR"
    fetch_pinned "$SDK_REPO" feature/openharmony || warn "sdk fetch WARN (using local refs)"
    if [ ! -d "$WT_SDK" ]; then
        git -C "$SDK_REPO" worktree add --detach "$WT_SDK" origin/feature/openharmony >/dev/null 2>&1 || \
            { err "sdk worktree add failed"; return 1; }
    else
        git -C "$WT_SDK" checkout --detach origin/feature/openharmony >/dev/null 2>&1 || \
            { err "sdk worktree checkout failed"; return 1; }
    fi
    _venv="$WT_SDK/eng/ohos-install/versions.env"
    [ -f "$_venv" ] || { err "missing $_venv"; return 4; }
    python3 - "$_venv" "$_new" <<'PY' || return 1
import sys
path, new = sys.argv[1:3]
src = open(path, encoding="utf-8").read()
if new in src:
    print("already anchored:", new); sys.exit(0)
import re
m = re.findall(r"WORKLOAD_BUNDLE_SHA256=([0-9a-f]{64})", src)
if len(m) != 1:
    print(f"FAIL: expected exactly one WORKLOAD_BUNDLE_SHA256, found {len(m)}"); sys.exit(1)
open(path, "w", encoding="utf-8").write(src.replace(m[0], new))
print(f"WORKLOAD_BUNDLE_SHA256 {m[0][:8]} -> {new[:8]}")
PY
    _f=0
    for _t in test-installer-verification test-hostfeed-verification test-codesign-filewrites; do
        _testpath="$WT_SDK/eng/ohos-install/tests/$_t.sh"
        if [ -f "$_testpath" ]; then
            ( cd "$WT_SDK" && sh "eng/ohos-install/tests/$_t.sh" ) > "$LOGDIR/sdk-$_t.log" 2>&1 || \
                { err "$_t failed (log $LOGDIR/sdk-$_t.log)"; _f=$((_f + 1)); }
        else
            warn "installer test missing: $_testpath (skipped)"
        fi
    done
    [ "$_f" = 0 ] || return 1
    git -C "$WT_SDK" add eng/ohos-install/versions.env
    git -C "$WT_SDK" -c user.name=springmin -c user.email=springmin@hotmail.com \
        commit -m "ohos-install: re-anchor the workload bundle digest (kit #$KIT)" >/dev/null 2>&1 || \
        { err "sdk anchor commit failed"; return 1; }
    _anchor="$(git -C "$WT_SDK" rev-parse HEAD)"
    st_set sdk_anchor_commit "$_anchor"
    git_push "$WT_SDK" HEAD:feature/openharmony || return 1
    log "sdk anchor $_anchor"
    return 0
}

phase_P3() {
    log "== P3 bundle + sdk anchor (kit #$KIT) =="
    p3_bundle || return $?
    p3_sdk_anchor || return $?
    st_set P3_kit "$KIT"
    log "P3 PASS"
    return 0
}

# ------------------------------------------------------------------------- P4
release_id_of() { # <key>
    for _kv in $RELEASE_IDS; do
        case "$_kv" in
            "$1="*) printf '%s\n' "${_kv#*=}"; return 0 ;;
        esac
    done
    return 1
}

assets_snapshot() { # <rid> <out-json>
    if [ -n "$ASSETS_DIR" ] && [ -f "$ASSETS_DIR/assets-$1.json" ]; then
        cp "$ASSETS_DIR/assets-$1.json" "$2" && return 0
    fi
    api_get "repos/$API_REPO/releases/$1/assets?per_page=100" > "$2" || return 1
    [ -s "$2" ] || return 1
}

p4_plan_file() { # prints "<rid>|<asset-name>|<local-file>" lines
    _dtk="$(release_id_of dtk)"; _latest="$(release_id_of latest)"
    _ver="$(release_id_of versioned)"; _sdkrc="$(release_id_of sdkrc2)"
    _oww="$(src_ow)"
    _bundle="$(st_get bundle_path || true)"
    [ -n "$_bundle" ] || _bundle="$(ls -1 "$_oww"/dist/openharmony-workload-*.tar.gz 2>/dev/null | sort | tail -n 1)"
    if [ -n "$_bundle" ] && [ -f "$_bundle" ]; then
        _ver_name="$(basename "$_bundle")"
    else
        _ver_name="openharmony-workload-$(python3 -c "import json;print(json.load(open('$_oww/manifests/${SDK_BAND:-11.0.100-rc.1}/microsoft.net.sdk.openharmony/WorkloadManifest.json'))['version'])" 2>/dev/null || echo '<version>').tar.gz"
    fi
    _sums="$_oww/dist/SHA256SUMS"
    _merged="$SCRATCH/sdkrc2-sums-expected.txt"
    [ -f "$_merged" ] || _merged="$_sums"
    cat <<EOF
$_ver|$_ver_name|$_bundle
$_ver|SHA256SUMS|$_sums
$_latest|openharmony-workload-latest.tar.gz|$_bundle
$_latest|SHA256SUMS|$_sums
$_latest|device-test-kit.tar.gz|$KIT_OUT
$_latest|device-test-kit.tar.gz.sha256|$KIT_OUT.sha256
$_sdkrc|$_ver_name|$_bundle
$_sdkrc|SHA256SUMS|$_merged
$_dtk|device-test-kit.tar.gz|$KIT_OUT
$_dtk|device-test-kit.tar.gz.sha256|$KIT_OUT.sha256
EOF
}

p4_print_plan() { # reads the plan lines from stdin
    printf '   clobber plan (F4 explicit clobber):\n'
    while IFS='|' read -r _rid _name _file; do
        [ -n "$_rid" ] || continue
        _ls="-"; [ -f "$_file" ] && _ls="$(size_of "$_file") B / $(sha256_of "$_file" | cut -c1-12)"
        _cur="-"
        if [ -n "$ASSETS_DIR" ] && [ -f "$ASSETS_DIR/assets-$_rid.json" ]; then
            _cur="$(python3 -c "
import json,sys
try: d=json.load(open('$ASSETS_DIR/assets-$_rid.json'))
except Exception: d=[]
for a in d:
    if a.get('name')=='$_name':
        print('%s B / %s' % (a.get('size'), (a.get('digest') or 'nodigest')[:19])); break
else: print('-')" 2>/dev/null)"
        fi
        printf '     release %-12s %-46s local %-28s published %s\n' "$_rid" "$_name" "$_ls" "$_cur"
    done
    printf '   notes: a "## Integrity (kit #%s)" block will be appended to the four release bodies\n' "$KIT"
}

p4_confirm() {
    if [ "$YES" = 1 ]; then
        warn "--yes given: skipping the typed clobber confirmation (rehearsal only)"
        return 0
    fi
    printf '   type "clobber kit %s" to proceed (anything else aborts): ' "$KIT"
    IFS= read -r _ans || _ans=""
    if [ "$_ans" != "clobber kit $KIT" ]; then
        err "confirmation declined; no upload performed"
        return 3
    fi
    return 0
}

p4_notes() { # append the Integrity block per release (idempotent)
    _block="$(cat <<EOF

## Integrity (kit #$KIT)

- kit: \`device-test-kit.tar.gz\` $(st_get kit_size_B || echo '?') B / \`$(st_get kit_sha256 || echo '?')\`
- tree: \`$(st_get kit_tree_digest || echo '?')\`
- bundle: $(st_get bundle_size_B || echo '?') B / \`$(st_get bundle_sha256 || echo '?')\`
- pins: ow \`$(st_get pin_ow || echo '?')\` / maui \`$(st_get pin_maui || echo '?')\` / runtime \`$(st_get pin_runtime || echo '?')\`
EOF
)"
    for _rid in $(release_id_of dtk) $(release_id_of latest) $(release_id_of versioned) $(release_id_of sdkrc2); do
        _body="$(api_get "repos/$API_REPO/releases/$_rid" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("body") or "")' 2>/dev/null)"
        case "$_body" in
            *"Integrity (kit #$KIT)"*) log "notes $_rid already carries kit #$KIT"; continue ;;
        esac
        _tok="$(api_token)" || { err "no API token (--token-file/GH_TOKEN)"; return 1; }
        CUT_KIT_TOKEN="$_tok" python3 - "$API_REPO" "$_rid" "$_block" <<'PY' >> "$LOGDIR/p4-notes.log" 2>&1 || { err "notes patch failed for release $_rid"; return 1; }
import json, os, sys, urllib.request
repo, rid, block = sys.argv[1:4]
tok = os.environ.get("CUT_KIT_TOKEN", "")
body = json.dumps({"body": block})
req = urllib.request.Request(f"https://api.github.com/repos/{repo}/releases/{rid}",
                             data=body.encode(), method="PATCH",
                             headers={"Authorization": f"token {tok}", "Content-Type": "application/json"})
print(urllib.request.urlopen(req, timeout=90).status)
PY
        log "notes patched: release $_rid"
    done
}

phase_P4() {
    log "== P4 release: F4 explicit clobber (kit #$KIT) =="
    _planfile="$SCRATCH/p4-upload-plan.txt"
    if [ "$DRY" = 1 ]; then
        p4_plan_file | p4_print_plan
        printf '   [dry-run] confirmation gate: "clobber kit %s" required before any upload\n' "$KIT"
        printf '   [dry-run] upload via --upload-hook <script> (receives the plan file) or the repo uploader\n'
        printf '   [dry-run] by-id re-check + zero-change list after the upload; notes x4\n'
        return 0
    fi
    require_execute_iknow P4 || return $?
    mkdir -p "$SCRATCH" "$LOGDIR"
    p4_plan_file > "$_planfile"
    [ -s "$_planfile" ] || { err "empty upload plan (bundle/kit artifacts missing)"; return 4; }
    p4_print_plan < "$_planfile"
    p4_confirm || return 3
    # before snapshots (read-only)
    for _rid in $(release_id_of dtk) $(release_id_of latest) $(release_id_of versioned) $(release_id_of sdkrc2); do
        assets_snapshot "$_rid" "$SCRATCH/assets-$_rid-before.json" || \
            { err "cannot snapshot release $_rid (token/API?)"; return 1; }
    done
    # upload
    if [ -n "$UPLOAD_HOOK" ] && [ -f "$UPLOAD_HOOK" ]; then
        sh "$UPLOAD_HOOK" "$_planfile" >> "$LOGDIR/p4-upload.log" 2>&1 || \
            { err "upload hook failed (log $LOGDIR/p4-upload.log)"; return 1; }
    elif [ -x "$OW_REPO/scripts/publish-workload-release.sh" ]; then
        _args="--bundle-sha256 $(st_get bundle_sha256 || true) --kit-sha256 $(st_get kit_sha256 || true) --kit-tree-digest $(st_get kit_tree_digest || true) --kit $KIT_OUT --allow-clobber-mismatch"
        [ -n "$SDK_RELEASE_TAG" ] && _args="$_args --also-sdk-release $SDK_RELEASE_TAG"
        # shellcheck disable=SC2086
        sh "$OW_REPO/scripts/publish-workload-release.sh" $_args >> "$LOGDIR/p4-upload.log" 2>&1 || \
            { err "repo uploader failed (log $LOGDIR/p4-upload.log)"; return 1; }
    else
        err "no uploader: pass --upload-hook <script> (the #49..#53 scratch curl driver shape) or install gh+repo scripts"
        return 1
    fi
    # after snapshots + zero-change/by-id verification
    for _rid in $(release_id_of dtk) $(release_id_of latest) $(release_id_of versioned) $(release_id_of sdkrc2); do
        assets_snapshot "$_rid" "$SCRATCH/assets-$_rid-after.json" || \
            { err "cannot snapshot release $_rid after upload"; return 1; }
    done
    python3 - "$SCRATCH" "$KIT_OUT" "$KIT_OUT.sha256" "$(st_get bundle_path || true)" \
        "$(src_ow)/dist/SHA256SUMS" "$(release_id_of dtk) $(release_id_of latest) $(release_id_of versioned) $(release_id_of sdkrc2)" \
        > "$LOGDIR/p4-verify.log" 2>&1 <<'PY' || { err "by-id/zero-change verification failed (log $LOGDIR/p4-verify.log)"; return 1; }
import hashlib, json, os, sys
scratch, kit, side, bundle, sums_file, rids = sys.argv[1:7]
rids = rids.split()
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()
local = {"device-test-kit.tar.gz": kit, "device-test-kit.tar.gz.sha256": side,
         "openharmony-workload-1.0.0-preview.28.tar.gz": bundle,
         "openharmony-workload-latest.tar.gz": bundle}
targets = set(local) | {"SHA256SUMS"}
fails = 0
for rid in rids:
    before = {a["name"]: a for a in json.load(open(f"{scratch}/assets-{rid}-before.json"))}
    after = {a["name"]: a for a in json.load(open(f"{scratch}/assets-{rid}-after.json"))}
    print(f"== release {rid}")
    for name in sorted(set(before) | set(after)):
        b, a = before.get(name), after.get(name)
        if b is None: print(f"   added    {name}"); continue
        if a is None: print(f"   removed  {name}"); continue
        changed = (b.get("digest") or "", b["size"]) != (a.get("digest") or "", a["size"])
        if name in targets:
            if not changed and name != "SHA256SUMS":
                print(f"   UNCHANGED target {name}"); fails += 1
                continue
            if name == "SHA256SUMS":
                print(f"   sums     {name}: {a['size']} B / {(a.get('digest') or '')[:16]}")
                continue
            lf = local.get(name)
            if lf and os.path.exists(lf):
                ls, lh = os.path.getsize(lf), sha(lf)
                ok = a["size"] == ls and (a.get("digest") or "") == f"sha256:{lh}"
                print(f"   {'OK ' if ok else 'MISMATCH'} {name}: remote {a['size']}/{ (a.get('digest') or '')[:16]} local {ls}/{lh[:16]}")
                if not ok: fails += 1
        else:
            print(f"   zero-change {'OK' if not changed else 'VIOLATED'} {name} (id {b.get('id')}->{a.get('id')})")
            if changed: fails += 1
print("FAILS:", fails)
sys.exit(1 if fails else 0)
PY
    log "notes (x4)"
    CUT_KIT_TOKEN="$(api_token)" p4_notes || warn "notes patch incomplete (see $LOGDIR/p4-notes.log)"
    st_set P4_kit "$KIT"
    log "P4 PASS"
    return 0
}

# ------------------------------------------------------------------------- P5
p5_values() {
    if [ "$DRY" = 1 ]; then
        printf '   [dry-run] write %s/RELEASE-VALUES.txt + release-values.env (kit/bundle/sums/pins)\n' "$SCRATCH"
        return 0
    fi
    mkdir -p "$SCRATCH"
    _out="$SCRATCH/RELEASE-VALUES.txt"
    {
        printf 'kit=%s\n' "$KIT"
        printf 'date=%s\n' "$(date '+%F %T %z')"
        printf 'kit_size_B=%s\n' "$(st_get kit_size_B || echo '')"
        printf 'kit_sha256=%s\n' "$(st_get kit_sha256 || echo '')"
        printf 'kit_tree_digest=%s\n' "$(st_get kit_tree_digest || echo '')"
        printf 'kit_sidecar_sha256=%s\n' "$(st_get kit_sidecar_sha256 || echo '')"
        printf 'bundle_path=%s\n' "$(st_get bundle_path || echo '')"
        printf 'bundle_size_B=%s\n' "$(st_get bundle_size_B || echo '')"
        printf 'bundle_sha256=%s\n' "$(st_get bundle_sha256 || echo '')"
        printf 'bundle_sums_sha256=%s\n' "$(st_get bundle_sums_sha256 || echo '')"
        printf 'pin_ow=%s\n' "$(st_get pin_ow || echo '')"
        printf 'pin_maui=%s\n' "$(st_get pin_maui || echo '')"
        printf 'pin_runtime=%s\n' "$(st_get pin_runtime || echo '')"
        printf 'sdk_anchor_commit=%s\n' "$(st_get sdk_anchor_commit || echo '')"
    } | tee "$_out" | grep -E '^(kit|bundle|pin_|sdk_)' | sed 's/^/   /'
    cp "$_out" "$SCRATCH/release-values.env"
    return 0
}

p5_hook() { # <label> <hook>
    _label="$1"; _hook="$2"
    if [ -n "$_hook" ] && [ -f "$_hook" ]; then
        if [ "$DRY" = 1 ]; then
            printf '   [dry-run] sh %s --kit %s --scratch %s\n' "$_hook" "$KIT" "$SCRATCH"
            return 0
        fi
        sh "$_hook" --kit "$KIT" --scratch "$SCRATCH" >> "$LOGDIR/p5-$_label.log" 2>&1 || \
            { err "$_label hook failed (log $LOGDIR/p5-$_label.log)"; return 1; }
        log "$_label hook OK"
        return 0
    fi
    if [ "$DRY" = 1 ]; then
        printf '   [dry-run] %s hook not configured (pass --%s-hook); per-round scratch script expected\n' "$_label" "$_label"
        return 0
    fi
    err "$_label hook required for execute (pass --$_label-hook); the #49..#53 presign/manifest scripts live in the round scratch"
    return 1
}

phase_P5() {
    log "== P5 VALUES / presign / manifest / push (kit #$KIT) =="
    if [ "$DRY" = 1 ]; then
        p5_values
        p5_hook presign "$PRESIGN_HOOK"
        p5_hook manifest "$MANIFEST_HOOK"
        printf '   [dry-run] push of the sdk anchor commit is done in P3 (git_push, normal push first)\n'
        return 0
    fi
    require_execute_iknow P5 || return $?
    mkdir -p "$LOGDIR"
    p5_values || return 1
    p5_hook presign "$PRESIGN_HOOK" || return 1
    p5_hook manifest "$MANIFEST_HOOK" || return 1
    st_set P5_kit "$KIT"
    log "P5 PASS"
    return 0
}

# ------------------------------------------------------------------------- P6
phase_P6() {
    log "== P6 CI re-check (kit #$KIT) =="
    _owpin="$(st_get pin_ow || pin_ow)"
    _anchor="$(st_get sdk_anchor_commit || echo '')"
    _owrepo="$(git -C "$OW_REPO" remote get-url origin 2>/dev/null | sed -e 's#.*github.com[/:]##' -e 's#\.git$##')"
    _owrepo="${_owrepo:-springmin/ohos-workload}"
    if [ "$DRY" = 1 ]; then
        printf '   [dry-run] curl api.github.com/repos/%s/actions/runs?head_sha=%s (five workflows must be success)\n' "$_owrepo" "$_owpin"
        printf '   [dry-run] curl api.github.com/repos/%s/actions/runs?head_sha=%s (sdk run must be success)\n' "$API_REPO" "${_anchor:-<anchor>}"
        return 0
    fi
    require_execute_iknow P6 || return $?
    mkdir -p "$LOGDIR"
    _runs="$(api_get "repos/$_owrepo/actions/runs?head_sha=$_owpin&per_page=50")" || \
        { err "cannot query CI runs for $_owrepo@$_owpin"; return 1; }
    printf '%s\n' "$_runs" > "$LOGDIR/p6-ow-runs.json"
    _f=0
    for _wf in interaction pixel host-export ridgraph markdownlint; do
        _n="$(printf '%s\n' "$_runs" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(sum(1 for r in d.get('workflow_runs',[]) if '$_wf' in (r.get('name','')+r.get('path','')) and r.get('conclusion')=='success'))" 2>/dev/null || echo 0)"
        if [ "${_n:-0}" -gt 0 ] 2>/dev/null; then
            printf '   ci %-16s PASS (%s success)\n' "$_wf" "$_n"
        else
            printf '   ci %-16s FAIL (no success run for %s)\n' "$_wf" "$_owpin" >&2
            _f=$((_f + 1))
        fi
    done
    if [ -n "$_anchor" ]; then
        _sdkruns="$(api_get "repos/$API_REPO/actions/runs?head_sha=$_anchor&per_page=20")" || \
            { err "cannot query sdk CI runs for $_anchor"; return 1; }
        _n="$(printf '%s\n' "$_sdkruns" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(sum(1 for r in d.get('workflow_runs',[]) if r.get('conclusion')=='success'))" 2>/dev/null || echo 0)"
        if [ "${_n:-0}" -gt 0 ] 2>/dev/null; then
            printf '   ci sdk-ohos       PASS (%s success @ %s)\n' "$_n" "$(printf '%s' "$_anchor" | cut -c1-10)"
        else
            printf '   ci sdk-ohos       FAIL (no success run for %s)\n' "$_anchor" >&2
            _f=$((_f + 1))
        fi
    else
        printf '   ci sdk-ohos       SKIP (no anchor commit recorded)\n'
    fi
    [ "$_f" = 0 ] || { err "CI re-check failed ($_f workflow(s))"; return 1; }
    st_set P6_kit "$KIT"
    log "P6 PASS"
    return 0
}

# ------------------------------------------------------------------------- dispatch
phase_rc_key() { printf '%s_rc' "$1"; }

run_phase() { # <phase>
    _phase="$1"
    _phase_key="$(phase_rc_key "$_phase")"
    _phase_done="$(st_get "$_phase_key" || true)"
    if [ "$FORCE" != 1 ] && [ "$_phase_done" = 0 ]; then
        log "skip $_phase (already rc=0 in $STATE)"
        return 0
    fi
    case "$_phase" in
        P0) phase_P0 ;;
        P1) phase_P1 ;;
        P2) phase_P2 ;;
        P3) phase_P3 ;;
        P4) phase_P4 ;;
        P5) phase_P5 ;;
        P6) phase_P6 ;;
        *) err "unknown phase: $_phase"; return 2 ;;
    esac
    _rc=$?
    st_set "$_phase_key" "$_rc"
    st_set "${_phase}_ts" "$(date '+%F %T')"
    case "$_rc" in
        0) : ;;
        *) FAILED_PHASES=$((FAILED_PHASES + 1)) ;;
    esac
    return "$_rc"
}

phase_selected() { # <phase>
    case " $PHASE_SEL " in
        *" all "*) return 0 ;;
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

[ -n "$PHASE_SEL" ] || PHASE_SEL=" all"
[ "$DRY" = 1 ] && log "DRY RUN (default; pass --execute to write). kit #$KIT scratch=$SCRATCH" || \
    log "EXECUTE mode. kit #$KIT scratch=$SCRATCH"

_last_rc=0
for _phase in P0 P1 P2 P3 P4 P5 P6; do
    phase_selected "$_phase" || continue
    run_phase "$_phase"
    _rc=$?
    case "$_rc" in
        0) : ;;
        4)
            warn "$_phase skipped: prerequisite artifact missing"
            _last_rc=4
            break
            ;;
        *)
            _last_rc="$_rc"
            err "$_phase failed (rc=$_rc); stopping (files/state kept for resume)"
            break
            ;;
    esac
done

if [ "$_last_rc" = 0 ]; then
    log "cut-kit: requested phases done (kit #$KIT, dry=$DRY)"
    exit 0
fi
exit "$_last_rc"
