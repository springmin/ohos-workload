// Compatibility probe entry point: the same OpenHarmony host wiring as the shipped demo,
// minus Blazor. Kept small so a toolkit failure is attributable to the toolkit, not the host.
using CommunityToolkit.Maui;
using CommunityToolkit.Maui.Views;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Maui;
using Microsoft.Maui.Hosting;
using Microsoft.Maui.Platform;
using Microsoft.OpenHarmony.Hosting;

namespace CompatApp;

public static class Program
{
    public static int Main(string[] args) => Run(args);

    public static int Run(string[] args)
    {
        OpenHarmonyBridge.WriteStatus("[compat] enter Run");
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            OpenHarmonyBridge.WriteStatus($"[compat] UNHANDLED {e.ExceptionObject.GetType().Name}: {e.ExceptionObject}");
        AppDomain.CurrentDomain.FirstChanceException += (_, e) =>
        {
            Exception ex = e.Exception;
            if (ex is NotImplementedException or InvalidOperationException or NullReferenceException
                or ArgumentException or MissingMethodException or TypeInitializationException)
            {
                string stack = (ex.StackTrace ?? string.Empty).Replace('\n', '|');
                if (stack.Length > 400)
                {
                    stack = stack.Substring(0, 400);
                }
                string site = ex.TargetSite is { } target
                    ? $"{target.DeclaringType?.FullName}.{target.Name}"
                    : "?";
                OpenHarmonyBridge.WriteStatus($"[compat] EX {ex.GetType().Name}: {ex.Message} site={site} stack={stack}");
            }
        };
        OpenHarmonyBridge.LifecycleChanged += e =>
            OpenHarmonyBridge.WriteStatus($"[compat] lifecycle {e}");
        var builder = MauiApp.CreateBuilder();
        builder.UseOpenHarmony();
        builder.UseMauiApp<App>();
        OpenHarmonyHandlerConnector.RegisterHandler(typeof(DrawingView), typeof(CompatDrawingViewHandler));
        OpenHarmonyBridge.WriteStatus("[compat] builder configured (DrawingView handler registered)");
        builder.UseMauiCommunityToolkit();
        OpenHarmonyBridge.WriteStatus("[compat] toolkit registered");

        var mauiApp = builder.Build();
        OpenHarmonyBridge.WriteStatus("[compat] app built");
        var host = mauiApp.Services.GetRequiredService<OpenHarmonyMauiAppHost>();
        OpenHarmonyBridge.WriteStatus("[compat] starting MAUI toolkit compatibility app");
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
