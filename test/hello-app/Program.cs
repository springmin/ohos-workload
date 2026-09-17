using System.Runtime.InteropServices;
using Microsoft.OpenHarmony.Hosting;
using HostCanvas = Microsoft.OpenHarmony.Hosting.OpenHarmonyCanvas;
using MauiCanvas = Microsoft.OpenHarmony.Maui.Graphics.OpenHarmonyCanvas;
using MauiColors = Microsoft.Maui.Graphics.Colors;
using MauiGraphics = Microsoft.Maui.Graphics.CanvasExtensions;
using MauiHorizontal = Microsoft.Maui.Graphics.HorizontalAlignment;
using Microsoft.Maui.Graphics;

string? outPath = Environment.GetEnvironmentVariable("HELLO_OUT");

// Bridged mode (inside a hap): the native host runs Main on the application's main
// thread, so Main must return quickly; the app keeps running on its own thread.
if (outPath is null)
{
    OpenHarmonyBridge.WriteStatus("hello-app Main entered");
    var worker = new Thread(() =>
    {
        OpenHarmonyBridge.Initialized += context =>
        {
            OpenHarmonyBridge.WriteStatus($"app initialized: appDir={context.AppDir} filesDir={context.FilesDir}");
            OpenHarmonyBridge.WriteStatus($"[hello-app] RID={RuntimeInformation.RuntimeIdentifier} ProcessorCount={Environment.ProcessorCount} IsOpenHarmony={Microsoft.OpenHarmony.OpenHarmonyRuntime.IsOpenHarmony}");
        };

        // ---- demo UI: a Label and a Button drawn through the MauiGraphics backend, with
        // touch input from the XComponent and frame-driven redraw (the handler pattern).
        bool buttonPressed = false;
        bool needsFrame = false;
        int surfaceWidth = 0, surfaceHeight = 0;
        var maui = new MauiCanvas();

        void DrawUi()
        {
            if (surfaceWidth <= 0 || surfaceHeight <= 0 || !HostCanvas.Begin(surfaceWidth, surfaceHeight))
            {
                return;
            }
            maui.FillColor = MauiColors.DarkSlateBlue;
            maui.FillRectangle(0, 0, surfaceWidth, surfaceHeight);
            maui.FillColor = buttonPressed ? MauiColors.OrangeRed : MauiColors.MediumSeaGreen;
            maui.FillRoundedRectangle(24, surfaceHeight - 140, surfaceWidth - 48, 96, 24);
            maui.FontColor = MauiColors.White;
            maui.FontSize = 40;
            maui.DrawString(buttonPressed ? "Touched!" : "Tap me", 48, surfaceHeight - 118, surfaceWidth - 96, 56, MauiHorizontal.Left, Microsoft.Maui.Graphics.VerticalAlignment.Center);
            maui.FontSize = 32;
            maui.DrawString("MAUI Graphics on OpenHarmony", 32, 32, surfaceWidth - 64, 48, MauiHorizontal.Left, Microsoft.Maui.Graphics.VerticalAlignment.Center);
            HostCanvas.Present();
            OpenHarmonyBridge.WriteStatus($"[hello-app] frame drawn (pressed={buttonPressed}) at {surfaceWidth}x{surfaceHeight}");
        }

        bool InButton(float x, float y) => x >= 24 && x <= surfaceWidth - 24 && y >= surfaceHeight - 140 && y <= surfaceHeight - 44;

        OpenHarmonyBridge.Touch += args =>
        {
            if (args.Action == OpenHarmonyTouchAction.Down && InButton(args.X, args.Y))
            {
                buttonPressed = true;
                needsFrame = true;
            }
            else if (args.Action == OpenHarmonyTouchAction.Up && buttonPressed)
            {
                needsFrame = true;
            }
        };

        OpenHarmonyBridge.Frame += args =>
        {
            if (needsFrame)
            {
                needsFrame = false;
                DrawUi();
            }
        };

        using var finished = new ManualResetEventSlim(false);
        OpenHarmonyBridge.LifecycleChanged += e =>
        {
            OpenHarmonyBridge.WriteStatus($"hello-app lifecycle: {e}");
            if (e == OpenHarmonyLifecycleEvent.Destroy)
            {
                finished.Set();
            }
        };

        if (OpenHarmonyBridge.Context is null)
        {
            finished.Wait(TimeSpan.FromSeconds(20));
        }
        else
        {
            finished.Wait();
        }
        OpenHarmonyBridge.WriteStatus("hello-app worker exiting");
    });
    worker.IsBackground = false;
    worker.Start();
    return 0;
}

File.WriteAllLines(outPath, new[]
{
    $"[hello-app] RID={RuntimeInformation.RuntimeIdentifier}",
    $"[hello-app] args=[{string.Join(",", args)}]",
    $"[hello-app] OSDescription={RuntimeInformation.OSDescription}",
    $"[hello-app] OSArchitecture={RuntimeInformation.OSArchitecture}",
    $"[hello-app] IsOpenHarmony={Microsoft.OpenHarmony.OpenHarmonyRuntime.IsOpenHarmony}",
    $"[hello-app] ProcessorCount={Environment.ProcessorCount}",
    $"[hello-app] TMPDIR={Path.GetTempPath()}",
    $"[hello-app] FrameworkDescription={RuntimeInformation.FrameworkDescription}",
});
return 0;
