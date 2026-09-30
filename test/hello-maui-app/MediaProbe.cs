// T20 media device probe. When the app receives an activation for app://media/probe (cold start
// or onNewWant), this probe
//   1. writes a short sine-wave WAV into the app cache directory (no packaged asset needed, so
//      it works on any hap and needs no device codec stream),
//   2. loads and plays it through the OpenHarmony media bridge
//      (OpenHarmonyMediaPlayer -> AVPlayer in the ArkTS shell),
//   3. waits for the Completed state (bounded), snapshots StatusAsync and
//   4. mirrors the outcome into the window title (visible in a WindowManagerService dump even
//      when the local desktop window does not render the MAUI controls) and the managed status
//      log; the shell half logs every state transition to hilog.
// The probe is also the demo page's manual entry (see App.BuildMediaSection).
using Microsoft.Maui.Platform;
using Microsoft.Maui.Storage;
using Microsoft.OpenHarmony.Hosting;

namespace HelloMauiApp;

internal static class MediaProbe
{
    private const string ProbeFileName = "media-probe.wav";
    private const int SampleRate = 16000;
    private const double ToneSeconds = 1.5;
    private const double ToneFrequency = 440.0;
    private const short ToneAmplitude = 6000;

    private static int s_running;

    private static long s_latestPositionMs;
    private static int s_stateEvents;

    /// <summary>Starts the probe once; a second start while it runs is ignored.</summary>
    public static void Start(Microsoft.Maui.Controls.Window window)
    {
        if (Interlocked.CompareExchange(ref s_running, 1, 0) != 0)
        {
            WriteStatus("[media-probe] already running");
            return;
        }
        _ = RunAsync(window);
    }

    private static async Task RunAsync(Microsoft.Maui.Controls.Window window)
    {
        try
        {
            SetTitle(window, "media probing");
            // First bridge round trip: it proves on the device log (the shell logs every media
            // request) that the activation reached managed code and the sink is registered.
            var probe = await OpenHarmonyMediaPlayer.StatusAsync();
            WriteStatus($"[media-probe] entry status={probe.Status} state={probe.State}");
            string path = WriteTone();
            WriteStatus($"[media-probe] tone written: {path}");
            s_latestPositionMs = 0;
            s_stateEvents = 0;
            var stateTrace = new System.Text.StringBuilder();
            void OnState(object? sender, OpenHarmonyMediaStateChangedEventArgs args)
            {
                Interlocked.Increment(ref s_stateEvents);
                lock (stateTrace)
                {
                    stateTrace.Append(args.State).Append('/');
                }
            }
            void OnPosition(object? sender, OpenHarmonyMediaPositionChangedEventArgs args)
            {
                Interlocked.Exchange(ref s_latestPositionMs, (long)args.Position.TotalMilliseconds);
            }

            OpenHarmonyMediaPlayer.StateChanged += OnState;
            OpenHarmonyMediaPlayer.PositionChanged += OnPosition;
            try
            {
                var load = await OpenHarmonyMediaPlayer.LoadAsync(OpenHarmonyMediaSource.FromFile(path));
                WriteStatus($"[media-probe] load status={load.Status} message='{load.Message}'");
                if (!load.IsSuccess)
                {
                    SetTitle(window, $"media load {load.Status}");
                    return;
                }
                var play = await OpenHarmonyMediaPlayer.PlayAsync();
                WriteStatus($"[media-probe] play status={play.Status} message='{play.Message}'");
                // Wait (bounded) for the natural end so the trace covers playing -> completed.
                var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(4);
                while (DateTime.UtcNow < deadline &&
                       OpenHarmonyMediaPlayer.State != OpenHarmonyMediaPlaybackState.Completed)
                {
                    await Task.Delay(100);
                }
                var status = await OpenHarmonyMediaPlayer.StatusAsync();
                string trace;
                lock (stateTrace)
                {
                    trace = stateTrace.ToString();
                }
                WriteStatus(
                    $"[media-probe] status status={status.Status} state={status.State} " +
                    $"pos={status.Position.TotalMilliseconds:0}ms dur={status.Duration.TotalMilliseconds:0}ms " +
                    $"seen={s_latestPositionMs}ms states={trace}");
                SetTitle(window, $"media {status.State} pos={status.Position.TotalMilliseconds:0} dur={status.Duration.TotalMilliseconds:0}");
                var release = await OpenHarmonyMediaPlayer.ReleaseAsync();
                WriteStatus($"[media-probe] release status={release.Status}");
            }
            finally
            {
                OpenHarmonyMediaPlayer.StateChanged -= OnState;
                OpenHarmonyMediaPlayer.PositionChanged -= OnPosition;
            }
        }
        catch (Exception ex)
        {
            WriteStatus($"[media-probe] threw {ex.GetType().Name}: {ex.Message}");
            SetTitle(window, $"media failed {ex.GetType().Name}");
            // Best-effort second round trip: it keeps the failure visible on the shell log even
            // when the status file is unreadable on the device.
            try
            {
                await OpenHarmonyMediaPlayer.StatusAsync();
            }
            catch
            {
                // Diagnostics only.
            }
        }
        finally
        {
            Interlocked.Exchange(ref s_running, 0);
        }
    }

