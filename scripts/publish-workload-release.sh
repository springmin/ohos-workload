#!/bin/sh
# Publishes the OpenHarmony platform workload as GitHub releases:
#   workload-<version>  immutable release, assets openharmony-workload-<version>.tar.gz +
#                       SHA256SUMS
#   workload-latest     rolling release, asset openharmony-workload-latest.tar.gz
#   device-test-kit     delivery kit, assets device-test-kit.tar.gz + .sha256 (also attached to
#                       workload-latest); skipped with a log line when the kit tarball is
#                       absent (DEVICE_TEST_KIT overrides the default path)
#   --also-sdk-release <tag> additionally attaches the versioned asset to an SDK release (the
#                       "A" layout, e.g. v11.0.100-rc.1.26451.109-openharmony)
# Digest gate (fail closed): every artifact that is uploaded must match an independent
# expected sha256 supplied by the caller (local files are never trusted on their own):
# --bundle-sha256 / BUNDLE_SHA256 for the bundle, --kit-sha256 / DEVICE_TEST_KIT_SHA256 for the
# kit. A real (non --dry-run) publish without the expectation for an artifact it would upload
# aborts before touching any release.
# Release checksums are regenerated from the bundle being published on every run
# (release-checksums.sh: bare names, the versioned + rolling entries) and checked line by line
# against the digests this run gates on, so a stale dist/SHA256SUMS is never uploaded;
# --skip-latest drops the rolling entry, matching the versioned release assets.
# --kit-tree-digest / DEVICE_TEST_KIT_TREE_DIGEST: sha256 of the extracted kit contents, echoed
# into the kit release notes so a tester can bind the exact tree with
# `sh verify-kit.sh --expect-tree-digest <hex>`.
# --clobber is only used when the GitHub API reports the same digest for the existing asset
# (idempotent re-upload); replacing an asset whose published digest differs - including the
# rolling workload-latest and a rebuilt kit - requires --allow-clobber-mismatch (or
# ALLOW_CLOBBER_MISMATCH=1). Every check is logged.
# SDK release SHA256SUMS: the published body is fetched and merged - every line whose basename
# this run does not publish is kept verbatim, the workload entries are replaced with this
# run's digests, sorted by basename; only when the fetch fails (asset absent, API error) is the
# local file uploaded unchanged, with a warning. workload-<version> and workload-latest keep
# the exact two-line file, --clobber included.
# Release notes: scripts/release-notes.sh generates the notes for the versioned release and
# workload-latest (invoke it directly as `scripts/release-notes.sh --version <version>
# [--since <tag-or-commit>]` for the commits since the previous workload-<version> tag,
# grouped by type, plus the dist/SHA256SUMS digests); bundle/install guidance is appended, the
# static notes are the fallback. Run `git fetch --tags` before publishing.
# Usage: scripts/publish-workload-release.sh [--repo owner/name] [--dry-run]
#          [--skip-versioned] [--skip-latest] [--skip-kit] [--kit <tarball>]
#          [--kit-tag <tag>] [--also-sdk-release <tag>]
#          [--bundle-sha256 <hex>] [--kit-sha256 <hex>] [--kit-tree-digest <hex>]
#          [--allow-clobber-mismatch]
set -e

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

