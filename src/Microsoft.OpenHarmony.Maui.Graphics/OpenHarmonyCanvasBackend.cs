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
public class OpenHarmonyCanvas : ICanvas
{
    private readonly Stack<Matrix3x2> _savedStates = new();
    private Matrix3x2 _transform = Matrix3x2.Identity;
    private Color _strokeColor = Colors.Black;
    private Color _fillColor = Colors.Black;
    private Color _fontColor = Colors.Black;
    private float _alpha = 1f;
    private IPattern? _proceduralPattern;
    private RectF _patternRect;

    public float DisplayScale { get; set; } = 1f;
    public float StrokeSize { get; set; } = 1f;
    public float MiterLimit { get; set; } = 4f;
    public Color StrokeColor { get => _strokeColor; set => _strokeColor = value; }
    public LineCap StrokeLineCap { get; set; } = LineCap.Butt;
    public LineJoin StrokeLineJoin { get; set; } = LineJoin.Miter;
    public float[]? StrokeDashPattern { get; set; }
    public float StrokeDashOffset { get; set; }
    public Color FillColor
    {
        get => _fillColor;
        set
        {
            _fillColor = value;
            HostCanvas.ClearEffects();
        }
    }
    public Color FontColor { get => _fontColor; set => _fontColor = value; }
    public IFont? Font { get; set; }
    public float FontSize { get; set; } = 14f;
    public float Alpha { get => _alpha; set => _alpha = Math.Clamp(value, 0f, 1f); }
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

    /// <summary>Transforms one point into a packed x,y pair of a caller-owned span, so the
    /// primitive draws never build a params tuple array or a per-call float[].</summary>
    private void WritePoint(Span<float> xy, int index, float x, float y)
    {
        Vector2 p = P(x, y);
        xy[index * 2] = p.X;
        xy[index * 2 + 1] = p.Y;
    }

    private void Stroke(ReadOnlySpan<float> xy, bool closed)
        => HostCanvas.Polyline(xy, closed, ToArgb(_strokeColor, _alpha), filled: false, StrokeSize * DisplayScale);

    private void Fill(ReadOnlySpan<float> xy)
        => HostCanvas.Polyline(xy, closed: true, ToArgb(_fillColor, _alpha), filled: true);

    // ---------------------------------------------------------------- paths
    // The flattened polygon is kept in one buffer sized like the last path. A canvas is drawn
    // on one thread, every caller hands the buffer to a synchronous native call before the next
    // Flatten() can run, and no application code (pattern callbacks, subclasses) runs in
    // between, so the reuse cannot alias a live polygon. A path whose point count changes
    // reallocates once, then repeats at the new size.
    private float[] _pathXY = Array.Empty<float>();

    private float[] Flatten(PathF path)
    {
        // Flatten curves to a polygon the native canvas can stroke/fill in one path.
        PathF flat = path.GetFlattenedPath(0.25f, false);
        int floats = flat.Count * 2;
        if (_pathXY.Length != floats)
        {
            _pathXY = new float[floats];
        }
        for (int i = 0; i < flat.Count; i++)
        {
            PointF point = flat[i];
            Vector2 p = P(point.X, point.Y);
            _pathXY[i * 2] = p.X;
            _pathXY[i * 2 + 1] = p.Y;
        }
        return _pathXY;
    }

    public virtual void DrawPath(PathF path) => Stroke(Flatten(path), closed: true);
    public virtual void FillPath(PathF path, WindingMode windingMode) => Fill(Flatten(path));

    // ---------------------------------------------------------------- state
    public virtual void SaveState()
    {
        _savedStates.Push(_transform);
        HostCanvas.Save();
    }

    public virtual bool RestoreState()
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
    public virtual void Translate(float tx, float ty) => _transform = Matrix3x2.CreateTranslation(tx, ty) * _transform;
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

