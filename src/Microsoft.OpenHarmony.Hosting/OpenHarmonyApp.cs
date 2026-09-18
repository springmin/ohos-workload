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

public enum OpenHarmonyTouchAction
{
    Down = 0,
    Up = 1,
    Move = 2,
    Cancel = 3,
}

/// <summary>An XComponent touch/mouse event forwarded from the native host.</summary>
public sealed class OpenHarmonyTouchEventArgs
{
    public OpenHarmonyTouchEventArgs(OpenHarmonyTouchAction action, float x, float y, int pointerCount, int pointerId)
    {
        Action = action;
        X = x;
        Y = y;
        PointerCount = pointerCount;
        PointerId = pointerId;
    }

    public OpenHarmonyTouchAction Action { get; }
    public float X { get; }
    public float Y { get; }
    public int PointerCount { get; }
    public int PointerId { get; }
}

/// <summary>A frame tick from the platform (vsync-aligned).</summary>
public sealed class OpenHarmonyFrameEventArgs
{
    public OpenHarmonyFrameEventArgs(long timestamp, long targetTimestamp)
    {
        Timestamp = timestamp;
        TargetTimestamp = targetTimestamp;
    }

    public long Timestamp { get; }
    public long TargetTimestamp { get; }
}

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

    [DllImport(HostLibrary, EntryPoint = "ohos_host_register_input")]
    private static extern void RegisterInputNative(IntPtr touch, IntPtr frame);

    [DllImport(HostLibrary, EntryPoint = "ohos_host_register_text_input")]
    private static extern void RegisterTextInputNative(IntPtr callback);

    [DllImport(HostLibrary, EntryPoint = "ohos_host_register_text_submitted")]
    private static extern void RegisterTextSubmittedNative(IntPtr callback);

    [DllImport(HostLibrary, EntryPoint = "ohos_host_keystore_register_result")]
    private static extern void RegisterKeystoreResultNative(IntPtr callback);

    [DllImport(HostLibrary, EntryPoint = "ohos_host_request_text_input")]
    private static extern void RequestTextInputNative(int show);

    [DllImport(HostLibrary, EntryPoint = "ohos_host_request_vibration")]
    private static extern void RequestVibrationNative(int durationMs);

    [DllImport(HostLibrary, EntryPoint = "ohos_host_vibrate")]
    private static extern int VibrateNative(int durationMs);

    [DllImport(HostLibrary, EntryPoint = "ohos_host_network_access")]
    private static extern int NetworkAccessNative();

    [DllImport(HostLibrary, EntryPoint = "ohos_host_check_permission", CharSet = CharSet.Ansi)]
    private static extern int CheckPermissionNative(string permission);

    private delegate void NativeLifecycleDelegate(int evt);
    private delegate void NativeNodeDelegate(IntPtr node);
    private delegate void NativeSurfaceDelegate(IntPtr window, int width, int height, int state);
    private delegate void NativeTouchDelegate(int type, float x, float y, int pointerCount, int pointerId);
    private delegate void NativeFrameDelegate(long timestamp, long targetTimestamp);
    private delegate void NativeTextInputDelegate(IntPtr utf8);
    private delegate void NativeTextSubmittedDelegate();
    private delegate void NativeKeystoreResultDelegate(int requestId, int rc, IntPtr dataUtf8);

    private static readonly object s_sync = new();
    private static OpenHarmonyAppContext? s_context;
    private static IntPtr s_nodeContent;
    private static bool s_attached;
    private static NativeLifecycleDelegate? s_lifecycleThunk;
    private static NativeNodeDelegate? s_nodeThunk;
    private static NativeSurfaceDelegate? s_surfaceThunk;
    private static NativeTouchDelegate? s_touchThunk;
    private static NativeFrameDelegate? s_frameThunk;
    private static NativeTextInputDelegate? s_textInputThunk;
    private static NativeTextSubmittedDelegate? s_textSubmittedThunk;
    private static NativeKeystoreResultDelegate? s_keystoreResultThunk;
    private static readonly List<OpenHarmonyLifecycleEvent> s_pending = new();
    private static Action<OpenHarmonySurfaceInfo>? s_surfaceHandlers;
    private static Action<OpenHarmonyTouchEventArgs>? s_touchHandlers;
    private static Action<OpenHarmonyFrameEventArgs>? s_frameHandlers;
    private static Action<string>? s_textInputHandlers;
    private static Action? s_redrawHandlers;
    private static Action? s_textSubmittedHandlers;
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

    /// <summary>Raised for every XComponent touch/mouse event (input for handlers/gestures).</summary>
    public static event Action<OpenHarmonyTouchEventArgs>? Touch
    {
        add { lock (s_sync) { s_touchHandlers += value; } }
        remove { lock (s_sync) { s_touchHandlers -= value; } }
    }

    /// <summary>Raised with the text typed in the ArkTS shell's input control.</summary>
    public static event Action<string>? TextInput
    {
        add { lock (s_sync) { s_textInputHandlers += value; } }
        remove { lock (s_sync) { s_textInputHandlers -= value; } }
    }

    /// <summary>Completes a pending keystore request (called by the ArkTS sink).</summary>
    public static void CompleteKeystoreRequest(int requestId, int rc, string data)
        => KeystoreResult?.Invoke(requestId, rc, data);

    /// <summary>Raised when the ArkTS keystore sink answers a request.</summary>
    public static event Action<int, int, string>? KeystoreResult;

    /// <summary>Raised when the user pressed the return key in the ArkTS shell's input.</summary>
    public static event Action? TextSubmitted
    {
        add { lock (s_sync) { s_textSubmittedHandlers += value; } }
        remove { lock (s_sync) { s_textSubmittedHandlers -= value; } }
    }

    /// <summary>Raised when the UI asks for a redraw (navigation pushes/pops, app state changes).</summary>
    public static event Action? RedrawRequested
    {
        add { lock (s_sync) { s_redrawHandlers += value; } }
        remove { lock (s_sync) { s_redrawHandlers -= value; } }
    }

    /// <summary>Requests a redraw from the platform host (no-op without one).</summary>
    public static void RequestRedraw()
    {
        Action? handlers;
        lock (s_sync)
        {
            handlers = s_redrawHandlers;
        }
        handlers?.Invoke();
    }

    /// <summary>Vibrates through the platform NDK (falls back to the ArkTS sink when absent).</summary>
    public static bool Vibrate(int durationMs)
    {
        try
        {
            if (VibrateNative(durationMs) == 0)
            {
                return true;
            }
        }
        catch
        {
            // No native host (tests): fall through to the sink request.
        }
        RequestVibration(durationMs);
        return false;
    }

    /// <summary>Network access from the platform NDK: 0 unknown, 1 none, 2 local, 3 internet.</summary>
    public static int NetworkAccessLevel()
    {
        try
        {
            return NetworkAccessNative();
        }
        catch
        {
            return 0;
        }
    }

    /// <summary>Self permission check through the platform NDK (false when unavailable).</summary>
    public static bool CheckSelfPermission(string permission)
    {
        try
        {
            return CheckPermissionNative(permission) == 1;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Asks the ArkTS shell to vibrate for the given duration (no-op without a sink).</summary>
    public static void RequestVibration(int durationMs)
    {
        try
        {
            RequestVibrationNative(durationMs);
        }
        catch
        {
            // No native host (tests) or no sink: vibration is optional.
        }
    }

    /// <summary>Asks the ArkTS shell to show (true) or hide (false) the soft keyboard.</summary>
    public static void RequestTextInput(bool show)
    {
        try
        {
            RequestTextInputNative(show ? 1 : 0);
        }
        catch
        {
            // No native host (tests): the request is a no-op.
        }
    }

    /// <summary>Raised on every platform frame callback (vsync-aligned rendering tick).</summary>
    public static event Action<OpenHarmonyFrameEventArgs>? Frame
    {
        add { lock (s_sync) { s_frameHandlers += value; } }
        remove { lock (s_sync) { s_frameHandlers -= value; } }
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
            s_touchThunk = OnTouchNative;
            s_frameThunk = OnFrameNative;
            RegisterInputNative(
                Marshal.GetFunctionPointerForDelegate(s_touchThunk),
                Marshal.GetFunctionPointerForDelegate(s_frameThunk));
            s_textInputThunk = OnTextInputNative;
            try
            {
                RegisterTextInputNative(Marshal.GetFunctionPointerForDelegate(s_textInputThunk));
                s_textSubmittedThunk = OnTextSubmittedNative;
                RegisterTextSubmittedNative(Marshal.GetFunctionPointerForDelegate(s_textSubmittedThunk));
                s_keystoreResultThunk = OnKeystoreResultNative;
                RegisterKeystoreResultNative(Marshal.GetFunctionPointerForDelegate(s_keystoreResultThunk));
            }
            catch (Exception ex)
            {
                // Soft keyboard support is optional: an older host library must not break apps.
                WriteStatus($"text input registration skipped: {ex.GetType().Name}");
            }
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

    private static void OnTouchNative(int type, float x, float y, int pointerCount, int pointerId)
    {
        var args = new OpenHarmonyTouchEventArgs((OpenHarmonyTouchAction)type, x, y, pointerCount, pointerId);
        Action<OpenHarmonyTouchEventArgs>? handlers;
        lock (s_sync)
        {
            handlers = s_touchHandlers;
        }
        handlers?.Invoke(args);
    }

    private static void OnTextInputNative(IntPtr utf8)
    {
        string text = Marshal.PtrToStringUTF8(utf8) ?? string.Empty;
        Action<string>? handlers;
        lock (s_sync)
        {
            handlers = s_textInputHandlers;
        }
        handlers?.Invoke(text);
    }

    private static void OnKeystoreResultNative(int requestId, int rc, IntPtr dataUtf8)
    {
        string data = dataUtf8 == IntPtr.Zero ? string.Empty : Marshal.PtrToStringUTF8(dataUtf8) ?? string.Empty;
        KeystoreResult?.Invoke(requestId, rc, data);
    }

    private static void OnTextSubmittedNative()
    {
        Action? handlers;
        lock (s_sync)
        {
            handlers = s_textSubmittedHandlers;
        }
        handlers?.Invoke();
    }

    private static void OnFrameNative(long timestamp, long targetTimestamp)
    {
        var args = new OpenHarmonyFrameEventArgs(timestamp, targetTimestamp);
        Action<OpenHarmonyFrameEventArgs>? handlers;
        lock (s_sync)
        {
            handlers = s_frameHandlers;
        }
        handlers?.Invoke(args);
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

    [DllImport(HostLibrary, EntryPoint = "ohos_host_measure_text", CharSet = CharSet.Ansi)]
    private static extern int MeasureTextNative(string utf8, float size, out int width, out int height);

    private static bool s_textMetricsUnavailable;

    [DllImport(HostLibrary, EntryPoint = "ohos_host_draw_save")]
    private static extern void SaveNative();

    [DllImport(HostLibrary, EntryPoint = "ohos_host_draw_restore")]
    private static extern void RestoreNative();

    [DllImport(HostLibrary, EntryPoint = "ohos_host_draw_clip_rect")]
    private static extern void ClipRectNative(float x, float y, float width, float height, int subtract);

    [DllImport(HostLibrary, EntryPoint = "ohos_host_draw_clip_polyline")]
    private static extern void ClipPolylineNative(float[] xy, int count);

    [DllImport(HostLibrary, EntryPoint = "ohos_host_draw_image_bytes")]
    private static extern int DrawImageBytesNative(byte[] data, int length, float x, float y, float width, float height);

    [DllImport(HostLibrary, EntryPoint = "ohos_host_draw_set_linear_gradient")]
    private static extern void LinearGradientNative(float x0, float y0, float x1, float y1, uint[] colors, float[] stops, int count);

    [DllImport(HostLibrary, EntryPoint = "ohos_host_draw_set_radial_gradient")]
    private static extern void RadialGradientNative(float cx, float cy, float radius, uint[] colors, float[] stops, int count);

    [DllImport(HostLibrary, EntryPoint = "ohos_host_draw_set_image_pattern")]
    private static extern int ImagePatternNative(byte[] data, int length, int tileModeX, int tileModeY, float scaleX, float scaleY);

    [DllImport(HostLibrary, EntryPoint = "ohos_host_draw_set_shadow")]
    private static extern void ShadowNative(float dx, float dy, float blur, uint argb);

    [DllImport(HostLibrary, EntryPoint = "ohos_host_draw_clear_effects")]
    private static extern void ClearEffectsNative();

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

    /// <summary>Measures text with the platform font. Returns false when unavailable.</summary>
    public static bool MeasureText(string text, float size, out int width, out int height)
    {
        width = 0;
        height = 0;
        if (s_textMetricsUnavailable)
        {
            return false;
        }
        try
        {
            return MeasureTextNative(text, size, out width, out height) == 0;
        }
        catch
        {
            // No native host (tests/tools): remember it so the hot layout path never throws again.
            s_textMetricsUnavailable = true;
            return false;
        }
    }

    public static void Save() { try { SaveNative(); } catch { } }
    public static void Restore() { try { RestoreNative(); } catch { } }

    public static void ClipRect(float x, float y, float width, float height, bool subtract = false)
    {
        try { ClipRectNative(x, y, width, height, subtract ? 1 : 0); } catch { }
    }

    public static void ClipPolyline(float[] xy)
    {
        try { ClipPolylineNative(xy, xy.Length / 2); } catch { }
    }

    /// <summary>Decodes PNG/JPEG bytes and draws them into the destination rectangle.</summary>
    public static bool DrawImageBytes(byte[] data, int x, int y, int width, int height)
    {
        try
        {
            return DrawImageBytesNative(data, data.Length, x, y, width, height) == 0;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Linear gradient applied to subsequent fills/text.</summary>
    public static void SetLinearGradient(float x0, float y0, float x1, float y1, uint[] colors, float[] stops)
    {
        try { LinearGradientNative(x0, y0, x1, y1, colors, stops, colors.Length); } catch { }
    }

    /// <summary>Radial gradient applied to subsequent fills/text.</summary>
    public static void SetRadialGradient(float cx, float cy, float radius, uint[] colors, float[] stops)
    {
        try { RadialGradientNative(cx, cy, radius, colors, stops, colors.Length); } catch { }
    }

    /// <summary>Tile-image pattern applied to subsequent fills (0=clamp, 1=repeat, 2=mirror).</summary>
    public static bool SetImagePattern(byte[] data, int tileModeX = 1, int tileModeY = 1, float scaleX = 1f, float scaleY = 1f)
    {
        try
        {
            return ImagePatternNative(data, data.Length, tileModeX, tileModeY, scaleX, scaleY) == 0;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Drop shadow applied to subsequent fills/text.</summary>
    public static void SetShadow(float dx, float dy, float blur, uint argb)
    {
        try { ShadowNative(dx, dy, blur, argb); } catch { }
    }

    public static void ClearEffects() { try { ClearEffectsNative(); } catch { } }

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
