// Simple bar chart drawn with Microsoft.Maui.Graphics (no Skia/native dependency).
using Microsoft.Maui.Graphics;

namespace ReferenceLob;

public sealed class ChartDrawable : IDrawable
{
    public ChartDrawable(float[] values) => Values = values;

    public float[] Values { get; set; }

    public void Draw(ICanvas canvas, RectF dirtyRect)
    {
        canvas.SaveState();
        float width = dirtyRect.Width;
        float height = dirtyRect.Height;
        if (width <= 0 || height <= 0 || Values.Length == 0)
        {
            canvas.RestoreState();
            return;
        }

        float max = 1;
        foreach (float value in Values)
        {
            max = Math.Max(max, value);
        }

        float slot = width / Values.Length;
        float barWidth = Math.Max(6, slot * 0.55f);
        for (int i = 0; i < Values.Length; i++)
        {
            float barHeight = (height - 24) * (Values[i] / max);
            float x = i * slot + (slot - barWidth) / 2;
            float y = height - 24 - barHeight;
            canvas.FillColor = Color.FromArgb(i % 2 == 0 ? "#1B6EF3" : "#7BA7F7");
            canvas.FillRoundedRectangle(x, y, barWidth, barHeight, 4);
        }

        canvas.StrokeColor = Color.FromArgb("#C9D2E3");
        canvas.StrokeSize = 1;
        canvas.DrawLine(0, height - 20, width, height - 20);
        canvas.RestoreState();
    }
}