W="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${REPO:-springmin/sdk-ohos}"
BAND="${SDK_BAND:-11.0.100-rc.1}"
DRY_RUN=0
SKIP_VERSIONED=0
SKIP_LATEST=0
SKIP_KIT=0
SDK_RELEASE=""
# Delivery kit tarball (signed haps + acceptance docs). Its release carries the tarball plus a
# transfer checksum; the same two assets are refreshed on workload-latest.
KIT_SRC="${DEVICE_TEST_KIT:-/data/storage/el2/base/tmp/opencode/device-test-kit.tar.gz}"
KIT_TAG="${DEVICE_TEST_KIT_TAG:-device-test-kit}"
# Independent expected digests (caller-supplied; never regenerated from the local files).
BUNDLE_SHA256_EXPECT="${BUNDLE_SHA256:-}"
KIT_SHA256_EXPECT="${DEVICE_TEST_KIT_SHA256:-}"
# Optional digest of the extracted kit contents; published in the kit release notes.
KIT_TREE_DIGEST="${DEVICE_TEST_KIT_TREE_DIGEST:-}"
ALLOW_CLOBBER_MISMATCH="${ALLOW_CLOBBER_MISMATCH:-0}"

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) shift; REPO="$1" ;;
        --dry-run) DRY_RUN=1 ;;
        --skip-versioned) SKIP_VERSIONED=1 ;;
        --skip-latest) SKIP_LATEST=1 ;;
        --skip-kit) SKIP_KIT=1 ;;
        --kit) shift; KIT_SRC="$1" ;;
        --kit-tag) shift; KIT_TAG="$1" ;;
        --also-sdk-release) shift; SDK_RELEASE="$1" ;;
        --bundle-sha256) shift; BUNDLE_SHA256_EXPECT="$1" ;;
        --kit-sha256) shift; KIT_SHA256_EXPECT="$1" ;;
        --kit-tree-digest) shift; KIT_TREE_DIGEST="$1" ;;
        --allow-clobber-mismatch) ALLOW_CLOBBER_MISMATCH=1 ;;
        *) warn "unknown argument: $1"; exit 2 ;;
    esac
    shift
done

run() { if [ "$DRY_RUN" = 1 ]; then printf '   [dry-run] %s\n' "$*"; else "$@"; fi; }

# "<hash>  <name>" for a file in the current directory (sha256sum, or a python fallback for
# hosts without coreutils).
sha256_line() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1"
    else
        python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()+'  '+sys.argv[1])" "$1"
    fi
}

sha256_of() {
    sha256_line "$1" | cut -d' ' -f1
}

# Fail-closed digest gate for a local artifact that is about to be published. Sets
# CHECKED_SHA on success; a real publish without an expectation (or a mismatch) aborts.
verify_local_digest() {
    _file="$1"; _expect="$2"; _label="$3"
    [ -f "$_file" ] || { warn "$_label not found: $_file"; exit 1; }
    CHECKED_SHA="$(sha256_of "$_file")"
    if [ -z "$_expect" ]; then
        if [ "$DRY_RUN" = 1 ]; then
            warn "$_label: dry-run without an expected digest (local sha256=$CHECKED_SHA; pass the matching --...-sha256 in a real run)"
        else
            warn "$_label: refusing to publish without an independent expected digest"
            warn "  local $_file sha256=$CHECKED_SHA"
            warn "  pass --bundle-sha256 <hex> / --kit-sha256 <hex> (or BUNDLE_SHA256 / DEVICE_TEST_KIT_SHA256)"
            exit 1
        fi
    elif [ "$CHECKED_SHA" != "$_expect" ]; then
        warn "$_label: sha256 mismatch - refusing to publish"
        warn "  expected $_expect"
        warn "  actual   $CHECKED_SHA"
        exit 1
    else
        log "$_label: expected sha256 OK ($CHECKED_SHA)"
    fi
}

# Fail closed unless the regenerated sums file carries exactly "<digest>  <name>" for an
# artifact this run publishes (basenames only, as released).
check_sums_line() {
    _name="$1"; _want="$2"
    if [ -f "$SUMS" ] && grep -Fqx "$_want  $_name" "$SUMS"; then
        log "checksums: $_name expected sha256 OK ($_want)"
    else
        warn "refusing to publish $SUMS_NAME: missing or wrong entry for $_name"
        warn "  expected line: $_want  $_name"
        if [ -f "$SUMS" ]; then sed 's/^/    /' "$SUMS" >&2; fi
        warn "  regenerate with scripts/release-checksums.sh (check the manifest version/bundle)"
        exit 1
    fi
}

