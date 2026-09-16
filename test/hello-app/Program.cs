using System.Runtime.InteropServices;

var lines = new List<string>
{
    $"[hello-app] RID={RuntimeInformation.RuntimeIdentifier}",
    $"[hello-app] OSDescription={RuntimeInformation.OSDescription}",
    $"[hello-app] OSArchitecture={RuntimeInformation.OSArchitecture}",
    $"[hello-app] IsOpenHarmony={Microsoft.OpenHarmony.OpenHarmonyRuntime.IsOpenHarmony}",
    $"[hello-app] ProcessorCount={Environment.ProcessorCount}",
    $"[hello-app] TMPDIR={Path.GetTempPath()}",
    $"[hello-app] FrameworkDescription={RuntimeInformation.FrameworkDescription}",
    $"[hello-app] Assembly(Microsoft.OpenHarmony)={typeof(Microsoft.OpenHarmony.OpenHarmonyRuntime).Assembly.Location}",
};
File.WriteAllLines(Environment.GetEnvironmentVariable("HELLO_OUT") ?? "/data/storage/el2/base/tmp/opencode/hello-app-out.txt", lines);
