#!/bin/sh
# rtm-cutover.sh - read-only dry-run for the kit #59 / RTM cutover.
#
# The cutover itself is human-driven: it changes five repos, workload packs/manifests, CI refs
# and the kit. This script only verifies that the tree still matches the pins recorded in
# test/p0-gate/rtm-pins.json, prints the five repo tips, and prints the cutover sequence.
# It never writes, builds, installs or pushes.
#
# Usage: scripts/rtm-cutover.sh [--json <pins.json>] [--dry-run]
# Exit: 0 = version pins match, 1 = a hard pin mismatch, 2 = usage error.
#       Repo branch/tip differences are WARN (local feature checkouts are allowed).
set -u

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

W="$(cd "$(dirname "$0")/.." && pwd)"
JSON="$W/test/p0-gate/rtm-pins.json"

usage() {
    cat <<EOF
usage: $0 [--json <pins.json>] [--dry-run]

Read-only RTM/#59 cutover dry-run: version pins, five repo tips, CI refs, checklist.
Exit: 0 = pins match, 1 = hard mismatch, 2 = usage error.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --json)    JSON=$2; shift 2 ;;
        --dry-run) shift ;;
        -h|--help) usage; exit 0 ;;
        *) warn "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
done

command -v python3 >/dev/null 2>&1 || { warn "python3 not found"; exit 2; }
[ -f "$JSON" ] || { warn "pins file not found: $JSON"; exit 2; }

if [ -z "${DOTNET:-}" ] && [ -x "$HOME/.dotnet.11.0.100/dotnet" ]; then
    DOTNET="$HOME/.dotnet.11.0.100/dotnet"
fi
[ -n "${DOTNET:-}" ] && export DOTNET

log "RTM cutover dry-run (read-only)"
python3 - "$W" "$JSON" <<'PY'
import json
import os
import pathlib
import re
import subprocess
import sys

w = pathlib.Path(sys.argv[1])
pins = json.load(open(sys.argv[2]))
failed = 0


def check(name, ok, detail=""):
    global failed
    if not ok:
        failed += 1
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}{(' — ' + detail) if detail and not ok else ''}")


def read(path):
    try:
        return path.read_text()
    except OSError:
        return ""


# ---------------------------------------------------------------- version pins
print("== version pins ==")
packs = sorted((w / "packs" / "Microsoft.OpenHarmony.Sdk").glob("*"),
               key=lambda p: [int(x) if x.isdigit() else x for x in re.split(r"[.-]", p.name)])
newest = packs[-1].name if packs else "missing"
check(f"workload pack newest = {pins['workload']}", newest == pins["workload"], f"actual={newest}")
check(f"workload pack dir exists ({pins['workload']})",
      (w / "packs" / "Microsoft.OpenHarmony.Sdk" / pins["workload"]).is_dir())

manifests = sorted((w / "manifests").glob("*/microsoft.net.sdk.openharmony/WorkloadManifest.json"))
if not manifests:
    check("workload manifests found", False)
for m in manifests:
    try:
        version = json.loads(read(m)).get("version", "missing")
    except ValueError:
        version = "invalid-json"
    check(f"manifest {m.parent.parent.name} = {pins['workload']}",
          version == pins["workload"], f"actual={version}")

csproj = read(w / "test" / "maui-compat-app" / "maui-compat-app.csproj")
check(f"MAUI package = {pins['maui']}",
      bool(re.search(r'Include="Microsoft\.Maui\.Controls"\s+Version="' + re.escape(pins["maui"]) + r'"', csproj)))

try:
    dotnet = subprocess.run([os.environ.get("DOTNET", "dotnet"), "--list-sdks"],
                            capture_output=True, text=True, check=False)
    sdk_out = dotnet.stdout
except OSError:
    sdk_out = ""
check(f"SDK present = {pins['sdk']}", pins["sdk"] in sdk_out,
      "dotnet --list-sdks did not list it")

# ---------------------------------------------------------------- five repos
print("== five repos ==")
for name, cfg in pins.get("repos", {}).items():
    path = (w / cfg["path"]).resolve()
    if not (path / ".git").exists():
        print(f"  [SKIP] {name:<18} {path}")
        continue
    try:
        branch = subprocess.check_output(["git", "-C", str(path), "branch", "--show-current"],
                                         text=True).strip()
        tip = subprocess.check_output(["git", "-C", str(path), "rev-parse", "--short=12", "HEAD"],
                                      text=True).strip()
        dirty = len(subprocess.check_output(["git", "-C", str(path), "status", "--porcelain"],
                                            text=True).splitlines())
    except subprocess.CalledProcessError as exc:
        print(f"  [WARN] {name:<18} git failed: {exc}")
        continue
    ok = branch == cfg["branch"]
    note = "" if ok else f" (expected {cfg['branch']})"
    if dirty:
        note += f", dirty={dirty}"
    print(f"  [{'PASS' if ok else 'WARN'}] {name:<18} {branch} {tip}{note}")

# ---------------------------------------------------------------- CI slice refs
print("== CI slice refs (workflow_dispatch defaults) ==")
refs = {}
for wf in sorted((w / ".github" / "workflows").glob("*.yml")):
    for m in re.finditer(r"default:\s*'([0-9a-f]{7,40})'", read(wf)):
        refs.setdefault(m.group(1), []).append(wf.name)
for ref, wfs in sorted(refs.items()):
    print(f"  {ref}  {', '.join(sorted(set(wfs)))}")

# ---------------------------------------------------------------- checklist
print("== cutover checklist (human-driven; see the runbook) ==")
steps = [
    "1. RTM artifacts published (SDK/workload/MAUI packages); rc2-official-watch.sh or release notes confirm.",
    "2. Freeze builds and the device; .device-lock must be free. Keep kit #58 artifacts for rollback.",
    "3. Update five repo pins and this JSON; update manifests/packs, MAUI package, CI maui_ohos_ref.",
    "4. Rebuild packs and shell abc (hvigor defaults to --jitless); no content drift for the shell.",
    "5. Run scripts/p0-gate.sh --quick, then --full (IL budgets); cut-kit dry-run.",
    "6. Device round: kit install, cold start, deep links, second ability, perf metrics -> --metrics.",
    "7. Cut kit #59, verify-kit, checksums, release notes; then unfreeze.",
]
for step in steps:
    print("  " + step)

print("== summary ==")
if failed:
    print(f"RTM dry-run: {failed} hard pin(s) failed")
    sys.exit(1)
print("RTM dry-run: PASS (version pins match; repo/CI differences are informational)")
PY
rc=$?
exit "$rc"
