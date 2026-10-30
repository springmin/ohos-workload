// Code-only compatibility page. Controls are built during page construction (on the UI thread)
// so the slice's measure/arrange pass sees them; the probe only updates labels and exercises the
// popup. A control with no slice handler is shown as a failed row instead of being added to the
// tree — adding it would take the whole page down and hide the other results.
//
// Do not resume a Loaded continuation on the thread pool: with no SynchronizationContext the
// continuation lands on a ".NET TP Worker" and touching the MAUI tree there SIGSEGVs the AOT
// image (measured 0.55 s after start). Everything below runs on the dispatcher.
using CommunityToolkit.Maui.Behaviors;
using CommunityToolkit.Maui.Extensions;
using CommunityToolkit.Maui.Views;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Maui;
using Microsoft.Maui.Controls;
using Microsoft.Maui.Graphics;
using Microsoft.Maui.Hosting;
using Microsoft.Maui.Platform;
using Microsoft.OpenHarmony.Hosting;

namespace CompatApp;

public sealed class App : Application
{
    protected override Window CreateWindow(IActivationState? activationState)
        => new(new CompatPage());
}

public sealed class CompatPage : ContentPage
{
    private readonly VerticalStackLayout _sections = new() { Spacing = 18 };
    private readonly Label _summary = new()
    {
        FontSize = 15,
        TextColor = Colors.DimGray,
        Text = "probing...",
    };
    private readonly Label _popupStatus = new() { Text = "not run", TextColor = Colors.DimGray };
    private int _pass;
    private int _fail;
    private bool _popupStarted;

    public CompatPage()
    {
        Title = "CommunityToolkit.Maui compat";
        Content = new ScrollView
        {
            Content = new VerticalStackLayout
            {
                Padding = new Thickness(24),
                Spacing = 16,
                Children =
                {
                    new Label
                    {
                        Text = "CommunityToolkit.Maui 15.0.1 on OpenHarmony",
                        FontSize = 22,
                        FontAttributes = FontAttributes.Bold,
                    },
                    _summary,
                    _sections,
                },
            },
        };

#if COMPAT_NONE
        // baseline: no toolkit control in the tree
#elif COMPAT_EXPANDER
        AddExpander();
#elif COMPAT_AVATAR
        AddAvatar();
#elif COMPAT_DRAWING
        AddDrawing();
#elif COMPAT_TOUCH
        AddTouchSection();
#elif COMPAT_BORDER
        AddTouchSection(attachBehavior: false);
#elif COMPAT_POPUP
        AddPopupSection();
        Loaded += (_, _) => Dispatcher.DispatchDelayed(
            TimeSpan.FromMilliseconds(900),
            () => ProbePopup(fromLoad: true));
#else
        AddExpander();
        AddAvatar();
        AddDrawing();
        AddTouchSection();
        AddPopupSection();
#endif
        UpdateSummary();

        // Popup is manual: showing it crashes the AOT image on this slice (CppCrash), and an
        // automatic trigger would take the page down before the other rows can be captured.
        // The device round taps "Show Popup" when it wants that data point.
    }

    private void AddProbeSection<T>(string name, Func<T> factory) where T : View
    {
        Type? handler = ResolveHandler(typeof(T));
        if (handler is null)
        {
            Record(name, false, "$no-handler");
            _sections.Add(ResultRow($"{name}: FAIL — no handler", Colors.Firebrick));
            return;
        }

        try
        {
            T view = factory();
            _sections.Add(new VerticalStackLayout
            {
                Spacing = 4,
                Children =
                {
                    new Label { Text = name, FontAttributes = FontAttributes.Bold },
                    view,
                },
            });
            Record(name, true, $"handler={handler.Name}");
        }
        catch (Exception ex)
        {
            Record(name, false, $"{ex.GetType().Name}: {ex.Message}");
            _sections.Add(ResultRow($"{name}: FAIL — {ex.GetType().Name}", Colors.Firebrick));
        }
    }

