#!/bin/sh
# setup-harmony-sdk.sh - obtain a DevEco-style HarmonyOS SDK root for the opt-in
# ARKTS_SDK_FLAVOR=harmony shell build (see scripts/build-arkts-shell.sh and
# docs/openharmony-hap-packaging.md "HarmonyOS SDK branch").
#
# Two modes:
#
#   --mock <dir>
#       Create a minimal offline fixture with the DevEco SDK layout - <dir>/default/
#       {openharmony/ets,hms/ets} plus sdk-pkg.json and hms/ets kit stubs. It is enough for
#       --print-config, --scaffold-only and scripts/selftest-build-arkts-shell.sh (path
#       resolution, externalApiPaths injection, runtimeOS/compatibleSdkVersion generation),
#       and it is deliberately NOT a compiler: the stubs do not declare MapComponent or any
#       other real kit API, so a hvigor build against the mock fails with ordinary ArkTS
#       "cannot find" errors. No network, no node.
#
#   --download [dir]
#       Fetch and unpack the DevEco Command Line Tools bundle (the whole ArkTS toolchain:
#       hvigor, ohpm, node and a complete HarmonyOS SDK with the hms/ets declarations) from
#       the public mirrors, pinned by sha256. Verified 2026-09-27:
#         6.0.1.251 (HarmonyOS 6.0.1 Release / API 21) via hf-mirror.com  sha256 e971348e...
#         6.1.1.300 (HarmonyOS 6.1.1 Release, newer hvigor) via github.com release
#       The bundle is linux-x64: on a non-x86_64 host the SDK declarations (hms/ets, the
#       openharmony/ets d.ts) are usable but its native es2abc is not, so a build there needs
#       the arm64 toolchain of a local OpenHarmony SDK (the p2-harmony hybrid, 2026-09-27).
#       --url <url> and --sha256 <hash> override the pinned default; --size <bytes> checks the
#       size too. The unpacked SDK home is printed for DEVECO_SDK_HOME/ARKTS_HARMONY_SDK_ROOT.
#
# Requirements: curl, python3, tar; download needs network and ~6 GB free for the extraction.
set -e

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

usage() {
    cat <<'EOF'
usage: setup-harmony-sdk.sh --mock <dir>
       setup-harmony-sdk.sh --download [dir] [--url <url>] [--sha256 <hash>] [--size <bytes>]

  --mock <dir>          write the minimal offline SDK fixture into <dir> (no network)
  --download [dir]      fetch the pinned public DevEco command-line-tools bundle into
                        <dir>/command-line-tools (default dir: .harmony-sdk)
  --url <url>           override the download URL (with --download)
  --sha256 <hash>       override the expected sha256 (with --download; '' skips the check)
  --size <bytes>        also check the downloaded size (with --download)
EOF
}

# ---- pinned mirrors (verified 2026-09-27, see the header) --------------------------------
CLT_VERSION_DEFAULT=6.0.1.251
CLT_URL_DEFAULT="https://hf-mirror.com/csukuangfj/harmonyos-commandline-tools/resolve/main/commandline-tools-linux-x64-6.0.1.251.zip"
CLT_SHA_DEFAULT="e971348eabe959b41b1d07fae037b3cc53ab2c0a8306f0895357dd45f98ad421"
CLT_SIZE_DEFAULT=2108510902

# sha256_file <file>: sha256sum when present, python3 otherwise.
sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"
    fi
}

