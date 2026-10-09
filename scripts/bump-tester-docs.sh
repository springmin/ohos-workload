#!/bin/sh
# bump-tester-docs.sh - mechanical kit-number bump for the tester-docs wave contract that
# scripts/cut-kit.sh validates in P0 (the "current block" gate).
#
# For kit <N> the helper rewrites, across the 18 tester docs + docs/plans/README.md:
#   * every "current block" marker `kit #M，当前）` / `kit #M — current)` (the exact shapes
#     cut-kit.sh P0 matches) from the old kit M to N - all markers in a doc must agree, a
#     missing/ambiguous marker or a downgrade (M > N) refuses;
#   * each doc must carry the current shell abc (plain A or grouped A,B); --abc pins it,
#     otherwise the default EXPECT_ABC of scripts/verify-kit.sh is used;
#   * README.md gets its top `kit #N 日期口径` line (the cut-kit index rule); current markers
#     inside README are normalized the same way as in the docs.
#
# Idempotent: a second run with the same --kit reports "already at kit #N" and writes nothing.
# Fail-closed / transactional: any missing file, ambiguous marker or missing abc aborts the
# whole wave before the first write; on an apply error the files already written are restored
# from the backups. --dry-run prints the plan and writes nothing. Writes by default (cut-kit.sh
# P0 --bump-docs calls it without extra flags).
#
# Usage:
#   sh scripts/bump-tester-docs.sh --kit <N> [--abc <A[,B]>] [--docs-dir <dir>]
#                                  [--dry-run] [--quiet] [-h|--help]
#
# Env: CUT_KIT_DOCS_DIR   docs-dir fallback (then ../runtime-ohos/docs/plans, then
#                         $HOME/springsources/runtime-ohos/docs/plans).
# Exit: 0 = bumped (or already current / dry-run plan); 1 = refused or an error occurred;
#       2 = usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OW_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
CUT_KIT="$SCRIPT_DIR/cut-kit.sh"

log()  { [ "${QUIET:-0}" = 1 ] || printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
err()  { printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { err "$*"; exit "${2:-1}"; }

usage() {
    sed -n '2,/^set -u$/p' "$0" | sed '/^set -u$/d' | sed 's/^# \{0,1\}//'
}

# ------------------------------------------------------------------------- options
KIT=""
ABC=""
DOCS_DIR=""
DRY=0
QUIET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --kit)      shift; [ $# -ge 1 ] || die "--kit needs a value" 2; KIT="$1" ;;
        --abc)      shift; [ $# -ge 1 ] || die "--abc needs a value" 2; ABC="$1" ;;
        --docs-dir) shift; [ $# -ge 1 ] || die "--docs-dir needs a dir" 2; DOCS_DIR="$1" ;;
        --dry-run)  DRY=1 ;;
        --quiet)    QUIET=1 ;;
        -h|--help)  usage; exit 0 ;;
        *) err "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
    shift
done
[ -n "$KIT" ] || die "--kit <N> is required" 2
case "$KIT" in ''|*[!0-9]*) die "--kit must be a number, got: $KIT" 2 ;; esac
[ "$KIT" -gt 1 ] 2>/dev/null || die "--kit must be > 1" 2

# The 18-doc list is owned by cut-kit.sh (single source of truth for the docs gate).
[ -f "$CUT_KIT" ] || die "cut-kit.sh not found next to this helper: $CUT_KIT"
DOC_LIST="$(sed -n '/^docs_wave_list()/,/^EOF/p' "$CUT_KIT" | sed -n '/^[0-9]/p')"
[ -n "$DOC_LIST" ] || die "cannot parse docs_wave_list from $CUT_KIT"
DOC_COUNT="$(printf '%s\n' "$DOC_LIST" | grep -c .)"

# docs dir: --docs-dir > CUT_KIT_DOCS_DIR > sibling runtime-ohos > canonical checkout.
if [ -z "$DOCS_DIR" ]; then
    if [ -n "${CUT_KIT_DOCS_DIR:-}" ]; then
        DOCS_DIR="$CUT_KIT_DOCS_DIR"
    elif [ -d "$OW_REPO/../runtime-ohos/docs/plans" ]; then
        DOCS_DIR="$OW_REPO/../runtime-ohos/docs/plans"
    elif [ -d "$HOME/springsources/runtime-ohos/docs/plans" ]; then
        DOCS_DIR="$HOME/springsources/runtime-ohos/docs/plans"
    fi
fi
[ -n "$DOCS_DIR" ] && [ -d "$DOCS_DIR" ] || \
    die "docs dir not found: ${DOCS_DIR:-<unresolved>} (pass --docs-dir / set CUT_KIT_DOCS_DIR)"

