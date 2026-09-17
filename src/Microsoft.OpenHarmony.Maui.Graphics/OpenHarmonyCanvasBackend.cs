// Microsoft.Maui.Graphics backend over the OpenHarmony platform canvas
// (Microsoft.OpenHarmony.Hosting.OpenHarmonyCanvas -> native_drawing).
//
// The backend is deliberately thin: shapes are mapped to the platform's Skia-backed
// primitives, curves are flattened, and features the bridge does not expose yet
// (clipping, shadows, images, gradients) are tracked or ignored with a documented status.
using System.Numerics;
using Microsoft.Maui.Graphics;
using Microsoft.Maui.Graphics.Text;
using Microsoft.OpenHarmony.Hosting;
using HostCanvas = Microsoft.OpenHarmony.Hosting.OpenHarmonyCanvas;

namespace Microsoft.OpenHarmony.Maui.Graphics;

/// <summary>An <see cref="ICanvas"/> that draws into the ArkUI XComponent surface.</summary>
public sealed class OpenHarmonyCanvas : ICanvas
{
    private readonly Stack<Matrix3x2> _savedStates = new();
    private Matrix3x2 _transform = Matrix3x2.Identity;
    private Color _strokeColor = Colors.Black;
    private Color _fillColor = Colors.Black;
    private Color _fontColor = Colors.Black;
    private float _alpha = 1f;

    public float DisplayScale { get; set; } = 1f;
    public float StrokeSize { get; set; } = 1f;
    public float MiterLimit { get; set; } = 4f;
    public Color StrokeColor { set => _strokeColor = value; }
    public LineCap StrokeLineCap { get; set; } = LineCap.Butt;
    public LineJoin StrokeLineJoin { get; set; } = LineJoin.Miter;
    public float[]? StrokeDashPattern { get; set; }
    public float StrokeDashOffset { get; set; }
    public Color FillColor
    {
        set
        {
            _fillColor = value;
            HostCanvas.ClearEffects();
        }
    }
    public Color FontColor { set => _fontColor = value; }
    public IFont? Font { get; set; }
    public float FontSize { get; set; } = 14f;
    public float Alpha { set => _alpha = Math.Clamp(value, 0f, 1f); }
    public bool Antialias { get; set; } = true;
    public BlendMode BlendMode { get; set; } = BlendMode.Normal;

    // ---------------------------------------------------------------- helpers
    private static uint ToArgb(Color color, float alpha)
    {
        uint a = (uint)Math.Clamp(color.Alpha * alpha * 255f, 0f, 255f);
        uint r = (uint)Math.Clamp(color.Red * 255f, 0f, 255f);
        uint g = (uint)Math.Clamp(color.Green * 255f, 0f, 255f);
        uint b = (uint)Math.Clamp(color.Blue * 255f, 0f, 255f);
        return (a << 24) | (r << 16) | (g << 8) | b;
    }

    private Vector2 P(float x, float y) => Vector2.Transform(new Vector2(x, y), _transform);

    private float[] Points(params (float X, float Y)[] points)
    {
        var xy = new float[points.Length * 2];
        for (int i = 0; i < points.Length; i++)
        {
            Vector2 p = P(points[i].X, points[i].Y);
            xy[i * 2] = p.X;
            xy[i * 2 + 1] = p.Y;
        }
        return xy;
    }

    private void Stroke(float[] xy, bool closed)
        => HostCanvas.Polyline(xy, closed, ToArgb(_strokeColor, _alpha), filled: false, StrokeSize * DisplayScale);

    private void Fill(float[] xy)
        => HostCanvas.Polyline(xy, closed: true, ToArgb(_fillColor, _alpha), filled: true);

