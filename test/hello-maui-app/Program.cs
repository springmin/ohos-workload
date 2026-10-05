// Bridge-mode entry point: builds the MauiApp with the OpenHarmony platform services and
// hands the application to the platform host, which renders it when the XComponent surface
// arrives and forwards touch/frame/lifecycle events.
//
// The startup body lives in Program.Run so the two launch routes share it:
//   * JIT: the native host resolves this assembly's entry point (Program.Main) by reflection;
//   * NativeAOT: the AOT variant additionally exports openharmony_app_main (AotEntry.cs) and
//     the host dlopens libhello-maui-app.so and calls it (docs/aot-single-entry.md).
using Microsoft.AspNetCore.Components.WebView.Maui;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Maui;
using Microsoft.Maui.Hosting;
using Microsoft.Maui.Platform;
using Microsoft.OpenHarmony.Hosting;

namespace HelloMauiApp;

public static class Program
{
    public static int Main(string[] args) => Run(args);

    public static int Run(string[] args)
    {
#if STARTUP_PROBE
        StartupProbe.Install();
#endif
        var builder = MauiApp.CreateBuilder();
        builder.UseOpenHarmony();
        builder.UseMauiApp<App>();
        // S1: Blazor services + the OpenHarmony IBlazorWebView handler. AddMauiBlazorWebView() registers
        // the component services the WebViewManager's page scope resolves (IJSRuntime, NavigationManager,
        // ILoggerFactory, IScrollToLocationHash, ...); UsePlatformHandler replaces the package's
        // platform-less net11.0 handler with the slice handler (the registration the handler's own
        // header documents). The slice host additionally resolves the handler through
        // MauiOpenHarmonyExtensions.SliceHandlers (IBlazorWebView), so the control is connected either
        // way; both are kept explicit here.
        builder.Services.AddMauiBlazorWebView().UsePlatformHandler<OpenHarmonyBlazorWebViewHandler>();

        var mauiApp = builder.Build();
#if STARTUP_PROBE
        StartupProbe.Mark("built");
#endif
#if FRAMEPACING_PROBE
        // Opt-in telemetry: subscribes to the frame callback before the host (whose ctor
        // subscribes) so a callback can be timed through to its present. See FramePacingProbe.cs.
        FramePacingProbe.Install();
#endif
#if FRAMEPHASE_PROBE
        // Opt-in phase telemetry: same pre-host subscription, but aggregates the compositor's
        // measure/arrange/draw/accessibility/present phases and emits one line per 5 s.
        FramePhaseProbe.Install();
#endif
#if DRAWCOST_PROBE
        // Opt-in draw-cost telemetry: a timing canvas attributes every save/restore/clip/fill/
        // stroke/text/transform call to the node kind the compositor is drawing, and emits one
        // DCH line per 5 s. Installed after the phase probe so both present hooks chain.
        DrawCostProbe.Install();
#endif
        var host = mauiApp.Services.GetRequiredService<OpenHarmonyMauiAppHost>();
#if STARTUP_PROBE
        StartupProbe.Mark("services");
#endif

        OpenHarmonyBridge.WriteStatus("[hello-maui-app] starting MAUI application");
#if STARTUP_PROBE
        StartupProbe.Mark("run");
#endif
        host.Run(mauiApp.Services.GetRequiredService<IApplication>());

        using var finished = new ManualResetEventSlim(false);
        OpenHarmonyBridge.LifecycleChanged += e =>
        {
            if (e == OpenHarmonyLifecycleEvent.Destroy)
            {
                finished.Set();
            }
        };
        if (OpenHarmonyBridge.Context is not null)
        {
            finished.Wait();
        }

        return 0;
    }
}
