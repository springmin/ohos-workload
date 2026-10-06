// MULTIWINDOW-L M4-01 device evidence: per-window frame pacing.
//
// The host's `canvas presented` fold reports a 5 s present interval per window, but it cannot
// tell how many consecutive frames were long. This probe subscribes to the per-window frame
// callback (the same channel the production renderers consume; the primary window's ticks ride
// the untagged channel and are recorded as "main"), and every 5 s writes one status line per
// window:
//
//   [hello-maui-app] framestats <id> n=<frames> fps=<fps> avg=<ms> max=<ms> long=<n> longruns=<n>
//
// n/fps/avg/max describe the callback cadence, long counts frames whose gap exceeded 33 ms
// (a dropped vsync at 60 Hz), and longruns counts the occurrences of three consecutive long
// gaps (the M4-01 "连续长帧 ≤33ms×3=0" criterion). The probe is a passive observer: it never
// draws and never touches the renderers.
using Microsoft.OpenHarmony.Hosting;
using System.Diagnostics;

namespace HelloMauiApp;

/// <summary>Per-window frame-pacing probe for the M4-01/M4-06 device rounds.</summary>
internal static class WindowFrameStats
{
    private const double LongFrameMs = 33.0;
    private const int ReportIntervalMs = 5000;

    private sealed class WindowStats
    {
        public long LastTimestamp;
        public long WindowStartTicks;
        public int Frames;
        public double SumGapMs;
        public double MaxGapMs;
        public int LongFrames;
        public int LongRuns;
        public int ConsecutiveLong;
    }

    private static readonly object Sync = new();
    private static readonly Dictionary<string, WindowStats> Windows = new(StringComparer.Ordinal);
    private static int s_installed;

    /// <summary>Subscribes the probe (idempotent). Called once by the sample app.</summary>
    internal static void Install()
    {
        if (Interlocked.Exchange(ref s_installed, 1) != 0)
        {
            return;
        }
        try
        {
            OpenHarmonyBridge.WindowFrame += OnFrame;
            // The primary window's frame ticks travel on the historical untagged channel (the
            // tagged channel carries every other registered window); record it under "main" so
            // the dual-window comparison has both sides.
            OpenHarmonyBridge.Frame += _ => OnFrame("main", new OpenHarmonyFrameEventArgs(0, 0));
            OpenHarmonyBridge.WriteStatus("[hello-maui-app] framestats installed");
        }
        catch (Exception)
        {
            // No host library (off-device smoke): the probe stays silent.
        }
    }

    private static void OnFrame(string windowId, OpenHarmonyFrameEventArgs args)
    {
        try
        {
            long now = args.Timestamp > 0 ? args.Timestamp / 1_000_000 : Stopwatch.GetTimestamp() * 1000 / Stopwatch.Frequency;
            string report = string.Empty;
            lock (Sync)
            {
                if (!Windows.TryGetValue(windowId, out WindowStats? stats))
                {
                    stats = new WindowStats { WindowStartTicks = now, LastTimestamp = now };
                    Windows.Add(windowId, stats);
                    return;
                }
                long gapTicks = now - stats.LastTimestamp;
                stats.LastTimestamp = now;
                stats.Frames++;
                if (gapTicks > 0)
                {
                    double gapMs = gapTicks;
                    stats.SumGapMs += gapMs;
                    if (gapMs > stats.MaxGapMs)
                    {
                        stats.MaxGapMs = gapMs;
                    }
                    if (gapMs > LongFrameMs)
                    {
                        stats.LongFrames++;
                        stats.ConsecutiveLong++;
                        if (stats.ConsecutiveLong == 3)
                        {
                            stats.LongRuns++;
                        }
                    }
                    else
                    {
                        stats.ConsecutiveLong = 0;
                    }
                }
                if (now - stats.WindowStartTicks < ReportIntervalMs || stats.Frames == 0)
                {
                    return;
                }
                double elapsedMs = now - stats.WindowStartTicks;
                double fps = elapsedMs > 0 ? stats.Frames * 1000.0 / elapsedMs : 0;
                double avg = stats.Frames > 0 ? stats.SumGapMs / stats.Frames : 0;
                report = $"[hello-maui-app] framestats {windowId} n={stats.Frames} fps={fps:0.0} avg={avg:0.0}ms max={stats.MaxGapMs:0.0}ms long={stats.LongFrames} longruns={stats.LongRuns}";
                stats.WindowStartTicks = now;
                stats.Frames = 0;
                stats.SumGapMs = 0;
                stats.MaxGapMs = 0;
                stats.LongFrames = 0;
                stats.LongRuns = 0;
            }
            OpenHarmonyBridge.WriteStatus(report);
        }
        catch (Exception)
        {
            // A reverse callback must never propagate into the host frame loop.
        }
    }
}
