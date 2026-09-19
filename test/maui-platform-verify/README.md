# Interaction regression suite (headless)

The 126-check MAUI-on-OpenHarmony interaction harness. It builds the platform slice sources from the
`maui-ohos` working tree and drives the app host without a device: touch/drag/pinch/pointer input,
overlays, gestures, sensors/notification/picker wiring and the accessibility shadow tree snapshot.

## Running it

```bash
# The project references absolute paths to the maui-ohos slice and the hosting assembly; adjust
# HintPath entries (or set the env vars used by your checkout) before building elsewhere.
dotnet build -v:q
dotnet bin/Debug/net11.0/verify.dll | grep -c '\[verify\]'   # expect 126
```

## Notes

- Output goes to `bin/Debug/net11.0/verify.dll` (run the dll, not the apphost: the device policy
  blocks codesigned ELF apphosts on some machines).
- The suite fails loudly (unhandled exception) when a slice change breaks startup; keep it at
  126 checks when touching the platform slice.
- CI wiring (building the slice in a runner) is tracked in the handover status document; this copy
  preserves the suite in the repository so it can be made portable.
