// MAUI-style demo app for OpenHarmony: a small view tree (Label + counter Button + Label)
// rendered through the Microsoft.Maui.Graphics backend, driven by the platform lifecycle,
// XComponent surface, touch input and frame callbacks.
using Microsoft.OpenHarmony.Hosting;
using Microsoft.Maui.Graphics;
using HelloMaui;
using HostCanvas = Microsoft.OpenHarmony.Hosting.OpenHarmonyCanvas;
using MauiCanvas = Microsoft.OpenHarmony.Maui.Graphics.OpenHarmonyCanvas;

int clicks = 0;
bool needsFrame = true;
var status = new Label { Text = "Ready", FontSize = 28, TextColor = Colors.LightBlue };
var counter = new Button { Text = "Tap me", FontSize = 40 };
var title = new Label { Text = "MAUI-style UI on OpenHarmony", FontSize = 40 };

counter.Clicked = () =>
{
    clicks++;
    counter.Text = $"Tapped {clicks}x";
    status.Text = $"last tap #{clicks}";
    needsFrame = true;
    OpenHarmonyBridge.WriteStatus($"[hello-maui] button clicked ({clicks})");
};

var layout = new VerticalStackLayout { Padding = 32, Spacing = 24 };
layout.Children.Add(title);
layout.Children.Add(counter);
layout.Children.Add(status);

var canvas = new MauiCanvas();
int width = 0, height = 0;

void Render()
{
    if (width <= 0 || height <= 0 || !HostCanvas.Begin(width, height))
    {
        return;
    }
    canvas.FillColor = Colors.DarkSlateBlue;
    canvas.FillRectangle(0, 0, width, height);
    layout.Measure(width);
    layout.Draw(canvas);
    HostCanvas.Present();
    OpenHarmonyBridge.WriteStatus($"[hello-maui] rendered {width}x{height} (clicks={clicks})");
}

OpenHarmonyBridge.SurfaceChanged += info =>
{
    if (info.State == OpenHarmonySurfaceState.Created && info.Width > 0)
    {
        width = info.Width;
        height = info.Height;
        needsFrame = true;
        Render();
    }
};

OpenHarmonyBridge.Touch += args =>
{
    bool down = args.Action == OpenHarmonyTouchAction.Down;
    bool up = args.Action == OpenHarmonyTouchAction.Up;
    if (layout.OnTouch(down, up, args.X, args.Y))
    {
        needsFrame = true;
    }
};

OpenHarmonyBridge.Frame += _ =>
{
    if (needsFrame)
    {
        needsFrame = false;
        Render();
    }
};

OpenHarmonyBridge.WriteStatus("[hello-maui] app started");
using var finished = new ManualResetEventSlim(false);
OpenHarmonyBridge.LifecycleChanged += e =>
{
    OpenHarmonyBridge.WriteStatus($"[hello-maui] lifecycle {e}");
    if (e == OpenHarmonyLifecycleEvent.Destroy)
    {
        finished.Set();
    }
};
if (OpenHarmonyBridge.Context is not null)
{
    finished.Wait();
}
