// Device diagnostics for the B2 demo. This image does not route an app process's managed
// stderr to hilog and OpenHarmonyBridge.Context can still be empty during NativeAOT startup,
// so the shell's bounded poll of <filesDir>/dotnet-status.txt is the readable channel; the
// filesDir is taken straight from OHOS_HOST_APP_CONTEXT to be independent of the bridge.
using System;
using System.IO;

namespace HelloMauiWasm;

internal static class StatusBreadcrumb
{
    public static void Write(string message)
    {
        try
        {
            string context = Environment.GetEnvironmentVariable("OHOS_HOST_APP_CONTEXT") ?? string.Empty;
            const string key = "\"filesDir\":\"";
            int start = context.IndexOf(key, StringComparison.Ordinal);
            if (start < 0)
            {
                return;
            }
            start += key.Length;
            int end = context.IndexOf('"', start);
            if (end <= start)
            {
                return;
            }
            string directory = context.Substring(start, end - start);
            File.AppendAllText(Path.Combine(directory, "dotnet-status.txt"), "[hello-maui-wasm] " + message + "\n");
        }
        catch
        {
            // Diagnostics only; never disturb the app.
        }
    }
}
