namespace HelloLib;

public static class Hello
{
    public static string Greeting => $"Hello from {Microsoft.OpenHarmony.OpenHarmonyRuntime.IsOpenHarmony} on {System.Runtime.InteropServices.RuntimeInformation.RuntimeIdentifier}";
}
