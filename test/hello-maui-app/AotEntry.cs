// NativeAOT launch surface (OPENHARMONY_AOT): the native host (libopenharmonyhost.so) dlopens
// <app_dir>/lib<assembly stem>.so and calls this export directly - there is no hostfxr and no
// managed assembly to load by reflection on the AOT route (docs/aot-single-entry.md).
//
// The payload contract is shared with the JIT route's OpenHarmonyEntryPoint.Main: NUL-terminated
// UTF-8, first line = path to the application assembly (diagnostic only here), remaining lines =
// application arguments. The startup body is the same Program.Run the JIT Main calls.
#if OPENHARMONY_AOT
using System;
using System.Runtime.InteropServices;

namespace HelloMauiApp;

public static class AotEntryPoint
{
    [UnmanagedCallersOnly(EntryPoint = "openharmony_app_main")]
    public static int Main(IntPtr payload)
    {
        string text = Marshal.PtrToStringUTF8(payload) ?? string.Empty;
        string[] lines = text.Split('\n');
        string[] args = lines.Length > 1 ? lines[1..] : Array.Empty<string>();
        return Program.Run(args);
    }
}
#endif
