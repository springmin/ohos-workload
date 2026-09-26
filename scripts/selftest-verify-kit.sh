#!/bin/sh
# selftest-verify-kit.sh - repeatable, fully local selftest for scripts/verify-kit.sh (the
# tester-facing kit self-check) and its 2b deep assertions (kit #23+).
#
# Drives the real script against synthetic extracted kits built by the fixture helper below
# (python3 only: no device, no hdc, no network, no binutils, no compiler) and asserts exit
# codes plus the exact graded lines. Scenarios:
#   S0 policy     the HOST_DEPS_DEFAULT copy embedded in verify-kit.sh carries exactly the
#                 [needed]/[undefined] entries of src/OpenHarmonyHost/host-deps.conf
#   S1 good       a kit that satisfies the current contract -> exit 0, KIT OK, every 2b
#                 assertion passes (index 1588 B, abc 264136 B / PANDA 13.0.1.0, 14 .so,
#                 payload-in-libs marker (assembly + 19 entries + zip sha), DT_NEEDED=5,
#                 denylist 0, dotnet.zip 254 entries / 0 .so); S1b reruns the same kit to
#                 prove the check leaves no state behind
#   S2 noindex    one hap loses resources.index -> exit 1, FAIL names it and FIX-DEV3 0f26b74
#   S3 emptyindex resources.index is 0 B -> exit 1 ("0 B 空文件")
#   S4 bigindex   resources.index 4096 B -> WARN only, exit 0 (historical/soft drift)
#   S5 abcdrift   abc 214000 B -> WARN + KIT OK by default; --expected-abc 264136 -> FAIL;
#                 abc 18532 B (the headless shell) stays accepted without a warning
#   S6 abcver     abc PANDA version 12.9.9.9 -> exit 1
#   S7 libs       13 .so -> exit 1 (a runtime ELF is missing); 15 .so -> WARN only
#   S8 dotnetzip  dotnet.zip carrying a .so -> exit 1; 254 entries -> WARN only
#   S9 needed     host DT_NEEDED with libhilog_ndk.z.so -> exit 1 (whitelist)
#   S10 denylist  host with an undefined OH_LOG_Print -> exit 1 (nm -D -u denylist)
#   S11 hostfxr   host DT_NEEDED with libhostfxr.so -> exit 1 (dedicated message)
#   S12 hostdeps  --host-deps canonical -> exit 0; narrowed whitelist -> exit 1; missing file
#                 -> exit 2; a policy without [undefined] entries -> exit 1 (fail closed)
#   S13 usage     --expected-abc with a non-numeric token -> exit 2; unknown option -> exit 2
#   S14 payload   payload-in-libs marker mutants -> exit 1: marker missing, entry count drift,
#                 zip-sha mismatch, entry assembly not staged
#
# The kit fixture mirrors the real one: five haps (module.json / ets/modules.abc /
# resources.index / resources/rawfile/dotnet.zip / libs/arm64-v8a/*.so + the payload-in-libs
# marker and payload files), 自签说明.md, 签名说明.txt, the repository's verify-kit.sh and a
# regenerated SHA256SUMS (so step 1 passes and only the 2b assertion under test decides). The
# host ELF is hand-built ELF64 LE with PT_LOAD + PT_DYNAMIC + DT_NEEDED/DT_STRTAB/DT_SYMTAB/
# DT_HASH, so no toolchain is involved.
#
# Env: SELFTEST_TMPDIR=<dir>  work dir base (default: the approved opencode tmp dir)
#      SELFTEST_KEEP=1       keep the work dir even when all checks pass
#      SELFTEST_VERIFY_KIT=<path>  the script under test (default: next to this selftest)
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="1 (2026-09-24)"

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

# ---- paths ---------------------------------------------------------------------------
SELFTEST_DIR="$(cd "$(dirname "$0")" && pwd)"
VERIFY_SCRIPT="${SELFTEST_VERIFY_KIT:-$SELFTEST_DIR/verify-kit.sh}"
ROOT_DIR="$(cd "$SELFTEST_DIR/.." && pwd)"
CANONICAL_POLICY="$ROOT_DIR/src/OpenHarmonyHost/host-deps.conf"
WORK_BASE="${SELFTEST_TMPDIR:-/data/storage/el2/base/tmp/opencode}"
KEEP="${SELFTEST_KEEP:-0}"

if [ ! -f "$VERIFY_SCRIPT" ]; then
    printf 'FATAL: verify-kit.sh not found: %s\n' "$VERIFY_SCRIPT" >&2
    exit 1
fi
if [ ! -f "$CANONICAL_POLICY" ]; then
    printf 'FATAL: canonical host policy not found: %s\n' "$CANONICAL_POLICY" >&2
    exit 1