# abc: --abc wins; else the verify-kit.sh default (same parse as cut-kit.sh expect_abc).
if [ -z "$ABC" ] && [ -f "$SCRIPT_DIR/verify-kit.sh" ]; then
    ABC="$(sed -n 's/^EXPECT_ABC="\${KIT_EXPECTED_ABC:-\(.*\)}"/\1/p' "$SCRIPT_DIR/verify-kit.sh" | head -n 1)"
fi
ABC_UI="${ABC%%,*}"
[ -n "$ABC_UI" ] || die "no shell abc: pass --abc <A[,B]> or set EXPECT_ABC in $SCRIPT_DIR/verify-kit.sh"
case "$ABC_UI" in *[!0-9]*) die "abc must be numeric, got: $ABC_UI" 2 ;; esac
abc_forms() { # plain + thousands-grouped (the cut-kit.sh gate checks both)
    _p="$1"
    _c="$(printf '%s' "$_p" | sed -e 's/^\([0-9]\{1,\}\)\([0-9][0-9][0-9]\)$/\1,\2/')"
    printf '%s\n' "$_p"
    [ "$_c" != "$_p" ] && printf '%s\n' "$_c"
    return 0
}
ABC_COMMA="$(abc_forms "$ABC_UI" | tail -n 1)"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/bump-tester-docs.XXXXXX" 2>/dev/null)" || die "cannot create a temp dir"
trap 'rm -rf "$TMPD"' 0 1 2 3 15
: > "$TMPD/plan"       # "file|candidate" lines for files that need a write
: > "$TMPD/issues"     # one line per refused file

# ------------------------------------------------------------------------- primitives
marker_kits() { # <file> -> sorted unique kit numbers of the current-block markers
    grep -oE 'kit #[0-9]+，当前[）)]|kit #[0-9]+ — current[）)]' "$1" 2>/dev/null \
        | sed 's/kit #\([0-9][0-9]*\).*/\1/' | sort -u
}
rewrite_markers() { # <file> -> stdout with every current marker renumbered to $KIT
    sed -e "s/kit #\([0-9][0-9]*\)，当前）/kit #$KIT，当前）/g" \
        -e "s/kit #\([0-9][0-9]*\) — current)/kit #$KIT — current)/g" "$1"
}
abc_ok() { # <file> -> 0 when the ui abc is present in any accepted form
    for _form in $(abc_forms "$ABC_UI"); do
        grep -qF "$_form" "$1" 2>/dev/null && return 0
    done
    return 1
}
issue() { printf '%s\n' "$1" >> "$TMPD/issues"; err "$1"; }

# process_wave_doc <file> <label>: validates and stages the candidate when a bump is needed.
process_wave_doc() {
    _f="$1"; _label="$2"
    if [ ! -f "$_f" ]; then issue "$_label: missing"; return; fi
    _kits="$(marker_kits "$_f")"
    _n="$(printf '%s\n' "$_kits" | grep -c .)"
    if [ "$_n" = 0 ]; then
        issue "$_label: no 'kit #N，当前）' / 'kit #N — current)' marker"
        return
    fi
    if [ "$_n" != 1 ]; then
        issue "$_label: ambiguous current markers [$(printf '%s' "$_kits" | tr '\n' ' ' | sed 's/ $//')]"
        return
    fi
    _k="$_kits"
    if [ "$_k" -gt "$KIT" ]; then
        issue "$_label: refuses kit #$_k -> #$KIT (downgrade)"
        return
    fi
    _cand="$TMPD/cand.$(printf '%s' "$_label" | tr -c 'A-Za-z0-9._' '_')"
    if [ "$_k" = "$KIT" ]; then
        cp "$_f" "$_cand" || { issue "$_label: cannot stage"; return; }
        [ "$QUIET" = 1 ] || printf '   keep %s: already kit #%s\n' "$_label" "$KIT"
    else
        rewrite_markers "$_f" > "$_cand" || { issue "$_label: rewrite failed"; return; }
        _mk="$(marker_kits "$_cand")"
        [ "$_mk" = "$KIT" ] || { issue "$_label: rewrite did not converge (got [$_mk])"; return; }
        printf '%s|%s\n' "$_f" "$_cand" >> "$TMPD/plan"
        [ "$QUIET" = 1 ] || printf '   bump %s: kit #%s -> #%s (%s marker(s))\n' \
            "$_label" "$_k" "$KIT" "$(grep -cE 'kit #[0-9]+，当前[）)]|kit #[0-9]+ — current[）)]' "$_f")"
    fi
    abc_ok "$_cand" || issue "$_label: missing the current shell abc $ABC_UI (plain) / $ABC_COMMA (grouped)"
}