# ---- mock mode ---------------------------------------------------------------------------
# The mock mirrors the DevEco command-line-tools shape that the harmony branch must accept:
# openharmony/ets/oh-uni-package.json carries apiVersion + version but *no* platformVersion
# (that lives in default/sdk-pkg.json), and hms/ets carries uni-package.json, sdkConfig.json,
# kits/@kit.*.d.ts and api/@hms.*.d.ts.
write_mock_sdk() {
    _dir="$1"
    mkdir -p "$_dir/default/openharmony/ets/api" "$_dir/default/openharmony/ets/kits" \
             "$_dir/default/openharmony/ets/arkts" "$_dir/default/openharmony/ets/component" \
             "$_dir/default/hms/ets/kits" "$_dir/default/hms/ets/api"

    cat > "$_dir/default/openharmony/ets/oh-uni-package.json" <<'EOF'
{
  "apiVersion": "23",
  "displayName": "Ets",
  "meta": { "metaVersion": "3.0.0" },
  "path": "ets",
  "releaseType": "Release",
  "version": "6.1.0.105"
}
EOF
    cat > "$_dir/default/sdk-pkg.json" <<'EOF'
{
  "meta": { "version": "1.0.0" },
  "data": {
    "apiVersion": "23",
    "displayName": "HarmonyOS 6.1.0 (mock)",
    "path": "HarmonyOS-6.1.0",
    "platformVersion": "6.1.0",
    "releaseType": "Release",
    "version": "6.1.0.105",
    "stage": "Release"
  }
}
EOF
    cat > "$_dir/default/hms/ets/uni-package.json" <<'EOF'
{
  "apiVersion": "23",
  "displayName": "HarmonyOS HMS (mock)",
  "meta": { "metaVersion": "3.1.0" },
  "path": "ets",
  "platformVersion": "6.1.0",
  "releaseType": "Release",
  "version": "6.1.0.105"
}
EOF
    cat > "$_dir/default/hms/ets/sdkConfig.json" <<'EOF'
{
  "apiPath": ["./api", "./kits"],
  "prefix": "@hms",
  "osName": "HarmonyOS"
}
EOF

    # Minimal kit stubs: each file only proves the hms/ets path and module name resolve. They
    # intentionally declare no real API - compiling the shell against them must fail with
    # ordinary ArkTS errors (that is the mock's documented boundary, not a bug).
    _stub_note='/* Mock declaration written by scripts/setup-harmony-sdk.sh --mock. Structure only, not the real kit API; a hvigor build against this fixture is expected to fail on missing members. */'
    for _kit in MapKit LiveViewKit ShareKit ScanKit PushKit AccountKit CoreSpeechKit; do
        case "$_kit" in
            MapKit)        _dts='export declare const map: unknown;\nexport declare const MapComponent: unknown;' ;;
            LiveViewKit)   _dts='export declare const liveViewManager: unknown;' ;;
            ShareKit)      _dts='export declare const systemShare: unknown;' ;;
            ScanKit)       _dts='export declare const scanBarcode: unknown;' ;;
            PushKit)       _dts='export declare const pushService: unknown;' ;;
            AccountKit)    _dts='export declare const authentication: unknown;' ;;
            CoreSpeechKit) _dts='export declare const textToSpeech: unknown;' ;;
        esac
        {
            printf '%s\n' "$_stub_note"
            printf '%s\n' "$_dts" | while IFS= read -r _line; do printf '%s\n' "$_line"; done
        } > "$_dir/default/hms/ets/kits/@kit.$_kit.d.ts"
        # One api stub per kit so the kit modules look like the real re-export shape.
        printf '%s\nexport {};\n' "$_stub_note" > "$_dir/default/hms/ets/api/@hms.mock.$_kit.d.ts"
    done
    printf '%s\n' "$_stub_note" > "$_dir/default/hms/ets/api/@hms.core.map.MapComponent.d.ets"
    printf '%s\n' "$_stub_note" > "$_dir/default/hms/ets/api/@hms.ai.textToSpeech.d.ts"
}

# ---- download mode -----------------------------------------------------------------------
# Prefers unzip; falls back to python3's zipfile (the bundle has ~100k entries and unzip is
# not part of every minimal device root).
unpack_zip() {
    _zip="$1"; _dest="$2"
    if command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$_zip" -d "$_dest"
    else
        python3 - "$_zip" "$_dest" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
    fi
}