fi
for _t in python3 sha256sum grep sed mktemp cmp sort awk cp; do
    if ! command -v "$_t" >/dev/null 2>&1; then
        printf 'FATAL: required command not found: %s\n' "$_t" >&2
        exit 1
    fi
done

WORK="$(mktemp -d "$WORK_BASE/selftest-verify-kit.XXXXXX")" || {
    printf 'FATAL: cannot create a work dir under %s\n' "$WORK_BASE" >&2
    exit 1
}
GOOD_KIT="$WORK/kit-good"
LOG_FILE="$WORK/verify.log"
CHECKS=0
FAILED=0
RC=0

log "selftest-verify-kit v$SELFTEST_VERSION - script under test: $VERIFY_SCRIPT"

pass_() { CHECKS=$((CHECKS + 1)); printf '  [PASS] %s\n' "$*"; }
fail_() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$*" >&2; }
assert_rc() { # <expected> <actual> <label>
    if [ "$2" -eq "$1" ]; then pass_ "$3 (exit $2)"; else fail_ "$3 (expected exit $1, got $2)"; fi
}
assert_contains() { # <label> <needle> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then pass_ "$1"; else fail_ "$1 (missing: $2)"; fi
}
assert_not_contains() { # <label> <needle> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then fail_ "$1 (unexpected: $2)"; else pass_ "$1"; fi
}

# run_verify <kit-dir> [args...] -> RC; output in $LOG_FILE
run_verify() {
    LOG_FILE="$WORK/verify.log"
    ( cd "$ROOT_DIR" && sh "$VERIFY_SCRIPT" "$@" ) > "$LOG_FILE" 2>&1
    RC=$?
}

# new_kit <name> -> copies the good kit and prints the copy's path
new_kit() {
    cp -r "$GOOD_KIT" "$WORK/$1" || { printf 'FATAL: cannot copy the fixture kit\n' >&2; exit 1; }
    printf '%s' "$WORK/$1"
}

# ---- fixture helper -------------------------------------------------------------------
cat > "$WORK/fixture.py" <<'FIXTURE_EOF'
#!/usr/bin/env python3
"""Fixture builder for selftest-verify-kit.sh: a synthetic kit that matches the current
verify-kit.sh contract plus the mutations for the negative cases. Only the standard library
is used; the host ELF is generated byte by byte (ELF64 LE, PT_LOAD + PT_DYNAMIC, DT_NEEDED /
DT_STRTAB / DT_SYMTAB / DT_HASH) so no compiler or binutils is needed."""
import hashlib
import io
import json
import os
import shutil
import struct
import sys
import zipfile

HAPS = [
    "hello-maui-app.hap",
    "hello-maui-app-permissions.hap",
    "hello-maui-app-api20.hap",
    "hello-maui-app-api20-permissions.hap",
    "hello-maui-app-unsigned.hap",
]
# The 14 libs of a shipped hap: host + libc++ + the 12 runtime ELF.
LIBS = [
    "libopenharmonyhost.so",
    "libcoreclr.so", "libclrgc.so", "libclrgcexp.so", "libclrjit.so",
    "libhostfxr.so", "libhostpolicy.so", "libmscordaccore.so", "libmscordbi.so",
    "libSystem.Native.so", "libSystem.Globalization.Native.so",
    "libSystem.IO.Compression.Native.so", "libSystem.Security.Cryptography.Native.OpenSsl.so",
    "libc++_shared.so",
]
NEEDED = ["libace_napi.z.so", "libace_ndk.z.so", "libnative_drawing.so",
          "libc++_shared.so", "libc.so"]
MODULE = {
    "app": {"bundleName": "com.example.hellomauiapp", "versionName": "1.0.0",
            "minAPIVersion": 50002014, "targetAPIVersion": 60101024, "apiReleaseType": "Release"},
    "module": {"name": "entry", "type": "entry", "requestPermissions": []},
}
ABC_SIZE = 264136
ABC_VERSION = (13, 0, 1, 0)
INDEX_SIZE = 1588
DOTNET_ENTRIES = 254
# Payload-in-libs fixture: the marker plus the small synthetic payload the selftest stages in
# libs/arm64-v8a/. The marker's entry count describes the real libs file count (marker
# excluded): the 14 .so plus the payload files below.
PAYLOAD_MARKER = "libs/arm64-v8a/.dotnet-payload.json"
PAYLOAD_ASSEMBLY = "hello-maui-app.dll"
PAYLOAD_FILES = [
    PAYLOAD_ASSEMBLY,
    "hello-maui-app.runtimeconfig.json",
    "hello-maui-app.deps.json",
    "System.Private.CoreLib.dll",
    "wwwroot/index.html",
]


