// Managed surface for the OpenHarmony host bridge. The host (libopenharmonyhost.so)
// starts the application; this assembly registers callbacks back into the host and
// exposes host paths + lifecycle events to the application.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Microsoft.OpenHarmony.Hosting;

public enum OpenHarmonySurfaceState
{
    Created = 0,
    Changed = 1,
    Destroyed = 2,
}

/// <summary>ArkUI XComponent surface handed to managed code.</summary>
public sealed class OpenHarmonySurfaceInfo
{
    public OpenHarmonySurfaceInfo(IntPtr window, int width, int height, OpenHarmonySurfaceState state)
    {
        Window = window;
        Width = width;
        Height = height;
        State = state;
    }

    /// <summary>OHNativeWindow* (native pointer) to render into.</summary>
    public IntPtr Window { get; }
    public int Width { get; }
    public int Height { get; }
    public OpenHarmonySurfaceState State { get; }
}

public enum OpenHarmonyLifecycleEvent
{
    Create = 0,
    Destroy = 1,
    Foreground = 2,
    Background = 3,
}

public sealed class OpenHarmonyAppContext
{
    public string AppDir { get; init; } = string.Empty;
    public string FilesDir { get; init; } = string.Empty;
    public string CacheDir { get; init; } = string.Empty;
    public string BundleName { get; init; } = string.Empty;
    public string AbilityName { get; init; } = string.Empty;
    public long NodeContent { get; init; }
}

/// <summary>Bridge between the native OpenHarmony shell and the managed application.</summary>
public static class OpenHarmonyBridge
{
    private const string HostLibrary = "libopenharmonyhost.so";

    [DllImport(HostLibrary, EntryPoint = "ohos_host_get_app_context")]
    private static extern IntPtr GetAppContextNative();

    [DllImport(HostLibrary, EntryPoint = "ohos_host_register_bridge")]
    private static extern void RegisterBridgeNative(IntPtr lifecycle, IntPtr node, IntPtr surface);

    private delegate void NativeLifecycleDelegate(int evt);
    private delegate void NativeNodeDelegate(IntPtr node);
    private delegate void NativeSurfaceDelegate(IntPtr window, int width, int height, int state);

    private static readonly object s_sync = new();
    private static OpenHarmonyAppContext? s_context;
    private static IntPtr s_nodeContent;
    private static bool s_attached;
    private static NativeLifecycleDelegate? s_lifecycleThunk;
    private static NativeNodeDelegate? s_nodeThunk;
    private static NativeSurfaceDelegate? s_surfaceThunk;
    private static readonly List<OpenHarmonyLifecycleEvent> s_pending = new();
    private static Action<OpenHarmonySurfaceInfo>? s_surfaceHandlers;
    private static OpenHarmonySurfaceInfo? s_surface;
    private static Action<OpenHarmonyAppContext>? s_initializedHandlers;
    private static Action<OpenHarmonyLifecycleEvent>? s_lifecycleHandlers;

    /// <summary>Raised (also for late subscribers) once the host context is available.</summary>
    public static event Action<OpenHarmonyAppContext>? Initialized
    {
        add
        {
            OpenHarmonyAppContext? context;
            lock (s_sync)
            {
                s_initializedHandlers += value;
                context = s_context;
            }
            if (context is not null)
            {
                value(context);
            }
        }
        remove
        {
            lock (s_sync)
            {
                s_initializedHandlers -= value;
            }
        }
    }

    /// <summary>Raised when the ArkUI XComponent surface is created/changed/destroyed.
    /// <c>Window</c> is the OHNativeWindow* the renderer (e.g. Skia) should target.</summary>
    public static event Action<OpenHarmonySurfaceInfo>? SurfaceChanged

    {
        add
        {
            List<OpenHarmonySurfaceInfo> replay;
            lock (s_sync)
            {
                s_surfaceHandlers += value;
                replay = s_surface is null ? new List<OpenHarmonySurfaceInfo>() : new List<OpenHarmonySurfaceInfo> { s_surface };
            }
            foreach (OpenHarmonySurfaceInfo info in replay)
            {
                value(info);
            }
        }
        remove
        {
            lock (s_sync)
            {
                s_surfaceHandlers -= value;
            }
        }
    }

    /// <summary>Last reported surface (null until the XComponent reports one).</summary>
    public static OpenHarmonySurfaceInfo? Surface
    {
        get { lock (s_sync) { return s_surface; } }
    }

    public static event Action<OpenHarmonyLifecycleEvent>? LifecycleChanged
    {
        add
        {
            List<OpenHarmonyLifecycleEvent> replay;
            lock (s_sync)
            {
                s_lifecycleHandlers += value;
                replay = new List<OpenHarmonyLifecycleEvent>(s_pending);
                s_pending.Clear();
            }
            foreach (OpenHarmonyLifecycleEvent e in replay)
            {
                value(e);
            }
        }
        remove
        {
            lock (s_sync)
            {
                s_lifecycleHandlers -= value;
            }
        }
    }

    public static OpenHarmonyAppContext? Context
    {
        get { lock (s_sync) { return s_context; } }
    }

    /// <summary>Native ArkUI NodeContent handle handed over by the shell (0 if none).</summary>
    public static IntPtr NodeContent
    {
        get { lock (s_sync) { return s_nodeContent; } }
    }

    /// <summary>File the application can append status lines to (inside the app sandbox).</summary>
    public static string StatusFilePath
    {
        get
        {
            OpenHarmonyAppContext? context = Context;
            return context is null || string.IsNullOrEmpty(context.FilesDir)
                ? string.Empty
                : Path.Combine(context.FilesDir, "dotnet-status.txt");
        }
    }

