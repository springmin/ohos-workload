#!/bin/sh
# Writes dist/SHA256SUMS for every release artifact (bundle, signed/unsigned haps, shell archive).
set -e
W="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$W/dist/SHA256SUMS"
: > "$OUT"
for f in \
  "$W"/dist/openharmony-workload-*.tar.gz \
  "$W"/dist/ets/modules.abc \
  "$W"/test/hello-maui-app/bin/Release/*/openharmony-arm64/*.hap
do
  [ -f "$f" ] || continue
  sha256sum "$f" >> "$OUT"
done
cat "$OUT"