    /// <summary>Stops whatever the manual entry started.</summary>
    public static async void StopFromUi(Microsoft.Maui.Controls.Window? window)
    {
        try
        {
            await OpenHarmonyMediaPlayer.StopAsync();
            var release = await OpenHarmonyMediaPlayer.ReleaseAsync();
            WriteStatus($"[media-probe] ui stop/release status={release.Status}");
            if (window is not null)
            {
                SetTitle(window, "media stopped");
            }
        }
        catch (Exception ex)
        {
            WriteStatus($"[media-probe] ui stop threw {ex.GetType().Name}: {ex.Message}");
        }
    }

    /// <summary>
    /// Writes a 16-bit mono PCM WAV sine tone into the cache dir and returns its path (written
    /// once; a later probe reuses it).
    /// </summary>
    internal static string WriteTone()
    {
        string cacheDir = OpenHarmonyBridge.Context?.CacheDir ?? string.Empty;
        if (cacheDir.Length == 0)
        {
            // Fall back to Essentials only when the hosting context is not published yet.
            cacheDir = FileSystem.CacheDirectory;
        }
        string path = Path.Combine(cacheDir, ProbeFileName);
        if (File.Exists(path))
        {
            return path;
        }
        int sampleCount = (int)(SampleRate * ToneSeconds);
        using var stream = new MemoryStream(44 + sampleCount * 2);
        using var writer = new BinaryWriter(stream);
        writer.Write(new byte[] { (byte)'R', (byte)'I', (byte)'F', (byte)'F' });
        writer.Write((uint)(36 + sampleCount * 2));
        writer.Write(new byte[] { (byte)'W', (byte)'A', (byte)'V', (byte)'E' });
        writer.Write(new byte[] { (byte)'f', (byte)'m', (byte)'t', (byte)' ' });
        writer.Write(16u);
        writer.Write((ushort)1);                      // PCM
        writer.Write((ushort)1);                      // mono
        writer.Write((uint)SampleRate);
        writer.Write((uint)(SampleRate * 2));         // byte rate
        writer.Write((ushort)2);                      // block align
        writer.Write((ushort)16);                     // bits per sample
        writer.Write(new byte[] { (byte)'d', (byte)'a', (byte)'t', (byte)'a' });
        writer.Write((uint)(sampleCount * 2));
        for (int i = 0; i < sampleCount; i++)
        {
            short value = (short)(Math.Sin(2 * Math.PI * ToneFrequency * i / SampleRate) * ToneAmplitude);
            writer.Write(value);
        }
        File.WriteAllBytes(path, stream.ToArray());
        return path;
    }

    private static void SetTitle(Microsoft.Maui.Controls.Window window, string title)
    {
        try
        {
            window.Dispatcher.Dispatch(() => window.Title = title);
        }
        catch (Exception ex)
        {
            WriteStatus($"[media-probe] title dispatch failed: {ex.GetType().Name}");
        }
    }

    private static void WriteStatus(string message)
    {
        try
        {
            OpenHarmonyBridge.WriteStatus(message);
        }
        catch
        {
            // Diagnostics only.
        }
    }
}
