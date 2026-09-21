#!/bin/sh
# Publishes the OpenHarmony platform workload as GitHub releases:
#
#   workload-<version>   immutable release, assets openharmony-workload-<version>.tar.gz + SHA256SUMS
#   workload-latest      rolling release,  asset openharmony-workload-latest.tar.gz
#   device-test-kit      delivery kit,     assets device-test-kit.tar.gz + .sha256
#                        (also attached to workload-latest). Skipped, with a log line, when the
#                        kit tarball is absent (DEVICE_TEST_KIT overrides the default path).
#
# Optionally attach the versioned asset to an SDK release as well (the "A" layout):
#   --also-sdk-release v11.0.100-rc.1.26451.109-openharmony
#
# Usage: scripts/publish-workload-release.sh [--repo owner/name] [--dry-run]
#          [--skip-versioned] [--skip-latest] [--skip-kit] [--kit <tarball>]
#          [--kit-tag <tag>] [--also-sdk-release <tag>]
#          [--bundle-sha256 <hex>] [--kit-sha256 <hex>] [--allow-clobber-mismatch]
#
# Digest gate (fail closed): every artifact that is uploaded must match an independent
# expected sha256 supplied by the caller (local files are never trusted on their own):
#   --bundle-sha256 / BUNDLE_SHA256           dist/openharmony-workload-<version>.tar.gz
#   --kit-sha256    / DEVICE_TEST_KIT_SHA256  the device-test kit tarball
# A real (non --dry-run) publish without the expectation for an artifact it would upload
# aborts before touching any release.
#
# --clobber is only used when the GitHub API reports the same digest for the existing
# asset (idempotent re-upload); replacing an asset whose published digest differs -
# including the rolling workload-latest and a rebuilt kit - requires the explicit
# --allow-clobber-mismatch (or ALLOW_CLOBBER_MISMATCH=1). Every check is logged.
#
# Release notes: when scripts/release-notes.sh is present it generates the notes body for
# both the versioned release and workload-latest (invoke it directly as
#   scripts/release-notes.sh --version <version> [--since <tag-or-commit>]
# for the commits since the previous `workload-<version>` tag, grouped by type, plus the
# dist/SHA256SUMS digests). The bundle/install guidance is appended after the changelog; the
# static notes are the fallback when the generator is missing or fails. Run
# `git fetch --tags` before publishing so the default commit range is the previous release.
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

# Release notes: prefer the generated changelog (scripts/release-notes.sh) and append the
# bundle/install guidance; fall back to the static notes when the generator is absent or
# fails. Dist digests are materialised first so the changelog can carry them.
[ -f "$W/dist/SHA256SUMS" ] || sh "$W/scripts/release-checksums.sh" >/dev/null
SUMS_SHA="$(sha256_of "$W/dist/SHA256SUMS")"
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
        run gh release upload "$VERSIONED_TAG" "$W/dist/SHA256SUMS" --repo "$REPO" --clobber
        run gh release edit "$VERSIONED_TAG" --repo "$REPO" --notes-file "$NOTES"
    else
        run gh release create "$VERSIONED_TAG" --repo "$REPO" \
            --title "OpenHarmony platform workload $VER" --notes-file "$NOTES" --latest=false \
            "$BUNDLE" "$W/dist/SHA256SUMS"
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
    run gh release upload workload-latest "$W/dist/SHA256SUMS" --repo "$REPO" --clobber
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

        KIT_NOTES="$(mktemp)"
        cat > "$KIT_NOTES" <<MD
# OpenHarmony MAUI device-test kit

Signed \`hello-maui-app\` haps together with the acceptance checklist, the signing/UDID guide
and the bundle-level \`SHA256SUMS\` (default, permissions and api20 variants).

\`$KIT_NAME.sha256\` is the transfer checksum of this tarball. Extract it and follow
\`README-交付说明.md\`; on install error \`9568344\` send the device UDID (see
\`签名与UDID指南.md\`).
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
    guard_clobber "$SDK_RELEASE" "$(basename "$BUNDLE")" "$BUNDLE_SHA"
    guard_clobber "$SDK_RELEASE" "SHA256SUMS" "$SUMS_SHA"
    run gh release upload "$SDK_RELEASE" "$BUNDLE" --repo "$REPO" --clobber
    run gh release upload "$SDK_RELEASE" "$W/dist/SHA256SUMS" --repo "$REPO" --clobber
fi
rm -f "$NOTES"
log "== done =="
