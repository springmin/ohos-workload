// Migrated from the inline RoslynCodeTaskFactory task 'OpenHarmonyGenerateModuleJson' in OpenHarmony.Hap.targets.
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
using System.Text;
using Microsoft.Build.Framework;
using Microsoft.Build.Utilities;

public class OpenHarmonyGenerateModuleJson : Task
{
    [Required] public string TemplateFile { get; set; }
    [Required] public string OutputFile { get; set; }
    public ITaskItem[] Replacements { get; set; }
    public string CompileSdkVersion { get; set; }
    public string CompileSdkType { get; set; }
    public ITaskItem[] ExtraPermissions { get; set; }
    [Output] public bool Changed { get; set; }

    private sealed class JsonNode
    {
        public int Start;
        public int End;
        public List<JsonMember> Members;   // objects only
    }

    private sealed class JsonMember
    {
        public string Key;
        public JsonNode Value;
        public bool HasComma;
        public int CommaIndex = -1;
    }

    private sealed class Edit
    {
        public int Start;
        public int End;
        public string Text;
    }

    public override bool Execute()
    {
        if (string.IsNullOrEmpty(TemplateFile) || !File.Exists(TemplateFile))
        {
            Log.LogError("OpenHarmony module.json: template not found: '{0}'", TemplateFile);
            return false;
        }

        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        if (Replacements != null)
        {
            foreach (var item in Replacements)
            {
                var key = (item.ItemSpec ?? "").Trim().Trim('@');
                if (key.Length == 0)
                {
                    Log.LogError("OpenHarmony module.json: a replacement has an empty placeholder name");
                    return false;
                }
                if (values.ContainsKey(key))
                {
                    Log.LogError("OpenHarmony module.json: duplicate replacement for '@{0}@'", key);
                    return false;
                }
                values[key] = item.GetMetadata("Value") ?? "";
            }
        }

        // The old contract read the template line-by-line and joined the lines (which required a
        // single-line file); the task accepts any formatting and normalizes only the trailing
        // newline, matching the previous output bytes.
        string template = File.ReadAllText(TemplateFile).TrimEnd('\r', '\n');
        var output = new StringBuilder(template.Length + 256);
        var used = new HashSet<string>(StringComparer.Ordinal);
        int i = 0;
        bool inString = false;
        bool escaped = false;
        while (i < template.Length)
        {
            char c = template[i];
            if (inString)
            {
                if (escaped) { escaped = false; output.Append(c); i++; continue; }
                if (c == '\\') { escaped = true; output.Append(c); i++; continue; }
                if (c == '"') { inString = false; output.Append(c); i++; continue; }
                if (c == '@')
                {
                    int end = PlaceholderEnd(template, i);
                    if (end > i)
                    {
                        string key = template.Substring(i + 1, end - i - 1);
                        if (!values.ContainsKey(key))
                        {
                            Log.LogError("OpenHarmony module.json: the template carries '@{0}@' but no value was supplied", key);
                            return false;
                        }
                        output.Append(EscapeJsonString(values[key]));
                        used.Add(key);
                        i = end + 1;
                        continue;
                    }
                }
                output.Append(c);
                i++;
                continue;
            }

            if (c == '"') { inString = true; output.Append(c); i++; continue; }
            if (c == '@')
            {
                int end = PlaceholderEnd(template, i);
                if (end > i)
                {
                    string key = template.Substring(i + 1, end - i - 1);
                    if (!values.ContainsKey(key))
                    {
                        Log.LogError("OpenHarmony module.json: the template carries '@{0}@' but no value was supplied", key);
                        return false;
                    }
                    string raw = values[key];
                    if (!IsJsonLiteral(raw))
                    {
                        Log.LogError("OpenHarmony module.json: '@{0}@' is outside a JSON string, so its value must be a JSON literal (number, true, false or null); got '{1}'", key, raw);
                        return false;
                    }
                    output.Append(raw);
                    used.Add(key);
                    i = end + 1;
                    continue;
                }
            }
            output.Append(c);
            i++;
        }

        string json = output.ToString();
        JsonNode root;
        try
        {
            int pos = 0;
            root = ParseValue(json, ref pos);
            SkipWhitespace(json, ref pos);
            if (pos != json.Length)
            {
                throw new FormatException("trailing characters after the root value");
            }
        }
        catch (FormatException exc)
        {
            Log.LogError("OpenHarmony module.json: the generated document is not valid JSON: {0}", exc.Message);
            return false;
        }

        var edits = new List<Edit>();
        JsonNode app = FindMember(root, "app");
        JsonNode module = FindMember(root, "module");
        if (app == null)
        {
            Log.LogError("OpenHarmony module.json: the template has no 'app' object");
            return false;
        }
        if (module == null)
        {
            Log.LogError("OpenHarmony module.json: the template has no 'module' object");
            return false;
        }

        if (!string.IsNullOrEmpty(CompileSdkVersion) || !string.IsNullOrEmpty(CompileSdkType))
        {
            var apiRelease = FindJsonMember(app, "apiReleaseType");
            if (apiRelease == null)
            {
                Log.LogError("OpenHarmony module.json: compileSdkVersion/compileSdkType need an 'app.apiReleaseType' member to anchor the insertion");
                return false;
            }
            var fragment = new StringBuilder();
            if (!string.IsNullOrEmpty(CompileSdkVersion))
            {
                fragment.Append("\"compileSdkVersion\":\"").Append(EscapeJsonString(CompileSdkVersion)).Append("\",");
            }
            if (!string.IsNullOrEmpty(CompileSdkType))
            {
                fragment.Append("\"compileSdkType\":\"").Append(EscapeJsonString(CompileSdkType)).Append("\",");
            }
            string text = fragment.ToString();
            int at;
            if (apiRelease.HasComma)
            {
                at = apiRelease.CommaIndex + 1;   // after the member's comma
            }
            else
            {
                at = apiRelease.Value.End;
                text = "," + text.TrimEnd(',');
            }
            edits.Add(new Edit { Start = at, End = at, Text = text });
        }

        if (ExtraPermissions != null && ExtraPermissions.Length > 0)
        {
            var fragment = new StringBuilder(",\"requestPermissions\":[");
            for (int n = 0; n < ExtraPermissions.Length; n++)
            {
                if (n > 0)
                {
                    fragment.Append(',');
                }
                var permissionName = ExtraPermissions[n].ItemSpec;
                fragment.Append("{\"name\":\"").Append(EscapeJsonString(permissionName)).Append('"');
                var reason = (ExtraPermissions[n].GetMetadata("Reason") ?? "").Trim();
                if (reason.Length > 0)
                {
                    fragment.Append(",\"reason\":\"").Append(EscapeJsonString(reason)).Append('"');
                }
                var when = (ExtraPermissions[n].GetMetadata("UsedSceneWhen") ?? "").Trim();
                var abilities = (ExtraPermissions[n].GetMetadata("UsedSceneAbilities") ?? "").Trim();
                if (when.Length > 0 || abilities.Length > 0)
                {
                    fragment.Append(",\"usedScene\":{");
                    bool wroteMember = false;
                    if (abilities.Length > 0)
                    {
                        fragment.Append("\"abilities\":[");
                        var names = abilities.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries);
                        for (int a = 0; a < names.Length; a++)
                        {
                            if (a > 0)
                            {
                                fragment.Append(',');
                            }
                            fragment.Append('"').Append(EscapeJsonString(names[a].Trim())).Append('"');
                        }
                        fragment.Append(']');
                        wroteMember = true;
                    }
                    if (when.Length > 0)
                    {
                        if (wroteMember)
                        {
                            fragment.Append(',');
                        }
                        fragment.Append("\"when\":\"").Append(EscapeJsonString(when)).Append('"');
                    }
                    fragment.Append('}');
                }
                fragment.Append('}');
            }
            fragment.Append(']');
            int at = module.End - 1;   // before the module object's closing brace
            edits.Add(new Edit { Start = at, End = at, Text = fragment.ToString() });
        }

