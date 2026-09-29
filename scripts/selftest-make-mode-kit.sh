#!/bin/sh
# selftest-make-mode-kit.sh - repeatable, local selftest for scripts/make-mode-kit.sh (the
# jit/aot/interp runtime-mode kit builder). No real publish, no SDK, no device:
#
#   T1 usage       sh -n passes; --help lists the three modes; an unknown option/mode exits 2
#   T2 dry-run     one publish command per mode with the MS-MODE switch and the mode-specific
#                  properties (aot: PublishAot/PublishAotUsingRuntimePack/NativeLib plus the
#                  default OpenHarmonyUIPage=pages/Index, which a --property overrides; interp:
#                  OpenHarmonyInterpreterPack); --mode restricts the run; --property passes
#                  through; --sign prints the sign-for-device.sh invocations and never injects
#                  a password; nothing is written
#   T3 fixture     a fake dotnet "publishes" the three shapes (hap zips with the mode marker
#                  and libraries); the kit verifies each marker, keeps the per-mode dirs
#                  (<stem>-<mode>.hap + -unsigned + publish.log) and writes a working
#                  SHA256SUMS
#   T4 negatives   aot without lib<stem>.so, interp without libclrinterpreter.so, a wrong
#                  marker, a failed publish, an empty publish and an incomplete interp pack
#                  all exit non-zero and name the offending entry; an out-of-band stale hap
#                  cannot pass as this run's output
#   T5 signing     --sign passes through to sign-for-device.sh per mode hap (device args and
#                  external args reach it; no password on the generated argv), replaces the
#                  hap only on success and leaves the original in place on failure
#
# The fixture imports nothing from the SDK: the fake dotnet writes what the real pack targets
# stage (libs/<abi>/runtime-mode.txt, lib<stem>.so, the interpreter pair) into the documented
# publish output path, so the checks gate the kit script itself, not the packaging targets
# (scripts/selftest-hap-targets.sh T7 gates those).
#
# Env: SELFTEST_TMPDIR=<dir>  work dir base (default: the approved opencode tmp dir, else TMPDIR)
#      SELFTEST_KEEP=1       keep the work dir even when all checks pass
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="1 (2026-09-27)"

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

W="$(cd "$(dirname "$0")/.." && pwd)"
MK="$W/scripts/make-mode-kit.sh"
WORK_BASE="${SELFTEST_TMPDIR:-}"
if [ -z "$WORK_BASE" ]; then
    if [ -d /data/storage/el2/base/tmp/opencode ]; then
        WORK_BASE="/data/storage/el2/base/tmp/opencode"
    elif [ -n "${TMPDIR:-}" ]; then
        WORK_BASE="$TMPDIR"
    else
        WORK_BASE="/tmp"
    fi
fi
KEEP="${SELFTEST_KEEP:-0}"

[ -f "$MK" ] || { printf 'FATAL: make-mode-kit.sh not found: %s\n' "$MK" >&2; exit 1; }
for _t in python3 sh grep sed cmp mktemp sha256sum find; do
    command -v "$_t" >/dev/null 2>&1 || { printf 'FATAL: required command not found: %s\n' "$_t" >&2; exit 1; }
done

WORK="$(mktemp -d "$WORK_BASE/selftest-make-mode-kit.XXXXXX")" || {
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
    if grep -qF -- "$2" "$3" 2>/dev/null; then pass_ "$1"; else fail_ "$1 (missing '$2' in $3)"; fi
}
assert_not_contains() { # <label> <needle> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then fail_ "$1 (unexpected '$2' in $3)"; else pass_ "$1"; fi
}
assert_file() { # <label> <path>
    if [ -f "$2" ]; then pass_ "$1"; else fail_ "$1 (missing $2)"; fi
}

log "selftest-make-mode-kit v$SELFTEST_VERSION"
log "work: $WORK"

