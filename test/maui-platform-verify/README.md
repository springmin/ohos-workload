# Interaction regression suite (headless)

The MAUI-on-OpenHarmony interaction harness (374 interaction checks, a 4-line fuzz tail, a
frame-path performance budget and an accessibility publish-path budget). It builds the platform
slice sources from the
`maui-ohos` working tree and drives the app host without a device: touch/drag/pinch/pointer input,
overlays, gestures (tap/pan/swipe/pinch/pointer/drag-and-drop), sensors/haptics/notification/picker
wiring, the app-theme colour-mode handler, the launcher/browser/share ability bridge, the
accessibility shadow tree snapshot, the menu table/activation bridge, the WebView JavaScript
bridge (script evaluation + `dotnetHost.postMessage`), the contacts/calendar and
Bluetooth/printing platform extras (off-device degradation plus the delimited payload parsers
and the text-to-PDF renderer), the Essentials Battery/DeviceDisplay push bridge (payload
parsers plus the ModuleInitializer-installed defaults), the BATCH-1 Essentials real bridges
(runtime permissions through `abilityAccessCtrl.requestPermissionsFromUser`, the system
pasteboard through `@ohos.pasteboard` and network access through the NetworkKit observer: source
pins plus the fast off-device degradation), the BATCH-2 Essentials real bridges (email/SMS/phone
dialer through the startAbility `mailto:`/`sms:`/`tel:` URIs, the screenshot host capture with the
asynchronous PNG poll and the geocoding `ohos_host_geocode_request`/`host.geocodeResult` bridge
with the GeoAddress parser: source pins plus the fast off-device degradation), the D1
screen-reader announce wiring (the text-carrying `ohos_host_accessibility_announce` export with
its event-kind fallback: managed P/Invoke + host-source pins and an off-device bookkeeping
probe), the S-series features (the
BlazorWebView handler/manager/file-provider path, the accessibility node-count export, the
flashlight default/degradation and the file-share dispatch/MIME/URI path), the V-series
on-demand app-context publish (V8: native/NAPI/shell-template checks plus an off-device drill
of the managed bridge's surface-replay seam), and the PG2 packaging/host invariants (the runtime
natives staged into the signed `libs/<abi>/` with their `dotnet.zip` exclusion, the
`libc++_shared` staging + re-sign pass, the `.dotnet-payload.json` marker the staging writes and
the shell reads, the host's `libs/<abi>/` -> app-dir symlink bridge with the payload-in-libs
app_dir resolution and the exec-memory policy/probe, and the build-host `DT_NEEDED libhostfxr`
guard), plus the PI1/PI2/RB batch (the app-package root,
the Create=0 send + pre-Run activation, the carousel grouping flatten, the shadow mapper/
`DrawShadow`, the SecureStorage fallback note, the platform application object, the window-overlay
host and the TFM gating / public-API baseline / `SupportedPlatform` / frozen-ABI review
artifacts). Before the fuzz tail
it runs a frame-path performance budget (warm-up plus 200 timed
`OpenHarmonyWindowRenderer.Render` frames over a fixed 401-node tree, reporting
average/p50/p95/max frame time, the max/average ratio, a p95/average jitter ratio and the managed
allocation delta) and an accessibility
publish-path budget (unchanged vs mutated frames over the same tree, see "Performance budget"
below), failing the suite when the (deliberately loose for wall-clock, deterministic for
allocation and jitter) budgets are exceeded.

## Running it

```bash
# The project references the maui-ohos slice and two assemblies built from this repository.
# Override the defaults with the MAUI_SLICE_DIR / HOSTING_DLL / OPENHARMONY_GRAPHICS_DLL env vars
# (or the MauiSliceDir / HostingDll / OpenHarmonyGraphicsDll MSBuild properties) before building
# elsewhere; an explicit -p: value wins over the environment and the absolute fallbacks.
dotnet build -v:q
dotnet bin/Debug/net11.0/verify.dll | grep -c '\[verify\]'   # expect 468 (455 interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf)
```

The `interaction-regression` workflow (`.github/workflows/interaction-regression.yml`) runs the
suite on a GitHub runner as a real gate (on push to `master`, on pull requests and on
`workflow_dispatch`): it checks out this repository plus `springmin/maui-ohos`
(`feature/openharmony`, the branch carrying `src/Core/src/Platform/OpenHarmony`), builds
`src/Microsoft.OpenHarmony.Hosting` and `src/Microsoft.OpenHarmony.Maui.Graphics` in Release,
points `MAUI_SLICE_DIR` / `HOSTING_DLL` / `OPENHARMONY_GRAPHICS_DLL` at those roots, and fails the
job unless the run exits 0, the suite's own `[suite]` contract line reports `assert=True` with at
least the floor declared in `Program.cs`, both perf lines report `within=True`, and no `Unhandled`
line is logged. The floor (448 = 468 - 20, the documented convention) lives only in `Program.cs`;
the workflow and `scripts/preflight.sh` both read the printed `[suite] checks=... floor=...` line
instead of repeating a literal, so the two local/CI thresholds cannot drift apart.

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
the p95/average jitter ratio, the managed allocation delta (`GC.GetAllocatedBytesForCurrentThread`,
total and per frame) and the section's own wall time. The budget is intentionally loose for the
wall-clock ceilings because CI runners are shared, the suite runs in Debug and the off-device frame
keeps one failed native lookup on the dev host; the allocation and jitter ceilings are tight
because they are the regression signals the loose ceilings miss:

- `avg <= 20 ms` - the managed work is sub-millisecond; a uniform regression (extra walk, blocking
  call, quadratic layout) has to add more than ~14 ms/frame to trip this.
- `max <= 250 ms` - a very loose absolute hang guard.
- `max/avg <= 100x` - the raw relative outlier check, so a pathological single frame fails even on
  a machine where the absolute ceilings are too loose; single preempted frames (10-30x a
  sub-millisecond average) are tolerated.
- `p95/avg <= 2x` (the reported `jitter`) - the stability gate. The raw `max/avg` is not a stable
  signal on a loaded shared host: a single preempted frame measured 3.4x here while the frame path
  was healthy, and the pre-FIX-P2 baseline logged 8.1x, so the tight gate uses the 95th percentile
  instead (robust to one or two preempted frames, still catching a sustained regression where at
  least one frame in twenty - or every frame - gets slower). Measured: 1.08x on CI, 1.3-1.7x on
  the dev host (idle and loaded; 1.30-1.31x after the managed perf batch), so 2x keeps a
  documented margin.
- `alloc/frame <= 13,824 B` - the allocation gate, re-based at 3x the post-managed-perf-batch
  baseline (4,504 B/frame on the dev host = a deterministic 900,800 B per 200-frame run; the
  pre-batch baseline was 72,864 B/frame here and 72,056-72,080 B on CI). 3x = 13,512 B, rounded
  up to the next 512-byte boundary (13.5 KiB) so the ceiling is a tidy unit with a hair of
  margin (3.07x) and stays at the lower end of the documented 3-4x band. The delta is
  deterministic per code path, so unlike the wall-clock budgets this gate needs no noise slack;
  it catches a re-introduced per-frame allocation storm (the pre-FIX-P2 storm measured
  241,688 B/frame = 3.3x of the old baseline) long before the loose wall-clock ceilings would.
  If a legitimate baseline growth lands near the ceiling, raise the constant deliberately (see
  the constant comment in `Program.cs`).

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
keep the evidence. Measured on the OpenHarmony dev host after the managed perf batch (200
frames): avg ~3.1-3.5 ms, p50 ~3.0-3.4 ms, p95 ~4.1-4.5 ms, max ~5.0-5.4 ms (raw max/avg
1.6x, i.e. one or two preempted frames), jitter p95/avg 1.30-1.31x, 4,504 B allocated per frame
(also under load - the allocation delta is deterministic at 900,800 B per run), section wall time
~0.66-0.75 s; the a11y block adds ~0.2-0.4 s (50 skip + 50 mutated passes) with render ratios
~10-15x and publish ratios ~80-120x. On a normal CI runner the one remaining native lookup inside
`Render` is sub-millisecond: the pre-batch runs reported avg ~0.61-0.63 ms, p95 0.65-0.68 ms,
jitter ~1.08x and 72,056 B/frame, and the a11y block reported ~0.3/0.5 ms for the render step and
~0.07/0.28 ms for the publish pass (skip/republish). The post-batch run (commit a10b73e) reported
avg 0.488 ms, p95 0.698 ms, jitter 1.43x and 3,720 B/frame, i.e. the ceiling is 3.72x the CI
baseline. Every run ends with the `[suite]` contract line
(`checks=391 total=391 floor=371 assert=True`), which the workflow and `scripts/preflight.sh`
parse.

