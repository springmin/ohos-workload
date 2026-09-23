#!/bin/sh
# Builds the ArkTS shell (ability + ArkUI page) with the official hvigor toolchain and writes
# dist/ets/modules.abc; packaging consumes it via -p:OpenHarmonyArktsModulesAbc together with
# -p:OpenHarmonyUIPage (see the OpenHarmonyUIPage packing doc).
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
if [ -z "${BASH_VERSION:-}" ] && command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
fi
set -e
W="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${OHOS_SDK_ROOT:-$HOME/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_2}"
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
# compatibleSdkVersion of the generated hvigor project. 18 is the lowest API level whose
# es2abc output is 13.0.1.0, the newest abc the device runtime accepts (see the abc note
# in the header). Raise it only together with ARKTS_MAX_BC_VERSION.
COMPATIBLE_SDK_VERSION="${ARKTS_COMPATIBLE_SDK_VERSION:-18}"
MAX_BC_VERSION="${ARKTS_MAX_BC_VERSION:-13.0.1.0}"

info() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

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
HVIGOR_JS="$HVIGOR_DIR/node_modules/@ohos/hvigor/bin/hvigor.js"

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

if [ ! -f "$HVIGOR_JS" ]; then
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

python3 - "$PROJ" "$PLATFORM_VERSION" "$API_VERSION" "$TYPECHECK" "$BUNDLE_NAME" "$COMPATIBLE_SDK_VERSION" <<'PY'
import json, os, sys
proj, platform_version, api_version, typecheck, bundle_name, compatible_sdk_version = sys.argv[1:7]
typecheck_json = 'true' if typecheck == '1' else 'false'
def w(rel, text):
    with open(os.path.join(proj, rel), 'w') as f: f.write(text)

strings = [{"name": n, "value": "opendotnet"} for n in
           ("app_name", "module_desc", "EntryAbility_desc", "EntryAbility_label")]
for base in ('entry/src/main/resources/base/element', 'AppScope/resources/base/element'):
    w(f'{base}/string.json', json.dumps({"string": strings}, indent=2))
w('entry/src/main/resources/base/profile/main_pages.json', json.dumps({"src": ["pages/Index"]}))
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
w('hvigor/hvigor-config.json5', """{
  modelVersion: '6.0.0',
  dependencies: {},
  execution: { analyze: 'normal', daemon: false, incremental: false, parallel: true, typeCheck: __TYPECHECK__ },
  logging: { level: 'info' },
  debugging: { stacktrace: false },
}
""".replace('__TYPECHECK__', typecheck_json))
w('build-profile.json5', f"""{{
  app: {{
    products: [
      {{
        name: 'default',
        compileSdkVersion: '{platform_version}',
        compatibleSdkVersion: '{compatible_sdk_version}',
        targetSdkVersion: '{platform_version}',
        runtimeOS: 'OpenHarmony',
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
# The hvigorfile imports @ohos/hvigor-ohos-plugin; with TYPECHECK=1 hvigor typechecks that
# file too, and its module resolution only looks inside the project, so expose the installed
# hvigor packages as the project's node_modules (the layout DevEco Studio produces).
ln -sfn "$HVIGOR_DIR/node_modules" "$PROJ/node_modules"

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
          OHOS_BASE_SDK_HOME="$SDK" DEVECO_SDK_HOME="$SDK" \
          externalApiPaths="$SDK/ets/api:$SDK/ets/kits:$SDK/ets/arkts" \
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
# Read the abc version back from the fixed header: 8 B magic "PANDA\0\0\0", 4 B adler32,
# then one byte per version component at offset 0x0c. Fail when it is newer than the
# runtime limit, because the device then refuses to load the module (exit 254).
BC_VERSION="$(python3 - "$OUT_DIR/modules.abc" "$MAX_BC_VERSION" <<'PY'
import sys
abc, maximum = sys.argv[1], sys.argv[2]
raw = open(abc, 'rb').read(0x10)
assert raw[:5] == b'PANDA', f'{abc}: not an abc file'
version = tuple(raw[0x0c:0x10])
print('.'.join(str(b) for b in version))
max_version = tuple(int(p) for p in maximum.split('.')) if maximum and maximum != 'any' else ()
sys.exit(3 if max_version and version > max_version else 0)
PY
)" || die "abc version $BC_VERSION is newer than $MAX_BC_VERSION (set ARKTS_MAX_BC_VERSION=any to allow, or ARKTS_COMPATIBLE_SDK_VERSION to a level whose es2abc output the device accepts)"
info "ArkTS shell compiled: $OUT_DIR/modules.abc ($(stat -c%s "$OUT_DIR/modules.abc") bytes, abc version $BC_VERSION, compatibleSdkVersion $COMPATIBLE_SDK_VERSION)"
info "package it with: -p:OpenHarmonyUIPage=pages/Index -p:OpenHarmonyArktsModulesAbc=$OUT_DIR/modules.abc"
