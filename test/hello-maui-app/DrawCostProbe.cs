// DRAWCOST probe (opt-in): per-node-kind / per-canvas-op breakdown of the compositor's draw
// walk. Enabled by -p:DrawCostProbe=true (DefineConstants DRAWCOST_PROBE); the shipped sample
// does not compile this file's body and pays nothing.
//
// How the split works, without changing what the compositor draws:
//   * the compositor's DrawCostTick seam reports the coarse kind of every node as it enters its
//     own draw (0 text, 1 image, 2 shape, 3 container, 4 other);
//   * a CostCanvas substituted through CanvasFactory times its own virtual canvas operations,
//     which is where every fill/stroke/text/save/restore/clip/transform call the compositor and
//     the platform views make lands. Each operation is attributed to the kind currently active.
// The walk's own glue (property reads, child enumeration, flow maps, kind classification) is not
// inside a canvas call; comparing the DCH canvas total with the FPH draw phase isolates it.
//
// Aggregation is per 5 s window and single-threaded (the compositor draws and presents on the
// render thread), so no lock sits inside the hot path; one summary line goes to the status file.
#if DRAWCOST_PROBE
using System.Diagnostics;
using Microsoft.Maui.Graphics;
using Microsoft.Maui.Platform;
using Microsoft.OpenHarmony.Hosting;
using MauiCanvas = Microsoft.OpenHarmony.Maui.Graphics.OpenHarmonyCanvas;
using HostCanvas = Microsoft.OpenHarmony.Hosting.OpenHarmonyCanvas;

namespace HelloMauiApp;

internal static class DrawCostProbe
{
    internal const int KindCount = 5;
    internal const int OpCount = 14;
    internal const int OpSave = 0;
    internal const int OpRestore = 1;
    internal const int OpClip = 2;
    internal const int OpFillRect = 3;
    internal const int OpFillRound = 4;
    internal const int OpFillEllipse = 5;
    internal const int OpFillPath = 6;
    internal const int OpDrawRect = 7;
    internal const int OpDrawRound = 8;
    internal const int OpDrawEllipse = 9;
    internal const int OpDrawLine = 10;
    internal const int OpDrawPath = 11;
    internal const int OpText = 12;
    internal const int OpTransform = 13;

    private static readonly string[] s_opNames =
    {
        "save", "rest", "clip", "fRect", "fRound", "fEll", "fPath",
        "dRect", "dRound", "dEll", "dLine", "dPath", "text", "tr",
    };

    private static readonly long[] s_opSum = new long[OpCount];
    private static readonly long[] s_opMax = new long[OpCount];
    private static readonly int[] s_opCalls = new int[OpCount];
    private static readonly long[] s_kindSum = new long[KindCount];
    private static readonly int[] s_kindNodes = new int[KindCount];
    private static readonly long[,] s_kindOpSum = new long[KindCount, OpCount];
    private static int s_frames;
    private static long s_lastSummaryTick;
    private static bool s_installed;
    private static Action? s_previousPresent;

    public static void Install()
    {
        if (s_installed)
        {
            return;
        }
        s_installed = true;
        CostCanvas.CurrentKind = -1;
        OpenHarmonyWindowRenderer.CanvasFactory = () => new CostCanvas();
        OpenHarmonyWindowRenderer.DrawCostTick = OnNode;
        // A frame starts after the present; reset the kind so the surface fill and any chrome
        // drawn outside the node walk are not attributed to the previous frame's last node.
        OpenHarmonyBridge.Frame += OnFrameBoundary;
        s_previousPresent = OpenHarmonyWindowRenderer.SurfacePresent;
        OpenHarmonyWindowRenderer.SurfacePresent = OnPresent;
        OpenHarmonyBridge.WriteStatus("[drawcost] probe attached");
    }

    private static void OnFrameBoundary(OpenHarmonyFrameEventArgs args) => CostCanvas.CurrentKind = -1;

    private static void OnNode(int kind)
    {
        CostCanvas.CurrentKind = kind;
        s_kindNodes[kind]++;
    }

    /// <summary>One timed canvas operation, attributed to the kind currently drawing.</summary>
    internal static void Add(int op, long ticks)
    {
        s_opSum[op] += ticks;
        s_opCalls[op]++;
        if (ticks > s_opMax[op])
        {
            s_opMax[op] = ticks;
        }
        int kind = CostCanvas.CurrentKind;
        if (kind >= 0 && kind < KindCount)
        {
            s_kindSum[kind] += ticks;
            s_kindOpSum[kind, op] += ticks;
        }
    }

    private static void OnPresent()
    {
        if (s_previousPresent is { } previous)
        {
            previous();
        }
        else
        {
            HostCanvas.Present();
        }
        s_frames++;
        if (Environment.TickCount64 - s_lastSummaryTick >= 5000)
        {
            Emit();
        }
    }

    private static double KindOps(int kind, int first, int last)
    {
        long sum = 0;
        for (int op = first; op <= last; op++)
        {
            sum += s_kindOpSum[kind, op];
        }
        return TicksToMs(sum);
    }

