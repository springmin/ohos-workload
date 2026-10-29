// Compatibility probe entry point: the same OpenHarmony host wiring as the shipped demo,
// minus Blazor. Kept small so a toolkit failure is attributable to the toolkit, not the host.
using CommunityToolkit.Maui;
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
        var builder = MauiApp.CreateBuilder();
        builder.UseOpenHarmony();
        builder.UseMauiApp<App>();
        OpenHarmonyBridge.WriteStatus("[compat] builder configured");
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
