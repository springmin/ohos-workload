# ArkTS page sources

`Index.ets` and `entryability/EntryAbility.ets` are the shell sources.

- The **headless** build (what `dotnet publish -p:OpenHarmonyHapPackage=true` produces
  today) compiles only `entryability/EntryAbility.ets` with the SDK's `es2abc`
  (`--module --merge-abc --extension ts --record-name ets/entryability/EntryAbility`).
  It starts the managed app without a UI page.
- The **UI** build additionally needs `pages/Index.ets`, which uses ArkTS declarative
  syntax. Compile it with the ArkTS toolchain (`ets-loader` under hvigor / DevEco Studio)
  and switch `resources/base/profile/main_pages.json` to `{ "src": ["pages/Index"] }`
  plus `windowStage.loadContent('pages/Index', ...)` in the ability.