    // ---------------------------------------------------------------- paths
    private float[] Flatten(PathF path)
    {
        // Flatten curves to a polygon the native canvas can stroke/fill in one path.
        PathF flat = path.GetFlattenedPath(0.25f, false);
        var xy = new float[flat.Count * 2];
        for (int i = 0; i < flat.Count; i++)
        {
            PointF point = flat[i];
            Vector2 p = P(point.X, point.Y);
            xy[i * 2] = p.X;
            xy[i * 2 + 1] = p.Y;
        }
        return xy;
    }

    public void DrawPath(PathF path) => Stroke(Flatten(path), closed: true);
    public void FillPath(PathF path, WindingMode windingMode) => Fill(Flatten(path));

    // ---------------------------------------------------------------- state
    public void SaveState()
    {
        _savedStates.Push(_transform);
        HostCanvas.Save();
    }

    public bool RestoreState()
    {
        if (_savedStates.Count == 0)
        {
            return false;
        }
        _transform = _savedStates.Pop();
        HostCanvas.Restore();
        return true;
    }

    public void ResetState()
    {
        while (_savedStates.Count > 0)
        {
            _savedStates.Pop();
            HostCanvas.Restore();
        }
        _transform = Matrix3x2.Identity;
    }

    public void Rotate(float degrees, float x, float y)
    {
        Vector2 center = P(x, y);
        _transform = Matrix3x2.CreateRotation(degrees * MathF.PI / 180f, center) * _transform;
    }

    public void Rotate(float degrees)
        => _transform = Matrix3x2.CreateRotation(degrees * MathF.PI / 180f) * _transform;

    public void Scale(float sx, float sy) => _transform = Matrix3x2.CreateScale(sx, sy) * _transform;
    public void Translate(float tx, float ty) => _transform = Matrix3x2.CreateTranslation(tx, ty) * _transform;
    public void ConcatenateTransform(Matrix3x2 transform) => _transform = transform * _transform;

    // ---------------------------------------------------------------- clipping
    public void SubtractFromClip(float x, float y, float width, float height)
    {
        Vector2 topLeft = P(x, y);
        Vector2 bottomRight = P(x + width, y + height);
        HostCanvas.ClipRect(topLeft.X, topLeft.Y, bottomRight.X - topLeft.X, bottomRight.Y - topLeft.Y, subtract: true);
    }

    public void ClipPath(PathF path, WindingMode windingMode = WindingMode.NonZero)
        => HostCanvas.ClipPolyline(Flatten(path));

    public void ClipRectangle(float x, float y, float width, float height)
    {
        Vector2 topLeft = P(x, y);
        Vector2 bottomRight = P(x + width, y + height);
        HostCanvas.ClipRect(topLeft.X, topLeft.Y, bottomRight.X - topLeft.X, bottomRight.Y - topLeft.Y);
    }

    // ---------------------------------------------------------------- primitives
    public void DrawLine(float x1, float y1, float x2, float y2)
        => Stroke(Points((x1, y1), (x2, y2)), closed: false);

    public void DrawRectangle(float x, float y, float width, float height)
        => Stroke(Points((x, y), (x + width, y), (x + width, y + height), (x, y + height)), closed: true);

    public void FillRectangle(float x, float y, float width, float height)
        => Fill(Points((x, y), (x + width, y), (x + width, y + height), (x, y + height)));

    public void DrawRoundedRectangle(float x, float y, float width, float height, float cornerRadius)
        => Stroke(RoundedPoints(x, y, width, height, cornerRadius), closed: true);

    public void FillRoundedRectangle(float x, float y, float width, float height, float cornerRadius)
        => Fill(RoundedPoints(x, y, width, height, cornerRadius));

