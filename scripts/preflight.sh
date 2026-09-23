#!/bin/sh
# Local preflight for the ohos-workload repository: runs the same four gates CI runs, with a
# clear PASS/FAIL/SKIP per step and a summary at the end.
#
#   1. sh -n over scripts/*.sh                            (shell syntax of every repo script)
#   2. npx --yes markdownlint-cli2@0.23.3                 (.github/workflows/markdownlint.yml)
#   3. interaction suite, test/maui-platform-verify:      (.github/workflows/interaction-regression.yml)
#        dotnet build -m:1 + run bin/Debug/net11.0/verify.dll
#        requires exit 0, the suite's own "[suite] checks=... floor=... assert=True" contract
#        line (the floor is declared once in Program.cs; this script must not repeat a literal),
#        a grep count matching the suite-reported count, no "Unhandled" line, and both perf
#        markers (frame-path + a11y publish-path) reporting within=True
#   4. pixel suite, test/headless-render:                 (.github/workflows/pixel-regression.yml)
#        dotnet run -c Release, requires "PIXEL ASSERTIONS PASSED"
#
# The interaction suite is rebuilt from this working tree before it runs, so an older harness
# without the [suite] line makes the gate fail with a clear message instead of silently checking
# a stale threshold; there is deliberately no fallback literal.
#
# The suites need the build prerequisites CI materialises first (it checks out springmin/maui-ohos
# and builds the two hosting assemblies in Release); this script assumes the development machine
# already has them, but checks their usual locations and prints the commands when they are missing.
#
# Usage: scripts/preflight.sh [--skip-lint] [--skip-interaction] [--skip-pixel] [--quick]
#
#   --skip-lint         skip step 2 (markdownlint; also skipped when npx is not installed)
#   --skip-interaction  skip the test/maui-platform-verify suite
#   --skip-pixel        skip the test/headless-render suite
#   --quick             skip both suites (the fast gates: sh -n + markdownlint)
#
# Env: DOTNET (dotnet host, default: dotnet), PREFLIGHT_LOG_DIR (default: a fresh mktemp -d;
#      falls back to /data/storage/el2/base/tmp/opencode/preflight.<pid>). Logs are kept for
#      inspection and the path is printed at the start.
#
# Exit code: 0 = every non-skipped step passed; 1 = at least one step failed; 2 = bad usage.
# Arguments missing? Run with --skip-* to narrow, never to hide a failure.
set -u

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

W="$(cd "$(dirname "$0")/.." && pwd)"
DOTNET="${DOTNET:-dotnet}"
PROJ_INTERACTION="$W/test/maui-platform-verify"
PROJ_PIXEL="$W/test/headless-render"

SKIP_LINT=0
SKIP_INTERACTION=0
SKIP_PIXEL=0

