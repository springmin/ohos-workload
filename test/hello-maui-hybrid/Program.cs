// Bridge-mode entry point: builds the MauiApp with the OpenHarmony platform services and hands
// the application to the platform host, which renders it when the XComponent surface arrives and
// forwards touch/frame/lifecycle events.
//
// The startup body lives in Program.Run so the two launch routes share it:
//   * JIT: the native host resolves this assembly's entry point (Program.Main) by reflection;
//   * NativeAOT: the AOT variant additionally exports openharmony_app_main (AotEntry.cs) and the
//     host dlopens libhello-maui-hybrid.so and calls it.
using Microsoft.AspNetCore.Components.WebView.Maui;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Maui;
using Microsoft.Maui.Hosting;
using Microsoft.Maui.Platform;
using Microsoft.OpenHarmony.Hosting;

namespace HelloMauiHybrid;

public static class Program
{
    public static int Main(string[] args) => Run(args);

    public static int Run(string[] args)
    {
        var builder = MauiApp.CreateBuilder();
        builder.UseOpenHarmony();
        builder.UseMauiApp<App>();
        // Blazor services + the OpenHarmony IBlazorWebView handler: AddMauiBlazorWebView()
        // registers the component services the WebViewManager's page scope resolves; the slice
        // handler (behind OPENHARMONY_BLAZOR_WEBVIEW in the csproj) is the platform half.
        builder.Services.AddMauiBlazorWebView().UsePlatformHandler<OpenHarmonyBlazorWebViewHandler>();

        var mauiApp = builder.Build();
        OpenHarmonyBridge.WriteStatus("[hello-maui-hybrid] starting MAUI application");
        var host = mauiApp.Services.GetRequiredService<OpenHarmonyMauiAppHost>();
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
