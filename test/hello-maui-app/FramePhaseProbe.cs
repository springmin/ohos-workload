// FRAMEPHASE probe (opt-in): per-phase breakdown of the self-drawn compositor frame.
//
// Enabled by -p:FramePhaseProbe=true (DefineConstants FRAMEPHASE_PROBE); the shipped sample
// does not compile this file's body and pays nothing. Unlike FramePacingProbe (which emits one
// line per callback/present), this probe only aggregates in memory and writes one summary line
// every 5 s, so the measurement does not itself pay interpreter-priced string formatting and
// status-file I/O on every frame.
//
// It uses the compositor's RenderPhaseTick seam: tick 0 = Render entry, 1 = measure+arrange,
// 2 = surface begin + background fill, 3 = content draw, 4 = chrome/floating overlays,
// 5 = accessibility publish (immediately before the present). The probe times the callback
// boundary and the present itself (chaining the renderer's SurfacePresent hook), so one frame
// decomposes into: pre | measure | surface | draw | chrome | a11y | present | wait.
#if FRAMEPHASE_PROBE
using System.Diagnostics;
using Microsoft.Maui.Platform;
using Microsoft.OpenHarmony.Hosting;

namespace HelloMauiApp;

internal static class FramePhaseProbe
{
    private const long WindowMs = 45_000;
    private const int PhaseCount = 6;   // ticks 0..5
    private const int SlotCount = 8;    // pre measure surface draw chrome a11y present wait

    private static readonly object s_sync = new();
    private static bool s_installed;
    private static long s_startTick;
    private static readonly long[] s_ticks = new long[PhaseCount];
    private static readonly long[] s_sum = new long[SlotCount];
    private static readonly long[] s_max = new long[SlotCount];
    private static long s_callbackStart;   // callback entry (Stopwatch ticks)
    private static long s_presentEnd;      // end of the previous present
    private static long s_firstFrameStart; // window start for the fps figure
    private static int s_frames;
    private static int s_incomplete;
    private static bool s_sawRender;
    private static Action? s_previousPresent;

    public static void Install()
    {
        if (s_installed)
        {
            return;
        }
        s_installed = true;
        s_startTick = Environment.TickCount64;
        // Chain (do not replace) an existing present hook, exactly like FramePacingProbe.
        s_previousPresent = OpenHarmonyWindowRenderer.SurfacePresent;
        OpenHarmonyWindowRenderer.SurfacePresent = OnPresent;
        OpenHarmonyWindowRenderer.RenderPhaseTick = OnTick;
        OpenHarmonyBridge.Frame += OnFrame;
        OpenHarmonyBridge.WriteStatus("[framephase] probe attached");
    }

    private static long Now() => Stopwatch.GetTimestamp();

    private static void OnFrame(OpenHarmonyFrameEventArgs args)
    {
        long now = Now();
        lock (s_sync)
        {
            if (s_presentEnd > 0)
            {
                s_sum[7] += now - s_presentEnd;   // wait: present -> this callback
                if (now - s_presentEnd > s_max[7])
                {
                    s_max[7] = now - s_presentEnd;
                }
            }
            s_callbackStart = now;
            s_sawRender = false;
            if (s_firstFrameStart == 0)
            {
                s_firstFrameStart = now;
            }
        }
        if (Environment.TickCount64 - s_startTick > WindowMs)
        {
            EmitSummary(final: true);
            Detach();
        }
    }

    private static void OnTick(int phase)
    {
        if (phase >= PhaseCount)
        {
            return;
        }
        long now = Now();
        lock (s_sync)
        {
            s_ticks[phase] = now;
            if (phase == PhaseCount - 1)
            {
                s_sawRender = true;
            }
        }
    }

    private static void OnPresent()
    {
        long presentStart = Now();
        lock (s_sync)
        {
            if (s_sawRender)
            {
                s_sum[0] += s_ticks[0] - s_callbackStart;   // pre (event dispatch before Render)
                s_sum[1] += s_ticks[1] - s_ticks[0];        // measure + arrange
                s_sum[2] += s_ticks[2] - s_ticks[1];        // surface begin + background fill
                s_sum[3] += s_ticks[3] - s_ticks[2];        // content draw walk
                s_sum[4] += s_ticks[4] - s_ticks[3];        // chrome + floating overlays
                s_sum[5] += s_ticks[5] - s_ticks[4];        // accessibility refresh + publish
                for (int i = 0; i < PhaseCount; i++)
                {
                    long delta = i == 0 ? s_ticks[0] - s_callbackStart : s_ticks[i] - s_ticks[i - 1];
                    if (delta > s_max[i])
                    {
                        s_max[i] = delta;
                    }
                }
                s_frames++;
            }
            else
            {
                s_incomplete++;
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
        long end = Now();
        lock (s_sync)
        {
            if (s_sawRender)
            {
                s_sum[6] += end - presentStart;
                if (end - presentStart > s_max[6])
                {
                    s_max[6] = end - presentStart;
                }
            }
            s_presentEnd = end;
        }
        if (Environment.TickCount64 - s_startTick > WindowMs)
        {
            return;  // OnFrame detaches on the next callback
        }
        if (Environment.TickCount64 - s_lastSummaryTick >= 5000)
        {
            EmitSummary(final: false);
        }
    }

    private static long s_lastSummaryTick = Environment.TickCount64;

    private static void EmitSummary(bool final)
    {
        string line;
        lock (s_sync)
        {
            if (s_frames == 0 && s_incomplete == 0)
            {
                return;
            }
            double spanMs = s_firstFrameStart > 0 && s_presentEnd > 0
                ? TicksToMs(s_presentEnd - s_firstFrameStart)
                : 0;
            double fps = spanMs > 0 ? s_frames * 1000.0 / spanMs : 0;
            line = $"FPH n={s_frames} inc={s_incomplete} fps={fps:0.0}" +
                   $" pre={Avg(0):0.0}/{TicksToMs(s_max[0]):0.0}" +
                   $" meas={Avg(1):0.0}/{TicksToMs(s_max[1]):0.0}" +
                   $" surf={Avg(2):0.0}/{TicksToMs(s_max[2]):0.0}" +
                   $" draw={Avg(3):0.0}/{TicksToMs(s_max[3]):0.0}" +
                   $" chr={Avg(4):0.0}/{TicksToMs(s_max[4]):0.0}" +
                   $" a11y={Avg(5):0.0}/{TicksToMs(s_max[5]):0.0}" +
                   $" pres={Avg(6):0.0}/{TicksToMs(s_max[6]):0.0}" +
                   $" wait={Avg(7):0.0}/{TicksToMs(s_max[7]):0.0}" +
                   (final ? " final=1" : "");
            Array.Clear(s_sum);
            Array.Clear(s_max);
            s_frames = 0;
            s_incomplete = 0;
            s_firstFrameStart = 0;
            s_lastSummaryTick = Environment.TickCount64;
        }
        try
        {
            OpenHarmonyBridge.WriteStatus(line);
        }
        catch
        {
            // Diagnostics only.
        }
    }

    private static double Avg(int slot) => s_frames > 0 ? s_sum[slot] * 1000.0 / Stopwatch.Frequency / s_frames : 0;

    private static double TicksToMs(long ticks) => ticks * 1000.0 / Stopwatch.Frequency;

    private static void Detach()
    {
        OpenHarmonyBridge.Frame -= OnFrame;
        OpenHarmonyWindowRenderer.RenderPhaseTick = null;
        OpenHarmonyWindowRenderer.SurfacePresent = s_previousPresent;
        OpenHarmonyBridge.WriteStatus("[framephase] probe detached");
    }
}
#endif