usage() {
    cat <<EOF
usage: $0 [--skip-lint] [--skip-interaction] [--skip-pixel] [--quick]

Runs the CI gates locally: sh -n (scripts/*.sh), markdownlint-cli2 0.23.3, the
test/maui-platform-verify interaction suite and the test/headless-render pixel suite.
--quick skips both suites (same as --skip-interaction --skip-pixel).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-lint)        SKIP_LINT=1 ;;
        --skip-interaction) SKIP_INTERACTION=1 ;;
        --skip-pixel)       SKIP_PIXEL=1 ;;
        --quick)            SKIP_INTERACTION=1; SKIP_PIXEL=1 ;;
        -h|--help)          usage; exit 0 ;;
        *) warn "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
    shift
done

LOG_DIR="${PREFLIGHT_LOG_DIR:-}"
if [ -z "$LOG_DIR" ]; then
    LOG_DIR="$(mktemp -d 2>/dev/null || true)"
fi
if [ -z "$LOG_DIR" ]; then
    LOG_DIR="/data/storage/el2/base/tmp/opencode/preflight.$$"
fi
mkdir -p "$LOG_DIR" || { warn "cannot create log dir: $LOG_DIR"; exit 1; }

# status accumulators: PASS / FAIL / SKIP (+ a short detail for the summary)
ST_SH_N="SKIP"
ST_LINT="SKIP"
ST_INTERACTION="SKIP"
ST_PIXEL="SKIP"
FAILED=0

summary_line() { printf '   %-38s %s\n' "$1" "$2"; }

log "ohos-workload preflight"
log "repo:   $W"
log "logs:   $LOG_DIR"
[ "$SKIP_LINT$SKIP_INTERACTION$SKIP_PIXEL" = "111" ] && warn "every step is skipped; nothing will be verified"

# The suites compile the maui-ohos slice and reference two Release assemblies built from this
# repo (CI builds them up front). Their absence is not fatal here: the suite build reports the
# missing file anyway, but the commands to fix it are worth printing.
prereq_hints() {
    SLICE="${MAUI_SLICE_DIR:-/storage/Users/currentUser/springsources/maui-ohos/src/Core/src/Platform/OpenHarmony}"
    HOST_DLL="${HOSTING_DLL:-$W/src/Microsoft.OpenHarmony.Hosting/bin/Release/net11.0/Microsoft.OpenHarmony.Hosting.dll}"
    GFX_DLL="${OPENHARMONY_GRAPHICS_DLL:-$W/src/Microsoft.OpenHarmony.Maui.Graphics/bin/Release/net11.0/Microsoft.OpenHarmony.Maui.Graphics.dll}"
    [ -d "$SLICE" ] || warn "maui-ohos slice missing: $SLICE (set MAUI_SLICE_DIR=)"
    [ -f "$HOST_DLL" ] || warn "hosting assembly missing: $HOST_DLL (build: $DOTNET build src/Microsoft.OpenHarmony.Hosting/Microsoft.OpenHarmony.Hosting.csproj -c Release)"
    [ -f "$GFX_DLL" ] || warn "graphics assembly missing: $GFX_DLL (build: $DOTNET build src/Microsoft.OpenHarmony.Maui.Graphics/Microsoft.OpenHarmony.Maui.Graphics.csproj -c Release)"
}
if [ "$SKIP_INTERACTION" = 0 ] || [ "$SKIP_PIXEL" = 0 ]; then
    prereq_hints
fi

# ---------------------------------------------------------------- step 1: sh -n
log "== step 1/4: sh -n over scripts/*.sh =="
SH_N_FILES=0
SH_N_BAD=0
for f in "$W"/scripts/*.sh; do
    [ -f "$f" ] || continue
    SH_N_FILES=$((SH_N_FILES + 1))
    if sh -n "$f" 2> "$LOG_DIR/sh-n-$(basename "$f").err"; then
        printf '   ok   scripts/%s\n' "$(basename "$f")"
    else
        SH_N_BAD=$((SH_N_BAD + 1))
        printf '   FAIL scripts/%s\n' "$(basename "$f")" >&2
        sed 's/^/        /' "$LOG_DIR/sh-n-$(basename "$f").err" >&2
    fi
done
if [ "$SH_N_FILES" -eq 0 ]; then
    warn "no scripts/*.sh found under $W"
    ST_SH_N="FAIL (no scripts found)"
    FAILED=$((FAILED + 1))
elif [ "$SH_N_BAD" -gt 0 ]; then
    ST_SH_N="FAIL ($SH_N_BAD of $SH_N_FILES)"
    FAILED=$((FAILED + 1))
else
    ST_SH_N="PASS ($SH_N_FILES scripts)"
    log "   $SH_N_FILES scripts parse (sh -n)"
fi

# ---------------------------------------------------------------- step 2: markdownlint
log "== step 2/4: markdownlint-cli2 0.23.3 =="
if [ "$SKIP_LINT" = 1 ]; then
    log "   skipped (--skip-lint)"
    ST_LINT="SKIP (--skip-lint)"
elif ! command -v npx >/dev/null 2>&1; then
    warn "npx not found; skipping markdownlint (CI installs Node and runs it)"
    ST_LINT="SKIP (no npx)"
else
    if (cd "$W" && npx --yes markdownlint-cli2@0.23.3) > "$LOG_DIR/markdownlint.log" 2>&1; then
        tail -3 "$LOG_DIR/markdownlint.log" | sed 's/^/   /'
        ST_LINT="PASS"
        log "   markdownlint-cli2 0.23.3: no issues"
    else
        sed 's/^/   /' "$LOG_DIR/markdownlint.log" | tail -40 >&2
        warn "markdownlint failed (full log: $LOG_DIR/markdownlint.log)"
        ST_LINT="FAIL"
        FAILED=$((FAILED + 1))
    fi
fi

# ------------------------------------------------- step 3: interaction suite (maui-platform-verify)
log "== step 3/4: interaction suite (test/maui-platform-verify) =="
if [ "$SKIP_INTERACTION" = 1 ]; then
    log "   skipped (--skip-interaction)"
    ST_INTERACTION="SKIP (--skip-interaction)"
elif ! command -v "$DOTNET" >/dev/null 2>&1; then
    warn "dotnet not found: $DOTNET (set DOTNET=); cannot run the interaction suite"
    ST_INTERACTION="FAIL (no dotnet)"
    FAILED=$((FAILED + 1))
elif [ ! -f "$PROJ_INTERACTION/verify.csproj" ]; then
    warn "missing $PROJ_INTERACTION/verify.csproj"
    ST_INTERACTION="FAIL (project missing)"
    FAILED=$((FAILED + 1))
else
    if ! (cd "$PROJ_INTERACTION" && "$DOTNET" build -m:1 -v:q) > "$LOG_DIR/interaction-build.log" 2>&1; then
        sed 's/^/   /' "$LOG_DIR/interaction-build.log" | tail -30 >&2
        warn "interaction build failed (full log: $LOG_DIR/interaction-build.log)"
        ST_INTERACTION="FAIL (build)"
        FAILED=$((FAILED + 1))
    else
        (cd "$PROJ_INTERACTION" && "$DOTNET" bin/Debug/net11.0/verify.dll) > "$LOG_DIR/interaction-run.log" 2>&1
        RUN_RC=$?
        CHECKS="$(grep -c '\[verify\]' "$LOG_DIR/interaction-run.log" 2>/dev/null || true)"
        [ -n "$CHECKS" ] || CHECKS=0
        UNHANDLED=0
        grep -q 'Unhandled' "$LOG_DIR/interaction-run.log" && UNHANDLED=1
        # The suite declares its own count/floor contract on the [suite] line (the constants live
        # in test/maui-platform-verify/Program.cs); CI reads the same line, so the two gates share
        # one source and this script no longer carries a second, weaker literal (the old 226).
        SUITE_LINE=0
        SUITE_CHECKS=0
        SUITE_FLOOR=0
        SUITE_RAW="$(grep -E '^\[suite\] checks=[0-9]+ total=[0-9]+ floor=[0-9]+ assert=True$' "$LOG_DIR/interaction-run.log" 2>/dev/null | tail -1 || true)"
        if [ -n "$SUITE_RAW" ]; then
            SUITE_LINE=1
            SUITE_CHECKS="$(printf '%s\n' "$SUITE_RAW" | sed -n 's/.*checks=\([0-9][0-9]*\).*/\1/p')"
            SUITE_FLOOR="$(printf '%s\n' "$SUITE_RAW" | sed -n 's/.*floor=\([0-9][0-9]*\).*/\1/p')"
            [ -n "$SUITE_CHECKS" ] || SUITE_CHECKS=0
            [ -n "$SUITE_FLOOR" ] || SUITE_FLOOR=0
        fi
        # Mirror the CI gate: both perf markers must be present and carry within=True.
        PERF_FRAME=0
        grep -q '\[verify\] perf warmup=.*within=True' "$LOG_DIR/interaction-run.log" && PERF_FRAME=1
        PERF_A11Y=0
        grep -q '\[verify\] perf a11y .*within=True' "$LOG_DIR/interaction-run.log" && PERF_A11Y=1
        if [ "$RUN_RC" -ne 0 ] || [ "$UNHANDLED" -ne 0 ] || [ "$SUITE_LINE" -ne 1 ] || [ "$CHECKS" -ne "$SUITE_CHECKS" ] || [ "$CHECKS" -lt "$SUITE_FLOOR" ] || [ "$PERF_FRAME" -ne 1 ] || [ "$PERF_A11Y" -ne 1 ]; then
            if [ "$RUN_RC" -ne 0 ]; then
                warn "interaction suite exited $RUN_RC"
            fi
            if [ "$UNHANDLED" -ne 0 ]; then
                warn "interaction output contains an unhandled exception"
                grep -n -m 3 'Unhandled' "$LOG_DIR/interaction-run.log" | sed 's/^/   /' >&2
            fi
            if [ "$SUITE_LINE" -ne 1 ]; then
                warn "the suite did not report its [suite] checks/floor contract line (harness and preflight.sh must come from the same commit)"
            fi
            if [ "$SUITE_LINE" -eq 1 ] && [ "$CHECKS" -ne "$SUITE_CHECKS" ]; then
                warn "[suite] reports $SUITE_CHECKS checks but grep counts $CHECKS [verify] lines"
            fi
            if [ "$SUITE_LINE" -eq 1 ] && [ "$CHECKS" -lt "$SUITE_FLOOR" ]; then
                warn "expected at least $SUITE_FLOOR [verify] lines (suite-declared floor), got $CHECKS"
            fi
            if [ "$PERF_FRAME" -ne 1 ]; then
                warn "frame-path perf marker missing or within=False (expected '[verify] perf warmup=... within=True')"
            fi
            if [ "$PERF_A11Y" -ne 1 ]; then
                warn "a11y publish-path perf marker missing or within=False (expected '[verify] perf a11y ... within=True')"
            fi
            if [ "$PERF_FRAME" -ne 1 ] || [ "$PERF_A11Y" -ne 1 ]; then
                grep '\[verify\] perf' "$LOG_DIR/interaction-run.log" | sed 's/^/   /' >&2
                ST_INTERACTION="FAIL ($CHECKS [verify], rc=$RUN_RC, perf budget)"
            else
                ST_INTERACTION="FAIL ($CHECKS [verify], rc=$RUN_RC)"
            fi
            warn "interaction run failed (full log: $LOG_DIR/interaction-run.log)"
            FAILED=$((FAILED + 1))
        else
            # CI gates both perf markers on within=True; report the perf lines here, verbatim.
            grep '\[verify\] perf' "$LOG_DIR/interaction-run.log" | sed 's/^/   /'
            grep '^\[suite\]' "$LOG_DIR/interaction-run.log" | sed 's/^/   /'
            ST_INTERACTION="PASS ($CHECKS [verify], floor $SUITE_FLOOR, perf within budget)"
            log "   $CHECKS [verify] lines (suite floor $SUITE_FLOOR, count matches the [suite] line), no Unhandled, frame + a11y perf within=True"
        fi
    fi
fi

# ------------------------------------------------- step 4: pixel suite (headless-render)
log "== step 4/4: pixel suite (test/headless-render) =="
if [ "$SKIP_PIXEL" = 1 ]; then
    log "   skipped (--skip-pixel)"
    ST_PIXEL="SKIP (--skip-pixel)"
elif ! command -v "$DOTNET" >/dev/null 2>&1; then
    warn "dotnet not found: $DOTNET (set DOTNET=); cannot run the pixel suite"
    ST_PIXEL="FAIL (no dotnet)"
    FAILED=$((FAILED + 1))
elif [ ! -f "$PROJ_PIXEL/headless-render.csproj" ]; then
    warn "missing $PROJ_PIXEL/headless-render.csproj"
    ST_PIXEL="FAIL (project missing)"
    FAILED=$((FAILED + 1))
else
    # The OpenHarmony codesign target re-signs every ELF under bin/ after each build; with the
    # installed SDK, rewriting an already-signed apphost fails with "Access to the path is
    # denied" on a second run. Remove the outputs so the apphost is always signed exactly once.
    rm -rf "$PROJ_PIXEL/bin"
    (cd "$PROJ_PIXEL" && "$DOTNET" run -c Release) > "$LOG_DIR/pixel.log" 2>&1
    PIXEL_RC=$?
    if [ "$PIXEL_RC" -eq 0 ] && grep -q 'PIXEL ASSERTIONS PASSED' "$LOG_DIR/pixel.log"; then
        grep 'PIXEL ASSERTIONS' "$LOG_DIR/pixel.log" | sed 's/^/   /'
        ST_PIXEL="PASS"
        log "   dotnet run -c Release: PIXEL ASSERTIONS PASSED"
    else
        sed 's/^/   /' "$LOG_DIR/pixel.log" | tail -30 >&2
        if [ "$PIXEL_RC" -ne 0 ]; then
            warn "pixel suite exited $PIXEL_RC"
        fi
        warn "pixel suite did not report PIXEL ASSERTIONS PASSED (full log: $LOG_DIR/pixel.log)"
        ST_PIXEL="FAIL (rc=$PIXEL_RC)"
        FAILED=$((FAILED + 1))
    fi
fi

# ---------------------------------------------------------------- summary
log "== summary =="
summary_line "sh -n scripts/*.sh" "$ST_SH_N"
summary_line "markdownlint-cli2@0.23.3" "$ST_LINT"
summary_line "interaction suite (maui-platform-verify)" "$ST_INTERACTION"
summary_line "pixel suite (headless-render)" "$ST_PIXEL"
log "   logs: $LOG_DIR"

if [ "$FAILED" -gt 0 ]; then
    warn "PREFLIGHT FAILED — $FAILED step(s) failed; do not push until these are green"
    exit 1
fi
log "PREFLIGHT OK — every non-skipped gate is green"
exit 0