# ---- fixture ----------------------------------------------------------------------------
FIX="$WORK/fixture"
FAKEBIN="$WORK/bin"
mkdir -p "$FIX/pack/native" "$FIX/pack-coreclr-only" "$FAKEBIN"
: > "$FIX/FakeApp.csproj"
printf 'pack-coreclr-bytes' > "$FIX/pack/native/libcoreclr.so"
printf 'pack-interp-bytes'  > "$FIX/pack/libclrinterpreter.so"
printf 'pack-coreclr-bytes' > "$FIX/pack-coreclr-only/libcoreclr.so"

cat > "$FAKEBIN/dotnet" <<'FAKE_DOTNET'
#!/bin/sh
# fake dotnet for selftest-make-mode-kit: writes the haps the real OpenHarmony packaging targets
# would stage, into the documented publish output path.
printf 'fake-dotnet %s\n' "$*" >> "${FAKE_LOG:-/dev/null}"
if [ "${FAKE_FAIL_PUBLISH:-0}" = 1 ]; then
    printf 'fake-dotnet: simulated publish failure\n' >&2
    exit 1
fi
[ "${FAKE_NO_WRITE:-0}" = 1 ] && exit 0
cmd="$1"; shift
[ "$cmd" = publish ] || { printf 'fake-dotnet: expected publish, got %s\n' "$cmd" >&2; exit 2; }
PROJ=""; CONF=Release; TFM=""; MODE=jit; PACK=""; ABI=""
while [ $# -gt 0 ]; do
    case "$1" in
        -c) CONF="$2"; shift 2 ;;
        -r) RID="$2"; shift 2 ;;
        -f) TFM="$2"; shift 2 ;;
        -p:OpenHarmonyRuntimeMode=*) MODE="${1#-p:OpenHarmonyRuntimeMode=}"; shift ;;
        -p:OpenHarmonyInterpreterPack=*) PACK="${1#-p:OpenHarmonyInterpreterPack=}"; shift ;;
        -p:OpenHarmonyAbi=*) ABI="${1#-p:OpenHarmonyAbi=}"; shift ;;
        -p:*) shift ;;
        -*) shift ;;
        *) [ -z "$PROJ" ] && PROJ="$1"; shift ;;
    esac
done
[ -n "$PROJ" ] || { printf 'fake-dotnet: no project argument\n' >&2; exit 2; }
[ -n "$TFM" ] || { printf 'fake-dotnet: no -f <tfm>\n' >&2; exit 2; }
[ -n "$ABI" ] || ABI="${FAKE_ABI:-arm64-v8a}"
STEM="${FAKE_STEM:-FakeApp}"
DIR="$(dirname "$PROJ")/bin/$CONF/$TFM/$RID"
mkdir -p "$DIR"
python3 - "$DIR" "$MODE" "$PACK" "$STEM" "$ABI" <<'PY'
import json, os, sys, zipfile

outdir, mode, pack, stem, abi = sys.argv[1:6]
marker = os.environ.get('FAKE_WRONG_MARKER') or mode
entries = {
    'module.json': json.dumps({'app': {'bundleName': 'com.example.fake'}}).encode(),
    'resources/rawfile/app.json': json.dumps({'assembly': stem + '.dll'}).encode(),
    f'libs/{abi}/runtime-mode.txt': (marker + '\n').encode(),
    f'libs/{abi}/libopenharmonyhost.so': b'host',
}

def packfile(name):
    for path in (os.path.join(pack, name), os.path.join(pack, 'native', name)):
        if pack and os.path.isfile(path):
            return open(path, 'rb').read()
    return None

if mode == 'aot' and os.environ.get('FAKE_DROP_AOT_LIB') != '1':
    entries[f'libs/{abi}/lib{stem}.so'] = b'\x7fELF-fake-aot'
if mode == 'interp':
    for name, knob in (('libcoreclr.so', 'FAKE_DROP_CORECLR'), ('libclrinterpreter.so', 'FAKE_DROP_CLRINTERP')):
        if os.environ.get(knob) != '1':
            data = packfile(name)
            if data is not None:
                entries[f'libs/{abi}/{name}'] = data
for suffix in ('', '-unsigned'):
    with zipfile.ZipFile(os.path.join(outdir, stem + suffix + '.hap'), 'w', zipfile.ZIP_DEFLATED) as z:
        for name in sorted(entries):
            z.writestr(name, entries[name])
