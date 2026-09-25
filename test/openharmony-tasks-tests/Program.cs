// Unit tests for the six compiled hap-packaging tasks. Every check runs the real task class with a
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

        // 6. A malformed template and a missing template both fail with the documented messages.
        string badTemplate = TemplateDir("json-bad", "{\"app\":{\"bundleName\"\"x\"},\"module\":{}}");
        var bad = Generator(badTemplate, Path.Combine(Harness.TempDir("json-bad-out"), "module.json"));
        var (badOk, badEngine) = Harness.Run(bad);
        Check("module.json malformed template fails", !badOk && badEngine.HasErrorContaining("not valid JSON"));
        var noTemplate = Generator(Path.Combine(Harness.TempDir("json-notemplate"), "module.json.template"),
            Path.Combine(Harness.TempDir("json-notemplate-out"), "module.json"));
        var (noTemplateOk, noTemplateEngine) = Harness.Run(noTemplate);
        Check("module.json missing template fails", !noTemplateOk && noTemplateEngine.HasErrorContaining("template not found"));
    }
}
