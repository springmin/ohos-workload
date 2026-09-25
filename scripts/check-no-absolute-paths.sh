#!/bin/sh
# check-no-absolute-paths.sh - reject machine-specific absolute source paths in build inputs.
#
# The audit's V3 finding: the two test projects carried /storage/Users/<user>/... fallbacks, so a
# checkout in any other location silently resolved the wrong sources (or failed obscurely). Build
# inputs must resolve from the repository (test/Directory.Build.props relative roots) or from
# explicit environment/CI values.
#
# Scope: tracked build files (*.csproj, *.props, *.targets, *.proj, *.sln, *.slnx), scripts and
# GitHub workflows. Device paths (e.g. /data/storage/... inside a test's expected URI) are not
# affected: the patterns target a builder's home directory.
#
#   scripts/check-no-absolute-paths.sh              scan the tracked build inputs
#   scripts/check-no-absolute-paths.sh <file>...    scan explicit files (selftest fixtures)
#
# Exit: 0 = clean; 1 = at least one hit; 2 = bad usage.
set -u

W="$(cd "$(dirname "$0")/.." && pwd)"
PATTERN='/storage/Users/|/home/[A-Za-z0-9._-]+/(springsources|src|work|repos)|[A-Za-z]:\\Users\\'

if [ $# -gt 0 ]; then
    FILES=""
    for f in "$@"; do
        [ -f "$f" ] || { echo "not a file: $f" >&2; exit 1; }
        FILES="$FILES $f"
    done
else
    # The gate and its selftest carry the rejected patterns as fixture data/comments, so the
    # default scan excludes those two files; the explicit-file mode used by the selftest does not.
    FILES="$(cd "$W" && git ls-files -- '*.csproj' '*.props' '*.targets' '*.proj' '*.sln' '*.slnx' '*.fsproj' '*.vbproj' 'scripts/*.sh' '.github/workflows/*.yml' '.github/workflows/*.yaml' 2>/dev/null \
        | grep -vE '^scripts/(check-no-absolute-paths|selftest-repo-hygiene)\.sh$' || true)"
fi

[ -n "$FILES" ] || { echo "no build input files found" >&2; exit 1; }

COUNT=0
HITS=0
for f in $FILES; do
    COUNT=$((COUNT + 1))
    case "$f" in
        /*) path="$f" ;;
        *) path="$W/$f"; [ -f "$path" ] || path="$f" ;;
    esac
    [ -f "$path" ] || { echo "WARN: skipping missing $f" >&2; continue; }
    if grep -nE "$PATTERN" "$path" > /dev/null 2>&1; then
        grep -nE "$PATTERN" "$path" | sed "s|^|$f:|" >&2
        HITS=$((HITS + 1))
    fi
done

if [ "$HITS" -gt 0 ]; then
    echo "absolute-path check FAILED: $HITS file(s) of $COUNT carry a machine-specific home path" >&2
    echo "  resolve them relative to the repository (test/Directory.Build.props) or from an env/CI value" >&2
    exit 1
fi
echo "absolute-path check OK: $COUNT build input file(s) carry no machine-specific home path"