PY
exit 0
FAKE_DOTNET
chmod +x "$FAKEBIN/dotnet"

cat > "$FAKEBIN/fake-sign" <<'FAKE_SIGN'
#!/bin/sh
# fake sign-for-device.sh: records its argv and copies input -> output (plus a tail marker so
# the replacement is observable).
printf '%s\n' "$*" >> "${FAKE_SIGN_LOG:-/dev/null}"
IN=""; OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --unsigned) IN="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$IN" ] && [ -f "$IN" ] || { printf 'fake-sign: no --unsigned input\n' >&2; exit 2; }
[ -n "$OUT" ] || { printf 'fake-sign: no --out\n' >&2; exit 2; }
cp "$IN" "$OUT"
printf 'fake-signed\n' >> "$OUT"
# Fail after writing the output, like a failing verify-app: the caller must drop the temp file
# and keep the original hap.
[ "${FAKE_SIGN_FAIL:-0}" = 1 ] && { printf 'fake-sign: simulated signing failure\n' >&2; exit 1; }
exit 0
FAKE_SIGN
chmod +x "$FAKEBIN/fake-sign"

# Run the kit; LAST_RC carries the exit code. Output logs under $WORK/<name>.out|.err.
run_mk() { # <name> <args...>
    name="$1"; shift
    sh "$MK" "$@" > "$WORK/$name.out" 2> "$WORK/$name.err"
    LAST_RC=$?
}

hap_marker() { # <hap>
    python3 - "$1" <<'PY'
import sys, zipfile
try:
    print(zipfile.ZipFile(sys.argv[1]).read('libs/arm64-v8a/runtime-mode.txt').decode().strip())
except KeyError:
    print('<absent>')
PY
}
hap_has() { # <hap> <entry>  -> 0/1
    python3 - "$1" "$2" <<'PY'
import sys, zipfile
try:
    info = zipfile.ZipFile(sys.argv[1]).getinfo(sys.argv[2])
except KeyError:
    sys.exit(1)
sys.exit(0 if info.file_size > 0 else 1)
PY
}

# ---- T1: usage --------------------------------------------------------------------------
section "T1 usage"
if sh -n "$MK" 2> "$WORK/T1-syntax.err"; then
    pass_ "T1 sh -n passes"
else
    fail_ "T1 sh -n reports a syntax error (see $WORK/T1-syntax.err)"
fi
run_mk T1-help --help; assert_rc 0 $LAST_RC "T1 --help exits 0"
assert_contains "T1 help names the three modes" "jit | aot | interp" "$WORK/T1-help.out"
run_mk T1-badopt --nope; assert_rc 2 $LAST_RC "T1 an unknown option exits 2"
run_mk T1-badmode --project "$FIX/FakeApp.csproj" --out-dir "$WORK/out-t1" --mode full --dry-run
assert_rc 2 $LAST_RC "T1 an unknown --mode exits 2"
assert_contains "T1 names the rejected mode" "unknown runtime mode: 'full'" "$WORK/T1-badmode.err"
run_mk T1-nopack --project "$FIX/FakeApp.csproj" --out-dir "$WORK/out-t1" --mode interp --dry-run
assert_rc 2 $LAST_RC "T1 interp without --interp-pack exits 2"
run_mk T1-packjit --project "$FIX/FakeApp.csproj" --out-dir "$WORK/out-t1" --mode jit --interp-pack "$FIX/pack" --dry-run
assert_rc 2 $LAST_RC "T1 --interp-pack outside interp exits 2"

# ---- T2: dry-run commands ---------------------------------------------------------------
section "T2 dry-run"
run_mk T2-all --project "$FIX/FakeApp.csproj" --tfm net11.0-openharmony20.0 \
    --out-dir "$WORK/out-t2" --interp-pack "$FIX/pack" \
    --property OpenHarmonyUIPage=pages/Index --dry-run
