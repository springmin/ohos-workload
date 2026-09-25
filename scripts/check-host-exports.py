#!/usr/bin/env python3
"""Host export contract gate (FIX-INTEROP #1).

libopenharmonyhost.so is compiled as C++ (clang++ treats the .c file as C++), so a host
function only exports its plain name when it has C linkage: either it is declared in
openharmony_host.h (whose extern "C" block covers the whole header) or its definition sits
in an extern "C" region / carries an explicit extern "C". The sensor and notification
functions missed both and shipped as _Z... mangled symbols, so the managed P/Invoke
lookups failed only at runtime.

This script is the static, NDK-free half of the gate (CI runs it on every PR):
  * default mode checks every name in src/OpenHarmonyHost/host-exports.txt against the
    native sources and fails when a name is missing, has no C linkage, or only exists as a
    declaration-less C++-mangled definition;
  * --print-managed regenerates the expected list from the managed DllImport/LibraryImport declarations
    (maui-ohos platform slice + this repository's Hosting/Maui.Graphics sources).
  * --cross-check additionally resolves the managed EntryPoints (including
    EntryPoint = <const> forms) and fails when a managed requirement is absent from
    host-exports.txt, printing the full 121-declaration report.

The built-library half runs in scripts/build-host.sh (nm -D: every expected name must be
present as a plain symbol). Usage:
  python3 scripts/check-host-exports.py
  python3 scripts/check-host-exports.py --cross-check --maui-dir ../maui-ohos/src/Core/src/Platform/OpenHarmony
  python3 scripts/check-host-exports.py --print-managed --maui-dir <dir>
"""

import argparse
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST = os.path.join(REPO, "src", "OpenHarmonyHost")
EXPECTED = os.path.join(HOST, "host-exports.txt")
HEADER = os.path.join(HOST, "openharmony_host.h")
SOURCES = ["host_napi.cpp", "openharmony_host.c", "host_optional.c"]
# Managed import sources beyond the slice: keep in sync with the audit's extract.py.
HOSTING_DIRS = [
    os.path.join(REPO, "src", "Microsoft.OpenHarmony.Hosting"),
    os.path.join(REPO, "src", "Microsoft.OpenHarmony.Maui.Graphics"),
]

def read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()

def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)

def expected_names():
    names = []
    for line in read(EXPECTED).splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            names.append(line)
    if not names:
        sys.exit(f"ERROR: {EXPECTED} lists no exports")
    return names

def header_declarations():
    """Names declared inside openharmony_host.h (its whole body is an extern "C" block)."""
    text = strip_comments(read(HEADER))
    if 'extern "C"' not in text:
        sys.exit(f"ERROR: {HEADER} has no extern \"C\" block; every prototype would be mangled")
    return set(re.findall(r"\b(ohos_host_[a-z0-9_]+)\s*\(", text))

def c_linkage_regions(text):
    """[(start, end)] offsets covered by an extern "C" region or one-declaration prefix."""
    regions = []
    for match in re.finditer(r'extern\s*"C"', text):
        start = match.end()
        tail = text[start:]
        brace = re.match(r"\s*\{", tail)
        if brace:
            depth = 0
            index = start + brace.start()
            while index < len(text):
                if text[index] == "{":
                    depth += 1
                elif text[index] == "}":
                    depth -= 1
                    if depth == 0:
                        regions.append((match.start(), index + 1))
                        break
                index += 1
        else:
            # One-declaration form: cover up to the terminating ';' (or the '{' of an inline
            # definition) so the window cannot leak into the next function's declaration.
            index = start
            depth = 0
            while index < len(text):
                char = text[index]
                if char in "([":
                    depth += 1
                elif char in ")]":
                    depth -= 1
                elif char == ";" and depth == 0:
                    regions.append((match.start(), index + 1))
                    break
                elif char == "{" and depth == 0:
                    end = index
                    depth = 1
                    while end < len(text) and depth:
                        if text[end] == "{":
                            depth += 1
                        elif text[end] == "}":
                            depth -= 1
                        end += 1
                    regions.append((match.start(), end))
                    break
                index += 1
    return regions

def definitions(file_name):
    """Name -> offset of each function definition (statement ends with '{')."""
    path = os.path.join(HOST, file_name)
    text = strip_comments(read(path))
    # Blank out the linkage tokens so a definition prefixed by extern "C" still matches; the
    # replacement keeps the offsets aligned with the original text used for region checks.
    masked = text.replace('extern "C"', " " * len('extern "C"'))
    found = {}
    pattern = re.compile(
        r"(?:^|\n)[ \t]*[A-Za-z_][\w \t\*&:<>,]*?\b(ohos_host_[a-z0-9_]+)\s*\(",
    )
    for match in pattern.finditer(masked):
        name = match.group(1)
        # The definition's parameter list: find the matching ')' then require '{'.
        depth = 0
        index = match.end() - 1
        while index < len(masked):
            if masked[index] == "(":
                depth += 1
            elif masked[index] == ")":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        after = masked[index + 1:].lstrip()
        if after.startswith("{") and name not in found:
            found[name] = match.start()
    return found