## Notes

- Output goes to `bin/Debug/net11.0/verify.dll` (run the dll, not the apphost: the device policy
  blocks codesigned ELF apphosts on some machines).
- The suite fails loudly (unhandled exception) when a slice change breaks startup or when an
  assertion for the gesture flows (including the drag-and-drop checks) does not hold; keep it at
  455 interaction checks plus the 4 fuzz lines plus the 1 frame-perf line plus the 8 a11y-perf
  lines (468 `[verify]` lines) when touching the platform slice. The total and the floor
  (total - 20) are declared in `Program.cs`; the run ends with a `[suite] checks=... floor=...
  assert=...` line and fails itself when the printed count is below the floor, so the CI job and
  `scripts/preflight.sh` do not repeat the threshold.
- Image decode coverage (P2b-IMG): the stream image is pinned through the view-scoped seam - a
  large destination asks for the preview first (long edge / 8) and the display size on the
  redraw that follows, a small (100x100) isolated tree decodes once at its own size with no
  preview pass, a forced decode failure draws the placeholder once for the generation without
  per-frame retries, and the host/managed contract check asserts the sized export, the
  desired-size option, the decode-size cache key, the optional-library shim and the managed
  `LibraryImport` fallback.
- Contacts/calendar coverage: `OpenHarmonyContacts.FindAsync` and
  `OpenHarmonyCalendar.ListUpcomingAsync`/`AddEventAsync` return empty/false without throwing
  off-device and report `IsSupported == false` before and after the call (the permission probe
  fails without the host library); the delimited payload parsers are exercised with the
  exact "name\tphone" and "title\tstartIso\tendIso" payload shapes the ArkTS shell sends. The
  shell half imports `@kit.ContactsKit`/`@kit.CalendarKit` (both compile with the ArkTS toolchain)
  and requires `ohos.permission.READ_CONTACTS` (contacts) and `ohos.permission.READ_CALENDAR` /
  `ohos.permission.WRITE_CALENDAR` (calendar) at runtime; without the manifest declaration the
  sinks answer "unavailable" instead of guessing. The packaging target declares them by feature:
  `-p:'OpenHarmonyFeatures="contacts;calendar"'` emits the `requestPermissions` entries with their
  reason and usedScene (COMP-ARKTS S1), and an undeclared shell request point is reported (strict
  mode fails) by `_OpenHarmonyResolvePermissions`; `OpenHarmonyExtraPermissions` remains for raw
  permission names.
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
  `access`/`connection` from `@kit.ConnectivityKit` and `print` from `@kit.BasicServicesKit`,
  gates the print path on `canIUse('SystemCapability.Print.PrintFramework')` and requires
  `ohos.permission.ACCESS_BLUETOOTH` (user_grant, requested at call time) and
  `ohos.permission.PRINT` (system_grant); declare them with
  `-p:'OpenHarmonyFeatures="bluetooth;print"'` so the packaged module.json carries the entries
  with reason/usedScene.
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
- Host-boundary lifetime guards (F1: A1/A2/A5/A6/A7/A8) and per-document markers (B3): nine
  source-contract pins parse the committed sources, so a regression fails this off-device run
  instead of shipping a pack built from drifted sources. A1 asserts `g_context_mutex` and that
  the pending-snapshot take, the superseded free, the `g_app` publish and the setter's
  replacement all sit inside the locked region (the adoption race was an ASan use-after-free in
  `strdup`); A2 asserts the `g_a11y_mutex` region around begin/node/commit/count/get, the
  pthread-key per-thread string copies the 17-argument getter fills under the lock and the
  unchanged 16/17/16 signature counts; A5 asserts `OH_ArkUI_DestoryAccessibilityEventInfo`
  after `OH_ArkUI_SendAccessibilityAsyncEvent` plus the failure-path destroy (one leaked event
  info per published event before the fix); A6 asserts the pre-handle lifecycle/NodeContent
  queue globals, their transfer to the handle inside the A1 critical section and the
  register_bridge flush; A7 asserts the NAPI `g_launch_lock`/`g_launch_requested`
  reject-before-allocate guard with both failure-path clears and the native
  `g_launch_in_progress` guard set/cleared under the lock with the six `OhosHostEndLaunch()`
  failure calls; A8 asserts `ImeUtf8PrefixLength` backs off to a UTF-8 sequence boundary at both
  IME call sites (and no `strncpy` call site remains); B3 asserts the shell's
  `window.__ohHybridId`/`window.__ohBlazorId` stamps in all three preview templates and the
  marker-checked `'skip'` eval before `SendRawMessage` (hybrid) and `SendMessage` (Blazor),
  including the skip log. That is 9 `[verify]` lines: 253 + 9 = 262, the BATCH-1-era total
  (249 interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf). With the BATCH-2 lines below
  the suite reports 275 = 262 + 4 + 1 + 8; the audit and PG2 pins below take it to 288.
- BATCH-1 Essentials real bridges (permissions / clipboard / connectivity): six `[verify]` lines
  cover both halves of each bridge. Off-device each request fails fast (the 30 s permission and
  5 s clipboard timeouts are never waited out) and degrades to Denied / null / false / Unknown;
  the pasted pasteboard 'update' and NetworkKit change pushes are replayed through the same
  private native-shaped callbacks the host invokes, raising `ClipboardContentChanged` and
  `ConnectivityChanged` (the level map 0/1/2/3 -> Unknown/None/Local/Internet is asserted,
  including the getter's -1). The source pins parse the C definitions and the shared header
  (`ohos_host_request_permission`, `ohos_host_register_permission_result`,
  `ohos_host_clipboard_request`, `ohos_host_clipboard_register_result`,
  `ohos_host_clipboard_register_changed`, `ohos_host_network_access_register`,
  `ohos_host_network_access_notify`), the NAPI sinks and module-table names
  (`registerPermissionSink`/`permissionResult`, `registerClipboardSink`/`clipboardResult`/
  `notifyClipboardChanged`, `notifyNetworkAccess`), and the shell's statically imported
  `@ohos.pasteboard` sink with the on-demand `ohos.permission.READ_PASTEBOARD` request plus the
  lazily imported `@kit.NetworkKit` observer (`createNetConnection`); the three preview
  templates must stay byte-identical. IPermissions keeps the permission-name map and still
  answers `CheckStatusAsync` from `OH_AT_CheckSelfPermission`; IClipboard no longer has a
  file-backed store (the old `OpenHarmonyClipboard(string? path)` constructor is gone) and
  IConnectivity no longer reports a constant Unknown.
- BATCH-2 Essentials real bridges (email / SMS / phone dialer, screenshot, geocoding): twelve
  `[verify]` lines. `Email.Default`, `Sms.Default`, `PhoneDialer.Default`, `Screenshot.Default`
  and `Geocoding.Default` resolve to the slice implementations from the `UseOpenHarmony` DI
  registrations; the mailto builder is pinned byte-for-byte against the shipped shared
  `EmailImplementation.GetMailToUri` shape (`to`/`cc`/`bcc`/`subject`/`body`, every value
  `Uri.EscapeDataString`'d, `mailto:?` for an empty message) and the SMS builder to
  `sms:<recipients>?body=...`; the dialer keeps MAUI's `ArgumentNullException` validation and only
  then dispatches `tel:`. Off-device all five degrade fast (no timeout wait), a compose with an
  attachment logs the documented drop (one viewData Want cannot carry a file), `CaptureAsync`
  answers null without leaving a temp PNG, and both geocoding calls answer empty. The screenshot
  helpers are checked against the harness's 1x1 PNG (IHDR width/height, complete vs truncated
  IEND, `OpenReadAsync`/`CopyToAsync` round trip, and the documented PNG fallback for a Jpeg
  request). The geocoding parser is driven with a realistic `@ohos.geoLocationManager` GeoAddress
  array (placeName -> FeatureName, administrativeArea -> AdminArea, subAdministrativeArea ->
  SubAdminArea, streetNumber -> SubThoroughfare, ...) and with nested-coordinate/numeric-string
  locations; malformed payloads answer empty. The source pins parse the managed P/Invokes
  (`ohos_host_screenshot`, `ohos_host_geocode_request` with its int queued/dropped return,
  `ohos_host_register_geocode_result`), the C definitions and shared-header declarations, the
  NAPI sinks/answers (`registerScreenshotSink`, `registerGeocodeSink`/`geocodeResult`), the
  shell's `window.snapshot` + `packToFile` screenshot sink and the `JSON.parse(arg)` /
  `getAddressesFromLocationName` / `getAddressesFromLocation` / `host.geocodeResult(...)` call
  sites in all three byte-identical templates. The registration pass pins the ImageButton handler
  table entry plus a real `ImageButton` through the connector, the self-installing
  `SemanticScreenReader` default (no registration added) and the window handler/title mapper; the
  optional window pin covers the `ohos_host_set_window_title`/`_rect` exports and the shell
  `registerWindowTitleSink`/`registerWindowRectSink` sinks. That is 12 lines: 262 + 12 = 274 =
  261 interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf.
- D1 screen-reader announce wiring: `OpenHarmonyAccessibility.Announce` prefers the dedicated
  text-carrying host export `ohos_host_accessibility_announce` over the event-kind-only
  `ohos_host_accessibility_send_event(EventAnnouncement)` fallback kept for a host library that
  predates it. The managed P/Invoke is pinned reflectively (EntryPoint exact,
  `libopenharmonyhost.so`, `CharSet.Ansi`, `int` return, one `LPUTF8Str` string parameter), and
  the native half is pinned to the shared-header declaration, the `extern "C"` definition,
  `OH_ArkUI_AccessibilityEventSetTextAnnouncedForAccessibility(announceEvent, text)` and
  `ARKUI_ACCESSIBILITY_NATIVE_EVENT_TYPE_ANNOUNCE_FOR_ACCESSIBILITY`. Off-device the behavioral
  probe drives both the static call and the installed `SemanticScreenReader.Default` with the
  provider-availability flag restored (then put back): no throw, `LastAnnouncement` tracks the
  text, whitespace stays a no-op, `WouldAnnounce` stays true while the call reaches the host
  boundary and `AnnouncementsSent` counts only an accepted event. That is 1 line: 274 + 1 = 275 =
  262 interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf.
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
  hosting assemblies on the runner and gates on the suite's `[suite]` contract line (the floor
  declared in `Program.cs`, cross-checked against `grep -c '[verify]'`) plus both perf
  `within=True` markers (see "Running it" above). The job runs on push to `master`, on pull
  requests and on `workflow_dispatch`; it only needs the read-only `contents` permission and no
  secrets, so fork PRs run it with the default read-only token.