# process_readme: the index rule of the cut-kit docs gate (kit #N 日期口径 + markers).
process_readme() {
    _f="$DOCS_DIR/README.md"; _label="README.md"
    if [ ! -f "$_f" ]; then issue "$_label: missing"; return; fi
    _cand="$TMPD/cand.README.md"
    _kits="$(marker_kits "$_f")"
    _n="$(printf '%s\n' "$_kits" | grep -c .)"
    if [ "$_n" -gt 1 ]; then
        issue "$_label: ambiguous current markers [$(printf '%s' "$_kits" | tr '\n' ' ' | sed 's/ $//')]"
        return
    fi
    if [ "$_n" = 1 ] && [ "$_kits" -gt "$KIT" ]; then
        issue "$_label: refuses kit #$_kits -> #$KIT (downgrade)"
        return
    fi
    if [ "$_n" = 1 ] && [ "$_kits" != "$KIT" ]; then
        rewrite_markers "$_f" > "$_cand" || { issue "$_label: rewrite failed"; return; }
    else
        cp "$_f" "$_cand" || { issue "$_label: cannot stage"; return; }
    fi
    # the top `kit #N 日期口径` line: bump the first bare occurrence
    if ! grep -qE "kit #$KIT[ ]*日期口径|当前口径 ?= kit #$KIT" "$_cand"; then
        awk -v n="$KIT" 'BEGIN { done = 0 }
            { if (!done && match($0, /kit #[0-9]+ 日期口径/)) {
                  sub(/kit #[0-9]+ 日期口径/, "kit #" n " 日期口径", $0); done = 1 } }
            { print }' "$_cand" > "$_cand.awk" || { issue "$_label: date-line rewrite failed"; return; }
        mv "$_cand.awk" "$_cand" || { issue "$_label: date-line stage failed"; return; }
    fi
    if ! grep -qE "kit #$KIT[ ]*日期口径|当前口径 ?= kit #$KIT" "$_cand"; then
        issue "$_label: no 'kit #$KIT 日期口径' line (and the first 'kit #M 日期口径' rewrite did not land)"
        return
    fi
    if cmp -s "$_f" "$_cand"; then
        [ "$QUIET" = 1 ] || printf '   keep %s: already kit #%s\n' "$_label" "$KIT"
    else
        printf '%s|%s\n' "$_f" "$_cand" >> "$TMPD/plan"
        [ "$QUIET" = 1 ] || printf '   bump %s: index date line -> kit #%s\n' "$_label" "$KIT"
    fi
}

# ------------------------------------------------------------------------- validate whole wave
log "bump-tester-docs: kit #$KIT (docs $DOCS_DIR; abc $ABC_UI/$ABC_COMMA; dry=$DRY)"
for _d in $DOC_LIST; do
    process_wave_doc "$DOCS_DIR/$_d" "$_d"
done
process_readme

if [ -s "$TMPD/issues" ]; then
    err "refusing the wave: $(grep -c . "$TMPD/issues") issue(s); no file was written"
    exit 1
fi

PLANNED="$(grep -c . "$TMPD/plan")"
if [ "$PLANNED" = 0 ]; then
    log "already at kit #$KIT ($DOC_COUNT docs + README unchanged)"
    exit 0
fi
if [ "$DRY" = 1 ]; then
    log "dry-run: $PLANNED file(s) would change; nothing written"
    exit 0
fi

# ------------------------------------------------------------------------- apply (rollback-capable)
_i=0
while IFS='|' read -r _f _c; do
    [ -n "$_f" ] || continue
    cp "$_f" "$TMPD/bak.$_i" 2>/dev/null || { err "backup failed: $_f"; exit 1; }
    _i=$((_i + 1))
done < "$TMPD/plan"
: > "$TMPD/applied"
_i=0
while IFS='|' read -r _f _c; do
    [ -n "$_f" ] || continue
    if ! cp "$_c" "$_f" 2>/dev/null; then
        err "write failed: $_f - rolling back"
        _j=0
        while IFS='|' read -r _rf _rc2; do
            [ -n "$_rf" ] || continue
            [ "$_j" -lt "$_i" ] || break
            cp "$TMPD/bak.$_j" "$_rf" 2>/dev/null || true
            _j=$((_j + 1))
        done < "$TMPD/plan"
        exit 1
    fi
    _i=$((_i + 1))
done < "$TMPD/plan"
log "bumped $PLANNED file(s) to kit #$KIT"
exit 0