# Digest of an existing release asset as reported by the GitHub API ("" when unknown).
published_asset_digest() {
    _tag="$1"; _name="$2"
    _digest="$(gh api "repos/$REPO/releases/tags/$_tag" \
        --jq ".assets[] | select(.name == \"$_name\") | .digest" 2>/dev/null | head -n1)"
    case "$_digest" in
        sha256:*) printf '%s\n' "${_digest#sha256:}" ;;
        "")       : ;;
        *)        printf '%s\n' "$_digest" ;;
    esac
}

# Refuse --clobber unless the published asset digest equals the local one, or the caller
# explicitly forced the replacement. Only called when the release is known to exist.
guard_clobber() {
    _tag="$1"; _name="$2"; _sha="$3"
    if [ "$DRY_RUN" = 1 ] || ! gh release view "$_tag" --repo "$REPO" >/dev/null 2>&1; then
        return 0
    fi
    _pub="$(published_asset_digest "$_tag" "$_name")"
    if [ -z "$_pub" ]; then
        if [ "$ALLOW_CLOBBER_MISMATCH" = 1 ]; then
            warn "clobber override: $_tag/$_name published digest unreadable; replacing with $_sha"
        else
            warn "refusing --clobber $_tag/$_name: published digest unavailable from the API"
            warn "  local sha256=$_sha; pass --allow-clobber-mismatch to replace deliberately"
            exit 1
        fi
    elif [ "$_pub" = "$_sha" ]; then
        log "clobber check OK: $_tag/$_name published sha256=$_pub (identical content)"
    elif [ "$ALLOW_CLOBBER_MISMATCH" = 1 ]; then
        warn "clobber override: $_tag/$_name published=$_pub local=$_sha"
    else
        warn "refusing --clobber $_tag/$_name: published $_pub != local $_sha"
        warn "  pass --allow-clobber-mismatch to replace the published asset deliberately"
        exit 1
    fi
}

# Download the SHA256SUMS body currently attached to a release into the file named by $2.
# Returns 0 = fetched, 1 = the release has no such asset (or it is empty), 2 = request failed.
# The _fps_* names keep this helper from clobbering its callers' variables (POSIX sh has no
# function-local scope).
fetch_published_sums() {
    _fps_tag="$1"; _fps_out="$2"
    rm -f "$_fps_out"
    _fps_id=""
    if ! _fps_id="$(gh api --paginate "repos/$REPO/releases/tags/$_fps_tag" \
        --jq ".assets[] | select(.name == \"$SUMS_NAME\") | .id" 2>/dev/null)"; then
        return 2
    fi
    _fps_id="$(printf '%s\n' "$_fps_id" | head -n1)"
    [ -n "$_fps_id" ] || return 1
    if ! gh api "repos/$REPO/releases/assets/$_fps_id" \
        -H 'Accept: application/octet-stream' > "$_fps_out" 2>/dev/null; then
        rm -f "$_fps_out"
        return 2
    fi
    [ -s "$_fps_out" ] || { rm -f "$_fps_out"; return 1; }
    return 0
}

