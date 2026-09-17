// A tiny handler-shaped view model over the platform canvas: the same measure/arrange/draw/
// hit-test pattern MAUI handlers use, written without the MAUI repo so it can run on device
// today. The MAUI platform slice (Microsoft.Maui.Platform.OpenHarmony) reuses the same calls.
using Microsoft.Maui.Graphics;
using MauiCanvas = Microsoft.OpenHarmony.Maui.Graphics.OpenHarmonyCanvas;

namespace HelloMaui;

public abstract class Element
{
    public float X, Y, Width, Height;

    public abstract SizeF Measure(float availableWidth);
    public abstract void Draw(MauiCanvas canvas);
    public virtual bool HitTest(float x, float y) => x >= X && x <= X + Width && y >= Y && y <= Y + Height;
    public virtual bool OnTouch(bool down, bool up, float x, float y) => false;
}

public sealed class Label : Element
{
    public string Text = string.Empty;
    public float FontSize = 32;
    public Color TextColor = Colors.White;

    public override SizeF Measure(float availableWidth) => new(availableWidth, FontSize * 1.4f);

    public override void Draw(MauiCanvas canvas)
    {
        canvas.FontColor = TextColor;
        canvas.FontSize = FontSize;
        canvas.DrawString(Text, X, Y, Width, Height, HorizontalAlignment.Left, VerticalAlignment.Center);
    }
}

public sealed class Button : Element
{
    public string Text = string.Empty;
    public float FontSize = 36;
    public Color Background = Colors.MediumSeaGreen;
    public Color PressedBackground = Colors.OrangeRed;
    public Color TextColor = Colors.White;
    public Action? Clicked;
    private bool _pressed;

    public override SizeF Measure(float availableWidth) => new(availableWidth, 96);

    public override void Draw(MauiCanvas canvas)
    {
        canvas.FillColor = _pressed ? PressedBackground : Background;
        canvas.FillRoundedRectangle(X, Y, Width, Height, 24);
        canvas.FontColor = TextColor;
        canvas.FontSize = FontSize;
        canvas.DrawString(Text, X + 24, Y, Width - 48, Height, HorizontalAlignment.Left, VerticalAlignment.Center);
    }

    public override bool OnTouch(bool down, bool up, float x, float y)
    {
        if (down && HitTest(x, y))
        {
            _pressed = true;
            return true;
        }
        if (up && _pressed)
        {
            _pressed = false;
            if (HitTest(x, y))
            {
                Clicked?.Invoke();
            }
            return true;
        }
        return _pressed;
    }
}

public sealed class VerticalStackLayout : Element
{
    public float Spacing = 16;
    public float Padding = 24;

    public List<Element> Children { get; } = new();

    public override SizeF Measure(float availableWidth)
    {
        float y = Padding;
        foreach (Element child in Children)
        {
            SizeF size = child.Measure(availableWidth - Padding * 2);
            child.X = Padding;
            child.Y = y;
            child.Width = size.Width;
            child.Height = size.Height;
            y += size.Height + Spacing;
        }
        Height = y + Padding;
        Width = availableWidth;
        return new SizeF(Width, Height);
    }

    public override void Draw(MauiCanvas canvas)
    {
        foreach (Element child in Children)
        {
            child.Draw(canvas);
        }
    }

    public override bool OnTouch(bool down, bool up, float x, float y)
    {
        bool handled = false;
        foreach (Element child in Children)
        {
            handled |= child.OnTouch(down, up, x, y);
        }
        return handled;
    }
}
