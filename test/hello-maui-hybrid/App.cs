// Subwindow hybrid/Blazor asset-bridge sample (L3 tail, productized from the HYBRID-DEVICE round).
//
// The main window carries one HybridWebView (main-window asset bridge) and the subwindow triggers;
// the managed child window (Application.OpenWindow -> the shell's subwindow XComponent) carries:
//   * openweb                : HybridWebView (wwwroot/child-hybrid.html, stock
//                              _framework/hybridwebview.js + invoke/raw/host probes) plus a plain
//                              WebView carrying the B6 navigation-veto probe links;
//   * openweb/b6/deny|ok|veto: the same child, auto-clicking one B6 probe link after load
//                              (deny = the sample's own Navigating cancel, ok = managed ask ->
//                              approval -> reload attempt, veto = managed fail-closed refusal);
//   * openblazor             : BlazorWebView (#app mount through the subwindow payload) plus the
//                              same child hybrid.
// Every probe is automatic (managed eval read-backs + RawMessageReceived), so one device round
// reads the whole asset bridge out of hilog/dotnet-status without touching the screen.
//
// Triggers (warm or cold, via `aa start -U`):
//   app://subwindow/openweb  app://subwindow/openweb/b6/deny  .../b6/ok  .../b6/veto
//   app://subwindow/openblazor  app://subwindow/open  app://subwindow/close
//
// Bundle note: the hap keeps com.example.hellomauiapp because the pack's prebuilt UI-shell abc
// carries that bundle name (the device resolves <bundle>/<module>/ets/entryability/EntryAbility
// against the abc records); see README.md "Bundle name".
using Microsoft.AspNetCore.Components.WebView.Maui;
using Microsoft.Maui;
using Microsoft.Maui.Controls;
using Microsoft.Maui.Platform;
using Microsoft.OpenHarmony.Hosting;
using System.Diagnostics.CodeAnalysis;

namespace HelloMauiHybrid;

public sealed class App : Application
{
    private const string LogTag = "[hello-maui-hybrid]";

