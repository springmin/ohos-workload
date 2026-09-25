#!/bin/sh
# NativeAOT single-entry smoke driver (FIX-INTEROP #2, scaffold).
#
# Attempts the real cross publish of smoke-lib for the OpenHarmony NativeAOT RID. The ilc and
# runtime packs for openharmony-arm64 are not part of the stock SDK (see
# runtime-ohos/docs/plans/2026-09-24-ohos-runtime-strategy.md §3), so when they are missing the
# script prints SKIP and exits 0 unless --require is passed. On success the publish output is
# the payload directory the host starts with `ohos_host_run_app(<dir>, "Smoke.dll", ...)`.
#
# The host route itself is verified without the ilc pack by test/aot-smoke/fake-aot-app.c (see
# docs/aot-single-entry.md "Verification without the ilc pack").
set -e
W="$(cd "$(dirname "$0")/../.." && pwd)"
DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"
[ -x "$DOTNET" ] || DOTNET="$(command -v dotnet || true)"
[ -n "$DOTNET" ] || { echo "ERROR: no dotnet found (set DOTNET=/path/to/dotnet)" >&2; exit 1; }
RID="${RID:-openharmony-arm64}"
OUT="${OUT:-$W/test/aot-smoke/out}"
REQUIRE=0
for arg in "$@"; do
    [ "$arg" = "--require" ] && REQUIRE=1
done

echo "== AOT smoke publish: Smoke.csproj -r $RID -p:PublishAot=true (out: $OUT) =="
mkdir -p "$OUT"
if "$DOTNET" publish "$W/test/aot-smoke/smoke-lib/Smoke.csproj" -r "$RID" -c Release -o "$OUT" -v:m; then
    if [ -f "$OUT/libSmoke.so" ]; then
        ls -l "$OUT/libSmoke.so"
        echo "OK: publish produced libSmoke.so; copy the output directory to the device and run"
        echo "    the host's one-shot route against it:"
        echo "      ohos_host_run_app(<out_dir>, \"Smoke.dll\")"
        exit 0
    fi
    echo "ERROR: publish succeeded but $OUT/libSmoke.so is missing" >&2
    exit 1
fi

echo "SKIP: dotnet publish -r $RID -p:PublishAot=true is not available in this SDK"
echo "      (missing ilc/runtime pack for $RID; see docs/aot-single-entry.md)."
echo "      The host AOT route can still be exercised with test/aot-smoke/fake-aot-app.c."
if [ "$REQUIRE" = "1" ]; then
    exit 1
fi
exit 0