        if (edits.Count > 0)
        {
            edits.Sort(delegate (Edit a, Edit b) { return b.Start.CompareTo(a.Start); });
            for (int n = 0; n < edits.Count; n++)
            {
                var edit = edits[n];
                if (edit.Start < 0 || edit.End > json.Length || edit.Start > edit.End)
                {
                    Log.LogError("OpenHarmony module.json: internal edit out of range");
                    return false;
                }
                if (n > 0 && edit.End > edits[n - 1].Start)
                {
                    Log.LogError("OpenHarmony module.json: overlapping edits (apiReleaseType/permissions anchors collided)");
                    return false;
                }
                json = json.Substring(0, edit.Start) + edit.Text + json.Substring(edit.End);
            }
        }

        try
        {
            int pos = 0;
            ParseValue(json, ref pos);
            SkipWhitespace(json, ref pos);
            if (pos != json.Length)
            {
                throw new FormatException("trailing characters after the root value");
            }
        }
        catch (FormatException exc)
        {
            Log.LogError("OpenHarmony module.json: the document is not valid JSON after the insertions: {0}", exc.Message);
            return false;
        }

        string result = json + "\n";
        string previous = File.Exists(OutputFile) ? File.ReadAllText(OutputFile) : null;
        Changed = previous != result;
        if (Changed)
        {
            var dir = Path.GetDirectoryName(OutputFile);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }
            File.WriteAllText(OutputFile, result);
        }
        Log.LogMessage(MessageImportance.Low, "OpenHarmony module.json: wrote {0} ({1} bytes, changed={2})", OutputFile, result.Length, Changed);
        return true;
    }

    private static int PlaceholderEnd(string text, int at)
    {
        int end = text.IndexOf('@', at + 1);
        if (end < 0)
        {
            return -1;
        }
        string name = text.Substring(at + 1, end - at - 1);
        if (name.Length == 0)
        {
            return -1;
        }
        foreach (char c in name)
        {
            if (!char.IsLetterOrDigit(c) && c != '_')
            {
                return -1;
            }
        }
        return end;
    }

    private static bool IsJsonLiteral(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return false;
        }
        if (value == "true" || value == "false" || value == "null")
        {
            return true;
        }
        int start = value[0] == '-' ? 1 : 0;
        if (start >= value.Length)
        {
            return false;
        }
        bool digit = false;
        for (int n = start; n < value.Length; n++)
        {
            char c = value[n];
            if (c >= '0' && c <= '9') { digit = true; continue; }
            if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') { continue; }
            return false;
        }
        return digit;
    }

    private static string EscapeJsonString(string value)
    {
        var sb = new StringBuilder(value.Length + 8);
        foreach (char c in value)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < 0x20)
                    {
                        sb.Append("\\u").Append(((int)c).ToString("x4"));
                    }
                    else
                    {
                        sb.Append(c);
                    }
                    break;
            }
        }
        return sb.ToString();
    }

    private static void SkipWhitespace(string text, ref int pos)
    {
        while (pos < text.Length && (text[pos] == ' ' || text[pos] == '\t' || text[pos] == '\r' || text[pos] == '\n'))
        {
            pos++;
        }
    }

    private static string ParseString(string text, ref int pos)
    {
        if (pos >= text.Length || text[pos] != '"')
        {
            throw new FormatException("expected a string at offset " + pos);
        }
        int start = ++pos;
        while (pos < text.Length)
        {
            char c = text[pos];
            if (c == '\\') { pos += 2; continue; }
            if (c == '"') { break; }
            pos++;
        }
        if (pos >= text.Length)
        {
            throw new FormatException("unterminated string at offset " + start);
        }
        string value = text.Substring(start, pos - start);
        pos++;   // step over the closing quote
        return value;
    }

    private static JsonNode ParseValue(string text, ref int pos)
    {
        SkipWhitespace(text, ref pos);
        if (pos >= text.Length)
        {
            throw new FormatException("unexpected end of input");
        }
        var node = new JsonNode { Start = pos };
        char c = text[pos];
        if (c == '{')
        {
            node.Members = new List<JsonMember>();
            pos++;
            SkipWhitespace(text, ref pos);
            if (pos < text.Length && text[pos] == '}')
            {
                pos++;
                node.End = pos;
                return node;
            }
            while (true)
            {
                SkipWhitespace(text, ref pos);
                var member = new JsonMember();
                member.Key = ParseString(text, ref pos);
                SkipWhitespace(text, ref pos);
                if (pos >= text.Length || text[pos] != ':')
                {
                    throw new FormatException("expected ':' after key '" + member.Key + "' at offset " + pos);
                }
                pos++;
                member.Value = ParseValue(text, ref pos);
                SkipWhitespace(text, ref pos);
                if (pos < text.Length && text[pos] == ',')
                {
                    member.HasComma = true;
                    member.CommaIndex = pos;
                    pos++;
                }
                node.Members.Add(member);
                if (!member.HasComma)
                {
                    break;
                }
            }
            SkipWhitespace(text, ref pos);
            if (pos >= text.Length || text[pos] != '}')
            {
                throw new FormatException("expected '}' at offset " + pos);
            }
            pos++;
            node.End = pos;
            return node;
        }
        if (c == '[')
        {
            pos++;
            SkipWhitespace(text, ref pos);
            if (pos < text.Length && text[pos] == ']')
            {
                pos++;
                node.End = pos;
                return node;
            }
            while (true)
            {
                ParseValue(text, ref pos);
                SkipWhitespace(text, ref pos);
                if (pos < text.Length && text[pos] == ',')
                {
                    pos++;
                    continue;
                }
                break;
            }
            SkipWhitespace(text, ref pos);
            if (pos >= text.Length || text[pos] != ']')
            {
                throw new FormatException("expected ']' at offset " + pos);
            }
            pos++;
            node.End = pos;
            return node;
        }
        if (c == '"')
        {
            ParseString(text, ref pos);
            node.End = pos;
            return node;
        }
        while (pos < text.Length)
        {
            c = text[pos];
            if (c == ',' || c == '}' || c == ']' || c == ' ' || c == '\t' || c == '\r' || c == '\n')
            {
                break;
            }
            pos++;
        }
        if (pos == node.Start)
        {
            throw new FormatException("expected a value at offset " + node.Start);
        }
        string literal = text.Substring(node.Start, pos - node.Start);
        if (literal != "true" && literal != "false" && literal != "null" && !IsJsonLiteral(literal))
        {
            throw new FormatException("invalid literal '" + literal + "' at offset " + node.Start);
        }
        node.End = pos;
        return node;
    }

    private static JsonNode FindMember(JsonNode node, string key)
    {
        var member = FindJsonMember(node, key);
        return member == null ? null : member.Value;
    }

    private static JsonMember FindJsonMember(JsonNode node, string key)
    {
        if (node == null || node.Members == null)
        {
            return null;
        }
        foreach (var member in node.Members)
        {
            if (member.Key == key)
            {
                return member;
            }
        }
        return null;
    }
}

