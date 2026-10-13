// WEB-AUTH device probe (opt-in: build with -p:WebAuthProbe=true, which defines
// WEBAUTH_PROBE). It drives Microsoft.Maui.Authentication.WebAuthenticator through its real
// OpenHarmony flow from the warm activation path (App.OnActivation, which subscribes after
// OpenHarmonyAppLinks owns the cold-start wants):
//
//   aa start ... -U "app://webauth/start"    -> AuthenticateAsync opens the browser and awaits
//   aa start ... -U "app://webauth/cancel"   -> cancels the pending await (caller cancellation)
//   aa start ... -U "app://webauth/timeout"  -> starts with a 3 s caller timeout
//   aa start ... -U "app://webauth/loopback" -> loopback flow on the default probe port: the
//                                               browser is opened at the loopback callback URL
//                                               so the system browser itself reaches the app's
//                                               one-shot listener (no scheme chooser)
//   aa start ... -U "app://webauth/loopback/53123" -> same on an explicit port
//   aa start ... -U "app://webauth/loopback-localhost[/<port>]" -> the same flow on a
//                                               localhost route: the listener then also arms
//                                               the IPv6 loopback socket (best-effort), so the
//                                               browser's own localhost resolution reaches it
//   aa start ... -U "myapp://callback?..."   -> the WebAuthenticator itself consumes this
//
// The state line goes to dotnet-status.txt and, because the status file is unreadable from a
// device shell, to the window title as well: the shell logs every title application to hilog
// ([maui] window title applied), which is the device-visible evidence channel.
#if WEBAUTH_PROBE
using Microsoft.Maui;
using Microsoft.Maui.Authentication;
using Microsoft.Maui.Controls;
using Microsoft.OpenHarmony.Hosting;

namespace HelloMauiApp;

internal static class WebAuthProbe
{
    private static CancellationTokenSource? s_pending;

    /// <summary>The port the loopback trigger listens on when the activation carries none.</summary>
    private const int DefaultLoopbackPort = 53199;

    /// <summary>Handles one warm activation addressed to the probe (App.OnActivation calls it).</summary>
    public static void Handle(string uri)
    {
        if (uri.StartsWith("app://webauth/loopback-localhost", StringComparison.OrdinalIgnoreCase))
        {
            // WEBAUTH-LOOPBACK v6 half (TOUCH-PASTE round): the same one-shot flow on a
            // localhost route. The listener binds IPv4 and best-effort IPv6 loopback, so the
            // browser's own localhost resolution (which may pick ::1) still reaches the app.
            StartLoopback(uri, useLocalhost: true);
        }
        else if (uri.StartsWith("app://webauth/loopback", StringComparison.OrdinalIgnoreCase))
        {
            StartLoopback(uri, useLocalhost: false);
        }
        else if (uri.StartsWith("app://webauth/start", StringComparison.OrdinalIgnoreCase))
        {
            Start(timeout: null);
        }
        else if (uri.StartsWith("app://webauth/timeout", StringComparison.OrdinalIgnoreCase))
        {
            Start(TimeSpan.FromSeconds(3));
        }
        else if (uri.StartsWith("app://webauth/cancel", StringComparison.OrdinalIgnoreCase))
        {
            s_pending?.Cancel();
        }
    }

    private static void Start(TimeSpan? timeout)
    {
        var cts = timeout is { } limit ? new CancellationTokenSource(limit) : new CancellationTokenSource();
        s_pending = cts;
        SetTitle($"webauth: pending{(timeout is null ? string.Empty : " (timeout 3s)")}");
        _ = RunAsync(cts.Token, timeout is not null);
    }

    // The loopback synthetic flow: the callback route is a loopback URL and the authorize URL
    // the probe hands to the browser is that same URL carrying the response, so the system
    // browser's own GET reaches this process's listener and completes the await. On device the
    // browser window shows the listener's success page while the title below reports the
    // parsed result - both come from the same round trip.
    private static void StartLoopback(string uri, bool useLocalhost)
    {
        int port = DefaultLoopbackPort;
        string[] segments = uri.Split('?')[0].Split('/');
        if (segments.Length >= 5 && int.TryParse(segments[4], out int explicitPort) && explicitPort > 0 && explicitPort < 65536)
        {
            port = explicitPort;
        }
        string host = useLocalhost ? "localhost" : "127.0.0.1";
        var callback = new Uri($"http://{host}:{port}/callback");
        var authorize = new Uri($"http://{host}:{port}/callback?code=LOOPBACK-{port}&state=lbstate");
        var cts = new CancellationTokenSource();
        s_pending = cts;
        SetTitle($"webauth: pending (loopback {port}, {host})");
        _ = RunAsync(authorize, callback, cts.Token);
    }

    private static async Task RunAsync(CancellationToken token, bool timeoutCase)
        => await RunAsync(
            new Uri("https://example.invalid/authorize?probe=webauth"),
            new Uri("myapp://callback"),
            token,
            timeoutCase).ConfigureAwait(false);

    private static async Task RunAsync(Uri authorize, Uri callback, CancellationToken token, bool timeoutCase = false)
    {
        try
        {
            var result = await WebAuthenticator.Default.AuthenticateAsync(
                new WebAuthenticatorOptions
                {
                    Url = authorize,
                    CallbackUrl = callback,
                },
                token).ConfigureAwait(false);
            SetTitle($"webauth: ok code={result.Get("code")} state={result.Get("state")} token={result.AccessToken}");
        }
        catch (OperationCanceledException)
        {
            SetTitle(timeoutCase ? "webauth: timeout canceled" : "webauth: canceled");
        }
        catch (Exception ex)
        {
            SetTitle($"webauth: error {ex.GetType().Name}");
        }
    }

    private static void SetTitle(string title)
    {
        OpenHarmonyBridge.WriteStatus($"[webauth-probe] {title}");
        Microsoft.Maui.ApplicationModel.MainThread.BeginInvokeOnMainThread(() =>
        {
            if (Application.Current?.Windows.FirstOrDefault() is Window window)
            {
                window.Title = title;
            }
        });
    }
}
#endif
