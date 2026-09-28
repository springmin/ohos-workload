#!/bin/sh
# Runs the offline node unit tests for the ArkTS ArkWeb host page (no device, no SDK, no
# build). Node selection mirrors pack-host.sh: an explicit HVIGOR_NODE wins, then the
# harmonybrew node, then the PATH node; every candidate must pass a trivial `node -e` smoke
# test (the OpenHarmony environment's NODE=/data/service/hnp/bin/node aborts with a V8 fatal
# before it runs anything, so a bare $NODE is never trusted).
#
# usage: sh test/run-tests.sh   (from arkts-host/, or use the full path)
# env:   HVIGOR_NODE override, like pack-host.sh
set -e
SELF="$(cd "$(dirname "$0")" && pwd)"

node_runs() { sh -c '"$0" -e "process.exit(0)"' "$1" >/dev/null 2>&1; }
NODE_BIN=""
for cand in "${HVIGOR_NODE:-}" "$HOME/.harmonybrew/bin/node" "$(command -v node 2>/dev/null || true)"; do
    [ -n "$cand" ] || continue
    if node_runs "$cand"; then
        NODE_BIN="$cand"
        break
    fi
    echo "   note: node candidate $cand failed the smoke test; trying the next one" >&2
done
[ -n "$NODE_BIN" ] || {
    echo "ERROR: no runnable node found (set HVIGOR_NODE=/path/to/node; the test needs node >= 23.6)" >&2
    exit 1
}

echo "== node $("$NODE_BIN" -p 'process.version') : ArkWeb host rawfile-path unit tests =="
exec "$NODE_BIN" "$SELF/rawfile-path.test.mjs"
