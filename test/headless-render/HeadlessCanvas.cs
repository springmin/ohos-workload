// Managed ICanvas rasterizer for headless rendering assertions: fills a growable ARGB buffer so
// tests can check that the compositor really put the expected colours at the expected places.
using Microsoft.Maui.Graphics;
using MauiCanvas = Microsoft.OpenHarmony.Maui.Graphics.OpenHarmonyCanvas;

namespace HeadlessRender;

public sealed class HeadlessCanvas : MauiCanvas
{
    private uint[] _pixels = new uint[1024 * 1024];
    private int _width = 1024;
    private int _height = 1024;

    private float _offsetX;
    private float _offsetY;

    public int DrawnPixels { get; private set; }

    public Color GetPixel(int x, int y)
    {
        if (x < 0 || y < 0 || x >= _width || y >= _height)
        {
            return Colors.Transparent;
        }
        uint value = _pixels[y * _width + x];
        return Color.FromRgba(
            (byte)((value >> 16) & 0xFF), (byte)((value >> 8) & 0xFF), (byte)(value & 0xFF), (byte)((value >> 24) & 0xFF));
    }

    private void EnsureSize(int right, int bottom)
    {
        int width = Math.Max(_width, right + 1);
        int height = Math.Max(_height, bottom + 1);
        if (width == _width && height == _height)
        {
            return;
        }
        var grown = new uint[width * height];
        for (int y = 0; y < _height; y++)
        {
            Array.Copy(_pixels, y * _width, grown, y * width, _width);
        }
        _pixels = grown;
        _width = width;
        _height = height;
    }

    private void Blend(int x, int y, Color color)
    {
        if (x < 0 || y < 0)
        {
            return;
        }
        EnsureSize(x, y);
        byte a = (byte)Math.Clamp(color.Alpha * Alpha * 255f, 0, 255);
        if (a == 0)
        {
            return;
        }
        uint dst = _pixels[y * _width + x];
        byte dr = (byte)((dst >> 16) & 0xFF);
        byte dg = (byte)((dst >> 8) & 0xFF);
        byte db = (byte)(dst & 0xFF);
        byte sr = (byte)Math.Clamp(color.Red * 255f, 0, 255);
        byte sg = (byte)Math.Clamp(color.Green * 255f, 0, 255);
        byte sb = (byte)Math.Clamp(color.Blue * 255f, 0, 255);
        float t = a / 255f;
        byte r = (byte)(sr * t + dr * (1 - t));
        byte g = (byte)(sg * t + dg * (1 - t));
        byte b = (byte)(sb * t + db * (1 - t));
        byte outA = (byte)Math.Min(255, (dst >> 24) + a);
        _pixels[y * _width + x] = (uint)(outA << 24 | r << 16 | g << 8 | b);
        DrawnPixels++;
    }

    private (int X, int Y) Map(float x, float y) => ((int)MathF.Round(x + _offsetX), (int)MathF.Round(y + _offsetY));

    public override void FillPath(PathF path, WindingMode windingMode)
    {
        if (path.Points is null || !path.Points.Any())
        {
            return;
        }
        float minX = path.Points.Min(p => p.X), minY = path.Points.Min(p => p.Y);
        float maxX = path.Points.Max(p => p.X), maxY = path.Points.Max(p => p.Y);
        FillRectangle(minX, minY, Math.Max(1, maxX - minX), Math.Max(1, maxY - minY));
    }

    public override void DrawPath(PathF path)
        => FillPath(path, WindingMode.NonZero);

    public override void FillRectangle(float x, float y, float width, float height)
    {
        (int left, int top) = Map(x, y);
        for (int py = top; py < top + (int)height; py++)
        {
            for (int px = left; px < left + (int)width; px++)
            {
                Blend(px, py, FillColor);
            }
        }
    }

    public override void DrawRectangle(float x, float y, float width, float height)
    {
        FillRectangle(x, y, width, StrokeSize);
        FillRectangle(x, y + height - StrokeSize, width, StrokeSize);
        FillRectangle(x, y, StrokeSize, height);
        FillRectangle(x + width - StrokeSize, y, StrokeSize, height);
    }

    public override void FillRoundedRectangle(float x, float y, float width, float height, float cornerRadius)
        => FillRectangle(x, y, width, height);

    public override void DrawRoundedRectangle(float x, float y, float width, float height, float cornerRadius)
        => DrawRectangle(x, y, width, height);

    public override void FillEllipse(float x, float y, float width, float height)
        => FillEllipseCore(x + width / 2f, y + height / 2f, Math.Min(width, height) / 2f);

    public override void DrawEllipse(float x, float y, float width, float height)
    {
        Color fill = FillColor;
        FillColor = StrokeColor;
        FillEllipseCore(x + width / 2f, y + height / 2f, Math.Min(width, height) / 2f);
        FillColor = fill;
    }

    private void FillEllipseCore(float centerX, float centerY, float radius)
    {
        (int cx, int cy) = Map(centerX - radius, centerY - radius);
        int r = Math.Max(1, (int)radius);
        for (int py = -r; py <= r; py++)
        {
            for (int px = -r; px <= r; px++)
            {
                if (px * px + py * py <= r * r)
                {
                    Blend(cx + r + px, cy + r + py, FillColor);
                }
            }
        }
    }



    public override void DrawLine(float x1, float y1, float x2, float y2)
    {
        Color saved = FillColor;
        FillColor = StrokeColor;
        int steps = (int)Math.Max(Math.Abs(x2 - x1), Math.Abs(y2 - y1));
        for (int i = 0; i <= steps; i++)
        {
            float t = steps == 0 ? 0 : (float)i / steps;
            FillRectangle(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, Math.Max(1, StrokeSize), Math.Max(1, StrokeSize));
        }
        FillColor = saved;
    }

    public override void DrawString(string value, float x, float y, float width, float height,
        HorizontalAlignment horizontalAlignment, VerticalAlignment verticalAlignment, float lineSpacingAdjustment = 0)
    {
        // Text is approximated by a marker bar in the font colour inside the string box, which is
        // enough to assert "text was drawn here, in this colour".
        Color saved = FillColor;
        FillColor = FontColor;
        float barHeight = Math.Max(1, FontSize * 0.12f);
        float startY = y + height - barHeight - 1;
        FillRectangle(x + 2, startY, Math.Max(4, value.Length * FontSize * 0.5f), barHeight);
        FillColor = saved;
    }


    public override void Translate(float tx, float ty)
    {
        _offsetX += tx;
        _offsetY += ty;
    }

    public override void ClipRectangle(float x, float y, float width, float height)
    {
        // Clipping is not modelled: headless assertions look inside the drawn regions only.
    }
}