- Accessibility publish-contract coverage (R2b): the suite reflects
  `OpenHarmonyAccessibility.AccessibilityNode` (16 parameters now that hint, range and checked
  are published) and parses `ohos_host_accessibility_node`/`_get` out of
  `src/OpenHarmonyHost/openharmony_host.c` plus the shared header, comparing argument counts,
  normalized names, type kinds and the UTF-8 string marshalling; a missing/renamed/reordered
  argument fails the run instead of shifting registers on device. The probe tree also checks the
  value mapping (slider Minimum/Maximum/Value, progress 0/1/Progress, switch/checkBox 0/1,
  absent range NaN/NaN and checked -1 elsewhere) and that a slider value change with unchanged
  text/bounds raises a page-state update while an unchanged frame stays quiet.
- Audit pins (safe area / FontImageSource / cells / Shell chrome): nine `[verify]` lines cover
  the surfaces the follow-up audit found unguarded. `audit safearea` parses
  `OpenHarmonySafeArea.cs` (the `OpenHarmonyBridge.TryGetAvoidArea` read, the `Container`
  fallback and the overlap-only `Pad`) and `OpenHarmonySafeAreaArrange.cs` (depth-bounded walk,
  `OpenHarmonyContentArrange` delegation), pins both the app-host and page-handler usage and the
  host's `ohos_host_get_avoid_area` getter. `audit fontimage` pins the FontImageSource ->
  `OpenHarmonyFontImageSource` route, its desired-size read and the per-key glyph cache under
  the lock. `audit listcells` pins the SwitchCell/EntryCell branches and their two-way bindings
  (tap -> `On`, text -> `Cell.Text`, completed -> `SendCompleted`). `audit search` pins the
  `ohos_host_shell_search_set` / `ohos_host_shell_search_set_listener` DllImports, the
  changed-payload publish (op 0/1/2 routed back onto Query/QueryConfirmed) and the handler's
  page/shell attach-detach. `audit flyout` pins the `ohos_host_shell_flyout_header`/`_footer`
  publish, the first/last compositor row and the leading-row selection offset. `audit
  shellchrome` pins the `TabBarIsVisible` resolution (nearest page/ancestor, then shell) and the
  Disabled/Locked flyout behavior. `audit windowrect` pins the window title/rect DllImports, the
  X/Y/Width/Height mappers and the usable-size publish guard; `audit windowhost` pins the
  host's non-positive-size rejection, both clamp constants (width/height 16384, x/y 32768) and
  both bounds per axis. `audit shell sinks` pins the search/flyout/window sinks, the three
  `notifyShellSearch` call sites and the `moveWindowTo`+`resize` apply in all three preview
  templates (which stay byte-identical). That is 9 lines: 275 + 9 = 284 = 271 interaction
  checks + 4 fuzz + 1 frame perf + 8 a11y perf; the workflow floor moves with the total
  (284 - 20 = 264).
- PG2 packaging/host invariants (staged runtime natives / libc++ / module.json + Blazor +
  FileWrites / host bridge / build-host guard): five `[verify]` lines, all parsing committed sources. `pg2 pack runtime libs` pins the
  preview.22/23/24 `OpenHarmony.Hap.targets` files (which stay byte-identical): the publish
  `*.so` glob (`_OpenHarmonyPayloadNativeLib`), the ELF-magic validation and the host/libc++
  skip names, the copy into `libs/$(OpenHarmonyAbi)/` with the `_OpenHarmonyStagedRuntimeLib` /
  `_OpenHarmonyStagedRuntimeLibCount` / `_OpenHarmonyStagedRuntimeLibBytes` outputs, the hard
  error when the set is empty, and the deterministic zip half: `ExcludeFileNames` receives
  `@(_OpenHarmonyStagedRuntimeLib->'%(Filename)%(Extension)')` and drops those names
  (`Path.GetFileName` + `ExcludedCount`), with the staging before the `OpenHarmonyCodesign`
  pass and the zip after it. `pg2 pack libcxx` pins the `libc++_shared.so` lookup (the explicit
  `OpenHarmonySdkRoot`/`OHOS_NDK` roots and the `OpenHarmonyLibCxxShared` override; no `$HOME`
  probe), the missing-library hard errors, the `libs/<abi>/` copy and the in-place re-sign of the
  staged libs (the vendor `.codesign` rationale plus the missing
  `MicrosoftNETBuildTasksAssembly` failure). `pg2 pack contracts` pins the JSON-aware
  `OpenHarmonyGenerateModuleJson` task (no `ReadLinesFromFile`), the `@(StaticWebAsset)`-only
  Blazor staging, the four `FileWrites` registrations and the
  `OpenHarmonyAfterPublishDependsOn` hook. `pg2 host runtime bridge` parses
  `openharmony_host.c`: `OhosHostEnsureRuntimeLibs` is called on both the `run_app` and
  `start_app` paths before their `OhosHostOpenHostfxr`, its libs directory is derived through
  `dladdr` on `ohos_host_run_app`, the symlink is backed by the tmp+rename copy fallback
  (warned once per process), the name filter covers the nine runtime prefixes and the
  scan/link bounds, and the one summary log reports ensured/copied/failed with the last errno.
  `pg2 build-host guard` pins `scripts/build-host.sh`: the `READELF` default/fallback/no-readelf
  error, the `grep -q 'libhostfxr'` DT_NEEDED failure with its exit 1 message, and the guard's
  position after the link and before the self-sign pass. That is 5 lines: 284 + 5 = 289 = 276
  interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf; the workflow floor moves with the
  total (289 - 20 = 269).
