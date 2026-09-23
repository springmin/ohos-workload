#!/bin/sh
# One-command release wrapper for the OpenHarmony platform workload (ohos-workload): the
# proven manual release chain, in order. DRY-RUN BY DEFAULT.
#   1 pack consistency: repo packs/Microsoft.OpenHarmony.Sdk/<ver> vs the installed
#     ${DOTNET_ROOT:-~/.dotnet}/packs/... copy, for the three files a stale install breaks
#     (templates/ets/modules.ui.abc - rebuilt by build-arkts-shell.sh and synced into the
#     installed pack; modules.abc is the frozen default stub - hosts/arm64-v8a/
#     libopenharmonyhost.so, targets/OpenHarmony.Hap.targets). Reports MATCH / NOTE-DIFF; a
#     diff is a warning, never an abort (step 6 builds the kit against the installed copy, so
#     a diff deserves a look).
#   2 pack-workload-bundle.sh -> dist/openharmony-workload-<ver>.tar.gz
#   3 sha256 of that bundle -> BUNDLE_SHA (the independent digest gate)
#   4 release-checksums.sh -> dist/SHA256SUMS
#   5 publish-workload-release.sh --bundle-sha256 <hash> --skip-kit --also-sdk-release <tag>
#     (versioned workload-<ver>, rolling workload-latest, SDK release attachment). The clobber
#     switch stays opt-in (ALLOW_CLOBBER_MISMATCH=1 / --allow-clobber-mismatch): rolling tags
#     may legitimately differ, the versioned release is meant to be immutable, so the wrapper
#     does not weaken the digest guard by default.
#   6 make-device-test-kit.sh --publish. If that fails after (re)building the kit tarball,
#     the fallback uploads the kit and a freshly written <kit>.tar.gz.sha256 sidecar with
#     `gh release upload --clobber` to device-test-kit and workload-latest (what the manual
#     chain did by hand); a tarball unchanged since before step 6 is refused as a stale kit.
#   7 preflight.sh (skip with --skip-preflight)
#   8 read-only verification printout: local bundle/kit hashes, the kit tree digest
#     (verify-kit.sh --tree-digest, when the kit directory is present) and the GitHub API
#     asset digests for device-test-kit, workload-latest, workload-<ver> and the SDK release.
# --publish executes the chain; without it every mutating command is printed with a [dry-run]
# prefix and nothing is built, written or uploaded. Steps 1 and 8 are read-only and run in
# both modes.
# Failure handling: every step logs its exact command, the wrapper captures the real exit code
# (no pipelines that could mask it) and aborts with exit 1; bad usage exits 2.
# Usage: scripts/release-all.sh [--publish] [--skip-preflight] [--sdk-release <tag>]
#                              [--kit-dir <dir>] [--out <tar.gz>] [--allow-clobber-mismatch] [-h]
#   --sdk-release default v11.0.100-rc.1.26451.109-openharmony (empty = do not attach);
#   --kit-dir default $DEVICE_TEST_KIT_DIR or the approved opencode tmp dir.
# Env: SDK_BAND (default 11.0.100-rc.1), REPO (default springmin/sdk-ohos), DOTNET_ROOT
#      (default $HOME/.dotnet), DEVICE_TEST_KIT_DIR, GH (default gh),
#      ALLOW_CLOBBER_MISMATCH (default 0; see --allow-clobber-mismatch).
set -u

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { warn "$*"; exit 1; }

W="$(cd "$(dirname "$0")/.." && pwd)"
BAND="${SDK_BAND:-11.0.100-rc.1}"
REPO="${REPO:-springmin/sdk-ohos}"
DOTNET_ROOT_DIR="${DOTNET_ROOT:-${HOME:-}/.dotnet}"
DEFAULT_SDK_RELEASE="v11.0.100-rc.1.26451.109-openharmony"
DEFAULT_KIT_DIR=/data/storage/el2/base/tmp/opencode/device-test-kit
GH="${GH:-gh}"

PUBLISH=0
SKIP_PREFLIGHT=0
SDK_RELEASE="$DEFAULT_SDK_RELEASE"
KIT_DIR=""
KIT_OUT_ARG=""
ALLOW_CLOBBER_MISMATCH="${ALLOW_CLOBBER_MISMATCH:-0}"