assert_rc 0 $LAST_RC "T2 the three-mode dry run exits 0"
if [ ! -e "$WORK/out-t2" ]; then pass_ "T2 writes nothing"; else fail_ "T2 created $WORK/out-t2"; fi
assert_contains "T2 the jit publish carries the mode switch" "-p:OpenHarmonyRuntimeMode=jit" "$WORK/T2-all.out"
grep -F -- '-p:OpenHarmonyRuntimeMode=jit' "$WORK/T2-all.out" > "$WORK/T2-jit.line" || true
assert_not_contains "T2 the jit publish has no AOT flags" "-p:PublishAot=true" "$WORK/T2-jit.line"
assert_contains "T2 the aot publish sets PublishAot" "-p:PublishAot=true" "$WORK/T2-all.out"
assert_contains "T2 the aot publish uses the runtime pack" "-p:PublishAotUsingRuntimePack=true" "$WORK/T2-all.out"
assert_contains "T2 the aot publish builds a shared library" "-p:NativeLib=Shared" "$WORK/T2-all.out"
assert_contains "T2 the interp publish points at the pack" "-p:OpenHarmonyInterpreterPack=$FIX/pack" "$WORK/T2-all.out"
assert_contains "T2 --property is forwarded" "-p:OpenHarmonyUIPage=pages/Index" "$WORK/T2-all.out"
run_mk T2-aot-ui --project "$FIX/FakeApp.csproj" --tfm t --out-dir "$WORK/out-t2" --mode aot --dry-run
assert_rc 0 $LAST_RC "T2 --mode aot without --property exits 0"
assert_contains "T2 the aot default stages the UI shell page" "-p:OpenHarmonyUIPage=pages/Index" "$WORK/T2-aot-ui.out"
T2_UI_LINES="$(grep -c -- '-p:OpenHarmonyUIPage=' "$WORK/T2-aot-ui.out" || true)"
[ "$T2_UI_LINES" = 1 ] && pass_ "T2 the aot default page appears exactly once" \
                       || fail_ "T2 printed $T2_UI_LINES OpenHarmonyUIPage properties (expected 1)"
run_mk T2-aot-ui-override --project "$FIX/FakeApp.csproj" --tfm t --out-dir "$WORK/out-t2" --mode aot \
    --property OpenHarmonyUIPage=pages/Custom --dry-run
assert_contains "T2 --property wins over the aot default page" "-p:OpenHarmonyUIPage=pages/Custom" "$WORK/T2-aot-ui-override.out"
assert_not_contains "T2 an overridden aot publish carries no default page" "pages/Index" "$WORK/T2-aot-ui-override.out"
T2_PUBS="$(grep -c '^+ .*publish ' "$WORK/T2-all.out" || true)"
[ "$T2_PUBS" = 3 ] && pass_ "T2 the dry run prints 3 publish commands" \
                   || fail_ "T2 printed $T2_PUBS publish commands (expected 3)"
run_mk T2-one --project "$FIX/FakeApp.csproj" --tfm t --out-dir "$WORK/out-t2" --mode aot --dry-run
T2_ONE="$(grep -c '^+ .*publish ' "$WORK/T2-one.out" || true)"
[ "$T2_ONE" = 1 ] && pass_ "T2 --mode aot prints one publish" \
                  || fail_ "T2 --mode aot printed $T2_ONE publishes"
assert_contains "T2 --mode output carries the aot flags" "-p:PublishAot=true" "$WORK/T2-one.out"
run_mk T2-dotnetless --project "$FIX/FakeApp.csproj" --tfm t --out-dir "$WORK/out-t2" --mode jit --dry-run
assert_rc 0 $LAST_RC "T2 the dry run needs no dotnet"
DOTNET="$WORK/definitely-missing-dotnet" run_mk T2-dotnetless2 --project "$FIX/FakeApp.csproj" --tfm t \
    --out-dir "$WORK/out-t2" --mode jit --dry-run
assert_rc 0 $LAST_RC "T2 a missing DOTNET does not fail the dry run"
run_mk T2-sign --project "$FIX/FakeApp.csproj" --tfm t --out-dir "$WORK/out-t2" --mode jit \
    --dry-run --sign 0123456789ABCDEF
