#!/bin/sh
# Tester-facing self-check for the OpenHarmony MAUI device-test kit ("delivery kit").
# Run it from inside the extracted kit (the directory that holds SHA256SUMS):
#   sh verify-kit.sh                 # current directory must contain SHA256SUMS
#   sh verify-kit.sh <kit-dir>       # or point it at the extracted kit
# Steps: (1) verify every file against SHA256SUMS (sha256sum -c); (2) summarize the five haps
# from their module.json (bundleName, min/target API, requestPermissions) and fail unless all
# carry the expected bundle name (KIT_BUNDLE_NAME, default com.example.hellomauiapp); (2b) assert
# the payload facts that failed on a real device before (each one per hap, see below); (2c) when
# the optional Blazor WASM component hap is present (hello-blazorwasm-host-unsigned.hap, built
# with --with-blazor), assert its embedded ArkWeb site (index.html, _framework wasm + boot
# script, the stable dotnet.js + its fingerprinted source, PANDA abc, bundle name, no
# site-level .br/.gz/.map or icudt*.dat) and record its
# requestPermissions set (a set that disagrees with the source-side expectation is a WARN, not
# a FAIL: kit #31 predates the source-side INTERNET removal); (3) warn
# (one line) that the four default haps are self-signed and rejected by a real device
# (9568257/9568344 -> re-sign hello-maui-app-unsigned.hap or use a pre-signed kit), plus the
# install options and the self-sign pointer; (4) list the log lines to send back.
#
# Runtime mode (AOT-DEFAULT, 2026-10-03): every MAUI hap carries libs/<abi>/runtime-mode.txt
# (aot|jit|interp; absent = a pre-MS-MODE JIT kit). The 2b expectations are per mode: jit keeps
# the 15-.so / 258-zip JIT contract; aot expects the NativeAOT shape (the app library
# lib<stem>.so named by resources/rawfile/app.json, host + libc++_shared.so, no libcoreclr.so,
# a 9-entry dotnet.zip); interp additionally requires libclrinterpreter.so. The kit-root
# runtime-mode.txt, when present, is cross-checked against every MAUI hap marker. An unknown
# marker value is a FAIL (the packaging already rejects it, so it means drift).
#
# 2b assertions (per hap; FAIL -> exit 1, WARN -> printed but still KIT OK):
#   resources.index  present and non-empty (FAIL when missing/empty, pointing at FIX-DEV3
#                    0f26b74: dotnet publish must pack it with --index-path, or the device
#                    ResourceManager rejects the rawfile read with "GetRawFileContent failed,
#                    name is empty" and the managed bootstrap never starts). A size above the
#                    current cap only warns (resources/permissions grew -> review the
#                    expectation).
#   abc header       ets/modules.abc must be a PANDA file whose 4-byte version field at 0x0c is
#                    13.0.1.0 (FAIL otherwise), and its size must be one of the current
#                    expectations - 476516 for the ui/shell shell, 24324 for the headless shell
#                    (--expected-abc <bytes[,bytes]> / KIT_EXPECTED_ABC pins the set; a size
#                    outside it then FAILs instead of warning, so a historical kit's old abc
#                    does not kill the run).
#   libs             libs/arm64-v8a/: mode-aware. jit expects exactly 15 .so files (fewer = a
#                    runtime ELF is missing and the device loader will refuse the hap -> FAIL;
#                    more = WARN, update the expectation when the runtime file set really
#                    changed; kit #41 added createdump.so via the DEVCOMPAT-DEFAULT `.so`
#                    rewrite). aot expects >= 3 (host + libc++_shared.so + the NativeAOT app
#                    library lib<stem>.so) and FAILs when lib<stem>.so is missing; a hap marked
#                    aot must not carry libcoreclr.so. interp adds libclrinterpreter.so to the
#                    JIT set.
#   payload-in-libs  libs/arm64-v8a/.dotnet-payload.json exists and is self-consistent: the
#                    entry assembly it names is staged in the libs directory, its file count
#                    equals the real libs file count (marker excluded), payloadEntries equals
#                    zipEntries, and its zipSha256 equals the bytes of
#                    resources/rawfile/dotnet.zip. The staged payload is the namespace-allowed
#                    copy the runtime starts from (el1/bundle/libs/<abi> is the only directory
#                    the device lets a dlopen come from), so a missing or inconsistent marker
#                    means the app would fall back to the refused data-directory extraction
#                    -> FAIL. A hap packed with -p:OpenHarmonyHapPayloadInLibs=false fails this
#                    check by design.
#   dotnet.zip       readable -> must carry no .so (an unsigned duplicate would be dlopen'd from
#                    the extracted app dir and rejected by an enforcing device -> FAIL) and its
#                    entry count is expected to stay 258 on a jit hap / 9 on an aot hap (drift =
#                    WARN; kit #41 added the MULTI-OVERLAY-FULL hybrid-a/b/c.html demo assets).
#   host ELF         libs/arm64-v8a/libopenharmonyhost.so: DT_NEEDED (readelf -d equivalent)
#                    must be a subset of the host-deps.conf [needed] whitelist, must not name
#                    libhostfxr.so (resolved through the dlopen handle, never at load time), and
#                    the dynamic undefined symbols (nm -D -u equivalent) must not match the
#                    [undefined] denylist (IME/NativeWindow/Vibrator/Sensor/Location/NetConn/AT/
#                    ImageSource/Pixelmap/OH_LOG_). A direct reference means the dlopen/dlsym
#                    degradation in host_optional.c was bypassed and a reduced device image
#                    refuses to load the module. The DT_NEEDED/nm parsing is done in the same
#                    python3 pass as the zip reads, so testers need no binutils.
# The policy is embedded below because the script runs inside an extracted kit, where the
# repository is absent; --host-deps <file> / KIT_HOST_DEPS replaces it with the canonical
# src/OpenHarmonyHost/host-deps.conf (scripts/selftest-verify-kit.sh fails when the two drift).
# The 2b assertions are graded: only resources.index, the abc header version, a shrunken
# libs/, a .so inside dotnet.zip, the payload-in-libs marker, and the host DT_NEEDED/denylist
# failures are FAIL; an old abc size, a big index, extra libs and a zip entry-count drift are
# WARN, so a historical kit still reports its real defects without being killed for
# pre-contract values.
# The 2c Blazor assertions only run when the optional hello-blazorwasm-host-unsigned.hap is in
# the kit root (a kit without it logs one line and moves on). Every 2c deviation is FAIL: the
# component is self-contained, so a missing site file/abc/bundle or a slim leftover means the
# hap cannot serve the verified Blazor site. That includes the stable boot-loader name
# _framework/dotnet.js, which pack-host.sh materializes from the fingerprinted
# _framework/dotnet.<hash>.js asset (kits #31/#32 predate the mapping and FAIL this assertion).
# The one exception is the requestPermissions set:
# it is printed and compared with the source-side expectation (BLAZOR_SOURCE_PERMS, default
# empty because ohos-workload 2dcd846 removed INTERNET from the host's module.json5), and a
# disagreement is a WARN so a historical kit (#31 carries the pre-removal hap) keeps its real
# verdict. Override the name/bundle/permissions with KIT_BLAZOR_HAP /
# KIT_BLAZOR_BUNDLE / KIT_BLAZOR_PERMS (or --blazor-perms) for a kit packed differently.
# SHA256SUMS lives inside the archive it covers, so it proves internal consistency only:
#   1. check the transfer checksum of the .tar.gz: `sha256sum -c <kit>.tar.gz.sha256`, or let
#      this script check the tarball (--anchor / --anchor-file / KIT_ANCHOR);
#   2. extract the kit;
#   3. bind the exact tree with the published digest: --expect-tree-digest <sha256> (or
#      KIT_TREE_DIGEST); --tree-digest prints the digest for an out-of-band comparison.
# Tree digest: sha256 over the sorted kit contents - one "<file sha256>  <relative path>" line
# per regular file (SHA256SUMS and this script included), LC_ALL=C sorted by relative path and
# hashed again. Only relative path bytes and file contents are inputs (no modes/mtimes/owners/
# dir entries), so a mode-less extraction still matches. Transport leftovers are not content:
# a root-level archive (*.tar.gz/*.tgz/*.tar/*.tar.bz2/*.tar.xz/*.zip/*.7z) and its
# (*.sha256/*.sha1/*.md5/*.sha512) sidecar are skipped (named on stderr), so the common
# "extract in place" layout yields the clean-extraction digest; any other added file (e.g.
# .DS_Store) does change it, by design.
#
# Reuse (P16): step 1's `sha256sum -c` reads every file covered by SHA256SUMS, so the digest
# reuses those just-verified hashes instead of reading the same bytes a second time in one
# run. The reuse only covers entries whose check reported OK and whose inode/size/mtime pair
# was identical before and after the check; everything else (SHA256SUMS itself, docs outside
# the list, moved files) is hashed here from disk. Verification strength is unchanged: no
# hash is trusted unless it was computed against exactly these bytes in this run.
# --anchor does NOT bind the extracted tree (extraction happens outside this script). Both
# checks fail closed: missing/mismatching tarball, non-hex anchor, absent .tar.gz.sha256
# sidecar, non-hex or mismatching tree digest all fail.
# Exit: 0 = kit OK; 1 = checksum/anchor/tree-digest failure, missing/unreadable hap, unexpected
# bundleName, or a failed 2b/2c assertion, or absent 自签说明.md/签名说明.txt; 2 = SHA256SUMS not
# found (wrong directory) or bad usage. The kit's SHA256SUMS is not in its own list - the outer
# <kit>.tar.gz.sha256 covers it, and the tree digest covers SHA256SUMS itself.
set -e

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
fail_msg() { printf '[%s] FAIL: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

# Embedded copy of src/OpenHarmonyHost/host-deps.conf, the link policy scripts/build-host.sh
# enforces when the host is built. This script also runs inside an extracted kit, where the
# repository is not available, so the policy travels with it; --host-deps <file> /
# KIT_HOST_DEPS re-reads the canonical file when a checkout is at hand.
HOST_DEPS_DEFAULT="$(cat <<'HOST_DEPS_EOF'
# Link-time policy for libopenharmonyhost.so, enforced by scripts/build-host.sh.
# (Verbatim copy of src/OpenHarmonyHost/host-deps.conf; scripts/selftest-verify-kit.sh fails
#  when the entry lists drift apart.)
#
# The host ships to devices whose system image may be a reduced build (one observed
# HarmonyOS image is missing 10 NDK libraries and the API 12+ IME entry points). Anything
# that is not guaranteed to be present must be resolved with dlopen/dlsym at runtime
# (src/OpenHarmonyHost/host_optional.c) instead of a DT_NEEDED entry or a direct call.
#
# [needed]    - exact DT_NEEDED sonames allowed in the shipped .so. Keep this list to the
#               set observed on every test device; add a library only with device evidence.
# [undefined] - prefixes that must NOT appear in `nm -D -u` output. Each entry is the API
#               namespace of a dlopen/dlsym-degraded group; a direct reference means the
#               degradation was bypassed and the host would fail to load where the
#               library/symbol is absent.
#
# Format: one entry per line, '#' starts a comment, blank lines are ignored.

[needed]
# NAPI module registration + XComponent (libace_napi.z.so / libace_ndk.z.so): the ArkTS
# `import host from 'libopenharmonyhost.so'` path itself needs these, and both were
# present on the reduced test image.
libace_napi.z.so
libace_ndk.z.so
# OH_Drawing_* rendering surface: present on the reduced test image.
libnative_drawing.so
# Toolchain runtimes, always present.
libc++_shared.so
libc.so

[undefined]
# IME (inputmethod/*): API 12+ entry points were stripped from libace_ndk.z.so on the
# reduced test image.
OH_InputMethod
OH_TextEditorProxy
OH_AttachOptions
# NativeWindow (native_window/external_window.h): libnative_window.so absent on the
# reduced test image.
OH_NativeWindow_
# Vibrator (sensors/vibrator.h): libohvibrator.z.so absent on the reduced test image.
OH_Vibrator_
# Sensors (sensors/oh_sensor.h): libohsensor.so absent on the reduced test image.
OH_Sensor
# Location (LocationKit/oh_location*.h): liblocation_ndk.so absent on the reduced test image.
OH_Location
# Default-network capabilities (network/netmanager/net_connection.h): libnet_connection.so
# absent on the reduced test image.
OH_NetConn_
# Self permission check (accesstoken/ability_access_control.h): libability_access_control.so
# absent on the reduced test image.
OH_AT_
# ImageSource/Pixelmap (multimedia/image_framework): libimage_source.so and libpixelmap.so
# absent on the reduced test image. The downsample-decode options (OH_DecodingOptions_*) are
# API 12+ entry points resolved softly: without them the host decodes at full resolution.
OH_ImageSource
OH_Pixelmap
OH_DecodingOptions_
# HUKS (huks/native_huks_api.h, host_keystore.c): libhuks_ndk.z.so is resolved on demand,
# and the SecureStorage bridge falls back to the shell sink / file key when it is absent.
OH_Huks_
# hilog (hilog/log.h): libhilog_ndk.z.so absent on the reduced test image; OH_LOG_* falls
# back to stderr via host_optional_log.h.
OH_LOG_
HOST_DEPS_EOF
)"

