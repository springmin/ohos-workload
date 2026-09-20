# Interaction regression suite (headless)

The 191-check MAUI-on-OpenHarmony interaction harness. It builds the platform slice sources from the
`maui-ohos` working tree and drives the app host without a device: touch/drag/pinch/pointer input,
overlays, gestures (tap/pan/swipe/pinch/pointer/drag-and-drop), sensors/haptics/notification/picker
wiring, the app-theme colour-mode handler, the launcher/browser/share ability bridge, the
accessibility shadow tree snapshot, the menu table/activation bridge, the WebView JavaScript
bridge (script evaluation + `dotnetHost.postMessage`), the contacts/calendar and
Bluetooth/printing platform extras (off-device degradation plus the delimited payload parsers
and the text-to-PDF renderer) and the Essentials Battery/DeviceDisplay push bridge (payload
parsers plus the ModuleInitializer-installed defaults).

## Running it

```bash
# The project references the maui-ohos slice and two assemblies built from this repository.
# Override the defaults with the MAUI_SLICE_DIR / HOSTING_DLL / OPENHARMONY_GRAPHICS_DLL env vars
# (or the MauiSliceDir / HostingDll / OpenHarmonyGraphicsDll MSBuild properties) before building
# elsewhere; an explicit -p: value wins over the environment and the absolute fallbacks.
dotnet build -v:q
dotnet bin/Debug/net11.0/verify.dll | grep -c '\[verify\]'   # expect 191
```

The `interaction-regression` workflow (`.github/workflows/interaction-regression.yml`) runs the
suite on a GitHub runner as a real gate: it checks out this repository plus `springmin/maui-ohos`
(`feature/openharmony`, the branch carrying `src/Core/src/Platform/OpenHarmony`), builds
`src/Microsoft.OpenHarmony.Hosting` and `src/Microsoft.OpenHarmony.Maui.Graphics` in Release,
points `MAUI_SLICE_DIR` / `HOSTING_DLL` / `OPENHARMONY_GRAPHICS_DLL` at those roots, and fails the
job unless the run exits 0, reports at least 191 `[verify]` lines and logs no `Unhandled` line.

## Notes

- Output goes to `bin/Debug/net11.0/verify.dll` (run the dll, not the apphost: the device policy
  blocks codesigned ELF apphosts on some machines).
- The suite fails loudly (unhandled exception) when a slice change breaks startup or when an
  assertion for the gesture flows (including the drag-and-drop checks) does not hold; keep it at
  191 checks when touching the platform slice.
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
- CI wiring: `.github/workflows/interaction-regression.yml` builds the slice checkout and the
  hosting assemblies on the runner and gates on the 191-check output (see "Running it" above).
