# NativeAOT haps for the MAUI demo

`test/hello-maui-app` is the NativeAOT reference app: with
`-p:PublishAot=true -p:PublishAotUsingRuntimePack=true` it switches to `OutputType=Library` +
`NativeLib=Shared` and exports its own launch entry (`openharmony_app_main`, `AotEntry.cs`).
The publish output is a single `libhello-maui-app.so` (no managed assemblies, no CoreCLR
natives); the pack stages it in `libs/arm64-v8a/` next to the host and `libc++_shared.so` and
the host probes `<app_dir>/lib<stem>.so` before hostfxr (`aot=1`, see
`docs/aot-single-entry.md`). One publish produces `hello-maui-app.hap` (workload-signed, for a
matching debug profile) and `hello-maui-app-unsigned.hap` (re-sign for your own device).

## Publish

```sh
sh test/hello-maui-app/publish-aot.sh        # wraps the command below (memory gate included)
```

```sh
dotnet publish test/hello-maui-app/hello-maui-app.csproj \
    -f net11.0-openharmony26.0 -r openharmony-arm64 -c Release \
    -p:PublishAot=true -p:PublishAotUsingRuntimePack=true \
    -p:CompressSymbols=false -p:CopyOutputSymbolsToPublishDirectory=false \
    -p:OpenHarmonyHapPackage=true -p:OpenHarmonySdkRoot=$OHOS_SDK \
    -p:OpenHarmonyUIPage=pages/Index \
    -p:OpenHarmonyRuntimeMode=aot
```

- **`-p:OpenHarmonyUIPage=pages/Index` is mandatory (AOT and JIT alike).** With it the pack
  stages the UI ArkTS shell (`templates/ets/modules.ui.abc`: `XComponent` + `loadContent`,
  page `pages/Index`) and writes `resources/base/profile/main_pages.json`
  (`{"src":["pages/Index"]}`). Without it the hap carries the headless
  `templates/ets/modules.abc` and an empty `main_pages.json`: no `XComponent`, no
  `loadContent`, the window stays white and WMS logs `uiContent is null`. The aot-haps
  v1/v2 assets shipped that way; the v3 rebuild fixed it. `scripts/make-mode-kit.sh --mode aot`
  now defaults this property; `scripts/make-device-test-kit.sh` (JIT) has always carried it.
- `-p:OpenHarmonyRuntimeMode=aot` is bookkeeping only: it writes
  `libs/arm64-v8a/runtime-mode.txt=aot`; the host route is probe-driven, so haps without the
  marker still take the AOT path when `lib<stem>.so` is present.
- The rc.2 SDK on HarmonyOS hosts needs the local `Exec` hook
  (see "Known environment quirks" in `docs/openharmony-hap-packaging.md`); run with
  `OHOS_AOT_HOOKS=<aot-local-hooks.targets>` to apply the same workaround the released
  packages were built with.
- On the rc.2 line (`~/.dotnet.rc2-fix` + feed) the two AOT packs come from the
  `sdk-ohos` `aot-packs-11.0.0-rc.2` mirror
  (`Microsoft.NETCore.App.Runtime.NativeAOT.openharmony-arm64` +
  `runtime.openharmony-arm64.Microsoft.DotNet.ILCompiler` `11.0.0-rc.2.26451.112`;
  `eng/ohos-install/fetch-nativeaot-packs.sh` verifies the `versions.env` sha256 pins).
  The pack-time host and the UI shell abc are the workload preview.28 ones
  (`libopenharmonyhost.so` 285,600 B / `00ee9c84…`, `modules.ui.abc` 311,424 B / `7c1a3cac…`).

## Shape checks (per hap)

1. `libs/arm64-v8a/`: `libhello-maui-app.so` + `libopenharmonyhost.so` + `libc++_shared.so`
   (**no** `libcoreclr.so` / `libhostfxr.so` / `libclrjit.so`); `.dotnet-payload.json` names
   `hello-maui-app.dll`.
2. `ets/modules.abc` is the **UI shell** (the pack's `modules.ui.abc`, ~290 KB, contains
   `loadContent`/`XComponent`), not the headless ~21 KB abc; `resources/base/profile/main_pages.json`
   lists `pages/Index`.
3. `module.json` keeps `libIsolation=true`; `nm -D` of the app library shows
   `T openharmony_app_main@@V1.0`, `NEEDED = libc.so`, and a `.codesign` section.
4. `scripts/sign-for-device.sh <UDID>` (device mode) or the SDK `sign-hap.sh` re-signs the
   unsigned hap for a device: the debug profile must list that device's UDID, otherwise the
   install is refused (9568257) - debug profiles are per-device.

## Release lineage

| asset | change | device result |
| --- | --- | --- |
| `aot-haps.tar.gz` | kit #28 host, no TabbedPage fix, no UIPage | white window (control) |
| `aot-haps-v2.tar.gz` | TabbedPage render fix (`springmin/maui-ohos` `14bdb85f`) | still white: headless abc (no UIPage) |
| `aot-haps-v3.tar.gz` | UIPage fix on the v2 slice | UI shell abc, `ohos_dotnet_surface` buffer, window paints |
| `aot-haps-v3-rc2.tar.gz` | rc.2-mainline rebuild (SDK `11.0.100-rc.2.26451.112` / workload `1.0.0-preview.28`; slice = `springmin/maui-ohos` `ebffdd787c`, W6/W7/W8) keeping the UIPage fix | UI shell abc 311,424 B, `ohos_dotnet_surface` buffer, window paints (rc.2, 2026-09-30) |

Numbers (sizes/sha256, asset ids) are per asset in its `aot-haps-*-README.md` on the
`springmin/sdk-ohos` `device-test-kit` release; the rebuild runs are recorded in
`runtime-ohos/docs/plans/2026-09-29-ohos-aot-v2-rebuild.md` (v2), its v3 counterpart and
`2026-09-30-ohos-aot-v3-rc2-rebuild.md` (rc.2). The kit #34 (rc.2) AOT pick is
`aot-haps-v3-rc2.tar.gz`; v3/v2/v1 stay as controls.
