// Unit tests for the seven compiled hap-packaging tasks. Every check runs the real task class with a
// stub IBuildEngine, so the assertions are on the shipped behaviour (deterministic zip bytes, skip
// names, JSON generation, marker fields, permission resolution and the log/error strings), not on
// a reimplementation. scripts/selftest-tasks.sh runs this; it exits non-zero on the first failure
// summary and prints the [tasks-tests] contract line the gate greps for.
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Build.Framework;
using Microsoft.Build.Utilities;

namespace OpenHarmonyTasksTests;

internal static class Program
{
    private static int _checks;
    private static int _failed;

    private static void Check(string name, bool ok, string? detail = null)
    {
        _checks++;
        if (ok)
        {
            Console.WriteLine($"[check] PASS {name}");
        }
        else
        {
            _failed++;
            Console.WriteLine($"[check] FAIL {name}{(detail is null ? "" : ": " + detail)}");
        }
    }

    private static void CheckEqual<T>(string name, T expected, T actual)
    {
        Check(name, EqualityComparer<T>.Default.Equals(expected, actual), $"expected '{expected}', got '{actual}'");
    }

    private static byte[] Elf(params byte[] body)
    {
        var bytes = new byte[4 + body.Length];
        bytes[0] = 0x7F;
        bytes[1] = (byte)'E';
        bytes[2] = (byte)'L';
        bytes[3] = (byte)'F';
        body.CopyTo(bytes, 4);
        return bytes;
    }

    private static string Sha256Hex(byte[] bytes)
    {
        return Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    }

    private static string Sha256Hex(string path)
    {
        return Sha256Hex(File.ReadAllBytes(path));
    }

    private static int Main()
    {
        Console.WriteLine("[tasks-tests] OpenHarmony packaging task unit tests");
        DeterministicZipTests();
        StageRuntimeLibsTests();
        StagePayloadLibsTests();
        WritePayloadMarkerTests();
        ResolvePermissionsTests();
        GenerateModuleJsonTests();
        ExtractEmbeddedResourceTests();

        bool ok = _failed == 0;
        Console.WriteLine($"[tasks-tests] checks={_checks} failed={_failed} assert={(ok ? "True" : "False")}");
        return ok ? 0 : 1;
    }

    // ---------------------------------------------------------------- deterministic zip

    private static void DeterministicZipTests()
    {
        // 1. Two runs over the same tree produce identical bytes (ordinal order + fixed time).
        string source = Harness.TempDir("zip-det");
        Harness.WriteFile(Path.Combine(source, "b.txt"), "bravo");
        Harness.WriteFile(Path.Combine(source, "a.txt"), "alpha");
        Harness.WriteFile(Path.Combine(source, "sub", "c.txt"), "charlie");
        string first = Path.Combine(Harness.TempDir("zip-det-out1"), "dotnet.zip");
        string second = Path.Combine(Harness.TempDir("zip-det-out2"), "dotnet.zip");
        var task1 = new OpenHarmonyDeterministicZip { SourceDirectory = source, DestinationFile = first };
        var task2 = new OpenHarmonyDeterministicZip { SourceDirectory = source, DestinationFile = second };
        var (ok1, _) = Harness.Run(task1);
        var (ok2, _) = Harness.Run(task2);
        Check("zip runs twice", ok1 && ok2);
        CheckEqual("zip bytes are deterministic", Sha256Hex(first), Sha256Hex(second));
        CheckEqual("zip entry count is reported", 3, task1.IncludedCount);
        CheckEqual("zip excluded count is 0", 0, task1.ExcludedCount);

        using (var archive = ZipFile.OpenRead(first))
        {
            var names = archive.Entries.Select(e => e.FullName).ToArray();
            CheckEqual("zip entry order is ordinal (a.txt, b.txt, sub/c.txt)", "a.txt|b.txt|sub/c.txt", string.Join("|", names));
            Check("zip entry names use forward slashes", names.All(n => !n.Contains('\\')));
            var stamps = archive.Entries.Select(e => e.LastWriteTime.UtcDateTime).Distinct().ToArray();
            Check("zip entries all carry the fixed 1980-01-01 timestamp",
                stamps.Length == 1 && stamps[0] == new DateTime(1980, 1, 1, 0, 0, 0, DateTimeKind.Utc),
                string.Join(",", stamps));
            using var reader = new StreamReader(archive.Entries.Single(e => e.FullName == "sub/c.txt").Open());
            CheckEqual("zip entry content round-trips", "charlie", reader.ReadToEnd());
        }

        // 2. ExcludeFileNames drops by file name at every depth (the runtime-ELF exclusion set).
        string exSource = Harness.TempDir("zip-exclude");
        Harness.WriteFile(Path.Combine(exSource, "libcoreclr.so"), "elf");
        Harness.WriteFile(Path.Combine(exSource, "nested", "libcoreclr.so"), "elf-nested");
        Harness.WriteFile(Path.Combine(exSource, "keep.dll"), "managed");
        string exOut = Path.Combine(Harness.TempDir("zip-exclude-out"), "dotnet.zip");
        var exTask = new OpenHarmonyDeterministicZip
        {
            SourceDirectory = exSource,
            DestinationFile = exOut,
            ExcludeFileNames = " libcoreclr.so ; not-present.so ",
        };
        var (exOk, _) = Harness.Run(exTask);
        Check("zip exclude run succeeds", exOk);
        CheckEqual("zip excluded count counts nested matches", 2, exTask.ExcludedCount);
        CheckEqual("zip included count keeps the rest", 1, exTask.IncludedCount);
        using (var archive = ZipFile.OpenRead(exOut))
        {
            CheckEqual("zip excluded names are absent", "keep.dll", string.Join("|", archive.Entries.Select(e => e.FullName)));
        }

        // 3. An empty source directory still produces a valid empty zip.
        string emptySource = Harness.TempDir("zip-empty");
        string emptyOut = Path.Combine(Harness.TempDir("zip-empty-out"), "dotnet.zip");
        var emptyTask = new OpenHarmonyDeterministicZip { SourceDirectory = emptySource, DestinationFile = emptyOut };
        var (emptyOk, _) = Harness.Run(emptyTask);
        Check("zip empty source succeeds", emptyOk);
        CheckEqual("zip empty source reports 0 entries", 0, emptyTask.IncludedCount);
        using (var archive = ZipFile.OpenRead(emptyOut))
        {
            CheckEqual("zip empty source has no entries", "0", archive.Entries.Count.ToString());
        }
    }

    // ---------------------------------------------------------------- runtime-native staging

