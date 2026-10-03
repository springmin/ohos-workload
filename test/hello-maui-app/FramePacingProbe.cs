// FRAMEPACING probe (opt-in): per-frame telemetry for the self-drawn compositor.
//
// Enabled by -p:FramepacingProbe=true (DefineConstants FRAMEPACING_PROBE); the shipped
// sample does not compile this file's body and pays nothing. The probe subscribes to the
// platform frame callback BEFORE the app host (Program.Run calls Install right after the
// MauiApp is built and before OpenHarmonyMauiAppHost is resolved, so the probe sees every
// callback before the host renders) and chains the renderer's SurfacePresent hook to time
// the draw+present half of the same callback.
//
// One line per callback / present is appended to dotnet-status.txt (the same channel the
// native host's stderr uses). The ArkTS shell mirrors the file's tail to hilog on its first
// 12 polls (3 s apart), so a device run captures the interleaved FPF/FPP lines without a
// rebuilt shell. Lines are emitted for ~40 s, then the probe detaches.
#if FRAMEPACING_PROBE
using Microsoft.Maui.Platform;
using Microsoft.OpenHarmony.Hosting;

namespace HelloMauiApp;

internal static class FramePacingProbe
{
    private const long WindowMs = 40_000;

    private static readonly object s_sync = new();
    private static bool s_installed;
    private static long s_startTick;
    private static long s_lastTsNs;
    private static long s_lastCallbackTick;
    private static int s_frames;
    private static int s_presents;
    private static Action? s_previousPresent;

    public static void Install()
    {
        if (s_installed)
        {
            return;
        }
        s_installed = true;
        s_startTick = Environment.TickCount64;
        // Chain (do not replace) an existing present hook, exactly like the tooltip overlay:
        // with no hook installed, the renderer presents through OpenHarmonyCanvas itself.
        s_previousPresent = OpenHarmonyWindowRenderer.SurfacePresent;
        OpenHarmonyWindowRenderer.SurfacePresent = OnPresent;
        OpenHarmonyBridge.Frame += OnFrame;
        OpenHarmonyBridge.WriteStatus($"[framepacing] probe attached tick={s_startTick}");
    }

    private static void OnFrame(OpenHarmonyFrameEventArgs args)
    {
        long now = Environment.TickCount64;
        long ts = args.Timestamp;
        string line;
        lock (s_sync)
        {
            s_frames++;
            long gapUs = s_lastTsNs > 0 && ts > s_lastTsNs ? (ts - s_lastTsNs) / 1000 : 0;
            long tgtUs = args.TargetTimestamp > ts ? (args.TargetTimestamp - ts) / 1000 : 0;
            long idleMs = s_lastCallbackTick > 0 ? now - s_lastCallbackTick : 0;
            s_lastTsNs = ts;
            s_lastCallbackTick = now;
            int w = OpenHarmonyBridge.Surface?.Width ?? 0;
            line = $"FPF t={now} ts={ts} gap={gapUs} tgt={tgtUs} idle={idleMs} n={s_frames} p={s_presents} w={w}";
        }
        Emit(line);
        if (now - s_startTick > WindowMs)
        {
            OpenHarmonyBridge.WriteStatus($"[framepacing] probe detached n={s_frames} p={s_presents}");
            OpenHarmonyBridge.Frame -= OnFrame;
            OpenHarmonyWindowRenderer.SurfacePresent = s_previousPresent;
        }
    }

    private static void OnPresent()
    {
        long now = Environment.TickCount64;
        long latMs;
        lock (s_sync)
        {
            s_presents++;
            latMs = now - s_lastCallbackTick;
        }
        Emit($"FPP t={now} lat={latMs} p={s_presents}");
        if (s_previousPresent is { } previous)
        {
            previous();
        }
        else
        {
            OpenHarmonyCanvas.Present();
        }
    }

    private static void Emit(string line)
    {
        try
        {
            OpenHarmonyBridge.WriteStatus(line);
        }
        catch
        {
            // Diagnostics only; a write failure must never reach the frame path.
        }
    }
}
#endif