# Current abc size expectations: the ui/shell ArkTS shell (476516 B) and the headless shell
# (24324 B). --expected-abc <bytes[,bytes]> / KIT_EXPECTED_ABC replaces the set and turns a
# mismatch from a historical-kit WARN into a FAIL (the kit builder uses that strict form).
EXPECT_ABC="${KIT_EXPECTED_ABC:-476516,24324}"
EXPECT_ABC_PINNED="${KIT_EXPECTED_ABC:+1}"
HOST_DEPS_FILE="${KIT_HOST_DEPS:-}"

# Deterministic digest of the extracted kit contents: every regular file under the kit root
# (SHA256SUMS and this script included) contributes one "<file sha256>  <relative path>"
# line; only the relative path bytes and the file contents are inputs (LC_ALL=C byte sort,
# no modes/mtimes/owners/directory entries). Root-level transport leftovers of this kit
# (the outer .tar.gz/.tgz/.tar/.zip archive and its checksum sidecar) are skipped and named
# on stderr, so extracting the tarball in place still matches a clean extraction. Any other
# added file (.DS_Store/Thumbs.db/...) changes the digest. Publisher and tester run this
# same code, so identical path+content bytes produce the identical value anywhere.
# Tree digest lines: reuse the hashes step 1 verified for these exact bytes (the map holds
# the entries of a successful, snapshot-stable SHA256SUMS check) and hash only what the map
# does not cover (SHA256SUMS itself, docs outside the list, files that moved). One awk holds
# the map and the file list; sha256sum is spawned only for the leftovers, because process
# spawns are the expensive part on a device (~40 ms each).
tree_digest() {
    (
        cd "$KIT" || exit 1
        LC_ALL=C
        export LC_ALL
        find . -type f -print | sed 's|^\./||' | LC_ALL=C sort | awk -v map="$TMP/verified.map" '
            BEGIN {
                while ((getline line < map) > 0) {
                    split(line, kv, " ")
                    if (kv[1] != "") verified[kv[1]] = kv[2]
                }
                close(map)
            }
            {
                rel = $0
                if (rel !~ /\// && rel ~ /\.(tar\.gz|tgz|tar|tar\.bz2|tar\.xz|zip|7z|sha256|sha1|md5|sha512)$/) {
                    printf "[tree-digest] 忽略包外传输文件（不计入 tree digest）: %s\n", rel > "/dev/stderr"
                    next
                }
                if (rel in verified) {
                    printf "%s  %s\n", verified[rel], rel
                    next
                }
                safe = rel
                gsub(/\\/, "\\\\", safe)
                gsub(/"/, "\\\"", safe)
                gsub(/\$/, "\\$", safe)
                gsub(/`/, "\\`", safe)
                cmd = "sha256sum -- \"" safe "\""
                if ((cmd | getline out) > 0) {
                    split(out, parts, " ")
                    printf "%s  %s\n", parts[1], rel
                }
                close(cmd)
            }'
    ) | sha256sum | cut -d' ' -f1
}

# One "<name> <inode> <size> <mtime>" line per SHA256SUMS entry that exists, from a single
# awk + single stat pass (a per-file loop would spawn hundreds of processes on a device).
# The caller runs it from inside the kit directory.
sums_stat_snapshot() {
    [ -f SHA256SUMS ] || return 0
    _names="$(awk '{ n=substr($0,67); sub(/^\*/, "", n); sub(/^\.\//, "", n); if (n!="") print n }' SHA256SUMS)"
    [ -n "$_names" ] || return 0
    if command -v xargs >/dev/null 2>&1; then
        printf '%s\n' "$_names" | xargs -r stat -c '%n %i %s %Y' 2>/dev/null || true
    else
        printf '%s\n' "$_names" | while IFS= read -r _name; do
            [ -f "$_name" ] || continue
            printf '%s %s\n' "$_name" "$(stat -c '%i %s %Y' -- "$_name" 2>/dev/null)"
        done
    fi
}

usage() {
    cat <<EOF
usage: $0 [--anchor <sha256-of-tar.gz>] [--anchor-file <path-to.tar.gz>]
          [--tree-digest] [--expect-tree-digest <sha256>]
          [--expected-abc <bytes[,bytes]>] [--host-deps <host-deps.conf>] [kit-dir]

Verifies SHA256SUMS, summarizes the five haps of an extracted device-test kit, and
asserts the payload facts that failed on a real device before: resources.index present
and non-empty, abc PANDA header version 13.0.1.0 + current size, the per-mode libs contract
(jit: 15 .so; aot: the NativeAOT lib<stem>.so + host + libc++_shared.so, no libcoreclr.so),
the payload-in-libs marker (entry assembly + staged file count + zip fallback identity),
dotnet.zip composition, and the host ELF dependency discipline (DT_NEEDED subset of the
embedded host-deps.conf, no nm -D -u denylist hit).
Without an argument the current directory is used (it must contain SHA256SUMS).

  --anchor <hex>        also check the .tar.gz on disk against this sha256 (fail closed when
                        it cannot be checked); it does NOT bind the extracted tree
  --anchor-file <path>  the outer tarball used by --anchor (default: <kit-dir>.tar.gz);
                        without --anchor, the adjacent <path>.sha256 is read
  --tree-digest         print the sha256 of the extracted kit contents (sorted relative
                        paths + per-file sha256) to compare with the published value; a
                        root-level transport archive/sidecar (.tar.gz/.tgz/.tar/.zip/
                        .sha256/...) is ignored, other added files are not
  --expect-tree-digest <hex>
                        fail unless the extracted tree matches this digest (the value comes
                        with the delivery, e.g. the release notes)
  --expected-abc <bytes[,bytes]>
                        abc size expectation (default: 476516,24324 = the ui/shell and the
                        headless ArkTS shell); a size outside the set warns by default and
                        fails when this option pins the set
  --host-deps <path>    read the host dependency policy from this file instead of the
                        embedded copy (use the repository's
                        src/OpenHarmonyHost/host-deps.conf); fail closed when it cannot be
                        read or has no [needed]/[undefined] entries
  --blazor-perms <name[,name]>
                        expected requestPermissions of the Blazor component hap (default:
                        empty = the source module.json5 declares none after ohos-workload
                        2dcd846). The packed set is recorded and a disagreement is a WARN,
                        never a FAIL, so a pre-removal kit (#31) stays verifiable
  env: KIT_ANCHOR, KIT_ANCHOR_FILE, KIT_TREE_DIGEST, KIT_BUNDLE_NAME,
       KIT_EXPECTED_ABC, KIT_HOST_DEPS, KIT_BLAZOR_HAP, KIT_BLAZOR_BUNDLE,
       KIT_BLAZOR_PERMS

The optional Blazor WASM component hap (hello-blazorwasm-host-unsigned.hap, built with
make-device-test-kit.sh --with-blazor) is asserted when present: embedded site index.html,
_framework *.wasm + blazor.webassembly*.js, the stable _framework/dotnet.js (byte-equal to its
dotnet.<hash>.js fingerprint source; kit #31/#32 shipped without it), PANDA 13.0.1.0 abc,
bundle com.example.opendotnet, no .br/.gz/.map or icudt*.dat leftovers, and a recorded
requestPermissions set (mismatch vs the source-side expectation = WARN); a kit without the hap
only logs that fact.
EOF
}

KIT=""
ANCHOR="${KIT_ANCHOR:-}"
ANCHOR_FILE="${KIT_ANCHOR_FILE:-}"
TREE_MODE=0
TREE_EXPECT="${KIT_TREE_DIGEST:-}"
# Expected bundle name of the five haps. Pinned to the demo default (ohos-workload bbfa03c:
# hyphens are illegal in app.bundleName; kits built before it carry the hyphenated demo name
# and must be repacked). Override for a kit built with -p:OpenHarmonyBundleName=<other>.
BUNDLE_EXPECT="${KIT_BUNDLE_NAME:-com.example.hellomauiapp}"
# Optional Blazor WASM component hap (make-device-test-kit.sh --with-blazor). Asserted only
# when the hap is present in the kit root; KIT_BLAZOR_HAP / KIT_BLAZOR_BUNDLE override the
# packed name/bundle. Its abc version expectation mirrors the 2b ABC_VERSION below.
BLAZOR_HAP_NAME="${KIT_BLAZOR_HAP:-hello-blazorwasm-host-unsigned.hap}"
BLAZOR_BUNDLE_EXPECT="${KIT_BLAZOR_BUNDLE:-com.example.opendotnet}"
BLAZOR_ABC_VERSION="13.0.1.0"
# Source-side requestPermissions expectation of the Blazor component: the host module.json5 in
# test/hello-blazorwasm/arkts-host/project/entry declares none after ohos-workload 2dcd846, so
# the default is empty. A kit packed before that commit (e.g. #31) still carries
# ohos.permission.INTERNET; the 2c comparison records the packed set and WARNs on a
# disagreement instead of failing, so a historical kit stays verifiable. The selftest pins this
# embedded value against the source module.json5 (S0b).
BLAZOR_SOURCE_PERMS="${KIT_BLAZOR_PERMS:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --anchor)
            shift
            [ $# -gt 0 ] || { warn "--anchor 需要一个 sha256"; usage >&2; exit 2; }
            ANCHOR="$1"
            ;;
        --anchor-file)
            shift
            [ $# -gt 0 ] || { warn "--anchor-file 需要一个 tar.gz 路径"; usage >&2; exit 2; }
            ANCHOR_FILE="$1"
            ;;
        --tree-digest) TREE_MODE=1 ;;
        --expect-tree-digest)
            shift
            [ $# -gt 0 ] || { warn "--expect-tree-digest 需要一个 sha256"; usage >&2; exit 2; }
            TREE_EXPECT="$1"
            ;;
        --expected-abc)
            shift
            [ $# -gt 0 ] || { warn "--expected-abc 需要逗号分隔的字节数（如 476516,24324）"; usage >&2; exit 2; }
            EXPECT_ABC="$1"
            EXPECT_ABC_PINNED=1
            ;;
        --host-deps)
            shift
            [ $# -gt 0 ] || { warn "--host-deps 需要一个策略文件路径"; usage >&2; exit 2; }
            HOST_DEPS_FILE="$1"
            ;;
        --blazor-perms)
            shift
            [ $# -gt 0 ] || { warn "--blazor-perms 需要逗号分隔的权限名（默认空 = 源侧未声明）"; usage >&2; exit 2; }
            BLAZOR_SOURCE_PERMS="$1"
            ;;
        -*) warn "unknown argument: $1"; usage >&2; exit 2 ;;
        *)
            [ -z "$KIT" ] || { warn "unexpected extra argument: $1"; usage >&2; exit 2; }
            KIT="$1"
            ;;
    esac
    shift
done

if [ -z "$KIT" ]; then
    if [ -f SHA256SUMS ]; then
        KIT=.
    elif [ -f "$(dirname "$0")/SHA256SUMS" ]; then
        KIT="$(dirname "$0")"
    else
        warn "当前目录没有 SHA256SUMS；请在解压后的交付包内运行，或把包目录作为参数传入"
        usage >&2
        exit 2
    fi
fi
[ -d "$KIT" ] || { warn "kit dir not found: $KIT"; exit 2; }
KIT="$(cd "$KIT" && pwd)"
[ -f "$KIT/SHA256SUMS" ] || { warn "SHA256SUMS not found in: $KIT"; exit 2; }

# Normalize the abc size expectation to a space-separated list (commas allowed on the CLI);
# a non-numeric token is bad usage, not a kit failure.
EXPECT_ABC="$(printf '%s' "$EXPECT_ABC" | tr ',' ' ')"
for _abc in $EXPECT_ABC; do
    case "$_abc" in
        ''|*[!0-9]*) warn "--expected-abc 需要逗号/空格分隔的字节数（如 476516,24324），得到: $EXPECT_ABC"; usage >&2; exit 2 ;;
    esac
