#!/bin/sh
# selftest-ridgraph.sh - repeatable, local selftest for the portable RID graph single source
# (scripts/sync-ridgraph.sh) and the packed UseRidGraph branch.
#
#   T1 in-sync    the current tree passes `sync-ridgraph.sh --check` (byte-level when the
#                 sdk-ohos canonical is reachable, digest-level otherwise)
#   T2 identical  the three preview pack copies are byte-identical to each other
#   T3 digest     every pack copy matches the sha256 recorded in packs/ridgraph-canonical.sha256
#   T4 AOT map    every pack copy maps openharmony-arm/arm64/x64 to the matching linux-musl-* RID
#   T5 drift      a tampered pack copy is refused by --check, and the error names the pack and
#                 says how to fix it; a missing pack copy is refused too
#   T6 bad source a canonical graph without the AOT imports, and a non-JSON canonical, are both
#                 refused in sync and check mode
#   T7 regen      sync mode rewrites a tampered pack copy byte-identically from the canonical
#   T8 branch     each pack's Sdk.targets carries the UseRidGraph=true legacy branch and the
#                 portable default branch, and the legacy graph has the same AOT RID mapping
#   T9 no source  a missing canonical path fails with an actionable SDK_OHOS_ENG_GRAPH hint
#
# The tampered copies live in a scratch packs dir (RIDGRAPH_PACKS) and never touch the repo.
#
# Env: SELFTEST_TMPDIR=<dir>              work dir base (default: the approved opencode tmp dir
#                                         on this host, else TMPDIR, else /tmp)
#      SELFTEST_RIDGRAPH_CANONICAL=<path> explicit canonical graph for the cross-repo tests
#                                         (default: the sibling sdk-ohos checkout when present)
#      SELFTEST_KEEP=1                    keep the work dir even when all checks pass
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="1 (2026-09-24)"

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

W="$(cd "$(dirname "$0")/.." && pwd)"
SYNC="$W/scripts/sync-ridgraph.sh"
PACKS="${RIDGRAPH_PACKS:-$W/packs}"
WORK_BASE="${SELFTEST_TMPDIR:-}"
if [ -z "$WORK_BASE" ]; then
    # Same portable chain as scripts/selftest-tester-run.sh: CI runners have neither the
    # approved opencode dir nor (usually) TMPDIR, so the hardcoded host path must not be the
    # only option (a bare `mktemp -d <missing dir>` aborts the whole selftest).
    if [ -d /data/storage/el2/base/tmp/opencode ]; then
        WORK_BASE="/data/storage/el2/base/tmp/opencode"
    elif [ -n "${TMPDIR:-}" ]; then
        WORK_BASE="$TMPDIR"
    else
        WORK_BASE="/tmp"
    fi
fi
KEEP="${SELFTEST_KEEP:-0}"

[ -f "$SYNC" ] || { printf 'FATAL: sync-ridgraph.sh not found: %s\n' "$SYNC" >&2; exit 1; }
for _t in python3 cmp diff mktemp cut ls; do
    command -v "$_t" >/dev/null 2>&1 || { printf 'FATAL: required command not found: %s\n' "$_t" >&2; exit 1; }
done

WORK="$(mktemp -d "$WORK_BASE/selftest-ridgraph.XXXXXX")" || {
    printf 'FATAL: cannot create a work dir under %s\n' "$WORK_BASE" >&2
    exit 1
}
CHECKS=0
FAILED=0
SKIP=0

pass_() { CHECKS=$((CHECKS + 1)); printf '  [PASS] %s\n' "$*"; }
fail_() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$*" >&2; }
skip_() { CHECKS=$((CHECKS + 1)); SKIP=$((SKIP + 1)); printf '  [SKIP] %s\n' "$*"; }
assert_rc() { # <expected> <actual> <label>
    if [ "$2" -eq "$1" ]; then pass_ "$3 (exit $2)"; else fail_ "$3 (expected exit $1, got $2)"; fi
}
assert_contains() { # <label> <needle> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then pass_ "$1"; else fail_ "$1 (missing: $2)"; fi
}

