#!/bin/sh
# rc2-official-watch.sh - poll nuget.org / GitHub for the official MAUI rc.2+ packages (RC2-WATCH).
#
# Why: the pinned maui-ohos slice still carries Microsoft.Maui.* 11.0.0-rc.2.26478.12, a
# dnceng dotnet11 daily (docs/rc2-line-notes.md), and the interaction/pixel workflows still add
# the dnceng feed. The pin-switch batch in
# runtime-ohos/docs/plans/2026-09-30-rc2-mainline-adoption.md section 8 is unblocked only when
# an official rc.2 - or any later version - of the slice's packages is on nuget.org.
#
# Sources (both are queried on every run):
#   1. the nuget.org flat-container index of every package the slice references;
#   2. the dotnet/maui releases API (official release tags).
# A version triggers when it compares >= the watch baseline on its line (nuget: 11.0.0-rc.2,
# GitHub: 11.0.100-rc.2), so a later rc and a stable 11.x release trigger too.
#
# Usage: scripts/rc2-official-watch.sh [-h|--help]
# Env: RC2_WATCH_TIMEOUT=<seconds>       per-request curl timeout (default 30)
#      RC2_WATCH_NUGET_API=<base-url>    default https://api.nuget.org/v3-flatcontainer
#      RC2_WATCH_GITHUB_API=<base-url>   default https://api.github.com
#      RC2_WATCH_ADOPTION_DOC=<path>     override the section-8 doc path in the trigger block
# Exit: 0 = no official rc.2+ yet (keep waiting); 10 = official rc.2+ found (run the pin batch);
#       1 = every source failed; 2 = usage error.
set -u

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

usage() {
    cat <<'EOF'
usage: scripts/rc2-official-watch.sh

Polls nuget.org and the dotnet/maui releases for official rc.2+ MAUI packages. Exit 0 = no
rc.2+ yet (keep waiting), 10 = rc.2+ found (run the pin-switch batch in
runtime-ohos/docs/plans/2026-09-30-rc2-mainline-adoption.md section 8), 1 = every source
failed, 2 = usage error.
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) warn "unknown argument: $1"; usage >&2; exit 2 ;;
esac

W="$(cd "$(dirname "$0")/.." && pwd)"
TIMEOUT="${RC2_WATCH_TIMEOUT:-30}"
NUGET_API="${RC2_WATCH_NUGET_API:-https://api.nuget.org/v3-flatcontainer}"
GITHUB_API="${RC2_WATCH_GITHUB_API:-https://api.github.com}"
ADOPTION_DOC="${RC2_WATCH_ADOPTION_DOC:-$W/../runtime-ohos/docs/plans/2026-09-30-rc2-mainline-adoption.md}"
[ -f "$ADOPTION_DOC" ] && ADOPTION_DOC="$(cd "$(dirname "$ADOPTION_DOC")" && pwd)/$(basename "$ADOPTION_DOC")"
# The four packages the slice's standalone compile vehicle references (see the maui-ohos
# slice csproj); they ship in lockstep, so any of them reaching rc.2 is the signal.
PACKAGES="microsoft.maui.controls microsoft.maui.core microsoft.maui.graphics microsoft.aspnetcore.components.webview.maui"
NUGET_BASELINE="11.0.0-rc.2"
GITHUB_BASELINE="11.0.100-rc.2"

for _t in curl awk grep sed tr mktemp; do
    command -v "$_t" >/dev/null 2>&1 || { warn "required command not found: $_t"; exit 1; }
done

TMP="$(mktemp -d 2>/dev/null || true)"
[ -n "$TMP" ] || TMP="$(mktemp -d /data/storage/el2/base/tmp/opencode/rc2-watch.XXXXXX 2>/dev/null || true)"
[ -n "$TMP" ] || { warn "cannot create a temp dir"; exit 1; }
trap 'rm -rf "$TMP"' 0 1 2 3 15

