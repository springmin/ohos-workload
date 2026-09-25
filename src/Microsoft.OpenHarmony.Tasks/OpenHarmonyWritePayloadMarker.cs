// Migrated from the inline RoslynCodeTaskFactory task 'OpenHarmonyWritePayloadMarker' in OpenHarmony.Hap.targets.
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
        using System.Security.Cryptography;
        using System.Text;
        using Microsoft.Build.Framework;
        using Microsoft.Build.Utilities;

        public class OpenHarmonyWritePayloadMarker : Task
        {
            [Required] public string DestinationDirectory { get; set; }
            [Required] public string MarkerFileName { get; set; }
            [Required] public string Assembly { get; set; }
            public int PayloadEntries { get; set; }
            public long PayloadBytes { get; set; }
            public int ZipEntries { get; set; }
            public string ZipFile { get; set; }
            [Output] public int LibsEntries { get; set; }
            [Output] public string MarkerPath { get; set; }

            public override bool Execute()
            {
                var markerPath = Path.Combine(DestinationDirectory, MarkerFileName);
                LibsEntries = 0;
                foreach (var file in Directory.GetFiles(DestinationDirectory, "*", System.IO.SearchOption.AllDirectories))
                {
                    if (string.Equals(file, markerPath, StringComparison.Ordinal))
                    {
                        continue;  // a stale marker from an earlier staging is not a libs entry
                    }
                    LibsEntries++;
                }
                var zipSha = "";
                if (!string.IsNullOrEmpty(ZipFile) && File.Exists(ZipFile))
                {
                    using (var sha = SHA256.Create())
                    using (var stream = File.OpenRead(ZipFile))
                    {
                        zipSha = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
                    }
                }
                var json = new StringBuilder();
                json.Append("{\"schema\":1,\"assembly\":\"").Append(Escape(Assembly)).Append('"');
                json.Append(",\"entries\":").Append(LibsEntries);
                json.Append(",\"payloadEntries\":").Append(PayloadEntries);
                json.Append(",\"payloadBytes\":").Append(PayloadBytes);
                json.Append(",\"zipEntries\":").Append(ZipEntries);
                json.Append(",\"zipSha256\":\"").Append(zipSha).Append('"');
                json.Append('}');
                File.WriteAllText(markerPath, json.ToString());
                MarkerPath = markerPath;
                return true;
            }

            private static string Escape(string value)
            {
                return (value ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"");
            }
        }

