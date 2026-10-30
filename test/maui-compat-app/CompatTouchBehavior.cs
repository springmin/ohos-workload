// OpenHarmony-compatible replacement for CommunityToolkit's TouchBehavior. The toolkit's
// platform-neutral behavior dereferences a null handler/platform view during attach (observed
// as a NullReferenceException that closes the page). This behavior uses only MAUI gesture
// recognizers: a tap for the command, pointer pressed/released for the pressed scale/opacity,
// and a dispatcher timer for long press.
using System.Windows.Input;
using Microsoft.Maui.Controls;
using Microsoft.Maui.Dispatching;

namespace CompatApp;

public sealed class CompatTouchBehavior : Behavior<View>
{
    public ICommand? Command { get; set; }
    public ICommand? LongPressCommand { get; set; }
    public int LongPressDuration { get; set; } = 600;
    public double PressedScale { get; set; } = 0.96;
    public double PressedOpacity { get; set; } = 0.75;

    private View? _element;
    private TapGestureRecognizer? _tap;
    private PointerGestureRecognizer? _pointer;
    private IDispatcherTimer? _timer;
    private bool _pressed;
    private bool _longPressFired;
    private long _lastTapTicks;

    protected override void OnAttachedTo(View bindable)
    {
        base.OnAttachedTo(bindable);
        _element = bindable;

        _tap = new TapGestureRecognizer { Command = new Command(HandleTap) };
        bindable.GestureRecognizers.Add(_tap);

        _pointer = new PointerGestureRecognizer();
        _pointer.PointerPressed += OnPressed;
        _pointer.PointerReleased += OnReleased;
        _pointer.PointerExited += OnExited;
        bindable.GestureRecognizers.Add(_pointer);
    }

    protected override void OnDetachingFrom(View bindable)
    {
        if (_tap is not null)
        {
            bindable.GestureRecognizers.Remove(_tap);
        }
        if (_pointer is not null)
        {
            bindable.GestureRecognizers.Remove(_pointer);
        }
        _timer?.Stop();
        _timer = null;
        base.OnDetachingFrom(bindable);
    }

    private void OnPressed(object? sender, PointerEventArgs e)
    {
        if (_element is null)
        {
            return;
        }
        _pressed = true;
        _longPressFired = false;
        _element.Scale = PressedScale;
        _element.Opacity = PressedOpacity;

        _timer?.Stop();
        _timer = _element.Dispatcher.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(LongPressDuration);
        _timer.IsRepeating = false;
        _timer.Tick += (_, _) =>
        {
            if (!_pressed || _longPressFired)
            {
                return;
            }
            _longPressFired = true;
            _timer?.Stop();
            if (LongPressCommand?.CanExecute(null) is true)
            {
                LongPressCommand.Execute(null);
            }
        };
        _timer.Start();
    }

    private void HandleTap()
    {
        if (_longPressFired)
        {
            return;
        }
        long now = Environment.TickCount64;
        if (now - _lastTapTicks < 250)
        {
            return;
        }
        _lastTapTicks = now;
        if (Command?.CanExecute(null) is true)
        {
            Command.Execute(null);
        }
    }

    private void OnReleased(object? sender, PointerEventArgs e) => Release();
    private void OnExited(object? sender, PointerEventArgs e) => Release();

    private void Release()
    {
        _pressed = false;
        _timer?.Stop();
        _timer = null;
        if (_element is not null)
        {
            _element.Scale = 1;
            _element.Opacity = 1;
        }
    }
}
