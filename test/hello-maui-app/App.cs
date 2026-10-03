// A real MAUI application running on the OpenHarmony platform slice.
using Microsoft.AspNetCore.Components.WebView.Maui;
using Microsoft.Maui;
using Microsoft.Maui.Controls;
using Microsoft.Maui.Controls.Shapes;
using Microsoft.Maui.Platform;
using Microsoft.Maui.Storage;
using Microsoft.OpenHarmony.Hosting;
using System.Diagnostics.CodeAnalysis;

namespace HelloMauiApp;

public sealed class App : Application
{
    // NativeAOT gate: the string-path SetBinding overload and the Binding(string) constructor
    // are both annotated [RequiresUnreferencedCode], so a template self-binding ("." binds the
    // item itself) cannot be expressed without IL2026 in this MAUI version. The runtime call is
    // the same one the JIT build uses, behind one controlled suppression instead of three
    // unannotated warning sites; the AOT publish log then carries zero IL2026/IL3050/IL3051.
    [UnconditionalSuppressMessage("Trimming", "IL2026",
        Justification = "Template self-path binding to the item value itself; no member lookup.")]
    private static void BindSelfPath(BindableObject target, BindableProperty property)
        => target.SetBinding(property, ".");

    /// <summary>
    /// MULTI-OVERLAY-FULL demo invoker: answers a JS-&gt;.NET invocation with a JSON string that
    /// carries the hybrid's identity, so the device run can prove the invoke channel routed the
    /// request through the right overlay slot (A's page receives "A-echo:...", B's "B-echo:...").
    /// </summary>
    private sealed class EchoInvoker : HybridWebViewInvoker
    {
        private readonly string _tag;

        public EchoInvoker(string tag) : base(null, null) => _tag = tag;

        public override Task<string?> InvokeMethodAsync(string methodName, string[]? paramJsonValues)
        {
            string safeMethod = methodName.Replace('"', '\'');
            string result = $"\"{_tag}-echo:{safeMethod}:{paramJsonValues?.Length ?? 0}\"";
            return Task.FromResult<string?>(result);
        }
    }

    /// <summary>Updates a status label from the (possibly off-dispatcher) web callback thread.</summary>
    private static void SetStatus(Microsoft.Maui.Controls.VisualElement element, Label label, string text)
    {
        if (element.Dispatcher is { } dispatcher)
        {
            dispatcher.Dispatch(() => label.Text = text);
        }
        else
        {
            label.Text = text;
        }
    }

    protected override Window CreateWindow(IActivationState? activationState)
    {
        // The window hosts a flyout page (drawer) whose detail is a tabbed page; the main page
        // itself lives in a navigation page so the slice exercises every page type.
        var window = new Window(new FlyoutPage
        {
            Flyout = new ContentPage
            {
                Title = "Menu",
                Content = new VerticalStackLayout
                {
                    Padding = 24,
                    Spacing = 12,
                    Children =
                    {
                        new Label { Text = "Drawer", FontSize = 34 },
                        new Label { Text = "tap outside to close", FontSize = 22 },
                    },
                },
            },
            Detail = new TabbedPage
            {
                Children =
                {
                    new NavigationPage(BuildPage()) { Title = "Home", BarBackgroundColor = Colors.DarkSlateBlue },
                    new ContentPage { Title = "Animations", Content = BuildAnimationPage() },
                },
            },
        });
        // Replay the last activation title once the window exists (a warm activation that
        // arrived while the window was being created).
        if (s_lastActivation is { } pending)
        {
            ApplyActivationTitle(window, pending);
        }
        // T20 media probe trigger: a media activation that arrives while the app runs starts
        // the probe here (cold-start wants are owned by OpenHarmonyAppLinks, the first
        // Activation subscriber, so this handler intentionally serves the warm path).
        OpenHarmonyBridge.Activation += OnActivation;
        return window;
    }

    private static string? s_lastActivation;

    /// <summary>
    /// Startup heartbeat: sets the window title once the handlers are attached. The shell logs
    /// every title application ([maui] window title applied), so the line doubles as the
    /// managed-to-shell liveness marker on devices whose status file is unreadable.
    /// </summary>
    protected override void OnStart()
    {
        base.OnStart();
        if (CurrentWindow() is { } window)
        {
            ApplyActivationTitle(window, "w9d boot");
        }
    }

