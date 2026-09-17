#!/bin/sh
# Builds the ArkTS shell (ability + ArkUI page) with the OFFICIAL hvigor toolchain and
# writes dist/ets/modules.abc. The packaging then consumes it with:
#   dotnet publish ... -p:OpenHarmonyUIPage=pages/Index \
#                      -p:OpenHarmonyArktsModulesAbc=$PWD/dist/ets/modules.abc
#
# No DevEco Studio is required: hvigor and the ohos plugin are installed from the Huawei
# npm mirror (HVIGOR_MIRROR), and the SDK is exposed to hvigor through a version-nested
# symlink root (hvigor expects <sdkRoot>/<platformVersion>/<component>).
#
# Requirements: node >= 18, an OpenHarmony SDK (OHOS_SDK_ROOT or the harmonybrew default).
# hvigor aborts with a V8 fatal when driven from the device's toybox sh; re-exec under
# bash when available.
if [ -z "${BASH_VERSION:-}" ] && command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
fi
set -e
W="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${OHOS_SDK_ROOT:-$HOME/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_2}"
VER=1.0.0-preview.12
TPL="$W/packs/Microsoft.OpenHarmony.Sdk/$VER/templates"
BUILD="${ARKTS_BUILD_DIR:-$W/.arkts-build}"
PROJ="${ARKTS_PROJECT_DIR:-$HVIGOR_DIR/project}"
HVIGOR_DIR="${HVIGOR_DIR:-$BUILD/hvigor}"
HVIGOR_VERSION="${HVIGOR_VERSION:-6.26.4}"
MIRROR="${HVIGOR_MIRROR:-https://repo.harmonyos.com/npm}"
NODE_BIN="${NODE:-$(command -v node)}"
OUT_DIR="${OUT_DIR:-$W/dist/ets}"

info() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -x "$NODE_BIN" ] || die "node not found (set NODE=)"
[ -f "$SDK/ets/oh-uni-package.json" ] || die "oh-uni-package.json not found under $SDK (set OHOS_SDK_ROOT)"

# hvigor's own hap packaging needs java; the ArkTS compilation does not. Use JAVA_HOME or
# a harmonybrew JDK when present.
if [ -z "${JAVA_HOME:-}" ]; then
    for cand in "$HOME/.harmonybrew/opt/openjdk@17" "$HOME/.harmonybrew/opt/openjdk@21" \
                "$HOME/.harmonybrew/opt/openjdk@25" "$HOME/.harmonybrew/opt/openjdk"; do
        if [ -x "$cand/bin/java" ]; then JAVA_HOME="$cand"; break; fi
    done
fi
[ -n "${JAVA_HOME:-}" ] && info "java: $JAVA_HOME"

read_sdk_meta() { python3 -c "import json;print(json.load(open('$SDK/ets/oh-uni-package.json'))['$1'])"; }
PLATFORM_VERSION="$(read_sdk_meta platformVersion)"
API_VERSION="$(read_sdk_meta apiVersion)"
info "SDK $SDK (platform $PLATFORM_VERSION, API $API_VERSION)"

# 1) hvigor ------------------------------------------------------------------
HVIGOR_JS="$HVIGOR_DIR/node_modules/@ohos/hvigor/bin/hvigor.js"
if [ ! -f "$HVIGOR_JS" ]; then
    info "installing hvigor $HVIGOR_VERSION from $MIRROR"
    mkdir -p "$HVIGOR_DIR/node_modules/@ohos"
    for pkg in hvigor hvigor-ohos-plugin; do
        tgz="$HVIGOR_DIR/$pkg.tgz"
        url="$MIRROR/@ohos/$pkg/-/@ohos-$pkg-$HVIGOR_VERSION.tgz"
        [ -f "$tgz" ] || curl -fsSL --retry 3 -o "$tgz" "$url" || die "download failed: $url"
        tar xzf "$tgz" -C "$HVIGOR_DIR/node_modules/@ohos"
        mv "$HVIGOR_DIR/node_modules/@ohos/package" "$HVIGOR_DIR/node_modules/@ohos/$pkg"
    done
fi

