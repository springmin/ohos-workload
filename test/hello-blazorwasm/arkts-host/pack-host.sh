#!/bin/sh
# Packs the ArkTS ArkWeb host (project/) around a published Blazor site, signs the hap and
# verifies the signature.
#
# No DevEco Studio is required: hvigor comes from the in-repo toolchain that
# scripts/build-arkts-shell.sh installs (.arkts-build) and the packing/signing tools come from
# the OpenHarmony SDK's toolchains/lib (ohos_packing_tool / hap-sign-tool). The host page
# (project/entry/src/main/ets/pages/Index.ets) serves the site from resources/rawfile through
# Web.onInterceptRequest, the same asset-serving pattern the in-product HybridWebView bridge
# uses.
#
# hvigor's own PackageHap step is allowed to fail (some SDK/toolchain combinations ship only
# the native ohos_packing_tool, not app_packing_tool.jar, which the hvigor plugin expects);
# the script mirrors scripts/build-arkts-shell.sh and tolerates a PackageHap failure as long
# as CompileArkTS finished, then packs the hvigor intermediates itself.
#
# usage: pack-host.sh <site-dir> [options]
#   <site-dir>        published Blazor site: the directory holding index.html
#                     (normally <publish>/wwwroot; see ../run-smoke.sh)
#   --out <hap>       output hap (default <arkts-host>/out/hello-blazorwasm-host-signed.hap)
#   --work <dir>      scratch dir (default <arkts-host>/out/host-work)
#   --bundle <name>   bundle name (default com.example.opendotnet)
#   --help
# env:
#   OHOS_SDK_ROOT / OHOS_SDK   OpenHarmony SDK root (default: newest harmonybrew Cellar
#                              ohos-sdk install; must hold toolchains/lib/{ohos_packing_tool,
#                              hap-sign-tool,hap-sign-tool material})
#   HVIGOR_JS                  hvigor entry point (default
#                              <repo>/.arkts-build/hvigor/node_modules/@ohos/hvigor/bin/hvigor.js)
#   HVIGOR_NODE                node binary (default: the harmonybrew node, then the PATH
#                              node; the OpenHarmony NODE=/data/service/hnp/bin/node is
#                              refused because that build crashes hvigor at startup)
#   NODE_HOME                  nodejs.dir written to local.properties (default ~/.harmonybrew)
#   ARKTS_PLATFORM_VERSION     SDK version directory (default 26.0.0)
#   SIGN_KEY_ALIAS             app signing alias (default "OpenHarmony Application Release")
#   SIGN_PROFILE_ALIAS         profile signing alias (default "openharmony application profile debug")
#   SIGN_KEY_PWD / SIGN_STORE_PWD   keystore passwords (default 123456)
set -e

SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../../.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "== $* =="; }

SITE=""
OUT=""
WORK=""
BUNDLE="com.example.opendotnet"
while [ $# -gt 0 ]; do
    case "$1" in
        --out) shift; OUT="${1:-}" ;;
        --work) shift; WORK="${1:-}" ;;
        --bundle) shift; BUNDLE="${1:-}" ;;
        --help|-h) sed -n '2,40p' "$0"; exit 0 ;;
        -*) die "unknown option: $1 (see --help)" ;;
        *) [ -z "$SITE" ] || die "only one site directory may be given"; SITE="$1" ;;
    esac
    shift
done
[ -n "$SITE" ] || die "usage: pack-host.sh <site-dir> [--out <hap>] [--work <dir>] [--bundle <name>]"
[ -f "$SITE/index.html" ] || die "$SITE does not look like a Blazor site (no index.html)"
SITE="$(cd "$SITE" && pwd)"
OUT="${OUT:-$SELF/out/hello-blazorwasm-host-signed.hap}"
WORK="${WORK:-$SELF/out/host-work}"

# ---- tools -----------------------------------------------------------------
if [ -z "${OHOS_SDK_ROOT:-}" ]; then
    OHOS_SDK_ROOT="${OHOS_SDK:-}"