done
[ -n "$EXPECT_ABC" ] || { warn "--expected-abc 不能为空"; usage >&2; exit 2; }

FAIL=0

# Optional outer anchor: KIT_ANCHOR/--anchor is the sha256 of the .tar.gz the kit was
# extracted from. It binds the extracted tree to that archive; without it, SHA256SUMS only
# proves internal consistency. Requested-but-uncheckable always fails.
if [ -n "$ANCHOR" ] || [ -n "$ANCHOR_FILE" ]; then
    log "== 0/4 外层锚点校验（tar.gz sha256）"
    if [ -z "$ANCHOR_FILE" ]; then
        for _cand in "$KIT.tar.gz" "$(dirname "$KIT")/$(basename "$KIT").tar.gz"; do
            if [ -f "$_cand" ]; then ANCHOR_FILE="$_cand"; break; fi
        done
    fi
    if [ -z "$ANCHOR_FILE" ] || [ ! -f "$ANCHOR_FILE" ]; then
        warn "找不到外层 tar.gz（候选: $KIT.tar.gz）；用 --anchor-file <path> 指定，或先校验外层再运行"
        FAIL=1
    else
        if [ -z "$ANCHOR" ]; then
            # no digest given: read the published <tarball>.sha256 sidecar
            if [ -f "$ANCHOR_FILE.sha256" ]; then
                ANCHOR="$(cut -d' ' -f1 < "$ANCHOR_FILE.sha256")"
                [ -n "$ANCHOR" ] || { warn "$ANCHOR_FILE.sha256 里没有可用的 sha256"; FAIL=1; }
            else
                warn "未给出 --anchor <sha256>，且 $ANCHOR_FILE.sha256 不存在"
                FAIL=1
            fi
        fi
        case "$ANCHOR" in
            *[!0-9a-fA-F]*) warn "anchor 不是十六进制 sha256: $ANCHOR"; FAIL=1 ;;
            "")             warn "anchor 为空"; FAIL=1 ;;
            *) [ "${#ANCHOR}" -eq 64 ] || { warn "anchor 长度不是 64 个字符: $ANCHOR"; FAIL=1; } ;;
        esac
        if [ -n "$ANCHOR" ] && [ "${#ANCHOR}" -eq 64 ]; then
            case "$ANCHOR" in *[!0-9a-fA-F]*) ;; *)
                _got="$(sha256sum "$ANCHOR_FILE" | cut -d' ' -f1)"
                if [ "$_got" = "$ANCHOR" ]; then
                    log "   anchor OK $ANCHOR_FILE sha256=$_got"
                else
                    warn "anchor 不匹配 — 磁盘上的 .tar.gz 与发布锚点不一致（下载/传输被篡改）"
                    warn "  本项只校验 tar.gz 文件本身，不校验解压后的目录"
                    warn "  expected $ANCHOR"
                    warn "  actual   $_got"
                    FAIL=1
                fi
            ;; esac
        fi
    fi
else
    log "== 0/4 外层锚点：未请求（建议先 sha256sum -c <kit>.tar.gz.sha256 或 --anchor <sha256>）"
fi

# The tree digest is computed after step 1 so it can reuse the hashes that check just
# verified for these exact bytes (see the note at the top); both checks still run, and a
# requested --expect-tree-digest still fails closed.

TMP="$(mktemp -d 2>/dev/null || true)"
if [ -z "$TMP" ]; then
    TMP="${TMPDIR:-/tmp}/verify-kit.$$"
    mkdir -p "$TMP"
fi
trap 'rm -rf "$TMP"' 0 1 2 15

# Host dependency policy (step 2b): the embedded copy is the default; --host-deps/KIT_HOST_DEPS
# replaces it with the canonical src/OpenHarmonyHost/host-deps.conf. Copy it into $TMP before
# cd "$KIT" so a relative path keeps working. Both sections must be non-empty (fail closed:
# an empty whitelist would pass every NEEDED and an empty denylist every symbol).
POLICY="$TMP/host-deps.conf"
if [ -n "$HOST_DEPS_FILE" ]; then
    if [ ! -f "$HOST_DEPS_FILE" ]; then
        warn "host-deps 策略文件不存在: $HOST_DEPS_FILE"
        usage >&2
        exit 2
    fi
    cp "$HOST_DEPS_FILE" "$POLICY" || { warn "无法读取 host-deps 策略文件: $HOST_DEPS_FILE"; exit 2; }
    log "   宿主依赖策略：--host-deps $HOST_DEPS_FILE"
else
    printf '%s\n' "$HOST_DEPS_DEFAULT" > "$POLICY"
    log "   宿主依赖策略：内嵌副本（src/OpenHarmonyHost/host-deps.conf）"
fi
HOST_NEEDED="$(awk '/^\[needed\]/{in_section=1; next} /^\[/{in_section=0} in_section && $0 !~ /^[[:space:]]*#/ && NF {print $1}' "$POLICY")"
HOST_UNDEFINED="$(awk '/^\[undefined\]/{in_section=1; next} /^\[/{in_section=0} in_section && $0 !~ /^[[:space:]]*#/ && NF {print $1}' "$POLICY")"
if [ -z "$HOST_NEEDED" ]; then
    warn "$POLICY 没有 [needed] 条目；白名单为空会放行任何 DT_NEEDED，拒绝继续"
    FAIL=1