- Audit batch-2 pins (BLE GATT / lifecycle / list extras / settings / WebAuth / soft input + profiles /
  PE2 / Shell chrome / PJ): nine `[verify]` lines cover the surfaces the second audit found with
  zero source-contract coverage. `audit2 ble gatt` pins the managed request/result/event
  DllImports and callback delegates, the five shared-header declarations and NAPI definitions
  with their module-table names, and all three templates' `registerBluetoothGattSink` (with the
  `ohos.permission.ACCESS_BLUETOOTH` request) plus the result/event answers.
  `audit2 lifecycle` pins the IApplication handler with its four command-mapper entries, the app
  host's Created-before-Activated ordering for the Create event (once-guards plus the
  Created-from-Run path), the hosting enum numbering (Create=0/Destroy=1/Foreground=2/
  Background=3) and the templates' Foreground send; the Create=0 shell send (PI1) is reported as
  `createSend` but not required yet because it is not in the templates at this pin.
  `audit2 listextras` pins the CollectionView EmptyView/header-footer/SelectedItems/SelectionMode/
  RemainingItemsThreshold mappings and the ScrollToRequested wiring plus the shared materializer's
  header/footer/EmptyView factories, group ScrollTo rows, total/empty height and last-visible
  window. `audit2 settings` pins AppInfo's settings kind 4 and bundle-metadata getters with the
  host's set/get exports and the NAPI `setBundleInfo` name, plus the PostNotifications enablement
  bridge (op 0/1, DllImports, host exports, NAPI names, shell `isNotificationEnabledSync`/
  `requestEnableNotification`/`notificationPermissionResult`). `audit2 webauth` pins the
  WebAuthenticator implementation, its `FeatureNotSupportedException`/cancellation contract, the
  ModuleInitializer install and the DI registration. `audit2 softinput` pins the soft-input
  set/get/register exports and the managed inset reads, the ConnectionProfiles bearer-mask bridge
  (host parser, NAPI `notifyNetworkAccess`, managed `ConnectionProfile` mapping) and the shell
  `avoidAreaChange`/TYPE_KEYBOARD + `notifySoftInputArea`/`notifyNetworkAccess` pushes.
  `audit2 focuskeys` pins the PE2 focus hook (ViewMapper Focus/Unfocus + the surface id) and the
  internal key listener (DllImport, down/up constants, dispatch) with the host exports and the
  shell `onKeyEvent` -> `host.keyEvent` send. `audit2 shellchrome` pins the Shell TitleView
  resolution (Label text, rich-view note once), the ToolbarItems mirror/activation and the shell
  handler's chrome instance. `audit2 pj` pins PJ1 (animation loop register/pump/frame hook,
  scroll-physics tunables, the OpenHarmonyView offset/draw hooks, scrollbars and focus ring) and
  PJ2 (the tooltip manager's `ToolTip` mapper entry + present hook and the keyboard accelerator
  manager's key codes/handler/install). That is 9 lines: 289 + 9 = 298 = 285 interaction checks +
  4 fuzz + 1 frame perf + 8 a11y perf; the workflow floor moves with the total (298 - 20 = 278).
- PI1/PI2/RB pins (app-package root / Create=0 + pre-Run activation / carousel grouping /
  shadows / SecureStorage note / platform application / window overlays / TFM gating / public API /
  SupportedPlatform / frozen ABI): eleven `[verify]` lines for the newest slice surfaces, which
  had no source-contract coverage when the audit batch-2 pins were written. `pi1 apppackage` pins
  the FileSystem reads through `OpenHarmonyPaths.AppPackageDirectory` (the context `AppDir`) with
  the data-directory fallback and the missing-file `FileNotFoundException`. `pi1 create` pins all
  three templates' `LIFECYCLE_CREATE = 0` send from both entry-ability variants plus the page
  shell's 0-before-2 order, and the host's `_createReceived` completion of the activation when
  Create arrived before Run. `pi1 carousel` pins the grouped-ItemsSource flatten
  (`MaterializeItems`, `IsGroup`, the one-time `carousel.grouped` note) and the indicator counting
  the same slides. `pi1 shadow` pins `OpenHarmonyView.DrawShadow` (host shadow layer,
  `ClearEffects`), the `OpenHarmonyShadow` ViewMapper redraw hook and the renderer's
  `DrawShadow`-before-`Draw` order. `pi1 securestorage` pins the one-time file-key fallback note.
  `pi2 appobject` pins `OpenHarmonyMauiApplication` (`IPlatformApplication.Current = this`, the
  service-provider surface) and its `AddSingleton` + `IMauiInitializeService` registration.
  `pi2 overlay` pins `OpenHarmonyWindowOverlay` (register/unregister in Initialize/Deinitialize)
  and the host's `SurfacePresent` chaining (previous hook or `HostCanvas.Present`). `rb tfm` pins
  the OpenHarmony-only `MultiTargeting.targets` remove/define blocks and the Core.csproj
  `OpenHarmonyGraphicsAssembly` reference. `rb publicapi` pins the existing
  `src/Core/src/PublicAPI/net-openharmony` Shipped/Unshipped files, their `#nullable enable`
  header and the two PI2 types in the baseline. `rb supportedplatform` pins the single
  `<SupportedPlatform Include="openharmony" />` declaration in this repository's
  Directory.Build.props. `rb frozenabi` pins the `ohos_host_*`/`OHOS_HOST_APP_CONTEXT` ABI-freeze
  comment. That is 11 lines: 298 + 11 = 309 = 296 interaction checks + 4 fuzz + 1 frame perf +
  8 a11y perf; the workflow floor moves with the total (309 - 20 = 289).
- Audit batch-3 pins (FIX-MAUI residues: MB-1 bounded approval table / MB-2 guarded native
  callbacks / MB-3 app-package names / H-C2 approval + load channels): seven `[verify]` lines for
  the fixes that shipped without behavioural coverage here. `audit3 mb1` fills the web approval
  table through 200 `__OHNAV` requests and requires the 64-entry cap, the newest decision kept,
  the expired-marker prune on a page event, the oldest eviction when full and the one-shot
  consumption by the matching `started` event. `audit3 mb3` requires every traversal, rooted,
  drive-letter, UNC and control-character spelling to throw `ArgumentException` while five legal
  relative names keep the missing-file contract and the message carries the normalized
  `a/b/c.txt` name. `audit3 hc2 approvals` requires the eight file/foreign-looking targets to stay
  blocked while the absolute https target approves exactly (id, url); `audit3 hc2 load` pins the
  21-case `IsLoadableSourceUrl` table (app-internal references and the shell's own schemes stay
  loadable, network-path/UNC and scheme-like spellings are refused). `audit3 mb2 guards` attaches
  throwing handlers to the WebView JS-message, BLE-GATT, clipboard, sensor, menu, theme and
  hybrid boundaries, drives the private native entries and requires no escape, with the seven
  `NativeCallbackFailed` source guards pinned alongside; `audit3 mb2 status` requires the thrown
  failures to reach `dotnet-status.txt` flattened to one line. `audit3 host callbacks` does the
  same for this repository's ten `OpenHarmonyBridge` native entries (touch, frame, text input,
  text submitted, lifecycle, surface, pinch, web event, picker and keystore result): each private
  handler delegate is swapped for a thrower, the native entry is invoked, the delegate is
  restored and the ten inline `ReportCallbackFailure` guards are pinned in the source. That is 7
  lines: 309 + 7 = 316 = 303 interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf.
- PG2e pins (payload-in-libs app_dir resolution / payload marker / exec-memory policy + probe):
  five `[verify]` lines for the payload-in-libs launch path the host probes before hostfxr.
  `pg2 host resolve app dir` pins `OhosHostResolveAppDir` and both launch-path calls (the
  resolution runs before the runtime-lib bridge each path); `pg2 host resolve app dir log` pins
  the `used_own=0|1 own=... app=...` resolution log in both the hilog and stderr forms.
  `pg2 payload marker` pins the staging's `MarkerFileName=".dotnet-payload.json"` writer in all
  three preview packs (the libs entry count, the `payloadEntries`/`zipEntries` staging counters
  and the `zipSha256` of the packed fallback zip) plus the `PAYLOAD_MARKER_NAME`/`PayloadMarker`
  reader in both entry-ability templates. `pg2 host exec memory policy` pins
  `OhosHostApplyExecMemoryPolicy` on both launch paths before their `OhosHostOpenHostfxr`, the
  `DOTNET_EnableWriteXorExecute` environment pin and the `xwe=0|1 source=default|file` log in
  both forms; `pg2 host exec memory probe` pins the one-shot `OHOS_DOTNET probe:` mapping line
  and its `dotnet-status.txt` append (and the A7 native pin counts all six failure-path
  `OhosHostEndLaunch()` calls, the app_dir resolution failure included). That is 5 lines:
  316 + 5 = 321 = 308 interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf; the suite's
  documented floor convention is total - 20 = 301, declared once in `Program.cs` (the
  `verifyCheckTotal`/`verifyCheckFloor` constants behind the `[suite]` line). When checks are
  added or removed, update that one constant and the totals in this README; the workflow and
  preflight pick the floor up from the printed line automatically.
