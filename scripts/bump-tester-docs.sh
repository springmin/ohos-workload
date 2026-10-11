#!/bin/sh
# bump-tester-docs.sh - mechanical kit-number + shell-abc bump for the tester-docs wave contract
# that scripts/cut-kit.sh validates in P0 (the "current block" gate).
#
# For kit <N> the helper rewrites, across the 18 tester docs + docs/plans/README.md:
#   * every "current block" marker `kit #M，当前）` / `kit #M — current)` (the exact shapes
#     cut-kit.sh P0 matches) from the old kit M to N - all markers in a doc must agree, a
#     missing/ambiguous marker or a downgrade (M > N) refuses;
#   * on exactly those renumbered lines, the current-shell abc references are refreshed to the
#     target EXPECT_ABC: `expected-abc A` / `重锚 **A,H**` / `re-anchored A,H` / `abc **A` /
#     `abc A` (the un-bolded second block) / `headless H` / `EXPECT_ABC=A,H` and the zh
#     `）**/H（` headless slot. Plain (576664) and thousands-grouped (576,664) forms are both
#     understood and the written style is kept per value; a pair refreshes ui+headless
#     together, while an `--abc A` without H leaves the headless references as written;
#   * README.md gets its top `kit #N 日期口径` line (the cut-kit index rule) and its abc bits
#     are refreshed on that line; current markers inside README are normalized like the docs.
#   * with --abc-sha <sha8>, the sha fragment written directly next to the current ui abc on
#     those same lines (`abc **A / `sha…`` and `abc **A（`sha…`）` styles, plain or grouped A)
#     is refreshed to <sha8>…; historical sha references stay; the headless sha is untouched,
#     and a doc whose current block has no adjacent ui-abc sha refuses the whole wave.
#   * every doc must end up carrying the current shell abc (plain A or grouped A,B); --abc
#     pins it, otherwise the default EXPECT_ABC of scripts/verify-kit.sh is used; a doc left
#     without any current abc refuses the whole wave.
#
# Scope: the abc refresh only ever edits the lines whose markers it renumbers (plus the README
# index line). Historical references such as `#52=534192` and any shape the helper does not
# recognize are left untouched.
#
# Idempotent: a second run with the same --kit reports "already at kit #N" and writes nothing.
# Fail-closed / transactional: any missing file, ambiguous marker, downgrade or missing abc
# aborts the whole wave before the first write; on an apply error the files already written are
# restored from the backups. --dry-run prints the plan and writes nothing. Writes by default
# (cut-kit.sh P0 --bump-docs calls it without extra flags).
#
# Usage:
#   sh scripts/bump-tester-docs.sh --kit <N> [--abc <A[,H]>] [--abc-sha <sha8>] [--docs-dir <dir>]
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
ABC_SHA=""
DOCS_DIR=""
DRY=0
QUIET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --kit)      shift; [ $# -ge 1 ] || die "--kit needs a value" 2; KIT="$1" ;;
        --abc)      shift; [ $# -ge 1 ] || die "--abc needs a value" 2; ABC="$1" ;;
        --abc-sha)  shift; [ $# -ge 1 ] || die "--abc-sha needs a value" 2; ABC_SHA="$1" ;;
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
# The value is `A` or `A,H` (ui [, headless]); both halves must be numeric.
if [ -z "$ABC" ] && [ -f "$SCRIPT_DIR/verify-kit.sh" ]; then
    ABC="$(sed -n 's/^EXPECT_ABC="\${KIT_EXPECTED_ABC:-\(.*\)}"/\1/p' "$SCRIPT_DIR/verify-kit.sh" | head -n 1)"
fi
ABC_UI="${ABC%%,*}"
ABC_HL=""
case "$ABC" in *,*) ABC_HL="${ABC#*,}" ;; esac
[ -n "$ABC_UI" ] || die "no shell abc: pass --abc <A[,H]> or set EXPECT_ABC in $SCRIPT_DIR/verify-kit.sh"
case "$ABC_UI" in *[!0-9]*) die "abc must be numeric, got: $ABC_UI" 2 ;; esac
if [ -n "$ABC_HL" ]; then
    case "$ABC_HL" in *[!0-9]*) die "headless abc must be numeric, got: $ABC_HL" 2 ;; esac
    ABC_MSG="$ABC_UI,$ABC_HL"
else
    ABC_MSG="$ABC_UI"