def payload_entries(libs):
    return len(libs) + len(PAYLOAD_FILES)


def good_payload_marker(dotnet, entries):
    return json.dumps({
        "schema": 1,
        "assembly": PAYLOAD_ASSEMBLY,
        "entries": entries,
        "payloadEntries": DOTNET_ENTRIES,
        "payloadBytes": 38 * 1024 * 1024,
        "zipEntries": DOTNET_ENTRIES,
        "zipSha256": hashlib.sha256(dotnet).hexdigest(),
    }).encode()


def refresh_marker(items):
    """Rewrites the payload marker from the current libs/zip content, the way the packaging
    target does: count + zip entry count + zip sha256. Used by the mutations that change the
    libs file set or the zip but are not about the marker itself, so those scenarios keep
    testing exactly the assertion they name."""
    data = dict(items)
    if PAYLOAD_MARKER not in data or "resources/rawfile/dotnet.zip" not in data:
        return items
    dotnet = data["resources/rawfile/dotnet.zip"]
    marker = json.loads(data[PAYLOAD_MARKER])
    marker["entries"] = sum(1 for n in data if n.startswith("libs/arm64-v8a/") and not n.endswith("/")) - 1
    with zipfile.ZipFile(io.BytesIO(dotnet)) as dz:
        marker["zipEntries"] = len(dz.namelist())
    marker["payloadEntries"] = marker["zipEntries"]
    marker["zipSha256"] = hashlib.sha256(dotnet).hexdigest()
    data[PAYLOAD_MARKER] = json.dumps(marker).encode()
    return [(n, data[n]) for n, _ in items]


def _align(n, a=8):
    return (n + a - 1) // a * a


def good_abc(size=ABC_SIZE, version=ABC_VERSION):
    # PANDA magic (8) + checksum (4) + 4-byte version at 0x0c + zero fill.
    return b"PANDA\0\0\0" + b"\0\0\0\0" + bytes(version) + b"\0" * (size - 16)


