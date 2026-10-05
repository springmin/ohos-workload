// STARTUP probe (opt-in): one-shot cold/warm start decomposition.
//
// Enabled by -p:StartupProbe=true (DefineConstants STARTUP_PROBE); the shipped sample does not
// compile this file's body and pays nothing. The status file the probe writes to is polled by
// the ArkTS shell every 3 s, so per-milestone WriteStatus lines would all carry the poll time.
// The probe instead records Stopwatch ticks in memory and emits ONE line at the first present
// with the deltas and a UTC wall clock, which puts the measured milestones back on the hilog
// timeline (compare with the host's immediate OH_LOG_INFO lines).
#if STARTUP_PROBE
using System.Diagnostics;
using System.Globalization;
using System.Text;
using Microsoft.Maui.Platform;
using Microsoft.OpenHarmony.Hosting;

namespace HelloMauiApp;

internal static class StartupProbe
{
    private static readonly object s_sync = new();
    private static readonly Stopwatch s_clock = Stopwatch.StartNew();
    private static readonly StringBuilder s_marks = new();
    private static int s_installed;
    private static Action? s_previousPresent;

    /// <summary>Records one milestone once (first call wins); cheap enough for the start path.</summary>
    public static void Mark(string name)
    {
        if (s_installed == 0)
        {
            return;
        }
        lock (s_sync)
        {
            if (s_marks.Length > 0)
            {
                s_marks.Append(',');
            }
            s_marks.Append(name).Append(':').Append(s_clock.ElapsedMilliseconds);
        }
    }

    /// <summary>
    /// Installs the probe: marks "main", chains the renderer's present hook (first present emits
    /// the summary) and subscribes to the first frame/lifecycle/surface notifications.
    /// </summary>
    public static void Install()
    {
        if (Interlocked.Exchange(ref s_installed, 1) != 0)
        {
            return;
        }
        Mark("main");
        s_previousPresent = OpenHarmonyWindowRenderer.SurfacePresent;
        OpenHarmonyWindowRenderer.SurfacePresent = OnPresent;
        OpenHarmonyBridge.Frame += _ => Mark("frame");
        OpenHarmonyBridge.LifecycleChanged += e => Mark($"lifecycle{e}");
        OpenHarmonyBridge.SurfaceChanged += info => Mark($"surface{info.State}");
    }

    private static void OnPresent()
    {
        bool first;
        lock (s_sync)
        {
            first = !s_marks.ToString().Contains("present:");
            if (first)
            {
                s_marks.Append(",present:").Append(s_clock.ElapsedMilliseconds);
            }
        }
        if (s_previousPresent is { } previous)
        {
            previous();
        }
        else
        {
            OpenHarmonyCanvas.Present();
        }
        if (first)
        {
            lock (s_sync)
            {
                // Freeze the mark log: later frame callbacks must not grow it or take the
                // lock on the render path.
                s_installed = 0;
            }
            // The shell only mirrors the status file's tail (60 lines) every 3 s, and CEF
            // stderr shares the file, so a single line is usually buried before the poll
            // reads it. Re-emit the frozen summary until the 9 s [managed] mirror and beyond;
            // duplicates are identical and trimmed with the rest.
            var timer = new System.Threading.Timer(_ => Emit(), null, 0, 500);
            s_timer = timer;
        }
    }

    private static System.Threading.Timer? s_timer;

    private static void Emit()
    {
        string marks;
        long total;
        lock (s_sync)
        {
            marks = s_marks.ToString();
            total = s_clock.ElapsedMilliseconds;
        }
        if (total > 60_000)
        {
            s_timer?.Dispose();
            s_timer = null;
            return;
        }
        string line = string.Create(CultureInfo.InvariantCulture,
            $"[startup] utc={DateTime.UtcNow.Ticks / TimeSpan.TicksPerMillisecond} total={total} {marks}");
        OpenHarmonyBridge.WriteStatus(line);
    }
}
#endif