log "selftest-ridgraph v$SELFTEST_VERSION"
log "script: $SYNC"
log "work:   $WORK"

# ---- canonical resolution -------------------------------------------------------------
CANONICAL=""
if [ -n "${SELFTEST_RIDGRAPH_CANONICAL:-}" ]; then
    CANONICAL="$SELFTEST_RIDGRAPH_CANONICAL"
elif [ -n "${SDK_OHOS_ENG_GRAPH:-}" ]; then
    CANONICAL="$SDK_OHOS_ENG_GRAPH"
elif [ -f "$W/../sdk-ohos/eng/PortableRuntimeIdentifierGraph.openharmony.json" ]; then
    CANONICAL="$W/../sdk-ohos/eng/PortableRuntimeIdentifierGraph.openharmony.json"
fi
if [ -n "$CANONICAL" ]; then
    log "canonical: $CANONICAL (byte-level cross-repo checks enabled)"
else
    log "canonical: not reachable (digest-level checks only; set SELFTEST_RIDGRAPH_CANONICAL= to enable byte-level)"
fi

# A scratch packs tree mirroring the real pack layout; the tests tamper with the copies there.
scratch_packs() { # <dir>
    rm -rf "$1"
    mkdir -p "$1"
    for v in 1.0.0-preview.22 1.0.0-preview.23 1.0.0-preview.24; do
        mkdir -p "$1/Microsoft.OpenHarmony.Sdk/$v/ridgraph" "$1/Microsoft.OpenHarmony.Sdk/$v/Sdk"
        cp "$W/packs/Microsoft.OpenHarmony.Sdk/$v/ridgraph/PortableRuntimeIdentifierGraph.openharmony.json" \
           "$1/Microsoft.OpenHarmony.Sdk/$v/ridgraph/"
        cp "$W/packs/Microsoft.OpenHarmony.Sdk/$v/ridgraph/RuntimeIdentifierGraph.openharmony.json" \
           "$1/Microsoft.OpenHarmony.Sdk/$v/ridgraph/"
        cp "$W/packs/Microsoft.OpenHarmony.Sdk/$v/Sdk/Sdk.targets" \
           "$1/Microsoft.OpenHarmony.Sdk/$v/Sdk/"
    done
}

# ---- T1: the current tree is in sync ---------------------------------------------------
section "T1 in-sync tree"
sh "$SYNC" --check > "$WORK/T1.log" 2>&1
assert_rc 0 $? "T1 sync-ridgraph.sh --check accepts the current tree"
assert_contains "T1 reports the byte source or the recorded digest" "RID graph check" "$WORK/T1.log"

# ---- T2/T3/T4: byte identity, digest, AOT mapping --------------------------------------
section "T2/T3/T4 pack copies"
REF="$PACKS/Microsoft.OpenHarmony.Sdk/1.0.0-preview.24/ridgraph/PortableRuntimeIdentifierGraph.openharmony.json"
[ -f "$REF" ] || { fail_ "T2 reference pack graph missing: $REF"; REF=""; }
if [ -n "$REF" ]; then
    same=1
    for v in 1.0.0-preview.22 1.0.0-preview.23; do
        cmp -s "$PACKS/Microsoft.OpenHarmony.Sdk/$v/ridgraph/PortableRuntimeIdentifierGraph.openharmony.json" "$REF" || same=0
    done
    [ "$same" -eq 1 ] && pass_ "T2 preview.22/23/24 portable graphs are byte-identical" \
                      || fail_ "T2 the three pack portable graphs differ"

    if [ -f "$PACKS/ridgraph-canonical.sha256" ]; then
        recorded="$(cut -d' ' -f1 < "$PACKS/ridgraph-canonical.sha256")"
        digest_ok=1
        for v in 1.0.0-preview.22 1.0.0-preview.23 1.0.0-preview.24; do
            got="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' \
                "$PACKS/Microsoft.OpenHarmony.Sdk/$v/ridgraph/PortableRuntimeIdentifierGraph.openharmony.json")"
            [ "$got" = "$recorded" ] || { digest_ok=0; fail_ "T3 $v digest $got != recorded $recorded"; }
        done
        [ "$digest_ok" -eq 1 ] && pass_ "T3 all three pack graphs match the recorded digest ($recorded)"
    else
        fail_ "T3 packs/ridgraph-canonical.sha256 is missing (run scripts/sync-ridgraph.sh)"
    fi

    if python3 - "$REF" <<'PY'
