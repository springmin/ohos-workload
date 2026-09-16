// Managed bootstrap invoked by the native OpenHarmony host (libopenharmonyhost.so)
// through hostfxr's load_assembly_and_get_function_pointer.
using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.Loader;

namespace Microsoft.OpenHarmony.Hosting;

public static class OpenHarmonyEntryPoint
{
    /// <summary>
    /// Entry point exported to the native host.
    /// <paramref name="payload"/> is a NUL-terminated UTF-8 string:
    /// first line = path to the application assembly, remaining lines = app arguments.
    /// </summary>
    [UnmanagedCallersOnly(EntryPoint = "openharmony_app_main")]
    public static int Main(IntPtr payload)
    {
        string text = Marshal.PtrToStringUTF8(payload) ?? string.Empty;
        string[] parts = text.Split('\n');
        if (parts.Length == 0 || string.IsNullOrEmpty(parts[0]))
        {
            return 2;
        }

        string appPath = parts[0];
        string[] appArgs = parts.Length > 1 ? parts[1..] : Array.Empty<string>();
        string appDir = Path.GetDirectoryName(appPath) ?? ".";

        var alc = new AssemblyLoadContext("openharmony-app");
        alc.Resolving += (context, name) =>
        {
            string candidate = Path.Combine(appDir, name.Name + ".dll");
            return File.Exists(candidate) ? context.LoadFromAssemblyPath(candidate) : null;
        };

        Assembly app = alc.LoadFromAssemblyPath(appPath);
        MethodInfo? entryPoint = app.EntryPoint;
        if (entryPoint is null)
        {
            return 3;
        }

        object?[]? args = entryPoint.GetParameters().Length == 0 ? null : new object?[] { appArgs };
        object? result = entryPoint.Invoke(null, args);
        return result is int code ? code : 0;
    }
}