    private static void StageRuntimeLibsTests()
    {
        string source = Harness.TempDir("runtime-libs-src");
        string elf = Path.Combine(source, "libSystem.Native.so");
        string skip = Path.Combine(source, "libhostfxr.so");
        string notElf = Path.Combine(source, "libtext.so");
        string missing = Path.Combine(source, "libgone.so");
        Harness.WriteBytes(elf, Elf(1, 2, 3));
        Harness.WriteBytes(skip, Elf(9));
        Harness.WriteBytes(notElf, Encoding.ASCII.GetBytes("not an elf"));
        string destination = Harness.TempDir("runtime-libs-dst");

        var task = new OpenHarmonyStageRuntimeLibs
        {
            SourceFiles = new ITaskItem[] { Harness.Item(skip), Harness.Item(elf), Harness.Item(notElf), Harness.Item(missing) },
            DestinationDirectory = destination,
            SkipFileNames = " libhostfxr.so ; libc++_shared.so ",
        };
        var (ok, engine) = Harness.Run(task);
        Check("runtime libs run succeeds", ok);
        CheckEqual("runtime libs copied count skips the SDK names", 1, task.CopiedCount);
        CheckEqual("runtime libs copied bytes count the source length", 7L, task.CopiedBytes);
        CheckEqual("runtime libs copied file reports the destination", Path.Combine(destination, "libSystem.Native.so"), task.CopiedFiles.Single().ItemSpec);
        Check("runtime libs skip is logged at low importance", engine.Messages.Any(m => m.Contains("keeping the SDK copy of libhostfxr.so")));
        Check("runtime libs non-ELF is logged at low importance", engine.Messages.Any(m => m.Contains("skipping non-ELF")));
        Check("runtime libs staged file exists", File.Exists(Path.Combine(destination, "libSystem.Native.so")));
        Check("runtime libs skip name is not copied", !File.Exists(Path.Combine(destination, "libhostfxr.so")));

        var empty = new OpenHarmonyStageRuntimeLibs { DestinationDirectory = destination, SourceFiles = null };
        var (emptyOk, _) = Harness.Run(empty);
        Check("runtime libs null source list is not an error", emptyOk);
        CheckEqual("runtime libs null source list reports 0", 0, empty.CopiedCount);
    }

    // ---------------------------------------------------------------- payload staging

    private static void StagePayloadLibsTests()
    {
        string source = Harness.TempDir("payload-src");
        Harness.WriteFile(Path.Combine(source, "app.dll"), "app");
        Harness.WriteFile(Path.Combine(source, "sub", "dep.dll"), "dep");
        Harness.WriteFile(Path.Combine(source, "libhostfxr.so"), "hostfxr");
        string destination = Harness.TempDir("payload-dst");

        var task = new OpenHarmonyStagePayloadLibs
        {
            SourceDirectory = source + "/",
            DestinationDirectory = destination,
            SkipFileNames = "libhostfxr.so",
        };
        var (ok, _) = Harness.Run(task);
        Check("payload staging succeeds", ok);
        CheckEqual("payload copied count", 2, task.CopiedCount);
        CheckEqual("payload copied bytes", 6L, task.CopiedBytes);
        Check("payload keeps the relative layout", File.Exists(Path.Combine(destination, "sub", "dep.dll")));
        Check("payload copies the root file", File.Exists(Path.Combine(destination, "app.dll")));
        Check("payload skip name is not copied", !File.Exists(Path.Combine(destination, "libhostfxr.so")));

        var missing = new OpenHarmonyStagePayloadLibs
        {
            SourceDirectory = Path.Combine(source, "does-not-exist"),
            DestinationDirectory = destination,
        };
        var (missingOk, engine) = Harness.Run(missing);
        Check("payload missing source directory is an error", !missingOk);
        Check("payload missing source directory names the path", engine.HasErrorContaining("does not exist"));

        // Device compat for enforcing images >= 7.0.0.111 (default since DEVCOMPAT-DEFAULT): the SDK
        // HAP signer never covers an extension-less libs file in the code-sign block and a file of
        // exactly 4096 bytes fails the fs-verity enable, so the rewrite stages <name>.so/.bin and
        // pads 4096 -> 4100.
        string compatSrc = Harness.TempDir("payload-compat-src");
        Harness.WriteBytes(Path.Combine(compatSrc, "createdump"), Elf(new byte[8]));
        Harness.WriteFile(Path.Combine(compatSrc, "notes"), "no extension, not ELF");
        Harness.WriteBytes(Path.Combine(compatSrc, "exact.dll"), new byte[4096]);
        Harness.WriteFile(Path.Combine(compatSrc, "keep.dll"), "keep");
        string compatDst = Harness.TempDir("payload-compat-dst");
        var compat = new OpenHarmonyStagePayloadLibs
        {
            SourceDirectory = compatSrc,
            DestinationDirectory = compatDst,
            DeviceCompat = true,
        };
        var (compatOk, compatEngine) = Harness.Run(compat);
        Check("device compat staging succeeds", compatOk);
        CheckEqual("device compat copied count", 4, compat.CopiedCount);
        CheckEqual("device compat rewrite count", 3, compat.CompatRewrites);
        CheckEqual("device compat copied bytes account for the padding", 4137L, compat.CopiedBytes);
        Check("device compat stages ELF as .so", File.Exists(Path.Combine(compatDst, "createdump.so")));
        Check("device compat stages non-ELF as .bin", File.Exists(Path.Combine(compatDst, "notes.bin")));
        CheckEqual("device compat pads a 4096-byte file", 4100L, new FileInfo(Path.Combine(compatDst, "exact.dll")).Length);
        CheckEqual("device compat keeps other files untouched", "keep", File.ReadAllText(Path.Combine(compatDst, "keep.dll")));
        // DEVCOMPAT-DEFAULT: the rewrite being the default is stated in the build output.
        Check("device compat logs the enabled status line", compatEngine.HasMessageContaining("device compat: enabled"));
        Check("device compat status line promises the original dotnet.zip names/bytes",
            compatEngine.HasMessageContaining("dotnet.zip keeps the original names/bytes"));

        // The marker written after a normalization keeps its count/identity semantics, and the
        // dotnet.zip fallback stays byte-identical: entries = real libs count, payloadEntries =
        // what the staging copied (4, renames/padding do not change the count), the zip sha is
        // the fallback file's, and the fallback bytes are untouched.
        string fallbackZip = Path.Combine(Harness.TempDir("payload-compat-zip"), "dotnet.zip");
        Harness.WriteBytes(fallbackZip, Encoding.ASCII.GetBytes("zip-fallback-original"));
        string fallbackSha = Sha256Hex(fallbackZip);
        var normalizedMarker = new OpenHarmonyWritePayloadMarker
        {
            DestinationDirectory = compatDst,
            MarkerFileName = ".dotnet-payload.json",
            Assembly = "hello.dll",
            PayloadEntries = compat.CopiedCount,
            PayloadBytes = compat.CopiedBytes,
            ZipEntries = 4,
            ZipFile = fallbackZip,
        };
        var (normalizedMarkerOk, _) = Harness.Run(normalizedMarker);
        Check("device compat marker run succeeds", normalizedMarkerOk);
        CheckEqual("device compat marker counts the normalized libs entries", 4, normalizedMarker.LibsEntries);
        using (var doc = JsonDocument.Parse(File.ReadAllText(normalizedMarker.MarkerPath)))
        {
            var root = doc.RootElement;
            CheckEqual("device compat marker entries stay the real libs count", 4, root.GetProperty("entries").GetInt32());
            CheckEqual("device compat marker payloadEntries stay the copied count", 4, root.GetProperty("payloadEntries").GetInt32());
            CheckEqual("device compat marker payloadBytes account for the padding", 4137L, root.GetProperty("payloadBytes").GetInt64());
            CheckEqual("device compat marker zipEntries stay the zip identity", 4, root.GetProperty("zipEntries").GetInt32());
            CheckEqual("device compat marker zip sha matches the fallback", fallbackSha, root.GetProperty("zipSha256").GetString());
        }
        CheckEqual("device compat leaves the dotnet.zip fallback bytes unchanged", fallbackSha, Sha256Hex(fallbackZip));

        string plainDst = Harness.TempDir("payload-plain-dst");
        var plain = new OpenHarmonyStagePayloadLibs
        {
            SourceDirectory = compatSrc,
            DestinationDirectory = plainDst,
        };
        var (plainOk, plainEngine) = Harness.Run(plain);
        Check("escape-hatch layout staging succeeds", plainOk);
        Check("escape-hatch layout warns about enforcing images", plainEngine.HasWarningContaining("7.0.0.111"));
        Check("escape-hatch layout warning names the extension-less file", plainEngine.HasWarningContaining("createdump"));
        Check("escape-hatch layout warning points at the default rewrite", plainEngine.HasWarningContaining("OpenHarmonyHapPayloadInLibsDeviceCompat=true, or unset"));
        Check("escape-hatch layout keeps the extension-less name", File.Exists(Path.Combine(plainDst, "createdump")));
        CheckEqual("escape-hatch layout keeps the 4096-byte size", 4096L, new FileInfo(Path.Combine(plainDst, "exact.dll")).Length);
        CheckEqual("escape-hatch layout does not rewrite", 0, plain.CompatRewrites);
        Check("escape hatch does not log the enabled status line", !plainEngine.HasMessageContaining("device compat: enabled"));

        string collideSrc = Harness.TempDir("payload-collide-src");
        Harness.WriteBytes(Path.Combine(collideSrc, "createdump"), Elf());
        Harness.WriteBytes(Path.Combine(collideSrc, "createdump.so"), Elf());
        var collide = new OpenHarmonyStagePayloadLibs
        {
            SourceDirectory = collideSrc,
            DestinationDirectory = Harness.TempDir("payload-collide-dst"),
            DeviceCompat = true,
        };
        var (collideOk, collideEngine) = Harness.Run(collide);
        Check("device compat name collision is an error", !collideOk);
        Check("device compat collision names the mapped name", collideEngine.HasErrorContaining("createdump.so"));
    }

