// Minimal harness for the task unit tests: an IBuildEngine that records everything the task
// logs, a temp directory per test, and helpers to build MSBuild items.
using Microsoft.Build.Framework;
using Microsoft.Build.Utilities;

namespace OpenHarmonyTasksTests;

internal sealed class StubBuildEngine : IBuildEngine
{
    public List<string> Errors { get; } = new();
    public List<string> Warnings { get; } = new();
    public List<string> Messages { get; } = new();

    public bool ContinueOnError => false;
    public int LineNumberOfTaskNode => 0;
    public int ColumnNumberOfTaskNode => 0;
    public string ProjectFileOfTaskNode => "unit-tests.proj";

    public bool BuildProjectFile(string projectFileName, string[] targetNames, System.Collections.IDictionary globalProperties, System.Collections.IDictionary targetOutputs) => false;
    public void LogCustomEvent(CustomBuildEventArgs e) { }
    public void LogErrorEvent(BuildErrorEventArgs e) => Errors.Add(e.Message ?? "");
    public void LogWarningEvent(BuildWarningEventArgs e) => Warnings.Add(e.Message ?? "");
    public void LogMessageEvent(BuildMessageEventArgs e) => Messages.Add(e.Message ?? "");

    public bool HasErrorContaining(string fragment) => Errors.Any(e => e.Contains(fragment, StringComparison.Ordinal));
    public bool HasWarningContaining(string fragment) => Warnings.Any(e => e.Contains(fragment, StringComparison.Ordinal));
    public bool HasMessageContaining(string fragment) => Messages.Any(e => e.Contains(fragment, StringComparison.Ordinal));
}

internal static class Harness
{
    public static (bool ok, StubBuildEngine engine) Run(Microsoft.Build.Utilities.Task task)
    {
        var engine = new StubBuildEngine();
        task.BuildEngine = engine;
        bool ok = task.Execute();
        return (ok, engine);
    }

    public static TaskItem Item(string spec)
    {
        return new TaskItem(spec);
    }

    public static TaskItem Item(string spec, params (string name, string value)[] metadata)
    {
        var item = new TaskItem(spec);
        foreach (var (name, value) in metadata)
        {
            item.SetMetadata(name, value);
        }
        return item;
    }

    public static string TempDir(string label)
    {
        string dir = Path.Combine(Path.GetTempPath(), "ohos-tasks-tests", label + "-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        return dir;
    }

    public static void WriteFile(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text);
    }

    public static void WriteBytes(string path, byte[] bytes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, bytes);
    }
}
