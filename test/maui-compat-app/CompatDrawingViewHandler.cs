// Minimal DrawingView backend for the OpenHarmony slice. The toolkit ships handlers only for
// Android/iOS/MacCatalyst/Windows; this handler paints the recorded lines with the slice's
// MauiCanvas and is selected through the connector's third-party fallback (ConfigureMauiHandlers).
using CommunityToolkit.Maui.Views;
using Microsoft.Maui.Graphics;
using Microsoft.Maui.Platform;
using Microsoft.OpenHarmony.Hosting;
using MauiCanvas = Microsoft.OpenHarmony.Maui.Graphics.OpenHarmonyCanvas;

namespace CompatApp;

public sealed class CompatDrawingViewHandler : OpenHarmonyViewHandler<DrawingView>
{
    public static readonly IPropertyMapper<DrawingView, CompatDrawingViewHandler> Mapper =
        new PropertyMapper<DrawingView, CompatDrawingViewHandler>(ViewMapper)
        {
            [nameof(DrawingView.Lines)] = MapRedraw,
            [nameof(DrawingView.LineColor)] = MapRedraw,
            [nameof(DrawingView.LineWidth)] = MapRedraw,
        };

    public CompatDrawingViewHandler() : base(Mapper) { }

    protected override OpenHarmonyView CreatePlatformView() => new DrawingPlatformView();

    public override Size GetDesiredSize(double widthConstraint, double heightConstraint)
    {
        var element = VirtualView as VisualElement;
        double width = element?.WidthRequest > 0 ? element.WidthRequest : Math.Min(320, widthConstraint);
        double height = element?.HeightRequest > 0 ? element.HeightRequest : Math.Min(100, heightConstraint);
        return new Size(Math.Min(width, widthConstraint), Math.Min(height, heightConstraint));
    }

    private static void MapRedraw(CompatDrawingViewHandler handler, DrawingView view)
    {
        if (handler.PlatformView is DrawingPlatformView platform)
        {
            platform.Source = view;
        }
        OpenHarmonyBridge.RequestRedraw();
    }
}

internal sealed class DrawingPlatformView : OpenHarmonyView
{
    public DrawingView? Source { get; set; }

    public override void Draw(MauiCanvas canvas)
    {
        base.Draw(canvas);
        if (Source is null)
        {
            return;
        }

        canvas.SaveState();
        canvas.StrokeColor = Source.LineColor ?? Colors.Red;
        canvas.StrokeSize = (float)Source.LineWidth;
        canvas.StrokeLineCap = LineCap.Round;
        foreach (var line in Source.Lines)
        {
            var points = line.Points;
            if (points.Count < 2)
            {
                continue;
            }
            var path = new PathF();
            path.MoveTo(points[0].X, points[0].Y);
            for (int i = 1; i < points.Count; i++)
            {
                path.LineTo(points[i].X, points[i].Y);
            }
            canvas.DrawPath(path);
        }
        canvas.RestoreState();
    }
}
