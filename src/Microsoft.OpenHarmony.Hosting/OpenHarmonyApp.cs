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

    [DllImport(HostLibrary, EntryPoint = "ohos_host_fill_surface")]
    private static extern int FillSurfaceNative(uint argb);

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

    /// <summary>
    /// Fills the current surface with a solid colour (0xAARRGGBB). Returns true when the
    /// surface accepted the frame. This is the managed entry point that a renderer
    /// (Skia/MAUI) replaces with real drawing once it is attached.
    /// </summary>
    public static bool FillSurface(uint argb)
    {
        try
        {
            return FillSurfaceNative(argb) == 0;
        }
        catch
        {
            return false;
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

/// <summary>
/// Immediate-mode drawing over the ArkUI XComponent surface, backed by the platform's
/// Skia-based 2D API (native_drawing). This is the rendering entry point managed code uses
/// today; a Microsoft.Maui.Graphics backend maps its canvas onto the same calls.
/// </summary>
public static class OpenHarmonyCanvas
{
    private const string HostLibrary = "libopenharmonyhost.so";

    [DllImport(HostLibrary, EntryPoint = "ohos_host_draw_begin")]
    private static extern int BeginNative(int width, int height);

    [DllImport(HostLibrary, EntryPoint = "ohos_host_draw_clear")]
    private static extern void ClearNative(uint argb);

    [DllImport(HostLibrary, EntryPoint = "ohos_host_draw_rect")]
    private static extern void RectNative(int x, int y, int width, int height, uint argb, int filled);

    [DllImport(HostLibrary, EntryPoint = "ohos_host_draw_text", CharSet = CharSet.Ansi)]
    private static extern int TextNative(int x, int y, string utf8, float size, uint argb);

    [DllImport(HostLibrary, EntryPoint = "ohos_host_draw_polyline")]
    private static extern void PolylineNative(float[] xy, int count, int closed, uint argb, int filled, float strokeWidth);

    [DllImport(HostLibrary, EntryPoint = "ohos_host_draw_present")]
    private static extern int PresentNative();

    /// <summary>Creates/resizes the canvas for the current surface. Safe to call repeatedly.</summary>
    public static bool Begin(int width, int height)
    {
        try
        {
            return BeginNative(width, height) == 0;
        }
        catch
        {
            return false;
        }
    }

    public static void Clear(uint argb)
    {
        try { ClearNative(argb); } catch { }
    }

    public static void FillRect(int x, int y, int width, int height, uint argb)
    {
        try { RectNative(x, y, width, height, argb, 1); } catch { }
    }

    public static void StrokeRect(int x, int y, int width, int height, uint argb)
    {
        try { RectNative(x, y, width, height, argb, 0); } catch { }
    }

    /// <summary>Draws a polyline/polygon (packed x,y pairs). Curves are flattened by the caller.</summary>
    public static void Polyline(float[] xy, bool closed, uint argb, bool filled, float strokeWidth = 1f)
    {
        try { PolylineNative(xy, xy.Length / 2, closed ? 1 : 0, argb, filled ? 1 : 0, strokeWidth); } catch { }
    }

    /// <summary>Draws an ellipse approximated by a closed polyline.</summary>
    public static void Ellipse(float cx, float cy, float rx, float ry, uint argb, bool filled, float strokeWidth = 1f)
    {
        const int segments = 48;
        var pts = new float[segments * 2];
        for (int i = 0; i < segments; i++)
        {
            double a = 2 * Math.PI * i / segments;
            pts[i * 2] = cx + (float)(rx * Math.Cos(a));
            pts[i * 2 + 1] = cy + (float)(ry * Math.Sin(a));
        }
        Polyline(pts, closed: true, argb, filled, strokeWidth);
    }

    public static bool DrawText(int x, int y, string text, float size, uint argb)
    {
        try
        {
            return TextNative(x, y, text, size, argb) == 0;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Blits the canvas into the surface and flushes it.</summary>
    public static bool Present()
    {
        try
        {
            return PresentNative() == 0;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Draws a demo frame (background, bars, box and a label) and presents it.</summary>
    public static bool DrawDemoFrame(int width, int height)
    {
        if (!Begin(width, height))
        {
            return false;
        }
        Clear(0xff102030);                                     // ARGB background
        FillRect(0, 0, width, height / 6, 0xff2080ff);          // blue header
        FillRect(0, height - height / 6, width, height / 6, 0xff20c070);
        StrokeRect(width / 8, height / 3, width / 4, height / 4, 0xffffd040);
        FillRect(width / 8 + 4, height / 3 + 4, width / 4 - 8, height / 4 - 8, 0x40ffd040);
        DrawText(width / 2, height / 2, "OpenHarmony .NET", 48f, 0xffe0e0ff);
        DrawText(width / 2, height / 2 + 64, "native_drawing frame", 28f, 0xffa0c0ff);
        return Present();
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
