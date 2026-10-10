# hello-maui-hybrid — subwindow hybrid/Blazor asset-bridge sample

A focused MAUI-on-OpenHarmony sample for the **L3 tail** capability: managed child windows hosting
`HybridWebView`/`BlazorWebView`, served by the shell's subwindow asset bridge, plus the **B6**
child-navigation veto. It is the productized HYBRID-DEVICE round sample (2026-10-08); like
`test/hello-maui-razor` it is an on-demand sample, not part of any kit build.

| surface | control | what it proves |
| --- | --- | --- |
| main window | `HybridWebView` (`wwwroot/hybrid-main.html`) | main-window asset bridge: stock `_framework/hybridwebview.js`, `__hwvInvokeDotNet` (`MAIN-echo:...`), `__hwvSendMessage` + host→page raw |
| `openweb` child | `HybridWebView` (`wwwroot/child-hybrid.html`) + plain `WebView` | child asset bridge on the child's own pool slot + B6 probe document |
| `openblazor` child | `BlazorWebView` (`wwwroot/index.html` → BlazorCounter) + hybrid | child Blazor registration/bootstrap and `#app` mount |
| B6 | child plain web links | `deny` = app `Navigating` cancel; `ok` = managed ask→approve→DNS-fail reload; `veto` = `//host` fail-closed refusal |

All probes are automatic (managed eval read-backs + `RawMessageReceived`), so one device round reads
the whole chain out of hilog / `dotnet-status.txt` without screen interaction.

## Layout

```
App.cs                      main page + child pages + probes (echo invoker, B6 role-click)
Program.cs / AotEntry.cs    MAUI host wiring (JIT + NativeAOT routes)
BlazorCounter.cs            #app root component (RenderTreeBuilder, no Razor SDK)
wwwroot/hybrid-main.html    main-window hybrid probe page
wwwroot/child-hybrid.html   child hybrid probe page (stock framework script + invoke/raw/host)
wwwroot/index.html + js     shared Blazor host page (#app)
publish-jit.sh              JIT publish (fast device-round recipe, used for the evidence round)
publish-aot.sh              NativeAOT publish (the convention of test/hello-maui-app)
```

## Build and sign

```sh
# JIT hap (the device-round recipe)
OHOS_AOT_HOOKS=/data/storage/el2/base/tmp/opencode/mw-l/m2exit-aot/aot-local-hooks.targets \
  sh test/hello-maui-hybrid/publish-jit.sh
# AOT hap (NativeAOT, same flags as the demo's publish-aot.sh)
sh test/hello-maui-hybrid/publish-aot.sh

# sign the unsigned output for the tester UDID (debug profiles are per-device)
sh scripts/sign-for-device.sh <UDID> \
  --unsigned test/hello-maui-hybrid/bin/Release/net11.0-openharmony26.0/openharmony-arm64/hello-maui-hybrid-unsigned.hap \
  --out /data/storage/el2/base/tmp/opencode/hybrid-sample/hello-maui-hybrid-signed.hap
```

Build discipline: one publish at a time, MemAvailable >= 2 GB (both scripts gate/guard).
From a git worktree outside the standard sibling layout pass
`-p:OpenHarmonyMauiPlatformDir=<maui-ohos>/src/Core/src/Platform/OpenHarmony` (the scripts env
`OpenHarmonyMauiPlatformDir` does this).

## Device run

```sh
hdc install -r <signed.hap>                    # replaces com.example.hellomauiapp (see Bundle note)
hdc shell "aa start -b com.example.hellomauiapp -a EntryAbility"
hdc shell "aa start -b com.example.hellomauiapp -a EntryAbility -U app://subwindow/openweb"
hdc shell "aa start -b com.example.hellomauiapp -a EntryAbility -U app://subwindow/openblazor"
hdc shell "aa start -b com.example.hellomauiapp -a EntryAbility -U app://subwindow/close"
```

Triggers: `app://subwindow/openweb` · `openweb/b6/deny` · `openweb/b6/ok` · `openweb/b6/veto` ·
`openblazor` · `open` · `close`. The B6 variants auto-click one probe link after load; click them
in separate child launches (a vetoed/denied/approved `ok` navigation replaces the child document;
`ok` ends in the shell's `child web error` + `hide`). Main-window buttons do the same opens for
manual use.

Expected markers (tag prefixes `OHOS_MAUI`/`OHOS_MAUI_SUB` in hilog, mirrored from managed status):

- `child hybrid assets: origin=https://0.0.1/ root=wwwroot slot=N`, `child web serve hybrid (slot N): https://0.0.1/...`
- `child hybrid N probe[i]: title='CHILD-HYBRID-INVOKED' probe='api-ok fw-200-text/javascript... origin=https://0.0.1 id=<docId> raw-endpoint-204' result='invoke-result:"CH1-echo:Echo:1"' host='host-received:child-hybrid-host-N'`
- `child hybrid N raw: child-hybrid-raw-1..3` (`__hwvSendMessage` → `RawMessageReceived`)
- `child blazor N probe[i]: {"app":"BlazorWebView component...count: 0","dispatch":"function","blazor":"object"}`
- B6: `child web nav ask (slot N)` → `child web navigating: ...b6c-deny` → `child web navigating cancelled: b6c-deny` (deny);
  `ask` → `child web cmd: nav` → `child web nav approved` → `child web error` → hide (ok);
  `about:blank#blocked`, no ask/approved (veto).
- main window: `main hybrid probe[i]: title='MAIN-HYBRID-INVOKED' ... result='invoke-result:"MAIN-echo:Echo:1"' host='host-received:main-hybrid-host'`
  and `main window tap #N` after tapping.

## Bundle name

The hap keeps `com.example.hellomauiapp`: the pack's prebuilt UI-shell abc is built for that bundle
(the device resolves `<bundle>/<module>/ets/entryability/EntryAbility` against the abc records), so
a different bundle requires `ARKTS_SHELL_BUNDLE_NAME` + a full ArkTS shell rebuild. Installing this
sample therefore **replaces the demo on the device**; restore the kit hap (or the pre-round hap)
after the round.

## Evidence and references

- Device round evidence: `/data/storage/el2/base/tmp/opencode/hybrid-sample/round/` (hilog captures,
  screenshots, `dotnet-status.txt`); runtime docs:
  `runtime-ohos docs/plans/2026-10-08-ohos-hybrid-sample.md` (and `2026-10-07-ohos-l3-tail-fixes.md`).
- The hybrid/blazor bridge implementation and the B6 veto live in the shell/maui slice; this sample
  only drives them. The demo (`test/hello-maui-app`) is unchanged.