def good_index(size=INDEX_SIZE):
    return (b"RI\x01" + bytes(range(256)) * ((size // 256) + 1))[:size]


def good_dotnet(entries=DOTNET_ENTRIES, extra_so=()):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for i in range(entries):
            z.writestr(zipfile.ZipInfo("lib/file%03d.dll" % i, (1980, 1, 1, 0, 0, 0)), b"fixture")
        for name in extra_so:
            z.writestr(zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0)), b"\x7fELF fixture")
    return buf.getvalue()


def build_host_so(needed_extra=(), undef_extra=()):
    """ELF64 LE ET_DYN with one PT_LOAD (vaddr == offset) and one PT_DYNAMIC."""
    names = list(NEEDED) + list(needed_extra)
    strings = b"\0"
    off = {}
    for n in names + ["host_probe_symbol"] + list(undef_extra):
        off[n] = len(strings)
        strings += n.encode() + b"\0"
    ehsize, phentsize, phnum = 64, 56, 2
    off_dynstr = _align(ehsize + phentsize * phnum)
    off_symtab = _align(off_dynstr + len(strings))
    symbols = [struct.pack("<IBBHQQ", 0, 0, 0, 0, 0, 0)]                      # null symbol
    symbols.append(struct.pack("<IBBHQQ", off["host_probe_symbol"], 0x12, 0, 1, 0, 0))
    for n in undef_extra:                                                     # undefined
        symbols.append(struct.pack("<IBBHQQ", off[n], 0x12, 0, 0, 0, 0))
    symtab = b"".join(symbols)
    off_hash = _align(off_symtab + len(symtab))
    nsym = len(symbols)
    hash_tab = struct.pack("<II", 1, nsym) + b"\0" * 4 * (1 + nsym)
    off_dyn = _align(off_hash + len(hash_tab))
    dyn = [(1, off[n]) for n in names]                      # DT_NEEDED
    dyn += [(5, off_dynstr), (10, len(strings))]            # DT_STRTAB / DT_STRSZ
    dyn += [(6, off_symtab), (11, 24), (4, off_hash)]       # DT_SYMTAB / DT_SYMENT / DT_HASH
    dyn += [(0, 0)]                                         # DT_NULL
    dynamic = b"".join(struct.pack("<qQ", t, v) for t, v in dyn)
    total = off_dyn + len(dynamic)
    ident = b"\x7fELF" + bytes([2, 1, 1, 0]) + b"\0" * 8
    ehdr = ident + struct.pack("<HHIQQQIHHHHHH", 3, 183, 1, 0, ehsize, 0, 0,
                               ehsize, phentsize, phnum, 0, 0, 0)
    phdr_load = struct.pack("<IIQQQQQQ", 1, 5, 0, 0, 0, total, total, 0x1000)
    phdr_dyn = struct.pack("<IIQQQQQQ", 2, 6, off_dyn, off_dyn, off_dyn,
                           len(dynamic), len(dynamic), 8)
    buf = bytearray(total)
    buf[0:len(ehdr)] = ehdr
    buf[ehsize:ehsize + phentsize] = phdr_load
    buf[ehsize + phentsize:ehsize + phentsize * 2] = phdr_dyn
    buf[off_dynstr:off_dynstr + len(strings)] = strings
    buf[off_symtab:off_symtab + len(symtab)] = symtab
    buf[off_hash:off_hash + len(hash_tab)] = hash_tab
    buf[off_dyn:off_dyn + len(dynamic)] = dynamic
    return bytes(buf)


def write_haps(kit, abc=None, index=INDEX_SIZE, host=None, dotnet=None, libs=None):
    abc = good_abc() if abc is None else abc
    host = build_host_so() if host is None else host
    dotnet = good_dotnet() if dotnet is None else dotnet
    libs = LIBS if libs is None else libs
    for hap in HAPS:
        path = os.path.join(kit, hap)
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("module.json", json.dumps(MODULE))
            z.writestr("ets/modules.abc", abc)
            if index is not None:
                z.writestr("resources.index", good_index(index))
            z.writestr("resources/rawfile/dotnet.zip", dotnet)
            for name in libs:
                payload = host if name == "libopenharmonyhost.so" else b"\0" * 64
                z.writestr("libs/arm64-v8a/" + name, payload)
            # Payload-in-libs: the staged payload files and the marker the packaging writes.
            for name in PAYLOAD_FILES:
                z.writestr("libs/arm64-v8a/" + name, b"fixture payload")
            z.writestr(PAYLOAD_MARKER, good_payload_marker(dotnet, payload_entries(libs)))


def rebuild_sums(kit):
    names = sorted(HAPS + ["自签说明.md", "签名说明.txt", "verify-kit.sh"])
    lines = []
    for name in names:
        with open(os.path.join(kit, name), "rb") as f:
            lines.append("%s  %s" % (hashlib.sha256(f.read()).hexdigest(), name))
    with open(os.path.join(kit, "SHA256SUMS"), "w") as f:
        f.write("\n".join(lines) + "\n")


def build_good(kit, verify_script):
    os.makedirs(kit, exist_ok=True)
    write_haps(kit)
    for doc in ("自签说明.md", "签名说明.txt"):
        with open(os.path.join(kit, doc), "w") as f:
            f.write("fixture\n")
    shutil.copyfile(verify_script, os.path.join(kit, "verify-kit.sh"))
    rebuild_sums(kit)


def read_hap(path):
    with zipfile.ZipFile(path) as z:
        infos = z.infolist()
        items = [(i.filename, z.read(i.filename)) for i in infos]
    return items


def write_hap(path, items):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in items:
            z.writestr(zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0)), data)


