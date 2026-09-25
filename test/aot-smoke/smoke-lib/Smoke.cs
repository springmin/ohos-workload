// Minimal NativeAOT single-entry app for the OpenHarmony host (docs/aot-single-entry.md).
// The export is the only launch surface the host uses; Main is the app's own entry.
using System.Runtime.InteropServices;

internal static class Program
{
    [UnmanagedCallersOnly(EntryPoint = "openharmony_app_main")]
    public static int AotEntry(IntPtr payload)
    {
        string text = Marshal.PtrToStringUTF8(payload) ?? string.Empty;
        string[] lines = text.Split('\n');
        string[] args = lines.Length > 1 ? lines[1..] : Array.Empty<string>();
        return Main(args);
    }

    private static int Main(string[] args)
    {
        Console.WriteLine($"openharmony AOT smoke: {args.Length} argument(s): {string.Join(' ', args)}");
        // On device there is no console for a one-shot app; record the arguments so the
        // harness can assert the payload contract.
        string? output = Environment.GetEnvironmentVariable("OHOS_AOT_SMOKE_OUT");
        if (!string.IsNullOrEmpty(output))
        {
            File.WriteAllText(output, string.Join('\n', args));
        }
        return args.Length == 2 ? 0 : 1;
    }
}
