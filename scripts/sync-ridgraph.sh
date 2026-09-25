#!/bin/sh
# Single-source generation / verification for the OpenHarmony portable RID graph.
#
# The canonical graph lives in the sdk-ohos repository at
#   eng/PortableRuntimeIdentifierGraph.openharmony.json
# (the graph the SDK layout and the bootstrap-SDK injection use, see
# sdk-ohos/eng/ohos-install/build/build-ohos-all.sh). The workload SDK packs ship a copy under
# ridgraph/ and set RuntimeIdentifierGraphPath to it; the two copies must stay byte-identical or
# the SDK build and the workload restore resolve different RID sets (the audit's V1 drift).
#
#   scripts/sync-ridgraph.sh                 regenerate every pack copy from the canonical graph
#   scripts/sync-ridgraph.sh --check         verify only (no writes); exit 1 on drift
#   scripts/sync-ridgraph.sh --from <path>   explicit canonical graph path
#
# Canonical resolution (first hit wins): --from, $SDK_OHOS_ENG_GRAPH, the sibling checkout
#   ../sdk-ohos/eng/PortableRuntimeIdentifierGraph.openharmony.json.
# The sha256 of the source is recorded in packs/ridgraph-canonical.sha256, so --check still
# catches a hand-edited pack copy when the sdk-ohos checkout is not available (offline/CI
# without the sibling repo); when the canonical file IS reachable the check is byte-level.
#
# Env: SDK_OHOS_ENG_GRAPH=<canonical path>   override the source graph
#      RIDGRAPH_PACKS=<dir>                  override the packs dir (default: <repo>/packs)
# Exit: 0 = in sync; 1 = drift / invalid source; 2 = usage.
set -u

W="$(cd "$(dirname "$0")/.." && pwd)"
PACKS="${RIDGRAPH_PACKS:-$W/packs}"
RECORD="$PACKS/ridgraph-canonical.sha256"
SOURCE_DISPLAY="sdk-ohos/eng/PortableRuntimeIdentifierGraph.openharmony.json"
CHECK=0
FROM=""

usage() {
    echo "usage: $0 [--check] [--from <canonical graph>]" >&2
    exit 2
}
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK=1 ;;
        --from)
            shift
            [ $# -gt 0 ] || usage
            FROM="$1"
            ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
    shift
done

# GNU coreutils first, python3 fallback (the repo already requires python3).
sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
    fi
}

# The canonical graph must be the AOT-enabled one: every openharmony-<arch> RID imports the
# matching linux-musl-<arch> RID (the AOT pack fallback, sdk-ohos commit 59b9f9439d).
validate_graph() { # <file> <label>
    python3 - "$1" "$2" <<'PY' || exit 1
import json, sys
path, label = sys.argv[1], sys.argv[2]
try:
    graph = json.load(open(path, encoding='utf-8'))
except Exception as exc:  # noqa: BLE001 - report the parse error verbatim
    print(f"{label}: not valid JSON: {exc}", file=sys.stderr)
    sys.exit(1)
runtimes = graph.get('runtimes')
if not isinstance(runtimes, dict):
    print(f"{label}: no runtimes table", file=sys.stderr)
    sys.exit(1)
missing = []
for arch in ('arm', 'arm64', 'x64'):
    rid = f'openharmony-{arch}'
    imports = runtimes.get(rid, {}).get('#import', [])
    if f'linux-musl-{arch}' not in imports:
        missing.append(f'{rid} -> linux-musl-{arch}')
if missing:
    print(f"{label}: missing AOT RID imports: {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)
print(f"   graph OK: openharmony-arm/arm64/x64 import linux-musl-* ({label})")
PY
}

# Canonical source resolution.
CANONICAL=""
if [ -n "$FROM" ]; then
    CANONICAL="$FROM"
elif [ -n "${SDK_OHOS_ENG_GRAPH:-}" ]; then
    CANONICAL="$SDK_OHOS_ENG_GRAPH"
elif [ -f "$W/../sdk-ohos/eng/PortableRuntimeIdentifierGraph.openharmony.json" ]; then
    CANONICAL="$W/../sdk-ohos/eng/PortableRuntimeIdentifierGraph.openharmony.json"
fi

PACK_DIRS="$(ls -d "$PACKS"/Microsoft.OpenHarmony.Sdk/*/ridgraph 2>/dev/null || true)"
[ -n "$PACK_DIRS" ] || { echo "no $PACKS/Microsoft.OpenHarmony.Sdk/*/ridgraph directories found" >&2; exit 1; }

CANON_SHA=""
if [ -n "$CANONICAL" ]; then
    [ -f "$CANONICAL" ] || { echo "canonical RID graph not found: $CANONICAL" >&2; exit 1; }
    validate_graph "$CANONICAL" "$CANONICAL"
    CANON_SHA="$(sha256_file "$CANONICAL")"
    echo "== canonical: $CANONICAL"
    echo "   sha256: $CANON_SHA"
else
    if [ -f "$RECORD" ]; then
        CANON_SHA="$(cut -d' ' -f1 < "$RECORD")"
        echo "== canonical not reachable; using the recorded digest ($RECORD)"
        echo "   recorded: $CANON_SHA"
    else
        echo "canonical RID graph not found and no digest record at $RECORD" >&2
        echo "  set SDK_OHOS_ENG_GRAPH=/path/to/sdk-ohos/eng/PortableRuntimeIdentifierGraph.openharmony.json" >&2
        exit 1
    fi
fi

DRIFT=0
for dir in $PACK_DIRS; do
    dest="$dir/PortableRuntimeIdentifierGraph.openharmony.json"
    pack_label="${dir#"$PACKS"/}"
    if [ ! -f "$dest" ]; then
        echo "   MISSING $pack_label/PortableRuntimeIdentifierGraph.openharmony.json" >&2
        DRIFT=1
        continue
    fi
    dest_sha="$(sha256_file "$dest")"
    if [ "$dest_sha" != "$CANON_SHA" ]; then
        echo "   DRIFT   $pack_label (pack $dest_sha)" >&2
        DRIFT=1
        if [ "$CHECK" = 0 ] && [ -n "$CANONICAL" ]; then
            cp -f "$CANONICAL" "$dest"
            echo "   synced  $pack_label"
        fi
    else
        echo "   ok      $pack_label"
    fi
done

if [ "$CHECK" = 1 ]; then
    if [ "$DRIFT" != 0 ]; then
        echo "RID graph check FAILED: run scripts/sync-ridgraph.sh" >&2
        exit 1
    fi
    echo "RID graph check: all pack copies match $SOURCE_DISPLAY"
    exit 0
fi

if [ "$DRIFT" != 0 ] && [ -z "$CANONICAL" ]; then
    echo "RID graph sync FAILED: pack copies drift from the recorded digest and the canonical graph is unreachable" >&2
    exit 1
fi

printf '%s  %s\n' "$CANON_SHA" "$SOURCE_DISPLAY" > "$RECORD"
echo "recorded $RECORD"
echo "RID graph sync: pack copies == $SOURCE_DISPLAY"