fi
if [ -z "$HOST_UNDEFINED" ]; then
    warn "$POLICY 没有 [undefined] 条目；denylist 为空会放行任何直接引用，拒绝继续"
    FAIL=1
fi

cd "$KIT"

# Kit-root runtime-mode annotation (AOT-DEFAULT): when present it must name a known mode, and
# every MAUI hap marker must match it (the python block cross-checks). Absent on kits built
# before the switch: no cross-check then, and each hap falls back to its own marker.
KIT_MODE_EXPECT=""
if [ -f runtime-mode.txt ]; then
    KIT_MODE_EXPECT="$(head -n1 runtime-mode.txt 2>/dev/null | tr -d ' \r\n')"
    case "$KIT_MODE_EXPECT" in
        aot|jit|interp) log "   kit 运行时形态：runtime-mode.txt=$KIT_MODE_EXPECT" ;;
        *) warn "kit 根 runtime-mode.txt 值无法识别: '$KIT_MODE_EXPECT'（期望 aot|jit|interp）"; FAIL=1; KIT_MODE_EXPECT="" ;;
    esac
fi

log "== 1/4 SHA256SUMS 校验（sha256sum -c）"
ENTRIES="$(wc -l < SHA256SUMS | tr -d ' ')"
: > "$TMP/verified.map"
if [ "$ENTRIES" -eq 0 ]; then
    warn "SHA256SUMS 是空文件，无法校验"
    FAIL=1
else
    # First verification is always a real read of every covered file. The inode/size/mtime
    # snapshot around it proves the bytes did not move while being checked, which is what
    # makes the tree digest's reuse of these hashes sound; a moved file drops out of the map
    # and is hashed from disk below.
    SUMS_SNAP_BEFORE="$(sums_stat_snapshot)"
    sha256sum -c SHA256SUMS > "$TMP/sums.out" 2> "$TMP/sums.err" && SUMS_RC=0 || SUMS_RC=$?
    SUMS_SNAP_AFTER="$(sums_stat_snapshot)"
    while IFS= read -r line; do
        case "$line" in
            *": OK") printf '   ok   %s\n' "${line%": OK"}" ;;
            *)       printf '   FAIL %s\n' "$line" >&2 ;;
        esac
    done < "$TMP/sums.out"
    if [ "$SUMS_RC" -eq 0 ]; then
        log "   $ENTRIES 项全部通过（sha256sum -c OK）"
    else
        FAIL=1
        if [ -s "$TMP/sums.err" ]; then
            sed 's/^/   /' "$TMP/sums.err" >&2
        fi
        warn "SHA256SUMS 校验失败：以上 FAIL 项说明文件被改动或传输损坏，请重新下载并解压交付包"
    fi
    # Fail closed: an empty snapshot (stat/xargs unavailable) never arms the reuse.
    if [ "$SUMS_RC" -eq 0 ] && [ -n "$SUMS_SNAP_BEFORE" ] && [ "$SUMS_SNAP_BEFORE" = "$SUMS_SNAP_AFTER" ]; then
        # A zero exit from sha256sum -c means every entry matched, and the snapshot proves the
        # files did not move across the check, so the recorded hashes describe these bytes.
        awk '{ n=substr($0,67); sub(/^\*/, "", n); sub(/^\.\//, "", n); if (n=="") next; printf "%s %s\n", n, substr($0,1,64) }' \
            SHA256SUMS > "$TMP/verified.map"
    fi
fi

# Optional tree digest: unlike --anchor (which checks the .tar.gz file), this binds the
# extracted kit directory itself. --tree-digest prints it; --expect-tree-digest (or
# KIT_TREE_DIGEST) compares and fails closed. The hashes verified by step 1 for these exact
# bytes are reused instead of being read again (see the header note); SHA256SUMS itself,
# files outside the list and any file whose metadata moved are hashed from disk here.
TREE_DIGEST=""
if [ "$TREE_MODE" = 1 ] || [ -n "$TREE_EXPECT" ]; then
    log "== 1b/4 内容树摘要（tree digest：排序相对路径 + 每文件 sha256）"
    if [ -s "$TMP/verified.map" ]; then
        log "   复用本次已校验的 SHA256SUMS 哈希（同一次运行、失效校验通过，未逐文件重读）"
    else
        warn "   无可复用的本次校验结果，tree digest 逐文件重算（不降低校验强度）"
    fi
    TREE_DIGEST="$(tree_digest)"
    log "   tree sha256=$TREE_DIGEST"
    if [ -n "$TREE_EXPECT" ]; then
        case "$TREE_EXPECT" in
            *[!0-9a-fA-F]*) warn "tree digest 不是十六进制 sha256: $TREE_EXPECT"; FAIL=1 ;;
            "")             warn "tree digest 为空"; FAIL=1 ;;
            *) [ "${#TREE_EXPECT}" -eq 64 ] || { warn "tree digest 长度不是 64 个字符: $TREE_EXPECT"; FAIL=1; } ;;
        esac
        if [ "${#TREE_EXPECT}" -eq 64 ]; then
            case "$TREE_EXPECT" in *[!0-9a-fA-F]*) ;; *)
                if [ "$TREE_DIGEST" = "$TREE_EXPECT" ]; then
                    log "   tree digest OK（解压内容与发布方绑定一致）"
                else
                    warn "tree digest 不匹配 — 解压目录被增删改（或不是发布方绑定的那份 kit）"
                    warn "  expected $TREE_EXPECT"
                    warn "  actual   $TREE_DIGEST"
                    FAIL=1
                fi
            ;; esac
        fi
    fi
fi

# The five haps must be present and covered by SHA256SUMS (a truncated sums file would
# otherwise still pass for whatever entries remain).
for h in \
    hello-maui-app.hap \
    hello-maui-app-permissions.hap \
    hello-maui-app-api20.hap \
    hello-maui-app-api20-permissions.hap \
    hello-maui-app-unsigned.hap
do
    grep -Fq "  $h" SHA256SUMS || { warn "SHA256SUMS 未收录 $h"; FAIL=1; }
done
[ -f "自签说明.md" ] || { warn "缺少 自签说明.md（9568344 自签流程指向它）"; FAIL=1; }
[ -f "签名说明.txt" ] || { warn "缺少 签名说明.txt（自签名 hap 的预期拒绝与重签路径说明）"; FAIL=1; }

log "== 2/4 五个 hap 一览与深度断言（module.json / resources.index / abc / libs / 宿主依赖）"
DEEP_FAILS=0
DEEP_WARNS=0
if command -v python3 >/dev/null 2>&1; then
    python3 - "$KIT" "$BUNDLE_EXPECT" "$TMP/kit-bundle" "$POLICY" "$TMP/deep-status" \
        "$EXPECT_ABC" "$EXPECT_ABC_PINNED" "$KIT_MODE_EXPECT" <<'PY' || FAIL=1
import hashlib, io, json, os, struct, sys, zipfile

kit = sys.argv[1]
expected = sys.argv[2]
bundle_file = sys.argv[3]
policy_file = sys.argv[4]
status_file = sys.argv[5]
expected_abc = [int(v) for v in sys.argv[6].split()]
abc_pinned = sys.argv[7] == "1"
kit_mode_expect = sys.argv[8] if len(sys.argv) > 8 else ""

# Current-generation expectations; the abc sizes come from the shell (--expected-abc). The
# libs/zip numbers are per runtime mode (AOT-DEFAULT): jit = the JIT payload contract, aot =
# the NativeAOT shape, interp = jit + the interpreter library.
JIT_LIBS = 15               # host + libc++ + 12 runtime ELF + createdump.so under libs/arm64-v8a/
AOT_LIBS_MIN = 3            # host + libc++_shared.so + the NativeAOT app library lib<stem>.so
JIT_ZIP_ENTRIES = 258       # dotnet.zip entries (deterministic writer with the ELF names excluded)
AOT_ZIP_ENTRIES = 9         # AOT dotnet.zip: the static-web-asset/hybrid payload only
INDEX_SANE_MAX = 2560       # resources.index measured 1894 B (API 26) / 2102 B (API 20) on the rc.2 line
                            # (the WebView media-permission reason strings add ~320 B)
ABC_VERSION = "13.0.1.0"    # 4-byte PANDA version field at offset 0x0c
LIBS_DIR = "libs/arm64-v8a/"
RUNTIME_MARKER = LIBS_DIR + "runtime-mode.txt"
HOST_SO = LIBS_DIR + "libopenharmonyhost.so"
DOTNET_ZIP = "resources/rawfile/dotnet.zip"
PAYLOAD_MARKER = LIBS_DIR + ".dotnet-payload.json"
APP_JSON = "resources/rawfile/app.json"

haps = [
    ("hello-maui-app.hap",
     "默认包：API 26 波段，无额外权限（UI/交互/手势/IME/通知/安全区/WebView/无障碍/Hybrid）；"
     "自签名，设备会拒绝，需要重签"),
    ("hello-maui-app-permissions.hap",
     "带权限变体：蓝牙/打印/联系人/日历（验收说明 §4b 的 N1-N4）；自签名，设备会拒绝，需要重签"),
    ("hello-maui-app-api20.hap",
     "API 20 波段（min=target=60000020，Release）：给 API 20 设备；自签名，设备会拒绝，需要重签"),
    ("hello-maui-app-api20-permissions.hap",
     "API 20 波段 + 蓝牙/打印/联系人/日历权限；自签名，设备会拒绝，需要重签"),
    ("hello-maui-app-unsigned.hap",
     "未签名（与默认包同一负载）：本包唯一可重签安装的变体，按 自签说明.md 用你自己的自动签名安装"),
]

graded = []


def grade(level, msg):
    # FAIL -> the shell prints it and exits 1; WARN -> printed, run stays KIT OK.
    graded.append((level, msg))


