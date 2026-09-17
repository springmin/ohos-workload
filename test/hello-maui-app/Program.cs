// Bridge-mode entry point: builds the MauiApp with the OpenHarmony platform services and
// hands the application to the platform host, which renders it when the XComponent surface
// arrives and forwards touch/frame/lifecycle events.
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Maui;
using Microsoft.Maui.Hosting;
using Microsoft.Maui.Platform;
using Microsoft.OpenHarmony.Hosting;
using HelloMauiApp;

var builder = MauiApp.CreateBuilder();
builder.UseOpenHarmony();
builder.UseMauiApp<App>();

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