    private float[] RoundedPoints(float x, float y, float width, float height, float radius)
    {
        float r = Math.Min(radius, Math.Min(width, height) / 2f);
        const int steps = 6;
        var points = new List<(float, float)>();
        void Corner(float cx, float cy, double startAngle)
        {
            for (int i = 0; i <= steps; i++)
            {
                double a = startAngle + Math.PI / 2 * i / steps;
                points.Add((cx + (float)(r * Math.Cos(a)), cy + (float)(r * Math.Sin(a))));
            }
        }
        Corner(x + width - r, y + r, -Math.PI / 2);          // top-right
        Corner(x + width - r, y + height - r, 0);            // bottom-right
        Corner(x + r, y + height - r, Math.PI / 2);          // bottom-left
        Corner(x + r, y + r, Math.PI);                       // top-left
        return Points(points.ToArray());
    }

    public void DrawEllipse(float x, float y, float width, float height)
    {
        Vector2 c = P(x + width / 2f, y + height / 2f);
        HostCanvas.Ellipse(c.X, c.Y, width / 2f, height / 2f,
            ToArgb(_strokeColor, _alpha), filled: false, StrokeSize * DisplayScale);
    }

    public void FillEllipse(float x, float y, float width, float height)
    {
        Vector2 c = P(x + width / 2f, y + height / 2f);
        HostCanvas.Ellipse(c.X, c.Y, width / 2f, height / 2f,
            ToArgb(_fillColor, _alpha), filled: true);
    }

    public void DrawArc(float x, float y, float width, float height, float startAngle, float endAngle, bool clockwise, bool closed)
        => Stroke(ArcPoints(x, y, width, height, startAngle, endAngle, clockwise), closed);

    public void FillArc(float x, float y, float width, float height, float startAngle, float endAngle, bool clockwise)
        => Fill(ArcPoints(x, y, width, height, startAngle, endAngle, clockwise));

    private float[] ArcPoints(float x, float y, float width, float height, float startAngle, float endAngle, bool clockwise)
    {
        float cx = x + width / 2f, cy = y + height / 2f;
        float rx = width / 2f, ry = height / 2f;
        float from = startAngle * MathF.PI / 180f;
        float to = endAngle * MathF.PI / 180f;
        const int steps = 32;
        var points = new List<(float, float)>();
        for (int i = 0; i <= steps; i++)
        {
            float t = clockwise ? from + (to - from) * i / steps : from - (to - from) * i / steps;
            points.Add((cx + rx * MathF.Cos(t), cy + ry * MathF.Sin(t)));
        }
        return Points(points.ToArray());
    }

    // ---------------------------------------------------------------- text
    public void DrawString(string value, float x, float y, HorizontalAlignment horizontalAlignment)
    {
        var size = GetStringSize(value, Font!, FontSize);
        float dx = horizontalAlignment switch
        {
            HorizontalAlignment.Center => -size.Width / 2f,
            HorizontalAlignment.Right => -size.Width,
            _ => 0f,
        };
        DrawString(value, x + dx, y, size.Width, size.Height, horizontalAlignment, VerticalAlignment.Top);
    }

    public void DrawString(string value, float x, float y, float width, float height,
        HorizontalAlignment horizontalAlignment, VerticalAlignment verticalAlignment, float lineSpacingAdjustment = 0)
    {
        var size = GetStringSize(value, Font!, FontSize);
        float dx = horizontalAlignment switch
        {
            HorizontalAlignment.Center => (width - size.Width) / 2f,
            HorizontalAlignment.Right => width - size.Width,
            _ => 0f,
        };
        float dy = verticalAlignment switch
        {
            VerticalAlignment.Center => (height - size.Height) / 2f + size.Height,
            VerticalAlignment.Bottom => height,
            _ => size.Height,
        };
        Vector2 p = P(x + dx, y + dy);
        HostCanvas.DrawText((int)p.X, (int)p.Y, value, FontSize * DisplayScale, ToArgb(_fontColor, _alpha));
    }

    public void DrawString(string value, float x, float y, float width, float height,
        HorizontalAlignment horizontalAlignment, VerticalAlignment verticalAlignment,
        TextFlow textFlow, float lineSpacingAdjustment = 0)
        => DrawString(value, x, y, width, height, horizontalAlignment, verticalAlignment, lineSpacingAdjustment);

