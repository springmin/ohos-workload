#!/bin/sh
# build-login-shell.sh - build the custom ArkTS shell that adds the LoginAbility page.
#
# The stock shell (modules.ui.abc) contains only EntryAbility/pages/Index/pages/SubWindow.
# This script builds a standalone hvigor project from the platform pack templates + the
# scripts/loginability sources and emits a modules.abc that also contains
#   <bundle>/entry/ets/loginability/LoginAbility  and  <bundle>/entry/ets/pages/Login
#
# Usage: scripts/build-login-shell.sh [--out <modules.abc>] [--keep-work]
# Env: ARKTS_BUNDLE_NAME (default mauidemo.dotnet.springmin.com)
# Requires: the hvigor packages under .arkts-build/hvigor (run scripts/build-arkts-shell.sh once
# or let the kit install them) and the OpenHarmony SDK (default harmonybrew 26.0.0.18_2).
set -u

W="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VER="${ARKTS_PACK_VERSION:-1.0.0-preview.29}"
TPL="$W/packs/Microsoft.OpenHarmony.Sdk/$VER/templates"
OUT="$W/dist/ets/modules.login.abc"
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT=$2; shift 2 ;;
        --keep-work) KEEP=1; shift ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "build-login-shell: unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -d "$TPL/ets" ] || { echo "missing templates: $TPL" >&2; exit 2; }
HVIGOR_JS="$W/.arkts-build/hvigor/node_modules/@ohos/hvigor/bin/hvigor.js"
[ -f "$HVIGOR_JS" ] || { echo "missing hvigor packages: $HVIGOR_JS (run build-arkts-shell.sh once)" >&2; exit 2; }
NODE_BIN="${NODE:-$HOME/.harmonybrew/bin/node}"
[ -x "$NODE_BIN" ] || { echo "missing node: $NODE_BIN" >&2; exit 2; }
JAVA_HOME="${JAVA_HOME:-$HOME/.harmonybrew/opt/openjdk@17}"
SDK="${OHOS_SDK_ROOT:-$HOME/.harmonybrew/opt/ohos-sdk}"

WORK="${LOGIN_SHELL_WORK:-/data/storage/el2/base/tmp/opencode/login-shell}"
rm -rf "$WORK"
mkdir -p "$WORK"
P="$WORK/project"

echo "==> scaffold ($VER)"
ARKTS_SHELL_VARIANT=ui bash "$W/scripts/build-arkts-shell.sh" --scaffold-only "$P" >/dev/null || exit 1

echo "==> sources"
mkdir -p "$P/entry/src/main/ets/entryability" "$P/entry/src/main/ets/pages" \
         "$P/entry/src/main/ets/loginability" "$P/entry/src/main/resources/base/element" \
         "$P/entry/src/main/resources/base/media"
cp "$TPL/ets/entryability/EntryAbility.ui.ets" "$P/entry/src/main/ets/entryability/EntryAbility.ets"
cp "$TPL/ets/pages/Index.ets" "$P/entry/src/main/ets/pages/Index.ets"
cp "$TPL/ets/pages/SubWindow.ets" "$P/entry/src/main/ets/pages/SubWindow.ets"
cp "$W/scripts/loginability/LoginAbility.ets" "$P/entry/src/main/ets/loginability/LoginAbility.ets"
cp "$W/scripts/loginability/Login.ets" "$P/entry/src/main/ets/pages/Login.ets"
cp "$TPL/resources/base/element/color.json" "$P/entry/src/main/resources/base/element/"
cp "$TPL/resources/base/media/app_icon.png" "$P/entry/src/main/resources/base/media/"

echo "==> patch main_pages / module.json5"
python3 - "$P" <<'PY'
import json, sys
p = sys.argv[1]
mp = p + '/entry/src/main/resources/base/profile/main_pages.json'
d = json.load(open(mp))
if 'pages/Login' not in d.get('src', []):
    d.setdefault('src', []).append('pages/Login')
json.dump(d, open(mp, 'w'), separators=(',', ':'))
mj = p + '/entry/src/main/module.json5'
t = open(mj).read()
if 'LoginAbility' not in t:
    entry = """      {
        name: 'LoginAbility',
        srcEntry: './ets/loginability/LoginAbility.ets',
        description: '$string:EntryAbility_desc',
        icon: '$media:app_icon',
        label: '$string:EntryAbility_label',
        startWindowIcon: '$media:app_icon',
        startWindowBackground: '$color:start_window_background',
        exported: true,
        launchType: 'multiton',
        process: ':login',
      },
"""
    t = t.replace('    abilities: [', '    abilities: [\n' + entry, 1)
    open(mj, 'w').write(t)
print('patched pages:', d.get('src'))
PY

echo "==> toolchain links"
ln -sfn "$W/.arkts-build/hvigor/node_modules" "$P/node_modules"
if [ -d "$W/.arkts-build/sdk" ]; then
    ln -sfn "$W/.arkts-build/sdk" "$WORK/sdk"
else
    mkdir -p "$WORK/sdk"
    ln -sfn "$SDK" "$WORK/sdk/26.0.0"
fi

echo "==> hvigor assembleHap"
LOG="$WORK/hvigor.log"
ABC="$P/entry/build/default/intermediates/loader_out/default/ets/modules.abc"
attempt=1
while :; do
    ( cd "$P" && \
      env -i PATH="$(dirname "$NODE_BIN"):/usr/bin:/bin" HOME="$HOME" \
          JAVA_HOME="$JAVA_HOME" OHOS_BASE_SDK_HOME="$SDK" DEVECO_SDK_HOME="$SDK" \
          externalApiPaths="$SDK/ets/api:$SDK/ets/kits:$SDK/ets/arkts" \
          "$NODE_BIN" "$HVIGOR_JS" assembleHap -m module -p module=entry@default \
            -p product=default -p buildMode=debug > "$LOG" 2>&1 )
    RC=$?
    if [ -f "$ABC" ] && grep -q 'Finished :entry:default@CompileArkTS' "$LOG"; then
        break
    fi
    if [ "$attempt" -lt 3 ] && grep -qE 'Signal 5|Fatal error in' "$LOG"; then
        echo "hvigor crashed (attempt $attempt); retrying" >&2
        attempt=$((attempt + 1))
        continue
    fi
    echo "hvigor failed (rc=$RC); log: $LOG" >&2
    tail -20 "$LOG" >&2
    exit 1
done

mkdir -p "$(dirname "$OUT")"
cp "$ABC" "$OUT"
if ! strings "$OUT" | grep -q 'loginability/LoginAbility' || ! strings "$OUT" | grep -q 'pages/Login'; then
    echo "compiled abc lacks the LoginAbility/page records: $OUT" >&2
    exit 1
fi
echo "login shell abc: $OUT ($(stat -c%s "$OUT") B, sha256 $(sha256sum "$OUT" | cut -d' ' -f1))"
[ "$KEEP" = 1 ] || rm -rf "$WORK"