def patch(kit, op, arg=None):
    for hap in HAPS:
        path = os.path.join(kit, hap)
        items = read_hap(path)
        if op == "drop-index":
            items = [(n, d) for n, d in items if n != "resources.index"]
        elif op == "empty-index":
            items = [(n, b"" if n == "resources.index" else d) for n, d in items]
        elif op == "big-index":
            items = [(n, good_index(int(arg)) if n == "resources.index" else d) for n, d in items]
        elif op == "abc-size":
            items = [(n, good_abc(int(arg)) if n == "ets/modules.abc" else d) for n, d in items]
        elif op == "abc-version":
            version = tuple(int(v) for v in arg.split("."))
            items = [(n, good_abc(ABC_SIZE, version) if n == "ets/modules.abc" else d) for n, d in items]
        elif op == "libs-count":
            want = int(arg)
            host = dict(items)["libs/arm64-v8a/libopenharmonyhost.so"]
            pool = [n for n in LIBS if n != "libopenharmonyhost.so"]
            keep = pool[:want - 1]
            while len(keep) < want - 1:
                keep.append("libextra%d.so" % len(keep))
            items = [(n, d) for n, d in items
                     if not (n.startswith("libs/arm64-v8a/") and n.endswith(".so"))]
            items.append(("libs/arm64-v8a/libopenharmonyhost.so", host))
            for name in keep:
                items.append(("libs/arm64-v8a/" + name, b"\0" * 64))
            items = refresh_marker(items)  # the .so count changed: keep the marker describing it
        elif op == "zip-so":
            items = [(n, good_dotnet(DOTNET_ENTRIES, extra_so=["libcoreclr.so"])
                      if n == "resources/rawfile/dotnet.zip" else d) for n, d in items]
            items = refresh_marker(items)
        elif op == "zip-entries":
            items = [(n, good_dotnet(int(arg)) if n == "resources/rawfile/dotnet.zip" else d)
                     for n, d in items]
            items = refresh_marker(items)
        elif op == "host-so":
            with open(arg, "rb") as f:
                host = f.read()
            items = [(n, host if n == "libs/arm64-v8a/libopenharmonyhost.so" else d)
                     for n, d in items]
        elif op in ("payload-drop-marker", "payload-entries", "payload-zipsha",
                    "payload-assembly", "payload-drop-assembly"):
            # Marker mutants: the payload-in-libs assertion under test, so the marker is NOT
            # refreshed afterwards (except dropping the assembly, where the count is fixed too
            # so exactly the missing-assembly assertion fires).
            data = dict(items)
            marker = json.loads(data[PAYLOAD_MARKER]) if PAYLOAD_MARKER in data else None
            if op == "payload-drop-marker":
                items = [(n, d) for n, d in items if n != PAYLOAD_MARKER]
            elif op == "payload-entries":
                marker["entries"] = int(arg)
            elif op == "payload-zipsha":
                marker["zipSha256"] = arg
            elif op == "payload-assembly":
                marker["assembly"] = arg
            elif op == "payload-drop-assembly":
                items = [(n, d) for n, d in items if n != "libs/arm64-v8a/" + PAYLOAD_ASSEMBLY]
                items = refresh_marker(items)
            if marker is not None and op != "payload-drop-marker" and op != "payload-drop-assembly":
                data = dict(items)
                data[PAYLOAD_MARKER] = json.dumps(marker).encode()
                items = [(n, data[n]) for n, _ in items]
        else:
            raise SystemExit("unknown patch op: %s" % op)
        write_hap(path, items)
    rebuild_sums(kit)


def main():
    cmd = sys.argv[1]
    if cmd == "good":
        build_good(sys.argv[2], sys.argv[3])
    elif cmd == "hostso":
        extra = sys.argv[3:]
        needed = [a[len("needed:"):] for a in extra if a.startswith("needed:")]
        undef = [a[len("undef:"):] for a in extra if a.startswith("undef:")]
        with open(sys.argv[2], "wb") as f:
            f.write(build_host_so(needed_extra=needed, undef_extra=undef))
    elif cmd == "patch":
        patch(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None)
    else:
        raise SystemExit("unknown command: %s" % cmd)

if __name__ == "__main__":
    main()
FIXTURE_EOF


# ---- S0: the embedded policy must match the canonical conf ---------------------------
section "S0 embedded host policy equals src/OpenHarmonyHost/host-deps.conf"
EMBEDDED_POLICY="$WORK/embedded-host-deps.conf"
awk '/^HOST_DEPS_DEFAULT=/{on=1; next} on && /^HOST_DEPS_EOF$/{on=0} on{print}' \
    "$VERIFY_SCRIPT" > "$EMBEDDED_POLICY"
policy_entries() { # <file> -> sorted "<section> <entry>" lines
    LC_ALL=C awk '/^\[needed\]/{s="needed";next} /^\[undefined\]/{s="undefined";next} /^\[/{s=""} \
        s!="" && $0 !~ /^[[:space:]]*#/ && NF {print s" "$1}' "$1" | LC_ALL=C sort
}
policy_entries "$EMBEDDED_POLICY" > "$WORK/embedded.entries"
policy_entries "$CANONICAL_POLICY" > "$WORK/canonical.entries"
if [ -s "$WORK/embedded.entries" ]; then
    pass_ "S0 the embedded HOST_DEPS_DEFAULT block exists and lists entries"
else
    fail_ "S0 the embedded HOST_DEPS_DEFAULT block was not found in $VERIFY_SCRIPT"
fi
if cmp -s "$WORK/embedded.entries" "$WORK/canonical.entries"; then
    pass_ "S0 embedded [needed]/[undefined] entries are identical to the canonical conf"
else
    fail_ "S0 the embedded policy drifted from $CANONICAL_POLICY"
    diff -u "$WORK/canonical.entries" "$WORK/embedded.entries" | sed 's/^/       /' >&2
fi

