# Interaction regression suite (headless)

The 158-check MAUI-on-OpenHarmony interaction harness. It builds the platform slice sources from the
`maui-ohos` working tree and drives the app host without a device: touch/drag/pinch/pointer input,
overlays, gestures (tap/pan/swipe/pinch/pointer/drag-and-drop), sensors/haptics/notification/picker
wiring, the app-theme colour-mode handler, the launcher/browser/share ability bridge, the
accessibility shadow tree snapshot, the menu table/activation bridge and the WebView JavaScript
bridge (script evaluation + `dotnetHost.postMessage`).

## Running it

```bash
# The project references the maui-ohos slice and the hosting assembly. Override the defaults with
# the MAUI_SLICE_DIR / HOSTING_DLL env vars (or the MauiSliceDir / HostingDll MSBuild properties)
# before building elsewhere.
dotnet build -v:q
dotnet bin/Debug/net11.0/verify.dll | grep -c '\[verify\]'   # expect 158
```

## Notes

- Output goes to `bin/Debug/net11.0/verify.dll` (run the dll, not the apphost: the device policy
  blocks codesigned ELF apphosts on some machines).
- The suite fails loudly (unhandled exception) when a slice change breaks startup or when an
  assertion for the gesture flows (including the drag-and-drop checks) does not hold; keep it at
  158 checks when touching the platform slice.
- JavaScript bridge coverage: `WebView.EvaluateJavaScriptAsync` completes with null/empty and
  never throws off-device (no host library), the native `notifyJsMessage` callback raises
  `OpenHarmonyWebViewHandler.JsMessage` with the `dotnetHost.postMessage` payload, and the
  HybridWebView handler is registered in `SliceHandlers`, completes
  `HybridWebView.EvaluateJavaScriptAsync`/`InvokeJavaScriptAsync` without hanging, degrades
  `SendRawMessage` and routes `__RawMessage|...`/plain payloads into `RawMessageReceived`.
  Hybrid asset serving (`HybridRoot`/`DefaultFile`) is not part of this batch; see the slice's
  `OpenHarmonyHybridWebViewHandler` header.
- Haptics coverage: `HapticFeedback.Default` is the slice implementation, `Perform(Click/LongPress)`
  degrades without throwing off-device, and `IsSupported` is false without the host library. The app
  theme handler is exercised directly (ArkUI colour-mode reports need a device): setting dark/light
  updates `UserAppTheme`/`RequestedTheme` and the previous value is restored afterwards.
- Drag-and-drop coverage: a long press (500 ms) followed by a move past the 8 px slop raises
  DragStarting, DragOver/DragLeave fire when the pointer enters/leaves a drop-aware view, Drop
  delivers the source text through DataPackageView.GetTextAsync(), and a release over nothing raises
  DropCompleted with DropResult=None (the internal result is read reflectively).
- Rotation-vector coverage: the orientation sensor is wired to `SENSOR_TYPE_ROTATION_VECTOR` (259)
  and the host listener forwards four components. The assertion invokes the managed callback through
  the six-parameter `SensorCallback` delegate (pinning the native signature) and checks that
  `(x, y, z, w)` reaches `OrientationSensorData.Orientation` unchanged, with no reconstructed
  scalar part.
- CI wiring (building the slice in a runner) is tracked in the handover status document; this copy
  preserves the suite in the repository so it can be made portable.
