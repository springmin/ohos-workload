// Headless rendering assertions: renders a small page through the real compositor into a
// managed rasterizer and checks that the expected colours landed at the expected places.
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Maui;
using Microsoft.Maui.Controls;
using Microsoft.Maui.Hosting;
using Microsoft.Maui.Platform;
using HeadlessRender;

var canvas = new HeadlessCanvas();
OpenHarmonyWindowRenderer.CanvasFactory = () => canvas;
// No device surface in this environment: report a virtual one so rendering runs.
OpenHarmonyWindowRenderer.SurfaceBegin = (_, _) => true;
OpenHarmonyWindowRenderer.SurfacePresent = () => { };

var builder = MauiApp.CreateBuilder();
builder.UseOpenHarmony();
builder.UseMauiApp<PixelApp>();
var app = builder.Build();
var host = app.Services.GetRequiredService<OpenHarmonyMauiAppHost>();
host.Run(app.Services.GetRequiredService<IApplication>());
host.Arrange(1080, 1920);

var renderer = app.Services.GetRequiredService<OpenHarmonyWindowRenderer>();
var page = (ContentPage)host.Window!.Content!;
var root = (VerticalStackLayout)page.Content!;
var heading = (Label)root.Children[0];
var button = (Button)root.Children[3];
var border = (Border)root.Children[1];
var rectangle = root.Children[2];
host.Arrange(1080, 1920);
bool rendered = renderer.Render(page, 1080, 1920);

int failures = 0;
void Check(string what, Color actual, Color expected, int tolerance = 24)
{
    bool ok = Math.Abs(actual.Red * 255 - expected.Red * 255) <= tolerance &&
              Math.Abs(actual.Green * 255 - expected.Green * 255) <= tolerance &&
              Math.Abs(actual.Blue * 255 - expected.Blue * 255) <= tolerance;
    Console.WriteLine($"  [{(ok ? "PASS" : "FAIL")}] {what}: got {actual.ToHex()} expected {expected.ToHex()}");
    if (!ok)
    {
        failures++;
    }
}

Console.WriteLine($"renderer.Render -> {rendered} (canvas 可能没有原生 surface，这不影响像素断言)");

// Background (page fill) and the three known controls from the test page.
Console.WriteLine($"  frames: heading={heading.Frame} border={border.Frame} rect={rectangle.Frame}");
for (int y = 0; y < 1920; y += 160)
{
    var row = new System.Text.StringBuilder();
    for (int x = 0; x < 1080; x += 120)
    {
        row.Append(canvas.GetPixel(x, y).ToArgbHex()).Append(' ');
    }
    Console.WriteLine($"  y={y,4}: {row}");
}
Rect headingFrame = heading.Frame;
Rect borderFrame = border.Frame;
Rect rectFrame = rectangle.Frame;
var rectPlatform = rectangle.Handler?.PlatformView as OpenHarmonyView;
var rectShape = rectPlatform?.Shape;
var rectPath = rectShape?.PathForBounds(new Microsoft.Maui.Graphics.RectF((float)rectFrame.X, (float)rectFrame.Y, (float)rectFrame.Width, (float)rectFrame.Height));
Console.WriteLine($"  rect platform frame={rectPlatform?.Frame} virtual={rectFrame} shape={rectShape?.GetType().Name} pathPoints={rectPath?.Points?.Count() ?? 0} first={(rectPath?.Points?.Any() == true ? rectPath.Points.First().ToString() : "-")}");
var borderPlatform = border.Handler?.PlatformView as OpenHarmonyView;
var borderPath = borderPlatform?.Shape?.PathForBounds(new Microsoft.Maui.Graphics.RectF((float)borderFrame.X, (float)borderFrame.Y, (float)borderFrame.Width, (float)borderFrame.Height));
Console.WriteLine($"  border platform frame={borderPlatform?.Frame} shape={borderPlatform?.Shape?.GetType().Name} pathPoints={borderPath?.Points?.Count() ?? 0} first={(borderPath?.Points?.Any() == true ? borderPath.Points.First().ToString() : "-")}");
var rectOrigin = rectShape?.PathForBounds(new Microsoft.Maui.Graphics.RectF(0, 0, 60, 60));
Console.WriteLine($"  rect at origin pathPoints={rectOrigin?.Points?.Count() ?? 0} first={(rectOrigin?.Points?.Any() == true ? rectOrigin.Points.First().ToString() : "-")}");

Check("page background", canvas.GetPixel(4, 4), Colors.DarkSlateBlue);
Check("heading text marker", canvas.GetPixel((int)(headingFrame.X + 8), (int)(headingFrame.Y + headingFrame.Height - 4)), Colors.White);
// Strokes are approximated by a ring, so sample the border's edge (not its interior).
Check("border stroke", canvas.GetPixel((int)borderFrame.X + 1, (int)(borderFrame.Y + borderFrame.Height / 2)), Colors.DodgerBlue);
Check("rectangle fill", canvas.GetPixel((int)(rectFrame.X + rectFrame.Width / 2), (int)(rectFrame.Y + rectFrame.Height / 2)), Colors.OrangeRed);

// Interaction state: pressing the button repaints it in the pressed colour.
Rect buttonFrame = button.Frame;
host.HandleTouch(true, false, (float)(buttonFrame.X + buttonFrame.Width / 2), (float)(buttonFrame.Y + buttonFrame.Height / 2));
renderer.Render(page, 1080, 1920);
Check("button pressed state",
    canvas.GetPixel((int)(buttonFrame.X + buttonFrame.Width / 2), (int)(buttonFrame.Y + buttonFrame.Height / 2)),
    Colors.OrangeRed);
host.HandleTouch(false, true, (float)(buttonFrame.X + buttonFrame.Width / 2), (float)(buttonFrame.Y + buttonFrame.Height / 2));

Console.WriteLine($"  drawn pixel writes: {canvas.DrawnPixels}");
Console.WriteLine(failures == 0 ? "PIXEL ASSERTIONS PASSED" : $"PIXEL ASSERTIONS FAILED ({failures})");
return failures == 0 ? 0 : 1;

public sealed class PixelApp : Application
{
    protected override Window CreateWindow(IActivationState? activationState) => new(BuildPage());

    private static ContentPage BuildPage()
    {
        var layout = new VerticalStackLayout { Padding = 24, Spacing = 12 };
        layout.Add(new Label { Text = "pixel check", FontSize = 32, TextColor = Colors.White });
        layout.Add(new Border
        {
            Stroke = Colors.DodgerBlue,
            StrokeThickness = 4,
            Padding = 8,
            HeightRequest = 80,
            Content = new Label { Text = "inside", FontSize = 24 },
        });
        layout.Add(new Microsoft.Maui.Controls.Shapes.Rectangle
        {
            WidthRequest = 60,
            HeightRequest = 60,
            Fill = Colors.OrangeRed,
        });
        layout.Add(new Button
        {
            Text = "press me",
            FontSize = 26,
            BackgroundColor = Colors.MediumSeaGreen,
        });
        return new ContentPage { BackgroundColor = Colors.DarkSlateBlue, Content = layout };
    }
}
