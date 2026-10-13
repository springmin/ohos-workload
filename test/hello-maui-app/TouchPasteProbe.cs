// TOUCH-PASTE device probe (opt-in: build with -p:TouchPasteProbe=true, which defines
// TOUCH_PASTE_PROBE): the shell's touch paste entry point is gated on the process environment
// variable OHOS_TOUCH_PASTE=1 (see the shell's TOUCH_PASTE_ENV). This probe sets it at startup
// and gives the device round a deterministic target and report channel:
//
//   aa start ... -U "app://touchpaste/focus"   -> focus the page's Entry (drives the shell's
//                                                 text-input sink, so the paste lands there)
//   aa start ... -U "app://touchpaste/clear"   -> clear the Entry text
//   aa start ... -U "app://touchpaste/report"  -> report the current Entry text
//
// The text the Entry receives after a paste is reported through the window title (hilog logs
// every title application) and dotnet-status.txt, so the round does not depend on scrolling the
// page down to the Entry. The sample itself is unchanged without the flag.
#if TOUCH_PASTE_PROBE
using Microsoft.Maui.Controls;
using Microsoft.OpenHarmony.Hosting;

namespace HelloMauiApp;

internal static class TouchPasteProbe
{
    private static Entry? s_entry;

    /// <summary>Sets the shell opt-in (idempotent) and reports the switch once.</summary>
    public static void Install()
    {
        // The shell's reliable opt-in channel is the app's own sandbox marker
        // (<filesDir>/touch-paste.enabled): the device round measured that a process environment
        // variable set here (after the ArkTS page loaded) is not visible through the ArkTS
        // process API. Both are written; the shell reads the marker first.
        Environment.SetEnvironmentVariable("OHOS_TOUCH_PASTE", "1");
        WriteMarker();
        OpenHarmonyBridge.WriteStatus("[touch-paste-probe] OHOS_TOUCH_PASTE=1 + touch-paste.enabled marker written");
    }

    /// <summary>Writes the sandbox marker again once the app context is certainly available.</summary>
    private static void WriteMarker()
    {
        try
        {
            string? filesDir = OpenHarmonyBridge.Context?.FilesDir;
            if (!string.IsNullOrEmpty(filesDir))
            {
                File.WriteAllText(Path.Combine(filesDir, "touch-paste.enabled"), "1\n");
            }
        }
        catch (Exception ex)
        {
            OpenHarmonyBridge.WriteStatus($"[touch-paste-probe] marker write failed: {ex.Message}");
        }
    }

    /// <summary>The page hands the round's target Entry over (probe builds only).</summary>
    public static void Attach(Entry entry)
    {
        // By now the app context is certainly attached: make sure the marker exists even when
        // Install() ran before it was available.
        WriteMarker();
        s_entry = entry;
        entry.TextChanged += (_, e) => SetTitle($"touchpaste: text='{e.NewTextValue}'");
    }

    /// <summary>Handles one warm activation addressed to the probe; false for other URIs.</summary>
    public static bool TryHandle(string uri)
    {
        if (!uri.StartsWith("app://touchpaste/", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }
        string op = uri["app://touchpaste/".Length..];
        switch (op.ToLowerInvariant())
        {
            case "focus":
                SetTitle("touchpaste: focus");
                s_entry?.Focus();
                break;
            case "clear":
                if (s_entry is not null)
                {
                    s_entry.Text = string.Empty;
                }
                SetTitle("touchpaste: clear");
                break;
            case "report":
                SetTitle($"touchpaste: report text='{s_entry?.Text}'");
                break;
            default:
                SetTitle($"touchpaste: unknown op '{op}'");
                break;
        }
        return true;
    }

    private static void SetTitle(string title)
    {
        OpenHarmonyBridge.WriteStatus($"[touch-paste-probe] {title}");
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
