// NativeAOT launch surface: identical contract to test/hello-maui-app/AotEntry.cs.
#if OPENHARMONY_AOT
using System;
using System.Runtime.InteropServices;

namespace CompatApp;

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