usage() {
    cat <<EOF
usage: $0 [--publish] [--skip-preflight] [--sdk-release <tag>]
          [--kit-dir <dir>] [--out <tar.gz>] [-h]

One-command release wrapper around the proven manual chain (pack bundle -> bundle sha256 ->
release checksums -> publish versioned/rolling/SDK release -> device-test kit -> preflight ->
read-only verification). DRY-RUN BY DEFAULT: every command is printed; nothing is built,
written or uploaded unless --publish is given.

  --publish            execute the chain (uploads); without it: dry-run
  --skip-preflight     skip step 7 (scripts/preflight.sh)
  --sdk-release <tag>  SDK release for --also-sdk-release (default:
                       $DEFAULT_SDK_RELEASE)
  --kit-dir <dir>      passthrough to make-device-test-kit.sh
  --out <tar.gz>       passthrough to make-device-test-kit.sh
  --allow-clobber-mismatch
                       forward publish-workload-release.sh's clobber override (same as
                       ALLOW_CLOBBER_MISMATCH=1): overwrite an already-published asset
                       whose sha256 differs instead of refusing the release
  -h, --help           this help

Env: SDK_BAND, REPO, DOTNET_ROOT, DEVICE_TEST_KIT_DIR, GH, ALLOW_CLOBBER_MISMATCH (0/1).
Steps 1 and 8 are read-only and also run in dry-run; every step aborts (exit 1) on a
non-zero exit code, bad usage exits 2.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --publish)        PUBLISH=1 ;;
        --skip-preflight) SKIP_PREFLIGHT=1 ;;
        --sdk-release)
            shift
            [ $# -gt 0 ] || { warn "--sdk-release needs a tag"; usage >&2; exit 2; }
            SDK_RELEASE="$1" ;;
        --kit-dir)
            shift
            [ $# -gt 0 ] || { warn "--kit-dir needs a directory"; usage >&2; exit 2; }
            KIT_DIR="$1" ;;
        --out)
            shift
            [ $# -gt 0 ] || { warn "--out needs a tarball path"; usage >&2; exit 2; }
            KIT_OUT_ARG="$1" ;;
        --allow-clobber-mismatch) ALLOW_CLOBBER_MISMATCH=1 ;;
        -h|--help) usage; exit 0 ;;
        *) warn "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
    shift
done

# sha256 of a file (sha256sum, or a python fallback for hosts without coreutils). The
# capture keeps the real exit code (no pipeline), so a caller can check it when it matters.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        _sha_out="$(sha256sum "$1")" || return 1
    else
        _sha_out="$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1")" || return 1
    fi
    printf '%s\n' "${_sha_out%% *}"
}

# Run a step command: in dry-run it is printed, never executed; in publish mode it runs and
# the caller reads the real exit code straight after (no pipeline, rc never masked).
run_cmd() {
    log "cmd: $*"
    if [ "$PUBLISH" = 1 ]; then
        "$@"
    else
        printf '   [dry-run] %s\n' "$*"
        return 0
    fi
}

run_or_die() {
    _desc="$1"; shift
    run_cmd "$@"
    RC=$?
    [ "$RC" -eq 0 ] || die "$_desc: failed (rc=$RC); release aborted"
}

MANIFEST="$W/manifests/$BAND/microsoft.net.sdk.openharmony/WorkloadManifest.json"
[ -f "$MANIFEST" ] || die "workload manifest not found: $MANIFEST"
VER="$(python3 -c "import json;print(json.load(open('$MANIFEST'))['version'])")"
SDK_PACK_VER="$(python3 -c "import json;print(json.load(open('$MANIFEST'))['packs']['Microsoft.OpenHarmony.Sdk']['version'])")"

BUNDLE="$W/dist/openharmony-workload-$VER.tar.gz"
VERSIONED_TAG="workload-$VER"
KIT_TAG="device-test-kit"
LATEST_TAG="workload-latest"
EFF_KIT_DIR="${KIT_DIR:-${DEVICE_TEST_KIT_DIR:-$DEFAULT_KIT_DIR}}"
if [ -n "$KIT_OUT_ARG" ]; then
    KIT_OUT="$KIT_OUT_ARG"
else
    KIT_OUT="$(dirname "$EFF_KIT_DIR")/$(basename "$EFF_KIT_DIR").tar.gz"
fi
KIT_NAME="$(basename "$KIT_OUT")"
KIT_SUMS="$KIT_OUT.sha256"

STEP=0
TOTAL=8
step_begin() { STEP=$((STEP + 1)); log "== step $STEP/$TOTAL: $1 =="; }

