#!/usr/bin/env python3
# ============================================================================
# migrate-dllimport-to-libraryimport.py — rewrite [DllImport] to [LibraryImport] in the OHOS interop sources.
#
# Source-generated marshalling migration used on the OpenHarmony host and platform-slice
# interop files: converts `extern` to `partial`, marks the enclosing type `partial`, and adds
# `StringMarshalling = StringMarshalling.Utf8` where the declaration takes strings
# (`CharSet = CharSet.Ansi` maps to it). Comment/string aware; dry-run by default.
#
# Usage: python3 scripts/migrate-dllimport-to-libraryimport.py [--apply] FILE...
#        (files are normally src/OpenHarmonyHost/*.cs and the maui-ohos OpenHarmony slice)
# Exit:  0 = completed (dry-run included), 1 = file could not be migrated.
# The result must pass the export contract gate: scripts/check-host-exports.py.
# ============================================================================
import re
import sys

DLL = re.compile(r"\[(?:System\.Runtime\.InteropServices\.)?DllImport\(")
STRLIB = re.compile(r"StringMarshalling\s*=")


def strip_comments_strings(text):
    """Return text with comments and string/char literals blanked (offsets preserved)."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            while i < n and text[i] != '\n':
                out[i] = ' '
                i += 1
        elif c == '/' and i + 1 < n and text[i + 1] == '*':
            out[i] = out[i + 1] = ' '
            i += 2
            while i + 1 < n and not (text[i] == '*' and text[i + 1] == '/'):
                out[i] = ' '
                i += 1
            if i + 1 < n:
                out[i] = out[i + 1] = ' '
                i += 2
        elif c == '"' or c == "'":
            quote = c
            i += 1
            while i < n and text[i] != quote:
                if text[i] == '\\':
                    out[i] = ' '
                    i += 1
                out[i] = ' '
                i += 1
            i += 1
        else:
            i += 1
    return ''.join(out)


def find_types(text):
    """Yield (decl_start, brace_pos, name) for class/struct/interface declarations."""
    masked = strip_comments_strings(text)
    pattern = re.compile(
        r"(?m)^[ \t]*(?:(?:public|internal|protected|private|abstract|sealed|static|partial|unsafe|file|new|readonly|ref)[ \t]+)*"
        r"(class|struct|interface|record)[ \t]+([A-Za-z_]\w*)")
    for m in pattern.finditer(masked):
        brace = masked.find('{', m.end())
        if brace < 0:
            continue
        # No ';' or '=' before '{' on a non-declaration (e.g. record positional params end with ')').
        chunk = masked[m.end():brace]
        if ';' in chunk:
            continue
        yield (m.start(), brace, m.group(2))


def match_brace(masked, brace):
    depth = 0
    i = brace
    while i < len(masked):
        c = masked[i]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return len(masked)


def enclosing_types(text, pos):
    masked = strip_comments_strings(text)
    result = []
    for start, brace, name in find_types(text):
        if start < pos and match_brace(masked, brace) > pos:
            result.append((start, brace, name))
    result.sort()
    return result


def transform(path, apply_changes):
    with open(path, encoding='utf-8') as fh:
        text = fh.read()
    if not DLL.search(text):
        print(f"  {path}: no DllImport")
        return 0
    edits = []  # (start, end, replacement) on original text
    count = 0
    types_to_mark = set()

    for m in DLL.finditer(text):
        count += 1
        # The full attribute including its closing bracket+paren.
        attr_end = text.find(')]', m.end())
        if attr_end < 0:
            raise SystemExit(f"{path}: unterminated attribute at {m.start()}")
        attr_end += 2
        attr = text[m.end():attr_end - 2]
        # Method declaration runs from after the attribute to the first ';'.
        decl_end = text.find(';', attr_end)
        if decl_end < 0:
            raise SystemExit(f"{path}: unterminated declaration at {attr_end}")
        decl = text[attr_end:decl_end]
        has_string = re.search(r"\bstring\b", decl) is not None
        has_charset = 'CharSet = CharSet.Ansi' in attr
        new_attr = attr
        if has_charset:
            new_attr = new_attr.replace('CharSet = CharSet.Ansi', 'StringMarshalling = StringMarshalling.Utf8')
        elif has_string and not STRLIB.search(new_attr):
            new_attr = new_attr.rstrip() + ', StringMarshalling = StringMarshalling.Utf8'
        new_decl = re.sub(r"\bextern\b", "partial", decl)
        if new_decl == decl and "partial" not in decl:
            raise SystemExit(f"{path}: no extern to replace near offset {m.start()}")
        prefix = text[m.start():m.end() - len('DllImport(')]
        edits.append((m.start(), attr_end, prefix + 'LibraryImport(' + new_attr + ')]'))
        edits.append((attr_end, decl_end, new_decl))
        for start, brace, name in enclosing_types(text, m.start()):
            types_to_mark.add((start, brace, name))

    # Mark enclosing types partial.
    type_edits = []
    masked = strip_comments_strings(text)
    for start, brace, name in sorted(types_to_mark):
        line_end = masked.find('\n', start)
        line = text[start:line_end]
        # The type keyword in the original line.
        tm = re.search(r"\b(class|struct|interface|record)\b", line)
        if not tm:
            continue
        if re.search(r"\bpartial\b", line[:tm.start()]):
            print(f"  {path}: {name} already partial")
            continue
        insert_at = start + tm.start()
        type_edits.append((insert_at, insert_at, 'partial '))
        print(f"  {path}: {name} -> partial")

    all_edits = edits + type_edits
    all_edits.sort(key=lambda e: e[0])
    new_text = text
    for start, end, replacement in reversed(all_edits):
        new_text = new_text[:start] + replacement + new_text[end:]
    if new_text == text:
        print(f"  {path}: no change")
        return 0
    if apply_changes:
        with open(path, 'w', encoding='utf-8') as fh:
            fh.write(new_text)
    print(f"  {path}: {count} declarations migrated -> LibraryImport"
          + (" (written)" if apply_changes else " (dry-run)"))
    return count


def main():
    apply_changes = False
    files = []
    for arg in sys.argv[1:]:
        if arg == '--apply':
            apply_changes = True
        else:
            files.append(arg)
    if not files:
        print("usage: migrate-dllimport-to-libraryimport.py [--apply] FILE...", file=sys.stderr)
        return 2
    total = 0
    for path in files:
        total += transform(path, apply_changes)
    print(f"total: {total} declarations")
    return 0


if __name__ == '__main__':
    sys.exit(main())