def policy_entries(path):
    """host-deps.conf parser mirroring scripts/build-host.sh: [needed] / [undefined] sections,
    '#' comments and blank lines ignored, the first whitespace token is the entry."""
    needed, undefined, section = [], [], ""
    with open(path, "r", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if line == "[needed]":
                section = "needed"
                continue
            if line == "[undefined]":
                section = "undefined"
                continue
            if line.startswith("["):
                section = ""
                continue
            if not line or line.startswith("#"):
                continue
            if section == "needed":
                needed.append(line.split()[0])
            elif section == "undefined":
                undefined.append(line.split()[0])
    return needed, undefined


def vaddr_to_off(loads, vaddr):
    for p_off, p_vaddr, p_filesz in loads:
        if p_vaddr <= vaddr < p_vaddr + p_filesz:
            return p_off + (vaddr - p_vaddr)
    return None


def elf_dyn(data):
    """DT_NEEDED + undefined dynamic symbol names of an ELF64 little-endian shared object: the
    readelf -d / nm -D -u equivalent, parsed here so testers need no binutils."""
    if len(data) < 64 or data[:4] != b"\x7fELF":
        return None, None, "不是 ELF 文件"
    if data[4] != 2 or data[5] != 1:
        return None, None, "只解析 ELF64 小端"
    (e_type, _machine, _version, _entry, e_phoff, _shoff, _flags,
     _ehsize, e_phentsize, e_phnum, _shentsize, _shnum, _shstrndx) = \
        struct.unpack_from("<HHIQQQIHHHHHH", data, 16)
    if e_phentsize < 56 or e_phnum == 0:
        return None, None, "没有程序头（静态 ELF？）"
    loads, dyn_off = [], None
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if off + 56 > len(data):
            break
        p_type, _flags, p_offset, p_vaddr, _paddr, p_filesz, _p_memsz, _align = \
            struct.unpack_from("<IIQQQQQQ", data, off)
        if p_type == 1:    # PT_LOAD
            loads.append((p_offset, p_vaddr, p_filesz))
        elif p_type == 2:  # PT_DYNAMIC
            dyn_off = p_offset
    if dyn_off is None:
        return None, None, "没有 PT_DYNAMIC"
    needed_offsets, strtab_vaddr, strtab_sz, symtab_vaddr, hash_vaddr = [], None, 0, None, None
    i = 0
    while True:
        off = dyn_off + i * 16
        if off + 16 > len(data):
            return None, None, "dynamic 数组被截断"
        d_tag, d_val = struct.unpack_from("<qQ", data, off)
        i += 1
        if d_tag == 0:      # DT_NULL
            break
        if d_tag == 1:      # DT_NEEDED
            needed_offsets.append(d_val)
        elif d_tag == 5:    # DT_STRTAB
            strtab_vaddr = d_val
        elif d_tag == 10:   # DT_STRSZ
            strtab_sz = d_val
        elif d_tag == 6:    # DT_SYMTAB
            symtab_vaddr = d_val
        elif d_tag == 4:    # DT_HASH
            hash_vaddr = d_val
    if strtab_vaddr is None:
        return None, None, "没有 DT_STRTAB"
    str_off = vaddr_to_off(loads, strtab_vaddr)
    if str_off is None:
        return None, None, "DT_STRTAB 不在 PT_LOAD 内"

    def string_at(idx):
        if idx >= strtab_sz:
            return None
        end = data.find(b"\0", str_off + idx)
        if end < 0:
            return None
        return data[str_off + idx:end].decode("utf-8", "replace")

    needed = [n for n in (string_at(v) for v in needed_offsets) if n]

    # Symbol count: DT_HASH.nchain is exact; otherwise the gap to .dynstr is safe when it is
    # 24-byte aligned (lld lays .dynstr immediately after .dynsym).
    sym_off = vaddr_to_off(loads, symtab_vaddr) if symtab_vaddr is not None else None
    nsym = None
    if sym_off is not None:
        if hash_vaddr is not None:
            h = vaddr_to_off(loads, hash_vaddr)
            if h is not None and h + 8 <= len(data):
                _nbucket, nchain = struct.unpack_from("<II", data, h)
                if 0 < nchain <= (len(data) - sym_off) // 24:
                    nsym = nchain
        if nsym is None and sym_off < str_off and (str_off - sym_off) % 24 == 0:
            nsym = (str_off - sym_off) // 24
    undefined = []
    if nsym and sym_off is not None:
        for k in range(nsym):
            if sym_off + k * 24 + 24 > len(data):
                break
            st_name, _info, _other, st_shndx = struct.unpack_from("<IBBH", data, sym_off + k * 24)
            if st_shndx == 0 and st_name:  # SHN_UNDEF
                name = string_at(st_name)
                if name:
                    undefined.append(name)
        undefined = sorted(set(undefined))
    return needed, undefined, "%d 个 UND 符号" % len(undefined)


try:
    needed_allow, undefined_deny = policy_entries(policy_file)
    policy_ok = True
except Exception as exc:
    needed_allow, undefined_deny, policy_ok = [], [], False
    grade("FAIL", "无法读取宿主依赖策略 %s (%s) — 宿主依赖纪律无法校验，拒绝放行" % (policy_file, exc))


def aot_stem(names, z):
    """The AOT application-library stem: resources/rawfile/app.json names the entry assembly
    (hello-maui-app.dll) and the packaging stages lib<stem>.so, the host's probe target."""
    if APP_JSON not in names:
        return None
    try:
        asm = str(json.loads(z.read(APP_JSON)).get("assembly", ""))
    except Exception:
        return None
    if asm.endswith(".dll"):
        asm = asm[:-4]
    return asm or None


fail = 0
bundles = []
for name, purpose in haps:
    print("  %s  %s" % (name, purpose))
    path = os.path.join(kit, name)
    if not os.path.isfile(path):
        print("      MISS  文件不在交付包内")
        grade("FAIL", "%s: 文件不在交付包内" % name)
        fail = 1
        continue
    try:
        z = zipfile.ZipFile(path)
    except Exception as exc:
        print("      BAD   无法读取 hap (%s)" % exc)
        grade("FAIL", "%s: 无法读取 hap (%s)" % (name, exc))
        fail = 1
        continue
    with z:
        names = z.namelist()
        try:
            data = json.loads(z.read("module.json"))
        except Exception as exc:
            print("      BAD   无法读取 module.json (%s)" % exc)
            grade("FAIL", "%s: 无法读取 module.json (%s)" % (name, exc))
            fail = 1
            continue
        app = data.get("app") or {}
        mod = data.get("module") or {}
        bundle = app.get("bundleName", "?")
        if bundle != "?":
            bundles.append(bundle)
        perms = [p.get("name", "?") for p in (mod.get("requestPermissions") or [])]
        print("      bundle=%s  versionName=%s" % (bundle, app.get("versionName", "?")))
        print("      API    min=%s target=%s (%s)" % (app.get("minAPIVersion", "?"),
                                                      app.get("targetAPIVersion", "?"),
                                                      app.get("apiReleaseType", "?")))
        if perms:
            short = ", ".join(p.rsplit(".", 1)[-1] for p in perms)
            print("      权限   requestPermissions=%d [%s]" % (len(perms), short))
        else:
            print("      权限   requestPermissions=0")

        # --- runtime mode: the MS-MODE marker decides the libs/zip expectations ---------------
        mode = "jit"
        has_marker = RUNTIME_MARKER in names
        if has_marker:
            mode = z.read(RUNTIME_MARKER).decode("utf-8", "replace").strip()
        if mode not in ("jit", "aot", "interp"):
            grade("FAIL", "%s: %s 值 %r 非法（jit|aot|interp）— 打包期即拒绝该值，出现即漂移/手工编辑"
                          % (name, RUNTIME_MARKER, mode))
            mode = "jit"
        print("      mode   runtime-mode=%s%s" % (mode, "" if has_marker else "（无 marker：按历史 JIT 包判读）"))
        if kit_mode_expect and mode != kit_mode_expect:
            grade("FAIL", "%s: hap runtime-mode=%s 与 kit 根 runtime-mode.txt=%s 不一致（包内形态混杂/标注失真）"
                          % (name, mode, kit_mode_expect))

        # --- resources.index: the device ResourceManager needs it for the rawfile payload -----
        if "resources.index" not in names:
            print("      index  <缺 resources.index>")
            grade("FAIL", "%s: 缺 resources.index — 设备 ResourceManager 解析不了 hap 资源，ArkTS 壳读 rawfile 会报"
                         " \"GetRawFileContent failed, name is empty\"，托管引导起不来（FIX-DEV3 0f26b74：dotnet publish"
                         " 必须把 restool 编出的 index 用 --index-path 打包；该 kit 需重打包）" % name)
        else:
            try:
                idx = z.read("resources.index")
            except Exception as exc:
                idx = None
                print("      index  resources.index 读取失败 (%s)" % exc)
                grade("FAIL", "%s: resources.index 读取失败 (%s)" % (name, exc))
            if idx is not None:
                if len(idx) == 0:
                    print("      index  resources.index 0 B（空文件）")
                    grade("FAIL", "%s: resources.index 是 0 B 空文件（FIX-DEV3 0f26b74 之后不应出现；需重打包）" % name)
                else:
                    print("      index  resources.index %d B%s"
                          % (len(idx), "（≤%d B 合理范围）" % INDEX_SANE_MAX if len(idx) <= INDEX_SANE_MAX else "（> %d B）" % INDEX_SANE_MAX))
                    if len(idx) > INDEX_SANE_MAX:
                        grade("WARN", "%s: resources.index %d B 超出预期 ≤%d B — 资源/权限增加时正常，确认后更新本检查"
                                      % (name, len(idx), INDEX_SANE_MAX))

        # --- abc: PANDA format version + current shell size -----------------------------------
        if "ets/modules.abc" not in names:
            print("      abc    <缺 ets/modules.abc>")
            grade("FAIL", "%s: 缺 ets/modules.abc — ArkTS 壳没有可加载的入口" % name)
        else:
            abc = z.read("ets/modules.abc")
            ver = ".".join(str(b) for b in abc[0x0C:0x10]) if len(abc) >= 0x10 and abc[:5] == b"PANDA" else None
            print("      abc    ets/modules.abc %d B，PANDA 头版本 %s" % (len(abc), ver or "?"))
            if ver is None:
                grade("FAIL", "%s: ets/modules.abc 不是 PANDA abc（前 4 字节 %r）" % (name, abc[:4]))
            elif ver != ABC_VERSION:
                grade("FAIL", "%s: abc PANDA 头版本 %s != %s（0x0c 处的 4 字节版本；壳/格式漂移）"
                              % (name, ver, ABC_VERSION))
            if len(abc) not in expected_abc:
                sizes = "/".join(str(v) for v in expected_abc)
                if abc_pinned:
                    grade("FAIL", "%s: abc 大小 %d 不在 --expected-abc %s 内（已显式固定期望，按漂移处理）"
                                  % (name, len(abc), sizes))
                else:
                    grade("WARN", "%s: abc 大小 %d 不是当前期望（%s）— 历史 kit 的旧壳属正常；确认不是意外漂移，"
                                  "或用 --expected-abc %d 固定" % (name, len(abc), sizes, len(abc)))

        # --- libs/arm64-v8a: every runtime ELF must ship in the signed libs dir ----------------
        # The mode decides the contract: jit/interp carry the CoreCLR natives, aot carries the
        # NativeAOT application library instead (lib<stem>.so, named by app.json).
        libs = [n for n in names if n.startswith(LIBS_DIR) and n.endswith(".so")]
        if not libs:
            print("      libs   <缺 %s>" % LIBS_DIR)
            grade("FAIL", "%s: 缺 %s — 宿主 DT_NEEDED 的 libc++_shared.so 与运行时 ELF 必须随 hap 的 libs 目录签名，"
                          "否则设备加载器拒绝" % (name, LIBS_DIR))
        else:
            print("      libs   %s: %d 个 .so" % (LIBS_DIR, len(libs)))
            if mode == "aot":
                if len(libs) < AOT_LIBS_MIN:
                    grade("FAIL", "%s: AOT hap 的 %s 只有 %d 个 .so（期望 ≥%d：宿主 + libc++_shared.so + "
                                  "NativeAOT 应用库）；用 -p:PublishAot=true -p:PublishAotUsingRuntimePack=true "
                                  "-p:NativeLib=Shared 重新发布" % (name, LIBS_DIR, len(libs), AOT_LIBS_MIN))
                elif len(libs) > AOT_LIBS_MIN:
                    grade("WARN", "%s: AOT hap 的 %s 有 %d 个 .so（期望 %d）— 运行时文件集变化时正常，确认后更新期望"
                                  % (name, LIBS_DIR, len(libs), AOT_LIBS_MIN))
            else:
                want = JIT_LIBS + 1 if mode == "interp" else JIT_LIBS
                if len(libs) < want:
                    grade("FAIL", "%s: %s 只有 %d 个 .so（期望 %d）— 少了运行时 ELF，设备上会缺依赖"
                                  % (name, LIBS_DIR, len(libs), want))
                elif len(libs) > want:
                    grade("WARN", "%s: %s 有 %d 个 .so（期望 %d）— 运行时文件集变化时正常，确认后更新期望"
                                  % (name, LIBS_DIR, len(libs), want))
            if mode == "aot":
                stem = aot_stem(names, z)
                if stem is None:
                    grade("FAIL", "%s: AOT hap 缺 %s（宿主据此推导 lib<stem>.so；缺了无法路由到 AOT 入口）"
                                  % (name, APP_JSON))
                else:
                    entry = LIBS_DIR + "lib%s.so" % stem
                    if entry not in names:
                        grade("FAIL", "%s: AOT hap 缺 %s（NativeAOT 应用库；用 -p:PublishAot=true "
                                      "-p:PublishAotUsingRuntimePack=true -p:NativeLib=Shared 重新发布）" % (name, entry))
                    else:
                        esize = z.getinfo(entry).file_size
                        print("      aot    %s %d B" % (entry, esize))
                        if esize <= 0:
                            grade("FAIL", "%s: %s 是 0 B 空文件 — AOT 应用库不完整，宿主探测会失败" % (name, entry))
                if (LIBS_DIR + "libcoreclr.so") in names:
                    grade("FAIL", "%s: runtime-mode=aot 却带 libcoreclr.so — 包内形态混杂；AOT hap 不得携带 JIT "
                                  "运行时原生库（重新发布/打包，别把 AOT 标记打到 JIT payload 上）" % name)
            if mode == "interp" and (LIBS_DIR + "libclrinterpreter.so") not in names:
                grade("FAIL", "%s: runtime-mode=interp 但缺 %s — 解释器库没被换入（用 OpenHarmonyInterpreterPack 指向"
                              "解包目录）" % (name, LIBS_DIR + "libclrinterpreter.so"))

        # --- host ELF dependency discipline ---------------------------------------------------
        if HOST_SO not in names:
            print("      host   <缺 %s>" % HOST_SO)
            grade("FAIL", "%s: 缺 %s" % (name, HOST_SO))
        elif policy_ok:
            host = z.read(HOST_SO)
            needed, undef, note = elf_dyn(host)
            if needed is None:
                print("      host   %s %d B；ELF 解析失败（%s）" % (HOST_SO, len(host), note))
                grade("WARN", "%s: 宿主 ELF 解析失败（%s）— 跳过 DT_NEEDED/denylist 检查；确认不是 arm64 ELF64 之外的变体"
                              % (name, note))
            else:
                hits = sorted({u for p in undefined_deny for u in undef if p in u})
                shown_needed = needed if len(needed) <= 6 else needed[:6] + ["..."]
                print("      host   %s %d B；DT_NEEDED=%d [%s]；UND=%d，denylist 命中=%d"
                      % (HOST_SO, len(host), len(needed), "、".join(shown_needed), len(undef), len(hits)))
                extra = [n for n in needed if n not in needed_allow]
                if "libhostfxr.so" in extra:
                    grade("FAIL", "%s: 宿主 DT_NEEDED 含 libhostfxr.so — 它要在 dotnet.zip 解包后才经 dlopen 句柄解析，"
                                  "加载期 NEEDED 会让 ArkTS import 在解包前失败（见 scripts/build-host.sh 的同名门禁）" % name)
                    extra = [n for n in extra if n != "libhostfxr.so"]
                if extra:
                    grade("FAIL", "%s: 宿主 DT_NEEDED 超出 host-deps.conf 白名单: %s — 精简系统镜像没有这些库，"
                                  "需在 host_optional.c 里 dlopen/dlsym" % (name, ", ".join(extra)))
                if hits:
                    shown = ", ".join(hits[:8]) + (" ..." if len(hits) > 8 else "")
                    grade("FAIL", "%s: 宿主直接引用可选 API（nm -D -u denylist 命中 %d 个）: %s — dlopen/dlsym 降级被绕过"
                                  % (name, len(hits), shown))

        # --- dotnet.zip: no unsigned ELF duplicates, stable entry count ------------------------
        dotnet_entries = None
        dotnet_sha = None
        if DOTNET_ZIP not in names:
            print("      zip    <缺 %s>" % DOTNET_ZIP)
            grade("WARN", "%s: 包内没有 %s — 跳过 zip 组成检查（若 zip 可读才断言）" % (name, DOTNET_ZIP))
        else:
            try:
                dotnet_raw = z.read(DOTNET_ZIP)
                dotnet_sha = hashlib.sha256(dotnet_raw).hexdigest()
                with zipfile.ZipFile(io.BytesIO(dotnet_raw)) as dz:
                    dnames = dz.namelist()
                dotnet_entries = len(dnames)
                sos = [n for n in dnames if n.endswith(".so")]
                print("      zip    dotnet.zip entries=%d，.so=%d" % (dotnet_entries, len(sos)))
                if sos:
                    shown = ", ".join(sos[:3]) + (" ..." if len(sos) > 3 else "")
                    grade("FAIL", "%s: dotnet.zip 含 %d 个 .so: %s — 解包到 app 目录的未签名副本会被 enforcing 设备拒绝"
                                  " dlopen；同名 ELF 必须只出现在 libs/<abi>/（targets 的 OpenHarmonyDeterministicZip 排除名单）"
                                  % (name, len(sos), shown))
                expected_zip = AOT_ZIP_ENTRIES if mode == "aot" else JIT_ZIP_ENTRIES
                if dotnet_entries != expected_zip:
                    grade("WARN", "%s: dotnet.zip 条目 %d != 期望 %d — 运行时文件集变化时正常，确认后更新期望"
                                  % (name, dotnet_entries, expected_zip))
            except Exception as exc:
                print("      zip    dotnet.zip 读取失败（%s）" % exc)
                grade("WARN", "%s: 无法读取 dotnet.zip（%s）— 跳过 zip 组成检查（若 zip 可读才断言）" % (name, exc))

        # --- payload-in-libs: the staged payload the runtime starts from -----------------------
        # The packaging copies the whole managed payload into libs/<abi>/ and writes the
        # .dotnet-payload.json marker (see "Payload in libs" in the packaging doc). The device
        # namespace policy allows a dlopen only from that signed bundle directory, so the staged
        # payload is the copy that starts; without it the runtime falls back to the data
        # directory extraction an enforcing device refuses. The marker is therefore part of the
        # per-hap contract and every inconsistency is a FAIL: the named entry assembly must be
        # staged, the entry count must describe the real libs file count (marker excluded), the
        # payload count must match the zip fallback, and the recorded zip sha256 must describe
        # the packed dotnet.zip bytes.
        if PAYLOAD_MARKER not in names:
            print("      libs   <缺 %s（payload-in-libs 标志）>" % PAYLOAD_MARKER)
            grade("FAIL", "%s: 缺 %s — hap 没有把托管 payload 随 libs/<abi>/ 一起签名（el1/bundle/libs/<abi> 是设备"
                          "唯一允许 dlopen 的目录），启动会回退到 data 目录解包并被 enforcing 设备拒绝；用默认的"
                          " OpenHarmonyHapPayloadInLibs=true 重新打包" % (name, PAYLOAD_MARKER))
        else:
            libs_files = [n for n in names if n.startswith(LIBS_DIR) and not n.endswith("/")]
            actual_entries = len(libs_files) - 1  # the marker itself is not a libs payload entry
            payload_marker = None
            try:
                payload_marker = json.loads(z.read(PAYLOAD_MARKER))
                if not isinstance(payload_marker, dict):
                    raise ValueError("marker 不是 JSON 对象")
            except Exception as exc:
                print("      libs   payload marker 读取失败（%s）" % exc)
                grade("FAIL", "%s: %s 无法解析（%s）— payload-in-libs 身份无法校验，拒绝放行"
                              % (name, PAYLOAD_MARKER, exc))
            if payload_marker is not None:
                assembly = str(payload_marker.get("assembly", "?"))
                declared = payload_marker.get("entries")
                payload_entries = payload_marker.get("payloadEntries")
                zip_entries = payload_marker.get("zipEntries")
                zip_sha = str(payload_marker.get("zipSha256", ""))
                print("      libs   payload-in-libs: assembly=%s，条目=%s（实测 %d），payload=%s，zip=%s/%s"
                      % (assembly, declared, actual_entries, payload_entries, zip_entries,
                         (zip_sha[:12] + "...") if zip_sha else "<空>"))
                # The named entry must be staged: jit/interp stage the managed assembly itself;
                # aot stages the NativeAOT application library lib<stem>.so instead (the marker
                # still names the .dll the host derives the stem from).
                if mode == "aot":
                    stem = aot_stem(names, z)
                    staged = (LIBS_DIR + "lib%s.so" % stem) if stem else None
                    if assembly == "?" or staged is None or staged not in names:
                        grade("FAIL", "%s: payload marker 的入口程序集 '%s' 对应的 AOT 应用库 %s 不在 %s — payload 不完整"
                                      % (name, assembly, staged or "lib<stem>.so", LIBS_DIR))
                elif assembly == "?" or (LIBS_DIR + assembly) not in names:
                    grade("FAIL", "%s: payload marker 的入口程序集 '%s' 不在 %s（%s 缺失）— payload 不完整"
                                  % (name, assembly, LIBS_DIR, LIBS_DIR + assembly))
                if declared != actual_entries:
                    grade("FAIL", "%s: payload marker entries=%s 与实测 %s 目录文件数不符（实测 %d，不含 marker）—"
                                  " 标记与实际 payload 漂移" % (name, declared, LIBS_DIR, actual_entries))
                if payload_entries != zip_entries:
                    grade("FAIL", "%s: payload marker payloadEntries=%s != zipEntries=%s — libs payload 与 dotnet.zip"
                                  " 回退副本不一致" % (name, payload_entries, zip_entries))
                if dotnet_entries is not None and zip_entries != dotnet_entries:
                    grade("FAIL", "%s: payload marker zipEntries=%s != dotnet.zip 实际条目 %d — 回退 zip 已被替换"
                                  % (name, zip_entries, dotnet_entries))
                if dotnet_sha is not None:
                    if not zip_sha:
                        grade("FAIL", "%s: payload marker 没有 zipSha256 — 无法绑定 %s 回退副本" % (name, DOTNET_ZIP))
                    elif zip_sha != dotnet_sha:
                        grade("FAIL", "%s: payload marker zipSha256=%s... != dotnet.zip sha256=%s... — libs payload 与回退"
                                      " zip 不同源" % (name, zip_sha[:12], dotnet_sha[:12]))

with open(bundle_file, "w") as f:
    f.write(bundles[0] if bundles else "")

if sorted(set(bundles)) != [expected]:
    print("      FAIL  bundleName 期望 %s，实际 %s" % (expected, ", ".join(sorted(set(bundles))) or "无"))
    print("            旧 bundle 的 hap（bundle 名含连字符）需按 ohos-workload bbfa03c 重新打包")
    print("            后再交付；确属其他 bundle 时用 KIT_BUNDLE_NAME=<name> 覆盖期望值")
    grade("FAIL", "五个 hap 的 bundleName 期望 %s，实际 %s — 旧 bundle（含连字符）需按 ohos-workload bbfa03c 重打包；"
                  "确属其他 bundle 用 KIT_BUNDLE_NAME=<name> 覆盖" % (expected, ", ".join(sorted(set(bundles))) or "无"))
    fail = 1
else:
    print("      bundle 校验 OK：五个 hap 的 bundleName 一致（%s）" % expected)

with open(status_file, "w") as f:
    for level, msg in graded:
        f.write("%s\t%s\n" % (level, msg))
sys.exit(1 if fail else 0)
PY
    log "== 2b/4 深度断言（resources.index / abc / libs / payload-in-libs / dotnet.zip / 宿主依赖）"
    if [ -s "$TMP/deep-status" ]; then
        TAB="$(printf '\t')"
        while IFS="$TAB" read -r _lvl _msg; do
            case "$_lvl" in
                FAIL) DEEP_FAILS=$((DEEP_FAILS + 1)); FAIL=1; fail_msg "$_msg" ;;
                WARN) DEEP_WARNS=$((DEEP_WARNS + 1)); warn "$_msg" ;;
            esac
        done < "$TMP/deep-status"
    fi
    if [ "$DEEP_FAILS" -eq 0 ] && [ "$DEEP_WARNS" -eq 0 ]; then
        log "   全部关键断言通过：5 hap 的 index/abc/libs/payload-in-libs/宿主依赖均符合当前契约"
    else
        log "   深度断言汇总：FAIL $DEEP_FAILS，WARN $DEEP_WARNS（FAIL 需处理；WARN 不阻断）"
    fi
    KIT_BUNDLE="$(cat "$TMP/kit-bundle" 2>/dev/null || true)"
    [ -n "$KIT_BUNDLE" ] || KIT_BUNDLE="$BUNDLE_EXPECT"
