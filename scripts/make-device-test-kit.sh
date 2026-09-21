#!/bin/sh
# Builds and assembles the OpenHarmony MAUI device-test kit (the "delivery kit"):
#
#   4 signed haps     hello-maui-app.hap                (26.0 band, no extra permissions)
#                     hello-maui-app-permissions.hap    (26.0 band, +5 permissions)
#                     hello-maui-app-api20.hap          (20.0 band, no extra permissions)
#                     hello-maui-app-api20-permissions.hap
#   1 unsigned hap    hello-maui-app-unsigned.hap       (26.0 band, default payload)
#   8 docs            验收说明.md 快速开始.md 真机操作手册.md 文档索引.md 签名与UDID指南.md
#                     自签说明.md 最终状态.md README-交付说明.md
#   1 verifier        verify-kit.sh                    (tester self-check: sha256sum -c + hap summary)
#   SHA256SUMS        checksum of every hap + doc + verify-kit.sh in the kit
#   <out>.tar.gz      the kit root, packed flat (tar -C <kit> .)
#
# The haps are (re)published from test/hello-maui-app for both API bands with and without
# OpenHarmonyExtraPermissions, using <dist-dir>/ets/modules.abc as the ArkTS shell; each
# publish lands in test/hello-maui-app/bin/Release/<tfm>/openharmony-arm64/ and is copied
# into the kit right away. The 20.0 publishes use the TargetFrameworks/TargetFramework
# override documented in the acceptance doc (test/hello-maui-app multi-targets).
# Signing embeds a timestamp, so a rebuilt kit has fresh hap hashes - SHA256SUMS is always
# regenerated, never carried over.
#
# Usage: scripts/make-device-test-kit.sh [--kit-dir <dir>] [--dist-dir <dir>]
#          [--out <tar.gz>] [--skip-tar] [--publish]
#
#   --kit-dir <dir>   kit directory (default $DEVICE_TEST_KIT_DIR, else
#                     /data/storage/el2/base/tmp/opencode/device-test-kit)
#   --dist-dir <dir>  repo dist dir holding ets/modules.abc (default <repo>/dist)
#   --out <tar.gz>    tarball (default <kit-dir>.tar.gz)
#   --skip-tar        assemble the kit directory only
#   --publish         publish the tarball via scripts/publish-workload-release.sh
#
# Env: DOTNET (dotnet host, default: dotnet), RUNTIME_OHOS_PLANS (runtime-ohos docs/plans,
#      default: the sibling checkout's docs/plans).
#
# The kit directory is rebuilt from scratch in a staging dir and swapped in, so stale
# files cannot leak into SHA256SUMS. scripts/verify-kit.sh is always copied in from the
# repo (a tester can run `sh verify-kit.sh` inside the extracted kit; it is covered by
# SHA256SUMS like every other file). The two kit-only docs (自签说明.md, README-交付说明.md)
# are reused from the kit directory; when absent there the mirrored docs/plans copies
# (2026-09-21-ohos-tester-selfsign.md, 2026-09-21-ohos-delivery-kit-readme.md) are used.
# The operator-facing docs come from docs/plans as well: 2026-09-21-ohos-device-run-playbook.md
# ships as 真机操作手册.md and 2026-09-21-ohos-final-status.md ships as 最终状态.md; the
# SHA256SUMS glob below (*.md) picks every shipped doc up, so verify-kit.sh needs no change.
set -e

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

W="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$W/test/hello-maui-app"
DOTNET="${DOTNET:-dotnet}"
DEFAULT_KIT_DIR=/data/storage/el2/base/tmp/opencode/device-test-kit
KIT_DIR="${DEVICE_TEST_KIT_DIR:-$DEFAULT_KIT_DIR}"
DIST_DIR="$W/dist"
RUNTIME_PLANS="${RUNTIME_OHOS_PLANS:-$(dirname "$W")/runtime-ohos/docs/plans}"
VERIFY_KIT_SRC="$W/scripts/verify-kit.sh"
OUT=""
SKIP_TAR=0
PUBLISH=0

# Delivery permissions for the two "permissions" variants (acceptance doc 1b).
PERMS="ohos.permission.ACCESS_BLUETOOTH;ohos.permission.PRINT;ohos.permission.READ_CONTACTS;ohos.permission.READ_CALENDAR;ohos.permission.WRITE_CALENDAR"

