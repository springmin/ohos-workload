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

namespace HelloMauiWasm;

public static class AotEntryPoint
{
    [UnmanagedCallersOnly(EntryPoint = "openharmony_app_main")]
    public static int Main(IntPtr payload)
    {
        string text = Marshal.PtrToStringUTF8(payload) ?? string.Empty;
        string[] lines = text.Split('\n');
        string[] args = lines.Length > 1 ? lines[1..] : Array.Empty<string>();
        // Entry breadcrumb written straight to the shell-readable status file, bypassing
        // OpenHarmonyBridge.Context (which may still be empty this early on the AOT route):
        // the shell polls <filesDir>/dotnet-status.txt, so this proves whether the NativeAOT
        // trampoline reached the managed entry at all.
        StatusBreadcrumb.Write($"entry reached (lines={lines.Length})");
        int rc = Program.Run(args);
        StatusBreadcrumb.Write($"entry returning rc={rc}");
        return rc;
    }
}
#endif
