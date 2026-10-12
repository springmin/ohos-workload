// MEDIAELEMENT-ARKWEB A-M1 + MEDIA-SUBWIN+HLS B-M1 device probes (opt-in via
// -p:MediaElementProbe=true and the app://media/element[/long|/hls] activation triggers; the
// child window probe rides app://subwindow/openmedia).
//
// A-M1 (primary window): builds a real MAUI page whose child is a media element control
// (IOpenHarmonyMediaElementView) handled by OpenHarmonyMediaElementHandler, pushes it modally
// over the running app (the L8-REMAINDER modal path renders it), and drives the ArkWeb HTML5
// media path end to end:
//
//   rawfile source -> play -> natural end (currentTime/size/ended) -> seek/pause/resume ->
//   volume/mute acks -> slot occupancy -> modal close (slot release).
//
// B-M1 additions:
//   * StartHls: the same modal page with an HLS (m3u8) source - the media page lazily loads the
//     vendored hls.js runtime, attaches MSE and plays; the managed status log carries the page's
//     `[maui] media hls event:` diagnostics (manifest-parsed/fallback) next to the [media-element]
//     transport lines, so a device round can distinguish "hls.js initialized and the manifest
//     parsed" from a native fallback or a fatal error.
//   * StartChild: a media element on a real managed child window (app://subwindow/openmedia).
//     It logs the child pool claim, plays the short rawfile sample, then closes its own child
//     window and asserts the child ArkWeb slot was released (the B-M1 release path).
//
// MEDIA-MICRO additions (app://media/element/hlslocal and /hlsrange):
//   * StartHlsLocal: the same modal page with a local rawfile playlist - a segmented playlist
//     whose variant/segment files are served as siblings, or a single-file byte-range playlist
//     whose segment fetches exercise the shell's single-range 206/Content-Range answers. The
//     probe reports the same opened/ended/transport chain, so hilog carries the whole story.
//
// Every step is mirrored into the managed status file (hilog) as [media-element]/[media-child]
// lines and the window title, so a device round reads the outcome without a debugger; a
// mid-play screenshot supplies the "picture" evidence. The probe never throws: a failure logs
// and titles the reason.
using Microsoft.Maui.Controls;
using Microsoft.Maui.Platform;
using Microsoft.OpenHarmony.Hosting;

namespace HelloMauiApp;

internal static class MediaElementProbe
{
    // Staged into the HAP rawfile by the round script (scratch; no repo binary): the 1 s
    // H.264/AAC clip the MEDIA-Q1 probe measured as hardware-decoded on this device.
    internal const string SampleRawFileName = "h264-aac-good.mp4";

    // The 30 s 854x480 H.264/AAC clip, staged by the round as a second rawfile: the long-play
    // variant gives the round a wide window for mid-play screenshots.
    internal const string LongRawFileName = "long-test.mp4";

    // B-M1: the HLS probe source. The round runs a loopback bun server (scratch) that serves a
    // locally segmented CMAF sample (MP4Box.js, from long-test.mp4) under /hls/; the media page
    // loads hls.js from its own origin and plays the playlist through MSE.
    internal const string HlsProbeUrl = "http://127.0.0.1:8791/hls/master.m3u8";

    // MEDIA-MICRO: the local-playlist variants. The round stages the B-M1 CMAF sample as HAP
    // rawfiles before packing the probe hap: hlslocal/video.m3u8 + its segment/media siblings
    // (the segmented shape) and hlsrange/byte.m3u8 referencing the concatenated all.mp4 with
    // #EXT-X-BYTERANGE (the single-file byte-range shape whose segment fetches exercise the
    // shell's 206/Content-Range answers). No repo binary: scratch staging only.
    internal const string HlsLocalRawFileName = "hlslocal/video.m3u8";
    internal const string HlsRangeRawFileName = "hlsrange/byte.m3u8";

    private static int s_running;

    /// <summary>Starts the primary-window probe once; a second start while it runs is ignored.</summary>
    public static void Start(Window window, bool longClip = false)
    {
        if (!Begin())
        {
            return;
        }
        string name = longClip ? LongRawFileName : SampleRawFileName;
        _ = RunAsync(window, OpenHarmonyMediaSource.FromRawFile(name), name);
    }

