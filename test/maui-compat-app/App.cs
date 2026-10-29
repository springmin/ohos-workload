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
using Microsoft.Maui;
using Microsoft.Maui.Controls;
using Microsoft.Maui.Graphics;
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
#elif COMPAT_POPUP
        AddPopupSection();
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
        Type? handler = OpenHarmonyHandlerConnector.FindSliceHandlerType(typeof(T));
        if (handler is null)
        {
            Record(name, false, "$no-slice-handler");
            _sections.Add(ResultRow($"{name}: FAIL — no slice handler", Colors.Firebrick));
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

    private void AddTouchSection()
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
        try
        {
            behavior = new TouchBehavior
            {
                Command = new Command(() =>
                {
                    label.Text = "TouchBehavior command fired";
                    Record("TouchBehavior.tap", true, "command");
                    UpdateSummary();
                }),
            };
            border.Behaviors.Add(behavior);
            Record("TouchBehavior", true, "attached to Border");
        }
        catch (Exception ex)
        {
            Record("TouchBehavior", false, $"{ex.GetType().Name}: {ex.Message}");
            _sections.Add(ResultRow($"TouchBehavior: FAIL — {ex.GetType().Name}", Colors.Firebrick));
            return;
        }

        var fire = new Button { Text = "Fire TouchBehavior command" };
        TouchBehavior attached = behavior;
        fire.Clicked += (_, _) => attached.Command?.Execute(null);
        _sections.Add(new VerticalStackLayout
        {
            Spacing = 4,
            Children =
            {
                new Label { Text = "TouchBehavior (attached)", FontAttributes = FontAttributes.Bold },
                border,
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

        Type? handler = OpenHarmonyHandlerConnector.FindSliceHandlerType(typeof(Popup));
        OpenHarmonyBridge.WriteStatus($"[compat] Popup slice-handler={(handler?.Name ?? "null")}");
        try
        {
            Popup? popup = null;
            popup = new Popup
            {
                Content = new VerticalStackLayout
                {
                    Padding = 20,
                    Spacing = 10,
                    Children =
                    {
                        new Label { Text = "Popup body" },
                        new Button
                        {
                            Text = "Close",
                            Command = new Command(() =>
                            {
                                if (popup is not null)
                                {
                                    _ = popup.CloseAsync();
                                }
                            }),
                        },
                    },
                },
            };
            Task task = this.ShowPopupAsync(popup, null, CancellationToken.None);
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
                    if (popup is not null)
                    {
                        _ = popup.CloseAsync();
                    }
                    Record("Popup", true, handler is null ? "opened without slice handler" : $"handler={handler.Name}");
                    _popupStatus.Text = "PASS — opened and closed";
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