# ---- S1: the good kit passes every 2b assertion --------------------------------------
section "S1 good kit: index/abc/libs/host all match the current contract"
python3 "$WORK/fixture.py" good "$GOOD_KIT" "$VERIFY_SCRIPT"
run_verify "$GOOD_KIT"
cp "$LOG_FILE" "$WORK/S1a.log"
assert_rc 0 "$RC" "S1 good kit"
assert_contains "S1 KIT OK" "KIT OK" "$LOG_FILE"
assert_contains "S1 all 2b assertions pass" "全部关键断言通过" "$LOG_FILE"
assert_contains "S1 index 1588 B listed" "resources.index 1588 B（≤2 KiB 合理范围）" "$LOG_FILE"
assert_contains "S1 abc 264136 / PANDA 13.0.1.0" "ets/modules.abc 264136 B，PANDA 头版本 13.0.1.0" "$LOG_FILE"
assert_contains "S1 libs .so=14" "libs/arm64-v8a/: 14 个 .so" "$LOG_FILE"
assert_contains "S1 payload-in-libs marker staged + counted" "payload-in-libs: assembly=hello-maui-app.dll，条目=19（实测 19）" "$LOG_FILE"
assert_contains "S1 payload-in-libs marker zip bound" "zip=254/" "$LOG_FILE"
assert_contains "S1 host DT_NEEDED=5" "DT_NEEDED=5" "$LOG_FILE"
assert_contains "S1 host denylist 0" "denylist 命中=0" "$LOG_FILE"
assert_contains "S1 dotnet.zip 254 entries / 0 .so" "dotnet.zip entries=254，.so=0" "$LOG_FILE"

# The kit copy (what a tester actually runs) must behave identically.
( cd "$ROOT_DIR" && sh "$GOOD_KIT/verify-kit.sh" "$GOOD_KIT" ) > "$WORK/S1-kitcopy.log" 2>&1
RC=$?
assert_rc 0 "$RC" "S1 the kit's own verify-kit.sh copy"
assert_contains "S1 kit copy reports KIT OK" "KIT OK" "$WORK/S1-kitcopy.log"

# ---- S1b: a second consecutive run must give the same verdict ------------------------
section "S1b rerun: no state leak, identical verdict"
run_verify "$GOOD_KIT"
cp "$LOG_FILE" "$WORK/S1b.log"
assert_rc 0 "$RC" "S1b second run of the same kit"
assert_contains "S1b KIT OK" "KIT OK" "$LOG_FILE"
sed 's/^\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\] //' "$WORK/S1a.log" > "$WORK/S1a.norm"
sed 's/^\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\] //' "$WORK/S1b.log" > "$WORK/S1b.norm"
if cmp -s "$WORK/S1a.norm" "$WORK/S1b.norm"; then
    pass_ "S1b both runs printed the same lines (timestamps aside)"
else
    fail_ "S1b the two runs differ"
    diff -u "$WORK/S1a.norm" "$WORK/S1b.norm" | sed 's/^/       /' >&2
fi

# ---- S2: missing resources.index is the FIX-DEV3 defect ------------------------------
section "S2 missing resources.index -> FAIL with the FIX-DEV3 pointer"
K="$(new_kit kit-noindex)"
python3 "$WORK/fixture.py" patch "$K" drop-index
run_verify "$K"
assert_rc 1 "$RC" "S2 missing index fails"
assert_contains "S2 names resources.index" "缺 resources.index" "$LOG_FILE"
assert_contains "S2 points at FIX-DEV3 0f26b74" "0f26b74" "$LOG_FILE"
assert_contains "S2 KIT CHECK FAILED" "KIT CHECK FAILED" "$LOG_FILE"
assert_contains "S2 all five haps reported (FAIL 5)" "深度断言汇总：FAIL 5" "$LOG_FILE"

# ---- S3: a zero-byte index is also a defect ------------------------------------------
section "S3 empty resources.index -> FAIL"
K="$(new_kit kit-emptyindex)"
python3 "$WORK/fixture.py" patch "$K" empty-index
run_verify "$K"
assert_rc 1 "$RC" "S3 empty index fails"
assert_contains "S3 reports the empty file" "resources.index 是 0 B 空文件" "$LOG_FILE"

# ---- S4: an oversized index warns but keeps the run green ----------------------------
section "S4 oversized resources.index (4096 B) -> WARN only"
K="$(new_kit kit-bigindex)"
python3 "$WORK/fixture.py" patch "$K" big-index 4096
run_verify "$K"
assert_rc 0 "$RC" "S4 oversized index still KIT OK"
assert_contains "S4 warns about the size" "超出预期 ≤2048 B" "$LOG_FILE"
assert_contains "S4 KIT OK carries the WARN count" "KIT OK（5 条 WARN" "$LOG_FILE"