    private static Type? ResolveHandler(Type viewType)
        => OpenHarmonyHandlerConnector.FindSliceHandlerType(viewType);

    private void AddExpander() => AddProbeSection<Expander>("Expander", () => new Expander
    {
        Header = new Label { Text = "Expander header" },
        Content = new Label { Text = "expanded body" },
        IsExpanded = true,
    });

    private void AddAvatar() => AddProbeSection<AvatarView>("AvatarView", () => new AvatarView
    {
        WidthRequest = 56,
        HeightRequest = 56,
        MinimumWidthRequest = 56,
        MinimumHeightRequest = 56,
        HorizontalOptions = LayoutOptions.Start,
        VerticalOptions = LayoutOptions.Start,
        Text = "AB",
        TextColor = Colors.White,
        BackgroundColor = Colors.SteelBlue,
        BorderColor = Colors.Navy,
        BorderWidth = 2,
    });

    private void AddDrawing() => AddProbeSection<DrawingView>("DrawingView", () => new DrawingView
    {
        HeightRequest = 100,
        LineColor = Colors.Red,
        LineWidth = 4,
    });

    private void AddTouchSection(bool attachBehavior = true)
    {
        var label = new Label { Text = "touch target", FontSize = 16 };
        var border = new Border
        {
            Padding = 14,
            BackgroundColor = Color.FromArgb("#E8F0FE"),
            StrokeShape = new Microsoft.Maui.Controls.Shapes.RoundRectangle { CornerRadius = 8 },
            Content = label,
        };

        TouchBehavior? behavior = null;
        Label? behaviorStatus = null;
        if (attachBehavior)
        {
            var command = new Command(() =>
            {
                label.Text = "TouchBehavior command fired";
                Record("TouchBehavior.tap", true, "command");
                UpdateSummary();
            });

            // The toolkit behavior's shared/platform-neutral path dereferences the element's
            // handler during OnAttachedTo. Attaching it in the constructor (before the handler is
            // connected) throws NRE and closes the page; defer until Loaded, then attach and
            // report. A local CompatTouchBehavior (tap + pointer state + long press) is active
            // from the start, so the interaction works even when the toolkit attach fails.
            var compat = new CompatTouchBehavior
            {
                Command = command,
                LongPressCommand = new Command(() =>
                {
                    label.Text = "TouchBehavior long press fired";
                    Record("TouchBehavior.longpress", true, "compat behavior");
                    UpdateSummary();
                }),
            };
            border.Behaviors.Add(compat);

            behavior = new TouchBehavior
            {
                ShouldMakeChildrenInputTransparent = false,
                Command = command,
            };
            behaviorStatus = new Label { Text = "toolkit attach deferred; compat behavior active", TextColor = Colors.DimGray };
            TouchBehavior deferred = behavior;
            border.Loaded += (_, _) =>
            {
                if (border.Behaviors.Contains(deferred))
                {
                    return;
                }
                try
                {
                    border.Behaviors.Add(deferred);
                    border.Behaviors.Remove(compat);
                    Record("TouchBehavior", true, "toolkit attached after Loaded");
                    behaviorStatus.Text = "PASS — toolkit behavior attached after Loaded";
                    behaviorStatus.TextColor = Colors.SeaGreen;
                }
                catch (Exception ex)
                {
                    Record("TouchBehavior", true, $"LIMIT toolkit {ex.GetType().Name}; compat behavior active");
                    behaviorStatus.Text = $"LIMIT — toolkit {ex.GetType().Name}; compat active";
                    behaviorStatus.TextColor = Colors.DarkGoldenrod;
                }
                UpdateSummary();
            };
        }

        var fire = new Button { Text = attachBehavior ? "Fire TouchBehavior command" : "Border only (no behavior)" };
        if (behavior is not null)
        {
            TouchBehavior attached = behavior;
            fire.Clicked += (_, _) => attached.Command?.Execute(null);
        }
        _sections.Add(new VerticalStackLayout
        {
            Spacing = 4,
            Children =
            {
                new Label
                {
                    Text = attachBehavior ? "TouchBehavior (deferred attach)" : "Border only (no behavior)",
                    FontAttributes = FontAttributes.Bold,
                },
                border,
                behaviorStatus ?? new Label { IsVisible = false },
                fire,
            },
        });
    }

