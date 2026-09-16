// Thin platform surface for the OpenHarmony port (W1 skeleton).
// Grows into the full Microsoft.OpenHarmony binding in W3.
using System.Runtime.Versioning;

[assembly: SupportedOSPlatform("openharmony20.0")]

namespace Microsoft.OpenHarmony;

/// <summary>Runtime-facing helpers for OpenHarmony apps.</summary>
public static class OpenHarmonyRuntime
{
    /// <summary>True when running on OpenHarmony.</summary>
    public static bool IsOpenHarmony => OperatingSystem.IsOSPlatform("openharmony");
}
