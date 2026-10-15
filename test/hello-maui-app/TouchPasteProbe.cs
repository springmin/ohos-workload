// TOUCH-PASTE device probe (build with -p:TouchPasteProbe=true, which defines
// TOUCH_PASTE_PROBE): the shell's touch paste entry point is ON by default. An app opts out by
// writing its own sandbox marker (<filesDir>/touch-paste.disabled) at startup, a channel the
// device round measured to be reliable (a process environment variable set here after the
// ArkTS page loaded is not visible through the ArkTS process API; OHOS_TOUCH_PASTE=0 stays the
// secondary source). This probe gives the device round a deterministic target and report
// channel:
//
//   aa start ... -U "app://touchpaste/focus"   -> focus the page's Entry (drives the shell's
//                                                 text-input sink, so the paste lands there)
//   aa start ... -U "app://touchpaste/clear"   -> clear the Entry text
//   aa start ... -U "app://touchpaste/report"  -> report the current Entry text
//   aa start ... -U "app://touchpaste/optout"  -> write the touch-paste.disabled marker (the
//                                                 shell latches on the first surface touch, so
//                                                 force-stop + relaunch to observe it)
//   aa start ... -U "app://touchpaste/optin"   -> delete the marker again (the shipped default)
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

    /// <summary>Reports the opt-out marker state once at startup (the shipped default: absent).</summary>
    public static void Install()
    {
        ReportMarkerState();
    }

    /// <summary>The shell's opt-out marker in the app's own sandbox.</summary>
    private static string MarkerPath()
    {
        string? filesDir = OpenHarmonyBridge.Context?.FilesDir;
        return string.IsNullOrEmpty(filesDir) ? string.Empty : Path.Combine(filesDir, "touch-paste.disabled");
    }

    private static void ReportMarkerState()
    {
        try
        {
            string path = MarkerPath();
            bool disabled = path.Length > 0 && File.Exists(path);
            OpenHarmonyBridge.WriteStatus($"[touch-paste-probe] default-on; optout marker present={disabled}");
        }
        catch (Exception ex)
        {
            OpenHarmonyBridge.WriteStatus($"[touch-paste-probe] marker state read failed: {ex.Message}");
        }
    }

    /// <summary>Writes the shell's opt-out marker (idempotent; effective on the next launch).</summary>
    private static void WriteMarker()
    {
        try
        {
            string path = MarkerPath();
            if (path.Length > 0)
            {
                File.WriteAllText(path, "1\n");
            }
        }
        catch (Exception ex)
        {
            OpenHarmonyBridge.WriteStatus($"[touch-paste-probe] marker write failed: {ex.Message}");
        }
    }

    /// <summary>Deletes the shell's opt-out marker again (the shipped default).</summary>
    private static void ClearMarker()
    {
        try
        {
            string path = MarkerPath();
            if (path.Length > 0 && File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (Exception ex)
        {
            OpenHarmonyBridge.WriteStatus($"[touch-paste-probe] marker delete failed: {ex.Message}");
        }
    }

    /// <summary>The page hands the round's target Entry over (probe builds only).</summary>
    public static void Attach(Entry entry)
    {
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
            case "optout":
                WriteMarker();
                SetTitle("touchpaste: optout (relaunch to observe)");
                break;
            case "optin":
                ClearMarker();
                SetTitle("touchpaste: optin (relaunch to observe)");
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