download_mock_sdk() {
    _dir="$1"; _url="$2"; _sha="$3"; _size="$4"
    mkdir -p "$_dir"
    _tgz="$_dir/commandline-tools-linux-x64.zip"
    if [ -f "$_tgz" ] && [ -n "$_sha" ] && [ "$(sha256_file "$_tgz")" = "$_sha" ]; then
        info "using the cached bundle (sha256 verified): $_tgz"
    else
        info "downloading $_url"
        rm -f "$_tgz.part"
        curl -fL --retry 3 -C - -o "$_tgz.part" "$_url" || die "download failed: $_url"
        mv "$_tgz.part" "$_tgz"
    fi
    if [ -n "$_size" ]; then
        _have_size="$(wc -c < "$_tgz" | tr -d ' ')"
        [ "$_have_size" = "$_size" ] || die "size mismatch for $_tgz: expected $_size, got $_have_size"
    fi
    if [ -n "$_sha" ]; then
        _have="$(sha256_file "$_tgz")"
        [ "$_have" = "$_sha" ] || die "sha256 mismatch for $_tgz
  expected $_sha
  actual   $_have
  refusing to unpack; delete the file and retry, or pass --sha256 '' to skip the check"
    else
        info "WARNING: no sha256 pin given; unpacking an unverified bundle"
    fi
    rm -rf "$_dir/command-line-tools"
    info "unpacking (this takes a few minutes and ~6 GB)"
    unpack_zip "$_tgz" "$_dir"
    [ -d "$_dir/command-line-tools/sdk/default/openharmony/ets" ] \
        || die "unexpected bundle layout: $_dir/command-line-tools/sdk/default/openharmony/ets is missing"
    [ -d "$_dir/command-line-tools/sdk/default/hms/ets" ] \
        || die "unexpected bundle layout: $_dir/command-line-tools/sdk/default/hms/ets is missing"
    info "DevEco command-line tools ready: $_dir/command-line-tools"
    if [ "$(uname -m)" != "x86_64" ]; then
        info "WARNING: this bundle is linux-x64; $(uname -m) cannot run its native es2abc."
        info "         The SDK declarations work, but pair them with the arm64 toolchain of a"
        info "         local OpenHarmony SDK for a real compile (see docs/openharmony-hap-packaging.md)."
    fi
    printf 'DEVECO_SDK_HOME=%s/command-line-tools/sdk\n' "$_dir"
    printf 'ARKTS_HARMONY_SDK_ROOT=%s/command-line-tools/sdk\n' "$_dir"
}

# ---- argument parsing --------------------------------------------------------------------
MODE=""
DIR=""
URL="$CLT_URL_DEFAULT"
SHA="$CLT_SHA_DEFAULT"
SIZE="$CLT_SIZE_DEFAULT"

while [ $# -gt 0 ]; do
    case "$1" in
        --mock)      [ -n "${2:-}" ] || die "--mock needs a directory"; MODE=mock; DIR="$2"; shift 2 ;;
        --download)  MODE=download; shift
                     if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then DIR="$1"; shift; fi ;;
        --url)       [ -n "${2:-}" ] || die "--url needs a value"; URL="$2"; shift 2 ;;
        --sha256)    SHA="${2:-}"; shift 2 ;;
        --size)      [ -n "${2:-}" ] || die "--size needs a value"; SIZE="$2"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *)           usage >&2; die "unknown argument: $1" ;;
    esac
done

case "$MODE" in
    mock)
        [ -n "$DIR" ] || die "--mock needs a directory"
        write_mock_sdk "$DIR"
        info "mock HarmonyOS SDK written: $DIR (structure only - not a compiler)"
        info "check it with:"
        printf '    ARKTS_SDK_FLAVOR=harmony ARKTS_HARMONY_SDK_ROOT=%s sh scripts/build-arkts-shell.sh --print-config\n' "$DIR"
        printf '    ARKTS_SDK_FLAVOR=harmony ARKTS_HARMONY_SDK_ROOT=%s sh scripts/build-arkts-shell.sh --scaffold-only /tmp/scaffold\n' "$DIR"
        ;;
    download)
        [ -n "$DIR" ] || DIR=.harmony-sdk
        [ "$SIZE" != "$CLT_SIZE_DEFAULT" ] || [ "$URL" = "$CLT_URL_DEFAULT" ] || SIZE=""
        download_mock_sdk "$DIR" "$URL" "$SHA" "$SIZE"
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac
