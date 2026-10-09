// WEB-AUTH device probe (opt-in: build with -p:WebAuthProbe=true, which defines
// WEBAUTH_PROBE). It drives Microsoft.Maui.Authentication.WebAuthenticator through its real
// OpenHarmony flow from the warm activation path (App.OnActivation, which subscribes after
// OpenHarmonyAppLinks owns the cold-start wants):
//
//   aa start ... -U "app://webauth/start"    -> AuthenticateAsync opens the browser and awaits
//   aa start ... -U "app://webauth/cancel"   -> cancels the pending await (caller cancellation)
//   aa start ... -U "app://webauth/timeout"  -> starts with a 3 s caller timeout
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

    /// <summary>Handles one warm activation addressed to the probe (App.OnActivation calls it).</summary>
    public static void Handle(string uri)
    {
        if (uri.StartsWith("app://webauth/start", StringComparison.OrdinalIgnoreCase))
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

    private static async Task RunAsync(CancellationToken token, bool timeoutCase)
    {
        try
        {
            var result = await WebAuthenticator.Default.AuthenticateAsync(
                new WebAuthenticatorOptions
                {
                    Url = new Uri("https://example.invalid/authorize?probe=webauth"),
                    CallbackUrl = new Uri("myapp://callback"),
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