    // ---------------------------------------------------------------- payload marker

    private static void WritePayloadMarkerTests()
    {
        string libs = Harness.TempDir("marker-libs");
        Harness.WriteFile(Path.Combine(libs, "app.dll"), "app");
        Harness.WriteFile(Path.Combine(libs, "runtimeconfig.json"), "{}");
        Harness.WriteFile(Path.Combine(libs, "sub", "satellite.dll"), "sat");
        Harness.WriteFile(Path.Combine(libs, ".dotnet-payload.json"), "stale");
        string zip = Path.Combine(Harness.TempDir("marker-zip"), "dotnet.zip");
        Harness.WriteBytes(zip, Encoding.ASCII.GetBytes("zip-bytes"));

        var task = new OpenHarmonyWritePayloadMarker
        {
            DestinationDirectory = libs,
            MarkerFileName = ".dotnet-payload.json",
            Assembly = "hello-maui-app.dll",
            PayloadEntries = 7,
            PayloadBytes = 1234,
            ZipEntries = 254,
            ZipFile = zip,
        };
        var (ok, _) = Harness.Run(task);
        Check("marker run succeeds", ok);
        CheckEqual("marker counts libs entries without the stale marker", 3, task.LibsEntries);
        CheckEqual("marker path output", Path.Combine(libs, ".dotnet-payload.json"), task.MarkerPath);
        string expected = "{\"schema\":1,\"assembly\":\"hello-maui-app.dll\",\"entries\":3,\"payloadEntries\":7,"
            + "\"payloadBytes\":1234,\"zipEntries\":254,\"zipSha256\":\"" + Sha256Hex(File.ReadAllBytes(zip)) + "\"}";
        CheckEqual("marker bytes are the documented schema", expected, File.ReadAllText(task.MarkerPath));
        CheckEqual("marker removed the stale content", expected.Length, new FileInfo(task.MarkerPath).Length);

        // Assembly names and paths are JSON-escaped; a missing zip leaves an empty sha.
        var escaped = new OpenHarmonyWritePayloadMarker
        {
            DestinationDirectory = Harness.TempDir("marker-escape"),
            MarkerFileName = ".dotnet-payload.json",
            Assembly = "a\"b\\c",
            ZipFile = Path.Combine(libs, "no-such.zip"),
        };
        var (escapeOk, _) = Harness.Run(escaped);
        Check("marker escaping run succeeds", escapeOk);
        string escapedJson = File.ReadAllText(escaped.MarkerPath);
        CheckEqual("marker escapes quotes and backslashes", "{\"schema\":1,\"assembly\":\"a\\\"b\\\\c\",\"entries\":0,\"payloadEntries\":0,\"payloadBytes\":0,\"zipEntries\":0,\"zipSha256\":\"\"}", escapedJson);
    }

    // ---------------------------------------------------------------- feature permissions