else
    warn "python3 不可用，跳过 hap 摘要、bundleName 及深度断言（resources.index/abc/libs/宿主依赖）；文件完整性已由 SHA256SUMS 覆盖"
    KIT_BUNDLE="$BUNDLE_EXPECT"
fi

# ---- 2c: optional Blazor WASM ArkWeb component --------------------------------------------
# Only kits built with make-device-test-kit.sh --with-blazor carry the extra unsigned
# hello-blazorwasm-host-unsigned.hap; without it the section prints one line and moves on (a
# historical kit must not warn about a component it never had). When present, every deviation
# is a FAIL: the hap is self-contained (site + shell abc + bundle), so one missing piece means
# the ArkWeb host cannot boot the verified Blazor site. The stable `_framework/dotnet.js` is
# part of that set: pack-host.sh copies it from the fingerprinted asset since the host has no
# static-web-assets route table (kits #31/#32 predate the mapping and FAIL here).
if [ ! -f "$BLAZOR_HAP_NAME" ]; then
    log "== 2c/4 Blazor WASM 组件：本包未包含（构建时未启用 --with-blazor）"
else
    log "== 2c/4 Blazor WASM 组件断言（$BLAZOR_HAP_NAME）"
    grep -Fq "  $BLAZOR_HAP_NAME" SHA256SUMS || { warn "SHA256SUMS 未收录 $BLAZOR_HAP_NAME"; FAIL=1; }
    if command -v python3 >/dev/null 2>&1; then
        BLAZOR_DEEP_FAILS=0
        python3 - "$KIT" "$BLAZOR_HAP_NAME" "$BLAZOR_BUNDLE_EXPECT" "$TMP/blazor-status" \
            "$BLAZOR_ABC_VERSION" "$BLAZOR_SOURCE_PERMS" <<'PY' || FAIL=1