    /// <summary>
    /// Handles one warm activation the shell delivered (onNewWant). The subscription lives in
    /// CreateWindow, after the app host installed OpenHarmonyAppLinks: the hosting bridge replays
    /// a buffered cold activation to its first subscriber (AppLinks owns that path), so this
    /// diagnostic handler intentionally only sees the activations that arrive while running.
    /// </summary>
    internal static void OnActivation(OpenHarmonyActivationEventArgs activation)
    {
        string uri = activation.Uri ?? string.Empty;
        // T19 device evidence + T20 probe trigger. The window title is a WindowManagerService-
        // visible channel; the status line goes to dotnet-status.txt.
        OpenHarmonyBridge.WriteStatus(
            $"[hello-maui-app] activation seq={activation.Sequence} uri='{uri}' action='{activation.Action}'");
        string suffix = uri.Length > 64 ? uri[..64] : uri;
        string title = $"activation {activation.Sequence}: {suffix}";
        s_lastActivation = title;
        if (CurrentWindow() is { } window)
        {
            ApplyActivationTitle(window, title);
        }
        if (uri.StartsWith("app://media/probe", StringComparison.OrdinalIgnoreCase) &&
            CurrentWindow() is { } probeWindow)
        {
            MediaProbe.Start(probeWindow);
        }
    }

    private static Window? CurrentWindow()
        => Application.Current?.Windows.FirstOrDefault() as Window;

    private static void ApplyActivationTitle(Window window, string title)
    {
        try
        {
            window.Dispatcher.Dispatch(() => window.Title = title);
        }
        catch (Exception ex)
        {
            // Diagnostics only: a dispatch failure must not break the activation chain.
            OpenHarmonyBridge.WriteStatus($"[hello-maui-app] activation title dispatch failed: {ex.GetType().Name}");
        }
    }

    private static View BuildAnimationPage()
    {
        var fadeTarget = new Label { Text = "animate me", FontSize = 36, HorizontalOptions = LayoutOptions.Center };
        var status = new Label { Text = "tap the button", FontSize = 26, HorizontalOptions = LayoutOptions.Center };
        var run = new Button { Text = "Run animations", FontSize = 32 };
        run.Clicked += async (_, _) =>
        {
            status.Text = "fading out...";
            await fadeTarget.FadeTo(0.1, 600, Easing.CubicInOut);
            await fadeTarget.FadeTo(1.0, 400, Easing.CubicInOut);
            await fadeTarget.TranslateTo(60, 0, 300, Easing.CubicOut);
            await fadeTarget.TranslateTo(0, 0, 300, Easing.CubicOut);
            await fadeTarget.RotateTo(360, 600, Easing.Linear);
            fadeTarget.Rotation = 0;
            status.Text = "animations done";
        };
        var carousel = new CarouselView
        {
            ItemsSource = new List<string> { "swipe A", "swipe B", "swipe C" },
            ItemTemplate = new DataTemplate(() =>
            {
                var slide = new Label { FontSize = 34, HorizontalOptions = LayoutOptions.Center };
                BindSelfPath(slide, Label.TextProperty);
                return slide;
            }),
            HeightRequest = 160,
        };
        var positionLabel = new Label { Text = "swipe the carousel", FontSize = 24, HorizontalOptions = LayoutOptions.Center };
        carousel.PositionChanged += (_, _) => positionLabel.Text = $"slide {carousel.Position + 1}";
        return new VerticalStackLayout { Padding = 32, Spacing = 24, Children = { fadeTarget, carousel, positionLabel, run, status } };
    }

