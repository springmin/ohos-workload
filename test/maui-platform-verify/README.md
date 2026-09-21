# Interaction regression suite (headless)

The MAUI-on-OpenHarmony interaction harness (203 interaction checks, a 4-line fuzz tail and a
frame-path performance budget). It builds the platform slice sources from the
`maui-ohos` working tree and drives the app host without a device: touch/drag/pinch/pointer input,
overlays, gestures (tap/pan/swipe/pinch/pointer/drag-and-drop), sensors/haptics/notification/picker
wiring, the app-theme colour-mode handler, the launcher/browser/share ability bridge, the
accessibility shadow tree snapshot, the menu table/activation bridge, the WebView JavaScript
bridge (script evaluation + `dotnetHost.postMessage`), the contacts/calendar and
Bluetooth/printing platform extras (off-device degradation plus the delimited payload parsers
and the text-to-PDF renderer), the Essentials Battery/DeviceDisplay push bridge (payload
parsers plus the ModuleInitializer-installed defaults) and the S-series features (the
BlazorWebView handler/manager/file-provider path, the accessibility node-count export, the
flashlight default/degradation and the file-share dispatch/MIME/URI path). Before the fuzz tail
it runs a frame-path
performance budget: warm-up plus 200 timed `OpenHarmonyWindowRenderer.Render` frames over a fixed
401-node tree, reporting average/p50/p95/max frame time and the managed allocation delta and
failing the suite when the (deliberately loose) budget is exceeded.

## Running it

```bash
# The project references the maui-ohos slice and two assemblies built from this repository.
# Override the defaults with the MAUI_SLICE_DIR / HOSTING_DLL / OPENHARMONY_GRAPHICS_DLL env vars
# (or the MauiSliceDir / HostingDll / OpenHarmonyGraphicsDll MSBuild properties) before building
# elsewhere; an explicit -p: value wins over the environment and the absolute fallbacks.
dotnet build -v:q
dotnet bin/Debug/net11.0/verify.dll | grep -c '\[verify\]'   # expect 208 (203 checks + 4 fuzz + 1 perf)
```

The `interaction-regression` workflow (`.github/workflows/interaction-regression.yml`) runs the
suite on a GitHub runner as a real gate: it checks out this repository plus `springmin/maui-ohos`
(`feature/openharmony`, the branch carrying `src/Core/src/Platform/OpenHarmony`), builds
`src/Microsoft.OpenHarmony.Hosting` and `src/Microsoft.OpenHarmony.Maui.Graphics` in Release,
points `MAUI_SLICE_DIR` / `HOSTING_DLL` / `OPENHARMONY_GRAPHICS_DLL` at those roots, and fails the
job unless the run exits 0, reports at least 199 `[verify]` lines, the perf line reports
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

A violation throws (unhandled exception, non-zero exit) after the numbers are printed, so CI logs
keep the evidence. Measured on the OpenHarmony dev host (200 frames): avg ~3.5-3.8 ms, p50
~3.4-3.7 ms, p95 ~4.5-4.7 ms, max 6.4-7.2 ms, max/avg ~1.7-2.1, ~185 KiB allocated per frame (the
accessibility frame diff rebuilds the 401-node shadow tree: reported for context, not asserted),
section wall time ~750-810 ms; the whole suite stayed within ~1 s of the unmodified 199-line run.
On a normal CI runner the one remaining native lookup inside `Render` is sub-millisecond, so the
reported average should be well under 1 ms.

## Notes

- Output goes to `bin/Debug/net11.0/verify.dll` (run the dll, not the apphost: the device policy
  blocks codesigned ELF apphosts on some machines).
- The suite fails loudly (unhandled exception) when a slice change breaks startup or when an
  assertion for the gesture flows (including the drag-and-drop checks) does not hold; keep it at
  203 checks plus the 4 fuzz lines plus the 1 perf line (208 `[verify]` lines) when touching the
  platform slice.
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
  exercised with the exact "name\taddress" payload (including a nameless record and a record
  with no tab), the adapter-state parser with the `access.BluetoothState` values ("2" on,
  "0"/"1"/garbage off), and the discovered-device push with the native-shaped
  `OnDeviceFoundPayload` records (a named record and an address-only record raise `DeviceFound`,
  null/empty payloads raise nothing). The shell half registers
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
  `__hwvSendMessage` posts into the managed handler. Off-device there is no app context, so
  registration is a no-op. The JS -> .NET `__hwvInvokeDotNet` endpoint is implemented: the shell
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
  hosting assemblies on the runner and gates on the `[verify]` line count (>=199) plus the perf
  `within=True` marker (see "Running it" above).
- Accessibility publish-contract coverage (R2b): the suite reflects
  `OpenHarmonyAccessibility.AccessibilityNode` (16 parameters now that hint, range and checked
  are published) and parses `ohos_host_accessibility_node`/`_get` out of
  `src/OpenHarmonyHost/openharmony_host.c` plus the shared header, comparing argument counts,
  normalized names, type kinds and the UTF-8 string marshalling; a missing/renamed/reordered
  argument fails the run instead of shifting registers on device. The probe tree also checks the
  value mapping (slider Minimum/Maximum/Value, progress 0/1/Progress, switch/checkBox 0/1,
  absent range NaN/NaN and checked -1 elsewhere) and that a slider value change with unchanged
  text/bounds raises a page-state update while an unchanged frame stays quiet.
