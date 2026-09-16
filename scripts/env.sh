# Source this to test the local OpenHarmony workload against the installed SDK.
W="$(cd "$(dirname "$0")/.." && pwd)"
export DOTNETSDK_WORKLOAD_MANIFEST_ROOTS="$W/manifests"
export DOTNETSDK_WORKLOAD_PACK_ROOTS="$W/packs"
echo "DOTNETSDK_WORKLOAD_MANIFEST_ROOTS=$DOTNETSDK_WORKLOAD_MANIFEST_ROOTS"
echo "DOTNETSDK_WORKLOAD_PACK_ROOTS=$DOTNETSDK_WORKLOAD_PACK_ROOTS"