    public virtual void ClipRectangle(float x, float y, float width, float height)
    {
        Vector2 topLeft = P(x, y);
        Vector2 bottomRight = P(x + width, y + height);
        HostCanvas.ClipRect(topLeft.X, topLeft.Y, bottomRight.X - topLeft.X, bottomRight.Y - topLeft.Y);
    }

    // ---------------------------------------------------------------- primitives
    public virtual void DrawLine(float x1, float y1, float x2, float y2)
    {
        Span<float> xy = stackalloc float[4];
        WritePoint(xy, 0, x1, y1);
        WritePoint(xy, 1, x2, y2);
        Stroke(xy, closed: false);
    }

    public virtual void DrawRectangle(float x, float y, float width, float height)
    {
        Span<float> xy = stackalloc float[8];
        WriteRectangle(xy, x, y, width, height);
        Stroke(xy, closed: true);
    }

    public virtual void FillRectangle(float x, float y, float width, float height)
    {
        if (TryFillWithPattern(x, y, width, height))
        {
            return;
        }
        Span<float> xy = stackalloc float[8];
        WriteRectangle(xy, x, y, width, height);
        Fill(xy);
    }

    /// <summary>Top-left, top-right, bottom-right, bottom-left as packed x,y pairs.</summary>
    private void WriteRectangle(Span<float> xy, float x, float y, float width, float height)
    {
        WritePoint(xy, 0, x, y);
        WritePoint(xy, 1, x + width, y);
        WritePoint(xy, 2, x + width, y + height);
        WritePoint(xy, 3, x, y + height);
    }

    public virtual void DrawRoundedRectangle(float x, float y, float width, float height, float cornerRadius)
        => Stroke(RoundedPoints(x, y, width, height, cornerRadius), closed: true);

    public virtual void FillRoundedRectangle(float x, float y, float width, float height, float cornerRadius)
        => Fill(RoundedPoints(x, y, width, height, cornerRadius));

    private const int RoundedSteps = 6;

    // One buffer per shape family, sized for exactly the points the builder emits. The native
    // call reads it synchronously and no application code runs between a builder and its call,
    // so reuse cannot alias a live polygon (same invariant as _pathXY above).
    private readonly float[] _roundedXY = new float[(RoundedSteps + 1) * 4 * 2];

    private float[] RoundedPoints(float x, float y, float width, float height, float radius)
    {
        float r = Math.Min(radius, Math.Min(width, height) / 2f);
        int index = 0;
        Corner(_roundedXY, ref index, x + width - r, y + r, -Math.PI / 2, r);          // top-right
        Corner(_roundedXY, ref index, x + width - r, y + height - r, 0, r);            // bottom-right
        Corner(_roundedXY, ref index, x + r, y + height - r, Math.PI / 2, r);          // bottom-left
        Corner(_roundedXY, ref index, x + r, y + r, Math.PI, r);                       // top-left
        return _roundedXY;
    }

    private void Corner(Span<float> xy, ref int index, float cx, float cy, double startAngle, float r)
    {
        for (int i = 0; i <= RoundedSteps; i++)
        {
            double a = startAngle + Math.PI / 2 * i / RoundedSteps;
            WritePoint(xy, index++, cx + (float)(r * Math.Cos(a)), cy + (float)(r * Math.Sin(a)));
        }
    }

    public virtual void DrawEllipse(float x, float y, float width, float height)
    {
        Vector2 c = P(x + width / 2f, y + height / 2f);
        HostCanvas.Ellipse(c.X, c.Y, width / 2f, height / 2f,
            ToArgb(_strokeColor, _alpha), filled: false, StrokeSize * DisplayScale);
    }

    public virtual void FillEllipse(float x, float y, float width, float height)
    {
        Vector2 c = P(x + width / 2f, y + height / 2f);
        HostCanvas.Ellipse(c.X, c.Y, width / 2f, height / 2f,
            ToArgb(_fillColor, _alpha), filled: true);
    }