# Scratch space for captured stdout/stderr (never used to buffer artifact contents).
TMP="$(mktemp -d 2>/dev/null || true)"
if [ -z "$TMP" ]; then
    TMP="/data/storage/el2/base/tmp/opencode/release-all.$$"
    mkdir -p "$TMP" || die "cannot create scratch dir: $TMP"
fi
trap 'rm -rf "$TMP"' 0 1 2 15

log "ohos-workload release-all"
log "repo:    $W"
log "version: $VER (band $BAND, sdk pack $SDK_PACK_VER)"
log "tags:    versioned=$VERSIONED_TAG rolling=$LATEST_TAG kit=$KIT_TAG sdk=${SDK_RELEASE:-<none>}"
log "bundle:  $BUNDLE"
log "kit:     $KIT_OUT (dir $EFF_KIT_DIR)"
if [ "$PUBLISH" = 1 ]; then
    log "mode:    PUBLISH (steps run for real and upload)"
else
    log "mode:    DRY-RUN (pass --publish to execute; steps 1 and 8 are read-only and run now)"
fi

# ------------------------------------------------------------------ step 1: consistency
step_begin "pack consistency (repo vs installed $DOTNET_ROOT_DIR)"
REPO_PACK="$W/packs/Microsoft.OpenHarmony.Sdk/$SDK_PACK_VER"
INST_ROOT="$DOTNET_ROOT_DIR/packs/Microsoft.OpenHarmony.Sdk"
INST_PACK=""
[ -d "$REPO_PACK" ] || die "repo pack dir not found: $REPO_PACK"
log "repo pack:      $REPO_PACK"
if [ -d "$INST_ROOT" ]; then
    if [ -d "$INST_ROOT/$SDK_PACK_VER" ]; then
        INST_PACK="$INST_ROOT/$SDK_PACK_VER"
    else
        INST_PACK="$(LC_ALL=C ls -dt "$INST_ROOT"/*/ 2>/dev/null | head -n1)"
        [ -n "$INST_PACK" ] || INST_PACK=""
        [ -z "$INST_PACK" ] || warn "installed Sdk pack $SDK_PACK_VER not found; comparing against $(basename "$INST_PACK")"
    fi
else
    warn "no installed pack root: $INST_ROOT"
fi
if [ -n "$INST_PACK" ]; then
    log "installed pack: $INST_PACK"
    [ "$(basename "$INST_PACK")" = "$SDK_PACK_VER" ] || \
        warn "installed version $(basename "$INST_PACK") != manifest/repo $SDK_PACK_VER"
else
    log "installed pack: <not found> (NOTE-DIFF for every file)"
fi

DIFFS=0
for _item in "abc:templates/ets/modules.ui.abc" \
             "host:hosts/arm64-v8a/libopenharmonyhost.so" \
             "targets:targets/OpenHarmony.Hap.targets"; do
    _label="${_item%%:*}"; _rel="${_item#*:}"
    [ -f "$REPO_PACK/$_rel" ] || die "repo pack file missing: $REPO_PACK/$_rel"
    _repo_sha="$(sha256_of "$REPO_PACK/$_rel")"
    if [ -z "$INST_PACK" ] || [ ! -f "$INST_PACK/$_rel" ]; then
        printf '   %-8s %-9s repo=%s installed=<missing>\n' "$_label" "NOTE-DIFF" "$_repo_sha"
        DIFFS=$((DIFFS + 1))
    else
        _inst_sha="$(sha256_of "$INST_PACK/$_rel")"
        if [ "$_repo_sha" = "$_inst_sha" ]; then
            printf '   %-8s %-9s %s\n' "$_label" "MATCH" "$_repo_sha"
        else
            printf '   %-8s %-9s repo=%s installed=%s\n' "$_label" "NOTE-DIFF" "$_repo_sha" "$_inst_sha"
            DIFFS=$((DIFFS + 1))
        fi
    fi
done
log "step 1: $((3 - DIFFS))/3 MATCH, $DIFFS NOTE-DIFF"
if [ "$DIFFS" -gt 0 ]; then
    warn "installed pack copy differs from the repo pack; step 6 builds the kit against the installed"
    warn "copy (MSBuild resolves ~/.dotnet/packs), so sync the three files (or reinstall the workload)"
    warn "before --publish when the difference is not intended"
fi

# ------------------------------------------------------------------ step 2: pack
step_begin "pack the workload bundle (scripts/pack-workload-bundle.sh)"
run_or_die "step 2: pack-workload-bundle.sh" sh "$W/scripts/pack-workload-bundle.sh"

