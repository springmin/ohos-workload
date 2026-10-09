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
#if STARTUP_PROBE
        StartupProbe.Mark("create-window");
#endif
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
#if STARTUP_PROBE
        window.Created += (_, _) => StartupProbe.Mark("created");
        window.Activated += (_, _) => StartupProbe.Mark("activated");
        StartupProbe.Mark("window-built");
#endif
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
#if WEBAUTH_PROBE
        // WEB-AUTH device probe (see WebAuthProbe.cs): the flow triggers ride the same warm
        // activation path; the callback want (myapp://callback) is consumed by the
        // WebAuthenticator subscription itself.
        if (uri.StartsWith("app://webauth/", StringComparison.OrdinalIgnoreCase))
        {
            WebAuthProbe.Handle(uri);
            return;
        }
#endif
        // MULTIWINDOW-M/L device triggers (documented in the M/L plans): "demo" drives the
        // shell-drawn child create -> move -> resize -> close, "open" opens a real second MAUI
        // window on the subwindow XComponent (M3; falls back to the drawn child when the
        // per-window path is unavailable), "close" destroys whichever child is live.
        // N-SUBWINDOW: any subwindow trigger may carry the cap switch (app://subwindow/max/4,
        // or ?max=4 on an open) so the device round can move the pairing's bound before the
        // first command. Both the host and the shell read OHOS_SUBWINDOW_MAX lazily.
        if (uri.Contains("app://subwindow/", StringComparison.OrdinalIgnoreCase))
        {
            ApplySubWindowMaxFromUri(uri);
        }
        if (uri.StartsWith("app://subwindow/demo", StringComparison.OrdinalIgnoreCase))
        {
            RunSubWindowDemo();
        }
        // MULTIWINDOW-L2 device trigger: the managed child window carries a WebView whose
        // ArkWeb component is hosted by the subwindow page's own child pool (the second host).
        // Checked before the plain "open" branch: "openweb" also starts with "open".
        // C5-L3: "openwebhash" loads a '#'-bearing document (the loadData percent-encoding
        // probe); "openwebstorm" starts the navigation storm (the SEC7-F ask-rate probe).
        else if (uri.StartsWith("app://subwindow/openwebstorm", StringComparison.OrdinalIgnoreCase))
        {
            OpenManagedSubWindow(withWeb: true, stormDoc: true);
        }
        else if (uri.StartsWith("app://subwindow/openwebhash", StringComparison.OrdinalIgnoreCase))
        {
            OpenManagedSubWindow(withWeb: true, hashDoc: true);
        }
        else if (uri.StartsWith("app://subwindow/openweb", StringComparison.OrdinalIgnoreCase))
        {
            OpenManagedSubWindow(withWeb: true);
        }
        // C5-L3 main-page probe: "app://web/datahash" opens the primary window's data WebView
        // with a '#' in the document; "app://web/datanohash" is the no-# regression twin.
        else if (uri.StartsWith("app://web/datahash", StringComparison.OrdinalIgnoreCase))
        {
            RunMainDataProbe(withHash: true);
        }
        else if (uri.StartsWith("app://web/datanohash", StringComparison.OrdinalIgnoreCase))
        {
            RunMainDataProbe(withHash: false);
        }
        else if (uri.StartsWith("app://subwindow/open", StringComparison.OrdinalIgnoreCase))
        {
            OpenManagedSubWindow();
        }
        else if (uri.StartsWith("app://subwindow/close", StringComparison.OrdinalIgnoreCase))
        {
            CloseSubWindow();
        }
    }

    // MULTIWINDOW-L3 M1/N-SUBWINDOW: the live managed children in open order (default max 2,
    // raised by OHOS_SUBWINDOW_MAX up to the supported ceiling). The app host binds each to its
    // own shell session (sub-1, sub-2, ...) on the subwindow XComponent; the shell-drawn child
    // stays the degradation path when the managed path is unavailable.
    private static readonly List<Window> s_childWindows = new();
    private const int DefaultMaxManagedChildren = 2;
    private const int MaxSupportedManagedChildren = 8;

    /// <summary>The demo's own open guard: the same OHOS_SUBWINDOW_MAX switch the host and the
    /// shell read (default 2, ceiling 8), so the round's ?max=N triggers N child windows.</summary>
    private static int MaxManagedChildren()
    {
        string? raw = Environment.GetEnvironmentVariable("OHOS_SUBWINDOW_MAX");
        return int.TryParse(raw, out int value)
            ? Math.Clamp(value, DefaultMaxManagedChildren, MaxSupportedManagedChildren)
            : DefaultMaxManagedChildren;
    }

    /// <summary>N-SUBWINDOW test trigger: sets OHOS_SUBWINDOW_MAX from a subwindow deep link
    /// (app://subwindow/max/4 or ...?max=4) before the pairing's lazy reads happen.</summary>
    private static void ApplySubWindowMaxFromUri(string uri)
    {
        string digits = string.Empty;
        int query = uri.IndexOf("max=", StringComparison.OrdinalIgnoreCase);
        if (query >= 0)
        {
            foreach (char c in uri.AsSpan(query + 4))
            {
                if (!char.IsAsciiDigit(c))
                {
                    break;
                }
                digits += c;
            }
        }
        else
        {
            const string maxPrefix = "app://subwindow/max/";
            if (uri.StartsWith(maxPrefix, StringComparison.OrdinalIgnoreCase))
            {
                foreach (char c in uri.AsSpan(maxPrefix.Length))
                {
                    if (!char.IsAsciiDigit(c))
                    {
                        break;
                    }
                    digits += c;
                }
            }
        }
        if (digits.Length > 0 && int.TryParse(digits, out int value))
        {
            int clamped = Math.Clamp(value, DefaultMaxManagedChildren, MaxSupportedManagedChildren);
            Environment.SetEnvironmentVariable("OHOS_SUBWINDOW_MAX", clamped.ToString());
            OpenHarmonyBridge.WriteStatus($"[hello-maui-app] subwindow max switch: OHOS_SUBWINDOW_MAX={clamped}");
        }
    }

    /// <summary>
    /// MULTIWINDOW-L M3 entry / L3-M1: opens a real MAUI child window. Application.OpenWindow
    /// routes through the slice's application handler, which asks the shell for a subwindow
    /// XComponent (deferred surface) and binds the window when the surface reports in; the shell
    /// session registry carries up to two children. When the managed path is unavailable (no
    /// shell sink or an older host), the M shell-drawn child is created instead so the trigger
    /// never leaves the user with nothing.
    /// </summary>
    private static void OpenManagedSubWindow(bool withWeb = false, bool hashDoc = false, bool stormDoc = false)
    {
        var application = Application.Current;
        if (application is null)
        {
            return;
        }
        PruneClosedChildren(application);
        if (s_childWindows.Count >= MaxManagedChildren())
        {
            OpenHarmonyBridge.WriteStatus($"[hello-maui-app] subwindow open: managed child windows already open (max {MaxManagedChildren()})");
            return;
        }
        var child = new Window(BuildChildWindowPage(withWeb, s_childWindows.Count + 1, hashDoc, stormDoc)) { Title = $"MAUI child {s_childWindows.Count + 1}" };
        s_childWindows.Add(child);
        application.OpenWindow(child);
        var result = (application.Handler as OpenHarmonyApplicationHandler)?.LastOpenWindowResult
            ?? OpenHarmonyOpenWindowResult.None;
        OpenHarmonyBridge.WriteStatus(
            $"[hello-maui-app] subwindow open(managed){((withWeb) ? " web" : string.Empty)}: supported={OpenHarmonySubWindow.IsSupported} children={s_childWindows.Count} result={result}");
        if (result != OpenHarmonyOpenWindowResult.OpenedWindow)
        {
            s_childWindows.Remove(child);
            OpenHarmonyBridge.WriteStatus(
                $"[hello-maui-app] subwindow open(fallback drawn): queued={OpenHarmonySubWindow.Create("maui-demo", 120, 160, 720, 480, "MAUI child")}");
        }
    }

    /// <summary>Drops children the application no longer lists (closed on the shell side).</summary>
    private static void PruneClosedChildren(IApplication application)
    {
        for (int i = s_childWindows.Count - 1; i >= 0; i--)
        {
            if (!application.Windows.Contains(s_childWindows[i]))
            {
                s_childWindows.RemoveAt(i);
            }
        }
    }

    /// <summary>Closes the newest live child: the managed window through CloseWindow (the slice
    /// then asks the shell to destroy its session), the drawn child through the shell command.</summary>
    private static void CloseSubWindow()
    {
        var application = Application.Current;
        if (application is not null)
        {
            PruneClosedChildren(application);
        }
        if (application is not null && s_childWindows.Count > 0)
        {
            Window child = s_childWindows[^1];
            s_childWindows.RemoveAt(s_childWindows.Count - 1);
            application.CloseWindow(child);
            OpenHarmonyBridge.WriteStatus($"[hello-maui-app] subwindow close(managed): queued children={s_childWindows.Count}");
            return;
        }
        s_childWindows.Clear();
        OpenHarmonyBridge.WriteStatus($"[hello-maui-app] subwindow close(drawn): queued={OpenHarmonySubWindow.Close()}");
    }

    /// <summary>The second MAUI window's content: interactive managed views drawn by the
    /// per-window renderer into the subwindow surface (touch feedback proves input routing).
    /// MULTIWINDOW-L2: <paramref name="withWeb"/> adds a WebView whose ArkWeb component is
    /// hosted by the subwindow page's own child pool (the second web host). MULTIWINDOW-L3 M4:
    /// <paramref name="ordinal"/> names this child in its document (title/heading/tap text), so
    /// the two subwindows' eval read-backs prove which window's controller ran the script.</summary>
    private static ContentPage BuildChildWindowPage(bool withWeb = false, int ordinal = 1, bool hashDoc = false, bool stormDoc = false)
    {
        var title = new Label { Text = "MAUI child window", FontSize = 30, HorizontalOptions = LayoutOptions.Center };
        var counter = new Label { Text = "child taps: 0", FontSize = 26, HorizontalOptions = LayoutOptions.Center };
        var button = new Button { Text = "tap the child", FontSize = 30 };
        // Per-window counter: two children must never share input state (L3-M1 no-crosstalk
        // evidence reads each window's own line).
        int childTaps = 0;
        button.Clicked += (_, _) =>
        {
            childTaps++;
            counter.Text = $"child taps: {childTaps}";
            OpenHarmonyBridge.WriteStatus($"[hello-maui-app] child window tap #{childTaps} (window {title.Text})");
        };
        // MULTIWINDOW-L M4 device probe: a text entry in the second window. Tapping it must
        // raise the system IME for the child only (the per-window text focus request), and the
        // typed text must land in this window's Entry (tagged text events).
        var entryStatus = new Label { Text = "child entry: seed", FontSize = 22, HorizontalOptions = LayoutOptions.Center };
        var entry = new Entry { Text = "seed", FontSize = 26, Placeholder = "type in the child" };
        entry.TextChanged += (_, _) =>
        {
            entryStatus.Text = $"child entry: {entry.Text}";
            OpenHarmonyBridge.WriteStatus($"[hello-maui-app] child entry text '{entry.Text}'");
        };
        // MULTIWINDOW-L M4-04 device probe: per-window pinch. The gesture can only fire through
        // the child window's own routed pinch stream (the shell computes it from the child
        // XComponent's two-finger touches, tagged with the child surface id).
        var pinchStatus = new Label { Text = "child pinch: -", FontSize = 22, HorizontalOptions = LayoutOptions.Center };
        var pinchGesture = new PinchGestureRecognizer();
        pinchGesture.PinchUpdated += (_, e) =>
        {
            pinchStatus.Text = $"child pinch: {e.Status} {e.Scale:0.00}";
            OpenHarmonyBridge.WriteStatus($"[hello-maui-app] child pinch {e.Status} scale={e.Scale:0.00}");
        };
        var pinchLabel = new Label { Text = "pinch the child", FontSize = 26, HorizontalOptions = LayoutOptions.Center };
        pinchLabel.GestureRecognizers.Add(pinchGesture);
        // MULTIWINDOW-L M4-01: a continuously running indicator keeps this window rendering every
        // vsync during the dual-window frame-rate round (the primary page has its own spinner).
        var childSpinner = new ActivityIndicator { IsRunning = true, HeightRequest = 24 };
        var children = new List<View> { title, counter, entryStatus, entry, pinchStatus, pinchLabel, childSpinner, button };
        if (withWeb)
        {
            // MULTIWINDOW-L2: the child window's WebView. The document is inline (no network), so
            // the round proves the second ArkWeb host on its own; clicking the heading switches
            // the text, which shows the page really runs inside the child window.
            var webStatus = new Label { Text = "child web: loading", FontSize = 22, HorizontalOptions = LayoutOptions.Center };
            // C5-L3 probe: the hash document carries real '#' bytes (a hex color and body text).
            // With the loadData encoding fix they reach the page; without it the document is
            // truncated at the first '#' (the pre-fix A/B shape). The default/no-# document and
            // the storm document are the regression and SEC7-F probes.
            string childHtml;
            if (stormDoc)
            {
                childHtml = "<html><head><title>CHILD-WEB-STORM-" + ordinal + "</title></head><body style=\"margin:0;background:rgb(16,24,32)\">" +
                    "<h1 id=\"h\" style=\"color:rgb(255,180,80);font-family:sans-serif;font-size:28px\">CHILD STORM " + ordinal + "</h1>" +
                    // 30 navigations, 30 ms apart (~0.9 s): without the shell ask cap every one
                    // enters the managed Navigating path; with it only the burst reaches it.
                    "<script>var n=0;function storm(){n++;if(n>30)return;location.href='https://example.invalid/storm/'+n;setTimeout(storm,30);}setTimeout(storm,400);</script>" +
                    "</body></html>";
            }
            else if (hashDoc)
            {
                childHtml = "<html><head><title>CHILD-WEB-HASH-" + ordinal + "</title></head><body style=\"margin:0;background:#101820\">" +
                    "<h1 id=\"h\" style=\"color:#6ec1ff;font-family:sans-serif;font-size:28px\">CHILD HASH OK " + ordinal + "</h1>" +
                    "<p id=\"p\" style=\"color:#ffb450;font-family:sans-serif;font-size:22px\">tag#value</p>" +
                    "</body></html>";
            }
            else
            {
                childHtml = "<html><head><title>CHILD-WEB-" + ordinal + "</title></head><body style=\"margin:0;background:rgb(16,24,32)\">" +
                    "<h1 id=\"h\" style=\"color:rgb(110,193,255);font-family:sans-serif;font-size:28px\">CHILD WEB OK " + ordinal + "</h1>" +
                    "<script>document.getElementById('h').onclick=function(){this.textContent='CHILD WEB TAP " + ordinal + "';};</script>" +
                    // MULTIWINDOW-L3 B6 device probes: one app-origin-approvable link, one
                    // network-path spelling (the managed channel must refuse it) and one the
                    // sample's own Navigating handler cancels. All three keep the page.
                    "<p style=\"font-family:sans-serif;font-size:22px;margin:8px 0\">" +
                    "<a id=\"ext\" href=\"https://example.invalid/b6c\" style=\"color:rgb(255,180,80)\">external ok link</a> " +
                    "<a id=\"veto\" href=\"//evil.invalid/x\" style=\"color:rgb(255,120,120)\">external veto link</a> " +
                    "<a id=\"deny\" href=\"https://example.invalid/b6c-deny\" style=\"color:rgb(180,255,120)\">external deny link</a>" +
                    "</p>" +
                    "</body></html>";
            }
            var web = new WebView
            {
                HeightRequest = 220,
                Source = new HtmlWebViewSource { Html = childHtml },
            };
            web.Navigating += (_, e) =>
            {
                OpenHarmonyBridge.WriteStatus($"[hello-maui-app] child web navigating: {e.Url}");
                // B6 device probe: the app's own veto. The managed child handler raises Navigating
                // for the cancelled load; cancelling here must leave the load blocked and the
                // child page untouched (no approval is sent back). The SEC7-F storm navigations
                // are vetoed the same way so the storm document survives to keep firing.
                if (e.Url != null && (e.Url.StartsWith("https://example.invalid/b6c-deny", StringComparison.Ordinal) ||
                    e.Url.StartsWith("https://example.invalid/storm/", StringComparison.Ordinal)))
                {
                    e.Cancel = true;
                    OpenHarmonyBridge.WriteStatus($"[hello-maui-app] child web navigating cancelled: {e.Url}");
                }
            };
            web.Navigated += (_, e) => OpenHarmonyBridge.WriteStatus($"[hello-maui-app] child web navigated: {e.Result} {e.Url}");
            // The eval rounds prove the child host's eval sink: the title read runs on the child
            // window's own controller, and the click+read mutates the child document's DOM (the
            // interaction evidence that does not need uitest pointer injection). C5-L3: the hash
            // document also reads the '#'-bearing paragraph, so a truncated body shows as NO-P.
            web.Navigated += async (_, _) =>
            {
                var documentTitle = await web.EvaluateJavaScriptAsync("document.title || 'no-title'");
                OpenHarmonyBridge.WriteStatus($"[hello-maui-app] child web eval title='{documentTitle}'");
                var tapped = await web.EvaluateJavaScriptAsync(
                    "(function(){var h=document.getElementById('h');if(!h)return 'NO-H';h.click();return h.textContent;})()");
                if (hashDoc)
                {
                    var hashText = await web.EvaluateJavaScriptAsync(
                        "(function(){var p=document.getElementById('p');return p?p.textContent:'NO-P';})()");
                    OpenHarmonyBridge.WriteStatus($"[hello-maui-app] child web hash p='{hashText}' tap='{tapped}'");
                    webStatus.Text = $"child web hash p='{hashText}'";
                }
                else
                {
                    OpenHarmonyBridge.WriteStatus($"[hello-maui-app] child web tap text='{tapped}'");
                    webStatus.Text = $"child web eval='{documentTitle}' tap='{tapped}'";
                }
            };
            // The web sits at the top of the child page so the 720x480 window shows it without
            // scrolling (the M4 probing controls follow below).
            var webFirst = new List<View> { webStatus, web };
            webFirst.AddRange(children);
            children = webFirst;
        }
        var childLayout = new VerticalStackLayout { Padding = 32, Spacing = 24 };
        foreach (var element in children)
        {
            childLayout.Children.Add(element);
        }
        return new ContentPage { Content = childLayout };
    }

    /// <summary>
    /// C5-L3 primary-window probe: pushes a data WebView onto the main window's navigation page
    /// (the app://web/datahash and app://web/datanohash triggers). The hash document carries
    /// '#' bytes in a hex color and in body text; the eval read-back logs the paragraph and its
    /// computed color, so the pre-fix truncation (NO-P / NO-H) and the fixed document are both
    /// machine-readable from the status line.
    /// </summary>
    private static void RunMainDataProbe(bool withHash)
    {
        if (CurrentWindow() is not Window window)
        {
            OpenHarmonyBridge.WriteStatus("[hello-maui-app] main data probe: no main window");
            return;
        }
        if (window.Page is FlyoutPage { Detail: TabbedPage { CurrentPage: NavigationPage nav } })
        {
            _ = nav.PushAsync(BuildMainDataPage(withHash));
            OpenHarmonyBridge.WriteStatus($"[hello-maui-app] main data probe open: hash={withHash}");
        }
        else
        {
            OpenHarmonyBridge.WriteStatus("[hello-maui-app] main data probe: main navigation page unavailable");
        }
    }

    private static ContentPage BuildMainDataPage(bool withHash)
    {
        var status = new Label { Text = "main data: loading", FontSize = 22 };
        string docTitle = withHash ? "MAIN-DATA-HASH" : "MAIN-DATA-NOHASH";
        string doc = withHash
            ? "<html><head><title>" + docTitle + "</title></head><body>" +
              "<h1 id=\"h\" style=\"color:#3366ff;font-family:sans-serif;font-size:28px\">MAIN HASH</h1>" +
              "<p id=\"p\" style=\"font-family:sans-serif;font-size:22px\">tag#value</p>" +
              "</body></html>"
            : "<html><head><title>" + docTitle + "</title></head><body>" +
              "<h1 id=\"h\" style=\"color:rgb(51,102,255);font-family:sans-serif;font-size:28px\">MAIN NOHASH</h1>" +
              "<p id=\"p\" style=\"font-family:sans-serif;font-size:22px\">plain value</p>" +
              "</body></html>";
        var web = new WebView
        {
            HeightRequest = 220,
            Source = new HtmlWebViewSource { Html = doc },
        };
        web.Navigated += async (_, _) =>
        {
            var title = await web.EvaluateJavaScriptAsync("document.title || 'no-title'");
            var paragraph = await web.EvaluateJavaScriptAsync(
                "(function(){var p=document.getElementById('p');return p?p.textContent:'NO-P';})()");
            var color = await web.EvaluateJavaScriptAsync(
                "(function(){var h=document.getElementById('h');return h?getComputedStyle(h).color:'NO-H';})()");
            OpenHarmonyBridge.WriteStatus(
                $"[hello-maui-app] main data probe hash={withHash} title='{title}' p='{paragraph}' color='{color}'");
            status.Text = $"main data hash={withHash}: p='{paragraph}'";
        };
        return new ContentPage
        {
            Title = docTitle,
            Content = new VerticalStackLayout { Padding = 24, Spacing = 12, Children = { status, web } },
        };
    }

    /// <summary>
    /// Managed-driven subwindow demo: create -> move -> resize -> close, one status line per
    /// step. Every shell transition is also logged by the Changed handler in BuildPage, so a
    /// device round reads the whole sequence out of hilog without touching the page.
    /// </summary>
    private static void RunSubWindowDemo()
    {
        _ = Task.Run(async () =>
        {
            OpenHarmonyBridge.WriteStatus($"[hello-maui-app] subwindow demo: supported={OpenHarmonySubWindow.IsSupported} create queued={OpenHarmonySubWindow.Create("maui-demo", 120, 160, 720, 480, "MAUI child")}");
            await Task.Delay(3000);
            OpenHarmonyBridge.WriteStatus($"[hello-maui-app] subwindow demo: move queued={OpenHarmonySubWindow.Move(420, 360)}");
            await Task.Delay(3000);
            OpenHarmonyBridge.WriteStatus($"[hello-maui-app] subwindow demo: resize queued={OpenHarmonySubWindow.Resize(900, 600)}");
            await Task.Delay(3000);
            OpenHarmonyBridge.WriteStatus($"[hello-maui-app] subwindow demo: close queued={OpenHarmonySubWindow.Close()}");
        });
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

        // MULTIWINDOW-M demo: an application subwindow driven by the managed slice
        // (OpenHarmonySubWindow). "Open" creates the shell-drawn child under the main window,
        // "Move"/"Resize" drive it, "Close" destroys it; the shell reports lifecycle, rect and
        // touch events back into this page (the state line below). The child itself is
        // draggable and its close button destroys it, so both input paths are exercised.
        var subWindowStatus = new Label { Text = "subwindow: closed", FontSize = 22 };
        var subWindowOpen = new Button { Text = "Open subwindow", FontSize = 24 };
        var subWindowMove = new Button { Text = "Move subwindow", FontSize = 24 };
        var subWindowResize = new Button { Text = "Resize subwindow", FontSize = 24 };
        var subWindowClose = new Button { Text = "Close subwindow", FontSize = 24 };
        subWindowOpen.Clicked += (_, _) =>
        {
            subWindowStatus.Text = OpenHarmonySubWindow.IsSupported
                ? "subwindow: managed OpenWindow queued"
                : "subwindow: the shell reports no subwindow sink";
            OpenManagedSubWindow();
        };
        subWindowMove.Clicked += (_, _) =>
        {
            if (s_childWindows.Count > 0)
            {
                OpenHarmonyBridge.WriteStatus("[hello-maui-app] subwindow move: the managed child is moved with the OS title bar");
                return;
            }
            OpenHarmonySubWindow.Move(420, 360);
        };
        subWindowResize.Clicked += (_, _) =>
        {
            if (s_childWindows.Count > 0)
            {
                OpenHarmonyBridge.WriteStatus("[hello-maui-app] subwindow resize: the managed child follows its surface size");
                return;
            }
            OpenHarmonySubWindow.Resize(900, 600);
        };
        subWindowClose.Clicked += (_, _) => CloseSubWindow();
        OpenHarmonySubWindow.Changed += (_, e) =>
        {
            // Device evidence: every transition reaches the managed side (and the status file).
            // M4: text events log their payload and key events their code/type, so a device
            // round can read the per-window input routing straight out of hilog.
            string m4Input = e.Kind switch
            {
                OpenHarmonySubWindowEventKind.TextInput or OpenHarmonySubWindowEventKind.TextSubmitted =>
                    $" text='{e.Text}'",
                OpenHarmonySubWindowEventKind.TextComposition => $" composition='{e.Text}' offset={e.CompositionOffset}",
                OpenHarmonySubWindowEventKind.Key => $" key={e.KeyCode}/{e.KeyEventType}",
                _ => string.Empty,
            };
            OpenHarmonyBridge.WriteStatus($"[hello-maui-app] subwindow event {e.Kind}: id={e.WindowId} surface={e.SurfaceId} rect={e.Bounds.X:0},{e.Bounds.Y:0} {e.Bounds.Width:0}x{e.Bounds.Height:0}{m4Input}{(e.Message is null ? "" : " / " + e.Message)}");
            Microsoft.Maui.ApplicationModel.MainThread.BeginInvokeOnMainThread(() =>
                subWindowStatus.Text = $"subwindow {e.Kind}: id={e.WindowId} rect={e.Bounds.X:0},{e.Bounds.Y:0} {e.Bounds.Width:0}x{e.Bounds.Height:0}{(e.Message is null ? "" : " / " + e.Message)}");
        };
        OpenHarmonySubWindow.Touched += (_, e) =>
        {
            OpenHarmonyBridge.WriteStatus($"[hello-maui-app] subwindow touch action={e.Action} ({e.X:0},{e.Y:0}) pointers={e.PointerCount}");
            Microsoft.Maui.ApplicationModel.MainThread.BeginInvokeOnMainThread(() =>
                subWindowStatus.Text = $"subwindow touch: action={e.Action} ({e.X:0},{e.Y:0}) pointers={e.PointerCount}");
        };
        // MULTIWINDOW-L M4-04: the per-window pinch stream. A report tagged with a window id is
        // the device evidence that each window's gesture routing is independent.
        OpenHarmonyBridge.WindowPinch += (id, phase, scale, x, y) =>
            OpenHarmonyBridge.WriteStatus($"[hello-maui-app] per-window pinch window={id} phase={phase} scale={scale:0.00} at {x:0},{y:0}");
        // MULTIWINDOW-L M4-01/M4-06: per-window frame pacing evidence (framestats lines).
        WindowFrameStats.Install();
        var subWindowRow = new HorizontalStackLayout { Spacing = 8 };
        subWindowRow.Add(subWindowOpen);
        subWindowRow.Add(subWindowMove);
        subWindowRow.Add(subWindowResize);
        subWindowRow.Add(subWindowClose);

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
        layout.Add(subWindowRow);
        layout.Add(subWindowStatus);
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
