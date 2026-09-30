# hello-maui-wasm — B2: a full Blazor WebAssembly site in a MAUI WebView

A minimal MAUI application whose window hosts the published `test/hello-blazorwasm` site in a
plain `Microsoft.Maui.Controls.WebView`. This is the B2 milestone of the BlazorWebView
feasibility plan (`runtime-ohos/docs/plans/2026-09-29-ohos-blazorwebview-feasibility.md` §3):
Blazor **WebAssembly** (the site runs its own runtime inside ArkWeb), not Blazor Hybrid
(`test/hello-maui-razor` covers that).

## Flow

1. `test/hello-blazorwasm/run-smoke.sh` publishes the site (`out/publish/wwwroot`, 642 files,
   `_framework/dotnet*.js` + the wasm payloads).
2. The pack target `_OpenHarmonyStageWasmSite` (property `OpenHarmonyWasmSiteDir`, default
   `../hello-blazorwasm/out/publish/wwwroot`) copies that directory into the hap payload under
   `wasmsite/`; a missing `index.html` fails the publish instead of shipping a site-less app.
3. `App.CreateWindow` calls `OpenHarmonyWebViewHandler.RegisterWasmSite()`: the slice sends the
   shell's `blazor` registration with mode `wasm`, so the shell serves
   `https://blazorwasm.local/` from `<payload>/wasmsite` with the payload MIME types and injects
   **no** Blazor Hybrid bootstrap (the site's `blazor.webassembly.js` boots the runtime itself).
4. The WebView's `Source` is `OpenHarmonyWebViewHandler.WasmSiteOrigin`; the shell's
   `onInterceptRequest` answers `index.html`, `_framework/blazor.webassembly.js`, `dotnet.*.js`
   and the wasm/ICU payloads from the staged root.

## Build and device run (rc.2 line)

```sh
# 1) site (once)
DOTNET=$HOME/.dotnet.rc2-fix/dotnet sh test/hello-blazorwasm/run-smoke.sh --out /data/storage/el2/base/tmp/opencode/w9a/site
# 2) ArkTS shell abc for THIS bundle name (the pack's prebuilt abc carries
#    com.example.hellomauiapp; the device resolves the ability entry against the abc records)
ARKTS_SHELL_BUNDLE_NAME=com.example.hellomauiwasm sh scripts/build-arkts-shell.sh
#    -> dist/ets/modules.abc (ignore the provenance-drift exit; do NOT --install-packs)
# 3) AOT hap (UI shell + staged site)
DOTNET=$HOME/.dotnet.rc2-fix/dotnet MAUI_SLICE_DIR=<maui-ohos>/src/Core/src/Platform/OpenHarmony \
  WASM_SITE=/data/storage/el2/base/tmp/opencode/w9a/site/publish/wwwroot \
  WASM_ABC=$PWD/dist/ets/modules.abc \
  sh test/hello-maui-wasm/publish-aot.sh
# 4) sign for the device, install, start, markers
sh scripts/sign-for-device.sh <UDID> --bundle com.example.hellomauiwasm \
  --unsigned test/hello-maui-wasm/bin/Release/net11.0-openharmony26.0/openharmony-arm64/hello-maui-wasm-unsigned.hap \
  --out /data/storage/el2/base/tmp/opencode/w9a/device/hello-maui-wasm-signed.hap
hdc install -r <signed.hap>; hdc shell "aa start -b com.example.hellomauiwasm -a EntryAbility"
hdc shell "hilog -x -e BlazorWebHost"   # expect: marker: BLZ_BOOT / marker: BLZ_RENDERED
```

The `BLZ_*` markers come from the site (`wwwroot/index.html` logs `BLZ_BOOT` on window load,
`Pages/Home.razor` logs `BLZ_RENDERED` after the first render); the shell's Web `onConsole`
forwards them to hilog under `BlazorWebHost`, the same tag the ArkTS host (`test/hello-blazorwasm/arkts-host`)
uses. For a JIT hap, publish without `-p:PublishAot=true` (the local image's install policy
rejects the JIT payload layout; see the local test runbook).

## Interaction-suite pins

`test/maui-platform-verify/Program.cs` pins the B2 contract off-device (3 checks): the managed
registration API (origin/root constants, safe-root rejection, off-device degradation), the wire +
shell wasm mode (mode field, bootstrap skip, no auto-load, `BLZ_TAG` forwarding), and the staging
target + this demo's wiring.