fi
if [ -z "$OHOS_SDK_ROOT" ]; then
    for c in "$HOME"/.harmonybrew/Cellar/ohos-sdk/*/ "$HOME"/.harmonybrew/Cellar/ohos-sdk@*/*/; do
        [ -x "$c/toolchains/lib/ohos_packing_tool" ] && [ -z "$OHOS_SDK_ROOT" ] && OHOS_SDK_ROOT="$c"
    done
fi
[ -n "$OHOS_SDK_ROOT" ] && [ -x "$OHOS_SDK_ROOT/toolchains/lib/ohos_packing_tool" ] \
    || die "no OpenHarmony SDK found; set OHOS_SDK_ROOT (needs toolchains/lib/ohos_packing_tool)"
PACK_TOOL="$OHOS_SDK_ROOT/toolchains/lib/ohos_packing_tool"
SIGN_TOOL="$OHOS_SDK_ROOT/toolchains/lib/hap-sign-tool"
SIGN_LIB="$OHOS_SDK_ROOT/toolchains/lib"
for f in "$SIGN_TOOL" "$SIGN_LIB/OpenHarmony.p12" "$SIGN_LIB/OpenHarmonyApplication.pem" \
         "$SIGN_LIB/OpenHarmonyProfileDebug.pem" "$SIGN_LIB/UnsgnedDebugProfileTemplate.json"; do
    [ -e "$f" ] || die "signing material missing: $f"
done

HVIGOR_JS="${HVIGOR_JS:-$ROOT/.arkts-build/hvigor/node_modules/@ohos/hvigor/bin/hvigor.js}"
[ -f "$HVIGOR_JS" ] || die "hvigor entry point not found (run scripts/build-arkts-shell.sh once, or set HVIGOR_JS); looked at $HVIGOR_JS"
HVIGOR_MODULES="$(dirname "$(dirname "$(dirname "$(dirname "$HVIGOR_JS")")")")"
[ -d "$HVIGOR_MODULES/@ohos/hvigor-ohos-plugin" ] || die "hvigor plugin not found under $HVIGOR_MODULES"

# Node selection: the OpenHarmony device environment exports NODE=/data/service/hnp/bin/node
# (v24), and that build crashes hvigor at startup (V8 "Check failed: 12 == errno" in the V8
# startup path) - so $NODE is deliberately not the default. Prefer an explicit HVIGOR_NODE,
# then the harmonybrew node, then PATH; refuse the hnp node up front with a clear message.
NODE_BIN="${HVIGOR_NODE:-}"
if [ -z "$NODE_BIN" ] && [ -x "$HOME/.harmonybrew/bin/node" ]; then
    NODE_BIN="$HOME/.harmonybrew/bin/node"
fi
if [ -z "$NODE_BIN" ]; then
    NODE_BIN="$(command -v node 2>/dev/null || true)"