    public static void WriteStatus(string message)
    {
        string path = StatusFilePath;
        if (string.IsNullOrEmpty(path))
        {
            return;
        }
        try
        {
            // Deliberately no timestamps: DateTime.Now pulls in TimeZoneInfo/globalization
            // initialization, which is not available in every app sandbox yet.
            File.AppendAllText(path, message + "\n");
        }
        catch
        {
            // Diagnostics must never take the application down.
        }
    }

    /// <summary>
    /// Reads the host context and registers the managed callbacks. Called
    /// automatically through a module initializer; calling it again is a no-op.
    /// Safe to call outside a hap (the DllImport simply fails and is ignored).
    /// </summary>
    public static void Attach()
    {
        lock (s_sync)
        {
            if (s_attached)
            {
                return;
            }
            s_attached = true;
        }

        // The host publishes the context through the environment before starting the
        // runtime, so the bridge does not depend on the native call below.
        string json = Environment.GetEnvironmentVariable("OHOS_HOST_APP_CONTEXT") ?? "{}";
        if (json == "{}")
        {
            try
            {
                IntPtr raw = GetAppContextNative();
                if (raw != IntPtr.Zero)
                {
                    json = Marshal.PtrToStringUTF8(raw) ?? "{}";
                }
            }
            catch
            {
                // No native host (plain one-shot hosting): keep the defaults.
            }
        }

        ContextJson? parsed = null;
        try
        {
            parsed = JsonSerializer.Deserialize<ContextJson>(json);
        }
        catch
        {
            // Keep defaults; the status file then falls back to no-op.
        }

        var context = new OpenHarmonyAppContext
        {
            AppDir = parsed?.AppDir ?? string.Empty,
            FilesDir = parsed?.FilesDir ?? string.Empty,
            CacheDir = parsed?.CacheDir ?? string.Empty,
            BundleName = parsed?.BundleName ?? string.Empty,
            AbilityName = parsed?.AbilityName ?? string.Empty,
            NodeContent = parsed?.NodeContent ?? 0,
        };

        Action<OpenHarmonyAppContext>? initializedHandlers;
        lock (s_sync)
        {
            s_context = context;
            s_nodeContent = context.NodeContent != 0 ? new IntPtr(context.NodeContent) : IntPtr.Zero;
            initializedHandlers = s_initializedHandlers;
        }

        bool registered = false;
        try
        {
            s_lifecycleThunk = OnLifecycleNative;
            s_nodeThunk = OnNodeNative;
            s_surfaceThunk = OnSurfaceNative;
            RegisterBridgeNative(
                Marshal.GetFunctionPointerForDelegate(s_lifecycleThunk),
                Marshal.GetFunctionPointerForDelegate(s_nodeThunk),
                Marshal.GetFunctionPointerForDelegate(s_surfaceThunk));
            registered = true;
        }
        catch (Exception ex)
        {
            // Registration needs libopenharmonyhost.so; without it the app still runs,
            // it just does not receive shell callbacks.
            WriteStatus($"bridge registration failed: {ex.GetType().Name}: {ex.Message}");
        }

        WriteStatus($"bridge attached: registered={registered} bundle={context.BundleName} ability={context.AbilityName} filesDir={context.FilesDir}");
        initializedHandlers?.Invoke(context);
    }

    private static void OnLifecycleNative(int evt)
    {
        var lifecycleEvent = (OpenHarmonyLifecycleEvent)evt;
        Action<OpenHarmonyLifecycleEvent>? handlers;
        lock (s_sync)
        {
            handlers = s_lifecycleHandlers;
            if (handlers is null)
            {
                if (s_pending.Count < 32)
                {
                    s_pending.Add(lifecycleEvent);
                }
                return;
            }
        }
        WriteStatus($"lifecycle: {lifecycleEvent}");
        handlers(lifecycleEvent);
    }

    private static void OnSurfaceNative(IntPtr window, int width, int height, int state)
    {
        var info = new OpenHarmonySurfaceInfo(window, width, height, (OpenHarmonySurfaceState)state);
        Action<OpenHarmonySurfaceInfo>? handlers;
        lock (s_sync)
        {
            s_surface = info;
            handlers = s_surfaceHandlers;
        }
        WriteStatus($"surface: state={info.State} window=0x{window.ToInt64():x} {width}x{height}");
        handlers?.Invoke(info);
    }

    private static void OnNodeNative(IntPtr node)
    {
        lock (s_sync)
        {
            s_nodeContent = node;
        }
        WriteStatus($"node content set: 0x{node.ToInt64():x}");
    }

    private sealed class ContextJson
    {
        [JsonPropertyName("appDir")] public string? AppDir { get; set; }
        [JsonPropertyName("filesDir")] public string? FilesDir { get; set; }
        [JsonPropertyName("cacheDir")] public string? CacheDir { get; set; }
        [JsonPropertyName("bundleName")] public string? BundleName { get; set; }
        [JsonPropertyName("abilityName")] public string? AbilityName { get; set; }
        [JsonPropertyName("nodeContent")] public long NodeContent { get; set; }
    }
}

internal static class BridgeModuleInitializer
{
    [System.Runtime.CompilerServices.ModuleInitializer]
    internal static void Initialize()
    {
        try
        {
            OpenHarmonyBridge.Attach();
        }
        catch
        {
            // Running outside a hap (tests, desktop): the bridge is simply absent.
        }
    }
}
