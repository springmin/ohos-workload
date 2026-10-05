#!/bin/sh
# Enables the minimal a11y client (com.example.a11yclient/A11yExtAbility) on a device, best
# effort. This build of the platform (Huawei HarmonyOS 7.0.0.111 PC mode) has no third-party
# enable path: there is no `accessibility` CLI, the Settings accessibility page has no
# "installed services" entry, and the system config API needs WRITE_ACCESSIBILITY_CONFIG plus
# a system-signed app. The script reports which gate applies and prints the tester steps.
#
#   scripts/enable-a11y-client.sh [--status] [--try-cli]
#
#   --status    print the AccessibilityManagerService state and the installed extension list
#               (the latter via the companion ability probe: run-a11y-client.sh --probe)
#   --try-cli   attempt the stock `accessibility enable` CLI (absent on this image)
# Default: --status --try-cli.
set -e
W="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="com.example.a11yclient"
ABILITY="A11yExtAbility"
HDC="${HDC:-$(command -v hdc 2>/dev/null || printf '%s' "$HOME/ohos-clt/sdk/default/openharmony/toolchains/hdc")}"

STATUS=0
TRY_CLI=0
while [ $# -gt 0 ]; do
    case "$1" in
        --status) STATUS=1; shift ;;
        --try-cli) TRY_CLI=1; shift ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[ "$STATUS" = 1 ] || [ "$TRY_CLI" = 1 ] || { STATUS=1; TRY_CLI=1; }

info() { printf '==> %s\n' "$*"; }

if [ "$STATUS" = 1 ]; then
    info "AccessibilityManagerService state"
    "$HDC" shell "hidumper -s AccessibilityManagerService -a '-u'" 2>&1 | grep -E 'accessible:|touchGuide:|screenReader|client|shortKey' | sed 's/^/    /' || true
    "$HDC" shell "hidumper -s AccessibilityManagerService -a '-c'" 2>&1 | tail -1 | sed 's/^/    /'
    info "installed accessibility extensions (companion ability probe)"
    sh "$W/scripts/run-a11y-client.sh" --probe --out /data/storage/el2/base/tmp/opencode/a11y-client/enable 2>&1 \
        | grep -E 'A11YCLIENT (probe|EXTENSION)' | sed 's/^.*A11YCLIENT/A11YCLIENT/' | sed 's/^/    /' || true
fi

if [ "$TRY_CLI" = 1 ]; then
    info "trying the stock debug CLI: accessibility enable -a $ABILITY -b $BUNDLE -c rg"
    if "$HDC" shell "command -v accessibility >/dev/null 2>&1"; then
        "$HDC" shell "accessibility enable -a $ABILITY -b $BUNDLE -c rg" 2>&1 | sed 's/^/    /'
    else
        printf '    /bin/sh: accessibility: inaccessible or not found (the debug CLI is not shipped on this image)\n'
    fi
fi

cat <<'EOF'

Enablement gates on this device (all three closed for a third-party, debug-signed hap):
  1. debug CLI `accessibility enable -a A11yExtAbility -b com.example.a11yclient -c rg`
     -> binary absent (stock OpenHarmony dev builds only).
  2. Settings > Accessibility > installed services -> toggle
     -> absent (the PC-mode Settings page has only 视觉/听觉; no extension-services entry).
  3. @ohos.accessibility.config.enableAbility(name, capability)
     -> not in this SDK; upstream it is a system API requiring
        ohos.permission.WRITE_ACCESSIBILITY_CONFIG and a system-signed app.

Tester steps on a device where accessibility extensions are supported (stock OpenHarmony or a
phone/tablet image with the installed-services page):
  1. scripts/build-a11y-client.sh --install   (or: hdc install -r dist/a11y-client/a11y-client-signed.hap)
  2. Settings > Accessibility/辅助功能 > installed services/已安装的服务 -> A11y client (dump) -> on
     (accept the risk dialog after the countdown) - or run the debug CLI from gate 1.
  3. scripts/run-a11y-client.sh --capture 30  while driving com.example.hellomauiapp, then
     grep the capture for: A11YCLIENT dump / A11YCLIENT NODE / A11YCLIENT ACTION.
EOF
