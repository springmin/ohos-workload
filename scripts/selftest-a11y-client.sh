#!/bin/sh
# Offline fallback checks for the minimal a11y client (no device, no hvigor). Verifies the
# extension wiring, the packed hap contract and the pure dump model, so a regression in the
# client shows up even where the on-device extension cannot be enabled:
#
#   scripts/selftest-a11y-client.sh
#
# System deps: python3 and a runnable node (>= 23 for the TypeScript model test).
set -e
W="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$W/test/a11y-client"
DIST="${A11Y_OUT_DIR:-$W/dist/a11y-client}"
ABC="${A11Y_ABC:-$W/.a11y-build/project/entry/build/default/intermediates/loader_out/default/ets/modules.abc}"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }

info() { printf '==> %s\n' "$*"; }

# ---- 1) pure dump model -----------------------------------------------------------------
NODE_BIN="${NODE:-$(command -v node)}"
node_runs() { sh -c '"$0" -e "process.exit(0)"' "$1" >/dev/null 2>&1; }
if ! node_runs "$NODE_BIN"; then
    NODE_ALT="$(command -v node)"
    if [ -n "$NODE_ALT" ] && [ "$NODE_ALT" != "$NODE_BIN" ] && node_runs "$NODE_ALT"; then
        NODE_BIN="$NODE_ALT"
    fi
fi
if [ -x "$NODE_BIN" ] && node_runs "$NODE_BIN"; then
    info "dump model unit test (node)"
    if "$NODE_BIN" "$SRC/offline/a11y-model.test.ts" >/tmp/a11y-model.out 2>&1; then
        tail -1 /tmp/a11y-model.out | sed 's/^/    /'
        ok "model test"
    else
        tail -5 /tmp/a11y-model.out | sed 's/^/    /'
        bad "model test"
    fi
else
    bad "node not runnable (NODE=$NODE_BIN); model test skipped"
fi

# ---- 2) source wiring -------------------------------------------------------------------
info "source wiring"
grep -q "type: 'accessibility'" "$SRC/entry/src/main/module.json5" \
    && ok "module.json5 declares an accessibility extension" \
    || bad "module.json5 extension type missing"
grep -q "ohos.accessibleability" "$SRC/entry/src/main/module.json5" \
    && ok "module.json5 carries the ohos.accessibleability metadata" \
    || bad "module.json5 metadata name missing"
grep -q "accessibility_config" "$SRC/entry/src/main/module.json5" \
    && ok "module.json5 points at \$profile:accessibility_config" \
    || bad "module.json5 profile reference missing"
grep -q '"retrieve"' "$SRC/entry/src/main/resources/base/profile/accessibility_config.json" \
    && ok "accessibility_config.json declares the retrieve capability" \
    || bad "accessibility_config.json retrieve missing"
for token in "AccessibilityExtensionAbility" "getWindows" "getWindowRootElement" "attributeValue" "performAction"; do
    grep -q "$token" "$SRC/entry/src/main/ets/a11y/A11yExtAbility.ets" \
        && ok "A11yExtAbility.ets uses $token" \
        || bad "A11yExtAbility.ets does not use $token"
done

# ---- 3) build-script contract -----------------------------------------------------------
info "build-script contract"
grep -q 'MODULE_JSON="$INTER/package/default/module.json"' "$W/scripts/build-a11y-client.sh" \
    && ok "build packs the package/default module.json (carries virtualMachine/compileMode)" \
    || bad "build-a11y-client.sh does not pack package/default/module.json (ability load would time out)"
grep -q 'merge_profile/default/module.json' "$W/scripts/build-a11y-client.sh" \
    && bad "build-a11y-client.sh still references merge_profile/default/module.json" \
    || ok "merge_profile module.json is not packed (it lacks virtualMachine -> LIFECYCLE_HALF_TIMEOUT)"

# ---- 4) built artifacts (optional: only when present) -----------------------------------
if [ -f "$DIST/entry-default-unsigned.hap" ]; then
    info "packed hap ($DIST/entry-default-unsigned.hap)"
    python3 - "$DIST/entry-default-unsigned.hap" <<'PY' && ok "hap contract" || bad "hap contract"
import json, sys, zipfile
hap = zipfile.ZipFile(sys.argv[1])
names = set(hap.namelist())
for required in ('module.json', 'ets/modules.abc', 'resources.index',
                 'resources/base/profile/accessibility_config.json'):
    if required not in names:
        print('  missing hap entry: ' + required); sys.exit(1)
module = json.loads(hap.read('module.json'))['module']
if 'virtualMachine' not in module or 'compileMode' not in module:
    print('  module.json lacks virtualMachine/compileMode'); sys.exit(1)
exts = module.get('extensionAbilities') or []
if not any(e.get('type') == 'accessibility' and e.get('name') == 'A11yExtAbility' for e in exts):
    print('  module.json lacks the A11yExtAbility accessibility extension'); sys.exit(1)
caps = json.loads(hap.read('resources/base/profile/accessibility_config.json'))
if 'retrieve' not in caps.get('accessibilityCapabilities', []):
    print('  accessibility_config.json lacks retrieve'); sys.exit(1)
print('  module.json virtualMachine=%s extensionAbilities=%d capabilities=%s'
      % (module['virtualMachine'], len(exts), caps['accessibilityCapabilities']))
PY
fi
if [ -f "$ABC" ]; then
    info "compiled abc ($ABC)"
    python3 - "$ABC" <<'PY' && ok "abc symbols" || bad "abc symbols"
import sys
data = open(sys.argv[1], 'rb').read()
missing = [lit for lit in (b'A11yExtAbility', b'AccessibilityExtensionAbility', b'getWindowRootElement',
                           b'attributeValue', b'performAction', b'A11YCLIENT')
           if lit not in data]
if missing:
    print('  missing abc literal(s): ' + ', '.join(m.decode() for m in missing)); sys.exit(1)
print('  abc carries the extension class and the dump/action API references (%d bytes)' % len(data))
PY
fi

info "result: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
