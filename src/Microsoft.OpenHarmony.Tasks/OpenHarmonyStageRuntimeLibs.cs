// Migrated from the inline RoslynCodeTaskFactory task 'OpenHarmonyStageRuntimeLibs' in OpenHarmony.Hap.targets.
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

        public class OpenHarmonyStageRuntimeLibs : Task
        {
            public ITaskItem[] SourceFiles { get; set; }
            [Required] public string DestinationDirectory { get; set; }
            public string SkipFileNames { get; set; }
            [Output] public int CopiedCount { get; set; }
            [Output] public long CopiedBytes { get; set; }
            [Output] public ITaskItem[] CopiedFiles { get; set; }

            public override bool Execute()
            {
                var skip = new HashSet<string>(StringComparer.Ordinal);
                if (!string.IsNullOrEmpty(SkipFileNames))
                {
                    foreach (var name in SkipFileNames.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries))
                    {
                        skip.Add(name.Trim());
                    }
                }

                Directory.CreateDirectory(DestinationDirectory);
                var copied = new List<ITaskItem>();
                long bytes = 0;
                if (SourceFiles != null)
                {
                    foreach (var item in SourceFiles)
                    {
                        var path = item.ItemSpec;
                        var name = Path.GetFileName(path);
                        if (skip.Contains(name))
                        {
                            Log.LogMessage(MessageImportance.Low, "OpenHarmony runtime libs: keeping the SDK copy of {0}", name);
                            continue;
                        }
                        if (!File.Exists(path))
                        {
                            continue;
                        }
                        if (!IsElf(path))
                        {
                            Log.LogMessage(MessageImportance.Low, "OpenHarmony runtime libs: skipping non-ELF {0}", path);
                            continue;
                        }
                        var destination = Path.Combine(DestinationDirectory, name);
                        File.Copy(path, destination, true);
                        copied.Add(new TaskItem(destination));
                        bytes += new FileInfo(path).Length;
                    }
                }
                CopiedFiles = copied.ToArray();
                CopiedCount = copied.Count;
                CopiedBytes = bytes;
                return true;
            }

            private static bool IsElf(string path)
            {
                using (var stream = File.OpenRead(path))
                {
                    var magic = new byte[4];
                    if (stream.Read(magic, 0, 4) != 4)
                    {
                        return false;
                    }
                    return magic[0] == 0x7F && magic[1] == (byte)'E' && magic[2] == (byte)'L' && magic[3] == (byte)'F';
                }
            }
        }