# ------------------------------------------------------------------ step 3: digest
step_begin "compute the bundle sha256"
BUNDLE_SHA=""
if [ -f "$BUNDLE" ]; then
    BUNDLE_SHA="$(sha256_of "$BUNDLE")"
    log "bundle sha256: $BUNDLE_SHA"
    if [ "$PUBLISH" = 0 ]; then
        printf '   [dry-run] (recomputed after step 2 in a real run; this is the current file)\n'
    fi
else
    if [ "$PUBLISH" = 1 ]; then
        die "step 3: bundle not found after packing: $BUNDLE"
    fi
    warn "bundle not present yet: $BUNDLE (hash is computed after step 2 in a real run)"
fi
if [ -n "$BUNDLE_SHA" ]; then BUNDLE_SHA_ARG="$BUNDLE_SHA"; else BUNDLE_SHA_ARG='<bundle-sha256-after-step-2>'; fi

# ------------------------------------------------------------------ step 4: checksums
step_begin "write dist/SHA256SUMS (scripts/release-checksums.sh)"
run_or_die "step 4: release-checksums.sh" sh "$W/scripts/release-checksums.sh"

# ------------------------------------------------------------------ step 5: publish
step_begin "publish the versioned + rolling releases (scripts/publish-workload-release.sh)"
set -- --repo "$REPO" --bundle-sha256 "$BUNDLE_SHA_ARG" --skip-kit
# C4: publish-workload-release.sh refuses to clobber an already-published asset whose
# sha256 differs from this run's bundle digest. That gate is intentional for the versioned
# workload-<ver> release (immutable); refreshing the rolling tags may legitimately need the
# override, which is therefore forwarded only when explicitly requested.
if [ "$ALLOW_CLOBBER_MISMATCH" = 1 ]; then
    warn "ALLOW_CLOBBER_MISMATCH=1: forwarding --allow-clobber-mismatch (an existing asset with a different digest may be overwritten)"
    set -- "$@" --allow-clobber-mismatch
fi
if [ -n "$SDK_RELEASE" ]; then
    set -- "$@" --also-sdk-release "$SDK_RELEASE"
fi
run_or_die "step 5: publish-workload-release.sh" sh "$W/scripts/publish-workload-release.sh" "$@"

# ------------------------------------------------------------------ step 6: device kit
step_begin "build + publish the device-test kit (scripts/make-device-test-kit.sh --publish)"
set -- --publish
if [ -n "$KIT_DIR" ]; then set -- "$@" --kit-dir "$KIT_DIR"; fi
if [ -n "$KIT_OUT_ARG" ]; then set -- "$@" --out "$KIT_OUT_ARG"; fi

# Stale-kit guard: remember what is on disk before the build, so the fallback can refuse to
# upload a tarball the failed run never replaced.
KIT_PRE_SHA=""
if [ "$PUBLISH" = 1 ] && [ -f "$KIT_OUT" ]; then KIT_PRE_SHA="$(sha256_of "$KIT_OUT")"; fi

run_cmd sh "$W/scripts/make-device-test-kit.sh" "$@"
RC=$?
if [ "$PUBLISH" = 1 ] && [ "$RC" -eq 0 ]; then
    log "step 6: kit published through make-device-test-kit.sh"
elif [ "$PUBLISH" = 0 ]; then
    printf '   [dry-run] fallback (only if the command above fails in a real run):\n'
    printf '   [dry-run] (cd %s && sha256sum %s > %s)\n' "$(dirname "$KIT_OUT")" "$KIT_NAME" "$KIT_NAME.sha256"
    printf '   [dry-run] %s release upload %s %s %s --repo %s --clobber\n' "$GH" "$KIT_TAG" "$KIT_OUT" "$KIT_SUMS" "$REPO"
    printf '   [dry-run] %s release upload %s %s %s --repo %s --clobber\n' "$GH" "$LATEST_TAG" "$KIT_OUT" "$KIT_SUMS" "$REPO"
    printf '   [dry-run] (refused when the tarball is unchanged from before step 6: a stale kit)\n'