# ---- S5: abc size drift is a WARN by default, a FAIL when pinned ---------------------
section "S5 abc size drift: WARN by default, FAIL with --expected-abc"
K="$(new_kit kit-abcdrift)"
python3 "$WORK/fixture.py" patch "$K" abc-size 214000
run_verify "$K"
assert_rc 0 "$RC" "S5 drifted abc still KIT OK by default"
assert_contains "S5 warns about the drifted size" "abc 大小 214000 不是当前期望（264136/18532）" "$LOG_FILE"
assert_contains "S5 KIT OK carries the WARN count" "KIT OK（5 条 WARN" "$LOG_FILE"
run_verify "$K" --expected-abc 264136
assert_rc 1 "$RC" "S5 pinned --expected-abc 264136 turns the drift into a FAIL"
assert_contains "S5 reports the pinned set" "不在 --expected-abc 264136 内" "$LOG_FILE"
assert_contains "S5 KIT CHECK FAILED" "KIT CHECK FAILED" "$LOG_FILE"
K="$(new_kit kit-headlessabc)"
python3 "$WORK/fixture.py" patch "$K" abc-size 18532
run_verify "$K"
assert_rc 0 "$RC" "S5 headless abc (18532 B) is accepted"
assert_not_contains "S5 headless abc produces no size WARN" "不是当前期望" "$LOG_FILE"

# ---- S6: the PANDA header version is pinned ------------------------------------------
section "S6 abc PANDA version drift -> FAIL"
K="$(new_kit kit-abcver)"
python3 "$WORK/fixture.py" patch "$K" abc-version 12.9.9.9
run_verify "$K"
assert_rc 1 "$RC" "S6 abc version drift fails"
assert_contains "S6 names the version mismatch" "PANDA 头版本 12.9.9.9 != 13.0.1.0" "$LOG_FILE"

# ---- S7: the signed libs set must not shrink -----------------------------------------
section "S7 libs/arm64-v8a .so count: shrink FAILs, growth WARNs"
K="$(new_kit kit-libs13)"
python3 "$WORK/fixture.py" patch "$K" libs-count 13
run_verify "$K"
assert_rc 1 "$RC" "S7 13 libs fail (a runtime ELF is missing)"
assert_contains "S7 names the missing count" "只有 13 个 .so（期望 14）" "$LOG_FILE"
K="$(new_kit kit-libs15)"
python3 "$WORK/fixture.py" patch "$K" libs-count 15
run_verify "$K"
assert_rc 0 "$RC" "S7 15 libs still KIT OK"
assert_contains "S7 warns about the extra lib" "有 15 个 .so（期望 14）" "$LOG_FILE"

# ---- S8: dotnet.zip must not carry unsigned ELF copies -------------------------------
section "S8 dotnet.zip: a .so FAILs, an entry-count drift WARNs"
K="$(new_kit kit-zipso)"
python3 "$WORK/fixture.py" patch "$K" zip-so
run_verify "$K"
assert_rc 1 "$RC" "S8 .so inside dotnet.zip fails"
assert_contains "S8 names the leaked ELF" "dotnet.zip 含 1 个 .so: libcoreclr.so" "$LOG_FILE"
K="$(new_kit kit-zip255)"
python3 "$WORK/fixture.py" patch "$K" zip-entries 255
run_verify "$K"
assert_rc 0 "$RC" "S8 entry-count drift still KIT OK"
assert_contains "S8 warns about the entry count" "dotnet.zip 条目 255 != 期望 254" "$LOG_FILE"

# ---- S9/S10/S11: the host dependency discipline --------------------------------------
section "S9 host DT_NEEDED outside the whitelist -> FAIL"
python3 "$WORK/fixture.py" hostso "$WORK/host-needed.so" needed:libhilog_ndk.z.so
K="$(new_kit kit-needed)"
python3 "$WORK/fixture.py" patch "$K" host-so "$WORK/host-needed.so"
run_verify "$K"
assert_rc 1 "$RC" "S9 extra DT_NEEDED fails"
assert_contains "S9 names the offender" "宿主 DT_NEEDED 超出 host-deps.conf 白名单: libhilog_ndk.z.so" "$LOG_FILE"

section "S10 host undefined symbol in the denylist -> FAIL"
python3 "$WORK/fixture.py" hostso "$WORK/host-undef.so" undef:OH_LOG_Print
K="$(new_kit kit-undef)"
python3 "$WORK/fixture.py" patch "$K" host-so "$WORK/host-undef.so"
run_verify "$K"
assert_rc 1 "$RC" "S10 denylisted undefined symbol fails"
assert_contains "S10 names the symbol" "denylist 命中 1 个）: OH_LOG_Print" "$LOG_FILE"