- KIT-IMPL HMS kit platform extensions (Share Kit multi-file + Scan Kit default UI): three
  `[verify]` lines. `kit1 shell probe` pins both probes and their sinks/call sites in the
  preview.22/23/24 shells and requires all three packs to carry the block: the module
  specifiers stay in variables and the resolved value is cast to a local structural interface,
  because a literal `import('@kit.ShareKit')` is a hard ArkTS compile error on the OpenHarmony
  SDK (10505001), and the scan probe is additionally gated by
  `canIUse('SystemCapability.Multimedia.Scan.ScanBarcode')`; the sinks register only when the
  runtime resolves the kit, so the default shell registers neither. `kit2 bridge pins` pins the
  C ABI declarations (`ohos_host_share_kit_share`/`ohos_host_scan_*`), the NAPI sink/notify
  names plus the module-table entries, the managed P/Invoke entry points/the multi-file share
  routing and the `OpenHarmonyScan` public-API baseline entry. `kit3 degradation` drives both
  managed bridges with no host library: the Share Kit dispatch answers false, `ScanAsync`
  completes with null and `IsSupported` answers false, all without throwing. That is 3 lines:
  321 + 3 = 324 base lines, plus the two COMP-ARKTS conformance lines (sources + abc
  provenance) = 326 = 313 interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf; the workflow
  floor moves with the total (326 - 20 = 306).
- KIT-EXT2 HMS kit platform extensions (Push token + Account authorization + Map): four
  `[verify]` lines. `kit4 shell probe` pins the three probes and their sinks/call sites in the
  preview.22/23/24 shells (the variable-specifier imports
  `@kit.PushKit`/`@kit.AccountKit`/`@kit.MapKit` cast to local structural interfaces, the
  `registerPushSink`/`registerAccountSink`/`registerMapSink` registrations, the `getToken`/
  `deleteToken`, `createAuthorizationWithHuaweiIDRequest` + `quickLoginAnonymousPhone` +
  `forceAuthorization=false`, the `SystemCapability.Map.Core` check, the overlay-module probe with
  its second variable specifier `'./map/MapOverlay'`, the Map command ops and the
  `NodeContainer(this.hmsMapOverlay.nodeController)` mount, and the aboutToAppear call sites) and
  requires all three packs to carry the block. `kit7 map overlay module` (R2-3) pins the
  `templates/ets/map/MapOverlay.ets` module in all three packs (literal `@kit.MapKit` import,
  `MapComponent({...})` builder, `MapOverlayProxy`/`nodeController`, marker/click/camera wiring,
  `BuilderNode` build/dispose) and the `ARKTS_SDK_FLAVOR=harmony` gate in
  `scripts/build-arkts-shell.sh` that is the only path copying it into a project. `kit5 bridge
  pins` pins the C ABI declarations (`ohos_host_push_*`/`ohos_host_account_*`/`ohos_host_map_*`
  including the R2-3 `ohos_host_map_command` rename), the NAPI sink/notify names plus the
  module-table entries, the `host-exports.txt` rename, the managed P/Invoke entry points with the
  kit error-code maps (`1000900010`/`1000900012` push, `1001502014`/`1001500001` account) and the
  public-API baseline entries (overlay methods, events and region/marker types). `kit6
  degradation` drives all four new managed bridges with no host library: Push GetToken/DeleteToken
  answer `Unavailable` (no token) and `IsSupported` false, Account answers `Unavailable` (no
  payload) and `IsSupported` false, Map answers null with `IsSupported`/`IsOverlayAvailable` false
  and every overlay call (Show/Hide/Close/SetRegion/AddMarker) answering false without firing an
  event, all without throwing. That is 4 lines: 324 + 4 = 328 base lines, plus the two COMP-ARKTS
  conformance lines = 330 = 317 interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf; the
  workflow floor moves with the total (330 - 20 = 310).
- R2-SHELL-EXT (bridged AOT start_app + Live View Kit probe, 2026-09-26): the bridged AOT route
  is folded into the existing `a7 native launch guard` line (the pin now requires the
  `OhosHostAotLaunchRun` trampoline, the `openharmony_app_main` dlopen/dlsym probe, the
  `aot=0|1` log pair, the fall-through and the now-seven `OhosHostEndLaunch()` failure paths), so
  it adds no line. The Live View batch adds three: `kit8 shell probe` pins the
  `canIUse('SystemCapability.LiveView.LiveViewService')` + `@kit.LiveViewKit` variable-specifier
  probe, the `registerLiveViewSink` sink and its `isLiveViewEnabled`/start/update/stop TIMER
  scene body (`title`/`text`/`progress`/`time`) with the `this.probeLiveViewKit()` call site in
  all three byte-identical packs; `kit9 bridge pins` pins the four `ohos_host_liveview_*` C ABI
  declarations and definitions, the `HostSink liveview`/module-table names, the
  `host-exports.txt` entries, the managed P/Invoke entry points with the
  `1003500004`/`1003500005`/`NoActiveView` status marks, the public-API baseline entries and the
  ui-abc provenance literals in `scripts/build-arkts-shell.sh`; `kit10 degradation` drives
  Start/Update/Stop with no host library: all three answer `Unavailable` and `IsSupported` is
  false, without throwing. The companion interpreter switch adds `pg2 host interp policy`: the
  `<files>/interp.txt` helper (leading digit -> the value), the guarded
  `setenv("DOTNET_InterpMode", ...)` inside `OhosHostApplyExecMemoryPolicy` and the
  `interp=0|N source=default|file` log pair. That is 4 lines: 330 + 3 + 1 = 334 = 321 interaction
  checks + 4 fuzz + 1 frame perf + 8 a11y perf; the workflow floor moved with the total
  (334 - 20 = 314).
- A2-TTS (CoreSpeechKit text-to-speech probe, 2026-09-27): the fourth kit batch adds three:
  `kit11 shell probe` pins the `canIUse('SystemCapability.AI.TextToSpeech')` +
  `@kit.CoreSpeechKit` variable-specifier probe, the `registerTtsSink` sink with its
  create/speak/stop/locales/isBusy ops (lazy engine: person 0, offline mode, the listener that
  answers a pending speak by the kit request id) and the `this.probeTtsKit()` call site in all
  three byte-identical packs; `kit12 bridge pins` pins the four `ohos_host_tts_*` C ABI
  declarations and definitions (the old `ohos_host_tts_speak` export is gone), the
  `HostSink tts`/module-table names, the `host-exports.txt` entries, the managed P/Invoke entry
  points with the op codes and the `1002300005` BusinessError mark, the `IsSupported`/`Stop()`
  public-API baseline entries and the ui-abc provenance literals in
  `scripts/build-arkts-shell.sh`; `kit13 degradation` drives the bridge with no host library
  (SpeakAsync returns, Stop is a no-op, IsSupported is false, GetLocalesAsync keeps the
  device-locale fallback) without throwing. That is 3 lines: 334 + 3 = 337 = 324 interaction
  checks + 4 fuzz + 1 frame perf + 8 a11y perf; the workflow floor moves with the total
  (337 - 20 = 317).
- P2a-HUKS (SecureStorage HUKS-first, 2026-09-27): three `[verify]` lines upgrade the
  file-key fallback into a HUKS-first bridge. `kit14 host huks engine` pins
  `host_keystore.c` (the AES-256-GCM session shape: nonce 12 / tag 16, HUKS_TAG_NONCE +
  HUKS_TAG_AE_TAG, generate/encrypt/decrypt/delete ops, `/dev/urandom`, the
  wipe-on-free path), the `libhuks_ndk.z.so` resolution and `OH_Huks_*` symbols in
  `host_optional.c`, the `OH_Huks_` denylist entry (`host-deps.conf`), the new
  `ohos_host_keystore_available` export contract entry, the CMake/build-host source list
  and the HUKS-first order inside `ohos_host_keystore_request` (engine before the ArkTS
  listener). `kit14 managed bridge` pins the managed side: the availability P/Invoke, the
  delete op and `DeleteKeyAsync`/`IsAvailable`, the path-hashed
  `maui.ohos.securestorage.v1.` alias, the `k1:` prefix, the base64 `FormatException`
  guard, `IsHardwareBacked`, the `RemoveAll` key drop, the honest fallback note and the
  `PublicAPI` baseline entry. `kit14 degradation` runs off-device: `IsHardwareBacked=false`,
  the fallback read/write/remove keeps its semantics, a malformed `k1:` payload reads as
  absent and `RemoveAll` never throws. That is 3 lines: 337 + 3 = 340 = 327 interaction
  checks + 4 fuzz + 1 frame perf + 8 a11y perf; the workflow floor moves with the total
  (340 - 20 = 320).