fi
# --abc-sha: optional 8-hex prefix of the shell abc sha (case-normalized to lowercase when set).
if [ -n "$ABC_SHA" ]; then
    case "$ABC_SHA" in *[!0-9a-fA-F]*) die "--abc-sha must be 8 hex digits, got: $ABC_SHA" 2 ;; esac
    [ "${#ABC_SHA}" = 8 ] || die "--abc-sha must be 8 hex digits, got: $ABC_SHA" 2
    ABC_SHA="$(printf '%s' "$ABC_SHA" | tr 'A-F' 'a-f')"
    ABC_MSG="$ABC_MSG sha $ABC_SHA"
fi
abc_forms() { # plain + thousands-grouped (the cut-kit.sh gate checks both)
    _p="$1"
    _c="$(printf '%s' "$_p" | sed -e 's/^\([0-9]\{1,\}\)\([0-9][0-9][0-9]\)$/\1,\2/')"
    printf '%s\n' "$_p"
    [ "$_c" != "$_p" ] && printf '%s\n' "$_c"
    return 0
}
ABC_COMMA="$(abc_forms "$ABC_UI" | tail -n 1)"

# Adjacent-sha patterns for the --abc-sha checks (target lines only, see sha_check):
#   <ui-abc><gap>`<sha>…`  with the zh （ and the en " / " gap styles.
ABC_SHA_UI_RE="$ABC_UI"
[ "$ABC_COMMA" != "$ABC_UI" ] && ABC_SHA_UI_RE="$ABC_UI|$ABC_COMMA"
SHA_NEW_RE="(${ABC_SHA_UI_RE})[ /（(]*\`${ABC_SHA}…\`"
SHA_ANY_RE="(${ABC_SHA_UI_RE})[ /（(]*\`[0-9a-f]+…\`"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/bump-tester-docs.XXXXXX" 2>/dev/null)" || die "cannot create a temp dir"
trap 'rm -rf "$TMPD"' 0 1 2 3 15
: > "$TMPD/plan"       # "file|candidate" lines for files that need a write
: > "$TMPD/issues"     # one line per refused file

# ------------------------------------------------------------------------- primitives
marker_kits() { # <file> -> sorted unique kit numbers of the current-block markers
    grep -oE 'kit #[0-9]+，当前[）)]|kit #[0-9]+ — current[）)]' "$1" 2>/dev/null \
        | sed 's/kit #\([0-9][0-9]*\).*/\1/' | sort -u
}
abc_ok() { # <file> -> 0 when the ui abc is present in any accepted form
    for _form in $(abc_forms "$ABC_UI"); do
        grep -qF "$_form" "$1" 2>/dev/null && return 0
    done
    return 1
}
issue() { printf '%s\n' "$1" >> "$TMPD/issues"; err "$1"; }