assert_rc 0 $LAST_RC "T2 --dry-run --sign exits 0"
assert_contains "T2 the sign command passes the UDID" "0123456789ABCDEF" "$WORK/T2-sign.out"
assert_contains "T2 the sign command names the hap" "--unsigned $WORK/out-t2/jit/FakeApp-jit.hap" "$WORK/T2-sign.out"
assert_contains "T2 the sign command names sign-for-device.sh" "sign-for-device.sh" "$WORK/T2-sign.out"
assert_not_contains "T2 no password is injected" "--password" "$WORK/T2-sign.out"
run_mk T2-signout --project "$FIX/FakeApp.csproj" --tfm t --out-dir "$WORK/out-t2" --mode jit \
    --dry-run --sign --out x
assert_rc 2 $LAST_RC "T2 --sign refuses --out (the kit controls it)"

# ---- T3: fixture publish (all three modes) ----------------------------------------------
section "T3 fixture publish"
OUT3="$WORK/out-t3"
FAKE_LOG="$WORK/fake-dotnet-t3.log" DOTNET="$FAKEBIN/dotnet" run_mk T3 \
    --project "$FIX/FakeApp.csproj" --tfm net11.0-openharmony20.0 --out-dir "$OUT3" --interp-pack "$FIX/pack"
assert_rc 0 $LAST_RC "T3 the three-mode fixture run exits 0"
for m in jit aot interp; do
    assert_file "T3 $m hap exists" "$OUT3/$m/FakeApp-$m.hap"
    assert_file "T3 $m unsigned hap exists" "$OUT3/$m/FakeApp-$m-unsigned.hap"
    assert_file "T3 $m publish log exists" "$OUT3/$m/publish.log"
    MARK="$(hap_marker "$OUT3/$m/FakeApp-$m.hap")"
    [ "$MARK" = "$m" ] && pass_ "T3 $m hap marker reads $m" \
                      || fail_ "T3 $m hap marker is '$MARK'"
done
hap_has "$OUT3/aot/FakeApp-aot.hap" "libs/arm64-v8a/libFakeApp.so" \
    && pass_ "T3 the aot hap carries libFakeApp.so" \
    || fail_ "T3 the aot hap is missing libFakeApp.so"
if hap_has "$OUT3/jit/FakeApp-jit.hap" "libs/arm64-v8a/libFakeApp.so"; then
    fail_ "T3 the jit hap should not carry libFakeApp.so"
else
    pass_ "T3 the jit hap keeps the stock shape (no AOT library)"
fi
hap_has "$OUT3/interp/FakeApp-interp.hap" "libs/arm64-v8a/libcoreclr.so" &&
    hap_has "$OUT3/interp/FakeApp-interp.hap" "libs/arm64-v8a/libclrinterpreter.so" \
    && pass_ "T3 the interp hap carries libcoreclr.so + libclrinterpreter.so" \
    || fail_ "T3 the interp hap is missing a swapped library"assert_file "T3 SHA256SUMS exists" "$OUT3/SHA256SUMS"
T3_LINES="$(grep -c . "$OUT3/SHA256SUMS" || true)"
[ "$T3_LINES" = 6 ] && pass_ "T3 SHA256SUMS lists all 6 haps" \
                   || fail_ "T3 SHA256SUMS lists $T3_LINES entries (expected 6)"
if ( cd "$OUT3" && sha256sum -c SHA256SUMS > "$WORK/T3-check.log" 2>&1 ); then
    pass_ "T3 sha256sum -c SHA256SUMS passes"
else
    fail_ "T3 sha256sum -c failed (see $WORK/T3-check.log)"
fi
T3_PUBS="$(grep -c 'fake-dotnet publish ' "$WORK/fake-dotnet-t3.log" || true)"
[ "$T3_PUBS" = 3 ] && pass_ "T3 the fake dotnet published exactly 3 times" \
                   || fail_ "T3 the fake dotnet ran $T3_PUBS times"