import json, os, re, sys, zipfile

kit = sys.argv[1]
hap_name = sys.argv[2]
expected_bundle = sys.argv[3]
status_file = sys.argv[4]
abc_version = sys.argv[5]
expected_perms = [p for p in sys.argv[6].replace(",", " ").split() if p]

graded = []


def grade(level, msg):
    graded.append((level, msg))


fail = 0
path = os.path.join(kit, hap_name)
print("  %s  可选 Blazor WASM ArkWeb 宿主（站点内嵌 resources/rawfile/blazor；未签名，安装前按 自签说明.md 重签）"
      % hap_name)
z = None
try:
    z = zipfile.ZipFile(path)
except Exception as exc:
    print("      BAD   无法读取 hap (%s)" % exc)
    grade("FAIL", "%s: 无法读取 hap (%s)" % (hap_name, exc))
    fail = 1
if z is not None:
    with z:
        names = z.namelist()
        bundle = "?"
        perms = None
        try:
            data = json.loads(z.read("module.json"))
            bundle = (data.get("app") or {}).get("bundleName", "?")
            module = data.get("module") or {}
            perms = [p.get("name", "?") for p in (module.get("requestPermissions") or [])]
        except Exception as exc:
            grade("FAIL", "%s: 无法读取 module.json (%s)" % (hap_name, exc))
            fail = 1
        print("      bundle=%s" % bundle)
        if bundle != "?" and bundle != expected_bundle:
            grade("FAIL", "%s: bundleName 期望 %s，实际 %s — Blazor 宿主必须按期望 bundle 打包"
                         "（pack-host.sh 默认值；重签不改变 bundle）" % (hap_name, expected_bundle, bundle))
            fail = 1

        # requestPermissions: recorded on every run and compared with the source-side
        # expectation. A disagreement is a WARN (never a FAIL): the kit shipped today may
        # predate the source-side removal (ohos-workload 2dcd846 removed INTERNET from the
        # host's module.json5), and a historical kit must keep its real verdict.
        if perms is not None:
            if perms:
                short = ", ".join(p.rsplit(".", 1)[-1] for p in perms)
                print("      权限   requestPermissions=%d [%s]" % (len(perms), short))
            else:
                print("      权限   requestPermissions=0")
            if sorted(perms) != sorted(expected_perms):
                exp = ", ".join(sorted(expected_perms)) if expected_perms else "0"
                act = ", ".join(sorted(perms)) if perms else "0"
                grade("WARN", "%s: Blazor hap 权限集 [%s] 与源侧期望 [%s] 不一致（记录实际值，不阻断）—"
                              " ohos-workload 2dcd846 已从源 module.json5 移除 INTERNET；本 hap 若是移除前的"
                              "构建属已知包内 delta，下一 kit 用 make-device-test-kit.sh --with-blazor"
                              " 重建后即一致" % (hap_name, act, exp))

        # Embedded ArkWeb site: the host serves resources/rawfile/blazor through
        # onInterceptRequest, so index.html, at least one _framework *.wasm and the
        # blazor.webassembly*.js boot script are the minimum servable set (same facts
        # run-smoke.sh checks at publish time).
        site_prefix = "resources/rawfile/blazor/"
        index_html = site_prefix + "index.html"
        site_files = [n for n in names if n.startswith(site_prefix) and not n.endswith("/")]
        framework = [n for n in site_files if n.startswith(site_prefix + "_framework/")]
        wasm = [n for n in framework if n.endswith(".wasm")]
        boot = [n for n in framework
                if os.path.basename(n).startswith("blazor.webassembly") and n.endswith(".js")]
        print("      站点   内嵌文件=%d；_framework=%d（.wasm=%d，blazor.webassembly*.js=%d）"
              % (len(site_files), len(framework), len(wasm), len(boot)))
        if index_html not in names:
            grade("FAIL", "%s: 缺 resources/rawfile/blazor/index.html — 宿主没有可服务的 Blazor 首屏"
                         "（用 make-device-test-kit.sh --with-blazor 重跑）" % hap_name)
            fail = 1
        else:
            print("      index  index.html %d B" % z.getinfo(index_html).file_size)
        if not wasm:
            grade("FAIL", "%s: resources/rawfile/blazor/_framework/ 下没有 .wasm — Blazor WASM 载荷缺失"
                          % hap_name)
            fail = 1
        if not boot:
            grade("FAIL", "%s: resources/rawfile/blazor/_framework/ 下没有 blazor.webassembly*.js —"
                         " Blazor 引导脚本缺失" % hap_name)
            fail = 1

        # Fingerprinted boot loader: .NET serves the stable name `_framework/dotnet.js` from the
        # fingerprinted asset `_framework/dotnet.<hash>.js`, with the route table only in the
        # publish's staticwebassets endpoints manifest. The host serves rawfiles 1:1, so
        # pack-host.sh materializes the stable name at embed time; without it the boot script's
        # dynamic import fails ("Failed to fetch dynamically imported module") and the verified
        # site never renders (kits #31/#32 shipped that way).
        dotnet_js = site_prefix + "_framework/dotnet.js"
        dotnet_fp = [n for n in framework
                     if re.match(r"^" + re.escape(site_prefix)
                                 + r"_framework/dotnet\.[a-z0-9]{10}\.js$", n)]
        if dotnet_js not in names:
            grade("FAIL", "%s: 缺 resources/rawfile/blazor/_framework/dotnet.js — 引导脚本动态 import 的"
                         "稳定名缺失（pack-host.sh 的静态 web assets 默认名映射未生效；kit #31/#32 的 hap"
                         " 即此缺陷，修复随 kit #33，用 make-device-test-kit.sh --with-blazor 重建）" % hap_name)
            fail = 1
        elif not dotnet_fp:
            grade("FAIL", "%s: 有 _framework/dotnet.js 但没有 _framework/dotnet.<hash>.js 指纹资产 —"
                         " 无法核对稳定名来自同构建产物" % hap_name)
            fail = 1
        else:
            blob = z.read(dotnet_js)
            match = next((n for n in dotnet_fp if z.read(n) == blob), None)
            if match is None:
                grade("FAIL", "%s: _framework/dotnet.js 与 dotnet.<hash>.js (%s) 内容不一致 —"
                             " 疑似旧构建残留（pack-host.sh 应复制同构建的指纹资产）"
                             % (hap_name, os.path.basename(dotnet_fp[0])))
                fail = 1
            else:
                print("      dotnet dotnet.js == %s (%d B)"
                      % (os.path.basename(match), len(blob)))

        # Shell abc: same PANDA contract as the five haps (the Blazor host has its own shell,
        # so only the format version is pinned, not the MAUI shell size).
        if "ets/modules.abc" not in names:
            grade("FAIL", "%s: 缺 ets/modules.abc — ArkTS 壳没有可加载的入口" % hap_name)
            fail = 1
        else:
            abc = z.read("ets/modules.abc")
            ver = ".".join(str(b) for b in abc[0x0C:0x10]) if len(abc) >= 0x10 and abc[:5] == b"PANDA" else None
            print("      abc    ets/modules.abc %d B，PANDA 头版本 %s" % (len(abc), ver or "?"))
            if ver is None:
                grade("FAIL", "%s: ets/modules.abc 不是 PANDA abc（前 4 字节 %r）" % (hap_name, abc[:4]))
                fail = 1
            elif ver != abc_version:
                grade("FAIL", "%s: abc PANDA 头版本 %s != %s（0x0c 处的 4 字节版本；壳/格式漂移）"
                              % (hap_name, ver, abc_version))
                fail = 1

        # --slim packing contract: no precompressed siblings and no ICU data in the embedded
        # site. Scoped to resources/rawfile/blazor/: the host's own ArkTS compile output
        # carries ets/sourceMaps.map, which is not a web asset and must not be flagged.
        stray = [n for n in names if n.startswith(site_prefix) and n.endswith((".br", ".gz", ".map"))]
        icu = [n for n in names
               if n.startswith(site_prefix) and os.path.basename(n).startswith("icudt") and n.endswith(".dat")]
        print("      slim   站点内 .br/.gz/.map=%d，icudt*.dat=%d" % (len(stray), len(icu)))
        if stray:
            shown = ", ".join(stray[:3]) + (" ..." if len(stray) > 3 else "")
            grade("FAIL", "%s: 内嵌站点仍有 %d 个 .br/.gz/.map: %s — --slim 未生效（pack-host.sh --slim 应剔除预压缩副本）"
                          % (hap_name, len(stray), shown))
            fail = 1
        if icu:
            shown = ", ".join(icu[:3]) + (" ..." if len(icu) > 3 else "")
            grade("FAIL", "%s: 内嵌站点仍有 %d 个 icudt*.dat: %s — --slim 未让 InvariantGlobalization 生效"
                          % (hap_name, len(icu), shown))
            fail = 1