# Merge the published sums ($1) with the workload sums generated for this run ($2) into $3:
# every existing line whose basename ("hash  name" or "hash *name", any directory prefix) is
# not published by this run is kept verbatim, the workload entries are replaced by the local
# ones, and the result is sorted by basename (LC_ALL=C) so equal inputs give equal bytes.
merge_sums() {
    _ms_existing="$1"; _ms_local="$2"; _ms_out="$3"
    _ms_tmp="$3.merge.$$"
    {
        if [ -s "$_ms_existing" ]; then
            # The rolling name is a workload entry even when this run does not refresh it
            # (--skip-latest has no local line for it): a stale digest left by an earlier
            # merge is dropped rather than carried into the new file.
            awk -v rolling="openharmony-workload-latest.tar.gz" '
                {
                    n = $NF
                    sub(/^\*/, "", n)
                    sub(/^.*\//, "", n)
                    gsub(/\r$/, "", n)
                }
                NR == FNR { ours[n] = 1; next }
                !(n in ours) && n != rolling { print }
            ' "$_ms_local" "$_ms_existing"
        fi
        cat "$_ms_local"
    } > "$_ms_tmp"
    LC_ALL=C sort -s -k2,2 "$_ms_tmp" > "$_ms_out"
    rm -f "$_ms_tmp"
}

# Build the sums file to attach to the SDK release in $3 from the local workload file ($2).
# Sets SDK_SUMS_MERGED=1 when the published body was merged, 0 when there is nothing to
# merge (no asset, unreadable API): then the local file is copied unchanged, with a warning
# - exactly what the script always uploaded before the merge existed.
prepare_sdk_sums() {
    _pss_tag="$1"; _pss_local="$2"; _pss_out="$3"
    SDK_SUMS_MERGED=0
    _pss_existing="$(mktemp)"
    _pss_rc=0
    fetch_published_sums "$_pss_tag" "$_pss_existing" || _pss_rc=$?
    if [ "$_pss_rc" -eq 0 ]; then
        merge_sums "$_pss_existing" "$_pss_local" "$_pss_out"
        SDK_SUMS_MERGED=1
        log "SHA256SUMS: merged the published $_pss_tag/$SUMS_NAME with this run's workload entries ($(grep -c '' "$_pss_out") lines)"
    else
        if [ "$_pss_rc" -eq 1 ]; then
            warn "SHA256SUMS: no $_pss_tag/$SUMS_NAME asset (or empty); uploading the local workload-only file unchanged"
        else
            warn "SHA256SUMS: could not fetch $_pss_tag/$SUMS_NAME (gh api request failed); uploading the local workload-only file unchanged"
        fi
        cp -f "$_pss_local" "$_pss_out"
        log "SHA256SUMS: local workload-only file for the $_pss_tag upload ($(grep -c '' "$_pss_out") lines)"
    fi
    rm -f "$_pss_existing"
}

VER="$(python3 -c "import json;print(json.load(open('$W/manifests/$BAND/microsoft.net.sdk.openharmony/WorkloadManifest.json'))['version'])")"
VERSIONED_TAG="workload-$VER"
BUNDLE="$W/dist/openharmony-workload-$VER.tar.gz"
LATEST_ASSET="$W/.feed/openharmony-workload-latest.tar.gz"

log "== repo=$REPO version=$VER =="
if [ ! -f "$BUNDLE" ] || [ "$DRY_RUN" = 1 ]; then
    run sh "$W/scripts/pack-workload-bundle.sh"
fi
[ -f "$BUNDLE" ] || { warn "bundle not found: $BUNDLE"; exit 1; }

# Independent digest gate: verify every artifact this run would upload before any release
# is touched (fail closed in a real publish, warn-only in --dry-run).
NEED_BUNDLE=0
if [ "$SKIP_VERSIONED" = 0 ] || [ "$SKIP_LATEST" = 0 ] || [ -n "$SDK_RELEASE" ]; then
    NEED_BUNDLE=1
fi
if [ "$NEED_BUNDLE" = 1 ]; then
    verify_local_digest "$BUNDLE" "$BUNDLE_SHA256_EXPECT" "bundle"
    BUNDLE_SHA="$CHECKED_SHA"
else
    BUNDLE_SHA="$(sha256_of "$BUNDLE")"
fi

# Release checksums: always regenerated from the bundle being published (never reused from
# an earlier run - a stale dist/SHA256SUMS would be uploaded next to a fresh bundle) and
# then checked line by line. A dry run writes the scratch copy only, so dist/ is untouched;
# a real run replaces dist/SHA256SUMS through scripts/release-checksums.sh (tmp + mv).
SUMS="$W/dist/SHA256SUMS"
SUMS_NAME="$(basename "$SUMS")"
SUMS_SHA=""
SUMS_SCRATCH=0
if [ "$NEED_BUNDLE" = 1 ]; then
    [ -f "$W/scripts/release-checksums.sh" ] || {
        warn "scripts/release-checksums.sh not found; refusing to publish checksums that cannot be regenerated"
        exit 1
    }
    SUMS_ARGS=""
    if [ "$SKIP_LATEST" = 1 ]; then SUMS_ARGS="--no-rolling"; fi
    if [ "$DRY_RUN" = 1 ]; then
        SUMS_SCRATCH=1
        SUMS="$(mktemp)"
        sh "$W/scripts/release-checksums.sh" --out "$SUMS" $SUMS_ARGS >/dev/null
        if [ -f "$W/dist/SHA256SUMS" ] && ! cmp -s "$SUMS" "$W/dist/SHA256SUMS"; then
            warn "dist/SHA256SUMS is stale (differs from the bundle being published); a real run regenerates it"
        fi
    else
        sh "$W/scripts/release-checksums.sh" $SUMS_ARGS >/dev/null
    fi
    check_sums_line "$(basename "$BUNDLE")" "$BUNDLE_SHA"
    if [ "$SKIP_LATEST" = 0 ]; then
        check_sums_line "openharmony-workload-latest.tar.gz" "$BUNDLE_SHA"
    fi
    SUMS_SHA="$(sha256_of "$SUMS")"
fi

# Release notes: prefer the generated changelog (scripts/release-notes.sh) and append the
# bundle/install guidance; fall back to the static notes when the generator is absent or
# fails. Dist digests are materialised first so the changelog can carry them.
NOTES="$(mktemp)"
GEN="$W/scripts/release-notes.sh"

write_setup_notes() {
    cat <<MD
Bundle: \`openharmony-workload-$VER.tar.gz\` (manifest + \`feed/*.nupkg\` +
\`install-ohos-workload.sh\`).

\`\`\`sh
tar xzf openharmony-workload-$VER.tar.gz
cd openharmony-workload-$VER
./install-ohos-workload.sh
\`\`\`

\`sdk-ohos\`'s \`install-dotnet-ohos.sh\` resolves this release automatically (newest
\`workload-*\` release, or the rolling \`workload-latest\`), or pin it with
\`WORKLOAD_RELEASE_TAG=$VERSIONED_TAG\`.

Uninstall: \`dotnet workload uninstall openharmony\` and remove
\`<dotnet-root>/sdk-manifests/<band>/microsoft.net.sdk.openharmony\`.
MD
}

write_static_notes() {
    printf '# OpenHarmony platform workload %s\n\n' "$VER"
    write_setup_notes
}

if [ -f "$GEN" ]; then
    if sh "$GEN" --version "$VER" > "$NOTES"; then
        log "release notes: generated by scripts/release-notes.sh"
        printf '\n## Bundle and setup\n\n' >> "$NOTES"
        write_setup_notes >> "$NOTES"
    else
        warn "scripts/release-notes.sh failed; falling back to the static release notes"
        write_static_notes > "$NOTES"
    fi
else
    write_static_notes > "$NOTES"
fi

if [ "$SKIP_VERSIONED" = 0 ]; then
    log "== publishing $VERSIONED_TAG =="
    if [ "$DRY_RUN" = 0 ] && gh release view "$VERSIONED_TAG" --repo "$REPO" >/dev/null 2>&1; then
        # Publish the artifact checksums alongside the bundle; --clobber only when the
        # published digest matches (or the caller forced the replacement).
        guard_clobber "$VERSIONED_TAG" "$(basename "$BUNDLE")" "$BUNDLE_SHA"
        guard_clobber "$VERSIONED_TAG" "SHA256SUMS" "$SUMS_SHA"
        run gh release upload "$VERSIONED_TAG" "$BUNDLE" --repo "$REPO" --clobber
        run gh release upload "$VERSIONED_TAG" "$SUMS" --repo "$REPO" --clobber
        run gh release edit "$VERSIONED_TAG" --repo "$REPO" --notes-file "$NOTES"
    else
        run gh release create "$VERSIONED_TAG" --repo "$REPO" \
            --title "OpenHarmony platform workload $VER" --notes-file "$NOTES" --latest=false \
            "$BUNDLE" "$SUMS"
    fi
fi

if [ "$SKIP_LATEST" = 0 ]; then
    log "== refreshing workload-latest (stable asset name, updated in place) =="
    run mkdir -p "$(dirname "$LATEST_ASSET")"
    run cp -f "$BUNDLE" "$LATEST_ASSET"
    if gh release view workload-latest --repo "$REPO" >/dev/null 2>&1; then
        # Update in place: deleting first meant a failed recreate could drop the release.
        # A rolling asset is expected to change, so the caller must pass
        # --allow-clobber-mismatch for this replacement to happen.
        guard_clobber workload-latest "$(basename "$LATEST_ASSET")" "$BUNDLE_SHA"
        run gh release upload workload-latest "$LATEST_ASSET" --repo "$REPO" --clobber
        run gh release edit workload-latest --repo "$REPO" --title "OpenHarmony platform workload" --notes-file "$NOTES"
    else
        run gh release create workload-latest --repo "$REPO" \
            --title "OpenHarmony platform workload" \
            --notes-file "$NOTES" --latest=false "$LATEST_ASSET"
    fi
    guard_clobber workload-latest "SHA256SUMS" "$SUMS_SHA"
    run gh release upload workload-latest "$SUMS" --repo "$REPO" --clobber
fi

# Device-test kit: signed haps + acceptance/signing docs. Its own release gets the tarball and a
# transfer checksum, and workload-latest carries the same two assets (stable names, --clobber).
if [ "$SKIP_KIT" = 0 ]; then
    KIT_NAME="$(basename "$KIT_SRC")"
    KIT_STAGE="$W/.feed/$KIT_NAME"
    KIT_SUMS="$KIT_STAGE.sha256"
    if [ ! -f "$KIT_SRC" ]; then
        log "== device-test kit skipped (not found: $KIT_SRC) =="
    else
        log "== publishing the device-test kit $KIT_NAME (tag $KIT_TAG) =="
        verify_local_digest "$KIT_SRC" "$KIT_SHA256_EXPECT" "device-test kit"
        KIT_SHA="$CHECKED_SHA"
        run mkdir -p "$(dirname "$KIT_STAGE")"
        run cp -f "$KIT_SRC" "$KIT_STAGE"
        if [ "$DRY_RUN" = 1 ]; then
            printf '   [dry-run] %s > %s/%s\n' "sha256_line $KIT_NAME" "$(dirname "$KIT_STAGE")" "$(basename "$KIT_SUMS")"
            KIT_SUMS_SHA="$KIT_SHA"
        else
            ( cd "$(dirname "$KIT_STAGE")" && sha256_line "$KIT_NAME" > "$KIT_NAME.sha256" )
            log "kit sha256: $(cut -d' ' -f1 "$KIT_SUMS")"
            KIT_SUMS_SHA="$(sha256_of "$KIT_SUMS")"
        fi

        # The extracted-tree digest is optional but binds the exact kit contents (the
        # tarball anchor only proves the .tar.gz on disk); reject a malformed value.
        if [ -n "$KIT_TREE_DIGEST" ]; then
            case "$KIT_TREE_DIGEST" in
                *[!0-9a-fA-F]*) warn "--kit-tree-digest is not a hex sha256: $KIT_TREE_DIGEST"; exit 2 ;;
            esac
            [ "${#KIT_TREE_DIGEST}" -eq 64 ] || { warn "--kit-tree-digest is not 64 hex chars: $KIT_TREE_DIGEST"; exit 2; }
            KIT_TREE_NOTE="
Extracted tree digest (bind the exact kit contents, not just the tarball):
\`sh verify-kit.sh --expect-tree-digest $KIT_TREE_DIGEST\` inside the extracted kit."
        else
            KIT_TREE_NOTE=""
        fi

        KIT_NOTES="$(mktemp)"
        cat > "$KIT_NOTES" <<MD
# OpenHarmony MAUI device-test kit

Signed \`hello-maui-app\` haps together with the acceptance checklist, the signing/UDID guide
and the bundle-level \`SHA256SUMS\` (default, permissions and api20 variants).

\`$KIT_NAME.sha256\` is the transfer checksum of this tarball; it anchors the \`.tar.gz\` file.
Extract it and follow \`README-交付说明.md\`; on install error \`9568344\` send the device UDID
(see \`签名与UDID指南.md\`).$KIT_TREE_NOTE
MD

        if gh release view "$KIT_TAG" --repo "$REPO" >/dev/null 2>&1; then
            guard_clobber "$KIT_TAG" "$KIT_NAME" "$KIT_SHA"
            guard_clobber "$KIT_TAG" "$(basename "$KIT_SUMS")" "$KIT_SUMS_SHA"
            run gh release upload "$KIT_TAG" "$KIT_STAGE" "$KIT_SUMS" --repo "$REPO" --clobber
            run gh release edit "$KIT_TAG" --repo "$REPO" \
                --title "OpenHarmony MAUI device-test kit" --notes-file "$KIT_NOTES"
        else
            run gh release create "$KIT_TAG" --repo "$REPO" \
                --title "OpenHarmony MAUI device-test kit" --notes-file "$KIT_NOTES" --latest=false \
                "$KIT_STAGE" "$KIT_SUMS"
        fi
        if [ "$SKIP_LATEST" = 0 ]; then
            guard_clobber workload-latest "$KIT_NAME" "$KIT_SHA"
            guard_clobber workload-latest "$(basename "$KIT_SUMS")" "$KIT_SUMS_SHA"
            run gh release upload workload-latest "$KIT_STAGE" "$KIT_SUMS" --repo "$REPO" --clobber
        else
            log "workload-latest not refreshed (--skip-latest): kit assets not attached there"
        fi
        rm -f "$KIT_NOTES"
    fi
fi

if [ -n "$SDK_RELEASE" ]; then
    log "== attaching the versioned bundle and SHA256SUMS to the SDK release $SDK_RELEASE =="
    # gh names an uploaded asset after the file's basename, so the merged payload must live
    # in its own scratch directory as SHA256SUMS.
    SDK_DIR="$(mktemp -d)"
    SDK_SUMS="$SDK_DIR/SHA256SUMS"
    SDK_SUMS_MERGED=0
    prepare_sdk_sums "$SDK_RELEASE" "$SUMS" "$SDK_SUMS"
    SDK_SUMS_SHA="$(sha256_of "$SDK_SUMS")"
    guard_clobber "$SDK_RELEASE" "$(basename "$BUNDLE")" "$BUNDLE_SHA"
    # Guard the body actually uploaded: the first merge differs from the published
    # workload-only file (needs --allow-clobber-mismatch, which release-all.sh passes);
    # re-running over an already merged file matches and needs no override.
    guard_clobber "$SDK_RELEASE" "SHA256SUMS" "$SDK_SUMS_SHA"
    run gh release upload "$SDK_RELEASE" "$BUNDLE" --repo "$REPO" --clobber
    run gh release upload "$SDK_RELEASE" "$SDK_SUMS" --repo "$REPO" --clobber
fi
rm -f "$NOTES"
if [ "$SUMS_SCRATCH" = 1 ]; then rm -f "$SUMS"; fi
if [ -n "$SDK_DIR" ]; then rm -rf "$SDK_DIR"; fi
log "== done =="