    /// <summary>B-M1: the HLS variant (source = the loopback playlist URL).</summary>
    public static void StartHls(Window window)
    {
        if (!Begin())
        {
            return;
        }
        _ = RunAsync(window, OpenHarmonyMediaSource.FromUrl(HlsProbeUrl), "hls:" + HlsProbeUrl);
    }

    /// <summary>MEDIA-MICRO: the local rawfile playlist variant (segmented or byte-range).</summary>
    public static void StartHlsLocal(Window window, string rawFileName)
    {
        if (!Begin())
        {
            return;
        }
        _ = RunAsync(window, OpenHarmonyMediaSource.FromRawFile(rawFileName), "hls:" + rawFileName);
    }

    /// <summary>B-M1: starts the child-window probe over the element mounted on the child page.</summary>
    public static void StartChild(Label status, View element)
    {
        if (!Begin())
        {
            return;
        }
        _ = RunChildAsync(status, element);
    }

    /// <summary>The media element the probes drive: the slice interface over a plain MAUI View.</summary>
    internal sealed class ProbeMediaElement : View, IOpenHarmonyMediaElementView
    {
        public OpenHarmonyMediaSource Source { get; set; } = OpenHarmonyMediaSource.FromUrl("about:blank");

        public OpenHarmonyMediaAspect Aspect { get; set; } = OpenHarmonyMediaAspect.AspectFit;

        public double Volume { get; set; } = 1;

        public bool Muted { get; set; }
    }

    /// <summary>Builds one probe media element (the child page uses this factory).</summary>
    internal static View CreateElement(OpenHarmonyMediaSource source, double height = 360)
        => new ProbeMediaElement
        {
            Source = source,
            HeightRequest = height,
            HorizontalOptions = LayoutOptions.Fill,
        };

    private static bool Begin()
    {
        if (Interlocked.CompareExchange(ref s_running, 1, 0) != 0)
        {
            WriteStatus("[media-element] already running");
            return false;
        }
        return true;
    }