# sha_check <file> <doc|readme>: with --abc-sha, the target lines (current block / README date
# line) must carry the refreshed sha right next to the current ui abc, and no other adjacent sha.
sha_check() {
    _slf="$TMPD/shalines.$$.$2"
    if [ "$2" = readme ]; then
        grep -E "kit #$KIT[ ]*日期口径|当前口径 ?= kit #$KIT" "$1" 2>/dev/null > "$_slf"
    else
        grep -E "kit #$KIT，当前）|kit #$KIT — current\)" "$1" 2>/dev/null > "$_slf"
    fi
    if ! grep -qE "$SHA_NEW_RE" "$_slf"; then
        rm -f "$_slf"
        printf 'missing the current shell abc sha %s (no `%s…` adjacent to %s on a %s line)' \
            "$ABC_SHA" "$ABC_SHA" "$ABC_UI" "$2"
        return 1
    fi
    _bad="$(grep -oE "$SHA_ANY_RE" "$_slf" | grep -vE "^(${ABC_SHA_UI_RE})[ /（(]*\`${ABC_SHA}…\`$" | head -n 1)"
    rm -f "$_slf"
    if [ -n "$_bad" ]; then
        printf 'a sha adjacent to %s was not refreshed: %s' "$ABC_UI" "$_bad"
        return 1
    fi
    return 0
}

# The abc-aware rewriter lives in awk (toybox awk: no capture arrays): it runs only on the
# lines whose current marker it renumbers, keeps the plain/grouped writing style per value and
# leaves every unrecognized token alone.
ABC_AWK='
function group3(v,   out, n) {
    out = ""; n = length(v)
    while (n > 3) { out = "," substr(v, n - 2) out; v = substr(v, 1, n - 3); n = length(v) }
    return v out
}
function xform(tok, hlrole,   t, ui, hl, g1, g2, i, a) {
    if (tok == "") return ""
    t = tok; ui = ""; hl = ""; g1 = 0; g2 = 0
    if (t ~ /^[0-9]+$/) {
        ui = t
    } else if (t ~ /^[0-9]{1,3}(,[0-9]{3})+$/) {
        gsub(/,/, "", t); ui = t; g1 = 1
    } else if (t ~ /^[0-9]{4,},[0-9]{4,}$/) {
        i = index(t, ","); ui = substr(t, 1, i - 1); hl = substr(t, i + 1)
    } else if (t ~ /^[0-9]{1,3},[0-9]{3},[0-9]{4,}$/) {
        i = index(t, ",")
        ui = substr(t, 1, i - 1) substr(t, i + 1, 3); g1 = 1
        hl = substr(t, i + 5)
    } else if (t ~ /^[0-9]{1,3},[0-9]{3},[0-9]{1,3},[0-9]{3}$/) {
        split(t, a, ",")
        ui = a[1] a[2]; hl = a[3] a[4]; g1 = 1; g2 = 1
    } else {
        return ""
    }
    if (length(ui) < 4 || (hl != "" && length(hl) < 4)) return ""
    if (hl == "") {
        if (hlrole) return (nhl == "" ? "" : (g1 ? group3(nhl) : nhl))
        return (g1 ? group3(nui) : nui)
    }
    return (g1 ? group3(nui) : nui) "," (nhl != "" ? (g2 ? group3(nhl) : nhl) : (g2 ? group3(hl) : hl))
}
function rewr(s, ctx, tail, hlrole,   out, i, p, c, tok, nt, sep) {
    out = ""
    while ((i = index(s, ctx)) > 0) {
        out = out substr(s, 1, i + length(ctx) - 1)
        s = substr(s, i + length(ctx))
        p = 0; sep = ""; c = substr(s, p + 1, 1)
        while (c == " " || c == "\t" || c == "*" || c == "=" || c == "(" || c == "（") {
            sep = sep c; p++; c = substr(s, p + 1, 1)
        }
        tok = ""
        while (c ~ /^[0-9,]$/) { tok = tok c; p++; c = substr(s, p + 1, 1) }
        while (tok != "" && substr(tok, length(tok), 1) == ",") {
            tok = substr(tok, 1, length(tok) - 1); p--
        }
        nt = ""
        if (tok != "" && (tail == "" || substr(s, p + 1, length(tail)) == tail)) nt = xform(tok, hlrole)
        out = out sep (nt != "" ? nt : tok)
        s = substr(s, p + 1)
    }
    return out s
}
function shafix(tok,   p, c, h, j, c2) {
    # tok = line remainder right after an ui-abc occurrence; refresh `sha…` only when it is
    # directly adjacent (zh `（` / en ` / ` style gaps), leaving every other shape alone.
    if (nsha == "") return tok
    p = 0; c = substr(tok, p + 1, 1)
    while (c == " " || c == "\t" || c == "/" || c == "（" || c == "(") { p++; c = substr(tok, p + 1, 1) }
    if (c != "`") return tok
    j = p + 2; h = ""
    c2 = substr(tok, j, 1)
    while (c2 ~ /^[0-9a-fA-F]$/) { h = h c2; j++; c2 = substr(tok, j, 1) }
    if (h == "" || c2 != "…") return tok
    if (h == nsha) return tok
    return substr(tok, 1, p) "`" nsha substr(tok, j)
}
function shascan(s, form,   out, i) {
    out = ""
    while ((i = index(s, form)) > 0) {
        out = out substr(s, 1, i + length(form) - 1)
        s = substr(s, i + length(form))
        s = shafix(s)
    }
    return out s
}
function refresh_line(s) {
    s = rewr(s, "重锚 **", "", 0)
    s = rewr(s, "re-anchored ", "", 0)
    s = rewr(s, "EXPECT_ABC=", "", 0)
    s = rewr(s, "expected-abc", "", 0)
    s = rewr(s, "abc **", "", 0)
    s = rewr(s, "abc ", "", 0)
    s = rewr(s, "headless ", "", 1)
    s = rewr(s, "）**/", "（", 1)
    if (nsha != "") {
        s = shascan(s, nui)
        if (group3(nui) != nui) s = shascan(s, group3(nui))
    }
    return s
}
BEGIN { done = 0 }
{
    if (mode == "readme") {
        if (!done && $0 ~ /kit #[0-9]+ 日期口径/) {
            $0 = refresh_line($0)
            if (renum == 1) sub(/kit #[0-9]+ 日期口径/, "kit #" kit " 日期口径", $0)
            done = 1
        }
    } else if ($0 ~ /kit #[0-9]+，当前）|kit #[0-9]+ — current\)/) {
        $0 = refresh_line($0)
        gsub(/kit #[0-9]+，当前）/, "kit #" kit "，当前）", $0)
        gsub(/kit #[0-9]+ — current\)/, "kit #" kit " — current)", $0)
    }
    print
}
'

refresh_wave_file() { # <file> <doc|readme> <renum 0|1> -> stdout
    awk -v kit="$KIT" -v nui="$ABC_UI" -v nhl="$ABC_HL" -v nsha="$ABC_SHA" -v mode="$2" -v renum="$3" "$ABC_AWK" "$1"
}

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
    refresh_wave_file "$_f" doc 0 > "$_cand" || { issue "$_label: rewrite failed"; return; }
    _mk="$(marker_kits "$_cand")"
    [ "$_mk" = "$KIT" ] || { issue "$_label: rewrite did not converge (got [$_mk])"; return; }
    # the abc refresh must be its own fixed point (a second pass is a byte-level no-op)
    refresh_wave_file "$_cand" doc 0 > "$_cand.fp" || { issue "$_label: refresh failed"; return; }
    if ! cmp -s "$_cand" "$_cand.fp"; then
        issue "$_label: abc refresh is not a fixed point (unhandled shape?)"
        return
    fi
    if [ "$_k" = "$KIT" ] && cmp -s "$_f" "$_cand"; then
        [ "$QUIET" = 1 ] || printf '   keep %s: already kit #%s\n' "$_label" "$KIT"
    elif [ "$_k" = "$KIT" ]; then
        printf '%s|%s\n' "$_f" "$_cand" >> "$TMPD/plan"
        [ "$QUIET" = 1 ] || printf '   refresh %s: abc -> %s (kit #%s already)\n' "$_label" "$ABC_MSG" "$KIT"
    else
        printf '%s|%s\n' "$_f" "$_cand" >> "$TMPD/plan"
        [ "$QUIET" = 1 ] || printf '   bump %s: kit #%s -> #%s (abc -> %s; %s marker(s))\n' \
            "$_label" "$_k" "$KIT" "$ABC_MSG" "$(grep -cE 'kit #[0-9]+，当前[）)]|kit #[0-9]+ — current[）)]' "$_f")"
    fi
    abc_ok "$_cand" || issue "$_label: missing the current shell abc $ABC_UI (plain) / $ABC_COMMA (grouped)"
    if [ -n "$ABC_SHA" ]; then
        _smsg="$(sha_check "$_cand" doc)" || issue "$_label: $_smsg"
    fi
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
        refresh_wave_file "$_f" doc 0 > "$_cand" || { issue "$_label: rewrite failed"; return; }
    else
        cp "$_f" "$_cand" || { issue "$_label: cannot stage"; return; }
    fi
    # the top `kit #N 日期口径` line: renumber the first bare occurrence (when still missing)
    # and refresh its abc bits in the same pass
    _renum=1
    if grep -qE "kit #$KIT[ ]*日期口径|当前口径 ?= kit #$KIT" "$_cand"; then _renum=0; fi
    refresh_wave_file "$_cand" readme "$_renum" > "$_cand.date" || { issue "$_label: date-line rewrite failed"; return; }
    mv "$_cand.date" "$_cand" || { issue "$_label: date-line stage failed"; return; }
    if ! grep -qE "kit #$KIT[ ]*日期口径|当前口径 ?= kit #$KIT" "$_cand"; then
        issue "$_label: no 'kit #$KIT 日期口径' line (and the first 'kit #M 日期口径' rewrite did not land)"
        return
    fi
    if [ -n "$ABC_SHA" ]; then
        _smsg="$(sha_check "$_cand" readme)" || issue "$_label: $_smsg"
    fi
    if cmp -s "$_f" "$_cand"; then
        [ "$QUIET" = 1 ] || printf '   keep %s: already kit #%s\n' "$_label" "$KIT"
    else
        printf '%s|%s\n' "$_f" "$_cand" >> "$TMPD/plan"
        [ "$QUIET" = 1 ] || printf '   bump %s: index date line -> kit #%s (abc -> %s)\n' "$_label" "$KIT" "$ABC_MSG"
    fi
}

# ------------------------------------------------------------------------- validate whole wave
log "bump-tester-docs: kit #$KIT (docs $DOCS_DIR; abc $ABC_MSG; dry=$DRY)"
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