    private static ITaskItem Permission(string name, string feature, string reason, string when)
    {
        return Harness.Item(name, ("Feature", feature), ("GrantMode", "user_grant"), ("Reason", reason), ("UsedSceneWhen", when));
    }

    private static void ResolvePermissionsTests()
    {
        string shell = Harness.TempDir("perm-shell");
        string shellFile = Path.Combine(shell, "Index.ets");
        Harness.WriteFile(shellFile, "const P: string = 'ohos.permission.ACCESS_BLUETOOTH';\n// ohos.permission.NOT_A_REQUEST_POINT is prose\n");

        var bluetooth = Permission("ohos.permission.ACCESS_BLUETOOTH", "bluetooth", "$string:permission_reason_bluetooth", "inuse");
        var location = Permission("ohos.permission.APPROXIMATELY_LOCATION", "location", "$string:permission_reason_location", "always");

        OpenHarmonyResolvePermissions Resolver(ITaskItem[] table, string features, string extras = "", string optOut = "", bool strict = false)
        {
            return new OpenHarmonyResolvePermissions
            {
                FeatureTable = table,
                Features = features,
                ExtraPermissions = extras,
                ShellSources = new ITaskItem[] { Harness.Item(shellFile) },
                AbilityName = "EntryAbility",
                OptOut = optOut,
                RequireDeclaredRequestPoints = strict,
            };
        }

        // 1. A selected feature declares its permission with reason + usedScene.
        var selected = Resolver(new[] { bluetooth, location }, "bluetooth");
        var (selectedOk, _) = Harness.Run(selected);
        Check("permissions selected feature resolves", selectedOk);
        CheckEqual("permissions selected feature count", 1, selected.Permissions.Length);
        CheckEqual("permissions keeps the name", "ohos.permission.ACCESS_BLUETOOTH", selected.Permissions[0].ItemSpec);
        CheckEqual("permissions keeps the reason", "$string:permission_reason_bluetooth", selected.Permissions[0].GetMetadata("Reason"));
        CheckEqual("permissions fills the usedScene when", "inuse", selected.Permissions[0].GetMetadata("UsedSceneWhen"));
        CheckEqual("permissions fills the usedScene abilities", "EntryAbility", selected.Permissions[0].GetMetadata("UsedSceneAbilities"));
        CheckEqual("permissions scans the shell request points", "ohos.permission.ACCESS_BLUETOOTH", selected.RequestedPoints);
        CheckEqual("permissions has no undeclared points", "", selected.UndeclaredPoints);

        // 2. 'all' and ',' separators select every feature once.
        var all = Resolver(new[] { bluetooth, location }, "all");
        var (allOk, _) = Harness.Run(all);
        Check("permissions 'all' resolves", allOk);
        CheckEqual("permissions 'all' declares both", 2, all.Permissions.Length);
        var comma = Resolver(new[] { location }, "location,bluetooth");
        var (commaOk, _) = Harness.Run(comma);
        Check("permissions unknown id in a comma list fails", !commaOk);
        var dedupe = Resolver(new[] { bluetooth }, "bluetooth,bluetooth,bluetooth");
        var (dedupeOk, _) = Harness.Run(dedupe);
        Check("permissions duplicate feature ids collapse", dedupeOk && dedupe.Permissions.Length == 1);

        // 3. Unknown feature id names the known ids.
        var unknown = Resolver(new[] { bluetooth }, "bogus");
        var (unknownOk, unknownEngine) = Harness.Run(unknown);
        Check("permissions unknown feature fails", !unknownOk);
        Check("permissions unknown feature names the failure", unknownEngine.HasErrorContaining("unknown feature id"));
        Check("permissions unknown feature lists the known ids", unknownEngine.HasErrorContaining("bluetooth"));

        // 4. The table and its entries are validated.
        var empty = Resolver(Array.Empty<ITaskItem>(), "bluetooth");
        var (emptyOk, emptyEngine) = Harness.Run(empty);
        Check("permissions empty table fails", !emptyOk && emptyEngine.HasErrorContaining("the pack is corrupt"));
        var noFeature = new OpenHarmonyResolvePermissions
        {
            FeatureTable = new ITaskItem[] { Harness.Item("ohos.permission.X", ("Reason", "r"), ("UsedSceneWhen", "inuse")) },
            Features = "x",
            ShellSources = Array.Empty<ITaskItem>(),
        };
        var (noFeatureOk, noFeatureEngine) = Harness.Run(noFeature);
        Check("permissions entry without feature fails", !noFeatureOk && noFeatureEngine.HasErrorContaining("missing its permission name or feature id"));
        var noReason = Resolver(new[] { Permission("ohos.permission.ACCESS_BLUETOOTH", "bluetooth", "", "inuse") }, "bluetooth");
        var (noReasonOk, noReasonEngine) = Harness.Run(noReason);
        Check("permissions entry without reason fails", !noReasonOk && noReasonEngine.HasErrorContaining("has no reason resource"));
        var badWhen = Resolver(new[] { Permission("ohos.permission.ACCESS_BLUETOOTH", "bluetooth", "r", "never") }, "bluetooth");
        var (badWhenOk, badWhenEngine) = Harness.Run(badWhen);
        Check("permissions invalid usedScene when fails", !badWhenOk && badWhenEngine.HasErrorContaining("use 'inuse' or 'always'"));

        // 5. Request-point drift: a shell permission no feature declares is a hard error.
        string driftShell = Path.Combine(Harness.TempDir("perm-drift"), "Index.ets");
        Harness.WriteFile(driftShell, "'ohos.permission.CAMERA'");
        var drift = new OpenHarmonyResolvePermissions
        {
            FeatureTable = new[] { bluetooth },
            Features = "bluetooth",
            ShellSources = new ITaskItem[] { Harness.Item(driftShell) },
        };
        var (driftOk, driftEngine) = Harness.Run(drift);
        Check("permissions undecleared shell point fails", !driftOk);
        Check("permissions drift names the point", driftEngine.HasErrorContaining("the shell requests permission(s) no feature declares") && driftEngine.HasErrorContaining("ohos.permission.CAMERA"));

        // 6. An undeclared (but known) request point warns by default and fails in strict mode.
        var warning = Resolver(new[] { bluetooth, location }, "", strict: false);
        var (warningOk, warningEngine) = Harness.Run(warning);
        Check("permissions undeclared point warns by default", warningOk && warningEngine.HasWarningContaining("does not declare"));
        CheckEqual("permissions undeclared list is reported", "ohos.permission.ACCESS_BLUETOOTH", warning.UndeclaredPoints);
        var strict = Resolver(new[] { bluetooth, location }, "", strict: true);
        var (strictOk, strictEngine) = Harness.Run(strict);
        Check("permissions strict mode fails on an undeclared point", !strictOk && strictEngine.HasErrorContaining("does not declare"));

        // 7. Opt-out covers the request point in both scans.
        var optOut = Resolver(new[] { location }, "", optOut: "ohos.permission.ACCESS_BLUETOOTH", strict: true);
        var (optOutOk, _) = Harness.Run(optOut);
        Check("permissions opt-out keeps the build green", optOutOk);
        CheckEqual("permissions opt-out empties the undeclared list", "", optOut.UndeclaredPoints);

        // 8. Raw extras keep the minimal form and warn; a table-named extra inherits its metadata.
        var extras = Resolver(new[] { bluetooth }, "bluetooth", extras: "ohos.permission.CAMERA;ohos.permission.ACCESS_BLUETOOTH");
        var (extrasOk, extrasEngine) = Harness.Run(extras);
        Check("permissions raw extras resolve", extrasOk);
        CheckEqual("permissions raw extras count", 2, extras.Permissions.Length);
        Check("permissions raw extra warns", extrasEngine.HasWarningContaining("raw permission 'ohos.permission.CAMERA' has no feature-table entry"));
        CheckEqual("permissions raw extra keeps the minimal entry", "", extras.Permissions.Single(p => p.ItemSpec == "ohos.permission.CAMERA").GetMetadata("Reason"));
        CheckEqual("permissions table-named extra inherits the reason", "$string:permission_reason_bluetooth", extras.Permissions.Single(p => p.ItemSpec == "ohos.permission.ACCESS_BLUETOOTH").GetMetadata("Reason"));
    }

