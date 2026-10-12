// CLIPBOARD-FIX device probe (opt-in: build with -p:ClipboardProbe=true, which defines
// CLIPBOARD_PROBE). It drives Microsoft.Maui.ApplicationModel.DataTransfer.Clipboard through
// the PASTEBOARD-FIX paths from warm activations (App.OnActivation):
//
//   aa start ... -U "app://clipboard/has"              -> log HasText (cached snapshot)
//   aa start ... -U "app://clipboard/read"             -> GetTextAsync (host pasteboard NDK read)
//   aa start ... -U "app://clipboard/write/<text>"     -> SetTextAsync (shell @ohos.pasteboard)
//   aa start ... -U "app://clipboard/roundtrip/<text>" -> write, read back, report match
//
// The point of the probe: a -p:OpenHarmonyFeatures=all build must install (READ_PASTEBOARD is
// ACL-level and would fail the installer) and the read path (host OH_Pasteboard + UDMF plain
// text, permission-free) must return text written through the shell path. Results go to
// dotnet-status.txt as [clipboard-probe] lines (the shell mirrors the status file to hilog) and
// to the window title (hilog logs every title application). The probe never throws: errors are
// logged and titled.
#if CLIPBOARD_PROBE
using Microsoft.Maui.ApplicationModel.DataTransfer;
using Microsoft.Maui.Controls;
using Microsoft.OpenHarmony.Hosting;
// Microsoft.Maui.Controls also ships a Clipboard type; the probe drives the Essentials one
// (the IClipboard implementation the platform slice registers).
using EssentialsClipboard = Microsoft.Maui.ApplicationModel.DataTransfer.Clipboard;

namespace HelloMauiApp;

internal static class ClipboardProbe
{
    private static int s_running;

    /// <summary>Handles one warm activation addressed to the probe (App.OnActivation calls it).</summary>
    public static void Handle(string uri)
    {
        string rest = uri["app://clipboard/".Length..];
        string op = rest;
        string payload = string.Empty;
        int slash = rest.IndexOf('/');
        if (slash >= 0)
        {
            op = rest[..slash];
            payload = Uri.UnescapeDataString(rest[(slash + 1)..]);
        }
        if (Interlocked.Exchange(ref s_running, 1) != 0)
        {
            SetTitle("clipboard: busy (previous op still running)");
            return;
        }
        _ = RunAsync(op, payload);
    }

    private static async Task RunAsync(string op, string payload)
    {
        try
        {
            switch (op.ToLowerInvariant())
            {
                case "has":
                    SetTitle($"clipboard: has text={EssentialsClipboard.Default.HasText}");
                    break;
                case "read":
                    string? read = await EssentialsClipboard.Default.GetTextAsync().ConfigureAwait(false);
                    SetTitle(read is null
                        ? "clipboard: read null"
                        : $"clipboard: read {read.Length}B text='{Preview(read)}'");
                    break;
                case "write":
                    await EssentialsClipboard.Default.SetTextAsync(payload).ConfigureAwait(false);
                    SetTitle($"clipboard: wrote {payload.Length}B text='{Preview(payload)}'");
                    break;
                case "roundtrip":
                    await EssentialsClipboard.Default.SetTextAsync(payload).ConfigureAwait(false);
                    await Task.Delay(150).ConfigureAwait(false);
                    string? back = await EssentialsClipboard.Default.GetTextAsync().ConfigureAwait(false);
                    SetTitle($"clipboard: roundtrip wrote={payload.Length}B " +
                        $"read={(back is null ? "null" : $"{back.Length}B")} match={back == payload}");
                    break;
                default:
                    SetTitle($"clipboard: unknown op '{op}'");
                    break;
            }
        }
        catch (Exception ex)
        {
            SetTitle($"clipboard: error {ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            Interlocked.Exchange(ref s_running, 0);
        }
    }

    private static string Preview(string text) => text.Length <= 48 ? text : text[..48] + "...";

    private static void SetTitle(string title)
    {
        OpenHarmonyBridge.WriteStatus($"[clipboard-probe] {title}");
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