    private static async Task RunAsync(Microsoft.Maui.Controls.Window window, OpenHarmonyMediaSource source, string label)
    {
        try
        {
            SetTitle(window, "media element probing");
            if (window.Page is not FlyoutPage { Detail: TabbedPage { CurrentPage: NavigationPage nav } })
            {
                WriteStatus("[media-element] main navigation page unavailable");
                return;
            }
            var element = new ProbeMediaElement
            {
                Source = source,
                HeightRequest = 360,
                HorizontalOptions = LayoutOptions.Fill,
            };
            Mark(window, $"clip={label}");
            var status = new Label { Text = "media element: starting", FontSize = 22 };
            var page = new ContentPage
            {
                Title = "media element",
                Content = new VerticalStackLayout { Padding = 24, Spacing = 12, Children = { status, element } },
            };
            await nav.Navigation.PushModalAsync(page, animated: false);
            Mark(window, "push ok");

            OpenHarmonyMediaElementHandler? handler = null;
            for (int i = 0; i < 50 && handler is null; i++)
            {
                await Task.Delay(100);
                handler = element.Handler as OpenHarmonyMediaElementHandler;
            }
            if (handler is null)
            {
                WriteStatus("[media-element] handler unavailable");
                SetTitle(window, "media element: no handler");
                return;
            }
            OpenHarmonyMediaElementSurface surface = handler.Surface;
            Mark(window, $"slot={surface.OverlaySlot} supported={surface.IsSupported}");

            var stateTrace = new System.Text.StringBuilder();
            var ended = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            long lastPositionMs = 0;
            int openedCount = 0;
            int sizeWidth = 0;
            int sizeHeight = 0;
            void OnOpened(object? sender, OpenHarmonyMediaOpenedEventArgs args)
            {
                openedCount++;
                sizeWidth = args.Width;
                sizeHeight = args.Height;
                Mark(window, $"opened dur={args.Duration.TotalMilliseconds:0}ms size={args.Width}x{args.Height}");
            }
            void OnState(object? sender, OpenHarmonyMediaStateChangedEventArgs args)
            {
                lock (stateTrace)
                {
                    stateTrace.Append(args.State).Append('/');
                }
            }
            void OnPosition(object? sender, OpenHarmonyMediaPositionChangedEventArgs args)
            {
                Interlocked.Exchange(ref lastPositionMs, (long)args.Position.TotalMilliseconds);
            }
            void OnEnded(object? sender, OpenHarmonyMediaEndedEventArgs args)
            {
                ended.TrySetResult(true);
            }
            void OnFailed(object? sender, OpenHarmonyMediaFailedEventArgs args)
            {
                WriteStatus($"[media-element] failed code={args.Code} message='{args.Message}'");
                SetTitle(window, $"media element: failed {args.Message}");
            }
            surface.MediaOpened += OnOpened;
            surface.StateChanged += OnState;
            surface.PositionChanged += OnPosition;
            surface.Ended += OnEnded;
            surface.Failed += OnFailed;
            try
            {
                // 1) load + play + natural end (the currentTime/ended/size evidence).
                OpenHarmonyMediaResult play = await handler.PlayAsync();
                Mark(window, $"play status={play.Status} message='{play.Message}'");
                var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(label.StartsWith("hls:", StringComparison.Ordinal) ? 45 : 10);
                while (DateTime.UtcNow < deadline && !ended.Task.IsCompleted && surface.State != OpenHarmonyMediaPlaybackState.Error)
                {
                    await Task.Delay(100);
                }
                string trace;
                lock (stateTrace)
                {
                    trace = stateTrace.ToString();
                }
                Mark(
                    window,
                    $"after-play ended={ended.Task.IsCompleted} state={surface.State} " +
                    $"pos={surface.Position.TotalMilliseconds:0}ms dur={surface.Duration.TotalMilliseconds:0}ms " +
                    $"seen={Interlocked.Read(ref lastPositionMs)}ms size={sizeWidth}x{sizeHeight} opened={openedCount} states={trace}");

                // 2) seek back / resume / pause / resume: the transport evidence.
                OpenHarmonyMediaResult seek = await handler.SeekAsync(TimeSpan.Zero);
                OpenHarmonyMediaResult resume = await handler.PlayAsync();
                // Pause mid-clip (the short clip is 1 s; ~700 ms lands on a decoded picture), so
                // the round's screenshots catch a visible frame.
                await Task.Delay(700);
                long posBeforePause = (long)surface.Position.TotalMilliseconds;
                OpenHarmonyMediaResult pause = await handler.PauseAsync();
                await Task.Delay(250);
                long posAfterPause = (long)surface.Position.TotalMilliseconds;
                OpenHarmonyMediaPlaybackState pauseState = surface.State;
                // Hold the paused frame so the round's screenshots catch the decoded picture.
                Mark(window, $"pause-hold pos={posAfterPause}ms");
                await Task.Delay(4000);
                OpenHarmonyMediaResult resumeAgain = await handler.PlayAsync();
                await Task.Delay(250);
                long posAfterResume = (long)surface.Position.TotalMilliseconds;
                Mark(
                    window,
                    $"transport seek={seek.Status} resume={resume.Status} pause={pause.Status} " +
                    $"posBeforePause={posBeforePause}ms posAfterPause={posAfterPause}ms pauseState={pauseState} " +
                    $"resumeAgain={resumeAgain.Status} posAfterResume={posAfterResume}ms state={surface.State}");

                // 3) audio controls (arks only; the page applies them to the video element).
                OpenHarmonyMediaResult mute = await handler.SetMutedAsync(true);
                OpenHarmonyMediaResult volume = await handler.SetVolumeAsync(0.5);
                OpenHarmonyMediaResult unmute = await handler.SetMutedAsync(false);
                Mark(window, $"audio mute={mute.Status} volume={volume.Status} unmute={unmute.Status}");

                // 4) stop + slot occupancy; the modal close releases the slot.
                OpenHarmonyMediaResult stop = await handler.StopAsync();
                int slot = surface.OverlaySlot;
                bool claimedBefore = slot >= 0 && OpenHarmonyOverlays.IsClaimed(slot);
                Mark(window, $"stop={stop.Status} slot={slot} claimed={claimedBefore}");
                await nav.Navigation.PopModalAsync(animated: false);
                await Task.Delay(800);
                bool released = slot < 0 || !OpenHarmonyOverlays.IsClaimed(slot);
                bool mainAlive = window.Page is FlyoutPage;
                Mark(window, $"close released={released} mainWindowAlive={mainAlive}");
                SetTitle(window, $"media element: done released={released}");
            }
            finally
            {
                surface.MediaOpened -= OnOpened;
                surface.StateChanged -= OnState;
                surface.PositionChanged -= OnPosition;
                surface.Ended -= OnEnded;
                surface.Failed -= OnFailed;
            }
        }
        catch (Exception ex)
        {
            WriteStatus($"[media-element] threw {ex.GetType().Name}: {ex.Message}");
            SetTitle(window, $"media element: threw {ex.GetType().Name}");
        }
        finally
        {
            Interlocked.Exchange(ref s_running, 0);
        }
    }