def check_static(names):
    declared = header_declarations()
    problems = []
    defined = {}
    for source in SOURCES:
        for name, offset in definitions(source).items():
            defined.setdefault(name, (source, offset))
    for name in names:
        if name in declared:
            continue
        if name not in defined:
            problems.append(f"{name}: not declared in {os.path.basename(HEADER)} and no definition found")
            continue
        source, offset = defined[name]
        text = strip_comments(read(os.path.join(HOST, source)))
        # The definition's own match can start on the preceding newline (the regex consumes
        # it), so test overlap of the definition statement with the linkage regions.
        statement_window = (offset, offset + 400)
        if any(start < statement_window[1] and statement_window[0] < end for start, end in c_linkage_regions(text)):
            continue
        problems.append(
            f"{name}: defined in {source} without C linkage (not declared in {os.path.basename(HEADER)}, "
            f"not inside extern \"C\"); clang++ will export it as a mangled _Z symbol")
    return problems

# ---------------------------------------------------------------------------
# Managed EntryPoint cross-check (the DllImport/LibraryImport declarations).
# ---------------------------------------------------------------------------

def parse_managed(root_dir):
    """[(file, line, resolved_entry, method)] for DllImport/LibraryImport declarations in root_dir."""
    rows = []
    for file_name in sorted(os.listdir(root_dir)):
        if not file_name.endswith(".cs"):
            continue
        text = read(os.path.join(root_dir, file_name))
        consts = dict(re.findall(r'const\s+string\s+(\w+)\s*=\s*"([^"]+)"', text))
        for match in re.finditer(r"\[(?:System\.Runtime\.InteropServices\.)?(?:Dll|Library)Import\s*\(([^)]*)\)\s*\]", text):
            attr = match.group(1)
            after = text[match.end():]
            decl = re.search(r"(?:extern\s+)?[^;{]*?\b([A-Za-z_]\w*)\s*\(([^;{]*?)\)\s*;", after, flags=re.S)
            if not decl:
                continue
            entry = re.search(r"EntryPoint\s*=\s*([^,\)]+)", attr)
            if entry:
                value = entry.group(1).strip()
                if value.startswith('"'):
                    resolved = value.strip('"')
                elif value in consts:
                    resolved = consts[value]
                else:
                    resolved = "UNRESOLVED:" + value
            else:
                resolved = decl.group(1)
            line = text[:match.start()].count("\n") + 1
            rows.append((file_name, line, resolved, decl.group(1)))
    return rows

def managed_dirs(maui_dir):
    return [maui_dir] + HOSTING_DIRS

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--maui-dir", default=os.path.normpath(os.path.join(REPO, "..", "maui-ohos", "src", "Core", "src", "Platform", "OpenHarmony")),
                        help="directory with the maui-ohos OpenHarmony platform slice sources")
    parser.add_argument("--print-managed", action="store_true",
                        help="print the expected export list derived from the managed DllImport declarations")
    parser.add_argument("--cross-check", action="store_true",
                        help="compare the managed EntryPoints against host-exports.txt and print the report")
    args = parser.parse_args()

    if not os.path.isdir(args.maui_dir):
        sys.exit(f"ERROR: maui slice directory not found: {args.maui_dir}")

    rows = []
    for directory in managed_dirs(args.maui_dir):
        if os.path.isdir(directory):
            rows.extend(parse_managed(directory))
    unresolved = [row for row in rows if row[2].startswith("UNRESOLVED:")]
    if unresolved:
        for file_name, line, entry, _ in unresolved:
            print(f"ERROR: {file_name}:{line} EntryPoint const {entry} does not resolve", file=sys.stderr)
        return 1

    if args.print_managed:
        for name in sorted({row[2] for row in rows}):
            print(name)
        print(f"# {len(rows)} managed import declarations, {len({row[2] for row in rows})} unique EntryPoints", file=sys.stderr)
        return 0

    names = expected_names()
    known = set(names)
    missing_managed = sorted({row[2] for row in rows} - known)
    expected = set(names)

    problems = check_static(names)
    if missing_managed:
        problems.append("managed EntryPoints absent from host-exports.txt: " + ", ".join(missing_managed))

    print(f"host-exports.txt: {len(names)} expected exports")
    print(f"native declarations: {len(header_declarations())} in {os.path.basename(HEADER)}")
    print(f"managed imports: {len(rows)} declarations, {len({row[2] for row in rows})} unique EntryPoints")

    if args.cross_check:
        print("\nmanaged EntryPoint -> host-exports.txt:")
        for name in sorted({row[2] for row in rows}):
            mark = "ok" if name in expected else "MISSING"
            users = ", ".join(sorted({f"{file_name}:{line}" for file_name, line, entry, _ in rows if entry == name}))
            print(f"  [{mark}] {name} ({users})")

    if problems:
        print("\nFAIL: the host export contract is broken:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        print("\nAdd the missing declaration to src/OpenHarmonyHost/openharmony_host.h (inside its"
              " extern \"C\" block) and, when a managed import declaration changed, regenerate"
              " src/OpenHarmonyHost/host-exports.txt with --print-managed.", file=sys.stderr)
        return 1

    print(f"\nOK: all {len(names)} expected exports have C linkage and every managed EntryPoint is listed")
    return 0

if __name__ == "__main__":
    sys.exit(main())
