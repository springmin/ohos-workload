#!/bin/sh
# Builds and signs the minimal accessibility client hap (test/a11y-client) with the official
# hvigor toolchain. Reuses the hvigor install and SDK layout of scripts/build-arkts-shell.sh but
# keeps its own project: the hap carries an AccessibilityExtensionAbility plus the companion
# EntryAbility. Usage:
#
#   scripts/build-a11y-client.sh [--unsigned] [--install] [--udid <UDID>]
#
# Outputs: dist/a11y-client/entry-default-unsigned.hap and, unless --unsigned, the signed
# a11y-client-signed.hap. --install pushes the signed hap with hdc and verifies the bundle and
# the A11yExtAbility are visible to bm.
#
# Requirements: node (runnable), java, the OpenHarmony SDK (OHOS_SDK_ROOT or the harmonybrew
# 26.0.0.18_2 install) and a hvigor install at HVIGOR_DIR (default .arkts-build/hvigor, created
# by scripts/build-arkts-shell.sh). All paths can be overridden by env.
set -e
W="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$W/test/a11y-client"
BUILD="${A11Y_BUILD_DIR:-$W/.a11y-build}"
PROJ="$BUILD/project"
SDK="${OHOS_SDK_ROOT:-$HOME/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_2}"
HVIGOR_DIR="${HVIGOR_DIR:-$W/.arkts-build/hvigor}"
HVIGOR_JS="${HVIGOR_JS:-$HVIGOR_DIR/node_modules/@ohos/hvigor/bin/hvigor.js}"
NODE_BIN="${NODE:-$(command -v node)}"
OUT_DIR="${A11Y_OUT_DIR:-$W/dist/a11y-client}"
BUNDLE="com.example.a11yclient"
HDC="${HDC:-$(command -v hdc 2>/dev/null || printf '%s' "$HOME/ohos-clt/sdk/default/openharmony/toolchains/hdc")}"

UNSIGNED_ONLY=0
INSTALL=0
UDID="${A11Y_UDID:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --unsigned) UNSIGNED_ONLY=1; shift ;;
        --install) INSTALL=1; shift ;;
        --udid) UDID="$2"; shift 2 ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

info() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -x "$NODE_BIN" ] || die "node not found (set NODE=)"
# The environment exports NODE=<device node> here; that binary aborts with a V8 fatal, so fall
# back to the node on PATH unless the override passes a trivial smoke test (mirrors
# build-arkts-shell.sh).
node_runs() { sh -c '"$0" -e "process.exit(0)"' "$1" >/dev/null 2>&1; }
if ! node_runs "$NODE_BIN"; then
    NODE_ALT="$(command -v node)"
    if [ -n "$NODE_ALT" ] && [ "$NODE_ALT" != "$NODE_BIN" ] && node_runs "$NODE_ALT"; then
        info "NODE=$NODE_BIN is not runnable here; using $NODE_ALT"
        NODE_BIN="$NODE_ALT"
    else
        die "node '$NODE_BIN' cannot run a trivial script (set NODE= to a working node >= 18)"
    fi
fi
[ -f "$HVIGOR_JS" ] || die "hvigor not installed under $HVIGOR_DIR (run scripts/build-arkts-shell.sh once to install it, or set HVIGOR_DIR/HVIGOR_JS)"
[ -f "$SDK/ets/oh-uni-package.json" ] || die "OpenHarmony SDK not found at $SDK (set OHOS_SDK_ROOT)"
[ -d "$SRC/entry" ] || die "missing source tree: $SRC/entry"

if [ -z "${JAVA_HOME:-}" ]; then
    for cand in "$HOME/.harmonybrew/opt/openjdk@17" "$HOME/.harmonybrew/opt/openjdk@21" \
                "$HOME/.harmonybrew/opt/openjdk" "$HOME/.harmonybrew/Cellar/openjdk@17"; do
        if [ -x "$cand/bin/java" ]; then JAVA_HOME="$cand"; break; fi
    done
fi
[ -n "${JAVA_HOME:-}" ] && info "java: $JAVA_HOME"

PLATFORM_VERSION="$(python3 -c "import json;print(json.load(open('$SDK/ets/oh-uni-package.json'))['platformVersion'])" 2>/dev/null || printf '26.0.0')"
info "SDK $SDK (platform $PLATFORM_VERSION), hvigor $HVIGOR_DIR, node $NODE_BIN"

# 1) SDK root hvigor resolves from local.properties (version-nested symlinks).
SDK_ROOT="$BUILD/sdk"
rm -rf "$SDK_ROOT"; mkdir -p "$SDK_ROOT/$PLATFORM_VERSION"
for c in ets js native previewer toolchains; do
    [ -e "$SDK/$c" ] && ln -s "$SDK/$c" "$SDK_ROOT/$PLATFORM_VERSION/$c"
done

# 2) project copy (no build outputs, no offline test tree).
rm -rf "$PROJ"; mkdir -p "$PROJ"
cp "$SRC/build-profile.json5" "$SRC/hvigorfile.ts" "$SRC/oh-package.json5" "$PROJ/"
cp -R "$SRC/AppScope" "$SRC/hvigor" "$PROJ/"
cp -R "$SRC/entry" "$PROJ/"
rm -rf "$PROJ/entry/build" "$PROJ/entry/oh_modules" "$PROJ/entry/node_modules"
printf 'sdk.dir=%s\nnodejs.dir=%s\n' "$SDK_ROOT" "$(dirname "$NODE_BIN")" > "$PROJ/local.properties"
ln -sfn "$HVIGOR_DIR/node_modules" "$PROJ/node_modules"

