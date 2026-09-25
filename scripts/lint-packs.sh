#!/bin/sh
# lint-packs.sh - pack-layout lint for the workload SDK packs.
#
# Every .props/.targets file under packs/ must either be a documented SDK entry point or be
# imported by another pack file:
#   * entry points (the SDK imports them by name, no repo file does):
#       Sdk/Sdk.props          - imported at the top of every project by the SDK resolver
#       Sdk/Sdk.targets        - imported (deferred) by the SDK resolver
#       Sdk/AutoImport.props   - imported into every project by WorkloadAutoImportPropsLocator
#   * everything else must appear in an <Import Project="..."> inside packs/
# A file with no importer is dead (audit V3: BundledVersions.props / DefaultProperties.props /
# SupportedPlatforms.props / Microsoft.OpenHarmony.Sdk.targets shipped with no importer) and can
# silently drift from the live definitions in Sdk/Sdk.targets.
#
#   scripts/lint-packs.sh            lint the repo packs
#   LINT_PACKS_ROOTS=<dir>           lint another packs root (selftest fixtures)
#
# Exit: 0 = clean; 1 = violations; 2 = bad usage.
set -u

W="$(cd "$(dirname "$0")/.." && pwd)"
ROOTS="${LINT_PACKS_ROOTS:-$W/packs}"

[ -d "$ROOTS" ] || { echo "packs root not found: $ROOTS" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }

python3 - "$ROOTS" <<'PY'
import os, re, sys

roots = sys.argv[1]
entry_points = {'Sdk/Sdk.props', 'Sdk/Sdk.targets', 'Sdk/AutoImport.props'}
layout = []
imports = []  # (importing file, import target)
for dirpath, dirs, files in os.walk(roots):
    dirs[:] = [d for d in dirs if d not in {'.git', 'obj', 'bin', 'node_modules'}]
    for name in sorted(files):
        if not name.endswith(('.props', '.targets')):
            continue
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, roots)
        layout.append(rel)
        # <Import ... Project="value" ...> including multi-line attributes.
        text = open(path, encoding='utf-8', errors='replace').read()
        for m in re.finditer(r'<Import\b[^>]*?Project\s*=\s*"([^"]+)"', text, re.S):
            imports.append((rel, m.group(1)))

layout.sort()
if not layout:
    print(f'no .props/.targets files under {roots}', file=sys.stderr)
    sys.exit(1)

def base_of(target):
    t = target.replace('\\', '/')
    return t.rsplit('/', 1)[-1]

imported_basenames = {base_of(t) for _, t in imports}

packs = []
for d in sorted(os.listdir(roots)):
    product = os.path.join(roots, d)
    if d.startswith('Microsoft.OpenHarmony.Sdk') and os.path.isdir(product):
        for version in sorted(os.listdir(product)):
            vdir = os.path.join(product, version)
            if os.path.isdir(vdir):
                packs.append(os.path.join(d, version))
if not packs:
    print(f'no Microsoft.OpenHarmony.Sdk/<version> packs under {roots}', file=sys.stderr)
    sys.exit(1)

dead = []
missing_entry = []
dangling = []
for rel, target in imports:
    if '$(MSBuild' in target or '$(' in target or target.startswith('..'):
        b = base_of(target)
        if b not in {os.path.basename(x) for x in layout}:
            dangling.append((rel, target))

print(f'pack lint: {roots}')
for rel in layout:
    base = os.path.basename(rel)
    if rel in entry_points or base in {os.path.basename(e) for e in entry_points}:
        print(f'  entry    {rel}')
    elif base in imported_basenames:
        print(f'  imported {rel}')
    else:
        print(f'  DEAD     {rel} (no <Import> references it)', file=sys.stderr)
        dead.append(rel)

for pack in packs:
    for e in sorted(entry_points):
        if not os.path.isfile(os.path.join(roots, pack, e)):
            print(f'  MISSING entry point {pack}/{e}', file=sys.stderr)
            missing_entry.append(f'{pack}/{e}')

for rel, target in dangling:
    print(f'  DANGLING import in {rel}: {target}', file=sys.stderr)

total = len(layout)
if dead or missing_entry or dangling:
    print(f'pack lint FAILED: {len(dead)} dead file(s), {len(dangling)} dangling import(s), '
          f'{len(missing_entry)} missing entry point(s) of {total} file(s) in {len(packs)} pack(s)',
          file=sys.stderr)
    sys.exit(1)
print(f'pack lint OK: {total} file(s) in {len(packs)} pack(s), every non-entry file has an importer')
PY