usage() {
    cat <<EOF
usage: $0 [--kit-dir <dir>] [--dist-dir <dir>] [--out <tar.gz>] [--skip-tar] [--publish]

Builds the 4 signed + 1 unsigned demo haps, copies the acceptance/signing/operator docs and
the tester self-check script, writes SHA256SUMS and packs the kit tarball.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --kit-dir)  shift; KIT_DIR="$1" ;;
        --dist-dir) shift; DIST_DIR="$1" ;;
        --out)      shift; OUT="$1" ;;
        --skip-tar) SKIP_TAR=1 ;;
        --publish)  PUBLISH=1 ;;
        -h|--help)  usage; exit 0 ;;
        *) warn "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
    shift
done

case "$KIT_DIR" in
    ""|"/"|"."|"..") warn "invalid kit dir: '$KIT_DIR'"; exit 2 ;;
esac
[ -n "$OUT" ] || OUT="$(dirname "$KIT_DIR")/$(basename "$KIT_DIR").tar.gz"
if [ "$SKIP_TAR" = 1 ] && [ "$PUBLISH" = 1 ]; then
    warn "--publish needs a tarball (drop --skip-tar)"; exit 2
fi

command -v "$DOTNET" >/dev/null 2>&1 || { warn "dotnet not found: $DOTNET (set DOTNET=)"; exit 1; }
[ -d "$PROJ" ] || { warn "demo project not found: $PROJ"; exit 1; }
[ -f "$DIST_DIR/ets/modules.abc" ] || {
    warn "ArkTS shell not found: $DIST_DIR/ets/modules.abc (run scripts/build-arkts-shell.sh or set --dist-dir)"
    exit 1
}
[ -f "$VERIFY_KIT_SRC" ] || {
    warn "kit verifier not found: $VERIFY_KIT_SRC (expected in a full checkout)"
    exit 1
}

# Kit-only docs: prefer the kit directory itself (possibly a previous run), fall back to
# the default kit dir, then to the docs/plans mirrors added for the same purpose.
KIT_DOC_SRC="$KIT_DIR"
if [ ! -f "$KIT_DOC_SRC/自签说明.md" ] || [ ! -f "$KIT_DOC_SRC/README-交付说明.md" ]; then
    if [ "$KIT_DIR" != "$DEFAULT_KIT_DIR" ] &&
       [ -f "$DEFAULT_KIT_DIR/自签说明.md" ] && [ -f "$DEFAULT_KIT_DIR/README-交付说明.md" ]; then
        KIT_DOC_SRC="$DEFAULT_KIT_DIR"
    fi
fi
SELF_SIGN_SRC="$KIT_DOC_SRC/自签说明.md"
[ -f "$SELF_SIGN_SRC" ] || SELF_SIGN_SRC="$RUNTIME_PLANS/2026-09-21-ohos-tester-selfsign.md"
KIT_README_SRC="$KIT_DOC_SRC/README-交付说明.md"
[ -f "$KIT_README_SRC" ] || KIT_README_SRC="$RUNTIME_PLANS/2026-09-21-ohos-delivery-kit-readme.md"

need_file() {
    [ -f "$1" ] || { warn "missing input: $1${2:+ ($2)}"; exit 1; }
}

STAGE="$KIT_DIR.stage.$$"
LOG_DIR="$STAGE/.logs"
trap 'rm -rf "$STAGE"' 0 1 2 15
rm -rf "$STAGE"
mkdir -p "$STAGE" "$LOG_DIR"

# publish one band/permissions combination; output stays in the bin dir for copy_hap.
publish_variant() {
    _tfm="$1"; _perms="$2"
    if [ -n "$_perms" ]; then
        log "== publishing $_tfm with extra permissions =="
    else
        log "== publishing $_tfm =="
    fi
    set -- "$PROJ" -c Release -r openharmony-arm64 -m:1 \
        -p:OpenHarmonyUIPage=pages/Index \
        -p:OpenHarmonyArktsModulesAbc="$DIST_DIR/ets/modules.abc" \
        -p:OpenHarmonyHapPackage=true
    if [ "$_tfm" = "net11.0-openharmony20.0" ]; then
        # documented repro for the API 20 band override (the project multi-targets)
        set -- "$@" -p:TargetFrameworks="net11.0-openharmony20.0" -p:TargetFramework="net11.0-openharmony20.0"
    else
        set -- "$@" -f "$_tfm"
    fi
    if [ -n "$_perms" ]; then
        set -- "$@" "-p:OpenHarmonyExtraPermissions=\"$_perms\""
    fi
    _log="$LOG_DIR/publish-$_tfm${_perms:+_permissions}.log"
    if ! "$DOTNET" publish "$@" > "$_log" 2>&1; then
        warn "publish failed: $_tfm (log: $_log)"
        tail -20 "$_log" >&2
        exit 1
    fi
}

