#!/bin/sh
# Builds the ArkTS shell with the official hvigor toolchain. ARKTS_SHELL_VARIANT picks the
# sources: ui (default) compiles the UI ability + ArkUI page and writes dist/ets/modules.abc;
# packaging consumes it via -p:OpenHarmonyArktsModulesAbc together with -p:OpenHarmonyUIPage
# (see the OpenHarmonyUIPage packing doc). headless compiles the page-free EntryAbility.ets and
# writes dist/ets/modules.headless.abc, the artifact installed as the platform pack's
# templates/ets/modules.abc - the default shell for builds without OpenHarmonyUIPage.
#
# No DevEco Studio: hvigor and its ohos plugin come from the Huawei npm mirror
# (HVIGOR_MIRROR), pinned by sha256 (HVIGOR_SHA256 / HVIGOR_OHOS_PLUGIN_SHA256) and unpacked
# only after the member list passes the tar-slip gate (section 1; --check-tgz exposes it and
# scripts/selftest-build-arkts-shell.sh drives its negative cases). The SDK is exposed through
# a version-nested symlink root. Requirements: node >= 18, an OpenHarmony SDK (OHOS_SDK_ROOT
# or the harmonybrew default); re-exec under bash when hvigor would abort under toybox sh.
#
# useNormalizedOHMUrl stays false: the device resolves the ability entry as
# <bundleName>/<moduleName>/ets/entryability/EntryAbility against the abc record names, so the
# non-normalized build carries the HAP's bundle name (ARKTS_SHELL_BUNDLE_NAME / KIT_BUNDLE_NAME;
# default com.example.hellomauiapp). The normalized records need pkgContextInfo.json, which the
# HAP does not ship yet (RH1, 2026-09-23); the scaffold note below has the full story.
#
# abc version: the SDK 26 default 24.0.0.0 is rejected by the device runtime; compatibleSdkVersion
# 18 makes es2abc emit 13.0.1.0. The emitted version is read back from the abc header and must not
# exceed ARKTS_MAX_BC_VERSION (default 13.0.1.0); raise it with ARKTS_COMPATIBLE_SDK_VERSION.
# Two more gates run on the emitted artifact: the compile itself must be reported as finished
# (hvigor's own PackageHap failure is tolerated, a failed CompileArkTS is not), and the abc must
# carry the payload-in-libs probe plus the dotnet.zip fallback literals (dotnet-payload /
# bundleCodeDir / payload-in-libs / dotnet.marker), so a stale template cannot ship silently.
#
# hvigor "00302013 - The root node is not yet available for build" (the device-side testers hit it
# with an older scaffold; kit report 5) is guarded in three places. The generated
# hvigor/hvigor-config.json5 keeps `dependencies: {}` because DevEco Studio and the Command Line
# Tools already bundle the plugin - listing @ohos/hvigor or @ohos/hvigor-ohos-plugin there makes
# hvigor load two copies (official handling step 2 of ide-hvigor-errorcode-00302) - and
# check_hvigor_config_deps() re-reads the generated file so a future edit fails fast instead of
# mysteriously. When hvigor still fails with that code, diagnose_hvigor_log() prints the official
# three steps, the duplicate-config/cache checks and the DevEco-Studio fallback (create an empty
# project and replace entry/src/main/ets, the path that unblocked the device build).
# modelVersion is the DevEco-created 6.0.2 in the two files hvigor requires to agree
# (hvigor-config.json5 and oh-package.json5; a mismatch is INCONSISTENT_MODEL_VERSION), while
# runtimeOS stays OpenHarmony by default: this tree builds against the OpenHarmony SDK 26.0.0, and
# with runtimeOS HarmonyOS hvigor requires a '26.0.0'-style string compatibleSdkVersion for API
# >= 26 (verified error 00306042), which raises es2abc above the device's 13.0.1.0 abc limit.
# strictMode already carries the DevEco values caseSensitiveCheck=true / useNormalizedOHMUrl=false.
#
# ARKTS_SDK_FLAVOR=harmony (opt-in, default openharmony) selects a DevEco-style HarmonyOS SDK for
# the HMS-kit shell variant (Share/Scan/... need the hms/ets declarations the OpenHarmony SDK does
# not ship). It is the only branch that can compile the HMS Kit code paths: a literal
# import('@kit.ShareKit') is a hard ArkTS compile error on the OpenHarmony SDK (KIT-IMPL probe a,
# 2026-09-25). The branch changes five things and nothing else: the SDK root comes from
# ARKTS_HARMONY_SDK_ROOT (or DEVECO_SDK_HOME), runtimeOS is HarmonyOS, compatibleSdkVersion
# defaults to 6.1.0(23) - the value the device-side DevEco build used to emit the accepted
# 13.0.1.0 abc (MyApplication, 2026-09-21) - the UI variant additionally copies the Map
# overlay module (ets/map/MapOverlay.ets, R2-3 2026-09-26: the only file that names MapComponent,
# whose ArkUI declaration also lives in hms/ets), and the UI variant's Index.ets copy is rewritten
# by patch_harmony_index_ets() to import that module statically. The static import is what puts
# the overlay into hvigor's compile graph and hence into modules.abc (MAPFIX 2026-09-28;
# HCI-HARMONY-CI measured that the variable-specifier dynamic import the page keeps never
# registered a record, so a copied-but-uncompiled overlay only ever answered capability bit 1 = 0).
# The emitted abc is gated: the appended check requires the MapOverlay module record and its probe
# symbols in every harmony ui build, and --check-overlay-abc exposes the same gate offline. The
# default flavor never compiles that module and its abc stays byte-identical, so the page's
# dynamic import of './map/MapOverlay' fails at runtime there and the Map sink reports capability
# bit 1 = 0. The abc header gate (ARKTS_MAX_BC_VERSION 13.0.1.0) is unchanged, so a HarmonyOS
# build that raises es2abc above the device limit still fails here. The branch is build-verified
# 2026-09-27 with the DevEco command-line-tools bundle 6.0.1.251 (HarmonyOS 6.0.1 Release /
# API 21) and re-verified 2026-09-28 with the overlay compiled in. The hvigor and the SDK must
# match: the pinned 6.26.4 is a DevEco-26 toolchain and rejects a 6.0/6.1 SDK (00303313/00303312),
# so drive the SDK's own hvigor through the HVIGOR_JS override and set
# ARKTS_MODEL_VERSION/ARKTS_COMPATIBLE_SDK_VERSION to values it supports. scripts/
# setup-harmony-sdk.sh obtains or mocks an SDK; docs/openharmony-hap-packaging.md "HarmonyOS SDK
# branch" has the two routes, the tester recipe and the AGC checklist.
# --check-sources, --check-pack-abc, --install-packs, --check-tgz, --check-abc,
# --check-bc-version, --check-overlay-abc, --patch-harmony-index, --print-config,
# --diagnose-log <file>, --check-project-deps <dir> and
# --scaffold-only <dir> expose the gates, the flavor resolution and the abc ceiling to
# scripts/selftest-build-arkts-shell.sh without node, hvigor or an SDK.
if [ -z "${BASH_VERSION:-}" ] && command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
fi
set -e
W="$(cd "$(dirname "$0")/.." && pwd)"
# SDK flavor (opt-in): openharmony (default, unchanged behaviour) or harmony (DevEco-style
# HarmonyOS SDK with hms/ets, see the header). The harmony branch needs ARKTS_HARMONY_SDK_ROOT or
# DEVECO_SDK_HOME; nothing below changes for the default.
SDK_FLAVOR="${ARKTS_SDK_FLAVOR:-openharmony}"
case "$SDK_FLAVOR" in
    openharmony|harmony) ;;
    *) printf "ERROR: ARKTS_SDK_FLAVOR must be 'openharmony' or 'harmony' (got '%s')\n" "$SDK_FLAVOR" >&2; exit 1 ;;
esac
VER=1.0.0-preview.24
TPL="$W/packs/Microsoft.OpenHarmony.Sdk/$VER/templates"
BUILD="${ARKTS_BUILD_DIR:-$W/.arkts-build}"
HVIGOR_DIR="${HVIGOR_DIR:-$BUILD/hvigor}"
PROJ="${ARKTS_PROJECT_DIR:-$HVIGOR_DIR/project}"
HVIGOR_VERSION="${HVIGOR_VERSION:-6.26.4}"
MIRROR="${HVIGOR_MIRROR:-https://repo.harmonyos.com/npm}"
# TYPECHECK=1 enables hvigor's ArkTS type checker (typeCheck: true). The default stays false
# because the shipping build only needs the compile; use TYPECHECK=1 for the error-free check.
TYPECHECK="${TYPECHECK:-0}"
NODE_BIN="${NODE:-$(command -v node)}"
OUT_DIR="${OUT_DIR:-$W/dist/ets}"
# Bundle name of the generated shell app; see the useNormalizedOHMUrl note above. Keep it in
# sync with the HAP's OpenHarmonyBundleName (default com.example.<assembly minus hyphens>).
BUNDLE_NAME="${ARKTS_SHELL_BUNDLE_NAME:-${KIT_BUNDLE_NAME:-com.example.hellomauiapp}}"
# compatibleSdkVersion of the generated hvigor project depends on the flavor (see below):
# openharmony 18 is the lowest API level whose es2abc output is 13.0.1.0, the newest abc the
# device runtime accepts (see the abc note in the header); harmony 6.1.0(23) is the value the
# device-side DevEco build used to emit the same 13.0.1.0 abc. Raise it only together with
# ARKTS_MAX_BC_VERSION.
MAX_BC_VERSION="${ARKTS_MAX_BC_VERSION:-13.0.1.0}"
# modelVersion of the generated project (hvigor-config.json5 *and* oh-package.json5 must agree, or
# hvigor exits with INCONSISTENT_MODEL_VERSION). 6.0.2 is what a DevEco-created project carries;
# the pinned hvigor accepts anything in [5.0.0, 26.0.0], and 6.0.0 vs 6.0.2 compiles to a
# byte-identical modules.abc (verified), so the DevEco value is kept.
MODEL_VERSION="${ARKTS_MODEL_VERSION:-6.0.2}"
# Selective shell variant (see the header): ui is the default and keeps the kit-facing
# dist/ets/modules.abc; headless emits dist/ets/modules.headless.abc so it can never overwrite
# the UI shell the device-test kit packages.
VARIANT="${ARKTS_SHELL_VARIANT:-ui}"

info() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---- SDK flavor resolution (needs die, so it runs after the definition) ------------------
# openharmony: the OpenHarmony SDK root (OHOS_SDK_ROOT or the harmonybrew default).
# harmony: a DevEco-style HarmonyOS SDK root (ARKTS_HARMONY_SDK_ROOT or DEVECO_SDK_HOME). The
#   root either is the SDK home that contains default/ (DevEco layout, e.g. .../sdk.org/sdk_1.0.0)
#   or the versioned directory itself. The OpenHarmony toolchain half lives under
#   <base>/openharmony/{ets,js,native,previewer,toolchains}; the HMS kit declarations live under
#   <base>/hms/ets and are added to externalApiPaths.
# RUNTIME_OS / SDK_ETS_ROOT / SDK_ETS_EXTRA / COMPATIBLE_SDK_VERSION / TARGET_VERSION come out of
# here; the rest of the script reads them.
if [ "$SDK_FLAVOR" = harmony ]; then
    SDK="${ARKTS_HARMONY_SDK_ROOT:-${DEVECO_SDK_HOME:-}}"
    [ -n "$SDK" ] || die "ARKTS_SDK_FLAVOR=harmony needs a HarmonyOS SDK: set ARKTS_HARMONY_SDK_ROOT (or DEVECO_SDK_HOME) to the DevEco SDK root"
    if [ -d "$SDK/default/openharmony/ets" ]; then
        HARMONY_SDK_BASE="$SDK/default"
    elif [ -d "$SDK/openharmony/ets" ]; then
        HARMONY_SDK_BASE="$SDK"
    else
        die "no DevEco-style HarmonyOS SDK under $SDK (expected <root>/default/openharmony/ets or <root>/openharmony/ets)"
    fi
    [ -d "$HARMONY_SDK_BASE/hms/ets" ] || die "the HarmonyOS SDK at $SDK has no hms/ets (the HMS kit declarations Share/Scan/... need); pass the full DevEco SDK root"
    RUNTIME_OS=HarmonyOS
    SDK_ETS_ROOT="$HARMONY_SDK_BASE/openharmony/ets"
    SDK_ETS_EXTRA="$HARMONY_SDK_BASE/hms/ets"
    COMPATIBLE_SDK_VERSION="${ARKTS_COMPATIBLE_SDK_VERSION:-6.1.0(23)}"
else
    SDK="${OHOS_SDK_ROOT:-$HOME/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_2}"
    RUNTIME_OS=OpenHarmony
    SDK_ETS_ROOT="$SDK/ets"
    SDK_ETS_EXTRA=""
    COMPATIBLE_SDK_VERSION="${ARKTS_COMPATIBLE_SDK_VERSION:-18}"
fi

# SDK metadata (platformVersion/apiVersion); defined here so --scaffold-only and --print-config
# can read it without reaching the full SDK validation of the main path. Two layouts must work:
# the OpenHarmony SDK (and DevEco-generated projects) carry platformVersion in
# ets/oh-uni-package.json, while the DevEco command-line-tools SDK 6.0.1.251 carries only
# apiVersion + version there and keeps platformVersion in <base>/sdk-pkg.json (verified against
# commandline-tools-linux-x64-6.0.1.251, 2026-09-27). Fall back to sdk-pkg.json and then to the
# version's first three components, and fail with the searched paths named when none carries it.
read_sdk_meta() {
    python3 - "$1" "$SDK_ETS_ROOT" "${HARMONY_SDK_BASE:-}" <<'PY'
import json, os, sys
key, ets_root, base = sys.argv[1], sys.argv[2], sys.argv[3]

def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}

pkg = load(os.path.join(ets_root, 'oh-uni-package.json'))
if pkg.get(key):
    print(pkg[key]); sys.exit(0)
for candidate in (os.path.join(base, 'sdk-pkg.json') if base else '',
                  os.path.join(ets_root, 'sdk-pkg.json')):
    if candidate:
        data = load(candidate).get('data') or {}
        if data.get(key):
            print(data[key]); sys.exit(0)
version = str(pkg.get('version', ''))
if key == 'platformVersion' and version.count('.') >= 2:
    print('.'.join(version.split('.')[:3])); sys.exit(0)
sys.stderr.write('cannot read %s: looked in %s/oh-uni-package.json and %s\n' % (
    key, ets_root, os.path.join(base or ets_root, 'sdk-pkg.json')))
sys.exit(1)
PY
}

# TARGET_VERSION is the DevEco-style combined string platformVersion(apiVersion) on the harmony
# flavor and the plain platformVersion on OpenHarmony. Shared by the build path, --scaffold-only
# and --print-config so the generated build-profile.json5 cannot diverge between them.
compute_target_version() {
    if [ "$SDK_FLAVOR" = harmony ]; then
        printf '%s(%s)' "$1" "$2"
    else
        printf '%s' "$1"
    fi
}

# The externalApiPaths value hvigor receives: the OpenHarmony ets declarations plus, on the
# harmony flavor, the HMS kit declarations under hms/ets. Split out of run_hvigor so --print-config
# can show the exact value the build injects without node, hvigor or an SDK.
resolve_external_api_paths() {
    case "$SDK_FLAVOR" in
        harmony) printf '%s' "$HARMONY_SDK_BASE/openharmony/ets/api:$HARMONY_SDK_BASE/openharmony/ets/kits:$HARMONY_SDK_BASE/openharmony/ets/arkts:$SDK_ETS_EXTRA" ;;
        *)       printf '%s' "$SDK/ets/api:$SDK/ets/kits:$SDK/ets/arkts" ;;
    esac
}

# Directories every generated configuration file lives in (the ets sources are copied separately).
make_project_dirs() {
    mkdir -p "$PROJ/hvigor" "$PROJ/AppScope/resources/base/element" "$PROJ/AppScope/resources/base/media" \
        "$PROJ/entry/src/main/ets/entryability" \
        "$PROJ/entry/src/main/resources/base/element" "$PROJ/entry/src/main/resources/base/media" \
        "$PROJ/entry/src/main/resources/base/profile"
}

