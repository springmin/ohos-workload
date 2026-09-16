# ArkTS shell sources (headless vs UI)

| File | Compiled by | Used when |
|---|---|---|
| `entryability/EntryAbility.ets` | `es2abc` (see below) | headless builds (default) |
| `entryability/EntryAbility.ui.ets` | ArkTS toolchain (ets-loader/hvigor/DevEco) | UI builds (has `pages/Index`) |
| `pages/Index.ets` | ArkTS toolchain | UI builds |

## Headless build (works today)

```sh
es2abc --module --merge-abc --extension ts --record-name ets/entryability/EntryAbility \
       --target-api-version 26 --output ets/modules.abc ets/entryability/EntryAbility.ets
```

`dotnet publish -p:OpenHarmonyHapPackage=true` packages that `modules.abc` (the pack
template) and an empty `main_pages`.

## UI build

1. Compile the whole `ets/` tree (UI ability + `pages/Index.ets`) with the ArkTS toolchain,
   e.g. in DevEco Studio or with `hvigor` (`assembleHap`), or by driving the SDK's
   `ets-loader` (rollup pipeline) yourself. The resulting file must contain the module
   records `ets/entryability/EntryAbility` and `pages/Index`.
2. Build with:

   ```sh
   dotnet publish -f net11.0-openharmony26.0 -r openharmony-arm64 \
     -p:OpenHarmonyHapPackage=true \
     -p:OpenHarmonyUIPage=pages/Index \
     -p:OpenHarmonyArktsModulesAbc=$PWD/ets/modules.abc
   ```

   `OpenHarmonyUIPage` makes the packaging write `main_pages.json` with that page and
   `OpenHarmonyArktsModulesAbc` replaces the headless `modules.abc`.

3. `pages/Index.ets` hands its `NodeContent` to the native host
   (`host.setNodeContent(this.content)`), which forwards it to the managed app as
   `OpenHarmonyBridge.NodeContent`. That is the integration point for managed UI: attach
   an `XComponent`/canvas node there to let MAUI/Skia render, and use the lifecycle bridge
   for foreground/background.