# 2) version-nested SDK root -------------------------------------------------
SDK_ROOT="$BUILD/sdk"
rm -rf "$SDK_ROOT"; mkdir -p "$SDK_ROOT/$PLATFORM_VERSION"
for c in ets js native previewer toolchains; do
    [ -e "$SDK/$c" ] && ln -s "$SDK/$c" "$SDK_ROOT/$PLATFORM_VERSION/$c"
done

# 3) project scaffold --------------------------------------------------------
rm -rf "$PROJ"
mkdir -p "$PROJ/hvigor" "$PROJ/AppScope/resources/base/element" "$PROJ/AppScope/resources/base/media" \
    "$PROJ/entry/src/main/ets/entryability" "$PROJ/entry/src/main/ets/pages" \
    "$PROJ/entry/src/main/resources/base/element" "$PROJ/entry/src/main/resources/base/media" \
    "$PROJ/entry/src/main/resources/base/profile"
# UI ability + page from the platform pack templates
cp "$TPL/ets/entryability/EntryAbility.ui.ets" "$PROJ/entry/src/main/ets/entryability/EntryAbility.ets"
cp "$TPL/ets/pages/Index.ets" "$PROJ/entry/src/main/ets/pages/Index.ets"
cp "$TPL/resources/base/element/color.json" "$PROJ/entry/src/main/resources/base/element/"
cp "$TPL/resources/base/media/app_icon.png" "$PROJ/entry/src/main/resources/base/media/"
cp "$TPL/resources/base/media/app_icon.png" "$PROJ/AppScope/resources/base/media/"

python3 - "$PROJ" "$PLATFORM_VERSION" "$API_VERSION" <<'PY'
import json, os, sys
proj, platform_version, api_version = sys.argv[1:4]
def w(rel, text):
    with open(os.path.join(proj, rel), 'w') as f: f.write(text)

strings = [{"name": n, "value": "opendotnet"} for n in
           ("app_name", "module_desc", "EntryAbility_desc", "EntryAbility_label")]
for base in ('entry/src/main/resources/base/element', 'AppScope/resources/base/element'):
    w(f'{base}/string.json', json.dumps({"string": strings}, indent=2))
w('entry/src/main/resources/base/profile/main_pages.json', json.dumps({"src": ["pages/Index"]}))
w('AppScope/app.json5', """{
  app: {
    bundleName: 'com.example.opendotnet',
    vendor: 'example',
    versionCode: 1,
    versionName: '1.0.0',
    icon: '$media:app_icon',
    label: '$string:app_name',
  },
}
""")
w('hvigorfile.ts', "export { appTasks } from '@ohos/hvigor-ohos-plugin';\n")
w('entry/hvigorfile.ts', "export { hapTasks } from '@ohos/hvigor-ohos-plugin';\n")
w('oh-package.json5', """{
  modelVersion: '6.0.0',
  name: 'opendotnet',
  version: '1.0.0',
  description: 'ArkTS shell for a .NET OpenHarmony app',
  main: '',
  author: '',
  license: 'MIT',
  dependencies: {},
}
""")
w('entry/oh-package.json5', """{
  name: 'entry',
  version: '1.0.0',
  description: 'entry module',
  main: '',
  author: '',
  license: 'MIT',
  dependencies: {},
}
""")
w('hvigor/hvigor-config.json5', """{
  modelVersion: '6.0.0',
  dependencies: {},
  execution: { analyze: 'normal', daemon: false, incremental: false, parallel: true, typeCheck: false },
  logging: { level: 'info' },
  debugging: { stacktrace: false },
}
""")
w('build-profile.json5', f"""{{
  app: {{
    products: [
      {{
        name: 'default',
        compileSdkVersion: '{platform_version}',
        compatibleSdkVersion: '{platform_version}',
        targetSdkVersion: '{platform_version}',
        runtimeOS: 'OpenHarmony',
      }},
    ],
    buildModeSet: [{{ name: 'debug' }}, {{ name: 'release' }}],
  }},
  modules: [
    {{ name: 'entry', srcPath: './entry', targets: [{{ name: 'default', applyToProducts: ['default'] }}] }},
  ],
}}
""")
w('entry/build-profile.json5', """{
  apiType: 'stageMode',
  buildOption: {},
  targets: [{ name: 'default' }],
}
""")
w('entry/src/main/module.json5', """{
  module: {
    name: 'entry',
    type: 'entry',
    description: '$string:module_desc',
    mainElement: 'EntryAbility',
    deviceTypes: ['default'],
    deliveryWithInstall: true,
    installationFree: false,
    pages: '$profile:main_pages',
    abilities: [
      {
        name: 'EntryAbility',
        srcEntry: './ets/entryability/EntryAbility.ets',
        description: '$string:EntryAbility_desc',
        icon: '$media:app_icon',
        label: '$string:EntryAbility_label',
        startWindowIcon: '$media:app_icon',
        startWindowBackground: '$color:start_window_background',
        exported: true,
        skills: [{ entities: ['entity.system.home'], actions: ['action.system.home'] }],
      },
    ],
    requestPermissions: [],
  },
}
""")
w('local.properties', f"sdk.dir={proj}/../sdk\nnodejs.dir={os.path.expanduser('~/.harmonybrew')}\n")
print('  project scaffold written:', proj)
PY
printf 'sdk.dir=%s\nnodejs.dir=%s\n' "$SDK_ROOT" "${NODE_HOME:-$HOME/.harmonybrew}" > "$PROJ/local.properties"