    // ---------------------------------------------------------------- module.json

    private static string TemplateDir(string label, string template)
    {
        string dir = Harness.TempDir(label);
        Harness.WriteFile(Path.Combine(dir, "module.json.template"), template);
        return Path.Combine(dir, "module.json.template");
    }

    private static OpenHarmonyGenerateModuleJson Generator(string templatePath, string outputPath, params ITaskItem[] replacements)
    {
        return new OpenHarmonyGenerateModuleJson
        {
            TemplateFile = templatePath,
            OutputFile = outputPath,
            Replacements = replacements,
        };
    }

    private static void GenerateModuleJsonTests()
    {
        // 1. Substitution in string and bare-literal context, with the documented trailing newline
        //    and the Changed flag.
        string templatePath = TemplateDir("json-golden",
            "{\"app\":{\"bundleName\":\"@BUNDLE_NAME@\",\"versionCode\":@VERSION_CODE@},\"module\":{\"name\":\"entry\"}}");
        string outDir = Harness.TempDir("json-golden-out");
        string output = Path.Combine(outDir, "nested", "module.json");
        var replacements = new[]
        {
            Harness.Item("BUNDLE_NAME", ("Value", "com.example.hellomauiapp")),
            Harness.Item("VERSION_CODE", ("Value", "1")),
        };
        var golden = Generator(templatePath, output, replacements);
        var (goldenOk, _) = Harness.Run(golden);
        Check("module.json substitution succeeds", goldenOk);
        CheckEqual("module.json output bytes", "{\"app\":{\"bundleName\":\"com.example.hellomauiapp\",\"versionCode\":1},\"module\":{\"name\":\"entry\"}}\n", File.ReadAllText(output));
        Check("module.json reports changed on the first write", golden.Changed);
        var rerun = Generator(templatePath, output, replacements);
        var (rerunOk, _) = Harness.Run(rerun);
        Check("module.json rerun succeeds", rerunOk);
        Check("module.json reports unchanged when bytes match", !rerun.Changed);
        Check("module.json creates the output directory", File.Exists(output));

        // 2. String values are JSON-escaped (quotes, backslashes, control characters).
        string escapeTemplate = TemplateDir("json-escape", "{\"app\":{\"bundleName\":\"@BUNDLE_NAME@\"},\"module\":{\"name\":\"entry\"}}");
        string escapeOutput = Path.Combine(Harness.TempDir("json-escape-out"), "module.json");
        var escape = Generator(escapeTemplate, escapeOutput,
            Harness.Item("BUNDLE_NAME", ("Value", "a\"b\\c\nd")));
        var (escapeOk, _) = Harness.Run(escape);
        Check("module.json escaping succeeds", escapeOk);
        using (var document = JsonDocument.Parse(File.ReadAllText(escapeOutput)))
        {
            CheckEqual("module.json escaped value round-trips", "a\"b\\c\nd", document.RootElement.GetProperty("app").GetProperty("bundleName").GetString());
        }

        // 3. A placeholder without a value, and a bare placeholder without a JSON literal, fail.
        string missingTemplate = TemplateDir("json-missing", "{\"app\":{\"bundleName\":\"@BUNDLE_NAME@\"}}");
        var missing = Generator(missingTemplate, Path.Combine(Harness.TempDir("json-missing-out"), "module.json"));
        var (missingOk, missingEngine) = Harness.Run(missing);
        Check("module.json missing placeholder fails", !missingOk && missingEngine.HasErrorContaining("no value was supplied"));
        var raw = Generator(TemplateDir("json-raw", "{\"app\":{\"versionCode\":@VERSION_CODE@}}"),
            Path.Combine(Harness.TempDir("json-raw-out"), "module.json"),
            Harness.Item("VERSION_CODE", ("Value", "one")));
        var (rawOk, rawEngine) = Harness.Run(raw);
        Check("module.json bare non-literal fails", !rawOk && rawEngine.HasErrorContaining("must be a JSON literal"));
        var duplicate = Generator(TemplateDir("json-dup", "{\"app\":{\"bundleName\":\"@BUNDLE_NAME@\"}}"),
            Path.Combine(Harness.TempDir("json-dup-out"), "module.json"),
            Harness.Item("BUNDLE_NAME", ("Value", "a")), Harness.Item("BUNDLE_NAME", ("Value", "b")));
        var (duplicateOk, duplicateEngine) = Harness.Run(duplicate);
        Check("module.json duplicate replacement fails", !duplicateOk && duplicateEngine.HasErrorContaining("duplicate replacement"));

        // 4. compileSdkVersion/compileSdkType are inserted after app.apiReleaseType.
        string sdkTemplate = TemplateDir("json-sdk",
            "{\"app\":{\"bundleName\":\"x\",\"apiReleaseType\":\"Release\"},\"module\":{\"name\":\"entry\"}}");
        string sdkOutput = Path.Combine(Harness.TempDir("json-sdk-out"), "module.json");
        var sdk = Generator(sdkTemplate, sdkOutput);
        sdk.CompileSdkVersion = "6.0.2.130";
        sdk.CompileSdkType = "HarmonyOS";
        var (sdkOk, _) = Harness.Run(sdk);
        Check("module.json compileSdk insertion succeeds", sdkOk);
        string sdkJson = File.ReadAllText(sdkOutput);
        Check("module.json compileSdk bytes", sdkJson.Contains("\"apiReleaseType\":\"Release\",\"compileSdkVersion\":\"6.0.2.130\",\"compileSdkType\":\"HarmonyOS\""));
        using (var document = JsonDocument.Parse(sdkJson))
        {
            CheckEqual("module.json compileSdk value", "6.0.2.130", document.RootElement.GetProperty("app").GetProperty("compileSdkVersion").GetString());
        }
        var noAnchor = Generator(TemplateDir("json-noanchor", "{\"app\":{\"bundleName\":\"x\"},\"module\":{\"name\":\"entry\"}}"),
            Path.Combine(Harness.TempDir("json-noanchor-out"), "module.json"));
        noAnchor.CompileSdkVersion = "6.0.2.130";
        var (noAnchorOk, noAnchorEngine) = Harness.Run(noAnchor);
        Check("module.json missing apiReleaseType anchor fails", !noAnchorOk && noAnchorEngine.HasErrorContaining("to anchor the insertion"));

        // 5. requestPermissions are inserted into the module object with reason and usedScene.
        string permTemplate = TemplateDir("json-perm",
            "{\"app\":{\"bundleName\":\"x\"},\"module\":{\"name\":\"entry\"}}");
        string permOutput = Path.Combine(Harness.TempDir("json-perm-out"), "module.json");
        var perm = Generator(permTemplate, permOutput);
        perm.ExtraPermissions = new[]
        {
            Harness.Item("ohos.permission.ACCESS_BLUETOOTH", ("Reason", "$string:permission_reason_bluetooth"), ("UsedSceneWhen", "inuse"), ("UsedSceneAbilities", "EntryAbility")),
            Harness.Item("ohos.permission.CAMERA"),
        };
        var (permOk, _) = Harness.Run(perm);
        Check("module.json permissions insertion succeeds", permOk);
        using (var document = JsonDocument.Parse(File.ReadAllText(permOutput)))
        {
            var permissions = document.RootElement.GetProperty("module").GetProperty("requestPermissions");
            CheckEqual("module.json permission count", 2, permissions.GetArrayLength());
            CheckEqual("module.json permission name", "ohos.permission.ACCESS_BLUETOOTH", permissions[0].GetProperty("name").GetString());
            CheckEqual("module.json permission reason", "$string:permission_reason_bluetooth", permissions[0].GetProperty("reason").GetString());
            CheckEqual("module.json permission usedScene when", "inuse", permissions[0].GetProperty("usedScene").GetProperty("when").GetString());
            CheckEqual("module.json permission usedScene abilities", "EntryAbility", permissions[0].GetProperty("usedScene").GetProperty("abilities")[0].GetString());
            CheckEqual("module.json raw permission stays minimal", 1, permissions[1].EnumerateObject().Count());
        }

        // 6. app links: OpenHarmonyAppLinkHosts appends the browsable/viewData skill with one
        //    https uri per host (trimmed and de-duplicated) and domainVerify from
        //    AppLinkDomainVerify; the home skill element stays the first element.
        string linkTemplate = TemplateDir("json-applink",
            "{\"app\":{\"bundleName\":\"x\"},\"module\":{\"name\":\"entry\",\"abilities\":[{\"name\":\"EntryAbility\",\"skills\":[{\"entities\":[\"entity.system.home\"],\"actions\":[\"action.system.home\"]}]}]}}");
        string linkOutput = Path.Combine(Harness.TempDir("json-applink-out"), "module.json");
        var link = Generator(linkTemplate, linkOutput);
        link.AppLinkHosts = "example.com; www.example.com ;example.com";
        link.AppLinkDomainVerify = "true";
        var (linkOk, linkEngine) = Harness.Run(link);
        Check("module.json app-link insertion succeeds", linkOk, linkEngine.Errors.FirstOrDefault());
        using (var document = JsonDocument.Parse(File.ReadAllText(linkOutput)))
        {
            var skills = document.RootElement.GetProperty("module").GetProperty("abilities")[0].GetProperty("skills");
            CheckEqual("module.json app link keeps the home skill", "entity.system.home", skills[0].GetProperty("entities")[0].GetString());
            CheckEqual("module.json app link appends one skill element", 2, skills.GetArrayLength());
            var uris = skills[1].GetProperty("uris");
            CheckEqual("module.json app link uri count (trimmed/deduped)", 2, uris.GetArrayLength());
            CheckEqual("module.json app link scheme", "https", uris[0].GetProperty("scheme").GetString());
            CheckEqual("module.json app link host order", "example.com|www.example.com", string.Join("|", uris.EnumerateArray().Select(u => u.GetProperty("host").GetString())));
            CheckEqual("module.json app link entity", "entity.system.browsable", skills[1].GetProperty("entities")[0].GetString());
            CheckEqual("module.json app link action", "ohos.want.action.viewData", skills[1].GetProperty("actions")[0].GetString());
            Check("module.json app link domainVerify is true", skills[1].GetProperty("domainVerify").GetBoolean());
        }

        //    domainVerify=false omits the member (the pre-registration form) and an empty skills
        //    array still gets exactly one element.
        string noVerifyTemplate = TemplateDir("json-applink-noverify",
            "{\"app\":{\"bundleName\":\"x\"},\"module\":{\"name\":\"entry\",\"abilities\":[{\"skills\":[]}]}}");
        string noVerifyOutput = Path.Combine(Harness.TempDir("json-applink-noverify-out"), "module.json");
        var noVerify = Generator(noVerifyTemplate, noVerifyOutput);
        noVerify.AppLinkHosts = "example.com";
        noVerify.AppLinkDomainVerify = "false";
        var (noVerifyOk, _) = Harness.Run(noVerify);
        Check("module.json app link with an empty skills array succeeds", noVerifyOk);
        using (var document = JsonDocument.Parse(File.ReadAllText(noVerifyOutput)))
        {
            var skills = document.RootElement.GetProperty("module").GetProperty("abilities")[0].GetProperty("skills");
            CheckEqual("module.json app link empty skills gets one element", 1, skills.GetArrayLength());
            Check("module.json app link domainVerify omitted when off", !skills[0].TryGetProperty("domainVerify", out _));
        }

        //    Invalid and empty host lists fail, and a template without the skills anchor fails.
        var badHost = Generator(linkTemplate, Path.Combine(Harness.TempDir("json-applink-badhost-out"), "module.json"));
        badHost.AppLinkHosts = "exa mple.com";
        var (badHostOk, badHostEngine) = Harness.Run(badHost);
        Check("module.json app link invalid host fails", !badHostOk && badHostEngine.HasErrorContaining("is not a host name"));
        var noHost = Generator(linkTemplate, Path.Combine(Harness.TempDir("json-applink-nohost-out"), "module.json"));
        noHost.AppLinkHosts = ";;";
        var (noHostOk, noHostEngine) = Harness.Run(noHost);
        Check("module.json app link empty host list fails", !noHostOk && noHostEngine.HasErrorContaining("carries no host"));
        var noSkills = Generator(TemplateDir("json-applink-noskills", "{\"app\":{\"bundleName\":\"x\"},\"module\":{\"name\":\"entry\"}}"),
            Path.Combine(Harness.TempDir("json-applink-noskills-out"), "module.json"));
        noSkills.AppLinkHosts = "example.com";
        var (noSkillsOk, noSkillsEngine) = Harness.Run(noSkills);
        Check("module.json app link missing skills anchor fails", !noSkillsOk && noSkillsEngine.HasErrorContaining("needs a module.abilities[0].skills array"));

        // 6b. WebAuthenticator callback routes: WebAuthenticatorCallbackUrls appends one
        //     browsable/viewData skill element with one uri per route - a full URL contributes
        //     scheme + host (+ an explicit port), a bare scheme a scheme-only uri - trimmed and
        //     de-duplicated, the home skill staying first.
        string waTemplate = TemplateDir("json-webauth",
            "{\"app\":{\"bundleName\":\"x\"},\"module\":{\"name\":\"entry\",\"abilities\":[{\"name\":\"EntryAbility\",\"skills\":[{\"entities\":[\"entity.system.home\"],\"actions\":[\"action.system.home\"]}]}]}}");
        string waOutput = Path.Combine(Harness.TempDir("json-webauth-out"), "module.json");
        var wa = Generator(waTemplate, waOutput);
        wa.WebAuthenticatorCallbackUrls = "myapp://callback; Otherapp ;myapp://callback;custom://cb:8443";
        var (waOk, waEngine) = Harness.Run(wa);
        Check("module.json webauth callback insertion succeeds", waOk, waEngine.Errors.FirstOrDefault());
        using (var document = JsonDocument.Parse(File.ReadAllText(waOutput)))
        {
            var skills = document.RootElement.GetProperty("module").GetProperty("abilities")[0].GetProperty("skills");
            CheckEqual("module.json webauth keeps the home skill", "entity.system.home", skills[0].GetProperty("entities")[0].GetString());
            CheckEqual("module.json webauth appends one skill element", 2, skills.GetArrayLength());
            CheckEqual("module.json webauth entity", "entity.system.browsable", skills[1].GetProperty("entities")[0].GetString());
            CheckEqual("module.json webauth action", "ohos.want.action.viewData", skills[1].GetProperty("actions")[0].GetString());
            var uris = skills[1].GetProperty("uris");
            CheckEqual("module.json webauth uri count (trimmed/deduped, bare scheme kept)", 3, uris.GetArrayLength());
            CheckEqual("module.json webauth url route scheme", "myapp", uris[0].GetProperty("scheme").GetString());
            CheckEqual("module.json webauth url route host", "callback", uris[0].GetProperty("host").GetString());
            Check("module.json webauth url route omits the default port", !uris[0].TryGetProperty("port", out _));
            CheckEqual("module.json webauth bare route scheme only", "otherapp", uris[1].GetProperty("scheme").GetString().ToLowerInvariant());
            Check("module.json webauth bare route omits the host", !uris[1].TryGetProperty("host", out _));
            CheckEqual("module.json webauth explicit port", 8443, uris[2].GetProperty("port").GetInt32());
        }

        //     App links and callback routes together share one insertion at the skills bracket,
        //     so the generated bytes stay deterministic (two same-offset edits would not be
        //     order-stable); the app-link uri keeps its domainVerify in the same element.
        string combinedTemplate = TemplateDir("json-applink-webauth",
            "{\"app\":{\"bundleName\":\"x\"},\"module\":{\"name\":\"entry\",\"abilities\":[{\"skills\":[]}]}}");
        string combinedOutput1 = Path.Combine(Harness.TempDir("json-applink-webauth-out1"), "module.json");
        string combinedOutput2 = Path.Combine(Harness.TempDir("json-applink-webauth-out2"), "module.json");
        foreach (string combinedOutput in new[] { combinedOutput1, combinedOutput2 })
        {
            var combined = Generator(combinedTemplate, combinedOutput);
            combined.AppLinkHosts = "example.com";
            combined.AppLinkDomainVerify = "true";
            combined.WebAuthenticatorCallbackUrls = "myapp://callback";
            var (combinedOk, combinedEngine) = Harness.Run(combined);
            Check($"module.json app-link + webauth insertion succeeds ({Path.GetFileName(Path.GetDirectoryName(combinedOutput)!)})", combinedOk, combinedEngine.Errors.FirstOrDefault());
        }
        CheckEqual("module.json app-link + webauth bytes are deterministic", File.ReadAllText(combinedOutput1), File.ReadAllText(combinedOutput2));
        using (var document = JsonDocument.Parse(File.ReadAllText(combinedOutput1)))
        {
            var skills = document.RootElement.GetProperty("module").GetProperty("abilities")[0].GetProperty("skills");
            CheckEqual("module.json app-link + webauth element count", 2, skills.GetArrayLength());
            CheckEqual("module.json app-link keeps domainVerify next to the callback skill", "https", skills[0].GetProperty("uris")[0].GetProperty("scheme").GetString());
            Check("module.json app-link element keeps domainVerify true", skills[0].GetProperty("domainVerify").GetBoolean());
            CheckEqual("module.json callback element follows", "myapp", skills[1].GetProperty("uris")[0].GetProperty("scheme").GetString());
        }

        //     Invalid routes, an empty list and a template without the skills anchor all fail.
        var waBadRoute = Generator(waTemplate, Path.Combine(Harness.TempDir("json-webauth-badroute-out"), "module.json"));
        waBadRoute.WebAuthenticatorCallbackUrls = "exa mple";
        var (waBadRouteOk, waBadRouteEngine) = Harness.Run(waBadRoute);
        Check("module.json webauth invalid route fails", !waBadRouteOk && waBadRouteEngine.HasErrorContaining("is not a callback route"));
        var waBadHost = Generator(waTemplate, Path.Combine(Harness.TempDir("json-webauth-badhost-out"), "module.json"));
        waBadHost.WebAuthenticatorCallbackUrls = "myapp://[::1]";
        var (waBadHostOk, waBadHostEngine) = Harness.Run(waBadHost);
        Check("module.json webauth invalid host fails", !waBadHostOk && waBadHostEngine.HasErrorContaining("has an invalid host"));
        var waNoRoute = Generator(waTemplate, Path.Combine(Harness.TempDir("json-webauth-noroute-out"), "module.json"));
        waNoRoute.WebAuthenticatorCallbackUrls = ";;";
        var (waNoRouteOk, waNoRouteEngine) = Harness.Run(waNoRoute);
        Check("module.json webauth empty list fails", !waNoRouteOk && waNoRouteEngine.HasErrorContaining("carries no route"));
        var waNoSkills = Generator(TemplateDir("json-webauth-noskills", "{\"app\":{\"bundleName\":\"x\"},\"module\":{\"name\":\"entry\"}}"),
            Path.Combine(Harness.TempDir("json-webauth-noskills-out"), "module.json"));
        waNoSkills.WebAuthenticatorCallbackUrls = "myapp://callback";
        var (waNoSkillsOk, waNoSkillsEngine) = Harness.Run(waNoSkills);
        Check("module.json webauth missing skills anchor fails", !waNoSkillsOk && waNoSkillsEngine.HasErrorContaining("needs a module.abilities[0].skills array"));

        // 7. A malformed template and a missing template both fail with the documented messages.
        string badTemplate = TemplateDir("json-bad", "{\"app\":{\"bundleName\"\"x\"},\"module\":{}}");
        var bad = Generator(badTemplate, Path.Combine(Harness.TempDir("json-bad-out"), "module.json"));
        var (badOk, badEngine) = Harness.Run(bad);
        Check("module.json malformed template fails", !badOk && badEngine.HasErrorContaining("not valid JSON"));
        var noTemplate = Generator(Path.Combine(Harness.TempDir("json-notemplate"), "module.json.template"),
            Path.Combine(Harness.TempDir("json-notemplate-out"), "module.json"));
        var (noTemplateOk, noTemplateEngine) = Harness.Run(noTemplate);
        Check("module.json missing template fails", !noTemplateOk && noTemplateEngine.HasErrorContaining("template not found"));
    }

