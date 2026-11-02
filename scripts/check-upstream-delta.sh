#!/bin/sh
# check-upstream-delta.sh - drift check for the MAUI OpenHarmony slice against its upstream base.
#
# The slice lives in the sibling maui-ohos checkout. Its delta against the pinned upstream commit
# is the sync surface (see runtime-ohos docs/plans/2026-10-28-ohos-maui-upstream-delta.md):
# 152 files, +50,788/-3, 148 added / 4 modified, 143 slice files, and four intrusive upstream
# files at +77/-3. This script re-measures those numbers and fails when they move outside the
# tolerance recorded in test/p0-gate/upstream-delta.json, so RTM/upstream syncs cannot silently
# widen the conflict surface.
#
# Usage: scripts/check-upstream-delta.sh [--repo <maui-ohos checkout>] [--baseline <sha>]
#                                       [--json <baseline file>]
# Env: MAUI_SLICE_REPO  default repo path (else ../maui-ohos next to this repo)
# Exit: 0 = within tolerance, 1 = drift, 3 = prerequisite missing (skip), 2 = usage error.
set -u

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

W="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${MAUI_SLICE_REPO:-$W/../maui-ohos}"
JSON="$W/test/p0-gate/upstream-delta.json"
BASELINE=""

usage() {
    cat <<EOF
usage: $0 [--repo <maui-ohos checkout>] [--baseline <sha>] [--json <baseline file>]

Re-measures the slice delta against the pinned upstream commit and compares it with
test/p0-gate/upstream-delta.json (expected values + tolerance).

Exit: 0 = within tolerance, 1 = drift, 3 = prerequisite missing, 2 = usage error.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)     REPO=$2; shift 2 ;;
        --baseline) BASELINE=$2; shift 2 ;;
        --json)     JSON=$2; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *) warn "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
done

command -v python3 >/dev/null 2>&1 || { warn "python3 not found"; exit 3; }
[ -d "$REPO" ] || { warn "maui-ohos checkout not found: $REPO (set MAUI_SLICE_REPO)"; exit 3; }
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { warn "not a git checkout: $REPO"; exit 3; }
[ -f "$JSON" ] || { warn "baseline file not found: $JSON"; exit 2; }

BA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["baseline_commit"])' "$JSON" 2>/dev/null || true)"
[ -n "$BA" ] || { warn "cannot read baseline_commit from $JSON"; exit 2; }
[ -n "$BASELINE" ] && BA="$BASELINE"
if ! git -C "$REPO" cat-file -e "$BA^{commit}" 2>/dev/null; then
    warn "baseline commit not present in $REPO: $BA (fetch upstream history first)"
    exit 3
fi

log "upstream delta: $REPO vs $BA"
python3 - "$REPO" "$BA" "$JSON" <<'PY'
import json
import os
import subprocess
import sys

repo, baseline, doc_path = sys.argv[1], sys.argv[2], sys.argv[3]
doc = json.load(open(doc_path))
expected = doc["expected"]
tol = doc["tolerance"]
intrusive = doc.get("intrusive_files", [])


def git(*args):
    return subprocess.check_output(["git", "-C", repo, *args], text=True)


def numstat(paths=()):
    out = git("diff", "--numstat", f"{baseline}..HEAD", *paths)
    files = add = dele = 0
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        a, d, _path = parts
        files += 1
        if a != "-":
            add += int(a)
        if d != "-":
            dele += int(d)
    return files, add, dele


files, insertions, deletions = numstat()
status = git("diff", "--name-status", f"{baseline}..HEAD").splitlines()
counts = {}
for line in status:
    code = line.split("\t", 1)[0][:1]
    counts[code] = counts.get(code, 0) + 1
added = counts.get("A", 0)
modified = counts.get("M", 0)
slice_files = len(git("ls-files", "src/Core/src/Platform/OpenHarmony/**").splitlines())
intr_files, intr_add, intr_del = numstat(tuple(intrusive)) if intrusive else (0, 0, 0)

actual = {
    "files": files,
    "insertions": insertions,
    "deletions": deletions,
    "added": added,
    "modified": modified,
    "slice_files": slice_files,
    "intrusive_insertions": intr_add,
    "intrusive_deletions": intr_del,
}

failed = 0
print(f"  baseline {baseline[:12]}  files={files} +{insertions}/-{deletions}"
      f"  added={added} modified={modified}  slice_files={slice_files}"
      f"  intrusive=+{intr_add}/-{intr_del}")
for key, want in expected.items():
    got = actual[key]
    limit = tol.get(key, 0)
    ok = abs(got - want) <= limit
    if not ok:
        failed += 1
    print(f"  {'PASS' if ok else 'FAIL'} {key:<18} actual={got} expected={want} tol=±{limit}")

for path in intrusive:
    full = os.path.join(repo, path)
    if os.path.exists(full):
        print(f"  PASS intrusive-file    {path}")
    else:
        failed += 1
        print(f"  FAIL intrusive-file    missing: {path}")

if failed:
    print(f"upstream-delta: {failed} metric(s) outside tolerance")
    print("  If intentional, update test/p0-gate/upstream-delta.json and")
    print("  docs/plans/2026-10-28-ohos-maui-upstream-delta.md together.")
    sys.exit(1)
print("upstream-delta: PASS (within tolerance)")
PY
rc=$?
exit "$rc"