fi
[ -n "$NODE_BIN" ] || die "no node found (set HVIGOR_NODE=/path/to/node, needs node >= 18)"
case "$NODE_BIN" in
    /data/service/hnp/*)
        die "refusing the OpenHarmony hnp node ($NODE_BIN): it crashes hvigor; set HVIGOR_NODE=/path/to/node (e.g. \$HOME/.harmonybrew/bin/node)" ;;
esac

PLATFORM_VERSION="${ARKTS_PLATFORM_VERSION:-26.0.0}"
KEY_ALIAS="${SIGN_KEY_ALIAS:-OpenHarmony Application Release}"
PROFILE_ALIAS="${SIGN_PROFILE_ALIAS:-openharmony application profile debug}"
KEY_PWD="${SIGN_KEY_PWD:-123456}"
STORE_PWD="${SIGN_STORE_PWD:-123456}"

# ---- stage the project -----------------------------------------------------
info "staging the host project in $WORK"
rm -rf "$WORK"
mkdir -p "$WORK/.signing" "$WORK/sdk/$PLATFORM_VERSION"
cp -a "$SELF/project" "$WORK/project"
for c in ets js native previewer toolchains; do
    [ -e "$OHOS_SDK_ROOT/$c" ] && ln -s "$OHOS_SDK_ROOT/$c" "$WORK/sdk/$PLATFORM_VERSION/$c"
done
printf 'sdk.dir=%s\nnodejs.dir=%s\n' "$WORK/sdk" "${NODE_HOME:-$HOME/.harmonybrew}" > "$WORK/project/local.properties"
ln -sfn "$HVIGOR_MODULES" "$WORK/project/node_modules"

cat > "$WORK/project/build-profile.json5" <<EOF
{
  app: {
    signingConfigs: [
      {
        name: 'default',
        type: 'OpenHarmony',
        material: {
          certpath: '$SIGN_LIB/OpenHarmonyApplication.pem',
          storePassword: '$STORE_PWD',
          keyAlias: '$KEY_ALIAS',
          keyPassword: '$KEY_PWD',
          profile: '$WORK/.signing/debug.p7b',
          signAlg: 'SHA256withECDSA',
          storeFile: '$SIGN_LIB/OpenHarmony.p12',
        },
      },
    ],
    products: [
      {
        name: 'default',
        compileSdkVersion: '$PLATFORM_VERSION',
        compatibleSdkVersion: '18',
        targetSdkVersion: '$PLATFORM_VERSION',
        runtimeOS: 'OpenHarmony',
      },
    ],
    buildModeSet: [{ name: 'debug' }, { name: 'release' }],
  },
  modules: [
    { name: 'entry', srcPath: './entry', targets: [{ name: 'default', applyToProducts: ['default'] }] },
  ],
}
EOF

info "embedding the site into resources/rawfile/blazor"
RAW="$WORK/project/entry/src/main/resources/rawfile"
rm -rf "$RAW/blazor"
mkdir -p "$RAW"
cp -a "$SITE" "$RAW/blazor"

# ---- build (CompileArkTS; hvigor's PackageHap may fail, see the header) ----
info "running hvigor"
sync
hvigor_build() {
    ( cd "$WORK/project" && timeout 1800 "$NODE_BIN" "$HVIGOR_JS" --mode module -p product=default assembleHap --no-daemon ) \
        > "$WORK/hvigor.log" 2>&1 || true
}
hvigor_build
if ! grep -q "Finished :entry:default@CompileArkTS" "$WORK/hvigor.log" \
        && grep -qE "Fatal error in|Check failed" "$WORK/hvigor.log"; then
    # Transient V8 startup failure (allocation/errno check) seen on the OpenHarmony device
    # right after the large rawfile copy; retry once before giving up.
    cp "$WORK/hvigor.log" "$WORK/hvigor.attempt1.log"
    echo "   note: hvigor aborted before compiling (transient V8 failure); retrying once"
    sync
    sleep 2
    hvigor_build
fi
if ! grep -q "Finished :entry:default@CompileArkTS" "$WORK/hvigor.log"; then
    echo "--- hvigor.log (tail) ---" >&2
    tail -25 "$WORK/hvigor.log" >&2
    die "hvigor CompileArkTS did not finish (full log: $WORK/hvigor.log)"
fi
if grep -q "ERROR: Failed :entry:default@PackageHap" "$WORK/hvigor.log"; then
    echo "   note: hvigor's PackageHap failed (expected on toolchains without app_packing_tool.jar);"
    echo "         the native ohos_packing_tool packs the intermediates instead"
fi

# ---- pack ------------------------------------------------------------------
B="$WORK/project/entry/build/default"
LIBS="$B/intermediates/stripped_native_libs/default"
if [ ! -d "$LIBS" ]; then
    mkdir -p "$WORK/empty-libs"
    LIBS="$WORK/empty-libs"
fi
UNSIGNED="$WORK/entry-default-unsigned.hap"
PACK_ARGS="--mode hap --force true --lib-path $LIBS \
 --json-path $B/intermediates/package/default/module.json \
 --resources-path $B/intermediates/res/default/resources \
 --index-path $B/intermediates/res/default/resources.index \
 --pack-info-path $B/outputs/default/pack.info \
 --out-path $UNSIGNED \
 --ets-path $B/intermediates/loader_out/default/ets"
[ -e "$B/intermediates/syscap/default/rpcid.sc" ] && PACK_ARGS="$PACK_ARGS --rpcid-path $B/intermediates/syscap/default/rpcid.sc"
[ -e "$B/intermediates/loader/default/pkgSdkInfo.json" ] && PACK_ARGS="$PACK_ARGS --pkg-sdk-info-path $B/intermediates/loader/default/pkgSdkInfo.json"

info "packing (ohos_packing_tool)"
# shellcheck disable=SC2086  # word splitting is the point: PACK_ARGS is an argument list
"$PACK_TOOL" pack $PACK_ARGS > "$WORK/pack.log" 2>&1 || { tail -15 "$WORK/pack.log" >&2; die "packing failed (full log: $WORK/pack.log)"; }
[ -s "$UNSIGNED" ] || die "packing produced no hap"

# ---- sign ------------------------------------------------------------------
info "signing (hap-sign-tool)"
python3 - "$SIGN_LIB/UnsgnedDebugProfileTemplate.json" "$WORK/.signing/profile.json" "$BUNDLE" <<'PY'
import json, sys, time
src, dst, bundle = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, encoding='utf-8') as f:
    profile = json.load(f)
profile.setdefault('bundle-info', {})['bundle-name'] = bundle
now = int(time.time())
validity = profile.setdefault('validity', {})
validity['not-before'] = now - 86400
validity['not-after'] = now + 10 * 365 * 86400
with open(dst, 'w', encoding='utf-8') as f:
    json.dump(profile, f, indent=2, ensure_ascii=False)
    f.write('\n')
PY
"$SIGN_TOOL" sign-profile -mode localSign -keyAlias "$PROFILE_ALIAS" -signAlg SHA256withECDSA \
    -inFile "$WORK/.signing/profile.json" -profileCertFile "$SIGN_LIB/OpenHarmonyProfileDebug.pem" \
    -keystoreFile "$SIGN_LIB/OpenHarmony.p12" -keyPwd "$KEY_PWD" -keystorePwd "$STORE_PWD" \
    -outFile "$WORK/.signing/debug.p7b" > "$WORK/sign-profile.log" 2>&1 \
    || { tail -15 "$WORK/sign-profile.log" >&2; die "sign-profile failed (full log: $WORK/sign-profile.log)"; }

mkdir -p "$(dirname "$OUT")"
"$SIGN_TOOL" sign-app -mode localSign -keyAlias "$KEY_ALIAS" -signAlg SHA256withECDSA \
    -appCertFile "$SIGN_LIB/OpenHarmonyApplication.pem" -profileFile "$WORK/.signing/debug.p7b" \
    -inFile "$UNSIGNED" -outFile "$OUT" -signCode 1 \
    -keystoreFile "$SIGN_LIB/OpenHarmony.p12" -keyPwd "$KEY_PWD" -keystorePwd "$STORE_PWD" \
    > "$WORK/sign-app.log" 2>&1 \
    || { tail -15 "$WORK/sign-app.log" >&2; die "sign-app failed (full log: $WORK/sign-app.log)"; }

"$SIGN_TOOL" verify-app -inFile "$OUT" -outCertChain "$WORK/.signing/verify.cer" \
    -outProfile "$WORK/.signing/verify.p7b" > "$WORK/verify.log" 2>&1 \
    || { tail -15 "$WORK/verify.log" >&2; die "verify-app failed (full log: $WORK/verify.log)"; }

# ---- summary ---------------------------------------------------------------
RAW_COUNT=$(find "$RAW/blazor" -type f | wc -l | tr -d ' ')
SIZE=$(du -sh "$OUT" 2>/dev/null | awk '{print $1}')
SHA=$(python3 - "$OUT" <<'PY'
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], 'rb') as f:
    for chunk in iter(lambda: f.read(1 << 20), b''):
        h.update(chunk)
print(h.hexdigest())
PY
)
echo
echo "OK: $OUT"
echo "    size: $SIZE  sha256: $SHA"
echo "    bundle: $BUNDLE  embedded site files: $RAW_COUNT"
echo "    install: hdc install \"$OUT\" (or open the hap on the device)"
echo "    launch:  aa start -b $BUNDLE -a EntryAbility"
echo "    logs:    hilog | grep BlazorWebHost"
exit 0
