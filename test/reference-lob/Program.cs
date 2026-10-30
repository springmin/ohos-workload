// Reference LOB entry point: the same OpenHarmony host wiring as the compat probe, without
// CommunityToolkit. Deep links arrive through OpenHarmonyBridge.Activation (the shell forwards
// the ability want); the app navigates to the requested tab and keeps a pending route for the
// cold-start case.
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Maui;
using Microsoft.Maui.Hosting;
using Microsoft.Maui.Platform;
using Microsoft.OpenHarmony.Hosting;

namespace ReferenceLob;

public static class Program
{
    public static int Main(string[] args) => Run(args);

    public static int Run(string[] args)
    {
        OpenHarmonyBridge.WriteStatus("[ref] enter Run");
        OpenHarmonyBridge.Activation += App.HandleActivation;

        var builder = MauiApp.CreateBuilder();
        builder.UseOpenHarmony();
        builder.UseMauiApp<App>();

        var mauiApp = builder.Build();
        OpenHarmonyBridge.WriteStatus("[ref] app built");
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
