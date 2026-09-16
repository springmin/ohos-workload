#!/bin/sh
# Publishes the OpenHarmony platform workload as GitHub releases:
#
#   workload-<version>   immutable release, asset openharmony-workload-<version>.tar.gz
#   workload-latest      rolling release,  asset openharmony-workload-latest.tar.gz
#
# Optionally attach the versioned asset to an SDK release as well (the "A" layout):
#   --also-sdk-release v11.0.100-rc.1.26451.109-openharmony
#
# Usage: scripts/publish-workload-release.sh [--repo owner/name] [--dry-run]
#          [--skip-versioned] [--skip-latest] [--also-sdk-release <tag>]
set -e
W="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${REPO:-springmin/sdk-ohos}"
BAND="${SDK_BAND:-11.0.100-rc.1}"
DRY_RUN=0
SKIP_VERSIONED=0
SKIP_LATEST=0
SDK_RELEASE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) shift; REPO="$1" ;;
        --dry-run) DRY_RUN=1 ;;
        --skip-versioned) SKIP_VERSIONED=1 ;;
        --skip-latest) SKIP_LATEST=1 ;;
        --also-sdk-release) shift; SDK_RELEASE="$1" ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

run() { if [ "$DRY_RUN" = 1 ]; then printf '   [dry-run] %s\n' "$*"; else "$@"; fi; }

VER="$(python3 -c "import json;print(json.load(open('$W/manifests/$BAND/microsoft.net.sdk.openharmony/WorkloadManifest.json'))['version'])")"
VERSIONED_TAG="workload-$VER"
BUNDLE="$W/dist/openharmony-workload-$VER.tar.gz"
LATEST_ASSET="$W/.feed/openharmony-workload-latest.tar.gz"

echo "== repo=$REPO version=$VER =="
if [ ! -f "$BUNDLE" ] || [ "$DRY_RUN" = 1 ]; then
    run sh "$W/scripts/pack-workload-bundle.sh"
fi
[ -f "$BUNDLE" ] || { echo "ERROR: bundle not found: $BUNDLE" >&2; exit 1; }

NOTES="$(mktemp)"
cat > "$NOTES" <<MD
# OpenHarmony platform workload $VER

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

if [ "$SKIP_VERSIONED" = 0 ]; then
    echo "== publishing $VERSIONED_TAG =="
    if [ "$DRY_RUN" = 0 ] && gh release view "$VERSIONED_TAG" --repo "$REPO" >/dev/null 2>&1; then
        run gh release upload "$VERSIONED_TAG" "$BUNDLE" --repo "$REPO" --clobber
        run gh release edit "$VERSIONED_TAG" --repo "$REPO" --notes-file "$NOTES"
    else
        run gh release create "$VERSIONED_TAG" --repo "$REPO" \
            --title "OpenHarmony platform workload $VER" --notes-file "$NOTES" --latest=false \
            "$BUNDLE"
    fi
fi

if [ "$SKIP_LATEST" = 0 ]; then
    echo "== refreshing workload-latest (stable asset name) =="
    run mkdir -p "$(dirname "$LATEST_ASSET")"
    run cp -f "$BUNDLE" "$LATEST_ASSET"
    if [ "$DRY_RUN" = 0 ]; then
        gh release delete workload-latest --repo "$REPO" --yes --cleanup-tag >/dev/null 2>&1 || true
    fi
    run gh release create workload-latest --repo "$REPO" \
        --title "OpenHarmony platform workload — rolling latest" \
        --notes-file "$NOTES" --latest=false "$LATEST_ASSET"
fi

if [ -n "$SDK_RELEASE" ]; then
    echo "== attaching the versioned bundle to the SDK release $SDK_RELEASE =="
    run gh release upload "$SDK_RELEASE" "$BUNDLE" --repo "$REPO" --clobber
fi
rm -f "$NOTES"
echo "== done =="
