// Minimal frame probe for the reference app: one FPS line every 5 s plus the first-frame
// marker. Subscribing before the host runs (same ordering as hello-maui-app's probe) means the
// counters include the startup frames.
using Microsoft.OpenHarmony.Hosting;

namespace ReferenceLob;

internal static class FrameProbe
{
    private static long s_last = Environment.TickCount64;
    private static int s_frames;
    private static bool s_first = true;

    public static void Install()
    {
        OpenHarmonyBridge.Frame += OnFrame;
        OpenHarmonyBridge.WriteStatus("[ref] frame probe installed");
    }

    private static void OnFrame(OpenHarmonyFrameEventArgs args)
    {
        if (s_first)
        {
            s_first = false;
            OpenHarmonyBridge.WriteStatus($"[ref] first-frame tick={Environment.TickCount64}");
        }

        s_frames++;
        long now = Environment.TickCount64;
        long elapsed = now - s_last;
        if (elapsed >= 5000)
        {
            double fps = s_frames * 1000.0 / elapsed;
            OpenHarmonyBridge.WriteStatus($"[ref] fps={fps:F1} frames={s_frames} ms={elapsed}");
            s_frames = 0;
            s_last = now;
        }
    }
}
