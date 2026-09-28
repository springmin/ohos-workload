#!/bin/sh
# Blazor WebAssembly publish smoke for the OpenHarmony SDK (test tree).
#
# Publishes test/hello-blazorwasm and verifies the static site that the ArkTS host in
# arkts-host/ embeds into resources/rawfile: the app shell (index.html), the Blazor boot
# script and the wasm payloads under _framework/. The publish recipe is documented in
# README.md; its version pins live in Directory.Build.targets and NuGet.config.
#
# The first publish runs WITHOUT the task-host override. If it fails with the OpenHarmony
# task-host error (MSB4216, "task host", the 30s x5 retry pattern) the script retries with
# -p:OhosTaskHostOverride=true, which runs the WebAssembly/ILLink tasks in-process. A SDK
# carrying the eng/ohos-install/build/msbuild-pipe-patch fix (sdk-ohos feature/openharmony,
# 2026-09-28) passes the first run without the override.
#
# usage: run-smoke.sh [--require] [--trim] [--skip-publish] [--out DIR]
#   DOTNET=/path/to/dotnet   dotnet to use (default: ~/.dotnet/dotnet, then PATH)
#
# Without --require, a publish blocked by restore (feed or pack unavailable) prints SKIP and
# exits 0, mirroring test/aot-smoke/run-smoke.sh. --require turns that into a failure, for
# CI-style use. --trim opts into the ILLink trimming pass (needs the rc.2 ILLink tool
# runtime, see README.md "Trimming").
set -e

SELF="$(cd "$(dirname "$0")" && pwd)"
DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"
[ -x "$DOTNET" ] || DOTNET="$(command -v dotnet 2>/dev/null || true)"
[ -n "$DOTNET" ] || { echo "ERROR: no dotnet found (set DOTNET=/path/to/dotnet)" >&2; exit 1; }

REQUIRE=0
TRIM=0
SKIP_PUBLISH=0
OUT="$SELF/out"
while [ $# -gt 0 ]; do
    case "$1" in
        --require) REQUIRE=1 ;;
        --trim) TRIM=1 ;;
        --skip-publish) SKIP_PUBLISH=1 ;;
        --out)
            shift
            [ -n "${1:-}" ] || { echo "ERROR: --out needs a directory" >&2; exit 2; }
            OUT="$1"
            ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
mkdir -p "$OUT"

TRIMARG="-p:PublishTrimmed=false"
[ "$TRIM" = 1 ] && TRIMARG="-p:PublishTrimmed=true"

publish() { # <name> <extra msbuild args...>
    name="$1"
    shift
    echo "== dotnet publish ($name): $DOTNET publish hello-blazorwasm.csproj -c Release -o $OUT/publish $TRIMARG $* =="
    "$DOTNET" publish "$SELF/hello-blazorwasm.csproj" -c Release -o "$OUT/publish" $TRIMARG "$@" \
        > "$OUT/publish-$name.log" 2>&1
}

if [ "$SKIP_PUBLISH" = 1 ]; then
    [ -f "$OUT/publish/wwwroot/index.html" ] || {
        echo "ERROR: --skip-publish but $OUT/publish/wwwroot/index.html is missing" >&2
        exit 1
    }
else
    echo "== dotnet: $("$DOTNET" --version 2>/dev/null || echo unknown) =="
    if publish plain; then
        echo "   publish succeeded without the task-host override"
    else
        if grep -qE 'MSB4216|[Tt]ask host' "$OUT/publish-plain.log"; then
            echo "== the first publish hit the OpenHarmony task-host failure; retrying with the in-process overrides =="
            if publish override -p:OhosTaskHostOverride=true; then
                echo "   publish succeeded WITH the in-process overrides (-p:OhosTaskHostOverride=true)"
                echo "   note: the installed SDK still needs eng/ohos-install/build/msbuild-pipe-patch for the default path"
            fi
        fi
    fi

    # Decide whether a failed publish is a restore-level SKIP or a real failure. Both logs
    # are inspected: the plain run is the one that decides.
    if [ ! -f "$OUT/publish/wwwroot/index.html" ]; then
        if grep -qhE 'NU1101|NU1102|NU1103|NU1301|NU1302|Unable to load the service index|Unable to find package' \
                "$OUT"/publish-plain.log "$OUT"/publish-override.log 2>/dev/null; then
            echo "SKIP: the Blazor/WebAssembly flight could not be restored (feed or pack unavailable)."
            echo "      Check NuGet.config (dnceng-dotnet11) and network access; see README.md 'Recipe'."
            [ "$REQUIRE" = 1 ] && exit 1
            exit 0
        fi
        echo "ERROR: publish failed; see $OUT/publish-plain.log" >&2
        echo "       (override retry log: $OUT/publish-override.log)" >&2
        exit 1
    fi
fi

# ---- verification ----------------------------------------------------------
WEB="$OUT/publish/wwwroot"
OK=0
for f in index.html _framework; do
    if [ ! -e "$WEB/$f" ]; then
        echo "MISS $f" >&2
        OK=1
    fi
done
if [ ! -e "$WEB/_framework/blazor.webassembly.js" ]; then
    if ! ls "$WEB"/_framework/blazor.webassembly*.js >/dev/null 2>&1; then
        echo "MISS _framework/blazor.webassembly*.js (the Blazor boot script)" >&2
        OK=1
    fi
fi
if ! ls "$WEB"/_framework/dotnet*.wasm >/dev/null 2>&1; then
    echo "MISS _framework/dotnet*.wasm (the .NET runtime payload)" >&2
    OK=1
fi
WASM_COUNT=$(ls "$WEB"/_framework/*.wasm 2>/dev/null | wc -l | tr -d ' ')
[ "$WASM_COUNT" -gt 0 ] || { echo "MISS no .wasm payloads under _framework/" >&2; OK=1; }
[ "$OK" = 0 ] || { echo "ERROR: the publish output is not a servable Blazor site (see above)" >&2; exit 1; }

FILE_COUNT=$(find "$WEB" -type f | wc -l | tr -d ' ')
SIZE=$(du -sh "$WEB" 2>/dev/null | awk '{print $1}')
echo
echo "OK: site at $WEB"
echo "    $FILE_COUNT files, $SIZE, $WASM_COUNT wasm payloads, trimming: $([ "$TRIM" = 1 ] && echo on || echo off)"
echo "    host it with: test/hello-blazorwasm/arkts-host/pack-host.sh \"$WEB\""
echo "    or serve it during development: python3 -m http.server --directory \"$WEB\" 8199"
exit 0