    public void DrawArc(float x, float y, float width, float height, float startAngle, float endAngle, bool clockwise, bool closed)
        => Stroke(ArcPoints(x, y, width, height, startAngle, endAngle, clockwise), closed);

    public void FillArc(float x, float y, float width, float height, float startAngle, float endAngle, bool clockwise)
        => Fill(ArcPoints(x, y, width, height, startAngle, endAngle, clockwise));

    private const int ArcSteps = 32;

    private readonly float[] _arcXY = new float[(ArcSteps + 1) * 2];

    private float[] ArcPoints(float x, float y, float width, float height, float startAngle, float endAngle, bool clockwise)
    {
        float cx = x + width / 2f, cy = y + height / 2f;
        float rx = width / 2f, ry = height / 2f;
        float from = startAngle * MathF.PI / 180f;
        float to = endAngle * MathF.PI / 180f;
        for (int i = 0; i <= ArcSteps; i++)
        {
            float t = clockwise ? from + (to - from) * i / ArcSteps : from - (to - from) * i / ArcSteps;
            WritePoint(_arcXY, i, cx + rx * MathF.Cos(t), cy + ry * MathF.Sin(t));
        }
        return _arcXY;
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

    public virtual void DrawString(string value, float x, float y, float width, float height,
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
        _patternRect = rectangle;
        ApplyPaint(paint);
    }

    private void ApplyPaint(Paint paint)
    {
        switch (paint)
        {
            case SolidPaint solid when solid.Color is not null:
                _proceduralPattern = null;
                _fillColor = solid.Color;
                HostCanvas.ClearEffects();
                break;
            case LinearGradientPaint linear:
                _proceduralPattern = null;
                SetGradient(linear.GradientStops, linear.StartColor, linear.EndColor,
                    (float)linear.StartPoint.X, (float)linear.StartPoint.Y,
                    (float)linear.EndPoint.X, (float)linear.EndPoint.Y, isRadial: false);
                break;
            case RadialGradientPaint radial:
                _proceduralPattern = null;
                SetGradient(radial.GradientStops, radial.StartColor, radial.EndColor,
                    (float)radial.Center.X, (float)radial.Center.Y, (float)radial.Radius, 0f, isRadial: true);
                break;
            case ImagePaint imagePaint when imagePaint.Image is not null:
                _proceduralPattern = null;
                using (var stream = new MemoryStream())
                {
                    imagePaint.Image.Save(stream, ImageFormat.Png);
                    HostCanvas.SetImagePattern(stream.ToArray());
                }
                break;
            case PatternPaint patternPaint:
                // A pattern wrapping a paint recurses; anything else is a procedural pattern
                // that the fill operations tile themselves.
                if (patternPaint.Pattern is PaintPattern wrapper)
                {
                    ApplyPaint(wrapper.Paint);
                }
                else
                {
                    _proceduralPattern = patternPaint.Pattern;
                }
                break;
            default:
                break;
        }
    }

    /// <summary>Tiles a procedural pattern (IPattern.Draw) over a rectangle by clipping and
    /// translating the canvas, which is how a thin backend can honour PatternPaint.</summary>
    private bool TryFillWithPattern(float x, float y, float width, float height)
    {
        IPattern? pattern = _proceduralPattern;
        if (pattern is null)
        {
            return false;
        }
        float stepX = MathF.Max(pattern.StepX, 1f);
        float stepY = MathF.Max(pattern.StepY, 1f);
        SaveState();
        ClipRectangle(x, y, width, height);
        for (float ty = _patternRect.Y; ty < _patternRect.Bottom + stepY; ty += stepY)
        {
            for (float tx = _patternRect.X; tx < _patternRect.Right + stepX; tx += stepX)
            {
                SaveState();
                Translate(tx, ty);
                pattern.Draw(this);
                RestoreState();
            }
        }
        RestoreState();
        return true;
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
