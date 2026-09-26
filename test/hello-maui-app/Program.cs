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
        var host = mauiApp.Services.GetRequiredService<OpenHarmonyMauiAppHost>();

        OpenHarmonyBridge.WriteStatus("[hello-maui-app] starting MAUI application");
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