# 4) build -------------------------------------------------------------------
# hvigor resolves the plugin by walking up from the project directory; the default project
# location ($HVIGOR_DIR/project) therefore sits next to the installed packages.
if [ ! -e "$HVIGOR_DIR/node_modules/@ohos/hvigor-ohos-plugin" ]; then
    die "hvigor packages missing under $HVIGOR_DIR/node_modules/@ohos"
fi

info "running hvigor assembleHap"
# hvigor's own PackageHap step needs java (for the packing jar); the ArkTS compilation
# (everything this script needs) runs before it, so a failed PackageHap is tolerated.
LOG="$BUILD/hvigor-build.log"
run_hvigor() {
    ( cd "$PROJ" && \
      env -i PATH="$(dirname "$NODE_BIN")${JAVA_HOME:+:$JAVA_HOME/bin}:/usr/bin:/bin" HOME="$HOME" \
          ${JAVA_HOME:+JAVA_HOME="$JAVA_HOME"} \
          OHOS_BASE_SDK_HOME="$SDK_ROOT" DEVECO_SDK_HOME="$SDK_ROOT" \
          "$NODE_BIN" "$HVIGOR_JS" \
            assembleHap -m module -p module=entry@default -p product=default -p buildMode=debug \
            > "$LOG" 2>&1 )
}
# The toolchain occasionally aborts with a V8 fatal ("Signal 5") on this device; retry.
ABC_INTERMEDIATE="$PROJ/entry/build/default/intermediates/loader_out/default/ets/modules.abc"
attempt=1
while :; do
    if run_hvigor; then break; fi
    if [ -f "$ABC_INTERMEDIATE" ]; then
        # hvigor's own PackageHap step is not needed (this workload packages the hap with
        # the OpenHarmony packing tool); the ArkTS output is what matters.
        info "hvigor reported a failure after producing modules.abc; ignoring it"
        grep -E 'Failed :' "$LOG" | tail -2 | sed 's/^/    /'
        break
    fi
    if grep -qE 'Signal 5|Fatal error in' "$LOG" && [ "$attempt" -lt 3 ]; then
        info "hvigor crashed (attempt $attempt) - retrying"
        attempt=$((attempt + 1))
        continue
    fi
    tail -20 "$LOG" | sed 's/^/    /'
    die "hvigor failed (full log: $LOG)"
done
grep -E 'Finished :entry:default@CompileArkTS|Failed :entry:default@CompileArkTS' "$LOG" | tail -1 | sed 's/^/    /' || true

ABC="$(find "$PROJ/entry/build" -name modules.abc | head -1)"
[ -n "$ABC" ] || die "modules.abc not produced (see .arkts-build/project/.hvigor/outputs/build-logs)"
mkdir -p "$OUT_DIR"
cp "$ABC" "$OUT_DIR/modules.abc"
info "ArkTS shell compiled: $OUT_DIR/modules.abc ($(stat -c%s "$OUT_DIR/modules.abc") bytes)"
info "package it with: -p:OpenHarmonyUIPage=pages/Index -p:OpenHarmonyArktsModulesAbc=$OUT_DIR/modules.abc"