    /// <summary>
    /// Answers a JS-&gt;.NET invocation with a JSON string that carries the hybrid's identity, so
    /// the device run can prove the invoke channel routed the request to the right window's
    /// handler (the main window answers "MAIN-echo:...", the child window "CH&lt;ordinal&gt;-echo:...").
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
    private static void SetStatus(VisualElement element, Label label, string text)
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
        OpenHarmonyBridge.Activation += OnActivation;
        return new Window(BuildMainPage()) { Title = "hello-maui-hybrid" };
    }

    protected override void OnStart()
    {
        base.OnStart();
        if (CurrentWindow() is { } window)
        {
            ApplyActivationTitle(window, "hello-maui-hybrid boot");
        }
    }

    /// <summary>Handles one warm activation the shell delivered (onNewWant).</summary>
    internal static void OnActivation(OpenHarmonyActivationEventArgs activation)
    {
        string uri = activation.Uri ?? string.Empty;
        OpenHarmonyBridge.WriteStatus(
            $"{LogTag} activation seq={activation.Sequence} uri='{uri}' action='{activation.Action}'");
        if (CurrentWindow() is { } window)
        {
            string suffix = uri.Length > 64 ? uri[..64] : uri;
            ApplyActivationTitle(window, $"activation {activation.Sequence}: {suffix}");
        }
        // Subwindow triggers: "openweb" (the hybrid child), its B6 variants, "openblazor" and
        // "close". "openweb" is checked before the plain "open" prefix.
        if (uri.StartsWith("app://subwindow/openweb", StringComparison.OrdinalIgnoreCase))
        {
            string? b6 = uri.Contains("/b6/deny", StringComparison.OrdinalIgnoreCase) ? "deny"
                : uri.Contains("/b6/ok", StringComparison.OrdinalIgnoreCase) ? "ok"
                : uri.Contains("/b6/veto", StringComparison.OrdinalIgnoreCase) ? "veto"
                : null;
            OpenManagedSubWindow(withWeb: true, b6: b6);
        }
        else if (uri.StartsWith("app://subwindow/openblazor", StringComparison.OrdinalIgnoreCase))
        {
            OpenManagedSubWindow(withBlazor: true);
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

    // The live managed children in open order (the shell session registry carries up to two).
    private static readonly List<Window> s_childWindows = new();
    private const int MaxManagedChildren = 2;

    /// <summary>
    /// Opens a real MAUI child window. Application.OpenWindow routes through the slice's
    /// application handler, which asks the shell for a subwindow XComponent and binds the window
    /// when the surface reports in; when the managed path is unavailable the shell-drawn child is
    /// created instead so the trigger never leaves the user with nothing.
    /// </summary>
    private static void OpenManagedSubWindow(bool withWeb = false, bool withBlazor = false, string? b6 = null)
    {
        var application = Application.Current;
        if (application is null)
        {
            return;
        }
        PruneClosedChildren(application);
        if (s_childWindows.Count >= MaxManagedChildren)
        {
            OpenHarmonyBridge.WriteStatus($"{LogTag} subwindow open: both managed child windows are already open");
            return;
        }
        var child = new Window(BuildChildWindowPage(withWeb, s_childWindows.Count + 1, withBlazor, b6))
        {
            Title = $"MAUI child {s_childWindows.Count + 1}",
        };
        s_childWindows.Add(child);
        application.OpenWindow(child);
        var result = (application.Handler as OpenHarmonyApplicationHandler)?.LastOpenWindowResult
            ?? OpenHarmonyOpenWindowResult.None;
        OpenHarmonyBridge.WriteStatus(
            $"{LogTag} subwindow open(managed){(withWeb ? " web" : string.Empty)}{(withBlazor ? " blazor" : string.Empty)}{(b6 is null ? string.Empty : " b6-" + b6)}: supported={OpenHarmonySubWindow.IsSupported} children={s_childWindows.Count} result={result}");
        if (result != OpenHarmonyOpenWindowResult.OpenedWindow)
        {
            s_childWindows.Remove(child);
            OpenHarmonyBridge.WriteStatus(
                $"{LogTag} subwindow open(fallback drawn): queued={OpenHarmonySubWindow.Create("maui-demo", 120, 160, 720, 480, "MAUI child")}");
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

    /// <summary>Closes the newest live child.</summary>
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
            OpenHarmonyBridge.WriteStatus($"{LogTag} subwindow close(managed): queued children={s_childWindows.Count}");
            return;
        }
        s_childWindows.Clear();
        OpenHarmonyBridge.WriteStatus($"{LogTag} subwindow close(drawn): queued={OpenHarmonySubWindow.Close()}");
    }

    /// <summary>
    /// The main window: one main-window HybridWebView (the asset bridge on the primary window,
    /// auto-probed) plus the subwindow triggers and a tap counter that proves the main window
    /// stays interactive while child windows are open.
    /// </summary>
    private static ContentPage BuildMainPage()
    {
        var title = new Label { Text = "MAUI hybrid subwindow on OpenHarmony", FontSize = 36 };
        var triggers = new Label
        {
            Text = "aa -U app://subwindow/openweb[/b6/deny|/b6/ok|/b6/veto] | openblazor | open | close",
            FontSize = 18,
        };
        var hybridStatus = new Label { Text = "main hybrid: loading hybrid-main.html", FontSize = 20 };
        var hybridRaw = new Label { Text = "main hybrid raw: (none)", FontSize = 20 };
        var hybrid = new HybridWebView
        {
            HybridRoot = "wwwroot",
            DefaultFile = "hybrid-main.html",
            HeightRequest = 240,
        };
        hybrid.Invoker = new EchoInvoker("MAIN");
        hybrid.RawMessageReceived += (_, e) =>
        {
            OpenHarmonyBridge.WriteStatus($"{LogTag} main hybrid raw: {e.Message}");
            SetStatus(hybrid, hybridRaw, $"main hybrid raw: {e.Message}");
        };
        bool probeStarted = false;
        hybrid.HandlerChanged += (_, _) =>
        {
            if (probeStarted || hybrid.Handler is null)
            {
                return;
            }
            probeStarted = true;
            _ = ProbeMainHybridAsync(hybrid, hybridStatus);
        };

        var counterStatus = new Label { Text = "main taps: 0", FontSize = 22 };
        var tapButton = new Button { Text = "tap the main window", FontSize = 24 };
        int taps = 0;
        tapButton.Clicked += (_, _) =>
        {
            taps++;
            counterStatus.Text = $"main taps: {taps}";
            OpenHarmonyBridge.WriteStatus($"{LogTag} main window tap #{taps}");
        };

        var openWeb = new Button { Text = "Open child: web + hybrid", FontSize = 24 };
        openWeb.Clicked += (_, _) => OpenManagedSubWindow(withWeb: true);
        var openBlazor = new Button { Text = "Open child: Blazor + hybrid", FontSize = 24 };
        openBlazor.Clicked += (_, _) => OpenManagedSubWindow(withBlazor: true);
        var close = new Button { Text = "Close child", FontSize = 24 };
        close.Clicked += (_, _) => CloseSubWindow();

        return new ContentPage
        {
            Content = new VerticalStackLayout
            {
                Padding = 24,
                Spacing = 12,
                Children =
                {
                    title,
                    triggers,
                    hybridStatus,
                    hybridRaw,
                    hybrid,
                    tapButton,
                    counterStatus,
                    openWeb,
                    openBlazor,
                    close,
                },
            },
        };
    }

    /// <summary>
    /// The child window's content. <paramref name="withWeb"/> adds the plain WebView (inline
    /// B6 probe document) plus a HybridWebView; <paramref name="withBlazor"/> adds the
    /// BlazorWebView plus a HybridWebView; <paramref name="b6"/> names one B6 probe link the
    /// plain web clicks after load (deny/ok/veto).
    /// </summary>
    private static ContentPage BuildChildWindowPage(bool withWeb = false, int ordinal = 1, bool withBlazor = false, string? b6 = null)
    {
        var title = new Label { Text = $"MAUI child {ordinal}", FontSize = 28, HorizontalOptions = LayoutOptions.Center };
        var counter = new Label { Text = "child taps: 0", FontSize = 22, HorizontalOptions = LayoutOptions.Center };
        var button = new Button { Text = "tap the child", FontSize = 26 };
        int childTaps = 0;
        button.Clicked += (_, _) =>
        {
            childTaps++;
            counter.Text = $"child taps: {childTaps}";
            OpenHarmonyBridge.WriteStatus($"{LogTag} child {ordinal} tap #{childTaps}");
        };
        var children = new List<View> { title, counter, button };
        if (withWeb)
        {
            // The child window's HybridWebView (the subwindow asset bridge) leads the page so the
            // rendered probe is visible; the plain WebView (the B6 probe document) follows below.
            // The hybrid claims a slot of this window's own ArkWeb pool, loads its page from
            // https://0.0.1/ (the shell serves the extracted payload, _framework/hybridwebview.js
            // included) and routes the child-tagged invokes to this window's handler (the echo tag
            // CH<ordinal> names the window whose invoker answered).
            var (childHybrid, childHybridStatus, childHybridRaw) = BuildChildHybrid(ordinal);
            var webStatus = new Label { Text = "child web: loading", FontSize = 20, HorizontalOptions = LayoutOptions.Center };
            var web = BuildChildWeb(ordinal, b6, webStatus);
            var webFirst = new List<View> { childHybridStatus, childHybridRaw, childHybrid, webStatus, web };
            webFirst.AddRange(children);
            children = webFirst;
        }
        if (withBlazor)
        {
            // The child window's BlazorWebView: its "blazor" registration is served by the
            // subwindow page from the extracted payload (origin https://0.0.0.0/), which also
            // installs the Blazor bootstrap; the probe reads the mounted BlazorCounter back.
            var blazorStatus = new Label { Text = $"child blazor {ordinal}: loading", FontSize = 20, HorizontalOptions = LayoutOptions.Center };
            var childBlazor = BuildBlazorWebView();
            var (childHybrid, childHybridStatus, childHybridRaw) = BuildChildHybrid(ordinal);
            var blazorFirst = new List<View> { blazorStatus, childBlazor, childHybridStatus, childHybridRaw, childHybrid };
            blazorFirst.AddRange(children);
            children = blazorFirst;
            _ = ProbeChildBlazorAsync(childBlazor, blazorStatus, ordinal);
        }
        var childLayout = new VerticalStackLayout { Padding = 24, Spacing = 16 };
        foreach (var element in children)
        {
            childLayout.Children.Add(element);
        }
        return new ContentPage { Content = childLayout };
    }

    /// <summary>
    /// The child window's plain WebView: an inline document (no network) with the B6 navigation
    /// probes - one app-origin-approvable link (ok), one network-path spelling (veto) and one the
    /// sample's own Navigating handler cancels (deny). The managed probe reads the title/tap text
    /// through the child eval sink; when <paramref name="b6"/> is set it role-clicks the matching
    /// link once, so the shell ask/approval chain runs without screen interaction.
    /// </summary>
    private static WebView BuildChildWeb(int ordinal, string? b6, Label webStatus)
    {
        var web = new WebView
        {
            HeightRequest = 220,
            Source = new HtmlWebViewSource
            {
                // No '#' anywhere: ArkWeb's loadData builds a data: URL and a raw '#' starts the
                // URL fragment, which would truncate the document body.
                Html = "<html><head><title>CHILD-WEB-" + ordinal + "</title></head><body style=\"margin:0;background:rgb(16,24,32)\">" +
                    "<h1 id=\"h\" style=\"color:rgb(110,193,255);font-family:sans-serif;font-size:28px\">CHILD WEB OK " + ordinal + "</h1>" +
                    "<script>document.getElementById('h').onclick=function(){this.textContent='CHILD WEB TAP " + ordinal + "';};</script>" +
                    "<p style=\"font-family:sans-serif;font-size:22px;margin:8px 0\">" +
                    "<a id=\"ext\" href=\"https://example.invalid/b6c\" style=\"color:rgb(255,180,80)\">external ok link</a> " +
                    "<a id=\"veto\" href=\"//evil.invalid/x\" style=\"color:rgb(255,120,120)\">external veto link</a> " +
                    "<a id=\"deny\" href=\"https://example.invalid/b6c-deny\" style=\"color:rgb(180,255,120)\">external deny link</a>" +
                    "</p>" +
                    "</body></html>",
            },
        };
        web.Navigating += (_, e) =>
        {
            OpenHarmonyBridge.WriteStatus($"{LogTag} child web navigating: {e.Url}");
            // B6 device probe: the app's own veto. The managed child handler raises Navigating
            // for the cancelled load; cancelling here must leave the load blocked and the
            // child page untouched (no approval is sent back).
            if (e.Url != null && e.Url.StartsWith("https://example.invalid/b6c-deny", StringComparison.Ordinal))
            {
                e.Cancel = true;
                OpenHarmonyBridge.WriteStatus($"{LogTag} child web navigating cancelled: b6c-deny");
            }
        };
        web.Navigated += (_, e) => OpenHarmonyBridge.WriteStatus($"{LogTag} child web navigated: {e.Result} {e.Url}");
        bool probed = false;
        web.Navigated += async (_, e) =>
        {
            if (probed || e.Result != WebNavigationResult.Success)
            {
                return;
            }
            probed = true;
            // The eval round proves the child host's eval sink and the document identity.
            var documentTitle = await web.EvaluateJavaScriptAsync("document.title || 'no-title'");
            OpenHarmonyBridge.WriteStatus($"{LogTag} child web {ordinal} eval title='{documentTitle}'");
            var tapped = await web.EvaluateJavaScriptAsync(
                "(function(){var h=document.getElementById('h');h.click();return h.textContent;})()");
            OpenHarmonyBridge.WriteStatus($"{LogTag} child web {ordinal} tap text='{tapped}'");
            webStatus.Text = $"child web {ordinal}: eval='{documentTitle}' tap='{tapped}'";
            if (b6 is not null)
            {
                string elementId = b6 switch
                {
                    "ok" => "ext",
                    "veto" => "veto",
                    _ => "deny",
                };
                OpenHarmonyBridge.WriteStatus($"{LogTag} child web {ordinal} b6 {b6}: clicking #{elementId}");
                string clickResult = await web.EvaluateJavaScriptAsync(
                    $"(function(){{var e=document.getElementById('{elementId}');if(!e){{return 'missing';}}e.click();return 'clicked';}})()");
                OpenHarmonyBridge.WriteStatus($"{LogTag} child web {ordinal} b6 {b6}: click={clickResult}");
            }
        };
        return web;
    }

    /// <summary>
    /// The child window's HybridWebView and its automatic probes. The control claims a slot of the
    /// child window's own ArkWeb pool; the subwindow page serves https://0.0.1/ from the extracted
    /// payload and routes the child-tagged invokes to this window's handler. The page
    /// (wwwroot/child-hybrid.html) loads the stock _framework/hybridwebview.js, sends
    /// __hwvSendMessage raw messages and awaits one __hwvInvokeDotNet call.
    /// </summary>
    private static (HybridWebView Web, Label Status, Label RawStatus) BuildChildHybrid(int ordinal)
    {
        var status = new Label { Text = $"child hybrid {ordinal}: loading", FontSize = 20, HorizontalOptions = LayoutOptions.Center };
        var rawStatus = new Label { Text = $"child hybrid {ordinal} raw: (none)", FontSize = 18, HorizontalOptions = LayoutOptions.Center };
        var hybrid = new HybridWebView
        {
            HybridRoot = "wwwroot",
            DefaultFile = "child-hybrid.html",
            HeightRequest = 240,
        };
        hybrid.Invoker = new EchoInvoker($"CH{ordinal}");
        hybrid.RawMessageReceived += (_, e) =>
        {
            OpenHarmonyBridge.WriteStatus($"{LogTag} child hybrid {ordinal} raw: {e.Message}");
            SetStatus(hybrid, rawStatus, $"child hybrid {ordinal} raw: {e.Message}");
        };
        bool probeStarted = false;
        hybrid.HandlerChanged += (_, _) =>
        {
            if (probeStarted || hybrid.Handler is null)
            {
                return;
            }
            probeStarted = true;
            _ = ProbeChildHybridAsync(hybrid, status, ordinal);
        };
        return (hybrid, status, rawStatus);
    }

    /// <summary>
    /// The main window's hybrid probe: polls the page through the main eval sink, sends the
    /// host -&gt; page raw message once the shell stamped the document id, and stops when the
    /// invoke result and the host-received marker are both visible.
    /// </summary>
    private static async Task ProbeMainHybridAsync(HybridWebView hybrid, Label status)
    {
        OpenHarmonyBridge.WriteStatus($"{LogTag} main hybrid handler connected; probing");
        bool hostMessageSent = false;
        for (int probe = 0; probe < 20; probe++)
        {
            await Task.Delay(2000);
            string title = await ReadEvalAsync(hybrid, "document.title || 'no-title'");
            string body = await ReadEvalAsync(hybrid, "(document.getElementById('probe')||{}).textContent || ''");
            string result = await ReadEvalAsync(hybrid, "(document.getElementById('result')||{}).textContent || ''");
            string hostmsg = await ReadEvalAsync(hybrid, "(document.getElementById('hostmsg')||{}).textContent || ''");
            string marker = await ReadEvalAsync(hybrid, "window.__ohHybridId || 'none'");
            OpenHarmonyBridge.WriteStatus(
                $"{LogTag} main hybrid probe[{probe}]: title='{title}' probe='{body}' result='{result}' host='{hostmsg}' marker='{marker}'");
            SetStatus(hybrid, status, $"main hybrid: {title} | {body} | {result} | {hostmsg}");
            if (!hostMessageSent && !marker.Contains("none", StringComparison.Ordinal) && marker.Length > 4)
            {
                hostMessageSent = true;
                hybrid.SendRawMessage("main-hybrid-host");
                OpenHarmonyBridge.WriteStatus($"{LogTag} main hybrid host message sent");
            }
            if ((result.Contains("invoke-result", StringComparison.Ordinal) &&
                 hostmsg.Contains("host-received:", StringComparison.Ordinal)) ||
                title.Contains("ERROR", StringComparison.Ordinal))
            {
                break;
            }
        }
    }

    /// <summary>
    /// Polls the child hybrid page through the child eval sink and records one status line per
    /// attempt; sends the host -&gt; page raw message once the document carries this
    /// registration's stamped id, and stops when the invoke result and the host-received marker
    /// are both visible (or the page reported an error).
    /// </summary>
    private static async Task ProbeChildHybridAsync(HybridWebView hybrid, Label status, int ordinal)
    {
        OpenHarmonyBridge.WriteStatus($"{LogTag} child hybrid {ordinal} handler connected; probing");
        bool hostMessageSent = false;
        for (int probe = 0; probe < 20; probe++)
        {
            await Task.Delay(2000);
            string title = await ReadEvalAsync(hybrid, "document.title || 'no-title'");
            string body = await ReadEvalAsync(hybrid, "(document.getElementById('probe')||{}).textContent || ''");
            string result = await ReadEvalAsync(hybrid, "(document.getElementById('result')||{}).textContent || ''");
            string hostmsg = await ReadEvalAsync(hybrid, "(document.getElementById('hostmsg')||{}).textContent || ''");
            string marker = await ReadEvalAsync(hybrid, "window.__ohHybridId || 'none'");
            OpenHarmonyBridge.WriteStatus(
                $"{LogTag} child hybrid {ordinal} probe[{probe}]: title='{title}' probe='{body}' result='{result}' host='{hostmsg}' marker='{marker}'");
            SetStatus(hybrid, status, $"child hybrid {ordinal}: {title} | {body} | {result} | {hostmsg}");
            if (!hostMessageSent && !marker.Contains("none", StringComparison.Ordinal) && marker.Length > 4)
            {
                hostMessageSent = true;
                hybrid.SendRawMessage($"child-hybrid-host-{ordinal}");
                OpenHarmonyBridge.WriteStatus($"{LogTag} child hybrid {ordinal} host message sent");
            }
            if ((result.Contains("invoke-result", StringComparison.Ordinal) &&
                 hostmsg.Contains("host-received:", StringComparison.Ordinal)) ||
                title.Contains("ERROR", StringComparison.Ordinal))
            {
                break;
            }
        }
    }

    /// <summary>
    /// Polls the child window's Blazor page through the handler's eval until the root component
    /// has mounted (the #app container carries the BlazorCounter heading/count) and records one
    /// status line per attempt.
    /// </summary>
    private static async Task ProbeChildBlazorAsync(BlazorWebView blazor, Label status, int ordinal)
    {
        for (int probe = 0; probe < 15; probe++)
        {
            await Task.Delay(2000);
            if (blazor.Handler is not OpenHarmonyBlazorWebViewHandler handler)
            {
                continue;
            }
            string snapshot = await handler.EvaluateJavaScriptAsync(
                "(function(){var a=document.getElementById('app');return JSON.stringify({app:a?a.innerText.slice(0,140):'no-app',dispatch:typeof window.__dispatchMessageCallback,blazor:typeof window.Blazor});})()")
                ?? string.Empty;
            OpenHarmonyBridge.WriteStatus($"{LogTag} child blazor {ordinal} probe[{probe}]: {snapshot}");
            if (snapshot.Contains("count:", StringComparison.Ordinal) ||
                snapshot.Contains("BlazorWebView component", StringComparison.Ordinal))
            {
                SetStatus(blazor, status, $"child blazor {ordinal}: mounted ({snapshot})");
                break;
            }
        }
    }

    /// <summary>Null-safe eval read used by the hybrid probes.</summary>
    private static async Task<string> ReadEvalAsync(HybridWebView web, string script)
        => await web.EvaluateJavaScriptAsync(script) ?? string.Empty;

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
            OpenHarmonyBridge.WriteStatus($"{LogTag} activation title dispatch failed: {ex.GetType().Name}");
        }
    }

    /// <summary>
    /// The BlazorWebView for the child window (the same wiring the demo uses): HostPage
    /// wwwroot/index.html is served from the Blazor origin (https://0.0.0.0/) by the subwindow
    /// page, which also installs the bootstrap; the root component attaches to #app.
    /// NativeAOT root: the WebView renderer creates the root component through
    /// ActivatorUtilities over RootComponent.ComponentType, and that property carries no
    /// DynamicallyAccessedMembers annotation, so a trimmed publish would remove the
    /// component's constructor and the attach fails. All is the safe root (public ctors +
    /// the members the activator reflects over).
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
}
