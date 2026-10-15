// SECURE-STORAGE-ASSET device probe (build with -p:SecureStorageProbe=true, which defines
// SECURE_STORAGE_PROBE): gives the device round a deterministic SecureStorage exercise and report
// channel, so the normal set/get/remove path can be measured with the Asset Store backend in the
// shipped host (the device round otherwise has no app-level SecureStorage caller).
//
//   aa start ... -U "app://secure/roundtrip"  -> Set -> Get (compare) -> Remove -> Get (gone)
//   aa start ... -U "app://secure/report"     -> report the backend state + the key's value
//
// Every step reports through OpenHarmonyBridge.WriteStatus (the status file the shell mirrors to
// hilog as `[maui] status: ...`) and the window title. The report also reads the store's data
// file: with the Asset Store backend it must hold the `a1:` index marker, never the plaintext
// value. The probe compiles only with the flag; the shipped sample is unaffected.
#if SECURE_STORAGE_PROBE
using Microsoft.Maui.Platform;
using Microsoft.Maui.Storage;
using Microsoft.OpenHarmony.Hosting;

namespace HelloMauiApp;

internal static class SecureStorageProbe
{
    private const string Key = "probe-secure-asset";
    private const string Value = "asset-probe-v1";

    /// <summary>Reports the backend state once at startup.</summary>
    public static void Install()
    {
        // Status channel only: the UI thread dispatcher (and a window) does not exist yet at
        // this point, so a MainThread post here would throw out of the startup path.
        OpenHarmonyBridge.WriteStatus(
            $"[secure-probe] secure: install failClosed={OpenHarmonySecureStorage.FailClosed} " +
            $"hardwareBacked={OpenHarmonySecureStorage.IsHardwareBacked}");
    }

    /// <summary>Handles one warm activation addressed to the probe; false for other URIs.</summary>
    public static bool TryHandle(string uri)
    {
        if (!uri.StartsWith("app://secure/", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }
        string op = uri["app://secure/".Length..].TrimEnd('/');
        switch (op.ToLowerInvariant())
        {
            case "roundtrip":
                _ = RoundTripAsync();
                break;
            case "report":
                _ = ReportAsync();
                break;
            default:
                SetTitle($"secure: unknown op '{op}'");
                break;
        }
        return true;
    }

    private static async Task RoundTripAsync()
    {
        try
        {
            await SecureStorage.Default.SetAsync(Key, Value);
            (string afterSetState, _) = InspectDataFile();
            string? read = await SecureStorage.Default.GetAsync(Key);
            bool match = read == Value;
            bool removed = SecureStorage.Default.Remove(Key);
            string? after = await SecureStorage.Default.GetAsync(Key);
            bool gone = after is null;
            (string fileState, bool plainInFile) = InspectDataFile();
            SetTitle($"secure: roundtrip failClosed={OpenHarmonySecureStorage.FailClosed} " +
                     $"hardwareBacked={OpenHarmonySecureStorage.IsHardwareBacked} " +
                     $"assetAvailable={OpenHarmonyAssetStore.IsAvailable} match={match} " +
                     $"removed={removed} gone={gone} afterSet={afterSetState} file={fileState} " +
                     $"plainInFile={plainInFile}");
        }
        catch (Exception ex)
        {
            SetTitle($"secure: roundtrip FAILED {ex.GetType().Name}: {ex.Message}");
        }
    }

    private static async Task ReportAsync()
    {
        try
        {
            string? read = await SecureStorage.Default.GetAsync(Key);
            (string fileState, bool plainInFile) = InspectDataFile();
            SetTitle($"secure: report failClosed={OpenHarmonySecureStorage.FailClosed} " +
                     $"hardwareBacked={OpenHarmonySecureStorage.IsHardwareBacked} " +
                     $"value={read ?? "<null>"} file={fileState} plainInFile={plainInFile}");
        }
        catch (Exception ex)
        {
            SetTitle($"secure: report FAILED {ex.GetType().Name}: {ex.Message}");
        }
    }

    /// <summary>The default store's data file state: presence/size and whether the plaintext
    /// value leaked into it (the Asset Store backend must keep the value out).</summary>
    private static (string State, bool PlainInFile) InspectDataFile()
    {
        try
        {
            string path = Path.Combine(FileSystem.AppDataDirectory, "secure.dat");
            if (!File.Exists(path))
            {
                return ("absent", false);
            }
            long length = new FileInfo(path).Length;
            bool plain = File.ReadAllText(path).Contains(Value, StringComparison.Ordinal);
            return ($"bytes={length}", plain);
        }
        catch (Exception ex)
        {
            return ($"read-failed:{ex.GetType().Name}", false);
        }
    }

    private static void SetTitle(string title)
    {
        OpenHarmonyBridge.WriteStatus($"[secure-probe] {title}");
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