# make sure the generated module.json really carries the requested permissions
check_permissions() {
    python3 - "$1" "$PERMS" <<'PY' || { warn "permission check failed: $1"; exit 1; }
import json, sys, zipfile
hap, want = sys.argv[1], sys.argv[2].split(';')
with zipfile.ZipFile(hap) as z:
    got = [p.get('name') for p in json.loads(z.read('module.json'))['module'].get('requestPermissions', [])]
missing = [p for p in want if p not in got]
if missing:
    print('missing permissions: ' + ', '.join(missing), file=sys.stderr)
    sys.exit(1)
PY
}

copy_hap() {
    need_file "$1"
    cp -f "$1" "$STAGE/$2"
    log "hap     $2  $(sha256sum "$1" | cut -d' ' -f1)"
}

copy_doc() {
    need_file "$1"
    cp -f "$1" "$STAGE/$2"
    log "doc     $2  <- $1"
}

copy_tool() {
    need_file "$1"
    cp -f "$1" "$STAGE/$2"
    log "script  $2  <- $1"
}

BIN26="$PROJ/bin/Release/net11.0-openharmony26.0/openharmony-arm64"
BIN20="$PROJ/bin/Release/net11.0-openharmony20.0/openharmony-arm64"

# 26.0 default: also supplies the unsigned 26.0 default hap.
publish_variant net11.0-openharmony26.0 ""
copy_hap "$BIN26/hello-maui-app.hap" "hello-maui-app.hap"
copy_hap "$BIN26/hello-maui-app-unsigned.hap" "hello-maui-app-unsigned.hap"

publish_variant net11.0-openharmony26.0 "$PERMS"
check_permissions "$BIN26/hello-maui-app.hap"
copy_hap "$BIN26/hello-maui-app.hap" "hello-maui-app-permissions.hap"

publish_variant net11.0-openharmony20.0 ""
copy_hap "$BIN20/hello-maui-app.hap" "hello-maui-app-api20.hap"

publish_variant net11.0-openharmony20.0 "$PERMS"
check_permissions "$BIN20/hello-maui-app.hap"
copy_hap "$BIN20/hello-maui-app.hap" "hello-maui-app-api20-permissions.hap"

log "== copying docs =="
copy_doc "$RUNTIME_PLANS/2026-09-19-ohos-hap-acceptance-for-testers.md" "验收说明.md"
copy_doc "$RUNTIME_PLANS/2026-09-20-ohos-tester-quickstart.md" "快速开始.md"
copy_doc "$RUNTIME_PLANS/2026-09-21-ohos-device-run-playbook.md" "真机操作手册.md"
copy_doc "$RUNTIME_PLANS/README.md" "文档索引.md"
copy_doc "$RUNTIME_PLANS/2026-09-19-ohos-signing-and-udid-guide.md" "签名与UDID指南.md"
copy_doc "$SELF_SIGN_SRC" "自签说明.md"
copy_doc "$RUNTIME_PLANS/2026-09-21-ohos-final-status.md" "最终状态.md"
copy_doc "$KIT_README_SRC" "README-交付说明.md"

log "== copying the tester self-check =="
copy_tool "$VERIFY_KIT_SRC" "verify-kit.sh"

log "== generating SHA256SUMS =="
rm -rf "$LOG_DIR"
(
    cd "$STAGE"
    LC_ALL=C
    export LC_ALL
    sha256sum *.hap *.md verify-kit.sh > SHA256SUMS
)
( cd "$STAGE" && sha256sum -c SHA256SUMS >/dev/null ) || { warn "SHA256SUMS self-check failed"; exit 1; }
log "SHA256SUMS: $(wc -l < "$STAGE/SHA256SUMS" | tr -d ' ') entries, sha256sum -c OK"

# swap the freshly assembled kit in (old kit removed only now)
rm -rf "$KIT_DIR"
mv "$STAGE" "$KIT_DIR"
trap - 0 1 2 15
log "kit directory: $KIT_DIR"

if [ "$SKIP_TAR" = 0 ]; then
    log "== packing the tarball =="
    rm -f "$OUT"
    tar -czf "$OUT" -C "$KIT_DIR" .
    log "tar:    $OUT"
    log "size:   $(wc -c < "$OUT" | tr -d ' ') bytes"
    log "sha256: $(sha256sum "$OUT" | cut -d' ' -f1)"
else
    log "tar skipped (--skip-tar)"
fi

if [ "$PUBLISH" = 1 ]; then
    log "== publishing the kit (scripts/publish-workload-release.sh) =="
    DEVICE_TEST_KIT="$OUT" sh "$W/scripts/publish-workload-release.sh"
fi

log "== done =="
log "hint:   tester self-check inside the kit: (cd $KIT_DIR && sh verify-kit.sh)"
