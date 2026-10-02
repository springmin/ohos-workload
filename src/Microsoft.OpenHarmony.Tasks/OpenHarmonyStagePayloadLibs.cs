// Migrated from the inline RoslynCodeTaskFactory task 'OpenHarmonyStagePayloadLibs' in OpenHarmony.Hap.targets.
// The body is the inline code verbatim (task-assembly migration, audit V8 / RELEASE-25), so the
// task parameters, the log/error strings and the resulting bytes are unchanged. The assembly is
// built by scripts/prepare-packs.sh and shipped in packs/*/tools/; the targets import it with a
// UsingTask AssemblyFile instead of compiling this file at project-evaluation time.
//
// DeviceCompat (2026-09-30, enforcing images >= 7.0.0.111, see "Payload in libs" in the packaging
// doc): two file properties under libs/<abi>/ make the hap fail installation on images whose
// installer enforces the per-file code signature - (1) a file name without an extension is never
// listed in the HAP code-sign block by the SDK hap-sign-tool (NativeLibInfoSegment), so the
// installer reports "Libs signature not found"; (2) a file of exactly 4096 bytes fails the
// fs-verity enable ("enable code signature failed: 8519738"). With DeviceCompat=true the staged
// copy of such a payload file is renamed (ELF -> .so, otherwise .bin) and a 4096-byte file gets
// 4 zero padding bytes appended; the dotnet.zip fallback keeps the original names/bytes.
// Since DEVCOMPAT-DEFAULT (2026-10-02) the pack targets default this to true, so a default
// publish installs on an enforcing image out of the box; DeviceCompat=false is the escape hatch
// and keeps the previous names/bytes plus the advisory warning naming the incompatible files.
//
// #nullable disable: the MSBuild engine assigns every [Required] parameter before Execute(), and
// the original inline code predates nullable annotations; keeping it verbatim is the point.
#nullable disable


        using System;
        using System.Collections.Generic;
        using System.IO;
        using System.Text;
        using Microsoft.Build.Framework;
        using Microsoft.Build.Utilities;

        public class OpenHarmonyStagePayloadLibs : Task
        {
            [Required] public string SourceDirectory { get; set; }
            [Required] public string DestinationDirectory { get; set; }
            public string SkipFileNames { get; set; }
            public bool DeviceCompat { get; set; }
            [Output] public int CopiedCount { get; set; }
            [Output] public long CopiedBytes { get; set; }
            [Output] public int CompatRewrites { get; set; }

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
                var destinationRoot = DestinationDirectory.TrimEnd('/', '\\');
                var staged = new HashSet<string>(StringComparer.Ordinal);
                if (DeviceCompat && Directory.Exists(destinationRoot))
                {
                    // Files staged earlier (host, libc++_shared.so, runtime natives) take part in
                    // the collision check for a renamed payload file.
                    foreach (var existing in Directory.GetFiles(destinationRoot, "*", SearchOption.AllDirectories))
                    {
                        staged.Add(RelativeName(destinationRoot, existing));
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
                    var destinationRelative = relative;
                    if (DeviceCompat && Path.GetExtension(name).Length == 0)
                    {
                        // (1) extension-less names are not covered by the HAP code-sign block.
                        destinationRelative = relative + (IsElf(file) ? ".so" : ".bin");
                    }
                    if (DeviceCompat && !staged.Add(destinationRelative.Replace('\\', '/')))
                    {
                        Log.LogError("OpenHarmony payload-in-libs device compat: '{0}' maps to '{1}', " +
                                     "which is already staged under libs/; rename or skip one of the two files",
                                     relative, destinationRelative);
                        return false;
                    }
                    var destination = Path.Combine(DestinationDirectory, destinationRelative);
                    var parent = Path.GetDirectoryName(destination);
                    if (!string.IsNullOrEmpty(parent))
                    {
                        Directory.CreateDirectory(parent);
                    }
                    File.Copy(file, destination, true);
                    long size = new FileInfo(destination).Length;
                    bool rewritten = false;
                    if (DeviceCompat && !string.Equals(destinationRelative, relative, StringComparison.Ordinal))
                    {
                        rewritten = true;
                        Log.LogMessage(MessageImportance.High,
                                       "OpenHarmony payload-in-libs device compat: staged '{0}' as '{1}' " +
                                       "(an extension-less name is not covered by the HAP code-sign block)", relative, destinationRelative);
                    }
                    if (DeviceCompat && size == 4096)
                    {
                        // (2) a file of exactly one fs-verity block fails the enable on enforcing images.
                        using (var stream = new FileStream(destination, FileMode.Append, FileAccess.Write))
                        {
                            stream.Write(new byte[4], 0, 4);
                        }
                        size += 4;
                        rewritten = true;
                        Log.LogMessage(MessageImportance.High,
                                       "OpenHarmony payload-in-libs device compat: padded '{0}' from 4096 to 4100 bytes " +
                                       "(enforcing images reject a libs file of exactly one 4096-byte block)", destinationRelative);
                    }
                    if (rewritten)
                    {
                        CompatRewrites++;
                    }
                    CopiedCount++;
                    CopiedBytes += size;
                }
                if (DeviceCompat)
                {
                    // One status line per build (DEVCOMPAT-DEFAULT): the rewrite is the default now,
                    // so the build output states it is active and how many entries it changed.
                    Log.LogMessage(MessageImportance.High,
                                   "OpenHarmony payload-in-libs device compat: enabled for enforcing images " +
                                   "(>= 7.0.0.111); extension-less names staged as .so/.bin, 4096-byte files " +
                                   "padded to 4100 bytes ({0} rewrite(s)); dotnet.zip keeps the original names/bytes",
                                   CompatRewrites);
                }
                else
                {
                    // Escape hatch: the staged libs copy keeps the previous names/bytes; name the
                    // files an enforcing image rejects instead of shipping them silently.
                    WarnOnIncompatibleStagedFiles(destinationRoot);
                }
                return true;
            }

            private static bool IsElf(string path)
            {
                using (var stream = File.OpenRead(path))
                {
                    var magic = new byte[4];
                    return stream.Read(magic, 0, 4) == 4
                        && magic[0] == 0x7F && magic[1] == (byte)'E'
                        && magic[2] == (byte)'L' && magic[3] == (byte)'F';
                }
            }

            private static string RelativeName(string root, string path)
            {
                return path.Substring(root.Length).TrimStart('/', '\\').Replace('\\', '/');
            }

            // Advisory for the DeviceCompat=false escape hatch: name the staged files an
            // enforcing image (>= 7.0.0.111) rejects and the two properties that fix the build.
            private void WarnOnIncompatibleStagedFiles(string destinationRoot)
            {
                if (!Directory.Exists(destinationRoot))
                {
                    return;
                }
                var extensionless = new List<string>();
                var oneBlock = new List<string>();
                foreach (var file in Directory.GetFiles(destinationRoot, "*", SearchOption.AllDirectories))
                {
                    var name = RelativeName(destinationRoot, file);
                    if (Path.GetExtension(Path.GetFileName(file)).Length == 0)
                    {
                        extensionless.Add(name);
                    }
                    else if (new FileInfo(file).Length == 4096)
                    {
                        oneBlock.Add(name);
                    }
                }
                if (extensionless.Count == 0 && oneBlock.Count == 0)
                {
                    return;
                }
                var message = new StringBuilder("OpenHarmony payload-in-libs: the staged libs/ payload cannot " +
                    "be installed on enforcing device images (>= 7.0.0.111): ");
                if (extensionless.Count > 0)
                {
                    message.Append(extensionless.Count).Append(" file name(s) without an extension are not covered " +
                        "by the HAP code-sign block (")
                        .Append(string.Join(", ", extensionless.GetRange(0, Math.Min(8, extensionless.Count))))
                        .Append(extensionless.Count > 8 ? ", ..." : "").Append("); ");
                }
                if (oneBlock.Count > 0)
                {
                    message.Append(oneBlock.Count).Append(" file(s) of exactly 4096 bytes fail the fs-verity enable (")
                        .Append(string.Join(", ", oneBlock.GetRange(0, Math.Min(8, oneBlock.Count))))
                        .Append(oneBlock.Count > 8 ? ", ..." : "").Append("); ");
                }
                message.Append("the default rewrite (OpenHarmonyHapPayloadInLibsDeviceCompat=true, or unset) " +
                    "fixes this, or -p:OpenHarmonyHapPayloadInLibs=false ships the payload only in dotnet.zip");
                Log.LogWarning(message.ToString());
            }
        }
