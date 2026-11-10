#!/bin/sh
# selftest-selfsign.sh - functional gate for the workload's standalone OpenHarmony ELF signer.
#
#   S1 build      src/selfsign builds Release from the workload's own ElfSigner source
#   S2 sign       a minimal ELF64 gets a .codesign section; a second run is a byte-identical no-op
#   S3 strip      --strip removes the section and the stripped copy signs again
#   S4 refusals   a non-ELF and a symbolic link are refused with the documented exit codes
#   S5 wrapper    scripts/selfsign.sh builds/uses the workload CLI (no sdk-ohos checkout needed)
#   S6 contain    selfsign.sh and Program.cs carry no sdk-ohos / Microsoft.NET.Build.Tasks path
#
# Env: SELFTEST_TMPDIR=<dir>  work dir base (default: the approved opencode tmp dir)
#      DOTNET=<dotnet>       SDK used for the build (default: dotnet)
#      SELFTEST_KEEP=1       keep the work dir even when all checks pass
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="1 (2026-11-10)"
SELF_SIGN_PROJECT="src/selfsign/SelfSign.csproj"
SELF_SIGN_DLL="src/selfsign/bin/Release/net11.0/selfsign.dll"

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

W="$(cd "$(dirname "$0")/.." && pwd)"
WORK_BASE="${SELFTEST_TMPDIR:-/data/storage/el2/base/tmp/opencode}"
KEEP="${SELFTEST_KEEP:-0}"
DOTNET="${DOTNET:-dotnet}"

for _t in python3 mktemp cmp grep; do
    command -v "$_t" >/dev/null 2>&1 || { printf 'FATAL: required command not found: %s\n' "$_t" >&2; exit 1; }
done

WORK="$(mktemp -d "$WORK_BASE/selftest-selfsign.XXXXXX")" || {
    printf 'FATAL: cannot create a work dir under %s\n' "$WORK_BASE" >&2
    exit 1
}
CHECKS=0
FAILED=0

