#!/bin/sh
# Prints a Markdown changelog for an OpenHarmony platform workload release.
#
# Invocation:
#
#   scripts/release-notes.sh [--version <ver>] [--since <tag-or-commit>] [--repo <path>]
#
#   --version  Version in the H1. Default: the manifest version of the SDK_BAND band
#              (default 11.0.100-rc.1), else the newest local `workload-<version>` tag, else
#              the title carries no version.
#   --since    Ref whose commits are listed (range `<ref>..HEAD`). Default: the newest
#              local `workload-<version>` tag reachable from HEAD that is not the version
#              being released; without one the full history is listed with a note (run
#              `git fetch --tags` first when publishing from a fresh clone).
#   --repo     Repository root. Default: the parent directory of this script.
#
# Output: an H1 with the version (when known), a one-line range note, one H2 per
# Conventional Commits type in the order feat, fix, docs, ci, test, release, other with
# `- `<short-hash>` <subject>` lines, and an "Artifact digests" section when
# dist/SHA256SUMS exists (hashes kept, basenames shown to avoid host paths). Merge commits
# are omitted; unknown conventional types (chore, refactor, perf, a scoped area name, ...)
# land under `other`.
#
# Used by scripts/publish-workload-release.sh as the body of the versioned release notes
# when this file is present; that script falls back to its static notes otherwise.
set -eu

W="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=""
SINCE=""

die() { printf 'release-notes: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --version) [ $# -ge 2 ] || die "--version needs a value"; shift; VERSION="$1" ;;
        --since) [ $# -ge 2 ] || die "--since needs a value"; shift; SINCE="$1" ;;
        --repo) [ $# -ge 2 ] || die "--repo needs a value"; shift; W="$1" ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

[ -d "$W" ] || die "repository root not found: $W"
command -v git >/dev/null 2>&1 || die "git not found"
cd "$W"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$W is not a git working tree"

# Default version: manifest -> local workload tag -> none.
if [ -z "$VERSION" ]; then
    MANIFEST="$W/manifests/${SDK_BAND:-11.0.100-rc.1}/microsoft.net.sdk.openharmony/WorkloadManifest.json"
    if [ -f "$MANIFEST" ]; then
        VERSION="$(python3 -c "import json;print(json.load(open('$MANIFEST'))['version'])" 2>/dev/null || true)"
    fi
    if [ -z "$VERSION" ]; then
        VERSION="$(git describe --tags --match 'workload-[0-9]*' --abbrev=0 2>/dev/null || true)"
        VERSION="${VERSION#workload-}"
    fi
fi

# Default range: newest local versioned workload tag that is not the version being released.
if [ -z "$SINCE" ]; then
    if [ -n "$VERSION" ] && git rev-parse --verify --quiet "workload-$VERSION" >/dev/null; then
        SINCE="$(git describe --tags --match 'workload-[0-9]*' --exclude "workload-$VERSION" --abbrev=0 HEAD 2>/dev/null || true)"
    else
        SINCE="$(git describe --tags --match 'workload-[0-9]*' --abbrev=0 HEAD 2>/dev/null || true)"
    fi
fi

if [ -n "$SINCE" ]; then
    git rev-parse --verify --quiet "$SINCE^{commit}" >/dev/null || die "unknown --since ref: $SINCE"
    RANGE="$SINCE..HEAD"
    RANGE_NOTE="Commits since \`$SINCE\`"
else
    RANGE="HEAD"
    RANGE_NOTE="Full history (no local \`workload-<version>\` tag found; pass --since <ref> or run \`git fetch --tags\`)"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
GROUPS="feat fix docs ci test release other"
for g in $GROUPS; do : > "$TMP/$g"; done

git log --no-merges --pretty=format:'%h%x09%s' "$RANGE" > "$TMP/log"

while IFS="$(printf '\t')" read -r h s || [ -n "${h:-}" ]; do
    [ -n "${h:-}" ] || continue
    t="${s%%:*}"
    case "$t" in *"("* ) t="$(printf '%s\n' "$t" | sed 's/(.*//')" ;; esac
    case "$t" in *"!"*) t="${t%!}" ;; esac
    case "$t" in
        feat|feature|features) g=feat ;;
        fix|fixes|bugfix|hotfix) g=fix ;;
        docs|doc|documentation) g=docs ;;
        ci) g=ci ;;
        test|tests) g=test ;;
        release|rel) g=release ;;
        *) g=other ;;
    esac
    printf -- '- `%s` %s\n' "$h" "$s" >> "$TMP/$g"
done < "$TMP/log"

if [ -n "$VERSION" ]; then
    printf '# OpenHarmony platform workload %s\n\n' "$VERSION"
else
    printf '# OpenHarmony platform workload release notes\n\n'
fi
COUNT="$(git rev-list --no-merges --count "$RANGE")"
printf '_%s: %s commits (merge commits omitted)._\n' "$RANGE_NOTE" "$COUNT"

for g in $GROUPS; do
    if [ -s "$TMP/$g" ]; then
        printf '\n## %s\n\n' "$g"
        cat "$TMP/$g"
    fi
done

if [ -f "$W/dist/SHA256SUMS" ]; then
    printf '\n## Artifact digests\n\n'
    printf '_From `dist/SHA256SUMS` (basenames shown):_\n\n'
    printf '```text\n'
    sed 's|^\([0-9a-fA-F]\{1,\}\)  .*/|\1  |' "$W/dist/SHA256SUMS"
    printf '```\n'
fi