section "S11 host DT_NEEDED libhostfxr.so -> FAIL with the load-order reason"
python3 "$WORK/fixture.py" hostso "$WORK/host-hostfxr.so" needed:libhostfxr.so
K="$(new_kit kit-hostfxr)"
python3 "$WORK/fixture.py" patch "$K" host-so "$WORK/host-hostfxr.so"
run_verify "$K"
assert_rc 1 "$RC" "S11 libhostfxr NEEDED fails"
assert_contains "S11 names libhostfxr.so" "宿主 DT_NEEDED 含 libhostfxr.so" "$LOG_FILE"

# ---- S12: --host-deps override and fail-closed policy handling ------------------------
section "S12 --host-deps: canonical OK, narrow FAILs, missing/broken fail closed"
run_verify "$GOOD_KIT" --host-deps "$CANONICAL_POLICY"
assert_rc 0 "$RC" "S12 canonical policy via --host-deps"
assert_contains "S12 uses the given policy" "宿主依赖策略：--host-deps" "$LOG_FILE"
printf '# selftest narrow policy\n[needed]\nlibace_napi.z.so\n\n[undefined]\nOH_LOG_\n' > "$WORK/narrow.conf"
run_verify "$GOOD_KIT" --host-deps "$WORK/narrow.conf"
assert_rc 1 "$RC" "S12 a narrowed whitelist fails the good kit"
assert_contains "S12 names the now-extra library" "超出 host-deps.conf 白名单: libace_ndk.z.so" "$LOG_FILE"
run_verify "$GOOD_KIT" --host-deps "$WORK/does-not-exist.conf"
assert_rc 2 "$RC" "S12 a missing policy file is bad usage"
assert_contains "S12 says the file is missing" "host-deps 策略文件不存在" "$LOG_FILE"
printf '[needed]\nlibace_napi.z.so\n' > "$WORK/nodef.conf"
run_verify "$GOOD_KIT" --host-deps "$WORK/nodef.conf"
assert_rc 1 "$RC" "S12 a policy without [undefined] entries fails closed"
assert_contains "S12 reports the empty denylist" "没有 [undefined] 条目" "$LOG_FILE"

# ---- S13: bad usage stays exit 2 ------------------------------------------------------
section "S13 bad usage -> exit 2"
run_verify "$GOOD_KIT" --expected-abc abc
assert_rc 2 "$RC" "S13 non-numeric --expected-abc"
run_verify "$GOOD_KIT" --no-such-option
assert_rc 2 "$RC" "S13 unknown option"

# ---- S14: the payload-in-libs marker is part of the per-hap contract ------------------
section "S14 payload-in-libs marker mutants -> FAIL"
K="$(new_kit kit-nopayload)"
python3 "$WORK/fixture.py" patch "$K" payload-drop-marker
run_verify "$K"
assert_rc 1 "$RC" "S14 missing payload marker fails"
assert_contains "S14 names the missing marker" "缺 libs/arm64-v8a/.dotnet-payload.json" "$LOG_FILE"
assert_contains "S14 points at the namespace reason" "唯一允许 dlopen 的目录" "$LOG_FILE"
assert_contains "S14 points at OpenHarmonyHapPayloadInLibs" "OpenHarmonyHapPayloadInLibs=true" "$LOG_FILE"

K="$(new_kit kit-payloadcount)"
python3 "$WORK/fixture.py" patch "$K" payload-entries 999
run_verify "$K"
assert_rc 1 "$RC" "S14 marker entry-count drift fails"
assert_contains "S14 reports the count drift" "payload marker entries=999 与实测" "$LOG_FILE"

K="$(new_kit kit-payloadsha)"
python3 "$WORK/fixture.py" patch "$K" payload-zipsha 0000000000000000000000000000000000000000000000000000000000000000
run_verify "$K"
assert_rc 1 "$RC" "S14 marker zip-sha mismatch fails"
assert_contains "S14 reports the sha mismatch" "回退 zip 不同源" "$LOG_FILE"

K="$(new_kit kit-payloadasm)"
python3 "$WORK/fixture.py" patch "$K" payload-assembly missing.dll
run_verify "$K"
assert_rc 1 "$RC" "S14 marker naming an unstaged assembly fails"
assert_contains "S14 names the missing assembly" "入口程序集 'missing.dll' 不在 libs/arm64-v8a/" "$LOG_FILE"

# ---- summary -------------------------------------------------------------------------
section "summary"
log "checks: $CHECKS, failed: $FAILED"
if [ "$FAILED" -gt 0 ]; then
    log "SELFTEST FAILED - work dir kept: $WORK"
    exit 1
fi
log "SELFTEST OK - the 2b deep assertions grade kit defects (index/abc/libs/dotnet.zip/host) as designed"
if [ "$KEEP" = "1" ]; then
    log "work dir kept (SELFTEST_KEEP=1): $WORK"
else
    rm -rf "$WORK"
fi
exit 0