    /// <summary>
    /// B-M1: drives the media element mounted on a managed child window. Plays the rawfile
    /// sample through the child ArkWeb slot, then closes its own child window and checks the
    /// child pool claim is released (the managed close hook + the shell's slot destroy).
    /// </summary>
    private static async Task RunChildAsync(Label status, View element)
    {
        try
        {
            WriteStatus("[media-child] probing");
            // The element's window is stamped when the child tree connects.
            Microsoft.Maui.Controls.Window? child = null;
            for (int i = 0; i < 200 && child is null; i++)
            {
                await Task.Delay(100);
                child = element.Window;
            }
            if (child is null)
            {
                WriteStatus("[media-child] child window unavailable");
                SetStatus(status, "child media: no window");
                return;
            }
            SetTitle(child, "cm probing");
            OpenHarmonyMediaElementHandler? handler = null;
            for (int i = 0; i < 100 && handler is null; i++)
            {
                await Task.Delay(100);
                handler = element.Handler as OpenHarmonyMediaElementHandler;
            }
            if (handler is null)
            {
                WriteStatus("[media-child] handler unavailable");
                SetStatus(status, "child media: no handler");
                return;
            }
            OpenHarmonyMediaElementSurface surface = handler.Surface;
            string windowId = OpenHarmonySubWindow.SurfaceId;
            int slot = surface.OverlaySlot;
            MarkChild(child, $"slot={slot} supported={surface.IsSupported} win={windowId}");
            SetStatus(status, $"child media: slot={slot}");
            // The after-play/stop milestones go on the MAIN window's title: the child window's
            // own title applies are rejected by the platform once the subwindow is shown
            // ("window state is abnormal"), and the main channel is the reliable one.
            Window? main = null;
            if (Application.Current is { } app)
            {
                foreach (Window candidate in app.Windows)
                {
                    if (!ReferenceEquals(candidate, child))
                    {
                        main = candidate;
                        break;
                    }
                }
            }

            var stateTrace = new System.Text.StringBuilder();
            var ended = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            long lastPositionMs = 0;
            int openedCount = 0;
            int sizeWidth = 0;
            int sizeHeight = 0;
            void OnOpened(object? sender, OpenHarmonyMediaOpenedEventArgs args)
            {
                openedCount++;
                sizeWidth = args.Width;
                sizeHeight = args.Height;
                MarkChild(child, $"opened dur={args.Duration.TotalMilliseconds:0}ms size={args.Width}x{args.Height}");
            }
            void OnState(object? sender, OpenHarmonyMediaStateChangedEventArgs args)
            {
                lock (stateTrace)
                {
                    stateTrace.Append(args.State).Append('/');
                }
            }
            void OnPosition(object? sender, OpenHarmonyMediaPositionChangedEventArgs args)
            {
                Interlocked.Exchange(ref lastPositionMs, (long)args.Position.TotalMilliseconds);
            }
            void OnEnded(object? sender, OpenHarmonyMediaEndedEventArgs args)
            {
                ended.TrySetResult(true);
            }
            void OnFailed(object? sender, OpenHarmonyMediaFailedEventArgs args)
            {
                MarkChild(child, $"failed code={args.Code} message='{args.Message}'");
            }
            surface.MediaOpened += OnOpened;
            surface.StateChanged += OnState;
            surface.PositionChanged += OnPosition;
            surface.Ended += OnEnded;
            surface.Failed += OnFailed;
            try
            {
                OpenHarmonyMediaResult play = await handler.PlayAsync();
                MarkChild(child, $"play={play.Status}");
                var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(12);
                while (DateTime.UtcNow < deadline && !ended.Task.IsCompleted && surface.State != OpenHarmonyMediaPlaybackState.Error)
                {
                    await Task.Delay(100);
                }
                string trace;
                lock (stateTrace)
                {
                    trace = stateTrace.ToString();
                }
                MarkMain(main, 
                    $"after-play ended={ended.Task.IsCompleted} state={surface.State} " +
                    $"pos={surface.Position.TotalMilliseconds:0}ms dur={surface.Duration.TotalMilliseconds:0}ms " +
                    $"seen={Interlocked.Read(ref lastPositionMs)}ms size={sizeWidth}x{sizeHeight} opened={openedCount} states={trace}");
                await Task.Delay(300);
                OpenHarmonyMediaResult stop = await handler.StopAsync();
                bool claimed = slot >= 0 && !string.IsNullOrEmpty(windowId)
                    && OpenHarmonyChildWeb.IsClaimed(windowId, slot);
                MarkMain(main, $"stop={stop.Status} claimed={claimed}");
                await Task.Delay(300);
                SetStatus(status, $"child media: done claimed={claimed}");

                // Close the child from inside the probe: the managed close hook must release the
                // child pool claim and the shell destroys the slot. The result travels on the
                // main window's title, which stays alive after the child is gone.
                Application.Current?.CloseWindow(child);
                await Task.Delay(1500);
                bool released = slot < 0 || string.IsNullOrEmpty(windowId)
                    || !OpenHarmonyChildWeb.IsClaimed(windowId, slot);
                bool mainAlive = Application.Current?.Windows.Count > 0;
                MarkMain(main, $"close released={released} mainAlive={mainAlive} win={windowId} slot={slot}");
            }
            finally
            {
                surface.MediaOpened -= OnOpened;
                surface.StateChanged -= OnState;
                surface.PositionChanged -= OnPosition;
                surface.Ended -= OnEnded;
                surface.Failed -= OnFailed;
            }
        }
        catch (Exception ex)
        {
            WriteStatus($"[media-child] threw {ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            Interlocked.Exchange(ref s_running, 0);
        }
    }

    /// <summary>
    /// Writes one probe marker to both evidence channels: the managed status file
    /// ("[media-element] <marker>") and the window title ("me <marker>"). The shell mirrors the
    /// status file only while its startup poll window is open, but it logs every title apply,
    /// so the title channel carries the full sequence into hilog reliably.
    /// </summary>
    private static void Mark(Microsoft.Maui.Controls.Window window, string marker)
    {
        WriteStatus($"[media-element] {marker}");
        SetTitle(window, $"me {marker}");
    }

    /// <summary>The child-window marker channel ("cm &lt;marker&gt;"), logged by the shell's
    /// title-apply line while the child is alive.</summary>
    private static void MarkChild(Microsoft.Maui.Controls.Window window, string marker)
    {
        WriteStatus($"[media-child] {marker}");
        SetTitle(window, $"cm {marker}");
    }

    /// <summary>The main-window marker channel for the child probe's late milestones (the child
    /// window's own title apply is rejected once the subwindow is shown).</summary>
    private static void MarkMain(Microsoft.Maui.Controls.Window? main, string marker)
    {
        WriteStatus($"[media-child] {marker}");
        if (main is not null)
        {
            SetTitle(main, $"cm {marker}");
        }
    }

    private static void SetStatus(Label status, string text)
    {
        try
        {
            status.Dispatcher.Dispatch(() => status.Text = text);
        }
        catch (Exception ex)
        {
            WriteStatus($"[media-element] status dispatch failed: {ex.GetType().Name}");
        }
    }

    private static void SetTitle(Microsoft.Maui.Controls.Window window, string title)
    {
        try
        {
            window.Dispatcher.Dispatch(() => window.Title = title);
        }
        catch (Exception ex)
        {
            WriteStatus($"[media-element] title dispatch failed: {ex.GetType().Name}");
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