assert_contains "T3 the aot publish reached dotnet" "-p:OpenHarmonyRuntimeMode=aot" "$WORK/fake-dotnet-t3.log"

# ---- T4: negative gates -----------------------------------------------------------------
section "T4 negative gates"
OUT4="$WORK/out-t4"
FAKE_DROP_AOT_LIB=1 DOTNET="$FAKEBIN/dotnet" run_mk T4-aot --project "$FIX/FakeApp.csproj" \
    --tfm t --out-dir "$OUT4-aot" --mode aot
assert_rc 1 $LAST_RC "T4 aot without lib<stem>.so fails"
assert_contains "T4 the aot error names the library" "carries no libs/arm64-v8a/libFakeApp.so" "$WORK/T4-aot.err"
assert_contains "T4 the aot error names the publish flags" "-p:PublishAot=true" "$WORK/T4-aot.err"
FAKE_DROP_CLRINTERP=1 DOTNET="$FAKEBIN/dotnet" run_mk T4-interp --project "$FIX/FakeApp.csproj" \
    --tfm t --out-dir "$OUT4-interp" --mode interp --interp-pack "$FIX/pack"
assert_rc 1 $LAST_RC "T4 interp without libclrinterpreter.so fails"
assert_contains "T4 the interp error names the missing library" "carries no libs/arm64-v8a/libclrinterpreter.so" "$WORK/T4-interp.err"
FAKE_WRONG_MARKER=aot DOTNET="$FAKEBIN/dotnet" run_mk T4-marker --project "$FIX/FakeApp.csproj" \
    --tfm t --out-dir "$OUT4-marker" --mode jit
assert_rc 1 $LAST_RC "T4 a mismatching marker fails"
assert_contains "T4 the marker error shows the expected mode" "expected 'jit'" "$WORK/T4-marker.err"
FAKE_FAIL_PUBLISH=1 DOTNET="$FAKEBIN/dotnet" run_mk T4-fail --project "$FIX/FakeApp.csproj" \
    --tfm t --out-dir "$OUT4-fail" --mode jit
assert_rc 1 $LAST_RC "T4 a failed publish fails the run"
assert_contains "T4 the failure shows the publish log tail" "simulated publish failure" "$WORK/T4-fail.err"
FAKE_NO_WRITE=1 DOTNET="$FAKEBIN/dotnet" run_mk T4-nowrite --project "$FIX/FakeApp.csproj" \
    --tfm t --out-dir "$OUT4-nowrite" --mode jit
assert_rc 1 $LAST_RC "T4 a publish that writes no hap fails"
assert_contains "T4 the no-hap error names the expected names" "looked for FakeApp.hap" "$WORK/T4-nowrite.err"
run_mk T4-pack --project "$FIX/FakeApp.csproj" --tfm t --out-dir "$OUT4-pack" --mode interp \
    --interp-pack "$FIX/pack-coreclr-only"
assert_rc 1 $LAST_RC "T4 an incomplete interp pack fails"
assert_contains "T4 the pack error names libclrinterpreter.so" "carries no libclrinterpreter.so" "$WORK/T4-pack.err"
# A stale hap from an earlier publish must be removed before the publish, so it cannot pass as
# this run's output when the publish writes nothing.
mkdir -p "$FIX/bin/Release/t/openharmony-arm64"
printf 'stale-not-a-zip' > "$FIX/bin/Release/t/openharmony-arm64/FakeApp.hap"
FAKE_NO_WRITE=1 DOTNET="$FAKEBIN/dotnet" run_mk T4-stale --project "$FIX/FakeApp.csproj" \
    --tfm t --out-dir "$OUT4-stale" --mode jit
assert_rc 1 $LAST_RC "T4 a stale hap cannot pass as a publish"
if [ ! -f "$FIX/bin/Release/t/openharmony-arm64/FakeApp.hap" ]; then
    pass_ "T4 the stale hap was removed before the publish"
else
    fail_ "T4 the stale hap survived the publish"
fi