    private static void Emit()
    {
        string line = $"DCH n={s_frames}";
        for (int k = 0; k < KindCount; k++)
        {
            line += $" k{k}={s_kindNodes[k]}/{TicksToMs(s_kindSum[k]):0.00}" +
                    $"[f={KindOps(k, OpFillRect, OpFillPath):0.0} s={KindOps(k, OpDrawRect, OpDrawPath):0.0}" +
                    $" t={TicksToMs(s_kindOpSum[k, OpText]):0.0} c={TicksToMs(s_kindOpSum[k, OpClip]):0.0}]";
        }
        for (int op = 0; op < OpCount; op++)
        {
            line += $" {s_opNames[op]}={TicksToMs(s_opSum[op]):0.00}/{s_opCalls[op]}";
        }
        line += $" tot={TicksToMs(Total()):0.00}";
        try
        {
            OpenHarmonyBridge.WriteStatus(line);
        }
        catch
        {
            // Diagnostics only.
        }
        Array.Clear(s_opSum);
        Array.Clear(s_opMax);
        Array.Clear(s_opCalls);
        Array.Clear(s_kindSum);
        Array.Clear(s_kindNodes);
        Array.Clear(s_kindOpSum);
        s_frames = 0;
        s_lastSummaryTick = Environment.TickCount64;
    }

    private static long Total()
    {
        long total = 0;
        for (int i = 0; i < OpCount; i++)
        {
            total += s_opSum[i];
        }
        return total;
    }

    private static double TicksToMs(long ticks) => ticks * 1000.0 / Stopwatch.Frequency;
}

/// <summary>
/// The compositor's canvas with every virtual operation timed and attributed to the node kind
/// DrawCostTick last reported. Behavioural base calls are untouched; only the clock wraps them.
/// </summary>
internal sealed class CostCanvas : MauiCanvas
{
    internal static int CurrentKind = -1;

    private static void Done(int op, long start)
        => DrawCostProbe.Add(op, Stopwatch.GetTimestamp() - start);

    public override void SaveState()
    {
        long t = Stopwatch.GetTimestamp();
        base.SaveState();
        Done(DrawCostProbe.OpSave, t);
    }

    public override bool RestoreState()
    {
        long t = Stopwatch.GetTimestamp();
        bool result = base.RestoreState();
        Done(DrawCostProbe.OpRestore, t);
        return result;
    }

    public override void ClipRectangle(float x, float y, float width, float height)
    {
        long t = Stopwatch.GetTimestamp();
        base.ClipRectangle(x, y, width, height);
        Done(DrawCostProbe.OpClip, t);
    }

    public override void FillRectangle(float x, float y, float width, float height)
    {
        long t = Stopwatch.GetTimestamp();
        base.FillRectangle(x, y, width, height);
        Done(DrawCostProbe.OpFillRect, t);
    }

    public override void FillRoundedRectangle(float x, float y, float width, float height, float cornerRadius)
    {
        long t = Stopwatch.GetTimestamp();
        base.FillRoundedRectangle(x, y, width, height, cornerRadius);
        Done(DrawCostProbe.OpFillRound, t);
    }

    public override void FillEllipse(float x, float y, float width, float height)
    {
        long t = Stopwatch.GetTimestamp();
        base.FillEllipse(x, y, width, height);
        Done(DrawCostProbe.OpFillEllipse, t);
    }

    public override void FillPath(PathF path, WindingMode windingMode)
    {
        long t = Stopwatch.GetTimestamp();
        base.FillPath(path, windingMode);
        Done(DrawCostProbe.OpFillPath, t);
    }

    public override void DrawRectangle(float x, float y, float width, float height)
    {
        long t = Stopwatch.GetTimestamp();
        base.DrawRectangle(x, y, width, height);
        Done(DrawCostProbe.OpDrawRect, t);
    }

    public override void DrawRoundedRectangle(float x, float y, float width, float height, float cornerRadius)
    {
        long t = Stopwatch.GetTimestamp();
        base.DrawRoundedRectangle(x, y, width, height, cornerRadius);
        Done(DrawCostProbe.OpDrawRound, t);
    }

    public override void DrawEllipse(float x, float y, float width, float height)
    {
        long t = Stopwatch.GetTimestamp();
        base.DrawEllipse(x, y, width, height);
        Done(DrawCostProbe.OpDrawEllipse, t);
    }

    public override void DrawLine(float x1, float y1, float x2, float y2)
    {
        long t = Stopwatch.GetTimestamp();
        base.DrawLine(x1, y1, x2, y2);
        Done(DrawCostProbe.OpDrawLine, t);
    }

    public override void DrawPath(PathF path)
    {
        long t = Stopwatch.GetTimestamp();
        base.DrawPath(path);
        Done(DrawCostProbe.OpDrawPath, t);
    }

    public override void DrawString(string value, float x, float y, float width, float height,
        HorizontalAlignment horizontalAlignment, VerticalAlignment verticalAlignment,
        float lineSpacingAdjustment = 0)
    {
        long t = Stopwatch.GetTimestamp();
        base.DrawString(value, x, y, width, height, horizontalAlignment, verticalAlignment,
            lineSpacingAdjustment);
        Done(DrawCostProbe.OpText, t);
    }

    public override void Translate(float tx, float ty)
    {
        long t = Stopwatch.GetTimestamp();
        base.Translate(tx, ty);
        Done(DrawCostProbe.OpTransform, t);
    }
}
#endif