    // T20 media bridge demo: drives the AVPlayer playback bridge with the local sine tone the
    // probe writes into the cache dir (no packaged asset and no device codec stream needed).
    // The shell logs every state transition to hilog; the managed side mirrors the outcome into
    // the window title as well.
    private static View BuildMediaSection()
    {
        var status = new Label { Text = "media: tap Play tone (local wav in the cache dir)", FontSize = 22 };
        var play = new Button { Text = "Play tone", FontSize = 26 };
        play.Clicked += (_, _) =>
        {
            status.Text = "media: playing...";
            if (Application.Current?.Windows.FirstOrDefault() is Window window)
            {
                MediaProbe.Start(window);
            }
        };
        var stop = new Button { Text = "Stop media", FontSize = 26 };
        stop.Clicked += (_, _) =>
        {
            status.Text = "media: stopping";
            MediaProbe.StopFromUi(Application.Current?.Windows.FirstOrDefault());
        };
        var caption = new Label { Text = "Media playback bridge (ArkTS AVPlayer)", FontSize = 22 };
        return new VerticalStackLayout { Spacing = 8, Children = { caption, play, stop, status } };
    }

    /// <summary>
    /// S1/#app mount demo. The BlazorWebView was dropped from this page when MULTI-OVERLAY-FULL
    /// replaced it with the third hybrid (0e0129e); the mount itself was never re-verified on the
    /// demo after the Blazor IPC fixes, and the kit notes recorded it as an open "Blazor #app not
    /// mounted" item. It is restored on demand here: the fixed-height host exists from the start,
    /// so adding the control does not move the hybrids, and the LRU pool preempts a hybrid slot
    /// for it. The root component is BlazorCounter (see BlazorCounter.cs), mounted at #app in
    /// wwwroot/index.html.
    ///
    /// NativeAOT root: the WebView renderer creates the root component through
    /// ActivatorUtilities over <see cref="RootComponent.ComponentType"/>, and that property
    /// carries no DynamicallyAccessedMembers annotation, so a trimmed publish would remove the
    /// component's constructor and the attach fails ("A suitable constructor ... could not be
    /// located", FIX-BWVMount). PublicConstructors alone is not enough: the renderer also
    /// reflects over the component's members (activation/parameters), so All is the safe root.
    /// </summary>
    [DynamicDependency(DynamicallyAccessedMemberTypes.All, typeof(BlazorCounter))]
    private static BlazorWebView BuildBlazorWebView()
    {
        var blazor = new BlazorWebView
        {
            HostPage = "wwwroot/index.html",
            HeightRequest = 280,
        };
        blazor.RootComponents.Add(new RootComponent
        {
            Selector = "#app",
            ComponentType = typeof(BlazorCounter),
        });
        return blazor;
    }

