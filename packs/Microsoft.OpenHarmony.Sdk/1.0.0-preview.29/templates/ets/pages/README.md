# ArkTS shell sources (headless vs UI)

| File | Compiled by | Used when |
|---|---|---|
| `entryability/EntryAbility.ets` | `scripts/build-arkts-shell.sh` (`ARKTS_SHELL_VARIANT=headless`) | headless builds (default) |
| `entryability/EntryAbility.ui.ets` | ArkTS toolchain (ets-loader/hvigor/DevEco) | UI builds (has `pages/Index`) |
| `pages/Index.ets` | ArkTS toolchain | UI builds |

## Headless build (works today)

```sh
# from the workload repository root
ARKTS_SHELL_VARIANT=headless sh scripts/build-arkts-shell.sh
# -> dist/ets/modules.headless.abc (abc 13.0.1.0, compatibleSdkVersion 18)
cp dist/ets/modules.headless.abc \
   packs/Microsoft.OpenHarmony.Sdk/<version>/templates/ets/modules.abc
```

The script scaffolds a page-free hvigor project from this `EntryAbility.ets`, compiles it with
the same ArkTS toolchain as the UI shell and writes `dist/ets/modules.headless.abc` - never
`dist/ets/modules.abc` - so a headless build cannot overwrite the kit-facing UI shell. The
built file is installed as the pack's `templates/ets/modules.abc`; `dotnet publish
-p:OpenHarmonyHapPackage=true` (no `OpenHarmonyUIPage`) packages that template and an empty
`main_pages`.

## UI build

1. Compile the whole `ets/` tree (UI ability + `pages/Index.ets`) with the ArkTS toolchain,
   e.g. in DevEco Studio or with `hvigor` (`assembleHap`), or by driving the SDK's
   `ets-loader` (rollup pipeline) yourself; `scripts/build-arkts-shell.sh` (default
   `ARKTS_SHELL_VARIANT=ui`) is the scripted version and writes `dist/ets/modules.abc`. The
   resulting file must contain the module records `ets/entryability/EntryAbility` and
   `pages/Index`.
2. Build with:

   ```sh
   dotnet publish -f net11.0-openharmony26.0 -r openharmony-arm64 \
     -p:OpenHarmonyHapPackage=true \
     -p:OpenHarmonyUIPage=pages/Index \
     -p:OpenHarmonyArktsModulesAbc=$PWD/dist/ets/modules.abc
   ```

   `OpenHarmonyUIPage` makes the packaging write `main_pages.json` with that page and
   `OpenHarmonyArktsModulesAbc` replaces the headless `modules.abc`.

3. `pages/Index.ets` hands its `NodeContent` to the native host
   (`host.setNodeContent(this.content)`), which forwards it to the managed app as
   `OpenHarmonyBridge.NodeContent`. That is the integration point for managed UI: attach
   an `XComponent`/canvas node there to let MAUI/Skia render, and use the lifecycle bridge
   for foreground/background.