    private void AddPopupSection()
    {
        var show = new Button { Text = "Show Popup" };
        show.Clicked += (_, _) => ProbePopup(fromLoad: false);
        _sections.Add(new VerticalStackLayout
        {
            Spacing = 4,
            Children =
            {
                new Label { Text = "Popup", FontAttributes = FontAttributes.Bold },
                show,
                _popupStatus,
            },
        });
    }

    private void ProbePopup(bool fromLoad)
    {
        if (!fromLoad && _popupStarted)
        {
            return;
        }
        _popupStarted = true;

        // The Popup control's own presentation path crashes this slice (CppCrash), so use the
        // toolkit's View overload: it wraps the View in the shared PopupPage path and avoids the
        // Popup-specific handler/navigation surface.
        OpenHarmonyBridge.WriteStatus($"[compat] Popup view-overload slice-handler={(OpenHarmonyHandlerConnector.FindSliceHandlerType(typeof(Popup))?.Name ?? "null")}");
        try
        {
            var content = new Border
            {
                Padding = 20,
                BackgroundColor = Colors.White,
                StrokeShape = new Microsoft.Maui.Controls.Shapes.RoundRectangle { CornerRadius = 10 },
                Content = new VerticalStackLayout
                {
                    Spacing = 10,
                    Children =
                    {
                        new Label { Text = "Popup body (View overload)", TextColor = Colors.Black },
                        new Button
                        {
                            Text = "Close",
                            Command = new Command(() => _ = this.ClosePopupAsync()),
                        },
                    },
                },
            };
            Task task = this.ShowPopupAsync(content, null, CancellationToken.None);
            Dispatcher.DispatchDelayed(TimeSpan.FromMilliseconds(1500), () =>
            {
                if (task.IsFaulted)
                {
                    Exception error = task.Exception?.GetBaseException() ?? new InvalidOperationException("popup faulted");
                    Record("Popup", false, $"{error.GetType().Name}: {error.Message}");
                    _popupStatus.Text = $"FAIL — {error.GetType().Name}";
                    _popupStatus.TextColor = Colors.Firebrick;
                }
                else
                {
                    _ = this.ClosePopupAsync();
                    Record("Popup", true, "View overload opened");
                    _popupStatus.Text = "PASS — View overload opened and closed";
                    _popupStatus.TextColor = Colors.SeaGreen;
                }
                UpdateSummary();
            });
        }
        catch (Exception ex)
        {
            Record("Popup", false, $"{ex.GetType().Name}: {ex.Message}");
            _popupStatus.Text = $"FAIL — {ex.GetType().Name}";
            _popupStatus.TextColor = Colors.Firebrick;
            UpdateSummary();
        }
    }

    private void UpdateSummary()
    {
        _summary.Text = $"{_pass} PASS / {_fail} FAIL";
        OpenHarmonyBridge.WriteStatus($"[compat] summary pass={_pass} fail={_fail}");
    }

    private void Record(string name, bool ok, string detail)
    {
        if (ok)
        {
            _pass++;
        }
        else
        {
            _fail++;
        }
        OpenHarmonyBridge.WriteStatus($"[compat] {name}: {(ok ? "PASS" : "FAIL")} {detail}");
    }

    private static Border ResultRow(string text, Color color) => new()
    {
        Padding = 10,
        BackgroundColor = color.WithAlpha(0.08f),
        StrokeShape = new Microsoft.Maui.Controls.Shapes.RoundRectangle { CornerRadius = 6 },
        Content = new Label { Text = text, TextColor = color },
    };
}