# ---- T5: signing passthrough ------------------------------------------------------------
section "T5 signing"
OUT5="$WORK/out-t5"
FAKE_SIGN_LOG="$WORK/fake-sign-t5.log" SIGN_FOR_DEVICE="$FAKEBIN/fake-sign" DOTNET="$FAKEBIN/dotnet" \
    run_mk T5 --project "$FIX/FakeApp.csproj" --tfm t --out-dir "$OUT5" --mode jit,aot \
    --sign 0123456789ABCDEF --external --profile /tmp/ext.p7b --key-alias demo
assert_rc 0 $LAST_RC "T5 --sign exits 0"
T5_SIGNS="$(grep -c . "$WORK/fake-sign-t5.log" || true)"
[ "$T5_SIGNS" = 2 ] && pass_ "T5 signs once per selected mode" \
                   || fail_ "T5 ran the signer $T5_SIGNS times (expected 2)"
assert_contains "T5 the sign call passes the passthrough tail" "--external --profile /tmp/ext.p7b --key-alias demo" "$WORK/fake-sign-t5.log"
assert_contains "T5 the sign call passes the UDID" "0123456789ABCDEF" "$WORK/fake-sign-t5.log"
assert_contains "T5 the sign call signs the mode hap" "--unsigned $OUT5/jit/FakeApp-jit.hap" "$WORK/fake-sign-t5.log"
assert_contains "T5 the sign call signs the aot hap" "--unsigned $OUT5/aot/FakeApp-aot.hap" "$WORK/fake-sign-t5.log"
assert_not_contains "T5 no password enters the signer argv" "--password" "$WORK/fake-sign-t5.log"
T5_MARK="$(hap_marker "$OUT5/aot/FakeApp-aot.hap")"
[ "$T5_MARK" = aot ] && pass_ "T5 the signed hap still reads its marker" \
                     || fail_ "T5 the signed hap marker is '$T5_MARK'"
if [ "$(tail -c 12 "$OUT5/aot/FakeApp-aot.hap")" = "fake-signed" ]; then
    pass_ "T5 the successful sign replaced the mode hap in place"
else
    fail_ "T5 the successful sign left the hap untouched"
fi
if [ -z "$(find "$OUT5" -name '*.signed.*' -print 2>/dev/null)" ]; then
    pass_ "T5 no temporary sign output is left behind"
else
    fail_ "T5 a temporary sign output remained under $OUT5"
fi
# Failure: the original hap stays, no temp output, non-zero.
FAKE_SIGN_FAIL=1 FAKE_SIGN_LOG="$WORK/fake-sign-t5-fail.log" SIGN_FOR_DEVICE="$FAKEBIN/fake-sign" \
    DOTNET="$FAKEBIN/dotnet" run_mk T5-fail --project "$FIX/FakeApp.csproj" --tfm t \
    --out-dir "$OUT5-fail" --mode jit --sign 00FF
assert_rc 1 $LAST_RC "T5 a failing signer fails the run"
assert_contains "T5 the failure names the mode" "signing failed (jit)" "$WORK/T5-fail.err"
if [ -z "$(find "$OUT5-fail" -name '*.signed.*' -print 2>/dev/null)" ]; then
    pass_ "T5 no temporary output survives a failed sign"
else
    fail_ "T5 a temporary output survived the failed sign"
fi
if [ "$(tail -c 12 "$OUT5-fail/jit/FakeApp-jit.hap")" = "fake-signed" ]; then
    fail_ "T5 the failed sign replaced the hap anyway"
else
    pass_ "T5 the failed sign kept the published hap bytes"
fi

# ---- summary ----------------------------------------------------------------------------
section "summary"
log "checks: $CHECKS, failed: $FAILED, skipped: $SKIP"
if [ "$FAILED" -gt 0 ]; then
    log "SELFTEST FAILED - work dir kept: $WORK"
    exit 1
fi
log "SELFTEST OK - the runtime-mode kit builds and verifies jit/aot/interp from the MS-MODE switch"
if [ "$KEEP" = "1" ]; then
    log "work dir kept (SELFTEST_KEEP=1): $WORK"
else
    rm -rf "$WORK"
fi
exit 0