# Version comparator: major.minor.patch then stage (preview < rc < stable) then stage number.
# 11.0.0-rc.2.26478.12 >= 11.0.0-rc.2, 11.0.0-rc.1.26451.6 < 11.0.0-rc.2, 11.0.100 = stable.
cat > "$TMP/vcmp.awk" <<'AWK'
function vcmp(a, b,   A, B, i, ra, rb, na, nb) {
    split(a, A, /[.-]/); split(b, B, /[.-]/)
    for (i = 1; i <= 3; i++) {
        if ((A[i] + 0) > (B[i] + 0)) return 1
        if ((A[i] + 0) < (B[i] + 0)) return -1
    }
    ra = (A[4] == "") ? 2 : ((A[4] == "rc") ? 1 : 0)
    rb = (B[4] == "") ? 2 : ((B[4] == "rc") ? 1 : 0)
    if (ra != rb) return (ra > rb) ? 1 : -1
    na = (A[5] == "") ? 0 : A[5] + 0
    nb = (B[5] == "") ? 0 : B[5] + 0
    if (na != nb) return (na > nb) ? 1 : -1
    return 0
}
mode == "ge" && NR == 1 { print (vcmp($1, base) >= 0) ? "yes" : "no"; exit }
mode == "max" && $1 != "" { if (!seen || vcmp($1, max) > 0) { max = $1; seen = 1 } }
END { if (mode == "max" && seen) print max }
AWK

fetch() { # <url> <outfile>
    curl -fsSL --retry 2 --retry-delay 2 --connect-timeout "$TIMEOUT" -m "$TIMEOUT" "$1" -o "$2" 2>/dev/null
}
max_ver()  { awk -f "$TMP/vcmp.awk" -v mode=max; }
triggers() { printf '%s\n' "$1" | awk -f "$TMP/vcmp.awk" -v mode=ge -v base="$2"; }

FOUND=0
NUGET_OK=0
GITHUB_OK=0

log "rc2-official-watch - official MAUI rc.2+ poll"
log "baselines: nuget $NUGET_BASELINE / github $GITHUB_BASELINE"
log "nuget.org (flat-container indexes):"
for pkg in $PACKAGES; do
    f="$TMP/$pkg.json"
    if fetch "$NUGET_API/$pkg/index.json" "$f"; then
        NUGET_OK=1
        latest="$(grep -o '"[0-9][^"]*"' "$f" | tr -d '"' | max_ver)"
        if [ -n "$latest" ]; then
            hit="$(triggers "$latest" "$NUGET_BASELINE")"
            [ "$hit" = yes ] && FOUND=1
            printf '   %-46s latest=%s trigger=%s\n' "$pkg" "$latest" "$hit"
        else
            printf '   %-46s no version parsed\n' "$pkg"
        fi
    else
        warn "   $pkg: fetch failed"
    fi
done

log "github.com/dotnet/maui releases:"
f="$TMP/maui-releases.json"
if fetch "$GITHUB_API/repos/dotnet/maui/releases" "$f"; then
    GITHUB_OK=1
    latest_tag="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | max_ver)"
    if [ -n "$latest_tag" ]; then
        hit="$(triggers "$latest_tag" "$GITHUB_BASELINE")"
        [ "$hit" = yes ] && FOUND=1
        printf '   %-46s latest=%s trigger=%s\n' "dotnet/maui latest release" "$latest_tag" "$hit"
    else
        printf '   %-46s no tag parsed\n' "dotnet/maui latest release"
    fi
else
    warn "   dotnet/maui releases: fetch failed"
fi

if [ "$FOUND" = 1 ]; then
    cat <<EOF

********************************************************************************
RC2-WATCH TRIGGER: an official MAUI rc.2+ version is published.
********************************************************************************
Run the pin-switch batch (section 8 of the adoption record):
  $ADOPTION_DOC

  1. advance MAUI_OHOS_REF in interaction-regression.yml / pixel-regression.yml /
     host-export-contract.yml to a maui-ohos commit built on the official packages;
  2. drop the dnceng dotnet11 feed step in the interaction/pixel workflows;
  3. re-run the gates (ohos-workload CI 5/5 + the local suite per the record);
  4. record the switch in docs/rc2-line-notes.md;
  5. rollback = revert the pin and the feed step together (rc.1 line stays untouched).
EOF
    exit 10
fi

if [ "$NUGET_OK" = 0 ] && [ "$GITHUB_OK" = 0 ]; then
    warn "every poll source failed; the watch result is unknown"
    exit 1
fi

log "status: WAIT - no official rc.2+ yet (nuget rc.1 only); keep waiting"
exit 0