pass_() { CHECKS=$((CHECKS + 1)); printf '  [PASS] %s\n' "$*"; }
fail_() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$*" >&2; }
cleanup() {
    if [ "$KEEP" = "1" ] || [ "$FAILED" -ne 0 ]; then
        printf 'work dir kept: %s\n' "$WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

log "selftest-selfsign v$SELFTEST_VERSION"
log "work: $WORK"

# A minimal ELF64 with a null section and a .shstrtab section: ElfSigner needs a usable section
# header table before it can append .codesign. Same fixture shape the task unit tests use.
make_elf() {
    python3 - "$1" <<'PY'
import struct, sys
ident = bytearray(16)
ident[0:4] = b'\x7fELF'
ident[4] = 2   # ELFCLASS64
ident[5] = 1   # ELFDATA2LSB
ident[6] = 1   # EV_CURRENT
shstr = b'\x00.shstrtab\x00'
shoff = 64
shnum = 2
shstrndx = 1
shstroff = shoff + shnum * 64
hdr = bytes(ident) + struct.pack('<HHIQQQIHHHHHH', 2, 183, 1, 0, 0, shoff, 0, 64, 0, 0, 64, shnum, shstrndx)
s0 = bytes(64)
s1 = struct.pack('<IIQQQQIIQQ', 1, 3, 0, 0, shstroff, len(shstr), 0, 0, 1, 0)
open(sys.argv[1], 'wb').write(hdr + s0 + s1 + shstr)
PY
}

run_sign() { # <label> <expected-rc> <needle> <args...>
    _label=$1; _want=$2; _needle=$3; shift 3
    _out="$WORK/out.$CHECKS"
    "$DOTNET" "$W/$SELF_SIGN_DLL" "$@" >"$_out" 2>&1
    _rc=$?
    if [ "$_rc" -eq "$_want" ] && grep -qF -- "$_needle" "$_out"; then
        pass_ "$_label"
    else
        fail_ "$_label (rc=$_rc, wanted $_want; output: $(tr '\n' ' ' < "$_out"))"
    fi
}

section "S1 build"
if "$DOTNET" build "$W/$SELF_SIGN_PROJECT" -c Release -v:q --nologo >"$WORK/build.log" 2>&1; then
    pass_ "S1 the standalone signer builds"
else
    fail_ "S1 the standalone signer built (see $WORK/build.log)"
    sed -n '1,40p' "$WORK/build.log" >&2
fi
if [ -f "$W/$SELF_SIGN_DLL" ]; then
    pass_ "S1 the Release assembly exists"
else
    fail_ "S1 the Release assembly exists"
fi

section "S2 sign and idempotence"
ELF="$WORK/elf"
make_elf "$ELF"
size_before=$(wc -c < "$ELF" | tr -d ' ')
run_sign "S2 the first run signs in place" 0 "selfsign ok" "$ELF"
size_after=$(wc -c < "$ELF" | tr -d ' ')
if [ "$size_after" -gt "$size_before" ]; then
    pass_ "S2 the .codesign section grew the file ($size_before -> $size_after)"
else
    fail_ "S2 the .codesign section grew the file ($size_before -> $size_after)"
fi
cp "$ELF" "$WORK/signed.once"
run_sign "S2 a second run reports the signature valid" 0 "signature already valid" "$ELF"
if cmp -s "$ELF" "$WORK/signed.once"; then
    pass_ "S2 a second run is byte-identical"
else
    fail_ "S2 a second run is byte-identical"
fi

section "S3 strip and re-sign"
run_sign "S3 --strip writes the stripped copy" 0 "strip ok" --strip "$ELF" "$WORK/stripped"
run_sign "S3 a second strip reports no section" 0 "no .codesign section to strip" --strip "$WORK/stripped" "$WORK/stripped.again"
cp "$WORK/stripped" "$WORK/stripped.sign"
run_sign "S3 the stripped copy signs again" 0 "selfsign ok" "$WORK/stripped.sign"

section "S4 refusals"
printf 'not an elf\n' > "$WORK/plain.txt"
run_sign "S4 a non-ELF is refused" 1 "not an ELF64" "$WORK/plain.txt"
ln -s "$ELF" "$WORK/link"
run_sign "S4 a symbolic link is refused" 2 "symbolic link" "$WORK/link"

section "S5 wrapper"
WRAP="$WORK/wrapper"
make_elf "$WRAP"
if DOTNET="$DOTNET" sh "$W/scripts/selfsign.sh" "$WRAP" >"$WORK/wrapper.log" 2>&1 \
    && grep -qF "selfsign ok" "$WORK/wrapper.log"; then
    pass_ "S5 selfsign.sh signs through the workload CLI"
else
    fail_ "S5 selfsign.sh signs through the workload CLI (see $WORK/wrapper.log)"
fi

section "S6 containment"
if grep -qE 'sdk-ohos|SDK_REPO|Microsoft\.NET\.Build\.Tasks' "$W/scripts/selfsign.sh" "$W/src/selfsign/Program.cs"; then
    fail_ "S6 no sdk-ohos/Microsoft.NET.Build.Tasks dependency remains"
else
    pass_ "S6 no sdk-ohos/Microsoft.NET.Build.Tasks dependency remains"
fi

printf '\n=== summary ===\n'
printf '[%s] checks: %s, failed: %s\n' "$(date '+%H:%M:%S')" "$CHECKS" "$FAILED"
if [ "$FAILED" -ne 0 ]; then
    printf '[%s] SELFTEST FAILED - %s check(s) failed\n' "$(date '+%H:%M:%S')" "$FAILED" >&2
    exit 1
fi
printf '[%s] SELFTEST OK - the workload signer builds, signs, re-signs and refuses bad input\n' "$(date '+%H:%M:%S')"
exit 0