- P0c-TEXT-EDIT (self-drawn text editing, 2026-09-27): seven `[verify]` lines pin the
  cursor/selection/handle/IME-composition semantics. `text cursor api` drives the Entry
  `CursorPosition`/`SelectionLength` mapper; `text caret blink` pins the 500 ms visible/hidden
  cadence (`OpenHarmonyView.CaretClock` test clock), the no-caret-while-unfocused rule and the
  focused-entry frame registration (`NeedsAnimation`); `selection handles` checks the two round
  handles are hit-testable at the measured selection ends and that dragging the end handle moves
  only that endpoint (start stays the anchor) while the virtual Entry stays in sync; `selection
  drag inertia` proves the release suppression gate at the physics level (same sample stream arms
  a fling, the suppressed one does not); `text composition` drives the preedit
  (`OpenHarmonyBridge.CompleteTextComposition("nihao", 1)`) and the commit (empty composition
  clears the preedit and advances the caret to offset + preedit length on platform and virtual
  view). `text composition shell` pins the shell's `PreviewText` bridge in all three packs
  (`onChange` second argument -> `host.notifyTextComposition`, `previewTextValue/Offset` helpers)
  and the caret-carrying text-input sink (`(show: number, caret: number)` ->
  `controller.caretPosition(caret)`); `text composition host` pins the C ABI/NAPI/export-contract
  and the managed bridge (`ohos_host_register_text_composition`,
  `ohos_host_keyboard_set_caret`, `TextComposition` event, `SetKeyboardCaret`). That is 7 lines:
  340 + 7 = 347 = 334 interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf; the workflow
  floor moves with the total (347 - 20 = 327).
- P1a-ANIM (animations and transitions, 2026-09-27): ten `[verify]` lines pin the frame-driven
  effects with an injected `OpenHarmonyAnimationLoop.Clock` so every pass is deterministic.
  `anim page enter push` / `anim page enter pop` push and pop a NavigationPage and check the
  entering page starts at opacity 0, is mid-ease after 40 ms (fading and sliding in the right
  direction) and commits back to its exact base opacity/translation with the loop unregistered;
  `anim page enter reduce-motion skips` proves a navigation under
  `OpenHarmonyMotion.ReduceMotion` commits instantly; `anim ticker driver` starts/stops the
  OpenHarmony ticker directly and checks exactly one redraw-only frame-loop entry appears, a
  pumped frame raises `RedrawRequests` and `SystemEnabled` follows the reduce-motion flag;
  `anim maui fade/translate/scale` drives the public `FadeToAsync`/`TranslateToAsync`/
  `ScaleToAsync` on an in-tree label, polls until the ticker's redraw driver is live mid-flight
  and checks the final `Opacity`/`TranslationX/Y`/`Scale` values exactly; `anim controls` checks
  the switch knob, check-mark draw-on and press channels interpolate and reach their targets
  (including the release back to 0); `anim controls reduce-motion snap` proves the channels snap
  under the setting; `anim shared morph` pushes a page whose `AutomationId="shared:hero"` element
  matches the outgoing page's, checks the incoming element is mid-morph (translation from the
  source frame, uniform scale from the width ratio) and restores exactly;
  `anim shared morph reduce-motion skips` covers the gated path; `anim transitions config`
  checks a zero duration disables the pass and the loop is idle afterwards. That is 10 lines:
  347 + 10 = 357 = 344 interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf; the workflow
  floor moves with the total (357 - 20 = 337). The pixel suite (`test/headless-render`) settles
  the press/check channels before sampling, so its button-pressed and check-line assertions see
  the completed state instead of a mid-ease frame.
- **P1b-LIST (16 lines)** - the list depth on the shared materializer and the scroll physics.
  `p1b threshold` raises `RemainingItemsThresholdReached` once on entering the threshold zone,
  stays silent while scrolling inside it and fires again after leaving/re-entering;
  `p1b updating` prepends five items under each `ItemsUpdatingScrollMode`: KeepItemsInView keeps
  the first visible item's screen position (by identity), KeepLastItemInView keeps the last item
  bottom-aligned, KeepScrollOffset keeps the raw offset while the viewport shows the prepended
  items; `p1b scrollto` pins Start/Center/End/MakeVisible against the template's measured slot
  and `makeVisible` as a no-op for an already-visible row; `p1b scrollto animated` steps the tween
  through the injected frame clock (active, mid-flight offset strictly inside the range, exact
  settle, loop idle) and the reduce-motion snap; `p1b group footer`/`collapse`/`expand`/`header
  tap` pin the group footer rows (18 = 3 x (1+4+1) rows), the collapse (13 rows, offset pulled up
  by the hidden height, the row below keeps its screen position, `ItemsSource` untouched), the
  expansion and the header-tap opt-in; `p1b physics rubberband`/`edge-return`/`fling bounce`/
  `fling reduce-motion` pin the bounded drag overscroll, the release spring, the fling's bounded
  excursion past the edge before settling exactly on it, and the reduced-motion clamps;
  `p1b scrollbar` pins the documented defaults, a settable hold/fade, the fade itself and the
  instant hide under reduced motion; `p1b longlist` scrolls a 1,200-item list, pins the
  content height against the measured slot, a bounded materialized window (max 22 rows), a
  steady-state scroll allocation ceiling (1024 B/step) and the one-off materialization envelope;
  `p1b pins` re-reads the handler/materializer/physics/animation/extension sources and the
  net-openharmony API baseline for the new surface. That is 16 lines: 357 + 16 = 373 = 360
  interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf; the workflow floor moves with the
  total (373 - 20 = 353).
- **P2c-DEEPLINK (10 lines)** - the want/activation routing. `p2c shell activation` re-reads
  both ability templates and the three preview packs: onCreate stores the want, onNewWant
  forwards it, the cold one is published through `host.notifyActivation` before startApp and the
  payload carries uri/action/parameters/linkHosts/sequence; `p2c host transport` pins the NAPI
  method, both C exports, the bounded pending queue and the export list; `p2c hosting api` pins
  the managed event/registration/payload parse; `p2c activation parse` drives the real payload
  through `CompleteActivation` (all fields parsed, malformed payload inert); `p2c activation
  thunk` enters the registered native thunk through the exact function pointer; the dispatch
  checks run against the harness's NavigationPage: `p2c link https` covers the malformed URI,
  the refused https host, the app.json seed and the accepted allow-listed link, `p2c link
  unknown route` the unresolved route, `p2c link dedup` the sequence de-duplication and
  stale-drop, `p2c cold start pending` a request held until a navigation target exists, and
  `p2c shell approval` the Shell.GoToAsync path with a canceled Navigating that is recorded and
  then approved. That is 10 lines: 377 + 10 = 387; the MS-MODE runtime-mode batch adds 4
  host/pack pins: 387 + 4 = 391 = 378 interaction checks + 4 fuzz + 1 frame
  perf + 8 a11y perf; the workflow floor moves with the total (391 - 20 = 371).
- **T1 InputView mapping + T2 WebView residual gaps (7 lines, 2026-09-28)** - the InputView
  mapper completion and the WebView gaps the W-series left. `i1 input view mapping pins` re-reads
  the three text handlers and `OpenHarmonyView.cs`: the Entry mapper carries MaxLength/IsReadOnly/
  Keyboard/IsPassword/ReturnType/ClearButtonVisibility/PlaceholderColor/HorizontalTextAlignment,
  the Editor and SearchBar mappers carry their subsets, and the platform view keeps the
  `ApplyKeyboardFilter`/`ClampToMaxLength` rules plus the clear-button geometry and the
  alignment-aware `TextOriginX`. `i2 input mapping drill` connects a real Entry (MaxLength 5,
  Keyboard.Numeric, IsPassword, ReturnType.Next, ClearButtonVisibility.WhileEditing,
  HorizontalTextAlignment.Center, PlaceholderColor Red), drives the private shell-input entry
  point (the same path `notifyTextInput` takes): the mapped state reaches the platform view, the
  numeric filter drops letters, MaxLength clamps "ab12cd34567" to "12345", IsReadOnly freezes the
  text and the drawn form is five bullets. `i3 input clear/alignment` hits the clear button
  (drawing and hit-test share its centre), clears both views through the real touch path and
  checks the Start < Center < End origin order plus the x->index round trip on the same metrics.
  `w6 shell webview gaps` pins the three new shell blocks in every preview pack (and their
  byte-identity): `onShowFileSelector` feeding the document picker into `handleFileList`,
  `onPermissionRequest` prompting for CAMERA/MICROPHONE through
  `abilityAccessCtrl.requestPermissionsFromUser` and granting exactly the granted subset,
  `multiWindowAccess(true)` with `onWindowNew` loading the popup target in the same component
  (single-window slice). `w7 webview media feature` pins the `webview-media` feature entries
  (CAMERA + MICROPHONE, user_grant, reason strings) and the reason resources in every pack.
  `w8 cookie container pins` pins the managed sync surface (the `IWebView.Cookies` mapper,
  `SyncContainerToPlatform`, `MergeCookieHeader`, `ScheduleCookieRead` on page finished).
  `w9 cookie container drill` maps a container cookie to the platform command, merges a
  shell-shaped "sid=1; theme=dark" header into the container and requires the unsafe/empty/
  control-carrying/missing-container shapes to stay inert. That is 7 lines: 398 + 7 = 405 =
  392 interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf; the workflow floor moves with
  the total (405 - 20 = 385).
