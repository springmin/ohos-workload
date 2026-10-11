// MEDIAELEMENT-ARKWEB A-M1 device probe (opt-in via -p:MediaElementProbe=true and the
// app://media/element activation). Builds a real MAUI page whose child is a media element
// control (IOpenHarmonyMediaElementView) handled by OpenHarmonyMediaElementHandler, pushes it
// modally over the running app (the L8-REMAINDER modal path renders it), and drives the ArkWeb
// HTML5 media path end to end:
//
//   rawfile source -> play -> natural end (currentTime/size/ended) -> seek/pause/resume ->
//   volume/mute acks -> slot occupancy -> modal close (slot release).
//
// Every step is mirrored into the managed status file (hilog) as [media-element] lines and the
// window title, so a device round reads the outcome without a debugger; a mid-play screenshot
// supplies the "picture" evidence. The probe never throws: a failure logs and titles the reason.
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

    private static int s_running;

    /// <summary>Starts the probe once; a second start while it runs is ignored.</summary>
    public static void Start(Microsoft.Maui.Controls.Window window, bool longClip = false)
    {
        if (Interlocked.CompareExchange(ref s_running, 1, 0) != 0)
        {
            WriteStatus("[media-element] already running");
            return;
        }
        _ = RunAsync(window, longClip ? LongRawFileName : SampleRawFileName);
    }

    /// <summary>The probe's media element: the slice interface over a plain MAUI View.</summary>
    private sealed class ProbeMediaElement : View, IOpenHarmonyMediaElementView
    {
        public OpenHarmonyMediaSource Source { get; set; }

        public OpenHarmonyMediaAspect Aspect { get; set; } = OpenHarmonyMediaAspect.AspectFit;

        public double Volume { get; set; } = 1;

        public bool Muted { get; set; }
    }

    private static async Task RunAsync(Microsoft.Maui.Controls.Window window, string sampleRawFileName)
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
                Source = OpenHarmonyMediaSource.FromRawFile(sampleRawFileName),
                HeightRequest = 360,
                HorizontalOptions = LayoutOptions.Fill,
            };
            Mark(window, $"clip={sampleRawFileName}");
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
                // 1) rawfile load + play + natural end (the currentTime/ended/size evidence).
                OpenHarmonyMediaResult play = await handler.PlayAsync();
                Mark(window, $"play status={play.Status}");
                var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(10);
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
                // Pause mid-clip (the clip is 1 s; ~700 ms lands on a decoded picture), so the
                // round's screenshots catch a visible frame.
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
