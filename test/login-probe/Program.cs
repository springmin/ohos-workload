// Login-probe entry point: no deep links, no frame probe. The app starts on a single page and
// switches content views in place, so a page/tab/modal transition cannot be the trigger.
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Maui;
using Microsoft.Maui.Hosting;
using Microsoft.Maui.Platform;
using Microsoft.OpenHarmony.Hosting;

namespace LoginProbe;

public static class Program
{
    public static int Main(string[] args) => Run(args);

    public static int Run(string[] args)
    {
        OpenHarmonyBridge.WriteStatus("[probe] enter Run");
        var builder = MauiApp.CreateBuilder();
        builder.UseOpenHarmony();
        builder.UseMauiApp<App>();

        var mauiApp = builder.Build();
        OpenHarmonyBridge.WriteStatus("[probe] app built");
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
