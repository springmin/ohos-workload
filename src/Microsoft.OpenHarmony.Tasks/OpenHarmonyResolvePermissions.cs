// Migrated from the inline RoslynCodeTaskFactory task 'OpenHarmonyResolvePermissions' in OpenHarmony.Hap.targets.
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
using System.Linq;
using System.Text.RegularExpressions;
using Microsoft.Build.Framework;
using Microsoft.Build.Utilities;

public class OpenHarmonyResolvePermissions : Task
{
    // A quoted permission literal in the shell sources is a request point (the shell only ever
    // names a permission in code as a quoted literal; prose mentions are unquoted and ignored).
    private static readonly Regex RequestPoint = new Regex("['\"](ohos\\.permission\\.[A-Za-z0-9_]+)['\"]", RegexOptions.Compiled);

    [Required] public ITaskItem[] FeatureTable { get; set; }
    public string Features { get; set; }
    public string ExtraPermissions { get; set; }
    public ITaskItem[] ShellSources { get; set; }
    public string AbilityName { get; set; }
    public string OptOut { get; set; }
    public bool RequireDeclaredRequestPoints { get; set; }
    [Output] public ITaskItem[] Permissions { get; set; }
    [Output] public string RequestedPoints { get; set; }
    [Output] public string UndeclaredPoints { get; set; }

    private sealed class Entry
    {
        public string Name;
        public string Feature;
        public string GrantMode;
        public string Reason;
        public string When;
    }

