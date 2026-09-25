# NativeAOT single-entry launch (FIX-INTEROP #2)

The native host (`libopenharmonyhost.so`) supports two payload shapes behind the same
`ohos_host_run_app(app_dir, app_assembly_file, argc, argv)` call:

| Payload | Launch route | Discovery |
| --- | --- | --- |
| JIT (managed `MyApp.dll` + `hostfxr` + runtime natives) | `hostfxr_main_startupinfo` / `load_assembly_and_get_function_pointer` | no `libMyApp.so` next to the assembly |
| NativeAOT (`libMyApp.so`, `NativeLib=Shared`) | `dlopen` + `dlsym("openharmony_app_main")` | `<app_dir>/lib<assembly stem>.so` exists and exports the entry |

This removes the previous single point of failure: a NativeAOT payload has no hostfxr and no
managed assembly to load by reflection, so `Microsoft.OpenHarmony.Hosting.OpenHarmonyEntryPoint`
(which uses `AssemblyLoadContext.LoadFromAssemblyPath` + `MethodInfo.Invoke`) cannot start it.
`OpenHarmonyEntryPoint.Main` is now explicitly JIT-only: when it is reached under
`!RuntimeFeature.IsDynamicCodeSupported` it returns code `4` and writes a status line instead
of failing later with a metadata error.

## The application contract (NativeAOT)

The application (its own assembly, not the hosting assembly) exports:

```csharp
[UnmanagedCallersOnly(EntryPoint = "openharmony_app_main")]
public static int AotEntry(IntPtr payload)
{
    // payload: NUL-terminated UTF-8, line 1 = path to the application assembly
    //          (diagnostic only in AOT), following lines = application arguments.
    string text = Marshal.PtrToStringUTF8(payload) ?? string.Empty;
    string[] lines = text.Split('\n');
    string[] args = lines.Length > 1 ? lines[1..] : Array.Empty<string>();
    return Main(args); // the app's real entry
}
```

The host calls this on the shell's launch thread (one-shot `run_app`). The payload encoding is
identical to the JIT route, so the shell keeps passing `MyApp.dll` as the assembly file name and
the host derives `libMyApp.so` from it. `openharmony-arm64` is the RuntimeIdentifier; publishing
a MAUI app as a shared library also produces the platform slice archive handled by the app
packaging targets.

Bridged mode (`ohos_host_start_app`) stays JIT-only for now: the bridge needs the hosting
assembly's `register_bridge` handshake and handle management, which the AOT app would have to
reimplement. `start_app` detects a NativeAOT payload (`lib<stem>.so` present) and fails with an
explicit message instead of a generic hostfxr error; wiring the bridged AOT route is a follow-up.

## Publishing (host-side cross compile)

```sh
dotnet publish MyApp.csproj -r openharmony-arm64 -c Release \
    -p:PublishAot=true -p:NativeLib=Shared \
    -p:LinkerFlavor=lld -p:SysRoot=$OHOS_NDK_HOME/native/sysroot \
    -p:CppCompilerAndLinker=$OHOS_NDK_HOME/native/llvm/bin/clang++
```

The ilc/runtime pack for `openharmony-arm64` must be available (see the runtime strategy doc:
`runtime-ohos/docs/plans/2026-09-24-ohos-runtime-strategy.md` §3). When it is not installed,
`test/aot-smoke/run-smoke.sh` reports `SKIP` instead of failing.

## Verification without the ilc pack

`test/aot-smoke/` ships two layers:

* `fake-aot-app.c` builds a hand-written stand-in library (`libFakeApp.so`) that exports
  `openharmony_app_main` and records the payload it receives. Running the existing
  `src/OpenHarmonyHost/test_host.c` driver against it exercises the whole host route
  (`OhosHostTryRunAotApp` + payload encoding) on a device/emulator with the OpenHarmony NDK,
  with no .NET AOT toolchain involved:
  `test_host <dir> FakeApp.dll a b` must log `run_app: NativeAOT payload .../libFakeApp.so`
  and the recorded payload must be `.../FakeApp.dll\na\nb`.
* `run-smoke.sh` attempts the real `dotnet publish -r openharmony-arm64 -p:PublishAot=true`
  of `smoke-lib/` (the same `[UnmanagedCallersOnly]` shape) and falls back to a documented
  SKIP when the AOT packs are missing.

## Regression risk

* A JIT payload keeps the previous route: the AOT probe only opens
  `<app_dir>/lib<stem>.so`, and a library that does not export `openharmony_app_main` logs a
  warning and falls through to hostfxr (never blocks a JIT launch).
* The AOT library is deliberately not `dlclose`d: the runtime may own process-lifetime state and
  `run_app` is a one-shot launch.
* `scripts/check-host-exports.py` + `build-host.sh` keep the export surface of the host itself
  covered; the AOT probe uses `dlsym` on the *application* library, not on the host.
