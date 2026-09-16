using System.Runtime.InteropServices;
using Microsoft.OpenHarmony.Hosting;

string? outPath = Environment.GetEnvironmentVariable("HELLO_OUT");

// Bridged mode (inside a hap): the native host runs Main on the application's main
// thread, so Main must return quickly; the app keeps running on its own thread.
if (outPath is null)
{
    OpenHarmonyBridge.WriteStatus("hello-app Main entered");
    var worker = new Thread(() =>
    {
        OpenHarmonyBridge.Initialized += context =>
        {
            OpenHarmonyBridge.WriteStatus($"app initialized: appDir={context.AppDir} filesDir={context.FilesDir}");
            OpenHarmonyBridge.WriteStatus($"[hello-app] RID={RuntimeInformation.RuntimeIdentifier} ProcessorCount={Environment.ProcessorCount} IsOpenHarmony={Microsoft.OpenHarmony.OpenHarmonyRuntime.IsOpenHarmony}");
        };

        using var finished = new ManualResetEventSlim(false);
        OpenHarmonyBridge.LifecycleChanged += e =>
        {
            OpenHarmonyBridge.WriteStatus($"hello-app lifecycle: {e}");
            if (e == OpenHarmonyLifecycleEvent.Destroy)
            {
                finished.Set();
            }
        };

        if (OpenHarmonyBridge.Context is null)
        {
            finished.Wait(TimeSpan.FromSeconds(20));
        }
        else
        {
            finished.Wait();
        }
        OpenHarmonyBridge.WriteStatus("hello-app worker exiting");
    });
    worker.IsBackground = false;
    worker.Start();
    return 0;
}

File.WriteAllLines(outPath, new[]
{
    $"[hello-app] RID={RuntimeInformation.RuntimeIdentifier}",
    $"[hello-app] args=[{string.Join(",", args)}]",
    $"[hello-app] OSDescription={RuntimeInformation.OSDescription}",
    $"[hello-app] OSArchitecture={RuntimeInformation.OSArchitecture}",
    $"[hello-app] IsOpenHarmony={Microsoft.OpenHarmony.OpenHarmonyRuntime.IsOpenHarmony}",
    $"[hello-app] ProcessorCount={Environment.ProcessorCount}",
    $"[hello-app] TMPDIR={Path.GetTempPath()}",
    $"[hello-app] FrameworkDescription={RuntimeInformation.FrameworkDescription}",
});
return 0;
