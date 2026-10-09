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
    // Deep links: the same ';'-separated https host list the targets write into app.json
    // linkHosts. Non-empty appends the app-link skill (browsable/viewData + one https uri per
    // host) to module.abilities[0].skills, so the system can dispatch the app link the managed
    // allow-list accepts. Empty leaves the template bytes untouched.
    public string AppLinkHosts { get; set; }
    // 'true' (the targets default) adds "domainVerify":true to the app-link skill: the system
    // then dispatches an https link only after the host passed the AGC App Linking domain
    // verification. Any other value omits the member (the conservative pre-registration form).
    public string AppLinkDomainVerify { get; set; }
    // WebAuthenticator: the ';'-separated callback routes of the app's browser redirect flow
    // (a full absolute URL like "myapp://callback" or a bare scheme name). Non-empty appends a
    // browsable/viewData skill element carrying one uri per route to module.abilities[0].skills,
    // so the system can dispatch the browser's redirect back to the ability; the managed
    // OpenHarmonyWebAuthenticator then matches scheme/host/port/path against the app's callback
    // URL. Empty leaves the template bytes untouched.
    public string WebAuthenticatorCallbackUrls { get; set; }
    [Output] public bool Changed { get; set; }

    private sealed class JsonNode
    {
        public int Start;
        public int End;
        public List<JsonMember> Members;   // objects only
        public List<JsonNode> Elements;    // arrays only
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

        // Skills appends: the app-link skill element and the WebAuthenticator callback-route
        // skill element are collected here and inserted with ONE edit at the skills array's
        // closing bracket. Two separate same-offset edits would both apply, but the edit sort
        // does not define the order of equal keys, so the combined insertion keeps the generated
        // module.json deterministic when both properties are set. The home skill element stays
        // untouched; with neither property set there is no edit here.
        var skillElements = new List<string>();
        int skillAnchor = -1;
        bool skillsNeedComma = false;

        // Deep links: append the app-link skill element to module.abilities[0].skills so the
        // manifest declares the same https hosts the managed side accepts through app.json
        // linkHosts. The home skill element stays untouched; unset AppLinkHosts adds no edit.
        if (!string.IsNullOrEmpty(AppLinkHosts))
        {
            var hosts = new List<string>();
            foreach (string raw in AppLinkHosts.Split(';'))
            {
                string host = (raw ?? "").Trim();
                if (host.Length == 0)
                {
                    continue;
                }
                bool valid = host.IndexOf('.') > 0 && host.IndexOf('.') < host.Length - 1 && host.IndexOf("..", StringComparison.Ordinal) < 0;
                foreach (char c in host)
                {
                    if (!char.IsLetterOrDigit(c) && c != '.' && c != '-')
                    {
                        valid = false;
                        break;
                    }
                }
                if (!valid || host[0] == '-' || host[host.Length - 1] == '-')
                {
                    Log.LogError("OpenHarmony module.json: OpenHarmonyAppLinkHosts value '{0}' is not a host name (letters, digits, '.' and '-' only, at least one dot); pass a ';'-separated list like -p:OpenHarmonyAppLinkHosts=\"example.com;www.example.com\".", host);
                    return false;
                }
                bool known = false;
                foreach (string seen in hosts)
                {
                    if (string.Equals(seen, host, StringComparison.OrdinalIgnoreCase))
                    {
                        known = true;
                        break;
                    }
                }
                if (!known)
                {
                    hosts.Add(host);
                }
            }
            if (hosts.Count == 0)
            {
                Log.LogError("OpenHarmony module.json: OpenHarmonyAppLinkHosts carries no host after splitting '{0}' on ';'.", AppLinkHosts);
                return false;
            }
            var abilities = FindMember(module, "abilities");
            JsonNode ability = abilities != null && abilities.Elements != null && abilities.Elements.Count > 0 ? abilities.Elements[0] : null;
            var skills = ability == null ? null : FindMember(ability, "skills");
            if (skills == null || skills.Elements == null)
            {
                Log.LogError("OpenHarmony module.json: OpenHarmonyAppLinkHosts needs a module.abilities[0].skills array to append the app-link skill to.");
                return false;
            }
            skillsNeedComma = skills.Elements.Count > 0;
            skillAnchor = skills.End - 1;   // before the skills array's closing bracket
            var element = new StringBuilder();
            element.Append("{\"entities\":[\"entity.system.browsable\"],\"actions\":[\"ohos.want.action.viewData\"],\"uris\":[");
            for (int n = 0; n < hosts.Count; n++)
            {
                if (n > 0)
                {
                    element.Append(',');
                }
                element.Append("{\"scheme\":\"https\",\"host\":\"").Append(EscapeJsonString(hosts[n])).Append("\"}");
            }
            element.Append(']');
            if (string.Equals(AppLinkDomainVerify, "true", StringComparison.OrdinalIgnoreCase))
            {
                element.Append(",\"domainVerify\":true");
            }
            element.Append('}');
            skillElements.Add(element.ToString());
        }

        // WebAuthenticator: append a browsable/viewData skill element carrying one uri per
        // callback route, so the browser's redirect to the callback scheme/host is dispatched
        // back to this ability. A bare scheme declares a scheme-only uri (any host); a full
        // absolute URL contributes scheme + host (+ an explicit port). The managed side still
        // matches the app's exact callback URL before completing the flow.
        if (!string.IsNullOrEmpty(WebAuthenticatorCallbackUrls))
        {
            var routes = new List<string>();   // canonical "scheme|host|port" (lower-case, port empty when default)
            foreach (string raw in WebAuthenticatorCallbackUrls.Split(';'))
            {
                string route = (raw ?? "").Trim();
                if (route.Length == 0)
                {
                    continue;
                }
                string scheme;
                string host = "";
                int port = 0;
                if (Uri.TryCreate(route, UriKind.Absolute, out Uri parsed) && parsed.Scheme.Length > 0)
                {
                    scheme = parsed.Scheme;
                    host = parsed.Host;
                    if (!parsed.IsDefaultPort && parsed.Port > 0)
                    {
                        port = parsed.Port;
                    }
                }
                else if (IsValidSchemeToken(route))
                {
                    scheme = route;
                }
                else
                {
                    Log.LogError("OpenHarmony module.json: OpenHarmonyWebAuthenticatorCallbackUrls value '{0}' is not a callback route (an absolute URL like \"myapp://callback\" or a bare scheme name); pass a ';'-separated list like -p:OpenHarmonyWebAuthenticatorCallbackUrls=\"myapp://callback\".", route);
                    return false;
                }
                if (!IsValidSchemeToken(scheme))
                {
                    Log.LogError("OpenHarmony module.json: OpenHarmonyWebAuthenticatorCallbackUrls route '{0}' has an invalid scheme '{1}' (a letter followed by letters, digits, '+', '-' or '.').", route, scheme);
                    return false;
                }
                if (host.Length > 0 && !IsValidCallbackHost(host))
                {
                    Log.LogError("OpenHarmony module.json: OpenHarmonyWebAuthenticatorCallbackUrls route '{0}' has an invalid host '{1}' (letters, digits, '.', '-' and '_' only).", route, host);
                    return false;
                }
                string key = scheme.ToLowerInvariant() + "|" + host.ToLowerInvariant() + "|" + (port > 0 ? port.ToString() : "");
                if (!routes.Contains(key))
                {
                    routes.Add(key);
                }
            }
            if (routes.Count == 0)
            {
                Log.LogError("OpenHarmony module.json: OpenHarmonyWebAuthenticatorCallbackUrls carries no route after splitting '{0}' on ';'.", WebAuthenticatorCallbackUrls);
                return false;
            }
            var abilities = FindMember(module, "abilities");
            JsonNode ability = abilities != null && abilities.Elements != null && abilities.Elements.Count > 0 ? abilities.Elements[0] : null;
            var skills = ability == null ? null : FindMember(ability, "skills");
            if (skills == null || skills.Elements == null)
            {
                Log.LogError("OpenHarmony module.json: OpenHarmonyWebAuthenticatorCallbackUrls needs a module.abilities[0].skills array to append the callback skill to.");
                return false;
            }
            if (skillAnchor < 0)
            {
                skillsNeedComma = skills.Elements.Count > 0;
                skillAnchor = skills.End - 1;   // before the skills array's closing bracket
            }
            var element = new StringBuilder();
            element.Append("{\"entities\":[\"entity.system.browsable\"],\"actions\":[\"ohos.want.action.viewData\"],\"uris\":[");
            for (int n = 0; n < routes.Count; n++)
            {
                if (n > 0)
                {
                    element.Append(',');
                }
                string[] parts = routes[n].Split('|');
                element.Append("{\"scheme\":\"").Append(EscapeJsonString(parts[0])).Append('"');
                if (parts[1].Length > 0)
                {
                    element.Append(",\"host\":\"").Append(EscapeJsonString(parts[1])).Append('"');
                }
                if (parts[2].Length > 0)
                {
                    element.Append(",\"port\":").Append(parts[2]);
                }
                element.Append('}');
            }
            element.Append("]}");
            skillElements.Add(element.ToString());
        }

        if (skillElements.Count > 0)
        {
            var fragment = new StringBuilder();
            if (skillsNeedComma)
            {
                fragment.Append(',');
            }
            for (int n = 0; n < skillElements.Count; n++)
            {
                if (n > 0)
                {
                    fragment.Append(',');
                }
                fragment.Append(skillElements[n]);
            }
            edits.Add(new Edit { Start = skillAnchor, End = skillAnchor, Text = fragment.ToString() });
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

    // A URI scheme per RFC 3986: a letter followed by letters, digits, '+', '-' or '.'.
    private static bool IsValidSchemeToken(string value)
    {
        if (string.IsNullOrEmpty(value) || !char.IsLetter(value[0]))
        {
            return false;
        }
        for (int i = 1; i < value.Length; i++)
        {
            char c = value[i];
            if (!char.IsLetterOrDigit(c) && c != '+' && c != '-' && c != '.')
            {
                return false;
            }
        }
        return true;
    }

    // The host name forms a callback route may carry into the skill uri: letters, digits, '.',
    // '-' and '_' (covers DNS names and IPv4 literals; a bracketed IPv6 literal is rejected).
    private static bool IsValidCallbackHost(string value)
    {
        foreach (char c in value)
        {
            if (!char.IsLetterOrDigit(c) && c != '.' && c != '-' && c != '_')
            {
                return false;
            }
        }
        return value.Length > 0;
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
            node.Elements = new List<JsonNode>();
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
                node.Elements.Add(ParseValue(text, ref pos));
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