import json, sys
graph = json.load(open(sys.argv[1], encoding='utf-8'))['runtimes']
for arch in ('arm', 'arm64', 'x64'):
    assert f'linux-musl-{arch}' in graph[f'openharmony-{arch}']['#import'], arch
PY
    then
        pass_ "T4 every pack graph maps openharmony-arm/arm64/x64 -> linux-musl-*"
    else
        fail_ "T4 the AOT RID mapping is missing from the pack graph"
    fi
fi

# ---- T5: tampered pack copies are refused ----------------------------------------------
section "T5 drift detection"
SCRATCH="$WORK/packs-drift"
scratch_packs "$SCRATCH"
python3 - "$SCRATCH/Microsoft.OpenHarmony.Sdk/1.0.0-preview.23/ridgraph/PortableRuntimeIdentifierGraph.openharmony.json" <<'PY'
import json, sys
path = sys.argv[1]
graph = json.load(open(path, encoding='utf-8'))
graph['runtimes']['openharmony-arm64']['#import'] = ['openharmony']  # drop the AOT fallback
json.dump(graph, open(path, 'w', encoding='utf-8'), indent=2)
PY
RIDGRAPH_PACKS="$SCRATCH" sh "$SYNC" --check > "$WORK/T5a.log" 2>&1
assert_rc 1 $? "T5 a tampered pack copy fails --check"
assert_contains "T5 names the drifting pack" "Microsoft.OpenHarmony.Sdk/1.0.0-preview.23" "$WORK/T5a.log"
assert_contains "T5 says how to fix it" "run scripts/sync-ridgraph.sh" "$WORK/T5a.log"
rm -f "$SCRATCH/Microsoft.OpenHarmony.Sdk/1.0.0-preview.22/ridgraph/PortableRuntimeIdentifierGraph.openharmony.json"
RIDGRAPH_PACKS="$SCRATCH" sh "$SYNC" --check > "$WORK/T5b.log" 2>&1
assert_rc 1 $? "T5 a missing pack copy fails --check"
assert_contains "T5 reports the missing copy" "MISSING Microsoft.OpenHarmony.Sdk/1.0.0-preview.22" "$WORK/T5b.log"

# ---- T6: invalid canonical sources are refused -----------------------------------------
section "T6 invalid canonical"
printf 'not json\n' > "$WORK/notjson.json"
sh "$SYNC" --check --from "$WORK/notjson.json" > "$WORK/T6a.log" 2>&1
assert_rc 1 $? "T6 a non-JSON canonical fails"
assert_contains "T6 reports the parse failure" "not valid JSON" "$WORK/T6a.log"
python3 - "$CANONICAL" "$WORK/no-aot.json" <<'PY' 2>/dev/null || true
import json, sys
try:
    graph = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:  # noqa: BLE001 - the fixture is only built when the canonical exists
    sys.exit(1)
graph['runtimes']['openharmony-arm64']['#import'] = ['openharmony']
json.dump(graph, open(sys.argv[2], 'w', encoding='utf-8'), indent=2)
PY
if [ -f "$WORK/no-aot.json" ]; then
    sh "$SYNC" --check --from "$WORK/no-aot.json" > "$WORK/T6b.log" 2>&1
    assert_rc 1 $? "T6 a canonical without the AOT imports fails"
    assert_contains "T6 names the missing mapping" "openharmony-arm64 -> linux-musl-arm64" "$WORK/T6b.log"
else
    skip_ "T6 canonical fixture needs a reachable canonical graph (set SELFTEST_RIDGRAPH_CANONICAL=)"
fi