else
    warn "step 6: make-device-test-kit.sh --publish failed (rc=$RC); falling back to a direct upload"
    [ -f "$KIT_OUT" ] || die "step 6 fallback: kit tarball not found: $KIT_OUT"
    KIT_NOW_SHA="$(sha256_of "$KIT_OUT")"
    if [ -n "$KIT_PRE_SHA" ] && [ "$KIT_NOW_SHA" = "$KIT_PRE_SHA" ]; then
        die "step 6 fallback: $KIT_OUT is unchanged from before step 6 (the failed run did not rebuild it); refusing to upload a stale kit"
    fi
    ( cd "$(dirname "$KIT_OUT")" && sha256sum "$KIT_NAME" > "$KIT_NAME.sha256" )
    RC=$?
    [ "$RC" -eq 0 ] || die "step 6 fallback: could not write the sidecar $KIT_SUMS (rc=$RC)"
    log "step 6 fallback: sidecar $(cut -d' ' -f1 "$KIT_SUMS")  $KIT_NAME.sha256"
    "$GH" release upload "$KIT_TAG" "$KIT_OUT" "$KIT_SUMS" --repo "$REPO" --clobber
    RC=$?
    [ "$RC" -eq 0 ] || die "step 6 fallback: gh release upload $KIT_TAG failed (rc=$RC)"
    "$GH" release upload "$LATEST_TAG" "$KIT_OUT" "$KIT_SUMS" --repo "$REPO" --clobber
    RC=$?
    [ "$RC" -eq 0 ] || die "step 6 fallback: gh release upload $LATEST_TAG failed (rc=$RC)"
    log "step 6 fallback: kit uploaded to $KIT_TAG and $LATEST_TAG"
fi

# ------------------------------------------------------------------ step 7: preflight
step_begin "preflight (scripts/preflight.sh)"
if [ "$SKIP_PREFLIGHT" = 1 ]; then
    log "step 7: skipped (--skip-preflight)"
elif [ ! -f "$W/scripts/preflight.sh" ]; then
    die "step 7: preflight.sh not found: $W/scripts/preflight.sh"
else
    run_or_die "step 7: preflight.sh" sh "$W/scripts/preflight.sh"
fi

# ------------------------------------------------------------------ step 8: verification
step_begin "verification (read-only)"

# Local artifacts.
VERIFY_BUNDLE_SHA=""
VERIFY_KIT_SHA=""
if [ -f "$BUNDLE" ]; then
    VERIFY_BUNDLE_SHA="$(sha256_of "$BUNDLE")"
    log "bundle: $(basename "$BUNDLE") sha256=$VERIFY_BUNDLE_SHA"
else
    warn "bundle missing locally: $BUNDLE"
fi
if [ -f "$KIT_OUT" ]; then
    VERIFY_KIT_SHA="$(sha256_of "$KIT_OUT")"
    log "kit:    $(basename "$KIT_OUT") sha256=$VERIFY_KIT_SHA"
else
    warn "kit tarball missing locally: $KIT_OUT"
fi
# The published sidecar is written by publish-workload-release.sh into .feed/; the step 6
# fallback writes it next to the tarball. Prefer whichever exists.
KIT_SUMS_LOCAL=""
if [ -f "$W/.feed/$KIT_NAME.sha256" ]; then
    KIT_SUMS_LOCAL="$W/.feed/$KIT_NAME.sha256"
elif [ -f "$KIT_OUT.sha256" ]; then
    KIT_SUMS_LOCAL="$KIT_OUT.sha256"
fi
if [ -n "$KIT_SUMS_LOCAL" ]; then
    log "kit sidecar: $(cat "$KIT_SUMS_LOCAL")"
else
    warn "kit sidecar missing (looked at .feed/$KIT_NAME.sha256 and $KIT_OUT.sha256)"
fi
if [ -f "$W/dist/SHA256SUMS" ]; then
    log "sums:   dist/SHA256SUMS sha256=$(sha256_of "$W/dist/SHA256SUMS")"
    sed 's/^/        /' "$W/dist/SHA256SUMS"
fi

# Extracted-kit tree digest, computed by the shipped verifier (same code the tester runs).
if [ -f "$EFF_KIT_DIR/SHA256SUMS" ]; then
    sh "$W/scripts/verify-kit.sh" --tree-digest "$EFF_KIT_DIR" > "$TMP/verify.out" 2> "$TMP/verify.err"
    RC=$?
    if [ "$RC" -eq 0 ]; then
        _tree="$(sed -n 's/^.*tree sha256=//p' "$TMP/verify.out" | head -n1)"
        log "kit tree digest: ${_tree:-<not reported>}"
    else
        warn "kit tree digest unavailable (verify-kit.sh rc=$RC): $(head -n1 "$TMP/verify.err")"
    fi
