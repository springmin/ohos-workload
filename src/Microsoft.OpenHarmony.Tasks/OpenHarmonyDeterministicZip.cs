// Migrated from the inline RoslynCodeTaskFactory task 'OpenHarmonyDeterministicZip' in OpenHarmony.Hap.targets.
// The body is the inline code verbatim (task-assembly migration, audit V8 / RELEASE-25), so the
// task parameters, the log/error strings and the resulting bytes are unchanged. The assembly is
// built by scripts/prepare-packs.sh and shipped in packs/*/tools/; the targets import it with a
// UsingTask AssemblyFile instead of compiling this file at project-evaluation time.
//
// #nullable disable: the MSBuild engine assigns every [Required] parameter before Execute(), and
// the original inline code predates nullable annotations; keeping it verbatim is the point.
#nullable disable

using System;
using System.IO;
using System.IO.Compression;
using Microsoft.Build.Framework;
using Microsoft.Build.Utilities;

public class OpenHarmonyDeterministicZip : Task
{
    [Required] public string SourceDirectory { get; set; }
    [Required] public string DestinationFile { get; set; }
    public string ExcludeFileNames { get; set; }
    [Output] public int ExcludedCount { get; set; }
    [Output] public int IncludedCount { get; set; }

    public override bool Execute()
    {

        var fixedTime = new System.DateTimeOffset(1980, 1, 1, 0, 0, 0, System.TimeSpan.Zero);
        var exclude = new System.Collections.Generic.HashSet<string>(System.StringComparer.Ordinal);
        if (!System.String.IsNullOrEmpty(ExcludeFileNames))
        {
            foreach (var name in ExcludeFileNames.Split(new[] { ';' }, System.StringSplitOptions.RemoveEmptyEntries))
            {
                exclude.Add(name.Trim());
            }
        }
        var files = System.IO.Directory.GetFiles(SourceDirectory, "*", System.IO.SearchOption.AllDirectories);
        System.Array.Sort(files, System.StringComparer.Ordinal);
        System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(DestinationFile));
        using (var stream = System.IO.File.Create(DestinationFile))
        using (var archive = new System.IO.Compression.ZipArchive(stream, System.IO.Compression.ZipArchiveMode.Create))
        {
            foreach (var file in files)
            {
                var entryName = file.Substring(SourceDirectory.Length).TrimStart('/', '\\').Replace('\\', '/');
                if (exclude.Contains(System.IO.Path.GetFileName(file)))
                {
                    ExcludedCount++;
                    continue;
                }
                var entry = archive.CreateEntry(entryName, System.IO.Compression.CompressionLevel.Optimal);
                entry.LastWriteTime = fixedTime;
                using (var entryStream = entry.Open())
                using (var fileStream = System.IO.File.OpenRead(file))
                {
                    fileStream.CopyTo(entryStream);
                }
                IncludedCount++;
            }
        }

        return true;
    }
}
