// Extracts one embedded resource out of a referenced assembly into the hap payload.
//
// Why this task exists (SAMPLE-FIX, 2026-10-03): the HybridWebView bootstrap script
// (_framework/hybridwebview.js) is an embedded resource of Microsoft.Maui.dll; the managed
// HybridWebView handler extracts it next to the payload at runtime, but in the
// payload-in-libs launch modes (JIT DEVCOMPAT and NativeAOT) the payload root is the
// read-only bundle libs directory, so that write fails and the shell answers the stock
// script with 404. Staging the resource at pack time puts it in the payload itself
// (dotnet.zip and libs/<abi>/), where both payload modes serve it, and the runtime
// extraction becomes a no-op for pack-staged apps (it stays the fallback for apps built
// with older packs).
//
// The task stays dependency-free on purpose: it inspects the assembly file directly with
// Assembly.LoadFile, which does not resolve the assembly's references (only the manifest
// resource stream is read), so it works under either MSBuild host. A missing resource is a
// warning, not an error: HybridWebView is optional and the runtime extraction still covers
// a future package that moves or renames the resource.
#nullable disable
using System;
using System.IO;
using System.Reflection;
using Microsoft.Build.Framework;
using Microsoft.Build.Utilities;

public class OpenHarmonyExtractEmbeddedResource : Task
{
    /// <summary>Assembly file to read (usually a resolved Microsoft.Maui.dll reference).</summary>
    [Required]
    public string AssemblyPath { get; set; }

    /// <summary>Manifest resource name, for example "_framework/hybridwebview.js".</summary>
    [Required]
    public string ResourceName { get; set; }

    /// <summary>Destination file; parent directories are created.</summary>
    [Required]
    public string DestinationFile { get; set; }

    /// <summary>True when the destination was written (false when it was already up to date).</summary>
    [Output]
    public bool Extracted { get; set; }

    public override bool Execute()
    {
        if (string.IsNullOrEmpty(AssemblyPath) || !File.Exists(AssemblyPath))
        {
            Log.LogError("OpenHarmony embedded resource extraction: assembly not found: '{0}'", AssemblyPath);
            return false;
        }

        Assembly assembly;
        try
        {
            // Load-from-file keeps this out of the task host's default context and, crucially,
            // does not probe the assembly's references (the resource stream is pure metadata).
            assembly = Assembly.LoadFile(Path.GetFullPath(AssemblyPath));
        }
        catch (Exception ex) when (ex is BadImageFormatException || ex is FileLoadException || ex is IOException)
        {
            Log.LogError("OpenHarmony embedded resource extraction: cannot read '{0}': {1}", AssemblyPath, ex.Message);
            return false;
        }

        using (Stream resource = assembly.GetManifestResourceStream(ResourceName))
        {
            if (resource is null)
            {
                // Keep the previous behavior visible instead of failing the build: the runtime
                // extraction still serves writable payloads, and the warning names the contract.
                Log.LogWarning(
                    "OpenHarmony embedded resource extraction: '{0}' has no embedded resource '{1}'; " +
                    "the app falls back to the runtime HybridWebView script extraction",
                    AssemblyPath, ResourceName);
                return true;
            }

            string destination = Path.GetFullPath(DestinationFile);
            if (IsUpToDate(resource, destination))
            {
                Extracted = false;
                Log.LogMessage(MessageImportance.Low,
                    "OpenHarmony: embedded resource '{0}' already staged at {1}", ResourceName, destination);
                return true;
            }

            string directory = Path.GetDirectoryName(destination);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }
            using (FileStream file = File.Create(destination))
            {
                resource.CopyTo(file);
            }
            Extracted = true;
            Log.LogMessage(MessageImportance.High,
                "OpenHarmony: staged embedded resource '{0}' from {1} -> {2} ({3} bytes)",
                ResourceName, AssemblyPath, DestinationFile, new FileInfo(destination).Length);
            return true;
        }
    }

    // Byte comparison keeps the destination (and therefore the deterministic payload zip,
    // which stores fixed timestamps) stable across repeated builds of the same package.
    private static bool IsUpToDate(Stream resource, string destination)
    {
        var info = new FileInfo(destination);
        if (!info.Exists || info.Length != resource.Length)
        {
            return false;
        }
        resource.Position = 0;
        using (FileStream existing = File.OpenRead(destination))
        {
            var buffer = new byte[8192];
            var candidate = new byte[8192];
            while (true)
            {
                int read = resource.Read(buffer, 0, buffer.Length);
                int have = 0;
                while (have < read)
                {
                    int chunk = existing.Read(candidate, have, read - have);
                    if (chunk <= 0)
                    {
                        return false;
                    }
                    have += chunk;
                }
                if (read == 0)
                {
                    return existing.ReadByte() < 0;
                }
                for (int i = 0; i < read; i++)
                {
                    if (buffer[i] != candidate[i])
                    {
                        return false;
                    }
                }
            }
        }
    }
}
