// Bridge-mode entry point for the B2 demo (tests/hello-maui-wasm): builds the MauiApp with the
// OpenHarmony platform services and hands the application to the platform host, which renders it
// when the XComponent surface arrives and forwards touch/frame/lifecycle events.
//
// Unlike test/hello-maui-app there is no AddMauiBlazorWebView() here: this window hosts a full
// Blazor WebAssembly site in a plain WebView (the site runs its own runtime inside ArkWeb), not
// Blazor Hybrid components in-process. The WebView handler comes from UseOpenHarmony()'s slice
// registry (IWebView -> OpenHarmonyWebViewHandler).
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Maui;
using Microsoft.Maui.Hosting;
using Microsoft.Maui.Platform;
using Microsoft.OpenHarmony.Hosting;

namespace HelloMauiWasm;

public static class Program
{
    public static int Main(string[] args)
    {
        // Entry-point breadcrumb: on this image the managed side's only readable channel during
        // startup is dotnet-status.txt (the shell polls it); writing here proves whether the
        // NativeAOT trampoline reached the managed entry point at all.
        StatusBreadcrumb.Write("managed Main reached");
        return Run(args);
    }

    public static int Run(string[] args)
    {
        try
        {
            return RunCore(args);
        }
        catch (Exception ex)
        {
            StatusBreadcrumb.Write($"FAILURE: {ex.GetType().Name}: {ex.Message}");
            // Diagnostic surface: this image has no readable managed stderr/hilog for an app
            // process, so a startup failure is pushed through the shell's web overlay as a data
            // page (visible in the app window and in the shell's [maui] web cmd: data log) and
            // the process is kept alive briefly so a device run can capture it.
            try
            {
                OpenHarmonyBridge.WebCommand("data",
                    "<html><body style='font-family:monospace;font-size:14px;white-space:pre-wrap'>" +
                    "hello-maui-wasm FAILURE:\n" + System.Net.WebUtility.HtmlEncode(ex.ToString()) +
                    "</body></html>");
            }
            catch
            {
                // The diagnostics must never mask the original failure.
            }
            Thread.Sleep(TimeSpan.FromSeconds(5));
            return 1;
        }
    }

    public static int RunCore(string[] args)
    {
        StatusBreadcrumb.Write("runcore: building");
        var builder = MauiApp.CreateBuilder();
        builder.UseOpenHarmony();
        builder.UseMauiApp<App>();

        var mauiApp = builder.Build();
        StatusBreadcrumb.Write("runcore: built");
        var host = mauiApp.Services.GetRequiredService<OpenHarmonyMauiAppHost>();
        StatusBreadcrumb.Write("runcore: host resolved");

        host.Run(mauiApp.Services.GetRequiredService<IApplication>());
        StatusBreadcrumb.Write("runcore: host.Run returned");

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
