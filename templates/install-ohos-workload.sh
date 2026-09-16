#!/bin/sh
# Installs the OpenHarmony platform workload into a .NET SDK root.
#
# Usage: install-ohos-workload.sh [--dry-run] [--dotnet <muxer>] [bundle-dir]
#
# bundle-dir defaults to the directory containing this script and must contain:
#   manifests/microsoft.net.sdk.openharmony/{WorkloadManifest.json,WorkloadManifest.targets}
#   feed/*.nupkg                      (the workload packs; see scripts/pack-local-workload.sh)
#
# The script is idempotent: re-running verifies/refreshes the installation.
set -e

DRY_RUN=0
DOTNET=""
BUNDLE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --dotnet) shift; DOTNET="$1" ;;
        *) BUNDLE="$1" ;;
    esac
    shift
done
[ -n "$BUNDLE" ] || BUNDLE="$(cd "$(dirname "$0")" && pwd)"

info() { printf '==> %s\n' "$*"; }
run() {
    if [ "$DRY_RUN" = "1" ]; then printf '   [dry-run] %s\n' "$*"; else "$@"; fi
}

[ -d "$BUNDLE/feed" ] || { echo "ERROR: no feed/ directory in $BUNDLE" >&2; exit 1; }
[ -d "$BUNDLE/manifests/microsoft.net.sdk.openharmony" ] || { echo "ERROR: no manifests/ in $BUNDLE" >&2; exit 1; }

if [ -z "$DOTNET" ]; then
    DOTNET="$(command -v dotnet 2>/dev/null || true)"
fi
[ -n "$DOTNET" ] || { echo "ERROR: dotnet muxer not found (use --dotnet)" >&2; exit 1; }

# The muxer resolves the SDK through its real path, so the workload must go into
# the root that owns the SDK.
REAL_DOTNET="$(readlink -f "$DOTNET" 2>/dev/null || printf '%s' "$DOTNET")"
ROOT="$(cd "$(dirname "$REAL_DOTNET")" && pwd)"
[ -d "$ROOT/sdk" ] || { echo "ERROR: $ROOT does not look like a .NET root" >&2; exit 1; }

# SDK feature band: the sdk/<version> directory without the trailing build numbers,
# e.g. 11.0.100-rc.1.26451.109 -> 11.0.100-rc.1 (preview) or 11.0.100 (release).
SDK_VERSION="$(basename "$(ls -d "$ROOT"/sdk/*/ 2>/dev/null | sort -V | tail -1)")"
BAND="$(printf '%s' "$SDK_VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+(-[a-z]+\.[0-9]+)?)(\.[0-9]+)*$/\1/')"
[ -n "$BAND" ] || { echo "ERROR: could not derive the SDK feature band from $SDK_VERSION" >&2; exit 1; }

info "dotnet root : $ROOT"
info "SDK version : $SDK_VERSION (band $BAND)"
info "bundle      : $BUNDLE"

MANIFEST_DIR="$ROOT/sdk-manifests/$BAND/microsoft.net.sdk.openharmony"
if [ "$DRY_RUN" = "1" ]; then
    printf '   [dry-run] install -d %s\n' "$MANIFEST_DIR"
else
    mkdir -p "$ROOT/sdk-manifests/$BAND"
fi
run cp -r "$BUNDLE/manifests/microsoft.net.sdk.openharmony" "$ROOT/sdk-manifests/$BAND/"
run "$REAL_DOTNET" workload install openharmony --skip-manifest-update --source "$BUNDLE/feed"

if [ "$DRY_RUN" != "1" ]; then
    info "installed workloads:"
    "$REAL_DOTNET" workload list | sed 's/^/   /'
fi
