# a11y-client — minimal accessibility client for local read-screen verification

An ArkTS hap with an `AccessibilityExtensionAbility` (`A11yExtAbility`) that connects to the
accessibility pipeline, walks the shadow tree of the target app (`com.example.hellomauiapp`),
writes the dump to its files dir and emits per-node hilog lines. A UI-less companion
`EntryAbility` runs a public-API probe on `aa start` so the client artifact can be exercised
even where the extension cannot be enabled.

```
entry/src/main/
  module.json5                      # extension type accessibility + ohos.accessibleability metadata
  ets/a11y/A11yExtAbility.ets       # extension: getWindows/getWindowRootElement/attributeValue/performAction
  ets/a11y/A11yModel.ts             # pure dump model (node labels, summary, click target) - node-testable
  ets/entryability/EntryAbility.ets # probe: isOpenAccessibilitySync + getAccessibilityExtensionListSync
  resources/base/profile/accessibility_config.json
offline/a11y-model.test.ts          # host-side unit test (node >= 23 strips types)
```

## Build / install

```sh
sh scripts/build-a11y-client.sh            # hvigor ArkTS compile -> ohos_packing_tool pack -> sign
sh scripts/build-a11y-client.sh --install  # + hdc install and bm visibility check
sh scripts/selftest-a11y-client.sh         # offline: model test + source/hap/abc assertions
```

The hap is packed from the hvigor `package/default/module.json`; the `merge_profile` variant
must not be used (it lacks `virtualMachine`/`compileMode` and the ability start then hangs with
`LIFECYCLE_HALF_TIMEOUT`). Outputs in `dist/a11y-client/` (unsigned + signed, UDID-bound).

## Enable

The platform build tested (Huawei HarmonyOS 7.0.0.111, PC mode) has no third-party enable
path; see `docs/plans/2026-10-05-ohos-a11y-client.md` in runtime-ohos. Helper:

```sh
sh scripts/enable-a11y-client.sh            # state + CLI attempt + gate/tester report
sh scripts/run-a11y-client.sh --status --probe
```

## Run / evidence

```sh
sh scripts/run-a11y-client.sh --capture 30   # then drive the target app
# grep: A11YCLIENT dump / A11YCLIENT NODE / A11YCLIENT ACTION
```

On a device where the extension is enabled, `onConnect` dumps after 1.5 s and on accessibility
events (max 12 dumps, 600 nodes), writes `<filesDir>/a11y-dump.json`, then clicks the first
target-window node whose label contains `Count:` once and logs the read-back text. Dump lines
carry id/parent/depth/role/label/click/focus/a11yFocus/checked/selected/editable/scrollable/
visible/window/rect, i.e. the semantics a screen reader consumes.

Remote-DOM text is not published by the host (self-drawn canvas boundary), so the WebView case
shows the host-side node/role/geometry only.