with open(status_file, "w") as f:
    for level, msg in graded:
        f.write("%s\t%s\n" % (level, msg))
sys.exit(1 if fail else 0)
PY
        if [ -s "$TMP/blazor-status" ]; then
            TAB="$(printf '\t')"
            while IFS="$TAB" read -r _lvl _msg; do
                case "$_lvl" in
                    FAIL) BLAZOR_DEEP_FAILS=$((BLAZOR_DEEP_FAILS + 1)); DEEP_FAILS=$((DEEP_FAILS + 1)); FAIL=1; fail_msg "$_msg" ;;
                    WARN) DEEP_WARNS=$((DEEP_WARNS + 1)); warn "$_msg" ;;
                esac
            done < "$TMP/blazor-status"
        fi
        if [ "$BLAZOR_DEEP_FAILS" -eq 0 ]; then
            log "   Blazor 组件断言通过：index.html/_framework（dotnet.js 与指纹版同源）/abc/bundle/--slim 均符合契约"
        else
            log "   Blazor 组件断言汇总：FAIL $BLAZOR_DEEP_FAILS（组件需用 make-device-test-kit.sh --with-blazor 重打包）"
        fi
    else
        warn "python3 不可用，跳过 Blazor 组件断言（index.html/_framework/abc/bundle/--slim）；文件完整性已由 SHA256SUMS 覆盖"
    fi
fi

log "== 3/4 安装方式"
if [ -f 目标设备.txt ]; then
    log "   ★ 本包为预签包：全部 hap 已按 目标设备.txt 的 UDID 预签，可直接安装（其他设备仍被拒 9568344）"
else
    log "   ★ 警告：包内 4 个默认 hap 为【自签名】（仅绑定我方示例 UDID），真机安装会报 9568257/9568344 被拒；必须重签（自签说明.md，签 hello-maui-app-unsigned.hap）或改用发布方预签包"
fi
log "   文件管理器：把 hap 拷到设备后在文件管理器中打开 → 按提示安装（需开发者模式/允许调试与外部来源安装）"
log "   hdc：hdc list targets && hdc install <重签后的 hap>"
log "        启动：hdc shell aa start -a EntryAbility -b $KIT_BUNDLE（bundle 以上方 bundle= 行为准）"
log "   报 9568257 fail to verify pkcs7 file：自签名包的预期拒绝（见 签名说明.txt）—— 先重签再装"
log "   报 9568344 install parse profile prop check error：调试 profile 只绑了示例设备 UDID"
log "        二选一：① 按 自签说明.md 用你自己的 DevEco 自动签名；② 回传 UDID（hdc shell bm get -u）由签名方重签"
log "   设备策略报 E00C001 Operation restricted by the organization → 该设备关闭了 hdc，改用文件管理器安装"
log "   API 20 波段设备请装 hello-maui-app-api20*.hap；未签名 hap 自签完成后再装"

log "== 4/4 回传的日志行"
log "   [maui] openharmony build <ver> abi=<arch> provider=<n>    启动早期；provider=0 属预期"
log "   [maui] accessibility provider status=<n>                 1=已附着（理想）；0=启动初值（预期）"
log "   有 hdc：hdc hilog > log.txt（全程录制；失败项标注时间点）"
log "   无 hdc：截图应用日志区（或应用内 A11Y 自检弹窗）"
log "   关键字与 status 对照见 验收说明.md §5b；回传模板见 §6（一页上手：快速开始.md §6）"

if [ "$FAIL" -eq 0 ]; then
    if [ "$DEEP_WARNS" -gt 0 ]; then
        log "KIT OK（$DEEP_WARNS 条 WARN：多为历史 kit 的旧件提示，见上，不阻断）— 交付包完整，按 快速开始.md 开始测试"
    else
        log "KIT OK — 交付包完整，按 快速开始.md 开始测试"
    fi
    exit 0
else
    warn "KIT CHECK FAILED — 请先处理上面的 FAIL/WARN 项（深度断言 FAIL $DEEP_FAILS，WARN $DEEP_WARNS）"
    exit 1
fi
