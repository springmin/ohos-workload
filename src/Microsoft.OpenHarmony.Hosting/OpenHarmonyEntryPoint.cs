// Managed bootstrap invoked by the native OpenHarmony host (libopenharmonyhost.so)
// through hostfxr's load_assembly_and_get_function_pointer.
using System;
using System.Diagnostics.CodeAnalysis;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Loader;

namespace Microsoft.OpenHarmony.Hosting;

public static class OpenHarmonyEntryPoint
{
    /// <summary>
    /// Exit code the JIT-only entry point returns when it is reached under NativeAOT: the host
    /// launched a hostfxr-shaped payload on a runtime without dynamic code support, which cannot
    /// load the application assembly by reflection.
    /// </summary>
    public const int AotRuntimeRequiresAppEntry = 4;

    /// <summary>
    /// True when the runtime can compile code at run time (the CoreCLR/JIT route this assembly's
    /// entry point serves). NativeAOT route (FIX-INTEROP #2): the host never calls this export;
    /// the application ships as a native library whose own
    /// [UnmanagedCallersOnly(EntryPoint = "openharmony_app_main")] method is the launch surface,
    /// and libopenharmonyhost.so dlopens it directly (OhosHostTryRunAotApp in
    /// openharmony_host.c); hostfxr stays the JIT-only route.
    ///
    /// The FeatureGuard pair is the BCL's own pattern for a JIT-only path
    /// (System.Data.DataSet.XmlSerializationIsSupported): the trimmer substitutes a
    /// FeatureGuard(RequiresUnreferencedCode) property to false when trimming, and NativeAOT
    /// folds RuntimeFeature.IsDynamicCodeSupported to false, so both drop the reflection-based
    /// branch while the analyzer keeps the assembly IsAotCompatible. The IL4000 pragma is part
    /// of that pattern: the default is read from a runtime feature instead of a literal, which
    /// the analyzer cannot express without this narrow, justified suppression.
    /// </summary>
    [FeatureSwitchDefinition("Microsoft.OpenHarmony.Hosting.IsReflectionLoadSupported")]
    [FeatureGuard(typeof(RequiresUnreferencedCodeAttribute))]
    [FeatureGuard(typeof(RequiresDynamicCodeAttribute))]
#pragma warning disable IL4000 // see the pattern note above (BCL: DataSet.XmlSerializationIsSupported)
    public static bool IsReflectionLoadSupported =>
        AppContext.TryGetSwitch("Microsoft.OpenHarmony.Hosting.IsReflectionLoadSupported", out bool enabled)
            ? enabled
            : RuntimeFeature.IsDynamicCodeSupported;
#pragma warning restore IL4000

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

        if (!IsReflectionLoadSupported)
        {
            // AOT: AssemblyLoadContext.LoadFromAssemblyPath + MethodInfo.Invoke cannot run, and
            // the host must not route an AOT payload through hostfxr. Report why instead of
            // failing later with a metadata/reflection error.
            OpenHarmonyBridge.WriteStatus(
                "openharmony_app_main reached under NativeAOT: hostfxr is the JIT-only route; " +
                "the native host must call the application's own [UnmanagedCallersOnly] " +
                "openharmony_app_main export directly (see docs/aot-single-entry.md)");
            return AotRuntimeRequiresAppEntry;
        }

        return RunAssemblyEntryPoint(appPath, appArgs);
    }

    /// <summary>
    /// JIT route: loads the application assembly next to the payload and invokes its entry
    /// point. Trim/AOT analysis cannot see through the dynamic load, so the method carries the
    /// RequiresUnreferencedCode/RequiresDynamicCode contracts; <see cref="Main"/> calls it only
    /// behind <see cref="IsReflectionLoadSupported"/>.
    /// </summary>
    [RequiresUnreferencedCode("Loads the application assembly and invokes its entry point by reflection; the host guarantees the payload exposes them (JIT route).")]
    [RequiresDynamicCode("AssemblyLoadContext.LoadFromAssemblyPath and MethodInfo.Invoke need runtime code generation.")]
    private static int RunAssemblyEntryPoint(string appPath, string[] appArgs)
    {
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