# 3) build. hvigor's PackageHap step needs the Java app_packing_tool.jar, which this SDK ships
# only as the native ohos_packing_tool; the ArkTS compilation is what hvigor is used for, and a
# PackageHap failure after a finished CompileArkTS is tolerated (the hap is packed below).
mkdir -p "$BUILD" "$OUT_DIR"
LOG="$BUILD/hvigor-build.log"
EXTERNAL_API_PATHS="$SDK/ets/api:$SDK/ets/kits:$SDK/ets/arkts"
run_hvigor() {
    ( cd "$PROJ" && \
      env -i PATH="$(dirname "$NODE_BIN")${JAVA_HOME:+:$JAVA_HOME/bin}:/usr/bin:/bin" HOME="$HOME" \
          ${JAVA_HOME:+JAVA_HOME="$JAVA_HOME"} \
          OHOS_BASE_SDK_HOME="$SDK" DEVECO_SDK_HOME="$SDK" \
          externalApiPaths="$EXTERNAL_API_PATHS" \
          "$NODE_BIN" "$HVIGOR_JS" \
            assembleHap -m module -p module=entry@default -p product=default -p buildMode=debug \
            > "$LOG" 2>&1 )
}
info "running hvigor assembleHap"
attempt=1
while :; do
    if run_hvigor; then break; fi
    if grep -qE 'Signal 5|Fatal error in' "$LOG" && [ "$attempt" -lt 3 ]; then
        info "hvigor crashed (attempt $attempt) - retrying"
        attempt=$((attempt + 1))
        continue
    fi
    if grep -q 'Finished :entry:default@CompileArkTS' "$LOG"; then
        info "hvigor failed after a finished ArkTS compile (expected for the missing Java packing jar); packing below"
        grep -E 'Failed :' "$LOG" | tail -2 | sed 's/^/    /'
        break
    fi
    tail -25 "$LOG" | sed 's/^/    /'
    die "hvigor failed (full log: $LOG)"
done

# 4) pack the hap with the SDK's native ohos_packing_tool (the same inputs the .NET workload
# pack target uses: merged module.json, compiled resources.index, resources copy, ets/modules.abc).
INTER="$PROJ/entry/build/default/intermediates"
ABC="$INTER/loader_out/default/ets/modules.abc"
MODULE_JSON="$INTER/package/default/module.json"
RES_INDEX="$INTER/res/default/resources.index"
RES_DIR="$INTER/res/default/resources"
[ -f "$ABC" ] || die "modules.abc not produced (see $LOG)"
[ -f "$MODULE_JSON" ] || die "merged module.json not produced (see $LOG)"
[ -f "$RES_INDEX" ] || die "resources.index not produced (see $LOG)"
[ -d "$RES_DIR" ] || die "compiled resources tree not produced (see $LOG)"
LIB_DIR="$BUILD/empty-libs"
mkdir -p "$LIB_DIR"
UNSIGNED="$OUT_DIR/entry-default-unsigned.hap"
rm -f "$UNSIGNED"
"$SDK/toolchains/lib/ohos_packing_tool" pack --mode hap \
    --json-path "$MODULE_JSON" --ets-path "$INTER/loader_out/default/ets" \
    --resources-path "$RES_DIR" --index-path "$RES_INDEX" \
    --lib-path "$LIB_DIR" --out-path "$UNSIGNED" --force true > "$BUILD/packing.log" 2>&1 \
    || { tail -10 "$BUILD/packing.log" | sed 's/^/    /'; die "ohos_packing_tool failed (full log: $BUILD/packing.log)"; }
info "unsigned hap: $UNSIGNED ($(stat -c%s "$UNSIGNED") bytes, abc $(stat -c%s "$ABC") bytes)"

if [ "$UNSIGNED_ONLY" = 1 ]; then
    info "signing skipped (--unsigned)"
    exit 0
fi

# 5) sign with the SDK test material for the device UDID.
if [ -z "$UDID" ]; then
    UDID="$("$HDC" shell 'bm get -u' 2>/dev/null | tail -1 | tr -d '\r' || true)"
fi
[ -n "$UDID" ] || die "no UDID (connect the device or pass --udid <UDID>)"
SIGNED="$OUT_DIR/a11y-client-signed.hap"
rm -f "$SIGNED"
OHOS_SDK_ROOT="$SDK" "$W/scripts/sign-for-device.sh" "$UDID" \
    --bundle "$BUNDLE" --unsigned "$OUT_DIR/entry-default-unsigned.hap" --out "$SIGNED" \
    || die "sign-for-device.sh failed"
info "signed hap: $SIGNED ($(stat -c%s "$SIGNED") bytes, udid $UDID)"

# 6) optional install + visibility check.
if [ "$INSTALL" = 1 ]; then
    "$HDC" install -r "$SIGNED" || die "hdc install failed"
    info "installed; bm record:"
    "$HDC" shell "bm dump -n $BUNDLE" 2>/dev/null | grep -nE '"name"|A11yExtAbility|extensionAbilities|"type"' | head -20 | sed 's/^/    /'
    info "next: scripts/enable-a11y-client.sh  (or Settings > Accessibility > installed services)"
fi
