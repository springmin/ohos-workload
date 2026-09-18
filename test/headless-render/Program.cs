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

// Disabled state: the same colour, dimmed by the renderer's 50% alpha.
Rect disabledFrame = ((Button)root.Children[4]).Frame;
Console.WriteLine($"  disabled button IsEnabled={((Button)root.Children[4]).IsEnabled} cornerRadius={((Button)root.Children[3]).CornerRadius} platformCorner={((OpenHarmonyView)button.Handler!.PlatformView!).CornerRadius}");
Color dimmed = canvas.GetPixel((int)(disabledFrame.X + disabledFrame.Width / 2), (int)(disabledFrame.Y + disabledFrame.Height / 2));
Color expectedDim = Blend(Colors.DarkSlateBlue, Colors.MediumSeaGreen, 0.5f);
Check("disabled button dimmed", dimmed, expectedDim, 20);

// CheckBox: the box stroke is drawn at the view's edge.
var check = (CheckBox)root.Children[5];
Rect checkFrame = check.Frame;
// The box is drawn inset (70% of the view, centred): sample its left edge.
var checkPlatform = check.Handler?.PlatformView as OpenHarmonyView;
RectF drawFrame = checkPlatform?.Frame ?? new RectF((float)checkFrame.X, (float)checkFrame.Y, (float)checkFrame.Width, (float)checkFrame.Height);
float boxSide = Math.Min(drawFrame.Width, drawFrame.Height) * 0.7f;
float boxLeft = drawFrame.X + (drawFrame.Width - boxSide) / 2f;
Console.WriteLine($"  checkbox virtual={checkFrame} draw={drawFrame} boxLeft={boxLeft:0}");
Check("checkbox box stroke", canvas.GetPixel((int)boxLeft + 1, (int)(drawFrame.Y + drawFrame.Height / 2)), Colors.White, 40);

// Rounded corners: the button's corner stays background while its centre is the fill.
Rect roundedFrame = buttonFrame;
Color corner = canvas.GetPixel((int)roundedFrame.X + 1, (int)roundedFrame.Y + 1);
Check("button rounded corner", corner, Colors.DarkSlateBlue, 0);

// Image: the blit destination is observed (pixels come from the native blitter).
Rect? imageDestination = null;
OpenHarmonyView.ImageDrawn = rect => imageDestination ??= new Rect(rect.X, rect.Y, rect.Width, rect.Height);
renderer.Render(page, 1080, 1920);
Rect imageFrame = ((Image)root.Children[6]).Frame;
Console.WriteLine($"  image frame={imageFrame} drawnAt={(imageDestination is { } d ? d.ToString() : "<none>")} bytes={(((Image)root.Children[6]).Handler?.PlatformView as OpenHarmonyView)?.ImageBytes?.Length ?? 0}");
bool imageOk = imageDestination is { } destination2 &&
               Math.Abs(destination2.X + destination2.Width / 2 - (imageFrame.X + imageFrame.Width / 2)) <= 1 &&
               Math.Abs(destination2.Y + destination2.Height / 2 - (imageFrame.Y + imageFrame.Height / 2)) <= 1;
Console.WriteLine($"  [{(imageOk ? "PASS" : "FAIL")}] image blit centred in its frame");
if (!imageOk)
{
    failures++;
}

Console.WriteLine($"  drawn pixel writes: {canvas.DrawnPixels}");
Color Blend(Color background, Color foreground, float alpha) => new(
    (float)(foreground.Red * alpha + background.Red * (1 - alpha)),
    (float)(foreground.Green * alpha + background.Green * (1 - alpha)),
    (float)(foreground.Blue * alpha + background.Blue * (1 - alpha)),
    1f);

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
            CornerRadius = 14,
        });
        var disabled = new Button
        {
            Text = "disabled",
            FontSize = 26,
            BackgroundColor = Colors.MediumSeaGreen,
            IsEnabled = false,
        };
        layout.Add(disabled);
        layout.Add(new CheckBox { IsChecked = true });
        string imagePath = Path.Combine(Path.GetTempPath(), "pixel-image.png");
        File.WriteAllBytes(imagePath, Convert.FromBase64String(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="));
        layout.Add(new Image { Source = ImageSource.FromFile(imagePath), HeightRequest = 64 });
        return new ContentPage { BackgroundColor = Colors.DarkSlateBlue, Content = layout };
    }
}
