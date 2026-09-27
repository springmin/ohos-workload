#!/bin/sh
# Delivery-side self-check for the harmony-flavor hap set (`harmony-haps.tar.gz`).
#
# The five haps are the kit payload (five-variant matrix: 26.0/20.0 x optional permission set +
# unsigned) rebuilt with the ui/shell abc of the HarmonyOS-SDK build. The static shape is checked
# pairwise against a control set built from the same commit WITHOUT the abc override, so the only
# expected difference is ets/modules.abc:
#
#   * the harmony abc must carry the Map overlay module record (entry/ets/map/MapOverlay) and the
#     compiled overlay symbols (mapOverlayView / markerClick / cameraIdle). Before MAPFIX
#     (2026-09-28) the overlay was copied but never reached hvigor's compile graph, so the record
#     was absent and the Map sink could only answer capability bit 1 = 0; the build now injects a
#     static import of ./map/MapOverlay into its Index.ets copy (patch_harmony_index_ets).
#   * the control abc must be the default shell (no overlay record, byte-identical to the pack's
#     modules.ui.abc), which pins "default flavor unaffected".
#
# Usage: verify-harmony-haps.sh <harmony-haps-dir> <control-haps-dir> [outdir]
# Every check prints PASS/FAIL; exit 0 only when all passed.
set -u
HAPS=$(cd "$1" && pwd)
CONTROL=$(cd "$2" && pwd)
OUTBASE="${3:-${TMPDIR:-/tmp}/verify-harmony-haps}"
OUT=$(mkdir -p "$OUTBASE" && cd "$OUTBASE" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
ABC_SHA=a637a5136681b803186969ca2753a439735e35bf41c752d1849cbec2a482487b
ABC_SIZE=291628
CONTROL_ABC_SHA=5c06143a727dff8e534e357299278f22e3e49ae97419615b113b8d7053a417c7
CONTROL_ABC_SIZE=281052
HOST_SHA=5248c6a986e0935cce7b72172ebb5973ef444b16485aa731ba8298f8f56359fb
HOST_SIZE=285600
PERM_LIST="ohos.permission.ACCESS_BLUETOOTH;ohos.permission.PRINT;ohos.permission.READ_CONTACTS;ohos.permission.READ_CALENDAR;ohos.permission.WRITE_CALENDAR"
NAMES="hello-maui-app.hap hello-maui-app-unsigned.hap hello-maui-app-permissions.hap hello-maui-app-api20.hap hello-maui-app-api20-permissions.hap"
fail=0
say() { printf '%s\n' "$*"; }
check() {
    if eval "$2"; then say "[PASS] $1"; else say "[FAIL] $1"; fail=$((fail + 1)); fi
}
zipcount() { python3 -c 'import sys,zipfile;print(len(zipfile.ZipFile(sys.argv[1]).namelist()))' "$1"; }
abc_has() { # <abc> <needle>
    python3 -c 'import sys;sys.exit(0 if sys.argv[2].encode() in open(sys.argv[1],"rb").read() else 1)' "$1" "$2"
}
abc_panda() { # <abc> <size> <sha>
    python3 -c 'import hashlib,sys;b=open(sys.argv[1],"rb").read();sys.exit(0 if len(b)==int(sys.argv[2]) and hashlib.sha256(b).hexdigest()==sys.argv[3] and b[:5]==b"PANDA" and b[0x0c:0x10]==bytes([13,0,1,0]) else 1)' "$1" "$2" "$3"
}
rm -rf "$OUT"
mkdir -p "$OUT"
for n in $NAMES; do
    say ""
    say "== $n =="
    hap="$HAPS/$n"; ctl="$CONTROL/$n"; d="$OUT/${n%.hap}"
    check "$n: harmony hap present" "[ -f '$hap' ]"
    check "$n: control hap present" "[ -f '$ctl' ]"
    if [ ! -f "$hap" ] || [ ! -f "$ctl" ]; then continue; fi
    say "size=$(stat -c %s "$hap") sha256=$(sha256sum "$hap" | awk '{print $1}')"
    mkdir -p "$d/harmony" "$d/control"
    ( cd "$d/harmony" && unzip -oq "$hap" ) || { say "[FAIL] unzip $hap"; fail=$((fail + 1)); continue; }
    ( cd "$d/control" && unzip -oq "$ctl" ) || { say "[FAIL] unzip $ctl"; fail=$((fail + 1)); continue; }
    check "$n: zip entries = 278 (kit payload shape)" "[ \"\$(zipcount '$hap')\" = '278' ]"
    # harmony abc: size + sha + PANDA version, then the MAPFIX overlay evidence.
    abc="$d/harmony/ets/modules.abc"
    check "$n: harmony abc = $ABC_SIZE B / $ABC_SHA / PANDA 13.0.1.0" "abc_panda '$abc' '$ABC_SIZE' '$ABC_SHA'"
    check "$n: overlay module record entry/ets/map/MapOverlay" "abc_has '$abc' 'entry/ets/map/MapOverlay'"
    check "$n: overlay symbols mapOverlayView/markerClick/cameraIdle" "abc_has '$abc' 'mapOverlayView' && abc_has '$abc' 'markerClick' && abc_has '$abc' 'cameraIdle'"
    # control abc: the installed default shell, no overlay record.
    cabc="$d/control/ets/modules.abc"
    check "$n: control abc = $CONTROL_ABC_SIZE B / $CONTROL_ABC_SHA / PANDA 13.0.1.0" "abc_panda '$cabc' '$CONTROL_ABC_SIZE' '$CONTROL_ABC_SHA'"
    check "$n: control abc has no overlay record" "! abc_has '$cabc' 'entry/ets/map/MapOverlay'"
    check "$n: harmony abc differs from the control abc" "! cmp -s '$abc' '$cabc'"
    # host + libs shape (identical to the control; only the abc may differ).
    host="$d/harmony/libs/arm64-v8a/libopenharmonyhost.so"
    check "$n: host size $HOST_SIZE" "[ \"\$(stat -c %s '$host')\" = '$HOST_SIZE' ]"
    check "$n: host sha256 $HOST_SHA" "[ \"\$(sha256sum '$host' | cut -d' ' -f1)\" = '$HOST_SHA' ]"
    check "$n: libs/arm64-v8a files = 269" "[ \"\$(find '$d/harmony/libs/arm64-v8a' -type f | wc -l)\" = '269' ]"
    check "$n: libs .so = 14" "[ \"\$(find '$d/harmony/libs/arm64-v8a' -type f -name '*.so' | wc -l)\" = '14' ]"
    check "$n: payload entries = 254" "[ \"\$(find '$d/harmony/libs/arm64-v8a' -type f ! -name '*.so' ! -name '.dotnet-payload.json' | wc -l)\" = '254' ]"
    check "$n: payload-in-libs marker" "[ -f '$d/harmony/libs/arm64-v8a/.dotnet-payload.json' ]"
    check "$n: marker assembly hello-maui-app.dll" "grep -q 'hello-maui-app.dll' '$d/harmony/libs/arm64-v8a/.dotnet-payload.json'"
    codesign_n=0
    for so in "$d/harmony"/libs/arm64-v8a/*.so; do
        readelf -S "$so" 2>/dev/null | grep -q '\.codesign' && codesign_n=$((codesign_n + 1))
    done
    check "$n: .codesign on all 14 .so" "[ '$codesign_n' = '14' ]"
    check "$n: host exports ohos_host_start_app" "nm -D '$host' 2>/dev/null | grep -q ohos_host_start_app"
    # module.json: byte-equal to the control (pins libIsolation/permissions/template keys).
    check "$n: module.json == control counterpart" "cmp -s '$d/harmony/module.json' '$d/control/module.json'"
    check "$n: module.libIsolation = true" "python3 -c \"import json,sys;d=json.load(open('$d/harmony/module.json'));sys.exit(0 if d['module'].get('libIsolation') is True else 1)\""
done
say ""
say "== permissions variants =="
for n in hello-maui-app-permissions.hap hello-maui-app-api20-permissions.hap; do
    d="$OUT/${n%.hap}"
    check "$n: 5 requestPermissions with reason+usedScene" "python3 - '$d/harmony/module.json' '$PERM_LIST' <<'PY'
import json, sys
want = sys.argv[2].split(';')
perms = json.load(open(sys.argv[1]))['module'].get('requestPermissions', [])
sys.exit(0 if ([p.get('name') for p in perms] == want
                and all(p.get('reason')
                        and p.get('usedScene', {}).get('abilities') == ['EntryAbility']
                        and p['usedScene'].get('when') == 'inuse' for p in perms)) else 1)
PY"
done
say ""
if [ "$fail" = "0" ]; then say "ALL CHECKS PASSED"; else say "$fail CHECK(S) FAILED"; fi
exit "$fail"
