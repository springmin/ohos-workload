# Interaction regression suite (headless)

The MAUI-on-OpenHarmony interaction harness (234 interaction checks, a 4-line fuzz tail, a
frame-path performance budget and an accessibility publish-path budget). It builds the platform
slice sources from the
`maui-ohos` working tree and drives the app host without a device: touch/drag/pinch/pointer input,
overlays, gestures (tap/pan/swipe/pinch/pointer/drag-and-drop), sensors/haptics/notification/picker
wiring, the app-theme colour-mode handler, the launcher/browser/share ability bridge, the
accessibility shadow tree snapshot, the menu table/activation bridge, the WebView JavaScript
bridge (script evaluation + `dotnetHost.postMessage`), the contacts/calendar and
Bluetooth/printing platform extras (off-device degradation plus the delimited payload parsers
and the text-to-PDF renderer), the Essentials Battery/DeviceDisplay push bridge (payload
parsers plus the ModuleInitializer-installed defaults), the S-series features (the
BlazorWebView handler/manager/file-provider path, the accessibility node-count export, the
flashlight default/degradation and the file-share dispatch/MIME/URI path) and the V-series
on-demand app-context publish (V8: native/NAPI/shell-template checks plus an off-device drill
of the managed bridge's surface-replay seam). Before the fuzz tail
it runs a frame-path performance budget (warm-up plus 200 timed
`OpenHarmonyWindowRenderer.Render` frames over a fixed 401-node tree, reporting
average/p50/p95/max frame time and the managed allocation delta) and an accessibility
publish-path budget (unchanged vs mutated frames over the same tree, see "Performance budget"
below), failing the suite when the (deliberately loose) budgets are exceeded.

## Running it

```bash
# The project references the maui-ohos slice and two assemblies built from this repository.
# Override the defaults with the MAUI_SLICE_DIR / HOSTING_DLL / OPENHARMONY_GRAPHICS_DLL env vars
# (or the MauiSliceDir / HostingDll / OpenHarmonyGraphicsDll MSBuild properties) before building
# elsewhere; an explicit -p: value wins over the environment and the absolute fallbacks.
dotnet build -v:q
dotnet bin/Debug/net11.0/verify.dll | grep -c '\[verify\]'   # expect 247 (234 checks + 4 fuzz + 1 frame perf + 8 a11y perf)
```

The `interaction-regression` workflow (`.github/workflows/interaction-regression.yml`) runs the
suite on a GitHub runner as a real gate: it checks out this repository plus `springmin/maui-ohos`
(`feature/openharmony`, the branch carrying `src/Core/src/Platform/OpenHarmony`), builds
`src/Microsoft.OpenHarmony.Hosting` and `src/Microsoft.OpenHarmony.Maui.Graphics` in Release,
points `MAUI_SLICE_DIR` / `HOSTING_DLL` / `OPENHARMONY_GRAPHICS_DLL` at those roots, and fails the
job unless the run exits 0, reports at least 224 `[verify]` lines, both perf lines report
`within=True`, and no `Unhandled` line is logged.

## Fuzz tail

The suite ends with a bounded, deterministic fuzz section (fixed seed `20260920`) that adds four
`[verify]` lines:

- 300 down/move/up sequences through the app host with finite but extreme coordinates, mostly
  out-of-bounds (uniform in `+-2,000,000`, plus `+-float.MaxValue`); every fifth sequence lands
  inside the 1080x1920 surface so real hit-testing runs too. A throwing sequence fails the suite.
- two very long simulated JS -> .NET bridge payloads: a 32 KiB `__RawMessage` payload through
  `OpenHarmonyHybridWebViewHandler.OnJsMessage` (escaped and unescaped) and a 48 KiB JSON payload
  through the native-shaped `OpenHarmonyWebViewHandler.HandleJsMessage`; both must round-trip
  intact without throwing.
- a detached 301-node tree (150 nested layouts with a label each) driven through
  `OpenHarmonyWindowRenderer.Render`, which exercises the iterative accessibility shadow-tree walk
  (`OpenHarmonyAccessibility.Visit`) and the diagnostics overlay walk, plus the recursive
  `Describe` log.

It asserts no unhandled exception and no hang (the section must finish in seconds; the run above
took ~0.2 s) and performs no large allocations.

## Performance budget

Before the fuzz tail the suite measures the frame path: 8 warm-up frames (JIT/static caches, first
layout pass) and then 200 timed `OpenHarmonyWindowRenderer.Render` frames over a fixed, seedless
401-node tree (100 rows x 3 labels, detached from the app so the measurement is independent of the
state the interaction checks leave behind). The perf renderer is built through the slice's
documented `CanvasFactory` test hook with a canvas that no-ops the renderer-level background fill
(`FillRectangle`): off-device the native host is absent and every non-overridden canvas call is a
failed lookup that costs ~4 ms on the OpenHarmony dev host, so without that hook the section would
spend ~1 s in a rasterizer artifact instead of measuring managed renderer work. The managed frame
path (measure/arrange, the iterative view walk, the accessibility shadow-tree rebuild and frame
diff, the surface hooks) runs unchanged.

The `[verify] perf` line reports the average, p50, p95 and max frame time, the max/average ratio,
the managed allocation delta (`GC.GetAllocatedBytesForCurrentThread`, total and per frame) and the
section's own wall time. The budget is intentionally loose because CI runners are shared, the
suite runs in Debug and the off-device frame keeps one failed native lookup on the dev host:

- `avg <= 20 ms` - the managed work is sub-millisecond; a uniform regression (extra walk, blocking
  call, quadratic layout) has to add more than ~14 ms/frame to trip this.
- `max <= 250 ms` - a very loose absolute hang guard.
- `max/avg <= 100x` - the relative outlier check, so a pathological single frame fails even on a
  machine where the absolute ceilings are too loose; single preempted frames (10-30x a
  sub-millisecond average) are tolerated.

The suite then measures the accessibility publish path over the same fixed tree: 8 warm-up and 50
timed unchanged frames (the skip path), followed by 8 warm-up and 50 timed frames whose label text
was mutated since the last publish (the republish path). Each pass is reported twice - as the
render step (`OpenHarmonyAccessibility.Refresh` + `Publish`, what a frame pays) and as the publish
pass itself (`Publish` alone, where the skip decision and the host boundary live) - with the same
average/p50/p95/max shape. Off-device there is no host library, so the first publish attempt fails
and flips the slice's internal provider-availability flag, after which every pass (changed or not)
returns before the host boundary and the two paths become indistinguishable; the harness restores
that flag (the same reflection hook the publish-contract checks use) before every measured pass,
so the republish passes really take the host-boundary branch and fail there while the skip passes
take the "nothing moved" branch, and restores the previous value when the block ends. The eight
`[verify] perf a11y` lines report the numbers, the skip/republish decisions
(`wouldPublish`/`FramesSkipped`/host attempts) and the integrity checks (the skip passes never
asked the host for a publish; every republish pass detected the mutation and reached the host
boundary; the shadow-tree snapshot is still well-formed and indexed). The budget is the same
deliberately loose style as the frame budget:

- `skip avg <= 20 ms`, `skip max <= 250 ms` - the rebuild, the diff and the skip decision are
  sub-millisecond managed work, so the same loose ceilings as the frame budget apply.
- `republish avg <= 50 ms`, `republish max <= 500 ms` - the republish pass additionally crosses the
  host boundary once per pass; the ceilings leave room for the absent-host probe on a loaded host
  while still catching a genuine hang.
- `republish/skip >= 1.25x` (render step) and `>= 2x` (publish pass) - the documented relative
  floors: the skip path must be materially cheaper than a republish pass. CI runners measure
  ~1.6-1.7x and ~3.8-3.9x; on the OpenHarmony dev host the absent-host probe dominates and the
  ratios are ~10-15x and ~80-120x, so the floors sit well below the observed values.
- `elapsed <= 2 s` - the whole block is bounded (measured ~0.1 s on CI and ~0.5-0.9 s on the dev
  host), so the suite stays inside the ~2 s addition budget.

A violation throws (unhandled exception, non-zero exit) after the numbers are printed, so CI logs
keep the evidence. Measured on the OpenHarmony dev host (200 frames): avg ~3.5-3.8 ms, p50
~3.4-3.7 ms, p95 ~4.5-4.7 ms, max 6.4-7.2 ms, max/avg ~1.7-2.1, ~185 KiB allocated per frame (the
accessibility frame diff rebuilds the 401-node shadow tree: reported for context, not asserted),
section wall time ~750-810 ms; the a11y block adds ~0.5-0.9 s (50 skip + 50 mutated passes) and the
whole suite stayed within ~1 s of the unmodified 199-line run. On a normal CI runner the one
remaining native lookup inside `Render` is sub-millisecond, so the reported average should be well
under 1 ms, and the a11y block reported ~0.3/0.5 ms for the render step and ~0.07/0.28 ms for the
publish pass (skip/republish).

## Notes

- Output goes to `bin/Debug/net11.0/verify.dll` (run the dll, not the apphost: the device policy
  blocks codesigned ELF apphosts on some machines).
- The suite fails loudly (unhandled exception) when a slice change breaks startup or when an
  assertion for the gesture flows (including the drag-and-drop checks) does not hold; keep it at
  234 checks plus the 4 fuzz lines plus the 1 frame-perf line plus the 8 a11y-perf lines
  (247 `[verify]` lines) when touching the platform slice.
- Contacts/calendar coverage: `OpenHarmonyContacts.FindAsync` and
  `OpenHarmonyCalendar.ListUpcomingAsync`/`AddEventAsync` return empty/false without throwing
  off-device and report `IsSupported == false` before and after the call (the permission probe
  fails without the host library); the delimited payload parsers are exercised with the
  exact "name\tphone" and "title\tstartIso\tendIso" payload shapes the ArkTS shell sends. The
  shell half imports `@kit.ContactsKit`/`@kit.CalendarKit` (both compile with the ArkTS toolchain)
  and requires `ohos.permission.READ_CONTACTS` (contacts) and `ohos.permission.READ_CALENDAR` /
  `ohos.permission.WRITE_CALENDAR` (calendar) at runtime; without the manifest declaration the
  sinks answer "unavailable" instead of guessing. The packaging target declares them on request:
  `-p:'OpenHarmonyExtraPermissions="ohos.permission.READ_CONTACTS;ohos.permission.READ_CALENDAR"'`
  appends the minimal `requestPermissions` array to the generated module.json (preview.22 and
  preview.23 packs; unset keeps the file byte-identical).
- Bluetooth/printing coverage: `OpenHarmonyBluetooth.IsEnabledAsync`,
  `GetPairedDevicesAsync`, `StartDiscoveryAsync`, `StopDiscoveryAsync` and
  `GetDiscoveredDevicesAsync` return false/empty without throwing off-device and `IsSupported`
  stays false; the device parser (`ParseDevices`, which `ParsePairedDevices` delegates to) is
  exercised with the exact "name\taddress" payload (including a nameless record, while a record
  with no tab has no address and is dropped), the adapter-state parser with the
  `access.BluetoothState` values ("2" on, "0"/"1"/garbage off), and the discovered-device push
  with the native-shaped
  `OnDeviceFoundPayload` records (a named `name\taddress` record raises `DeviceFound`; a
  tabless/address-only record and null/empty payloads raise nothing). The escape decoder and the
  injection guard (a raw LF before the first tab folds into the previous field) are asserted here
  and on the contacts parser. The shell half registers
  `connection.on('bluetoothDeviceFind')` while discovery runs, pushes each record through
  `host.notifyBluetoothDeviceFound` and answers op 4 with the accumulated table.
  `OpenHarmonyPrinting.PrintFileAsync` returns false for a missing file
  and for an unavailable bridge, `PrintTextAsync` writes a real PDF into the cache directory
  and still degrades to false, and the text-to-PDF renderer is checked structurally: `%PDF-1.4`
  header, `startxref` pointing at the xref table, every xref entry resolving to its `n 0 obj`
  header, `/Length`-delimited streams followed by `endstream`, escaped parentheses/slashes and
  the Latin-1 octal escape, plus 3-page pagination of a 120-line document (the same documents
  were also validated with an independent Python xref/stream parser). The shell half compiles
  `access`/`connection` from `@kit.ConnectivityKit` and `print` from `@ohos.print` and requires
  `ohos.permission.ACCESS_BLUETOOTH` (user_grant, requested at call time) and
  `ohos.permission.PRINT` (system_grant); pass them through the same
  `-p:'OpenHarmonyExtraPermissions="..."'` list so the packaged module.json declares them.
- JavaScript bridge coverage: `WebView.EvaluateJavaScriptAsync` completes with null/empty and
  never throws off-device (no host library), the native `notifyJsMessage` callback raises
  `OpenHarmonyWebViewHandler.JsMessage` with the `dotnetHost.postMessage` payload, and the
  HybridWebView handler is registered in `SliceHandlers`, completes
  `HybridWebView.EvaluateJavaScriptAsync`/`InvokeJavaScriptAsync` without hanging, degrades
  `SendRawMessage` and routes `__RawMessage|...`/plain payloads into `RawMessageReceived`.
  Hybrid asset serving (`HybridRoot`/`DefaultFile`) rides the shell's ArkWeb request interception:
  the handler extracts the embedded `_framework/hybridwebview.js` bootstrap resource (the exact
  resource name and the `https://0.0.0.1/` origin are asserted) and registers `<AppDir>` + root +
  default file with the shell, which answers app-origin requests from `<AppDir>/<root>/...`,
  serves the bootstrap script from `<AppDir>/_framework/hybridwebview.js` and forwards the script's
  `__hwvSendMessage` posts into the managed handler. Off-device (no host library) the shell command
  itself is a no-op, but the registration path is still exercised (see the late app-context bullet
  below). The JS -> .NET `__hwvInvokeDotNet` endpoint is implemented: the shell
  intercepts the fetch, returns the response not-ready (`setResponseIsReady(false)` - the SDK
  members are pinned by the typeCheck probe in the workload repo), forwards
  `host.notifyHybridInvoke(requestId, method, argsJson)` and completes the response when the
  managed handler answers through `ohos_host_hwv_invoke_result`. The suite drives the managed half
  directly (`OnHybridInvokeAsync`, the same path as the native callback) with a
  `SetInvokeJavaScriptTarget` object: a string round trip (`Echo` -> `"echo:hi"`), a typed result
  (`Add` -> `42`), a missing method, malformed parameter JSON, a page without an invoker and a
  disconnected page all answer the `DotNetInvokeResult` error payload (never a hang), and the
  payload is observed through `HybridInvokeResultSent` because the native export is absent
  off-device. See the slice's `OpenHarmonyHybridWebViewHandler` header.
- Web navigation allow-list (B6) and status log (B7) coverage: the shell cancels main-frame loads
  it did not originate and asks the managed handler for a decision over the JS-message channel
  (`__OHNAV|<url>|<id>`). Three pins keep the flow guarded: an allowed envelope raises
  `IWebView.Navigating` once and is approved back as the exact `(id, url)` pair, while the
  page-begin event of the approved reload is suppressed (one-shot: the next started event raises
  again); a cancelled envelope sends no approval; and the envelope is scoped to its own channel
  (never fanned out to `JsMessage`) while malformed/unsafe envelopes (empty or relative URL, a
  control character, an empty id) stay inert. On the status side `SanitizeUrlForLog` drops the
  query/fragment, flattens control characters and truncates to 2 KiB, and 300 `finished` events
  keep `dotnet-status.txt` capped at 256 KiB with the newest line present, the oldest dropped and
  no query text in the file.
- HybridWebView late app-context coverage (U1): the shell can publish `AppDir` (and with it the
  payload directory) after a HybridWebView connected, so the suite drives the bridge seam directly
  (it sets `OpenHarmonyBridge`'s private `s_context` field and replays the private
  Initialized/SurfaceChanged backing delegates, the same path a late host context/surface takes)
  and asserts ten `[verify]` lines: a connect without `AppDir` is remembered as pending instead of
  dropped; the late replay registers the pending root exactly once with the expected
  directory/root/default file and extracts the bootstrap script; replaying the Initialized and
  SurfaceChanged signals (up to all signals plus repeated mapper passes) stays idempotent; a
  `HybridRoot` change re-registers once with the new root; the eager path (context already
  published) still registers immediately at connect; and two pending handlers are both remembered
  and land one by one when the late context arrives. The scenario pins the slice's registration
  contract: pending set, `Initialized`/`SurfaceChanged`/first-arrange retries and the
  exactly-once registration key.
- On-demand app-context publish (V8): the host entries `ohos_host_set_app_context` /
  `ohos_host_notify_context` are pinned in `openharmony_host.c` and `openharmony_host.h` (both
  definitions and declarations, parsed and checked against each other), the napi wrappers and
  the module-table names `host.setAppContext` / `host.notifyAppContext` are pinned in
  `host_napi.cpp`, and the `publishAppContext` method with its
  `typeof host.setAppContext !== 'function'` guard plus its call site inside the XComponent
  `onLoad` (right after `host.registerXComponent()`) is pinned in the preview.22/23/24
  `Index.ets` templates. The managed seam is then driven off-device: the `OHOS_HOST_APP_CONTEXT`
  copy (the same export the native set writes, and the first source `RefreshContext` reads) is
  swapped between two snapshots and the private `OnSurfaceNative` callback - the delegate
  `Attach` hands to `ohos_host_register_bridge`, pinned via `s_surfaceThunk` - is invoked through
  reflection, so a re-published snapshot must be re-read into `Initialized`/`Context` and
  re-raised as a `SurfaceChanged` event; a replay of the unchanged snapshot must not re-raise the
  context but must still emit the surface event, and the captured environment/context/surface
  state is restored before the perf blocks. That is 18 `[verify]` lines.
- Haptics coverage: `HapticFeedback.Default` is the slice implementation, `Perform(Click/LongPress)`
  degrades without throwing off-device, and `IsSupported` is false without the host library. The app
  theme handler is exercised directly (ArkUI colour-mode reports need a device): setting dark/light
  updates `UserAppTheme`/`RequestedTheme` and the previous value is restored afterwards.
- Battery/DeviceDisplay coverage: the `[ModuleInitializer]` installers make `Battery.Default` the
  slice `OpenHarmonyBattery` and `DeviceDisplay.Current` the slice `OpenHarmonyDeviceDisplay`; the
  battery parser is exercised with the shell payload "soc\tchargeState\tpluggedType\tpresent\
  tpowerMode" (Charging/Usb/Off, Discharging/AC/On, Full+absent+extreme-power-save, the explicit
  MODE_CUSTOM_POWER_SAVE 650, and malformed payloads -> null), and a native-shaped payload push
  updates `Battery.ChargeLevel`/`State`/`PowerSource`/`EnergySaverStatus` and raises both change
  events. The display parser is exercised with "width\theight\tdensityDPI\trotation\trefreshRate\
  torientation" (portrait 1080x2340@480 -> density 3/Rotation0, landscape-inverted 2340x1080@320 ->
  density 2/Rotation270, orientation inferred from width/height when the sixth field is missing, and
  malformed payloads -> null); a native-shaped push updates `DeviceDisplay.MainDisplayInfo` and
  raises `MainDisplayInfoChanged` once per distinct snapshot. Off-device nothing throws, the
  properties stay at Unknown/0x0 and `KeepScreenOn` reports false (no platform keep-screen path in
  this increment). The shell half reads `batteryInfo`/`power.getPowerMode()` and
  `display.getDefaultDisplaySync()` at page start, follows the battery common events and
  `display.on('change')`, and pushes the raw values through `host.notifyBattery`/`host.notifyDisplay`
  (the host replays the last snapshot to the managed listener).
- Drag-and-drop coverage: a long press (500 ms) followed by a move past the 8 px slop raises
  DragStarting, DragOver/DragLeave fire when the pointer enters/leaves a drop-aware view, Drop
  delivers the source text through DataPackageView.GetTextAsync(), and a release over nothing raises
  DropCompleted with DropResult=None (the internal result is read reflectively).
- Rotation-vector coverage: the orientation sensor is wired to `SENSOR_TYPE_ROTATION_VECTOR` (259)
  and the host listener forwards four components. The assertion invokes the managed callback through
  the six-parameter `SensorCallback` delegate (pinning the native signature) and checks that
  `(x, y, z, w)` reaches `OrientationSensorData.Orientation` unchanged, with no reconstructed
  scalar part.
- S-series coverage:
  - S1 BlazorWebView: the handler/manager source contract is asserted from
    `OpenHarmonyBlazorWebViewHandler.cs` (the `IBlazorWebViewHandler` shell, the
    `StartWebViewCoreIfPossible` startup, the platform `OpenHarmonyWebViewManager` and the root
    component add/remove publishes) together with the gated `IBlazorWebView` entry in
    `MauiOpenHarmonyExtensions.SliceHandlers`; the file provider is pinned by
    `OpenHarmonyBlazorFileProvider`/`IFileProvider` and by run-time checks of the unconditionally
    compiled `OpenHarmonyBlazorWebView` asset mapping the provider delegates to (default host file,
    `_framework/...`, origin/query/fragment stripping, `../`/`\`/encoded-escape rejection); the
    handler itself compiles only when `OPENHARMONY_BLAZOR_WEBVIEW` is defined, so the source
    contract is asserted where this harness cannot reference the Blazor package types.
  - S2 accessibility node count: `ohos_host_accessibility_node_count` is asserted in
    `openharmony_host.c`, the shared header and the napi module table
    (`AccessibilityNodeCount` -> `host.accessibilityNodeCount`, the shell self-check export), and
    the managed half proves a rebuilt live-page shadow tree has nodes while the publish pass stays
    a no-op without the host library (guarded, no throw).
  - S3 flashlight: `Flashlight.Default` is the slice `OpenHarmonyFlashlight`, `IsSupportedAsync`
    answers false and `TurnOnAsync`/`TurnOffAsync` degrade without throwing off-device; the bridge
    is pinned reflectively to the `ohos_host_flashlight_set` entry point in
    `libopenharmonyhost.so` with opcodes 0/1/2 (off/on/probe), and the native source must carry the
    export plus the `registerFlashlightSink` shell sink.
  - S4 file sharing: `OpenHarmonyShare.MimeTypeForPath` is checked on the common document/image
    extensions and `*/*` fallback, `FileUriForPath` on the absolute/relative/scheme-passthrough
    shapes, and `ShareFileRequest`/`ShareMultipleFilesRequest`/`ShareTextRequest` dispatch through
    the installed default must complete without throwing when the ability bridge is absent; the
    want kind for single-file sharing is pinned to 3.
- CI wiring: `.github/workflows/interaction-regression.yml` builds the slice checkout and the
  hosting assemblies on the runner and gates on the `[verify]` line count (>=224) plus both perf
  `within=True` markers (see "Running it" above).
- Accessibility publish-contract coverage (R2b): the suite reflects
  `OpenHarmonyAccessibility.AccessibilityNode` (16 parameters now that hint, range and checked
  are published) and parses `ohos_host_accessibility_node`/`_get` out of
  `src/OpenHarmonyHost/openharmony_host.c` plus the shared header, comparing argument counts,
  normalized names, type kinds and the UTF-8 string marshalling; a missing/renamed/reordered
  argument fails the run instead of shifting registers on device. The probe tree also checks the
  value mapping (slider Minimum/Maximum/Value, progress 0/1/Progress, switch/checkBox 0/1,
  absent range NaN/NaN and checked -1 elsewhere) and that a slider value change with unchanged
  text/bounds raises a page-state update while an unchanged frame stays quiet.
