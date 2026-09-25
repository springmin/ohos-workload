// Migrated from the inline RoslynCodeTaskFactory task 'OpenHarmonyStagePayloadLibs' in OpenHarmony.Hap.targets.
// The body is the inline code verbatim (task-assembly migration, audit V8 / RELEASE-25), so the
// task parameters, the log/error strings and the resulting bytes are unchanged. The assembly is
// built by scripts/prepare-packs.sh and shipped in packs/*/tools/; the targets import it with a
// UsingTask AssemblyFile instead of compiling this file at project-evaluation time.
//
// #nullable disable: the MSBuild engine assigns every [Required] parameter before Execute(), and
// the original inline code predates nullable annotations; keeping it verbatim is the point.
#nullable disable


        using System;
        using System.Collections.Generic;
        using System.IO;
        using Microsoft.Build.Framework;
        using Microsoft.Build.Utilities;

        public class OpenHarmonyStagePayloadLibs : Task
        {
            [Required] public string SourceDirectory { get; set; }
            [Required] public string DestinationDirectory { get; set; }
            public string SkipFileNames { get; set; }
            [Output] public int CopiedCount { get; set; }
            [Output] public long CopiedBytes { get; set; }

            public override bool Execute()
            {
                if (string.IsNullOrEmpty(SourceDirectory) || !Directory.Exists(SourceDirectory))
                {
                    Log.LogError("OpenHarmony payload-in-libs: publish directory '{0}' does not exist", SourceDirectory);
                    return false;
                }
                var skip = new HashSet<string>(StringComparer.Ordinal);
                if (!string.IsNullOrEmpty(SkipFileNames))
                {
                    foreach (var name in SkipFileNames.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries))
                    {
                        skip.Add(name.Trim());
                    }
                }
                Directory.CreateDirectory(DestinationDirectory);
                var files = Directory.GetFiles(SourceDirectory, "*", System.IO.SearchOption.AllDirectories);
                Array.Sort(files, StringComparer.Ordinal);
                var source = SourceDirectory.TrimEnd('/', '\\');
                foreach (var file in files)
                {
                    var name = Path.GetFileName(file);
                    if (skip.Contains(name))
                    {
                        continue;
                    }
                    var relative = file.Substring(source.Length).TrimStart('/', '\\');
                    var destination = Path.Combine(DestinationDirectory, relative);
                    var parent = Path.GetDirectoryName(destination);
                    if (!string.IsNullOrEmpty(parent))
                    {
                        Directory.CreateDirectory(parent);
                    }
                    File.Copy(file, destination, true);
                    CopiedCount++;
                    CopiedBytes += new FileInfo(file).Length;
                }
                return true;
            }
        }