else
    warn "kit tree digest skipped: $EFF_KIT_DIR/SHA256SUMS not found"
fi

# GitHub API asset digests (read-only). Local files are compared where a name is known.
if ! command -v "$GH" >/dev/null 2>&1; then
    warn "gh not found ($GH); remote digests unavailable"
else
    BUNDLE_NAME="$(basename "$BUNDLE")"
    KIT_NAME="$(basename "$KIT_OUT")"
    KIT_SUMS_NAME="$KIT_NAME.sha256"
    LOCAL_SUMS_SHA=""
    if [ -f "$W/dist/SHA256SUMS" ]; then LOCAL_SUMS_SHA="$(sha256_of "$W/dist/SHA256SUMS")"; fi

    # print the assets of one release; "current" limits the listing to the bundle this run
    # releases plus SHA256SUMS (the SDK release also carries the whole historical bundle
    # series and the SDK tarball/nupkgs, which would bury the two assets that matter).
    report_release() {
        _tag="$1"; _filter="$2"
        "$GH" api "repos/$REPO/releases/tags/$_tag" \
            --jq '.assets[] | "\(.name)\t\(.digest // "no-digest")"' > "$TMP/gh.out" 2> "$TMP/gh.err"
        _rc=$?
        if [ "$_rc" -ne 0 ]; then
            warn "gh api $_tag: unavailable (rc=$_rc) $(head -n1 "$TMP/gh.err")"
            return 0
        fi
        log "release $_tag:"
        _shown=0
        _hidden=0
        while IFS='	' read -r _name _digest; do
            [ -n "$_name" ] || continue
            if [ "$_filter" = "current" ]; then
                case "$_name" in
                    "$BUNDLE_NAME"|SHA256SUMS) : ;;
                    *) _hidden=$((_hidden + 1)); continue ;;
                esac
            fi
            _local=""
            case "$_name" in
                "$BUNDLE_NAME"|"openharmony-workload-latest.tar.gz") _local="$VERIFY_BUNDLE_SHA" ;;
                "$KIT_NAME") _local="$VERIFY_KIT_SHA" ;;
                "$KIT_SUMS_NAME") if [ -n "$KIT_SUMS_LOCAL" ]; then _local="$(sha256_of "$KIT_SUMS_LOCAL")"; fi ;;
                "SHA256SUMS") _local="$LOCAL_SUMS_SHA" ;;
            esac
            _remote="${_digest#sha256:}"
            _cmp=""
            if [ -n "$_local" ] && [ -n "$_remote" ]; then
                if [ "$_local" = "$_remote" ]; then
                    _cmp="  local=MATCH"
                    VERIFY_MATCH=$((VERIFY_MATCH + 1))
                else
                    _cmp="  local=DIFF"
                    VERIFY_DIFF=$((VERIFY_DIFF + 1))
                fi
            fi
            printf '   %-48s %s%s\n' "$_name" "$_digest" "$_cmp"
            _shown=$((_shown + 1))
        done < "$TMP/gh.out"
        [ "$_hidden" -eq 0 ] || printf '   (%s other assets not shown)\n' "$_hidden"
        [ "$_shown" -gt 0 ] || printf '   (no matching assets)\n'
    }

    VERIFY_MATCH=0
    VERIFY_DIFF=0
    report_release "$KIT_TAG" ""
    report_release "$LATEST_TAG" ""
    report_release "$VERSIONED_TAG" ""
    if [ -n "$SDK_RELEASE" ]; then
        report_release "$SDK_RELEASE" "current"
    fi
    log "remote digest comparison: $VERIFY_MATCH MATCH, $VERIFY_DIFF DIFF"
    [ "$VERIFY_DIFF" -eq 0 ] || \
        warn "published digests differ from local files (local=DIFF above); a real publish uploads the current files and should align them"
fi

# ------------------------------------------------------------------ summary
log "== summary =="
log "mode:    $([ "$PUBLISH" = 1 ] && printf 'PUBLISH' || printf 'DRY-RUN')"
log "version: $VER  versioned=$VERSIONED_TAG  kit=$KIT_TAG  rolling=$LATEST_TAG  sdk=${SDK_RELEASE:-<none>}"
if [ "$PUBLISH" = 1 ]; then
    log "release-all OK: the chain ran to completion"
else
    log "release-all DRY-RUN complete: the plan above is what --publish would execute"
fi
exit 0
