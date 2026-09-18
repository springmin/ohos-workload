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
Check("page background", canvas.GetPixel(4, 4), Colors.DarkSlateBlue);
Rect headingFrame = heading.Frame;
Check("heading text marker", canvas.GetPixel((int)(headingFrame.X + 8), (int)(headingFrame.Y + headingFrame.Height - 4)), Colors.White);
Rect borderFrame = border.Frame;
Check("border stroke", canvas.GetPixel((int)borderFrame.X + 2, (int)(borderFrame.Y + borderFrame.Height / 2)), Colors.DodgerBlue);
Rect rectFrame = rectangle.Frame;
Check("rectangle fill", canvas.GetPixel((int)(rectFrame.X + rectFrame.Width / 2), (int)(rectFrame.Y + rectFrame.Height / 2)), Colors.OrangeRed);

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
        return new ContentPage { BackgroundColor = Colors.DarkSlateBlue, Content = layout };
    }
}