    public void DrawText(IAttributedText value, float x, float y, float width, float height)
    {
        DrawString(value.Text, x, y, width, height, HorizontalAlignment.Left, VerticalAlignment.Top);
    }

    // Platform metrics when available, otherwise an estimate.
    public SizeF GetStringSize(string value, IFont font, float fontSize)
    {
        if (string.IsNullOrEmpty(value))
        {
            return SizeF.Zero;
        }
        if (HostCanvas.MeasureText(value, fontSize * DisplayScale, out int width, out int height) && width > 0)
        {
            return new SizeF(width / DisplayScale, height / DisplayScale);
        }
        return new SizeF(value.Length * fontSize * 0.55f, fontSize * 1.25f);
    }

    public SizeF GetStringSize(string value, IFont font, float fontSize,
        HorizontalAlignment horizontalAlignment, VerticalAlignment verticalAlignment)
        => GetStringSize(value, font, fontSize);

    // ---------------------------------------------------------------- effects
    public void SetShadow(SizeF offset, float blur, Color color)
        => HostCanvas.SetShadow(offset.Width, offset.Height, blur, ToArgb(color, _alpha));

    public void SetFillPaint(Paint paint, RectF rectangle)
    {
        switch (paint)
        {
            case SolidPaint solid when solid.Color is not null:
                _fillColor = solid.Color;
                HostCanvas.ClearEffects();
                break;
            case LinearGradientPaint linear:
                SetGradient(linear.GradientStops, linear.StartColor, linear.EndColor,
                    (float)linear.StartPoint.X, (float)linear.StartPoint.Y,
                    (float)linear.EndPoint.X, (float)linear.EndPoint.Y, isRadial: false);
                break;
            case RadialGradientPaint radial:
                SetGradient(radial.GradientStops, radial.StartColor, radial.EndColor,
                    (float)radial.Center.X, (float)radial.Center.Y, (float)radial.Radius, 0f, isRadial: true);
                break;
            default:
                // PatternPaint and other paints are not mapped yet; the current fill colour stays.
                break;
        }
    }

    private void SetGradient(PaintGradientStop[]? stops, Color? startColor, Color? endColor,
        float x0, float y0, float x1, float y1, bool isRadial)
    {
        var colors = new List<uint>();
        var positions = new List<float>();
        if (stops is { Length: > 0 })
        {
            foreach (PaintGradientStop stop in stops)
            {
                colors.Add(ToArgb(stop.Color, _alpha));
                positions.Add(stop.Offset);
            }
        }
        else
        {
            colors.Add(ToArgb(startColor ?? _fillColor, _alpha));
            positions.Add(0f);
            colors.Add(ToArgb(endColor ?? _fillColor, _alpha));
            positions.Add(1f);
        }
        if (colors.Count < 2)
        {
            return;
        }
        Vector2 p0 = P(x0, y0);
        if (isRadial == true)
        {
            HostCanvas.SetRadialGradient(p0.X, p0.Y, x1, colors.ToArray(), positions.ToArray());
        }
        else
        {
            Vector2 p1 = P(x1, y1);
            HostCanvas.SetLinearGradient(p0.X, p0.Y, p1.X, p1.Y, colors.ToArray(), positions.ToArray());
        }
    }
    public void DrawImage(IImage image, float x, float y, float width, float height)
    {
        if (image is null)
        {
            return;
        }
        try
        {
            using var stream = new MemoryStream();
            image.Save(stream, ImageFormat.Png);
            Vector2 topLeft = P(x, y);
            Vector2 bottomRight = P(x + width, y + height);
            HostCanvas.DrawImageBytes(stream.ToArray(), (int)topLeft.X, (int)topLeft.Y,
                (int)(bottomRight.X - topLeft.X), (int)(bottomRight.Y - topLeft.Y));
        }
        catch
        {
            // Decoding failures must not take the frame down.
        }
    }
}
