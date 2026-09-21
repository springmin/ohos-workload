#!/bin/sh
# Writes dist/SHA256SUMS for the artifacts that are actually published to GitHub:
#
#   openharmony-workload-<version>.tar.gz   workload-<version> + the SDK release
#   openharmony-workload-latest.tar.gz      rolling workload-latest name (same bytes)
#
# Entries are bare file names - never absolute build-host paths - so a consumer can run
# `sha256sum -c SHA256SUMS` in the directory the release assets were downloaded to
# (installers match a release asset with awk '$NF == name', which absolute paths broke).
# Each release carries only one of the two names (the rolling asset only on
# workload-latest); to check just the asset that is present, filter its line:
#   grep '  openharmony-workload-latest.tar.gz$' SHA256SUMS | sha256sum -c -
# Local-only build outputs (demo haps under test/, dist/ets/modules.abc, the extracted
# bundle directory) are deliberately not listed: they are not release assets.
#
# Usage: scripts/release-checksums.sh [--out <file-or-dir>] [--no-rolling]
#   --out <path>    write the sums to <path>; a directory gets <path>/SHA256SUMS
#                   (default: dist/SHA256SUMS)
#   --no-rolling    omit the rolling openharmony-workload-latest.tar.gz entry
#                   (for a publish run with --skip-latest)
set -e

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

usage() {
    cat <<'MD'
Usage: scripts/release-checksums.sh [--out <file-or-dir>] [--no-rolling]
  --out <path>    write the sums to <path>; a directory gets <path>/SHA256SUMS
  --no-rolling    omit the rolling openharmony-workload-latest.tar.gz entry
MD
}

W="$(cd "$(dirname "$0")/.." && pwd)"
BAND="${SDK_BAND:-11.0.100-rc.1}"
OUT="$W/dist/SHA256SUMS"
ROLLING=1

while [ $# -gt 0 ]; do
    case "$1" in
        --out) shift; OUT="$1" ;;
        --no-rolling) ROLLING=0 ;;
        -h|--help) usage; exit 0 ;;
        *) warn "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
    shift
done

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"
    fi
}

MANIFEST="$W/manifests/$BAND/microsoft.net.sdk.openharmony/WorkloadManifest.json"
[ -f "$MANIFEST" ] || { warn "workload manifest not found: $MANIFEST"; exit 1; }
VER="$(python3 -c "import json;print(json.load(open('$MANIFEST'))['version'])")"

BUNDLE="$W/dist/openharmony-workload-$VER.tar.gz"
ROLLING_NAME="openharmony-workload-latest.tar.gz"
ROLLING_FILE="$W/.feed/$ROLLING_NAME"
[ -f "$BUNDLE" ] || { warn "bundle not found: $BUNDLE (run scripts/pack-workload-bundle.sh first)"; exit 1; }

if [ -d "$OUT" ]; then OUT="$OUT/SHA256SUMS"; fi
mkdir -p "$(dirname "$OUT")"
TMP="$OUT.tmp.$$"
trap 'rm -f "$TMP"' EXIT

BUNDLE_SHA="$(sha256_of "$BUNDLE")"
printf '%s  %s\n' "$BUNDLE_SHA" "${BUNDLE##*/}" > "$TMP"

if [ "$ROLLING" = 1 ]; then
    # The rolling asset is published as a byte copy of the versioned bundle, so it shares
    # the digest; a stale .feed copy from an older run is replaced at publish time.
    if [ -f "$ROLLING_FILE" ] && [ "$(sha256_of "$ROLLING_FILE")" != "$BUNDLE_SHA" ]; then
        warn "$ROLLING_NAME in .feed is stale (digest differs from the bundle); it is replaced when published"
    fi
    printf '%s  %s\n' "$BUNDLE_SHA" "$ROLLING_NAME" >> "$TMP"
fi

mv -f "$TMP" "$OUT"
log "wrote $OUT ($(grep -c '' "$OUT") entries)"
cat "$OUT"