- **T10 modal accessibility (7 lines, 2026-09-28)** - the self-drawn Alert/ActionSheet/Prompt
  overlays join the accessibility shadow tree and trap focus. The dialog root (title, or the
  message when there is no title), the message, the prompt text field and one button per
  accept/cancel label or action sheet row are appended after the view tree with shared dialog
  geometry (`TitleRect`/`MessageRect`/`PromptRect`), and the frame records the modal root id.
  While an alert is open every background node is republished non-focusable (the host's
  focus-move scans walk the published table by that bit), background accessibility actions are
  rejected, and the alert's own nodes accept a screen-reader CLICK through the same tap path a
  finger uses; closing it restores the background focusables. `alert a11y tree` asserts the
  dialog/message/OK+Cancel nodes, their parent chain, shared accept-button bounds and the
  content-update event; `alert a11y trap` counts the background focusable flip to zero (modal
  focusables stay positive) and requires the stale background CLICK to be rejected without a
  tap; `alert a11y click` completes the alert and checks the restore. The action sheet and
  prompt blocks do the same for the three option rows (Alpha/Beta/Cancel) and the prompt
  field's text update and OK click ("hi"). That is 7 lines: 409 + 7 = 416 = 403 interaction
  checks + 4 fuzz + 1 frame perf + 8 a11y perf; the workflow floor moves with the total
  (416 - 20 = 396).
- **T4 Label formatted text (4 lines, 2026-09-28)** - the Label mapper desugars
  `FormattedString`/`Span` into platform runs (span colour/size/attributes/decorations/
  background/character-spacing override the label-level style, the text transform inherits
  from the label) and the styled text view lays the runs out with the same wrapping/max-lines
  contract as plain text, drawing each run in its own style. `l1 label formatted pins` pins
  the mapper entry, the Text/FormattedText sync, the run model/layout and the run-aware draw
  path; `l2 label formatted drill` maps a three-span label and checks the resolved runs, the
  inherited label colour/line-height and the run-layout measure; `l3 label formatted
  switches` follows a span mutation, the Text -> plain and FormattedText -> formatted modes
  and the null reset; `l4 label formatted layout` measures the mixed-font text wide (one
  line) and narrow (wraps, the 40-px run raises the line height) and requires MaxLines=1 to
  tail-truncate with the ellipsis. That is 4 lines: 416 + 4 = 420 = 407 interaction checks +
  4 fuzz + 1 frame perf + 8 a11y perf; the workflow floor moves with the total (420 - 20 =
  400).