    public override bool Execute()
    {
        var table = new List<Entry>();
        foreach (var item in FeatureTable)
        {
            var entry = new Entry
            {
                Name = (item.ItemSpec ?? "").Trim(),
                Feature = (item.GetMetadata("Feature") ?? "").Trim(),
                GrantMode = (item.GetMetadata("GrantMode") ?? "").Trim(),
                Reason = (item.GetMetadata("Reason") ?? "").Trim(),
                When = (item.GetMetadata("UsedSceneWhen") ?? "").Trim(),
            };
            if (entry.Name.Length == 0 || entry.Feature.Length == 0)
            {
                Log.LogError("OpenHarmony permissions: a feature-table entry is missing its permission name or feature id");
                return false;
            }
            table.Add(entry);
        }
        if (table.Count == 0)
        {
            Log.LogError("OpenHarmony permissions: the feature table is empty; the pack is corrupt");
            return false;
        }

        var known = new HashSet<string>(table.Select(e => e.Feature), StringComparer.Ordinal);
        var selected = Split(Features);
        var unknown = selected.Where(s => s != "all" && !known.Contains(s)).Distinct().ToList();
        if (unknown.Count > 0)
        {
            Log.LogError("OpenHarmony features: unknown feature id(s) '{0}'; known ids: {1} (use 'all' for every feature)",
                string.Join(";", unknown), string.Join(";", known.OrderBy(f => f, StringComparer.Ordinal)));
            return false;
        }
        if (selected.Contains("all"))
        {
            selected = known.ToList();
        }

        var optOut = new HashSet<string>(Split(OptOut), StringComparer.Ordinal);

        // Declaration set: selected features first (table order), then raw extras that are not
        // already covered. A raw extra that names a table permission inherits its metadata.
        var declared = new List<Entry>();
        var declaredNames = new HashSet<string>(StringComparer.Ordinal);
        foreach (var feature in selected)
        {
            foreach (var entry in table.Where(e => e.Feature == feature))
            {
                if (entry.Reason.Length == 0)
                {
                    Log.LogError("OpenHarmony permissions: feature '{0}' permission '{1}' has no reason resource; every declared user_grant permission needs one (see the feature table)",
                        feature, entry.Name);
                    return false;
                }
                if (entry.When != "inuse" && entry.When != "always")
                {
                    Log.LogError("OpenHarmony permissions: feature '{0}' permission '{1}' has usedScene when='{2}'; use 'inuse' or 'always'",
                        feature, entry.Name, entry.When);
                    return false;
                }
                if (declaredNames.Add(entry.Name))
                {
                    declared.Add(entry);
                }
            }
        }
        foreach (var name in Split(ExtraPermissions))
        {
            if (!declaredNames.Add(name))
            {
                continue;
            }
            var knownEntry = table.FirstOrDefault(e => e.Name == name);
            if (knownEntry != null)
            {
                declared.Add(knownEntry);
            }
            else
            {
                // Raw escape hatch: the module.json entry keeps the historical minimal form, but
                // it is flagged because a user_grant permission declared without a reason can be
                // ignored by the platform.
                Log.LogWarning("OpenHarmony permissions: raw permission '{0}' has no feature-table entry, so its module.json entry carries no reason/usedScene; prefer OpenHarmonyFeatures", name);
                declared.Add(new Entry { Name = name, Reason = "", When = "" });
            }
        }

        // Request-point scan over the shell sources (the shipped template by default).
        var requested = new SortedSet<string>(StringComparer.Ordinal);
        long scanned = 0;
        if (ShellSources != null)
        {
            foreach (var source in ShellSources)
            {
                var path = source.ItemSpec;
                if (string.IsNullOrEmpty(path) || !File.Exists(path))
                {
                    continue;
                }
                scanned++;
                foreach (Match match in RequestPoint.Matches(File.ReadAllText(path)))
                {
                    requested.Add(match.Groups[1].Value);
                }
            }
        }
        RequestedPoints = string.Join(";", requested);
        Log.LogMessage(MessageImportance.Low, "OpenHarmony permissions: scanned {0} shell source file(s), request points: {1}", scanned, RequestedPoints);

        // The request-point manifest must stay covered by the feature table: a permission the
        // shell requests that no feature declares is a matrix drift and fails the build.
        var uncovered = requested.Where(p => !table.Any(e => e.Name == p) && !optOut.Contains(p)).ToList();
        if (uncovered.Count > 0)
        {
            Log.LogError("OpenHarmony permissions: the shell requests permission(s) no feature declares: {0}. Add the permission to the _OpenHarmonyFeaturePermission table (or to OpenHarmonyPermissionsOptOut with a documented reason); the request-point manifest and the declaration set must stay in sync.",
                string.Join(";", uncovered));
            return false;
        }

        // Undeclared request points: the app has not enabled the matching feature. Strict mode
        // fails the build; the default warns and names the feature to enable.
        var undeclared = requested.Where(p => !declaredNames.Contains(p) && !optOut.Contains(p)).ToList();
        UndeclaredPoints = string.Join(";", undeclared);
        bool ok = true;
        if (undeclared.Count > 0)
        {
            var message = string.Format(
                "OpenHarmony permissions: the shipped shell can request permission(s) the app does not declare: {0}. Enable the matching feature with -p:OpenHarmonyFeatures=<feature> (see the feature matrix in docs/openharmony-hap-packaging.md) or list the permission in OpenHarmonyPermissionsOptOut when the app never exercises it. An undeclared request answers 'unavailable' at runtime.",
                string.Join(";", undeclared));
            if (RequireDeclaredRequestPoints)
            {
                Log.LogError(message);
                ok = false;
            }
            else
            {
                Log.LogWarning(message);
            }
        }

        Permissions = declared.Select(d =>
        {
            var item = new TaskItem(d.Name);
            if (!string.IsNullOrEmpty(d.Reason))
            {
                item.SetMetadata("Reason", d.Reason);
            }
            if (!string.IsNullOrEmpty(d.When))
            {
                item.SetMetadata("UsedSceneWhen", d.When);
                if (!string.IsNullOrEmpty(AbilityName))
                {
                    item.SetMetadata("UsedSceneAbilities", AbilityName);
                }
            }
            return item;
        }).ToArray();
        Log.LogMessage(MessageImportance.Low, "OpenHarmony permissions: declared {0} permission(s) for features '{1}'", Permissions.Length, string.Join(";", selected));
        return ok && !Log.HasLoggedErrors;
    }

    private static List<string> Split(string value)
    {
        var result = new List<string>();
        if (string.IsNullOrEmpty(value))
        {
            return result;
        }
        foreach (var part in value.Replace(',', ';').Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var trimmed = part.Trim();
            if (trimmed.Length > 0)
            {
                result.Add(trimmed);
            }
        }
        return result;
    }
}