    private static ContentPage BuildPage()
    {
        // W22-13: Essentials - the counter survives restarts through Preferences.
        int clicks = Preferences.Get("demo.clicks", 0);
        var title = new Label { Text = "MAUI on OpenHarmony", FontSize = 44 };
        var subtitle = new Label { Text = "Microsoft.Maui.Controls through the platform slice", FontSize = 24 };

        // MULTI-OVERLAY-FULL demo (one page, three+ web controls, dynamic shell slot pool):
        //   * hybrid A and hybrid B are two HybridWebViews on this page, each with its own
        //     staged document (wwwroot/hybrid-a.html / hybrid-b.html) served on its own overlay
        //     slot; both are interactive (raw messages and JS->.NET invokes);
        //   * the "Add web C" button creates a third hybrid on demand (SLOTS-DYNAMIC: the pool
        //     grows the shell's overlay set, so A, B and C render and stay interactive
        //     concurrently - the previous N=2 pool preempted A), and removes it again ("slot
        //     destroy") so the recycle/rebuild path can be exercised on the device;
        //   * the "Add Blazor" button swaps the third control for the BlazorWebView (#app
        //     mount), which claims the freed dynamic slot; "Activate hybrid A/B" restores a
        //     preempted hybrid if the shell capacity is ever exhausted (LRU replay).
        // The pages load _framework/hybridwebview.js (the handler extracts it next to the
        // payload), so the visible buttons exercise the stock raw-message and invoke endpoints.
        var hybridA = new HybridWebView
        {
            HybridRoot = "wwwroot",
            DefaultFile = "hybrid-a.html",
            HeightRequest = 180,
        };
        hybridA.Invoker = new EchoInvoker("A");
        var hybridAStatus = new Label { Text = "hybrid A: loading hybrid-a.html", FontSize = 20 };
        hybridA.RawMessageReceived += (_, e) => SetStatus(hybridA, hybridAStatus, $"A raw: {e.Message}");

        var hybridB = new HybridWebView
        {
            HybridRoot = "wwwroot",
            DefaultFile = "hybrid-b.html",
            HeightRequest = 180,
        };
        hybridB.Invoker = new EchoInvoker("B");
        var hybridBStatus = new Label { Text = "hybrid B: loading hybrid-b.html", FontSize = 20 };
        hybridB.RawMessageReceived += (_, e) => SetStatus(hybridB, hybridBStatus, $"B raw: {e.Message}");

        var webStatus = new Label { Text = "SLOTS-DYNAMIC: 2 hybrids live; add web C for a 3rd live overlay", FontSize = 20 };
        var activateA = new Button { Text = "Activate hybrid A (LRU restore)", FontSize = 24 };
        activateA.Clicked += async (_, _) =>
        {
            webStatus.Text = "activating hybrid A...";
            string? result = await hybridA.EvaluateJavaScriptAsync("document.title");
            webStatus.Text = $"hybrid A activated (eval: {result ?? "null"})";
        };
        var activateB = new Button { Text = "Activate hybrid B (LRU restore)", FontSize = 24 };
        activateB.Clicked += async (_, _) =>
        {
            webStatus.Text = "activating hybrid B...";
            string? result = await hybridB.EvaluateJavaScriptAsync("document.title");
            webStatus.Text = $"hybrid B activated (eval: {result ?? "null"})";
        };

        // web C is a third web control, added to the page on demand so the two hybrids are the
        // first two slot owners. SLOTS-DYNAMIC: the pool grows the shell's overlay set for it
        // (slot 2, created by "slot ensure"), so A, B and C are live at the same time; removing
        // it sends "slot destroy" and re-adding it recreates the slot (the recycle evidence).
        //
        // S1/#app mount demo (SAMPLE-FIX): the same host carries the restored BlazorWebView, so
        // requesting it swaps out hybrid C - its disconnect releases the slot, which the Blazor
        // handler then claims (registration + load replay). Requesting one swaps the other;
        // re-adding a swapped-out control connects its handler again (the Blazor origin, the
        // mount and the counter work under both payload modes, see BuildBlazorWebView).
        var hybridC = new HybridWebView
        {
            HybridRoot = "wwwroot",
            DefaultFile = "hybrid-c.html",
            HeightRequest = 240,
        };
        hybridC.Invoker = new EchoInvoker("C");
        var hybridCStatus = new Label { Text = "hybrid C: not added yet", FontSize = 20 };
        hybridC.RawMessageReceived += (_, e) => SetStatus(hybridC, hybridCStatus, $"C raw: {e.Message}");

        var blazor = BuildBlazorWebView();
        var blazorStatus = new Label { Text = "Blazor #app: not added yet", FontSize = 20 };

        var extraHost = new Grid { HeightRequest = 280, BackgroundColor = Colors.Gainsboro };
        bool webCAdded = false;
        bool blazorAdded = false;
        var addC = new Button { Text = "Add web C (3rd hybrid, dynamic slot)", FontSize = 22 };
        var addBlazor = new Button { Text = "Add Blazor (#app mount)", FontSize = 22 };
        addC.Clicked += (_, _) =>
        {
            if (!webCAdded)
            {
                extraHost.Children.Clear();
                extraHost.Children.Add(hybridC);
                webCAdded = true;
                blazorAdded = false;
                addC.Text = "Remove web C (slot destroy)";
                addBlazor.Text = "Add Blazor (#app mount)";
                hybridCStatus.Text = "hybrid C: loading hybrid-c.html (dynamic slot)";
                blazorStatus.Text = "Blazor #app: not added";
            }
            else
            {
                extraHost.Children.Clear();
                webCAdded = false;
                addC.Text = "Add web C (3rd hybrid, dynamic slot)";
                hybridCStatus.Text = "hybrid C: removed (slot destroy)";
            }
        };
        addBlazor.Clicked += (_, _) =>
        {
            if (!blazorAdded)
            {
                extraHost.Children.Clear();
                extraHost.Children.Add(blazor);
                blazorAdded = true;
                webCAdded = false;
                addC.Text = "Add web C (3rd hybrid, dynamic slot)";
                addBlazor.Text = "Remove Blazor (#app mount)";
                blazorStatus.Text = "Blazor #app: loading wwwroot/index.html";
                hybridCStatus.Text = "hybrid C: swapped out";
            }
            else
            {
                extraHost.Children.Clear();
                blazorAdded = false;
                addBlazor.Text = "Add Blazor (#app mount)";
                blazorStatus.Text = "Blazor #app: removed";
            }
        };

        var status = new Label { Text = "Tap the counter", FontSize = 28 };
        var counter = new Button { Text = $"Count: {clicks}", FontSize = 40 };
        counter.Clicked += (_, _) =>
        {
            clicks++;
            Preferences.Set("demo.clicks", clicks);
            counter.Text = $"Count: {clicks}";
            status.Text = $"last click #{clicks} (saved)";
        };
        // W22-1: soft-keyboard text input through the ArkTS shell's TextInput.
        var entry = new Entry { Placeholder = "type here (soft keyboard)", FontSize = 32 };
        entry.TextChanged += (_, e) => status.Text = $"text: '{e.NewTextValue}'";
        entry.Completed += (_, _) => status.Text = "entry completed";

        // W22-2: value controls (checkbox, switch, slider, progress, spinner).
        var checkBox = new CheckBox { IsChecked = true };
        var toggle = new Switch { IsToggled = false };
        var slider = new Slider { Minimum = 0, Maximum = 100, Value = 40, HeightRequest = 40 };
        var progress = new ProgressBar { Progress = 0.4, HeightRequest = 8 };
        var spinner = new ActivityIndicator { IsRunning = true, HeightRequest = 24 };
        checkBox.CheckedChanged += (_, e) => status.Text = $"checkbox: {e.Value}";
        toggle.Toggled += (_, e) => status.Text = $"switch: {e.Value}";
        slider.ValueChanged += (_, e) =>
        {
            progress.Progress = e.NewValue / 100.0;
            status.Text = $"slider: {e.NewValue:0}";
        };
        var valueControls = new HorizontalStackLayout { Spacing = 16 };
        valueControls.Add(checkBox);
        valueControls.Add(toggle);
        valueControls.Add(slider);
        valueControls.Add(spinner);

        // W22-4: collection view (items materialized from a template, drag-scrollable).
        var collection = new CollectionView
        {
            ItemsSource = Enumerable.Range(0, 30).Select(i => $"collection item {i}").ToList(),
            ItemTemplate = new DataTemplate(() =>
            {
                var itemLabel = new Label { FontSize = 26 };
                BindSelfPath(itemLabel, Label.TextProperty);
                return itemLabel;
            }),
            HeightRequest = 260,
        };

        // W21: clip + translate scrolling, driven by touch drags.
        var rows = new VerticalStackLayout { Spacing = 8 };
        for (int i = 0; i < 12; i++)
        {
            rows.Add(new Label { Text = $"scrollable row {i}", FontSize = 26 });
        }
        var scroll = new ScrollView { Content = rows, HeightRequest = 320 };

        // W22-12: legacy ListView (cells) and a CarouselView.
        var legacyList = new ListView
        {
            ItemsSource = Enumerable.Range(0, 12).Select(i => $"legacy row {i}").ToList(),
            ItemTemplate = new DataTemplate(() =>
            {
                var cell = new TextCell();
                BindSelfPath(cell, TextCell.TextProperty);
                return cell;
            }),
            HeightRequest = 200,
        };

        // W22-6: gesture recognizer (tap) + view transforms.
        int taps = 0;
        var tapTarget = new Label { Text = "tap this label (0 taps)", FontSize = 30, BackgroundColor = Colors.DimGray };
        var tapGesture = new TapGestureRecognizer();
        tapGesture.Tapped += (_, _) =>
        {
            taps++;
            tapTarget.Text = $"tap this label ({taps} taps)";
        };
        tapTarget.GestureRecognizers.Add(tapGesture);

        var reset = new Button { Text = "Reset", FontSize = 32 };
        reset.Clicked += (_, _) =>
        {
            clicks = 0;
            Preferences.Remove("demo.clicks");
            counter.Text = "Count: 0";
            status.Text = "reset";
        };

        var layout = new VerticalStackLayout { Padding = 32, Spacing = 20 };        // W22-5: shapes, border, stepper, radio button, search bar.
        var shapeRow = new HorizontalStackLayout { Spacing = 12 };
        shapeRow.Add(new Rectangle { WidthRequest = 48, HeightRequest = 48, Fill = Colors.OrangeRed, Stroke = Colors.White, StrokeThickness = 2 });
        shapeRow.Add(new Ellipse { WidthRequest = 48, HeightRequest = 48, Fill = Colors.MediumSeaGreen });
        shapeRow.Add(new Line { X1 = 0, Y1 = 0, X2 = 48, Y2 = 48, Stroke = Colors.Gold, StrokeThickness = 3 });
        var borderBox = new Border
        {
            Stroke = Colors.DodgerBlue,
            StrokeThickness = 3,
            Padding = 10,
            Content = new Label { Text = "inside border", FontSize = 24 },
        };
        var pickerDemo = new Picker { Title = "pick", FontSize = 24 };
        pickerDemo.Items.Add("one");
        pickerDemo.Items.Add("two");
        pickerDemo.Items.Add("three");
        var valueRow2 = new HorizontalStackLayout { Spacing = 16 };
        valueRow2.Add(new Stepper { Minimum = 0, Maximum = 10, Increment = 1, Value = 1 });
        valueRow2.Add(new RadioButton { Content = "radio choice" });
        valueRow2.Add(new SearchBar { Placeholder = "search...", HeightRequest = 48 });
        valueRow2.Add(new DatePicker { Date = new DateTime(2026, 9, 17), FontSize = 24 });
        valueRow2.Add(new TimePicker { Time = new TimeSpan(14, 30, 0), FontSize = 24 });
        valueRow2.Add(pickerDemo);

        layout.Add(title);
        layout.Add(subtitle);
        layout.Add(webStatus);
        var webControls = new HorizontalStackLayout { Spacing = 8 };
        webControls.Add(activateA);
        webControls.Add(activateB);
        webControls.Add(addC);
        layout.Add(webControls);
        // SAMPLE-FIX: the Blazor toggle is its own row so the existing web-control row keeps its
        // device-verified width (the three buttons already use most of the window).
        layout.Add(addBlazor);
        // ZORDER-NAV: hybrids A and B share one 270-DIP zone and offset by (80,90) DIP instead
        // of two stacked full rows. The rows are fixed (180 + 90) because the web handler's
        // GetDesiredSize reports the cell constraint (HeightRequest is not honoured): A fills
        // row 0 (y 0-180), B spans both rows with a top margin of 90 (y 90-270). A keeps an
        // exposed strip at the top (y 0-90) and in its left column (x 0-80), B one at the bottom
        // (y 180-270, x 80-end); the contested band is y 90-180 x 80-end. A touch on an exposed
        // strip raises that page through the shell's activation z-index, which the device round
        // verifies with a pixel diff of the contested band. The zone is shorter than the old
        // stacked rows, so web C's host keeps its place in the window and the LRU demo still runs.
        var webZone = new Grid
        {
            HeightRequest = 270,
            RowDefinitions =
            {
                new RowDefinition { Height = new GridLength(180) },
                new RowDefinition { Height = new GridLength(90) },
            },
        };
        hybridB.Margin = new Thickness(80, 90, 0, 0);
        webZone.Add(hybridA, 0, 0);
        webZone.Add(hybridB, 0, 0);
        Grid.SetRowSpan(hybridB, 2);
        layout.Add(webZone);
        layout.Add(hybridAStatus);
        layout.Add(hybridBStatus);
        layout.Add(extraHost);
        layout.Add(hybridCStatus);
        layout.Add(blazorStatus);
        layout.Add(counter);
        layout.Add(entry);
        layout.Add(valueControls);
        layout.Add(progress);
        layout.Add(shapeRow);
        layout.Add(borderBox);
        layout.Add(valueRow2);
        layout.Add(BuildMediaSection());
        layout.Add(legacyList);
        layout.Add(collection);
        layout.Add(scroll);
        layout.Add(tapTarget);
        layout.Add(reset);
        layout.Add(status);
        return new ContentPage { Title = "MAUI on OpenHarmony", Content = layout };
    }
}