- **T9 window title bar (4 lines, 2026-09-28)** - `Window.TitleBar` (the window-level
  `Microsoft.Maui.Controls.TitleBar`, a logical child of the window rather than of the page) is
  measured/arranged/drawn by the compositor as a top row. The window handler builds the row on
  the `"TitleBar"` mapper key (the Controls property name travels through
  `Element.UpdateHandlerValue`); the renderer resolves it through the content's window, gives it
  the top `HeightRequest` pixels (else the 56-px chrome height), arranges the window content
  below it, and draws the TitleBar's template subtree (Title/Subtitle/Leading/Content/Trailing)
  with the row's solid background. Touches that land on the row route into the template's views
  (a Button set as `TitleBar.Content` clicks through the compositor), and the leading slot maps
  onto the window's back affordance: while the window's page tree can consume a back press
  (modal stack / NavigationPage stack / presented flyout / Shell stack, the slice's mirror of
  Controls' internal `Window.CanConsumeBackNavigation`) the row draws the shell chrome's chevron
  and a tap invokes `IWindow.BackButtonClicked` (the navigation page pops; a tap outside the slot
  does not), and clearing `Window.TitleBar` drops the row. `t9 row attach` pins the source
  contract (mapper entry, `OpenHarmonyTitleBarRow`, `BackButtonWidth`/`InBackButton`,
  `DrawBackAffordance`, `OpenHarmonyBackNavigation`) plus the mapping and the connected template
  handler; `t9 layout` pins the row frame (300x64 for HeightRequest 64), the template subtree
  arranged inside it, the content arranged below and the hidden-TitleBar fallback; `t9 touch`
  pins both a row button click and a page button click below it; `t9 back` pushes a second page,
  pops it through the back slot, keeps a tap outside the slot from popping and checks the cleared
  row. That is 4 lines: 420... the pre-T9 total plus 4 (424 + 4 = 428 = 415 interaction checks +
  4 fuzz + 1 frame perf + 8 a11y perf); the workflow floor moves with the total (428 - 20 = 408).
  The pixel suite pins the row's background across the width, the content shift, the leading
  chevron and the hidden-TitleBar fallback (7 new PASS checks in `test/headless-render`).

- **T11 diagnostics overlay (4 lines, 2026-09-28)** - the window's
  `Window.VisualDiagnosticsOverlay` (Controls' per-window `IAdorner` host) is initialized when the
  window handler attaches (`OpenHarmonyWindowHandler.MapContent`, the Tizen hook) and drawn by the
  overlay host next to `IWindow.Overlays`; Controls' `Invalidate` is a no-op on the platform-less
  build, so a frame-tick signature check (`SyncDiagnostics`, weak keys) requests the redraw when
  an adorner was added or removed. The window handler also answers
  `IWindow.RequestDisplayDensity` (1: the compositor draws in device pixels with one logical unit
  per pixel) because Controls' `Window.RequestDisplayDensity` throws "No result value was set."
  when the command is unmapped and the adorner path reads the overlay density through it.
  `t11 diagnostics overlay` requires the initialized+visible overlay after startup;
  `t11 diagnostics sync` requires the watcher to stay quiet while the adorner set is unchanged,
  to report a change (and raise `RedrawRequested`) when one adorner is added and to go steady
  again; `t11 diagnostics adorner` renders the window and requires the adorner's fill on the
  overlay canvas (one overlay draw pass); `t11 diagnostics skip` requires a deinitialized overlay
  to be skipped and the lifecycle initializer to rewire it. That is 4 lines: 428 + 4 = 432 = 419
  interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf; the workflow floor moves with the
  total (432 - 20 = 412).

- **T7 DatePicker calendar + Min/Max clamping (6 lines, 2026-09-29)** - the DatePicker popup draws
  the month calendar through the popup path (`DrawPopup` -> `DrawCalendar`: header with `<`/`>`
  month navigation, Monday-first weekday row, 6x7 day grid with today/selection highlighting) and
  `MinimumDate`/`MaximumDate` drive it: out-of-range days draw disabled and `CalendarHit` refuses
  them, the header clamps at the first/last in-range month, and a selected day is clamped to the
  range (the control's own coercion keeps the last word). `datepicker open`/`calendar next` pin the
  tap opening 2026-09 with the 17th selected and the header navigating to 2026-10; `after calendar
  tap` pins the picked day, the rendered popup and the closed state; `min/max hit` requires day 12
  to hit-test and day 25 (outside 2026-09-10..2026-09-20) not to; `min/max month clamp` keeps both
  header arrows in September; `outside tap` keeps the refused day from changing the date or
  closing the calendar; `select clamp` requires the platform selection callback to clamp a refused
  2026-09-25 to `MaximumDate`; `inside tap` selects 2026-09-12 and closes. That is 6 new lines:
  432 + 6 = 438 = 425 interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf; the workflow floor
  moves with the total (438 - 20 = 418).

- **T8 TableView (6 lines, 2026-09-29)** - the legacy TableView renders on the shared virtualized
  list pipeline and reads its rows through `ITableViewController.Model` (the platform contract
  Controls implements on TableView): a section title (or the model's header cell) becomes a
  section row and every cell is materialized through `OpenHarmonyCellFactory`, the same factory
  the ListView handler uses (ViewCell inner view, TextCell text/detail, SwitchCell two-way
  toggle, EntryCell, ImageCell thumbnail, plain View). `TableView.RowHeight` maps to the
  materializer's fixed row height (the row maths no longer key off the first/header row's
  measured height) and `HasUnevenRows`/`Cell.Height` are reported once as not modelled by the
  uniform pipeline. Cells keep their inherited binding context (no row-context overwrite) and are
  never pooled (a row carries its cell's content). `tableview sections` pins the section
  projection (header titles coloured by `TableSection.TextColor`, cell order, `RowHeight`
  content height, untitled section header omitted); `tableview cells` pins the shared cell
  materialisation (switch two-way binding, image source, TextCell detail, ViewCell inner view);
  `tableview tap` proves a section row is inert while a cell tap reaches `Cell.Tapped` through
  `ITableViewController.Model.RowSelected` on the real touch walk; `tableview updates` adds a
  section, removes a cell and scrolls a tail row into the window through `ModelChanged`;
  `tableview model` drives a custom `TableModel` (section titles, header cell, `OnRowSelected`);
  `tableview pins` parses the handler/factory/materializer/registration/public-api contract.
  That is 6 new lines on top of the N2 empty-ContentPage line (439): 439 + 6 = 445 = 432
  interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf; the workflow floor moves with the
  total (445 - 20 = 425).

- **T6 RTL/FlowDirection (7 lines, 2026-09-29)** - upstream MAUI leaves RTL layout mirroring to
  the platform (dotnet/maui#9558), so the compositor mirrors the canvas placement of every child
  of a right-to-left layout: each walk carries an `OpenHarmonyFlowMap` (`x' = Scale * x +
  Offset`), a RightToLeft view is a mirror boundary that reflects its children's logical offsets
  within its physical frame, `MatchParent` inherits, and an LTR tree maps to itself. The MAUI
  frames stay logical for arrange-time readers; `OpenHarmonyView.CanvasFrame` is the mapped
  rectangle drawing and hit-testing use. `t6 layout mirror` requires the three children of an RTL
  `HorizontalStackLayout` at physical 200/100/0 while the logical frames stay 0/100/200 and the
  MatchParent children resolve RTL; `t6 hit mirror` taps the physical right/left halves and
  requires the first/second (logical) buttons to click exactly once each; `t6 text` requires an
  RTL entry's Start origin at the right edge and End at the left with the clear button on the
  physical left; `t6 nav chrome` requires the back region at the right strip and the toolbar dock
  at the left (hit-testing both sides); `t6 flyout menu` opens the shell drawer from the
  hamburger at the physical right, hit-tests row 0 at the right and the dismiss region left of
  the panel, and selects the second item; `t6 picker popup` requires the dropdown to open from
  the field's right edge and grow left with row hits and selection; `t6 calendar` requires the
  previous-month arrow at the right header and next at the left, the mirrored day columns
  (day 15) and the picked date. That is 7 new lines on top of the N2 (+1) and T8 (+6) lines:
  445 + 7 = 452 = 439 interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf; the workflow
  floor moves with the total (452 - 20 = 432).

- **T22 MainThread bridge (5 lines, 2026-09-29)** - rc.1's Essentials initialization bridges the
  MAUI application dispatcher into the netstandard `MainThread` on non-native TFMs
  (`EssentialsMauiAppBuilderExtensions` -> `MainThread.SetCustomImplementation`, no public API
  and no platform partial), so `MainThread.IsMainThread` mirrors the app dispatcher's
  `IsDispatchRequired` and `BeginInvokeOnMainThread` / `InvokeOnMainThreadAsync` post through the
  slice's `OpenHarmonyDispatcher` queue. `t22 mainthread bridge` requires the app dispatcher to
  be the slice's `OpenHarmonyDispatcher` and `MainThread.IsMainThread` to equal
  `!dispatcher.IsDispatchRequired` on the suite thread; `t22 begin-invoke` posts from a fresh
  worker thread (where `IsDispatchRequired` is deterministically true) and requires the callback
  to queue rather than run inline on the worker and to observe `IsMainThread` true when the
  safety-net timer drains it; `t22 invoke-async func` requires the `Func<T>` overload to
  round-trip its value from a fresh worker thread; `t22 invoke-async action` requires the
  `Action` overload to complete successfully with exactly one callback; `t22 begin-invoke shares
  the app dispatcher queue` interleaves a `MainThread` post and a direct `IDispatcher.Dispatch`
  post and requires FIFO order (1 then 2), pinning that the bridge posts into the application
  dispatcher's own queue. That is 5 new lines on top of the N2 (+1), T8 (+6) and T6 (+7) lines:
  452 + 5 = 457 = 444 interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf; the workflow
  floor moves with the total (457 - 20 = 437).

- **FIX-TABBED TabbedPage CurrentPage (2 lines, 2026-09-29)** - the device verification report
  (conclusion 2 / finding 5.3-3: a TabbedPage app drew the tab bar but a black body) traced the
  root cause to the compositor's `ChildEnumerator`, which enumerated layout children, the
  content-view's presented content, the navigation page's current page and the flyout
  detail/panel but not `TabbedPage.CurrentPage`. The enumerator now yields the selected tab's page
  exactly like `NavigationPage.CurrentPage` (same presented-content reference guard; rc.1's
  TabbedPage is not an `IContentView`, so the current page is the walk's only source). `tabbed
  draw current` renders a two-page TabbedPage through a text-recording canvas and requires the
  selected page's label in the frame with the unselected page's label absent (before the fix the
  frame carried neither); `tabbed draw after switch` taps the second tab and requires the frame
  to follow the switch (the new label drawn, the previous label gone). That is 2 new lines on top
  of the T22 line: 457 + 2 = 459 = 446 interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf;
  the workflow floor moves with the total (459 - 20 = 439).

- **T13 CollectionView GroupFooter view template + N3 Picker/DatePicker/TimePicker IsOpen
  (4 lines, 2026-09-29)** - a `GroupFooterTemplate` that materialises a full `View` (not just a
  `Label`) becomes the footer row itself: the handler realises the template per group, binds it
  to the group object and connects its handler tree, so nested views and bindings render (Label
  templates keep the existing text path and the one-time status for non-View content is
  updated). `p1b group footer view` renders two groups with a Grid footer (a Label bound to the
  group `Name` plus an accent BoxView), requiring the footer Grid rows after each group's items
  (10 = 2*(1 header + 3 items + 1 footer) slots), both Grids bound to their group object and the
  bound Label texts `g1`/`g2`. `IsOpen` maps both ways on all three pickers: `picker isopen`
  opens/closes programmatically, opens by a field tap and dismisses through the renderer's
  outside-tap `PopupClosed` path, requiring `Opened`/`Closed` exactly twice; `datepicker isopen`
  opens on the picker's date month, closes programmatically and closes on a day selection;
  `timepicker isopen` rebuilds the 48 half-hour slots on a programmatic open and closes on a slot
  selection. That is 4 new lines on top of the T22 and FIX-TABBED lines: 459 + 4 = 463 =
  450 interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf; the workflow floor moves
  with the total (463 - 20 = 443).
- **T21 system font scale (5 lines, 2026-09-29)** - OpenHarmony reports the user's font size
  setting as a scale factor; the slice now applies it at the one boundary every text path shares,
  `OpenHarmonyFontManager` (public `SetSystemFontScale(float)` / `SystemFontScale`, non-finite or
  non-positive resets to 1, clamped to 0.5..3, with the two `PublicAPI.Unshipped.txt` entries).
  MAUI font values stay logical (a Label keeps `FontSize` 20) while `ScaleFontSize` multiplies at
  the measurement and drawing boundary: the plain and `FormattedText` run drawing scale
  `canvas.FontSize` (bold offset and decoration metrics included), the entry/editor/searchbar
  text, placeholder, IME composition and per-character caret metrics scale, and the self-drawn
  chrome (picker values/dropdown rows, calendar labels, tab captions, title/navigation bars,
  stepper, swipe panel, flyout rows, alerts, tooltips) scales its fixed sizes; a scale of 1 is
  identity, so existing output is unchanged. Text-measure caches carry the scale generation
  (label measurement key, view line-break/formatted/natural-height/char-width caches), so a
  scale change can never serve stale metrics. `t21 font scale api` pins the defaults, the reset
  and both clamps plus the public-API baseline; `t21 label scale` requires the desired size to
  double at scale 2, the original metrics to return at scale 1 and the logical `FontSize` to
  stay 20; `t21 formatted scale` requires the run-aware layout to scale; `t21 entry scale`
  requires the caret x to double (minus the fixed origin) and the caret hit at one x to move
  from index 2 to 1; `t21 draw scale` renders through a recording canvas (`CanvasFactory`) and
  requires the glyph draw at 18 then 36. The pixel suite adds three checks: the label's frame
  grows (40.5 -> 81), the marker pixel count grows (360 -> 1680), and the marker draws lower and
  wider (rightmost 145 -> 265). That is 5 new lines on top of the T22 (+5) line:
  463 + 5 = 468 = 455 interaction checks + 4 fuzz + 1 frame perf + 8 a11y perf; the workflow
  floor moves with the total (468 - 20 = 448).