# Writes every generated project configuration into $PROJ. Extracted from section 3 so
# --scaffold-only can exercise the exact texts (the selftest asserts the hvigor-config
# dependencies stay empty, modelVersion agreement and the strictMode values).
write_project_configs() {
python3 - "$PROJ" "$PLATFORM_VERSION" "$API_VERSION" "$TYPECHECK" "$BUNDLE_NAME" \
    "$COMPATIBLE_SDK_VERSION" "$VARIANT" "$MODEL_VERSION" "$RUNTIME_OS" "$TARGET_VERSION" <<'PY'
import json, os, sys
proj, platform_version, api_version, typecheck, bundle_name, compatible_sdk_version, variant, model_version, runtime_os, target_version = sys.argv[1:11]
typecheck_json = 'true' if typecheck == '1' else 'false'
def w(rel, text):
    with open(os.path.join(proj, rel), 'w') as f: f.write(text)

strings = [{"name": n, "value": "opendotnet"} for n in
           ("app_name", "module_desc", "EntryAbility_desc", "EntryAbility_label")]
for base in ('entry/src/main/resources/base/element', 'AppScope/resources/base/element'):
    w(f'{base}/string.json', json.dumps({"string": strings}, indent=2))
if variant == 'ui':
    # MULTIWINDOW-M: pages/SubWindow is the shell-drawn subwindow content loaded through the
    # named route 'ohos_dotnet_subwindow'; listing it here is what compiles it into the abc.
    w('entry/src/main/resources/base/profile/main_pages.json', json.dumps({"src": ["pages/Index", "pages/SubWindow"]}))
w('AppScope/app.json5', f"""{{
  app: {{
    bundleName: '{bundle_name}',
    vendor: 'example',
    versionCode: 1,
    versionName: '1.0.0',
    icon: '$media:app_icon',
    label: '$string:app_name',
  }},
}}
""")
w('hvigorfile.ts', "export { appTasks } from '@ohos/hvigor-ohos-plugin';\n")
w('entry/hvigorfile.ts', "export { hapTasks } from '@ohos/hvigor-ohos-plugin';\n")
w('oh-package.json5', """{
  modelVersion: '__MODEL_VERSION__',
  name: 'opendotnet',
  version: '1.0.0',
  description: 'ArkTS shell for a .NET OpenHarmony app',
  main: '',
  author: '',
  license: 'MIT',
  dependencies: {},
}
""".replace('__MODEL_VERSION__', model_version))
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
# ohpm lock files for the (empty) dependency tree. hvigor does not require them to produce
# loader_out (module.json/pkgContextInfo.json/filesInfo.txt are generated either way), but the
# device-test feedback flagged a missing lock as an incomplete DevEco-style project.
lock = """{
  meta: {
    stableOrder: true,
    enableUnifiedLockfile: false,
  },
  lockfileVersion: 3,
  ATTENTION: 'THIS IS AN AUTOGENERATED FILE. DO NOT EDIT THIS FILE DIRECTLY.',
  specifiers: {},
  packages: {},
}
"""
w('oh-package-lock.json5', lock)
w('entry/oh-package-lock.json5', lock)
# dependencies stays empty on purpose: DevEco Studio and the Command Line Tools bundle hvigor,
# and listing @ohos/hvigor / @ohos/hvigor-ohos-plugin here makes hvigor load a second copy
# (official handling step 2 of ide-hvigor-errorcode-00302) and fail with 00302013 "The root node
# is not yet available for build". check_hvigor_config_deps() below re-checks this after writing.
w('hvigor/hvigor-config.json5', """{
  modelVersion: '__MODEL_VERSION__',
  dependencies: {},
  execution: { analyze: 'normal', daemon: false, incremental: false, parallel: true, typeCheck: __TYPECHECK__ },
  logging: { level: 'info' },
  debugging: { stacktrace: false },
}
""".replace('__MODEL_VERSION__', model_version).replace('__TYPECHECK__', typecheck_json))
w('build-profile.json5', f"""{{
  app: {{
    products: [
      {{
        name: 'default',
        compileSdkVersion: '{target_version}',
        compatibleSdkVersion: '{compatible_sdk_version}',
        targetSdkVersion: '{target_version}',
        runtimeOS: '{runtime_os}',
        buildOption: {{
          strictMode: {{
            caseSensitiveCheck: true,
            // The device runtime (HarmonyOS 7.0 / API 26) resolves the ability entry as
            // <bundleName>/entry/ets/entryability/EntryAbility and matches it against the abc
            // record names. Normalized OHM URLs ('&entry/src/main/ets/...&') are only resolved
            // when the HAP ships pkgContextInfo.json (the ArkTS VM's IsNormalizedOhmUrlPack()
            // gate), which this workload's packaging does not include yet - the pre-PA1
            // normalized abc failed the entry on the device. Non-normalized records are
            // <bundleName>/entry/ets/... and resolve directly. The host registers both its
            // bare name and the file name, so switching back to true is a packaging-side job
            // (ship pkgContextInfo.json) rather than a host-side one.
            useNormalizedOHMUrl: false,
          }},
        }},
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
module_json = """{
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
"""
if variant != 'ui':
    # The headless module has no pages profile: hvigor rejects an empty main_pages.json
    # (src needs at least one item) and the ability never loadContent's. The packaging target
    # emits an empty main_pages for the same reason on the no-OpenHarmonyUIPage path.
    module_json = module_json.replace("    pages: '$profile:main_pages',\n", '')
w('entry/src/main/module.json5', module_json)
w('local.properties', f"sdk.dir={proj}/../sdk\nnodejs.dir={os.path.expanduser('~/.harmonybrew')}\n")
print('  project scaffold written:', proj)
PY
}

# Official handling step 2 of ide-hvigor-errorcode-00302: DevEco Studio and the Command Line
# Tools already bundle hvigor, so hvigor-config.json5's dependencies must not list @ohos/hvigor
# or @ohos/hvigor-ohos-plugin - a listed copy makes hvigor find two plugins and abort with
# 00302013 "The root node is not yet available for build". The generated file is written with an
# empty dependencies on purpose; this guard makes a later (hand or template) edit fail fast with
# the official pointer instead of a cryptic hvigor error.
# rc=0 clean; rc=1 a hvigor plugin is listed (reason on stdout); rc=2 config missing.
check_hvigor_config_deps() {
    python3 - "$1" <<'PY'
import os, re, sys
proj = sys.argv[1]
cfg = os.path.join(proj, 'hvigor', 'hvigor-config.json5')
if not os.path.isfile(cfg):
    print(f'hvigor-config.json5 not found: {cfg}')
    sys.exit(2)
# Strip // comments so the explanatory comment inside the generated file cannot trip the check.
text = re.sub(r'//[^\n]*', '', open(cfg, encoding='utf-8', errors='replace').read())
bad = [name for name in ('@ohos/hvigor-ohos-plugin', '@ohos/hvigor') if name in text]
if bad:
    print('hvigor-config.json5 lists a hvigor plugin dependency: ' + ', '.join(bad))
    print('ide-hvigor-errorcode-00302 handling step 2: remove it/them - DevEco Studio and the')
    print('Command Line Tools bundle hvigor, and a second copy fails the build with')
    print('00302013 "The root node is not yet available for build".')
    print(f'config: {cfg}')
    sys.exit(1)
sys.exit(0)
PY
}

# Attribution for the hvigor failure the device-side testers hit (kit report 5): prints the
# official three handling steps of ide-hvigor-errorcode-00302, the duplicate-config/cache checks
# and the DevEco-Studio fallback that unblocked their abc build. Returns 0 when the log carries
# the 00302013 / "root node" signature, 1 otherwise (the build still fails; this only explains).
diagnose_hvigor_log() {
    grep -qE '00302013|root node is not yet available' "$1" || return 1
    cat >&2 <<EOF

hvigor 00302013 "The root node is not yet available for build" found in $1

Official handling steps (ide-hvigor-errorcode-00302):
  1. Call hvigor APIs from hvigorfile.ts, never from hvigorconfig.ts: that file executes before
     nodesInitialized, so an API call there aborts with exactly this error.
  2. Remove '@ohos/hvigor' and '@ohos/hvigor-ohos-plugin' from hvigor-config.json5's
     dependencies: DevEco Studio and the Command Line Tools bundle the plugin, and a listed copy
     makes hvigor find two plugins. This script generates dependencies: {} and re-checks it:
       $0 --check-project-deps $PROJ
  3. A plugin's own package.json must not declare '@ohos/hvigor*' in dependencies either; move
     them to that package's devDependencies.

Project: $PROJ
  generated config:        $PROJ/hvigor/hvigor-config.json5
  duplicate config files:  find "$PROJ" -name hvigor-config.json5 -not -path '*/node_modules/*'
  duplicate plugin copies: find "$PROJ" -path '*/@ohos/hvigor-ohos-plugin/package.json'
  our node_modules:        ls -ld "$PROJ/node_modules"  (a symlink to the CLI's hvigor install;
                           DevEco resolves its own bundled copy instead)
  stray hvigorconfig.ts:   rm -f "$PROJ/hvigorconfig.ts"  (not generated by this script)
  clear the stale hvigor caches and retry:
    rm -rf "$PROJ/.hvigor" "$PROJ/build" "$PROJ/entry/build" "$PROJ/node_modules/.cache"
    DevEco Studio: Build > Clean Project, then File > Sync and Refresh Project.

Verified fallback when the CLI cannot get past it (unblocked the device abc build, kit report 5.3):
  create an empty project in DevEco Studio (its complete layout; keep its modelVersion 6.0.2,
  runtimeOS HarmonyOS and strictMode useNormalizedOHMUrl=false), then replace its ets sources:
    cp "$PROJ/entry/src/main/ets/entryability/EntryAbility.ets" <deveco>/entry/src/main/ets/entryability/
    cp "$PROJ/entry/src/main/ets/pages/Index.ets" <deveco>/entry/src/main/ets/pages/   # ui variant only
  build with hvigorw assembleHap and feed the result back as
    -p:OpenHarmonyArktsModulesAbc=<deveco>/entry/build/default/intermediates/loader_out/default/ets/modules.abc
EOF
    # Live duplicate report, best effort; find does not follow the node_modules symlink, so this
    # only lists real copies inside the project.
    _dups="$(find "$PROJ" -path '*/@ohos/hvigor-ohos-plugin/package.json' 2>/dev/null | head -5)"
    if [ -n "$_dups" ]; then
        printf 'extra hvigor plugin copies found under the project (remove them):\n' >&2
        printf '%s\n' "$_dups" | sed 's/^/  /' >&2
    fi
    return 0
}

# The two hvigor tarballs are unpacked with `tar xzf` and the extracted files are then executed
# by node, so besides the sha256 pin (section 1) their member list must be safe: an absolute path
# or a `..` component would write outside node_modules (tar-slip) even when the hash matched an
# explicitly overridden HVIGOR_SHA256 / HVIGOR_OHOS_PLUGIN_SHA256. rc=0 only when $1 is a
# readable gzip tarball whose members are all relative and free of `..`; the caller reports why.
verify_tgz_members() {
    _tgz="$1"
    _members="$(tar tzf "$_tgz" 2>/dev/null)" || return 1
    [ -n "$_members" ] || return 2
    printf '%s\n' "$_members" | grep -Eq '(^/)|(^\.\.$)|(^\.\./)|(/\.\.$)|(/\.\./)' && return 3
    return 0
}

# The offending member names of an unsafe tarball (empty for the other failure modes).
unsafe_tgz_members() {
    tar tzf "$1" 2>/dev/null | grep -E '(^/)|(^\.\.$)|(^\.\./)|(/\.\.$)|(/\.\./)' || true
}

# --check-tgz <file>: run just the member-safety check and exit. It never unpacks anything, so it
# is safe to point at an untrusted tarball; scripts/selftest-build-arkts-shell.sh drives the
# negative cases through it.
if [ "${1:-}" = "--check-tgz" ]; then
    [ -n "${2:-}" ] || die "usage: $0 --check-tgz <file.tgz>"
    if verify_tgz_members "$2"; then
        info "tarball member list is safe: $2"
        exit 0
    else
        # capture the failure reason; `set -e` must not short-circuit the report below
        _rc=$?
    fi
    case "$_rc" in
        1) die "cannot list $2 as a gzip tarball" ;;
        2) die "$2 has no members" ;;
        *) printf 'ERROR: unsafe member names (absolute path or .. traversal) in %s:\n' "$2" >&2
           unsafe_tgz_members "$2" | sed 's/^/  /' >&2
           exit 1 ;;
    esac
fi

# --check-abc <file>: run just the compiled-shell contract check and exit. It needs no node,
# hvigor or SDK, so scripts/selftest-build-arkts-shell.sh drives its positive and negative cases.
# rc=0 when the abc carries every payload-in-libs literal, 1 when one is missing (named on
# stdout), 2 when the file cannot be read.
check_abc_contract() {
    python3 - "$1" <<'PY'
import sys
abc = sys.argv[1]
try:
    data = open(abc, 'rb').read()
except OSError as exc:
    print('cannot read %s (%s)' % (abc, exc))
    sys.exit(2)
missing = [lit for lit in ('dotnet-payload', 'bundleCodeDir', 'payload-in-libs', 'dotnet.marker')
           if lit.encode() not in data]
if missing:
    print('ERROR: %s lacks the literal(s): %s' % (abc, ', '.join(missing)))
    sys.exit(1)
print('    payload-in-libs probe (dotnet-payload/bundleCodeDir) and the dotnet.zip fallback (dotnet.marker) are present in %s' % abc)
PY
}

# ---- harmony overlay registration (MAPFIX 2026-09-28) ------------------------------------
# The harmony UI build compiles ets/map/MapOverlay.ets against the HMS kit types, but copying the
# file is not enough: hvigor only emits a modules.abc record for sources that static imports
# reach from an entry module. Index.ets keeps its dynamic import (whose specifier stays in a
# variable, so the default flavor's abc stays byte-identical and free of the MapComponent
# declaration); the harmony branch instead rewrites its project copy to import the module
# statically. patch_harmony_index_ets applies that rewrite and fails when either anchor is
# missing, so a future Index.ets refactor cannot silently drop the overlay again.
patch_harmony_index_ets() { # <Index.ets>
    python3 - "$1" <<'PY'
import sys
path = sys.argv[1]
import_anchor = "import { process, util } from '@kit.ArkTS';"
static_import = "import { MapOverlayProxy as HmsMapOverlayProxyImpl } from '../map/MapOverlay';"
probe_anchor = "    const overlayModule: string = './map/MapOverlay';\n    try {"
probe_patch = """\
    // Static registration injected by scripts/build-arkts-shell.sh for the harmony flavor: the
    // import at the top of this file puts MapOverlay.ets into hvigor's compile graph, so
    // modules.abc carries its <bundle>/entry/ets/map/MapOverlay record (the variable-specifier
    // dynamic import below never did; HCI-HARMONY-CI, 2026-09-28).
    const staticallyLinked: ESObject = HmsMapOverlayProxyImpl;
    if (staticallyLinked !== undefined) {
      this.hmsMapOverlayModule = { MapOverlayProxy: staticallyLinked };
      return true;
    }
"""
try:
    text = open(path, encoding='utf-8').read()
except OSError as exc:
    sys.exit('cannot read %s (%s)' % (path, exc))
for anchor, what in ((import_anchor, 'the @kit.ArkTS import line'),
                     (probe_anchor, 'the probeMapOverlay dynamic-import block')):
    count = text.count(anchor)
    if count != 1:
        sys.exit('ERROR: the harmony overlay patch anchor (%s) appears %d times in %s, expected 1; '
                 'update patch_harmony_index_ets in scripts/build-arkts-shell.sh' % (what, count, path))
text = text.replace(import_anchor, import_anchor + '\n' + static_import, 1)
text = text.replace(probe_anchor, probe_patch + probe_anchor, 1)
open(path, 'w', encoding='utf-8').write(text)
print('    harmony overlay static registration injected: %s' % path)
PY
}

# check_harmony_overlay_abc <abc>: the compiled harmony ui shell must carry the MapOverlay module
# record and the symbols of its compiled code (string + module-table double evidence). When the
# static registration regresses, the abc still compiles and passes every payload gate but silently
# answers capability bit 1 = 0; this gate (and its --check-overlay-abc twin) fails instead.
# rc=0 present, 1 missing (named on stdout), 2 unreadable.
check_harmony_overlay_abc() { # <abc>
    python3 - "$1" <<'PY'
import sys
abc = sys.argv[1]
try:
    data = open(abc, 'rb').read()
except OSError as exc:
    print('cannot read %s (%s)' % (abc, exc))
    sys.exit(2)
missing = []
if b'entry/ets/map/MapOverlay' not in data:
    missing.append('the MapOverlay module record (entry/ets/map/MapOverlay)')
for symbol in (b'mapOverlayView', b'markerClick', b'cameraIdle'):
    if symbol not in data:
        missing.append('the overlay symbol %s' % symbol.decode())
if missing:
    print('%s lacks %s' % (abc, ', '.join(missing)))
    sys.exit(1)
print('    MapOverlay module record and probe symbols are present in %s' % abc)
PY
}

if [ "${1:-}" = "--check-abc" ]; then
    [ -n "${2:-}" ] || die "usage: $0 --check-abc <modules.abc>"
    check_abc_contract "$2" && _abc_rc=0 || _abc_rc=$?
    case "$_abc_rc" in
        0) exit 0 ;;
        1) exit 1 ;;
        *) exit 2 ;;
    esac
fi

# --check-overlay-abc <abc>: run just the harmony overlay gate and exit. No node, hvigor or SDK
# needed; scripts/selftest-build-arkts-shell.sh drives its positive and negative cases.
if [ "${1:-}" = "--check-overlay-abc" ]; then
    [ -n "${2:-}" ] || die "usage: $0 --check-overlay-abc <modules.abc>"
    check_harmony_overlay_abc "$2" && _ov_rc=0 || _ov_rc=$?
    case "$_ov_rc" in
        0) exit 0 ;;
        1) exit 1 ;;
        *) exit 2 ;;
    esac
fi

# --patch-harmony-index <Index.ets>: apply only the harmony static registration to a page source
# (in place) and exit - the offline check for the rewrite the harmony UI build runs.
if [ "${1:-}" = "--patch-harmony-index" ]; then
    [ -n "${2:-}" ] || die "usage: $0 --patch-harmony-index <Index.ets>"
    patch_harmony_index_ets "$2" || die "the harmony overlay static registration failed (see above)"
    exit 0
fi

# check_bc_version <abc> [max-version]: read the abc version from the fixed header (8 B magic
# "PANDA\0\0\0", 4 B adler32, one byte per version component at 0x0c) and enforce the device
# ceiling. Prints the version and exits 0 when it is within the ceiling, 1 when it is newer
# (the version is still printed so the caller can name it) and 2 when the file is unreadable or
# not an abc; 'any' as the ceiling disables the check. Shared by the build path and
# --check-bc-version so the offline selftest exercises the exact gate the build runs.
check_bc_version() {
    python3 - "$1" "${2:-$MAX_BC_VERSION}" <<'PY'
import os, sys
abc, maximum = sys.argv[1], sys.argv[2]
if not os.path.isfile(abc):
    sys.stderr.write('cannot read %s (no such file)\n' % abc)
    sys.exit(2)
with open(abc, 'rb') as f:
    raw = f.read(0x10)
if len(raw) < 0x10 or raw[:5] != b'PANDA':
    sys.stderr.write('%s: not an abc file (missing the PANDA header)\n' % abc)
    sys.exit(2)
version = tuple(raw[0x0c:0x10])
print('.'.join(str(b) for b in version))
max_version = tuple(int(p) for p in maximum.split('.')) if maximum and maximum != 'any' else ()
sys.exit(1 if max_version and version > max_version else 0)
PY
}

# --check-bc-version <abc> [max-version]: run just the header/ceiling gate and exit. No node,
# hvigor or SDK needed; defaults to the build's ARKTS_MAX_BC_VERSION ceiling.
if [ "${1:-}" = "--check-bc-version" ]; then
    [ -n "${2:-}" ] || die "usage: $0 --check-bc-version <modules.abc> [max-version]"
    _bc_max="${3:-$MAX_BC_VERSION}"
    if _bc_v="$(check_bc_version "$2" "$_bc_max")"; then
        info "abc version $_bc_v is within the ceiling $_bc_max: $2"
        exit 0
    else
        _bc_rc=$?
        case "$_bc_rc" in
            1) printf 'ERROR: abc version %s is newer than the ceiling %s: %s\n' "$_bc_v" "$_bc_max" "$2" >&2
               exit 1 ;;
            *) printf 'ERROR: not an abc file (or unreadable): %s\n' "$2" >&2
               exit 2 ;;
        esac
    fi
fi

# ---- source contract (audit ARKTS-S2/S3) ------------------------------------------------
# The shell sources must not carry the migrated patterns: '@ohos' module/dynamic imports
# (the @kit.* migration), the global getContext(), the deprecated decodeWithStream() decoder or
# a global focusControl call. Comments may name the migrated APIs in prose, so the patterns
# match the import/global-call forms only.
check_source_tokens() { # <templates-dir>
    _dir="$1"
    _bad=0
    # Each spec is <ERE>|<label>; the parentheses are escaped so every pattern is a valid ERE
    # (an invalid pattern makes grep exit 2, which must never be mistaken for "no match").
    for _spec in "from '@ohos|a module import from '@ohos" "import\('@ohos|a dynamic import from '@ohos" \
                 "getContext\(|the global getContext()" "decodeWithStream\(|the deprecated decodeWithStream()" \
                 "focusControl\.|the global focusControl"; do
        _re="$(printf '%s' "$_spec" | sed 's/|.*//')"
        _label="$(printf '%s' "$_spec" | sed 's/^[^|]*|//')"
        _probe=0
        grep -qE "$_re" /dev/null || _probe=$?
        if [ "$_probe" -eq 2 ]; then
            printf 'ERROR: internal: the source gate regex %s is not a valid ERE\n' "$_re" >&2
            _bad=1
            continue
        fi
        if grep -rnE "$_re" "$_dir/ets" --include='*.ets' >/dev/null 2>&1; then
            printf 'ERROR: %s still appears in %s:\n' "$_label" "$_dir" >&2
            grep -rnE "$_re" "$_dir/ets" --include='*.ets' | sed 's/^/  /' >&2
            _bad=1
        fi
    done
    return $_bad
}

# AOT-STARTUP: the shell must keep the first-use ArkWeb mount gate. Instantiating a Web
# component starts the ArkWeb engine synchronously on the UI thread (~0.25 s on the device
# 2in1); at page build that init sat between the XComponent AttachToMainTree and its surface
# callback and pushed the AOT first frame out by the same amount (measured 796 -> 534 ms). The
# overlay components (webSlots) stay declared; only their instantiation is gated on
# webOverlaysMounted, flipped by ensureWebSlot - the single funnel every defer/ensure takes.
# A pack that drops the gate or the flip would silently regress the startup path, so the
# source contract fails and names the missing marker instead.
check_aot_startup_gate() { # <templates-dir>
    _index="$1/ets/pages/Index.ets"
    _missing=""
    for _marker in "@State webOverlaysMounted: boolean = false;" \
                   "if (!this.webOverlaysMounted) {" \
                   "this.logInfo('[maui] web overlays mounted on first use');" \
                   "if (this.webOverlaysMounted) {"; do
        grep -Fq -- "$_marker" "$_index" 2>/dev/null || _missing="$_missing
  $_marker"
    done
    if [ -n "$_missing" ]; then
        printf 'ERROR: the AOT-STARTUP first-use overlay mount gate is missing from %s:%s\n' "$_index" "$_missing" >&2
        return 1
    fi
    return 0
}

# E4-CAPACITY8: the per-slot tables must derive from WEB_SLOT_MAX and the served capacity must
# keep the 4-slot default plus the explicit 8-slot switch. The E4 root cause (2026-10-08) was a
# constant-only capacity raise: WEB_SLOT_MAX moved to 8 but 18 per-slot tables stayed at a
# hardcoded length 4, so slots 4-7 were created but never attached/served. This gate fails when
# a future edit reintroduces a fixed-length table literal or drops a derivation/switch marker.
check_slot_capacity_contract() { # <templates-dir>
    _index="$1/ets/pages/Index.ets"
    _missing=""
    for _marker in "const WEB_SLOT_MAX: number = 8;" \
                   "const WEB_SLOT_DEFAULT_MAX: number = 4;" \
                   "function slotBooleans(value: boolean): boolean[] {" \
                   "function hotSlotBooleans(): boolean[] {" \
                   "function slotNumbers(value: number): number[] {" \
                   "function slotStrings(): string[] {" \
                   "function slotControllers(): (web_webview.WebviewController | null)[] {" \
                   "function slotNavigations(): (ApprovedNavigation | null)[] {" \
                   "@State webVisible: boolean[] = slotBooleans(false);" \
                   "private webSlotCreated: boolean[] = hotSlotBooleans();" \
                   "private webControllers: (web_webview.WebviewController | null)[] = slotControllers();" \
                   "private navApproved: (ApprovedNavigation | null)[] = slotNavigations();" \
                   "private webSlotLimit: number = WEB_SLOT_DEFAULT_MAX;" \
                   "private navSlotIndexable(slot: number): boolean {" \
                   "host.notifyWebEvent('capacity', \`\${this.webSlotLimit}\`);" \
                   "const WEB_SLOT_MAX_ENV: string = 'OHOS_OVERLAY_MAX';" \
                   "const WEB_SLOT_MAX_RAWFILE: string = 'ohos-overlay-max.txt';"; do
        grep -Fq -- "$_marker" "$_index" 2>/dev/null || _missing="$_missing
  $_marker"
    done
    if [ -n "$_missing" ]; then
        printf 'ERROR: the E4-CAPACITY8 derived per-slot tables/capacity switch contract is missing from %s:%s\n' "$_index" "$_missing" >&2
        return 1
    fi
    # The exact fixed-length literals the incomplete scratch patch left behind (the red control:
    # a copy with one of these is rejected and the shape is named).
    for _bad in "[false, false, false, false]" "[0, 0, 0, 0]" "[null, null, null, null]" \
                "[true, true, false, false]" "['', '', '', '']"; do
        if grep -Fq -- "$_bad" "$_index"; then
            printf 'ERROR: %s still hardcodes a 4-slot table (%s); derive it from WEB_SLOT_MAX (E4-CAPACITY8)\n' "$_index" "$_bad" >&2
            return 1
        fi
    done
    return 0
}

# pack_sources_hash <templates-dir>: one hash over the ets/**/*.ets file list and contents, so
# the three preview packs can be compared without diffing directories.
pack_sources_hash() { # <templates-dir>
    python3 - "$1" <<'PY'
import hashlib, os, sys
tpl = sys.argv[1]
h = hashlib.sha256()
root = os.path.join(tpl, 'ets')
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(filenames):
        if not name.endswith('.ets'):
            continue
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, tpl).replace(os.sep, '/')
        h.update(rel.encode())
        h.update(b'\0')
        h.update(hashlib.sha256(open(path, 'rb').read()).digest())
print(h.hexdigest())
PY
}

# check_sources_contract [templates-dir]: the token and AOT-STARTUP gate for one pack, plus the
# cross-pack byte-identity check when no directory is given (the packaging harness pins the
# sources).
check_sources_contract() { # [<templates-dir>]
    if [ -n "${1:-}" ]; then
        check_source_tokens "$1" || return 1
        check_aot_startup_gate "$1" || return 1
        check_slot_capacity_contract "$1"
        return $?
    fi
    _hash=""
    _root="${ARKTS_PACK_ROOT:-$W}"
    for _v in 1.0.0-preview.22 1.0.0-preview.23 1.0.0-preview.24; do
        _tpl="$_root/packs/Microsoft.OpenHarmony.Sdk/$_v/templates"
        check_source_tokens "$_tpl" || return 1
        check_aot_startup_gate "$_tpl" || return 1
        check_slot_capacity_contract "$_tpl" || return 1
        _h="$(pack_sources_hash "$_tpl")" || return 1
        if [ -z "$_hash" ]; then
            _hash="$_h"
            _first="$_v"
        elif [ "$_h" != "$_hash" ]; then
            printf 'ERROR: %s/templates/ets sources differ from %s/templates/ets (all three preview packs must stay byte-identical)\n' "$_v" "$_first" >&2
            return 1
        fi
    done
    printf '    shell sources clean (no @ohos import, getContext(), decodeWithStream() or focusControl), AOT-STARTUP mount gate and E4-CAPACITY8 derived-slot-table/switch contract present, and byte-identical across preview.22/23/24 (sources %s)\n' "$_hash"
}

# pack_abc_provenance_json <dist-dir>: prints the provenance document for the two dist
# artifacts (schema pinned by the pack gate below).
pack_abc_provenance_json() { # <dist-dir>
    python3 - "$1" "${ARKTS_PACK_ROOT:-$W}" <<'PY'
import hashlib, json, os, sys
dist, root = sys.argv[1], sys.argv[2]
tpl = os.path.join(root, 'packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.24/templates')

def sha(path):
    return hashlib.sha256(open(path, 'rb').read()).hexdigest()

def abc_version(path):
    raw = open(path, 'rb').read(0x10)
    if raw[:5] != b'PANDA':
        sys.exit('not an abc file: ' + path)
    return '.'.join(str(b) for b in raw[0x0c:0x10])

variants = {}
for name, dist_name, pack_name, sources in (
    ('headless', 'modules.headless.abc', 'modules.abc',
     ['entryability/EntryAbility.ets']),
    ('ui', 'modules.abc', 'modules.ui.abc',
     ['entryability/EntryAbility.ui.ets', 'pages/Index.ets', 'pages/SubWindow.ets']),
):
    dist_path = os.path.join(dist, dist_name)
    if not os.path.exists(dist_path):
        sys.exit('missing dist artifact: ' + dist_path)
    variants[name] = {
        'file': pack_name,
        'dist': dist_name,
        'bytes': os.path.getsize(dist_path),
        'sha256': sha(dist_path),
        'abcVersion': abc_version(dist_path),
        'sources': {rel: sha(os.path.join(tpl, 'ets', rel)) for rel in sources},
    }

print(json.dumps({
    'schema': 1,
    'compiler': {
        'script': 'scripts/build-arkts-shell.sh',
        'flavor': 'openharmony',
        'compatibleSdkVersion': '18',
        'modelVersion': '6.0.2',
        'hvigor': '6.26.4',
        'abcVersion': '13.0.1.0',
    },
    'variants': variants,
}, indent=2, sort_keys=True))
PY
}

# check_pack_abc [dist-dir]: the abc provenance gate. Verifies, per preview pack, the
# provenance record (size/sha/abc version), the per-variant literal contract, the source hashes
# (a source edit without a rebuild fails here), the absence of the redundant modules.shell.abc
# and the byte-identity across the three packs; with a dist dir the freshly rebuilt artifacts
# must match the installed packs byte-for-byte.
check_pack_abc() { # [<dist-dir>]
    python3 - "${ARKTS_PACK_ROOT:-$W}" "${1:-}" <<'PY'
import hashlib, json, os, sys
root, dist = sys.argv[1], sys.argv[2]
versions = ['1.0.0-preview.22', '1.0.0-preview.23', '1.0.0-preview.24']
common = ['dotnet-payload', 'bundleCodeDir', 'payload-in-libs', 'dotnet.marker',
          'notifyActivation', 'onNewWant']
ui_only = ['ohos_dotnet_surface', 'ohos_dotnet_input', '__hwvInvokeDotNet', './map/MapOverlay',
           'registerLiveViewSink', 'notifyLiveViewResult', '@kit.LiveViewKit',
           'SystemCapability.LiveView.LiveViewService',
           'registerTtsSink', 'notifyTtsResult', '@kit.CoreSpeechKit',
           'SystemCapability.AI.TextToSpeech', 'notifyTextComposition',
           'notifyAnimationReduce', '@kit.AccessibilityKit',
           'SystemCapability.BarrierFree.Accessibility.Core',
           'application/wasm',
           'ohos_dotnet_subwindow', 'registerSubWindowSink', 'notifySubWindowEvent']
errors = []
provenance_ref = None
abc_ref = {}
for version in versions:
    ets = os.path.join(root, 'packs/Microsoft.OpenHarmony.Sdk', version, 'templates/ets')
    prov_path = os.path.join(ets, 'abc-provenance.json')
    if not os.path.exists(prov_path):
        errors.append('%s: missing abc-provenance.json (run --install-packs)' % version)
        continue
    prov = json.load(open(prov_path))
    if provenance_ref is None:
        provenance_ref = (version, prov)
    elif prov != provenance_ref[1]:
        errors.append('%s: abc-provenance.json differs from %s' % (version, provenance_ref[0]))
    for variant, meta in sorted(prov.get('variants', {}).items()):
        path = os.path.join(ets, meta['file'])
        if not os.path.exists(path):
            errors.append('%s: missing %s' % (version, meta['file']))
            continue
        raw = open(path, 'rb').read()
        if len(raw) != meta['bytes']:
            errors.append('%s: %s is %d bytes, provenance records %d' % (version, meta['file'], len(raw), meta['bytes']))
        if hashlib.sha256(raw).hexdigest() != meta['sha256']:
            errors.append('%s: %s sha256 does not match the provenance' % (version, meta['file']))
        version_read = '.'.join(str(b) for b in raw[0x0c:0x10]) if raw[:5] == b'PANDA' else '<not abc>'
        if version_read != prov['compiler']['abcVersion']:
            errors.append('%s: %s abc version %s, provenance records %s' % (version, meta['file'], version_read, prov['compiler']['abcVersion']))
        for literal in common:
            if literal.encode() not in raw:
                errors.append('%s: %s lacks the payload literal %s' % (version, meta['file'], literal))
        if variant == 'ui':
            for literal in ui_only:
                if literal.encode() not in raw:
                    errors.append('%s: ui abc lacks the UI literal %s' % (version, literal))
        if variant == 'headless':
            for literal in ui_only:
                if literal.encode() in raw:
                    errors.append('%s: headless abc carries the UI literal %s' % (version, literal))
        for rel, want in sorted(meta.get('sources', {}).items()):
            source = os.path.join(ets, rel)
            if not os.path.exists(source):
                errors.append('%s: provenance names a missing source %s' % (version, rel))
            elif hashlib.sha256(open(source, 'rb').read()).hexdigest() != want:
                errors.append('%s: source drift in %s (rebuild the abc and run --install-packs)' % (version, rel))
        if variant in abc_ref:
            if abc_ref[variant][1] != raw:
                errors.append('%s: %s differs from %s' % (version, meta['file'], abc_ref[variant][0]))
        else:
            abc_ref[variant] = (version, raw)
        if dist:
            rebuilt = os.path.join(dist, meta['dist'])
            if not os.path.exists(rebuilt):
                errors.append('%s: rebuilt %s is missing from %s' % (version, meta['dist'], dist))
            elif open(rebuilt, 'rb').read() != raw:
                errors.append('%s: %s differs from the installed %s (rebuild all variants and run --install-packs)' % (version, meta['dist'], meta['file']))
    if os.path.exists(os.path.join(ets, 'modules.shell.abc')):
        errors.append('%s: redundant modules.shell.abc is still present (use modules.ui.abc)' % version)
if errors:
    for error in errors:
        print('ERROR: ' + error, file=sys.stderr)
    sys.exit(1)
variants = sorted(provenance_ref[1]['variants']) if provenance_ref else []
print('    pack abc provenance clean: %s variants=%s packs=%s' % (
    provenance_ref[0] if provenance_ref else '<none>',
    ','.join(variants),
    ','.join(versions)))
for variant, (version, raw) in sorted(abc_ref.items()):
    print('    %s %s: %d bytes sha256=%s abcVersion=%s' % (
        variant, version, len(raw), hashlib.sha256(raw).hexdigest(), '.'.join(str(b) for b in raw[0x0c:0x10])))
PY
}

# --check-sources [templates-dir]: run just the source contract gate.
if [ "${1:-}" = "--check-sources" ]; then
    if check_sources_contract "${2:-}"; then
        info "shell source contract clean${2:+: $2}"
        exit 0
    fi
    die "the shell source contract check failed (see above)"
fi

# --check-pack-abc [dist-dir]: run just the abc provenance gate.
if [ "${1:-}" = "--check-pack-abc" ]; then
    if check_pack_abc "${2:-}"; then
        info "pack abc provenance gate passed${2:+ against $2}"
        exit 0
    fi
    die "the pack abc provenance gate failed (see above)"
fi

# --install-packs [dist-dir]: install the two rebuilt abc artifacts into all three preview
# packs (ui -> modules.ui.abc, headless -> modules.abc), drop the redundant modules.shell.abc
# and refresh the abc-provenance.json record, then re-run the gate. No node/hvigor needed.
if [ "${1:-}" = "--install-packs" ]; then
    _dist="${2:-${OUT_DIR:-$W/dist/ets}}"
    _root="${ARKTS_PACK_ROOT:-$W}"
    [ -d "$_dist" ] || die "no dist directory: $_dist"
    _prov="$(pack_abc_provenance_json "$_dist")" || die "cannot derive the abc provenance from $_dist"
    _prov_tmp="$(mktemp "${TMPDIR:-/tmp}/abc-provenance.XXXXXX")"
    printf '%s\n' "$_prov" > "$_prov_tmp" || die "cannot write the provenance temp file"
    for _v in 1.0.0-preview.22 1.0.0-preview.23 1.0.0-preview.24; do
        _ets="$_root/packs/Microsoft.OpenHarmony.Sdk/$_v/templates/ets"
        [ -d "$_ets" ] || die "missing pack templates: $_ets"
        cp "$_dist/modules.abc" "$_ets/modules.ui.abc" || die "cannot install the ui abc into $_v"
        cp "$_dist/modules.headless.abc" "$_ets/modules.abc" || die "cannot install the headless abc into $_v"
        rm -f "$_ets/modules.shell.abc"
        cp "$_prov_tmp" "$_ets/abc-provenance.json" || die "cannot write the provenance into $_v"
        info "installed abc into $_v (ui $(stat -c%s "$_ets/modules.ui.abc") B, headless $(stat -c%s "$_ets/modules.abc") B)"
    done
    rm -f "$_prov_tmp"
    check_pack_abc "$_dist" || die "the installed packs failed the abc provenance gate"
    info "pack abc installed and verified across preview.22/23/24"
    exit 0
fi

# --diagnose-log <file>: attribute a saved hvigor log and exit. Needs no node or SDK, so it also
# works on a log copied from another machine; scripts/selftest-build-arkts-shell.sh drives the
# 00302013 positive and negative cases through it. Exit 0 = signature found (handling steps
# printed), 1 = not found.
if [ "${1:-}" = "--diagnose-log" ]; then
    [ -n "${2:-}" ] || die "usage: $0 --diagnose-log <file>"
    [ -f "$2" ] || die "no such log file: $2"
    if diagnose_hvigor_log "$2"; then
        exit 0
    fi
    info "no 00302013/'root node' signature in $2"
    exit 1
fi

# --check-project-deps <dir>: run only the hvigor-config dependency guard over an existing
# project dir. Exit 0 = clean; 1 = a hvigor plugin is listed (reason printed by the guard);
# 2 = hvigor/hvigor-config.json5 missing.
if [ "${1:-}" = "--check-project-deps" ]; then
    [ -n "${2:-}" ] || die "usage: $0 --check-project-deps <project-dir>"
    check_hvigor_config_deps "$2" && _crc=0 || _crc=$?
    case "$_crc" in
        0) info "hvigor-config dependencies clean: $2"; exit 0 ;;
        1) exit 1 ;;
        *) die "no hvigor/hvigor-config.json5 under $2" ;;
    esac
fi

# --print-config: print the resolved flavor configuration (SDK roots, runtimeOS, compatible and
# target version strings, the exact externalApiPaths and the abc ceiling) and exit - no node,
# hvigor or SDK needed. This is the offline check for the harmony branch's path resolution and
# externalApiPaths injection; scripts/selftest-build-arkts-shell.sh drives both flavors through it.
if [ "${1:-}" = "--print-config" ]; then
    if [ -f "$SDK_ETS_ROOT/oh-uni-package.json" ]; then
        PLATFORM_VERSION="$(read_sdk_meta platformVersion)"
        API_VERSION="$(read_sdk_meta apiVersion)"
    else
        PLATFORM_VERSION="${ARKTS_PLATFORM_VERSION:-26.0.0}"
        API_VERSION="${ARKTS_API_VERSION:-26}"
    fi
    TARGET_VERSION="$(compute_target_version "$PLATFORM_VERSION" "$API_VERSION")"
    printf 'flavor=%s\n' "$SDK_FLAVOR"
    printf 'sdk_root=%s\n' "$SDK"
    printf 'sdk_ets_root=%s\n' "$SDK_ETS_ROOT"
    printf 'sdk_ets_extra=%s\n' "$SDK_ETS_EXTRA"
    printf 'runtime_os=%s\n' "$RUNTIME_OS"
    printf 'platform_version=%s\n' "$PLATFORM_VERSION"
    printf 'api_version=%s\n' "$API_VERSION"
    printf 'compatible_sdk_version=%s\n' "$COMPATIBLE_SDK_VERSION"
    printf 'target_version=%s\n' "$TARGET_VERSION"
    printf 'external_api_paths=%s\n' "$(resolve_external_api_paths)"
    printf 'max_bc_version=%s\n' "$MAX_BC_VERSION"
    printf 'variant=%s\n' "$VARIANT"
    printf 'project_dir=%s\n' "$PROJ"
    printf 'dist_dir=%s\n' "$OUT_DIR"
    exit 0
fi

# --scaffold-only <dir>: write only the generated project configuration - no node, no hvigor
# download, no SDK symlink and no template copy - so the selftest can assert the exact texts
# hvigor reads (empty dependencies, modelVersion agreement, strictMode). Platform values come
# from the SDK when present, else ARKTS_PLATFORM_VERSION / ARKTS_API_VERSION.
if [ "${1:-}" = "--scaffold-only" ]; then
    [ -n "${2:-}" ] || die "usage: $0 --scaffold-only <dir>"
    PROJ="$2"
    if [ -f "$SDK_ETS_ROOT/oh-uni-package.json" ]; then
        PLATFORM_VERSION="$(read_sdk_meta platformVersion)"
        API_VERSION="$(read_sdk_meta apiVersion)"
    else
        PLATFORM_VERSION="${ARKTS_PLATFORM_VERSION:-26.0.0}"
        API_VERSION="${ARKTS_API_VERSION:-26}"
    fi
    TARGET_VERSION="$(compute_target_version "$PLATFORM_VERSION" "$API_VERSION")"
    make_project_dirs
    write_project_configs
    check_hvigor_config_deps "$PROJ" && _crc=0 || _crc=$?
    if [ "$_crc" -ne 0 ]; then
        die "the generated hvigor-config.json5 failed the hvigor-plugin dependency guard (see above)"
    fi
    info "scaffold configs written: $PROJ (flavor $SDK_FLAVOR, modelVersion $MODEL_VERSION, runtimeOS $RUNTIME_OS, compatibleSdkVersion $COMPATIBLE_SDK_VERSION, targetSdkVersion $TARGET_VERSION)"
    exit 0
fi

# Source contract (audit ARKTS-S2/S3): the shell sources must not carry the migrated patterns
# and all three preview packs must stay byte-identical before a build consumes them.
check_sources_contract || die "the shell source contract gate failed (fix the sources or run --check-sources)"

[ -x "$NODE_BIN" ] || die "node not found (set NODE=)"
# NODE= overrides the host node. The device's /data/service/hnp node (v24.13.0) aborts with a
# V8 fatal ("Check failed: 12 == (*__errno_location())") before it runs anything, so fall back
# to the node on PATH unless the override passes a trivial smoke test.
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
[ -f "$SDK_ETS_ROOT/oh-uni-package.json" ] || die "oh-uni-package.json not found under $SDK_ETS_ROOT (set OHOS_SDK_ROOT, or ARKTS_HARMONY_SDK_ROOT for the harmony flavor)"

# hvigor's own hap packaging needs java; the ArkTS compilation does not. Use JAVA_HOME or
# a harmonybrew JDK when present.
if [ -z "${JAVA_HOME:-}" ]; then
    for cand in "$HOME/.harmonybrew/opt/openjdk@17" "$HOME/.harmonybrew/opt/openjdk@21" \
                "$HOME/.harmonybrew/opt/openjdk@25" "$HOME/.harmonybrew/opt/openjdk"; do
        if [ -x "$cand/bin/java" ]; then JAVA_HOME="$cand"; break; fi
    done
fi
[ -n "${JAVA_HOME:-}" ] && info "java: $JAVA_HOME"

PLATFORM_VERSION="$(read_sdk_meta platformVersion)"
API_VERSION="$(read_sdk_meta apiVersion)"
TARGET_VERSION="$(compute_target_version "$PLATFORM_VERSION" "$API_VERSION")"
info "SDK $SDK (flavor $SDK_FLAVOR, platform $PLATFORM_VERSION, API $API_VERSION)"

# 1) hvigor ------------------------------------------------------------------
# The two tarballs are downloaded and then executed by node (hvigor.js assembleHap), so they
# are pinned by sha256 (A2): a compromised mirror, a DNS/TLS MITM or a poisoned cache must
# not get code execution on the build host. The pins are for the default HVIGOR_VERSION
# 6.26.4: a fresh download on 2026-09-23 had these digests and they matched both the local
# cache that produced the working device build and the mirror's registry metadata
# (dist.shasum / dist.integrity). A version bump must update the pins, or pass
# HVIGOR_SHA256 / HVIGOR_OHOS_PLUGIN_SHA256 explicitly. The sha256 pin covers the bytes; the
# member-list gate below covers what `tar xzf` would do with them (tar-slip), which matters
# when the pins are explicitly overridden.
HVIGOR_SHA256="${HVIGOR_SHA256:-33b2741aca3ee00f6375d6a988b4951875a0c2369d0b0ce3568a6d69249ad82d}"
HVIGOR_OHOS_PLUGIN_SHA256="${HVIGOR_OHOS_PLUGIN_SHA256:-2f97a309bad4297a478091278ed6372c18330f1159551427529436c3525779b6}"
# HVIGOR_JS overrides the hvigor entry point (a wrapper or the copy bundled with DevEco Studio /
# the Command Line Tools). The pinned mirror version 6.26.4 belongs to a DevEco-26 toolchain:
# against a 6.0/6.1 SDK it fails with 00303313/00303312, so an SDK-matched hvigor must be used
# there (scripts/setup-harmony-sdk.sh --download ships one; see the packaging doc). The project's
# node_modules symlink still comes from HVIGOR_DIR, so point HVIGOR_DIR at the directory whose
# node_modules holds the matching @ohos/hvigor* packages when overriding.
HVIGOR_JS_OVERRIDE="${HVIGOR_JS:-}"
HVIGOR_JS="${HVIGOR_JS_OVERRIDE:-$HVIGOR_DIR/node_modules/@ohos/hvigor/bin/hvigor.js}"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"
    fi
}

# rc=0 only when $1 hashes to the pinned $2; the caller reports what went wrong.
verify_hvigor_tgz() {
    _file="$1"; _want="$2"
    [ -f "$_file" ] || return 1
    _have="$(sha256_of "$_file")" || return 1
    [ "$_have" = "$_want" ] || return 1
    return 0
}

if [ -n "$HVIGOR_JS_OVERRIDE" ] && [ ! -f "$HVIGOR_JS" ]; then
    die "HVIGOR_JS is set but not a file: $HVIGOR_JS"
fi
if [ -z "$HVIGOR_JS_OVERRIDE" ] && [ ! -f "$HVIGOR_JS" ]; then
    info "installing hvigor $HVIGOR_VERSION from $MIRROR"
    mkdir -p "$HVIGOR_DIR/node_modules/@ohos"
    for pkg in hvigor hvigor-ohos-plugin; do
        case "$pkg" in
            hvigor)             want="$HVIGOR_SHA256" ;;
            hvigor-ohos-plugin) want="$HVIGOR_OHOS_PLUGIN_SHA256" ;;
        esac
        tgz="$HVIGOR_DIR/$pkg.tgz"
        if [ -f "$tgz" ]; then
            # Cache from an earlier run: it is executed too, so verify before unpacking.
            if ! verify_hvigor_tgz "$tgz" "$want"; then
                die "sha256 mismatch for the cached $pkg tarball
  file     $tgz
  expected $want
  actual   $(sha256_of "$tgz" 2>/dev/null || printf '<unreadable>')
  refusing to unpack/execute it; replace or delete the file and retry"
            fi
        else
            # The mirror serves the standard npm tarball path (scope stripped); the
            # @ohos-prefixed name its metadata advertises currently 404s, so try it second.
            url="$MIRROR/@ohos/$pkg/-/$pkg-$HVIGOR_VERSION.tgz"
            url_alt="$MIRROR/@ohos/$pkg/-/@ohos-$pkg-$HVIGOR_VERSION.tgz"
            part="$tgz.part.$$"
            rm -f "$part"
            curl -fsSL --retry 3 -o "$part" "$url" \
                || curl -fsSL --retry 3 -o "$part" "$url_alt" \
                || die "download failed: $url (also tried $url_alt)"
            # Verify before the file enters the cache or is unpacked, and never keep a
            # failed download around (the next run would trip over it).
            if ! verify_hvigor_tgz "$part" "$want"; then
                _have="$(sha256_of "$part" 2>/dev/null || printf '<unreadable>')"
                rm -f "$part"
                die "sha256 mismatch for the downloaded $pkg tarball
  url      $url
  expected $want
  actual   $_have
  refusing to unpack/execute it (compromised mirror, or HVIGOR_VERSION bumped without pins?)"
            fi
            mv "$part" "$tgz"
        fi
        # Second gate after the sha256 pin: the member list must be safe to unpack. A crafted
        # tarball (overridden pins, or a poisoned cache whose hash was recomputed) can carry
        # `../` or absolute members and write outside node_modules via tar-slip; this check runs
        # after the hash verification and before the first extraction, and never unpacks.
        if verify_tgz_members "$tgz"; then
            _mrc=0
        else
            _mrc=$?   # captured here so `set -e` cannot skip the report below
        fi
        if [ "$_mrc" -ne 0 ]; then
            case "$_mrc" in
                1) _why="cannot list it as a gzip tarball" ;;
                2) _why="it has no members" ;;
                *) _why="it carries unsafe member names (absolute path or '..' traversal)" ;;
            esac
            printf 'ERROR: %s tarball: %s\n  file %s\n' "$pkg" "$_why" "$tgz" >&2
            unsafe_tgz_members "$tgz" | sed 's/^/    /' >&2
            die "refusing to unpack it; replace or delete the file and retry"
        fi
        rm -rf "$HVIGOR_DIR/node_modules/@ohos/package" "$HVIGOR_DIR/node_modules/@ohos/$pkg"
        tar xzf "$tgz" -C "$HVIGOR_DIR/node_modules/@ohos" || die "cannot unpack $tgz"
        mv "$HVIGOR_DIR/node_modules/@ohos/package" "$HVIGOR_DIR/node_modules/@ohos/$pkg" \
            || die "cannot install $pkg under $HVIGOR_DIR/node_modules/@ohos"
        info "installed $pkg $HVIGOR_VERSION (sha256 verified)"
    done
fi

# 2) version-nested SDK root -------------------------------------------------
# The default flavor exposes a version-nested symlink root for local.properties (hvigor resolves
# the SDK from it). The harmony flavor keeps the DevEco SDK home as-is: its layout already carries
# default/openharmony (toolchain) and default/hms (kits), and hvigor resolves both from
# DEVECO_SDK_HOME.
if [ "$SDK_FLAVOR" = harmony ]; then
    SDK_ROOT="$SDK"
else
    SDK_ROOT="$BUILD/sdk"
    rm -rf "$SDK_ROOT"; mkdir -p "$SDK_ROOT/$PLATFORM_VERSION"
    for c in ets js native previewer toolchains; do
        [ -e "$SDK/$c" ] && ln -s "$SDK/$c" "$SDK_ROOT/$PLATFORM_VERSION/$c"
    done
fi

# 3) project scaffold --------------------------------------------------------
case "$VARIANT" in
    ui|headless) ;;
    *) die "ARKTS_SHELL_VARIANT must be 'ui' or 'headless' (got '$VARIANT')" ;;
esac
rm -rf "$PROJ"
make_project_dirs
if [ "$VARIANT" = ui ]; then
    # UI variant: the UI-enabled ability + the ArkUI page from the platform pack templates.
    mkdir -p "$PROJ/entry/src/main/ets/pages"
    cp "$TPL/ets/entryability/EntryAbility.ui.ets" "$PROJ/entry/src/main/ets/entryability/EntryAbility.ets"
    cp "$TPL/ets/pages/Index.ets" "$PROJ/entry/src/main/ets/pages/Index.ets"
    # MULTIWINDOW-M: the shell-drawn subwindow page (named route, loaded by Index after
    # createSubWindowWithOptions). Harmless for the harmony flavor: it only imports @kit.* modules
    # the default SDK provides.
    cp "$TPL/ets/pages/SubWindow.ets" "$PROJ/entry/src/main/ets/pages/SubWindow.ets"
    # Map overlay (R2-3 + MAPFIX): ets/map/MapOverlay.ets names the MapComponent ArkUI component,
    # which only the HarmonyOS SDK declares (hms/ets), so only the harmony branch copies it into
    # the project. Copying alone never compiled it (no modules.abc record; HCI-HARMONY-CI
    # 2026-09-28), so the same branch injects the static import into its Index.ets copy: the
    # compile graph then registers <bundle>/entry/ets/map/MapOverlay and probeMapOverlay takes
    # the statically imported proxy. The default OpenHarmony SDK build must not compile it: the
    # page's dynamic import fails at runtime (no module record), the Map sink reports capability
    # bit 1 = 0 and the managed side keeps the documented degradation.
    if [ "$SDK_FLAVOR" = harmony ]; then
        mkdir -p "$PROJ/entry/src/main/ets/map"
        cp "$TPL/ets/map/MapOverlay.ets" "$PROJ/entry/src/main/ets/map/MapOverlay.ets"
        patch_harmony_index_ets "$PROJ/entry/src/main/ets/pages/Index.ets" \
            || die "cannot register ets/map/MapOverlay.ets in the harmony compile graph (see the log above)"
    fi
    OUT_NAME=modules.abc
else
    # Headless variant: the page-free ability only. No pages/Index is copied and main_pages
    # stays empty below, matching the packaging target's no-OpenHarmonyUIPage path.
    cp "$TPL/ets/entryability/EntryAbility.ets" "$PROJ/entry/src/main/ets/entryability/EntryAbility.ets"
    OUT_NAME=modules.headless.abc
fi
cp "$TPL/resources/base/element/color.json" "$PROJ/entry/src/main/resources/base/element/"
cp "$TPL/resources/base/media/app_icon.png" "$PROJ/entry/src/main/resources/base/media/"
cp "$TPL/resources/base/media/app_icon.png" "$PROJ/AppScope/resources/base/media/"

write_project_configs
# Fool-proofing for hvigor 00302013 (official handling step 2): the config just written must not
# list the bundled hvigor plugin. The generator never does, but a hand/template edit that added
# one fails here with the official pointer instead of a cryptic "root node" abort later.
check_hvigor_config_deps "$PROJ" && _grc=0 || _grc=$?
if [ "$_grc" -ne 0 ]; then
    die "generated hvigor-config.json5 failed the hvigor-plugin dependency guard (see ide-hvigor-errorcode-00302 step 2; fix $PROJ/hvigor/hvigor-config.json5)"
fi
printf 'sdk.dir=%s\nnodejs.dir=%s\n' "$SDK_ROOT" "${NODE_HOME:-$HOME/.harmonybrew}" > "$PROJ/local.properties"
# The hvigorfile imports @ohos/hvigor-ohos-plugin; with TYPECHECK=1 hvigor typechecks that
# file too, and its module resolution only looks inside the project, so expose the installed
# hvigor packages as the project's node_modules (the layout DevEco Studio produces).
ln -sfn "$HVIGOR_DIR/node_modules" "$PROJ/node_modules"

# 4) build -------------------------------------------------------------------
# hvigor resolves the plugin by walking up from the project directory; the default project
# location ($HVIGOR_DIR/project) therefore sits next to the installed packages.
if [ -z "$HVIGOR_JS_OVERRIDE" ] && [ ! -e "$HVIGOR_DIR/node_modules/@ohos/hvigor-ohos-plugin" ]; then
    die "hvigor packages missing under $HVIGOR_DIR/node_modules/@ohos"
fi

info "running hvigor assembleHap"
# hvigor's own PackageHap step needs java (for the packing jar); the ArkTS compilation
# (everything this script needs) runs before it, so a failed PackageHap is tolerated.
# The log directory is created here because a reused HVIGOR_DIR may sit outside BUILD (the
# default HVIGOR_DIR is created by the install step in section 1, but a cached one is not).
mkdir -p "$BUILD"
LOG="$BUILD/hvigor-build.log"
# externalApiPaths: the OpenHarmony ets declarations always; the harmony flavor additionally
# exposes the HMS kit declarations (hms/ets), which is what lets the Share/Scan/... sinks compile
# against their real types there (the OpenHarmony SDK has no @kit.ShareKit declaration at all).
# resolve_external_api_paths is the single source --print-config prints it too.
EXTERNAL_API_PATHS="$(resolve_external_api_paths)"
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
    diagnose_hvigor_log "$LOG" || true
    die "hvigor failed (full log: $LOG)"
done
# The ArkTS compile itself must have finished: the tolerated failure above is hvigor's own
# PackageHap step, but a `Failed :entry:default@CompileArkTS` line means the abc below is not
# the compiled result of these sources and must not be shipped as the shell.
COMPILE_LINE="$(grep -E 'Finished :entry:default@CompileArkTS|Failed :entry:default@CompileArkTS' "$LOG" | tail -1 || true)"
case "$COMPILE_LINE" in
    *'Finished :entry:default@CompileArkTS'*)
        printf '    %s\n' "$COMPILE_LINE" ;;
    *)
        tail -20 "$LOG" | sed 's/^/    /'
        diagnose_hvigor_log "$LOG" || true
        die "hvigor did not report a finished ArkTS compile (full log: $LOG)" ;;
esac

ABC="$(find "$PROJ/entry/build" -name modules.abc | head -1)"
[ -n "$ABC" ] || die "modules.abc not produced (see .arkts-build/project/.hvigor/outputs/build-logs)"
mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/$OUT_NAME"
cp "$ABC" "$OUT_FILE"
# Read the abc version back from the fixed header and fail when it is newer than the runtime
# limit, because the device then refuses to load the module (exit 254). check_bc_version is the
# same gate --check-bc-version exposes (see its definition above).
if BC_VERSION="$(check_bc_version "$OUT_FILE" "$MAX_BC_VERSION")"; then
    :
else
    _bc_rc=$?
    case "$_bc_rc" in
        1) die "abc version $BC_VERSION is newer than $MAX_BC_VERSION (set ARKTS_MAX_BC_VERSION=any to allow, or ARKTS_COMPATIBLE_SDK_VERSION to a level whose es2abc output the device accepts)" ;;
        *) die "cannot read the abc version from $OUT_FILE (not an abc file?)" ;;
    esac
fi
info "ArkTS shell compiled ($VARIANT): $OUT_FILE ($(stat -c%s "$OUT_FILE") bytes, abc version $BC_VERSION, compatibleSdkVersion $COMPATIBLE_SDK_VERSION)"
# Compiled-artifact gate: the abc must be the payload-in-libs shell - it probes the staged
# bundle payload (libs/<abi>/.dotnet-payload.json under bundleCodeDir) and keeps the dotnet.zip
# fallback (the P17 dotnet.marker). A build from a stale EntryAbility source (or the wrong
# template) still compiles and passes the version check but would always take the extraction
# path, so fail here; --check-abc exposes the same check to the selftest.
check_abc_contract "$OUT_FILE" || die "the compiled shell lacks the payload-in-libs probe; rebuild from packs/.../templates/ets/entryability"
# HarmonyOS-flavor overlay gate (MAPFIX 2026-09-28): the injected static import must have put
# MapOverlay.ets into modules.abc. The same gate runs in CI
# (.github/workflows/harmony-flavor.yml, HARMONY_REQUIRE_MAP_OVERLAY=1) and offline through
# --check-overlay-abc; without it a regression compiles clean but silently answers bit 1 = 0.
if [ "$SDK_FLAVOR" = harmony ] && [ "$VARIANT" = ui ]; then
    check_harmony_overlay_abc "$OUT_FILE" \
        || die "the harmony ui abc does not carry the MapOverlay module record/symbols (did patch_harmony_index_ets run? see the log above)"
fi
# Variant/provenance gate: when both variant artifacts are present, the freshly built abc must
# match the installed packs byte-for-byte and carry the per-variant literals (run
# ARKTS_SHELL_VARIANT=headless too to complete the pair).
if [ -f "$OUT_DIR/modules.abc" ] && [ -f "$OUT_DIR/modules.headless.abc" ]; then
    if [ -f "$TPL/ets/abc-provenance.json" ]; then
        check_pack_abc "$OUT_DIR" || die "the built abc does not match the installed packs (rebuild both variants and run --install-packs)"
    else
        info "no abc-provenance.json in the packs yet; run --install-packs to install and pin the rebuilt abc"
    fi
else
    info "variant/provenance gate not run: build both ARKTS_SHELL_VARIANT=ui and =headless first (the other artifact is missing from $OUT_DIR)"
fi
if [ "$VARIANT" = ui ]; then
    info "package it with: -p:OpenHarmonyUIPage=pages/Index -p:OpenHarmonyArktsModulesAbc=$OUT_FILE"
else
    info "package it with: -p:OpenHarmonyArktsModulesAbc=$OUT_FILE"
    info "install it as the default headless shell: cp $OUT_FILE $TPL/ets/modules.abc (and the other preview packs)"
fi