# ---- T7: sync mode regenerates the pack copy byte-identically --------------------------
section "T7 regeneration"
if [ -n "$CANONICAL" ] && [ -f "$CANONICAL" ]; then
    SCRATCH2="$WORK/packs-regen"
    scratch_packs "$SCRATCH2"
    python3 - "$SCRATCH2/Microsoft.OpenHarmony.Sdk/1.0.0-preview.24/ridgraph/PortableRuntimeIdentifierGraph.openharmony.json" <<'PY'
import json, sys
path = sys.argv[1]
graph = json.load(open(path, encoding='utf-8'))
graph['runtimes']['openharmony-x64']['#import'] = ['openharmony']
json.dump(graph, open(path, 'w', encoding='utf-8'), indent=2)
PY
    RIDGRAPH_PACKS="$SCRATCH2" sh "$SYNC" --from "$CANONICAL" > "$WORK/T7.log" 2>&1
    assert_rc 0 $? "T7 sync mode rewrites the tampered copy"
    if cmp -s "$SCRATCH2/Microsoft.OpenHarmony.Sdk/1.0.0-preview.24/ridgraph/PortableRuntimeIdentifierGraph.openharmony.json" "$CANONICAL"; then
        pass_ "T7 the regenerated copy is byte-identical to the canonical"
    else
        fail_ "T7 the regenerated copy differs from the canonical"
    fi
    if [ -f "$SCRATCH2/ridgraph-canonical.sha256" ]; then
        pass_ "T7 sync mode records the canonical digest"
    else
        fail_ "T7 sync mode did not record the canonical digest"
    fi
else
    skip_ "T7 regeneration needs a reachable canonical graph (set SELFTEST_RIDGRAPH_CANONICAL=)"
fi

# ---- T8: the packed UseRidGraph branch -------------------------------------------------
section "T8 UseRidGraph branch"
branch_ok=1
for v in 1.0.0-preview.22 1.0.0-preview.23 1.0.0-preview.24; do
    sdk="$PACKS/Microsoft.OpenHarmony.Sdk/$v/Sdk/Sdk.targets"
    legacy="$PACKS/Microsoft.OpenHarmony.Sdk/$v/ridgraph/RuntimeIdentifierGraph.openharmony.json"
    grep -qF "and '\$(UseRidGraph)' == 'true' " "$sdk" || branch_ok=0
    grep -qF 'ridgraph/RuntimeIdentifierGraph.openharmony.json</RuntimeIdentifierGraphPath>' "$sdk" || branch_ok=0
    grep -qF 'ridgraph/PortableRuntimeIdentifierGraph.openharmony.json</RuntimeIdentifierGraphPath>' "$sdk" || branch_ok=0
    python3 - "$legacy" <<'PY' || branch_ok=0
import json, sys
graph = json.load(open(sys.argv[1], encoding='utf-8'))['runtimes']
for arch in ('arm', 'arm64', 'x64'):
    assert f'linux-musl-{arch}' in graph[f'openharmony-{arch}']['#import'], arch
PY
done
[ "$branch_ok" -eq 1 ] && pass_ "T8 every pack has the UseRidGraph legacy branch + AOT-mapped legacy graph" \
                      || fail_ "T8 a pack is missing the UseRidGraph branch or the legacy AOT mapping"

# ---- T9: a missing canonical path is reported ------------------------------------------
section "T9 missing canonical"
sh "$SYNC" --check --from "$WORK/does-not-exist.json" > "$WORK/T9.log" 2>&1
assert_rc 1 $? "T9 a missing canonical path fails"
assert_contains "T9 names the missing file" "canonical RID graph not found" "$WORK/T9.log"

# ---- summary ---------------------------------------------------------------------------
section "summary"
log "checks: $CHECKS, failed: $FAILED, skipped: $SKIP"
if [ "$FAILED" -gt 0 ]; then
    log "SELFTEST FAILED - work dir kept: $WORK"
    exit 1
fi
log "SELFTEST OK - the pack RID graphs single-source from sdk-ohos/eng and the UseRidGraph branch holds"
if [ "$KEEP" = "1" ]; then
    log "work dir kept (SELFTEST_KEEP=1): $WORK"
else
    rm -rf "$WORK"
fi
exit 0