    // ---------------------------------------------------------------- embedded resource

    private static void ExtractEmbeddedResourceTests()
    {
        // 1. The extractor reads the test host's own assembly (a stand-in for Microsoft.Maui.dll)
        //    and writes the embedded resource bytes, creating the destination directory.
        string fixtureDir = Harness.TempDir("extract");
        string fixtureAssembly = Path.Combine(fixtureDir, "fixture.dll");
        File.Copy(typeof(Program).Assembly.Location, fixtureAssembly);
        string destination = Path.Combine(Harness.TempDir("extract-out"), "nested", "_framework", "hybridwebview.js");
        var extract = new OpenHarmonyExtractEmbeddedResource
        {
            AssemblyPath = fixtureAssembly,
            ResourceName = "OpenHarmonyTasksTests.fixture-resource.txt",
            DestinationFile = destination,
        };
        var (extractOk, extractEngine) = Harness.Run(extract);
        Check("extract embedded resource succeeds", extractOk && extract.Extracted && extractEngine.Errors.Count == 0);
        Check("extract embedded resource creates the destination directory", File.Exists(destination));
        CheckEqual("extract embedded resource round-trips the bytes",
            "OpenHarmony task fixture resource.\n", File.ReadAllText(destination));

        // 2. A second run over the same destination is a no-op: the byte comparison keeps the
        //    publish output (and the deterministic payload zip) stable across builds.
        var rerun = new OpenHarmonyExtractEmbeddedResource
        {
            AssemblyPath = fixtureAssembly,
            ResourceName = "OpenHarmonyTasksTests.fixture-resource.txt",
            DestinationFile = destination,
        };
        var (rerunOk, _) = Harness.Run(rerun);
        Check("extract embedded resource is idempotent", rerunOk && !rerun.Extracted);

        // 3. A resource the assembly does not carry warns but succeeds: HybridWebView is
        //    optional and the runtime extraction remains the fallback.
        var missing = new OpenHarmonyExtractEmbeddedResource
        {
            AssemblyPath = fixtureAssembly,
            ResourceName = "OpenHarmonyTasksTests.does-not-exist.js",
            DestinationFile = Path.Combine(fixtureDir, "missing.js"),
        };
        var (missingOk, missingEngine) = Harness.Run(missing);
        Check("extract embedded resource warns for a missing resource",
            missingOk && !missing.Extracted && missingEngine.Errors.Count == 0 &&
            missingEngine.HasWarningContaining("no embedded resource"));
        Check("extract embedded resource does not create a file for a missing resource", !File.Exists(Path.Combine(fixtureDir, "missing.js")));

        // 4. A missing assembly is a build error naming the path (the target only invokes the
        //    task for an existing reference, so this is a genuine broken input).
        var badAssembly = new OpenHarmonyExtractEmbeddedResource
        {
            AssemblyPath = Path.Combine(fixtureDir, "not-there.dll"),
            ResourceName = "x",
            DestinationFile = Path.Combine(fixtureDir, "x.js"),
        };
        var (badOk, badEngine) = Harness.Run(badAssembly);
        Check("extract embedded resource fails for a missing assembly",
            !badOk && badEngine.HasErrorContaining("assembly not found"));

        // 5. A non-assembly file fails with the load error instead of writing anything.
        string notAssembly = Path.Combine(fixtureDir, "not-an-assembly.dll");
        File.WriteAllText(notAssembly, "not a PE file");
        var badImage = new OpenHarmonyExtractEmbeddedResource
        {
            AssemblyPath = notAssembly,
            ResourceName = "x",
            DestinationFile = Path.Combine(fixtureDir, "bad.dll"),
        };
        var (badImageOk, badImageEngine) = Harness.Run(badImage);
        Check("extract embedded resource fails for a non-assembly file",
            !badImageOk && badImageEngine.HasErrorContaining("cannot read") && !File.Exists(Path.Combine(fixtureDir, "bad.dll")));
    }
}
