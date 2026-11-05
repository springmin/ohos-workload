#!/bin/sh
# watch-maui-rtm.sh - poll the stable/RTM artifacts MAUI on OpenHarmony needs.
#
# Unlike rc2-official-watch.sh (which tracks the rc.2 line), this watches for the RTM set:
#   * Microsoft.Maui.* stable 11.0.0 on nuget.org;
#   * .NET SDK 11.0.100 stable and .NET runtime 11.0.0 stable;
#   * OpenHarmony runtime/SDK RTM releases in springmin/runtime-ohos and springmin/sdk-ohos;
#   * an RTM OpenHarmony workload (preview.32+ or stable) for the kit.
#
# Exit: 0 = not ready (keep waiting); 10 = the MAUI + .NET + OpenHarmony RTM set is ready;
#       1 = every relevant source failed; 2 = usage error.
#
# Usage: scripts/watch-maui-rtm.sh
set -u

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

usage() {
    cat <<'EOF'
usage: scripts/watch-maui-rtm.sh

Polls NuGet and GitHub for the RTM set: MAUI stable 11.0.0, .NET SDK 11.0.100,
.NET runtime 11.0.0, OpenHarmony runtime/SDK RTM, and an RTM workload (preview.32+).
Exit 0 = wait, 10 = ready, 1 = all sources failed, 2 = usage error.
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) warn "unknown argument: $1"; usage >&2; exit 2 ;;
esac

for _t in curl python3 mktemp; do
    command -v "$_t" >/dev/null 2>&1 || { warn "required command not found: $_t"; exit 1; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/maui-rtm-watch.XXXXXX" 2>/dev/null || true)"
[ -n "$TMP" ] || { warn "cannot create a temp dir"; exit 1; }
trap 'rm -rf "$TMP"' 0 1 2 15

fetch() { # <url> <out>
    curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 30 -m 30 "$1" -o "$2" 2>/dev/null
}

READY=1
FAILED=0
MISSING=""

check_nuget() { # <package> <label>
    _pkg=$1
    _label=$2
    _out="$TMP/nuget-$_pkg.json"
    if ! fetch "https://api.nuget.org/v3-flatcontainer/$_pkg/index.json" "$_out"; then
        warn "$_label: nuget fetch failed"
        FAILED=$((FAILED + 1))
        READY=0
        return
    fi
    _v=$(python3 - "$_out" <<'PY'
import json, re, sys
try:
    versions = json.load(open(sys.argv[1]))["versions"]
except Exception:
    print("")
    raise SystemExit(0)
stable = [v for v in versions if re.fullmatch(r"11\.0\.0", v)]
print(stable[-1] if stable else "")
PY
)
    if [ -n "$_v" ]; then
        printf '   %-38s %s\n' "$_label" "$_v"
    else
        printf '   %-38s WAIT\n' "$_label"
        READY=0
        MISSING="$MISSING $_label"
    fi
}

check_github_stable() { # <owner/repo> <label> <regex>
    _repo=$1
    _label=$2
    _re=$3
    _out="$TMP/gh-$(echo "$_repo" | tr '/' '-').json"
    if ! fetch "https://api.github.com/repos/$_repo/releases?per_page=30" "$_out"; then
        warn "$_label: github fetch failed"
        FAILED=$((FAILED + 1))
        READY=0
        return
    fi
    _tag=$(python3 - "$_out" "$_re" <<'PY'
import json, re, sys
try:
    rel = json.load(open(sys.argv[1]))
except Exception:
    print("")
    raise SystemExit(0)
pat = re.compile(sys.argv[2])
for r in rel:
    tag = r.get("tag_name", "")
    if pat.fullmatch(tag):
        print(tag)
        break
PY
)
    if [ -n "$_tag" ]; then
        printf '   %-38s %s\n' "$_label" "$_tag"
    else
        printf '   %-38s WAIT\n' "$_label"
        READY=0
        MISSING="$MISSING $_label"
    fi
}

check_workload() {
    _out="$TMP/gh-sdk-ohos-workload.json"
    if ! fetch "https://api.github.com/repos/springmin/sdk-ohos/releases?per_page=50" "$_out"; then
        warn "OpenHarmony workload: github fetch failed"
        FAILED=$((FAILED + 1))
        READY=0
        return
    fi
    _tag=$(python3 - "$_out" <<'PY'
import json, re, sys
try:
    rel = json.load(open(sys.argv[1]))
except Exception:
    print("")
    raise SystemExit(0)
best = ("", -1)
for r in rel:
    tag = r.get("tag_name", "")
    m = re.fullmatch(r"workload-1\.0\.0-preview\.(\d+)", tag)
    if m and int(m.group(1)) > best[1]:
        best = (tag, int(m.group(1)))
    if re.fullmatch(r"workload-1\.0\.0", tag):
        best = (tag, 9999)
        break
print(best[0])
PY
)
    if [ -n "$_tag" ]; then
        _n=$(printf '%s' "$_tag" | sed -n 's/.*preview\.\([0-9][0-9]*\)$/\1/p')
        case "$_tag" in
            workload-1.0.0) _ok=1 ;;
            *) [ "${_n:-0}" -ge 32 ] && _ok=1 || _ok=0 ;;
        esac
        if [ "$_ok" = 1 ]; then
            printf '   %-38s %s\n' "OpenHarmony workload RTM" "$_tag"
        else
            printf '   %-38s %s (want preview.32+)\n' "OpenHarmony workload RTM" "$_tag"
            READY=0
            MISSING="$MISSING workload"
        fi
    else
        printf '   %-38s WAIT\n' "OpenHarmony workload RTM"
        READY=0
        MISSING="$MISSING workload"
    fi
}

log "MAUI / OpenHarmony RTM watch"
check_nuget "microsoft.maui.controls" "MAUI Controls stable 11.0.0"
check_nuget "microsoft.netcore.app.ref" ".NET runtime stable 11.0.0"
check_github_stable "dotnet/maui" "dotnet/maui stable release" "v?11\\.0\\.0"
check_github_stable "dotnet/sdk" ".NET SDK stable 11.0.100" "v?11\\.0\\.100"
check_github_stable "springmin/runtime-ohos" "OpenHarmony runtime RTM" "v11\\.0\\.0-openharmony"
check_github_stable "springmin/sdk-ohos" "OpenHarmony SDK RTM" "v11\\.0\\.100-openharmony"
check_workload

if [ "$READY" = 1 ]; then
    log "RTM READY — update rtm-pins.json, rebase the MAUI slice, run p0-gate/smoke, then cut kit #59"
    exit 10
fi
if [ "$FAILED" -ge 7 ]; then
    warn "every RTM watch source failed; result unknown"
    exit 1
fi
log "status: WAIT — missing:${MISSING}"
exit 0
