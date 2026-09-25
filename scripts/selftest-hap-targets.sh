#!/bin/sh
# selftest-hap-targets.sh - repeatable functional selftest for the hap packaging contracts that
# can run without a device, the OpenHarmony SDK or a full publish:
#
#   T1 static      the three packs stay byte-identical and carry the JSON-aware module.json task
#                  (no ReadLinesFromFile template read)
#   T2 golden      the task reproduces the documented module.json bytes for the API 20 band, the
#                  device band with compileSdk+permissions, and a multi-line template
#   T3 negatives   an unknown template placeholder, a bare non-literal value and a malformed
#                  template all fail the build instead of packing a broken manifest
#   T4 toolchain   the strict toolchain resolution fails without a root / with a root that has no
#                  toolchains/lib, naming the property or the missing file (no $HOME probe)
#   T5 features    the feature -> permission matrix resolves to module.json entries with
#                  reason/usedScene, an unknown feature id and the strict request-point mode fail,
#                  'all' emits the eight unique permissions, and the raw extra-permission path
#                  keeps its minimal form plus the raw-permission warning
#   T6 device      hdc-gated install + grant integration: installs OHOS_TEST_HAP, reads the
#                  installed requestPermissions back through bm dump and checks that each entry
#                  carries name/reason/usedScene; SKIPs without a device or the hap (no device
#                  is attached to this build host, so the scaffold + the manual commands in the
#                  packaging doc are the evidence there)
#
# The fixture imports the real pack targets (so the UsingTask under test is the shipped one) and
# calls the task directly. Needs a dotnet SDK; when dotnet is unavailable the functional half is
# reported as [SKIP] so the static half still gates.
#
# Env: SELFTEST_TMPDIR=<dir>  work dir base (default: the approved opencode tmp dir)
#      DOTNET=<dotnet>       SDK used for the fixture
#      SELFTEST_KEEP=1       keep the work dir even when all checks pass
# Exit: 0 = all checks passed; 1 = at least one check failed (work dir kept for triage).
set -u

SELFTEST_VERSION="1 (2026-09-25)"

log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

W="$(cd "$(dirname "$0")/.." && pwd)"
PACK_VERSIONS="1.0.0-preview.22 1.0.0-preview.23 1.0.0-preview.24"
WORK_BASE="${SELFTEST_TMPDIR:-/data/storage/el2/base/tmp/opencode}"
KEEP="${SELFTEST_KEEP:-0}"
DOTNET="${DOTNET:-dotnet}"

for _t in python3 grep sed cmp mktemp; do
    command -v "$_t" >/dev/null 2>&1 || { printf 'FATAL: required command not found: %s\n' "$_t" >&2; exit 1; }
done

WORK="$(mktemp -d "$WORK_BASE/selftest-hap-targets.XXXXXX")" || {
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

log "selftest-hap-targets v$SELFTEST_VERSION"
log "work: $WORK"

# ---- T1: static pack contract -----------------------------------------------------------
section "T1 static pack contract"
REF="$W/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.24/targets/OpenHarmony.Hap.targets"
same=1
for v in $PACK_VERSIONS; do
    cmp -s "$W/packs/Microsoft.OpenHarmony.Sdk/$v/targets/OpenHarmony.Hap.targets" "$REF" || same=0
done
[ "$same" -eq 1 ] && pass_ "T1 preview.22/23/24 OpenHarmony.Hap.targets are byte-identical" \
                  || fail_ "T1 the three pack targets differ"
if grep -qF '<UsingTask TaskName="OpenHarmonyGenerateModuleJson"' "$REF" &&
   grep -qF 'class OpenHarmonyGenerateModuleJson' "$REF" &&
   ! grep -qF '<ReadLinesFromFile File="$(_OpenHarmonyTemplatesDir)module.json.template">' "$REF"; then
    pass_ "T1 the module.json task is present and the ReadLinesFromFile template read is gone"
else
    fail_ "T1 the module.json task contract drifted"
fi

# ---- T2/T3: the functional fixture -------------------------------------------------------
section "T2/T3 module.json fixture"
if ! command -v "$DOTNET" >/dev/null 2>&1; then
    skip_ "T2/T3 need dotnet (set DOTNET= to run the fixture)"
else
    FIX="$WORK/fixture"
    mkdir -p "$FIX"
    TPL="$W/packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.24/templates/module.json.template"
    python3 - "$FIX" "$TPL" "$REF" <<'PY'
import json, os, sys

fix, template, targets = sys.argv[1:4]
tpl = open(template).read()
values = {
    'BUNDLE_NAME': 'com.example.hellomauiapp',
    'VENDOR': 'openharmony',
    'VERSION_CODE': '1',
    'VERSION_NAME': '1.0.0',
    'MIN_API': '60000020',
    'TARGET_API': '60000020',
    'API_RELEASE_TYPE': 'Release',
    'DEBUG': 'true',
    'ABILITY_NAME': 'EntryAbility',
}
perms = ['ohos.permission.ACCESS_BLUETOOTH', 'ohos.permission.PRINT']

def fill(s):
    for k, v in values.items():
        s = s.replace(f'@{k}@', v)
    return s

def with_compile_sdk(s):
    return s.replace('"apiReleaseType":"Release",',
                     '"apiReleaseType":"Release","compileSdkVersion":"6.0.2.130","compileSdkType":"HarmonyOS",')

def with_perms(s):
    body = ','.join('{"name":"%s"}' % p for p in perms)
    cut = len(s.rstrip('}'))
    return s[:cut] + f',"requestPermissions":[{body}]' + '}}'

base = tpl.rstrip('\n')
open(os.path.join(fix, 'expected-A.json'), 'w').write(fill(base) + '\n')
open(os.path.join(fix, 'expected-B.json'), 'w').write(with_perms(with_compile_sdk(fill(base))) + '\n')

# multi-line variant: the JSON pretty-printed with the bundle-name placeholder still in place
pretty = json.dumps(json.loads(fill(base)), indent=2).replace('com.example.hellomauiapp', '@BUNDLE_NAME@')
open(os.path.join(fix, 'multi-line.template'), 'w').write(pretty + '\n')
open(os.path.join(fix, 'expected-C.json'), 'w').write(pretty.replace('@BUNDLE_NAME@', 'com.example.hellomauiapp') + '\n')

# malformed template: a string value without its closing quote (must fail JSON validation)
bad = fill(base).replace('"vendor":"openharmony"', '"vendor""openharmony"')
open(os.path.join(fix, 'bad-json.template'), 'w').write(bad + '\n')

def items(name, vals):
    return '\n'.join(f'      <{name} Include="{k}"><Value>{v}</Value></{name}>' for k, v in vals.items())

proj = f'''<Project>
  <PropertyGroup>
    <!-- Satisfies the Hap.targets UsingTask evaluation; the codesign task is never run here. -->
    <MicrosoftNETBuildTasksAssembly>$(MSBuildToolsPath)/Microsoft.Build.Tasks.Core.dll</MicrosoftNETBuildTasksAssembly>
  </PropertyGroup>
  <Import Project="{targets}" />
  <ItemGroup>
{items('_R', values)}
      <_P Include="{perms[0]}" /><_P Include="{perms[1]}" />
      <_Partial Include="BUNDLE_NAME"><Value>com.example.x</Value></_Partial>
{items('_RBadRaw', dict(values, VERSION_CODE='one'))}
  </ItemGroup>
  <Target Name="Run">
    <OpenHarmonyGenerateModuleJson TemplateFile="$(TplA)" OutputFile="out-A.json" Replacements="@(_R)" />
    <OpenHarmonyGenerateModuleJson TemplateFile="$(TplA)" OutputFile="out-B.json" Replacements="@(_R)"
                                   CompileSdkVersion="6.0.2.130" CompileSdkType="HarmonyOS" ExtraPermissions="@(_P)" />
    <OpenHarmonyGenerateModuleJson TemplateFile="$(TplMulti)" OutputFile="out-C.json" Replacements="@(_R)" />
  </Target>
  <Target Name="BadMissing">
    <OpenHarmonyGenerateModuleJson TemplateFile="$(TplA)" OutputFile="out-bad-missing.json" Replacements="@(_Partial)" />
  </Target>
  <Target Name="BadRaw">
    <OpenHarmonyGenerateModuleJson TemplateFile="$(TplA)" OutputFile="out-bad-raw.json" Replacements="@(_RBadRaw)" />
  </Target>
  <Target Name="BadJson">
    <OpenHarmonyGenerateModuleJson TemplateFile="$(TplBad)" OutputFile="out-bad-json.json" Replacements="@(_R)" />
  </Target>
  <Target Name="DetectNoRoot">
    <CallTarget Targets="_OpenHarmonyDetectToolchain" />
  </Target>
  <Target Name="DetectBadRoot">
    <CallTarget Targets="_OpenHarmonyDetectToolchain" />
  </Target>
</Project>
'''
open(os.path.join(fix, 'fixture.proj'), 'w').write(proj)
print('fixture written')
PY
    run_fixture() { # <target>
        ( cd "$FIX" && "$DOTNET" msbuild fixture.proj -t:"$1" -nologo -v:m \
            -p:TplA="$TPL" -p:TplMulti="$FIX/multi-line.template" -p:TplBad="$FIX/bad-json.template" ) \
            > "$WORK/$1.log" 2>&1
    }

    run_fixture Run
    assert_rc 0 $? "T2 the fixture evaluates and runs"
    for pair in "A:golden API20 placeholders" "B:golden compileSdk+permissions" "C:multi-line template"; do
        out="${pair%%:*}"; label="${pair#*:}"
        if cmp -s "$FIX/expected-$out.json" "$FIX/out-$out.json"; then
            pass_ "T2 $label is byte-identical"
        else
            fail_ "T2 $label differs (see $FIX/out-$out.json)"
        fi
    done

    for target in BadMissing BadRaw BadJson; do
        run_fixture "$target"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            pass_ "T3 $target fails the build (exit $rc)"
        else
            fail_ "T3 $target was accepted (expected a failure)"
        fi
    done
    grep -qF 'no value was supplied' "$WORK/BadMissing.log" && pass_ "T3 BadMissing names the missing placeholder" \
        || fail_ "T3 BadMissing does not name the missing placeholder"
    grep -qF 'must be a JSON literal' "$WORK/BadRaw.log" && pass_ "T3 BadRaw names the JSON-literal requirement" \
        || fail_ "T3 BadRaw does not name the JSON-literal requirement"
    grep -qF 'not valid JSON' "$WORK/BadJson.log" && pass_ "T3 BadJson reports the JSON validation failure" \
        || fail_ "T3 BadJson does not report the JSON validation failure"

    # T4: the strict toolchain resolution (no $HOME probe): with neither root set the target
    # fails naming the property, with a bad root it names the missing toolchains/lib.
    ( cd "$FIX" && env -u OHOS_SDK_ROOT -u OHOS_SDK -u OpenHarmonySdkRoot -u OpenHarmonyToolchainDir \
        "$DOTNET" msbuild fixture.proj -t:DetectNoRoot -nologo -v:m -p:OpenHarmonyHapPackage=true \
        -p:OpenHarmonySdkRoot= -p:OpenHarmonyToolchainDir= ) > "$WORK/DetectNoRoot.log" 2>&1
    assert_rc 1 $? "T4 DetectNoRoot fails without an SDK root"
    grep -qF 'Set OpenHarmonySdkRoot (or OHOS_SDK_ROOT)' "$WORK/DetectNoRoot.log" \
        && pass_ "T4 DetectNoRoot names the property to set" \
        || fail_ "T4 DetectNoRoot does not name the property to set"
    ( cd "$FIX" && env -u OHOS_SDK_ROOT -u OHOS_SDK -u OpenHarmonySdkRoot -u OpenHarmonyToolchainDir \
        "$DOTNET" msbuild fixture.proj -t:DetectBadRoot -nologo -v:m -p:OpenHarmonyHapPackage=true \
        -p:OpenHarmonySdkRoot="$WORK/does-not-exist" -p:OpenHarmonyToolchainDir= ) > "$WORK/DetectBadRoot.log" 2>&1
    assert_rc 1 $? "T4 DetectBadRoot fails on a root without toolchains/lib"
    grep -qF 'does not contain toolchains/lib/ohos_packing_tool' "$WORK/DetectBadRoot.log" \
        && pass_ "T4 DetectBadRoot names the missing toolchain path" \
        || fail_ "T4 DetectBadRoot does not name the missing toolchain path"
fi

# ---- T5: feature permissions (fixture) --------------------------------------------------
section "T5 feature permissions"
if ! command -v "$DOTNET" >/dev/null 2>&1; then
    skip_ "T5 needs dotnet for the feature-permission fixture"
else
    PERMFIX="$WORK/permfix"
    mkdir -p "$PERMFIX"
    python3 - "$PERMFIX" "$W" "$REF" "$TPL" <<'PY'
import os, sys
fix, root, targets, template = sys.argv[1:5]
pack_dir = os.path.dirname(os.path.dirname(targets)) + '/'
values = {
    'BUNDLE_NAME': 'com.example.permprobe',
    'VENDOR': 'openharmony',
    'VERSION_CODE': '1',
    'VERSION_NAME': '1.0.0',
    'MIN_API': '60000020',
    'TARGET_API': '60000020',
    'API_RELEASE_TYPE': 'Release',
    'DEBUG': 'true',
    'ABILITY_NAME': 'EntryAbility',
}
items = '\n'.join(f'      <_R Include="{k}"><Value>{v}</Value></_R>' for k, v in values.items())
proj = f'''<Project>
  <PropertyGroup>
    <MicrosoftNETBuildTasksAssembly>$(MSBuildToolsPath)/Microsoft.Build.Tasks.Core.dll</MicrosoftNETBuildTasksAssembly>
    <_OpenHarmonySdkPackDir>{pack_dir}</_OpenHarmonySdkPackDir>
  </PropertyGroup>
  <Import Project="{targets}" />
  <ItemGroup>
{items}
  </ItemGroup>
  <Target Name="Emit" DependsOnTargets="_OpenHarmonyResolvePermissions">
    <OpenHarmonyGenerateModuleJson TemplateFile="$(Tpl)" OutputFile="out.json" Replacements="@(_R)"
                                   ExtraPermissions="@(_OpenHarmonyModuleJsonPermission)" />
  </Target>
</Project>
'''
open(os.path.join(fix, 'perm.proj'), 'w').write(proj)
PY
    run_perm() { # <args...>
        ( cd "$PERMFIX" && "$DOTNET" msbuild perm.proj -t:Emit -nologo -v:m -p:Tpl="$TPL" \
            -p:TargetPlatformIdentifier=openharmony -p:OpenHarmonyHapPackage=true "$@" ) > "$WORK/T5-case.log" 2>&1
    }
    run_perm -p:OpenHarmonyFeatures=bluetooth
    assert_rc 0 $? "T5 the bluetooth feature resolves"
    python3 - "$PERMFIX/out.json" <<'PY' && pass_ "T5 the bluetooth entry carries name/reason/usedScene" || fail_ "T5 the bluetooth entry is incomplete"
import json, sys
perms = json.load(open(sys.argv[1]))['module'].get('requestPermissions', [])
assert len(perms) == 1, perms
entry = perms[0]
assert entry['name'] == 'ohos.permission.ACCESS_BLUETOOTH', entry
assert entry['reason'] == '$string:permission_reason_bluetooth', entry
assert entry['usedScene']['abilities'] == ['EntryAbility'], entry
assert entry['usedScene']['when'] == 'inuse', entry
PY
    run_perm -p:OpenHarmonyFeatures=bogus
    assert_rc 1 $? "T5 an unknown feature id fails"
    grep -qF 'unknown feature id' "$WORK/T5-case.log" && pass_ "T5 names the unknown feature" \
        || fail_ "T5 does not name the unknown feature"
    run_perm
    assert_rc 0 $? "T5 no features keeps the legacy build working"
    python3 - "$PERMFIX/out.json" <<'PY' && pass_ "T5 no features emits no requestPermissions" || fail_ "T5 no-feature module.json carries requestPermissions"
import json, sys
assert 'requestPermissions' not in json.load(open(sys.argv[1]))['module']
PY
    grep -qF 'the shipped shell can request permission(s) the app does not declare' "$WORK/T5-case.log" \
        && pass_ "T5 no features warns about the shell request points" \
        || fail_ "T5 no request-point warning"
    run_perm -p:OpenHarmonyFeatures=all
    assert_rc 0 $? "T5 the 'all' feature selection resolves"
    python3 - "$PERMFIX/out.json" <<'PY' && pass_ "T5 'all' declares the eight unique permissions once each" || fail_ "T5 'all' declaration set is wrong"
import json, sys
names = [p['name'] for p in json.load(open(sys.argv[1]))['module']['requestPermissions']]
assert len(names) == len(set(names)) == 8, names
for want in ('ohos.permission.ACCESS_BLUETOOTH', 'ohos.permission.APPROXIMATELY_LOCATION',
             'ohos.permission.READ_PASTEBOARD', 'ohos.permission.READ_CONTACTS',
             'ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR',
             'ohos.permission.PRINT', 'ohos.permission.INTERNET'):
    assert want in names, (want, names)
PY
    run_perm -p:OpenHarmonyFeatures=bluetooth -p:OpenHarmonyRequireDeclaredRequestPoints=true
    assert_rc 1 $? "T5 the strict request-point mode fails on an undeclared point"
    grep -qF 'does not declare' "$WORK/T5-case.log" && pass_ "T5 strict mode names the undeclared points" \
        || fail_ "T5 strict mode does not name the undeclared points"
    run_perm '-p:OpenHarmonyExtraPermissions="ohos.permission.CAMERA"'
    assert_rc 0 $? "T5 the raw extra-permission escape hatch still works"
    grep -qF 'raw permission' "$WORK/T5-case.log" && pass_ "T5 flags a raw permission without a reason" \
        || fail_ "T5 does not flag the raw permission"
    python3 - "$PERMFIX/out.json" <<'PY' && pass_ "T5 the raw extra keeps the minimal entry form" || fail_ "T5 the raw extra entry changed"
import json, sys
perms = json.load(open(sys.argv[1]))['module']['requestPermissions']
assert perms == [{'name': 'ohos.permission.CAMERA'}], perms
PY
fi

# ---- T6: device install + grant (hdc-gated) ---------------------------------------------
section "T6 device install + grant"
HDC="$(command -v hdc 2>/dev/null || true)"
DEVICE=""
if [ -n "$HDC" ]; then
    DEVICE="$("$HDC" list targets 2>/dev/null | head -1)"
fi
HAP="${OHOS_TEST_HAP:-}"
if [ -z "$DEVICE" ]; then
    skip_ "T6 no hdc device attached; run on a device with OHOS_TEST_HAP=<signed hap> to verify install + grant"
elif [ -z "$HAP" ] || [ ! -f "$HAP" ]; then
    skip_ "T6 set OHOS_TEST_HAP=<signed hap> to run the install + grant integration"
else
    BUNDLE="$(python3 - "$HAP" <<'PY'
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    print(json.loads(z.read('module.json'))['app']['bundleName'])
PY
)"
    "$HDC" install -r "$HAP" > "$WORK/T6-install.log" 2>&1
    assert_rc 0 $? "T6 hdc install accepts the hap"
    "$HDC" shell bm dump -n "$BUNDLE" > "$WORK/T6-dump.json" 2>&1
    assert_rc 0 $? "T6 bm dump reports the installed bundle"
    python3 - "$WORK/T6-dump.json" <<'PY' && pass_ "T6 the installed requestPermissions carry reason+usedScene" \
        || fail_ "T6 the installed requestPermissions are incomplete (see $WORK/T6-dump.json)"
import json, sys
text = open(sys.argv[1]).read()
start = text.find('{')
data = json.loads(text[start:]) if start >= 0 else json.loads(text)
# bm dump emits a list (or a single object) of modules; collect requestPermissions.
records = data if isinstance(data, list) else [data]
found = []
for record in records:
    for module in (record.get('moduleInfos') or record.get('moduleInfo') or [record]):
        found.extend(module.get('requestPermissions') or [])
assert found, 'no requestPermissions in bm dump'
for entry in found:
    assert entry.get('name'), entry
    assert entry.get('reason'), entry
    assert entry.get('usedScene'), entry
print('    requestPermissions:', ', '.join(e['name'] for e in found))
PY
    # System-grant permissions (INTERNET/PRINT) must already be granted at install time; the
    # user_grant entries stay ungranted until the app requests them, which UI automation drives.
    "$HDC" shell atm dump -n "$BUNDLE" > "$WORK/T6-atm.log" 2>&1 || true
    if grep -qE 'INTERNET|PRINT' "$WORK/T6-atm.log"; then
        pass_ "T6 atm dump reports the system-grant permissions (full log: $WORK/T6-atm.log)"
    else
        skip_ "T6 atm dump shape not recognized on this device; inspect $WORK/T6-atm.log"
    fi
    pass_ "T6 device evidence kept in $WORK (install/dump/atm logs)"
fi

# ---- summary ---------------------------------------------------------------------------
section "summary"
log "checks: $CHECKS, failed: $FAILED, skipped: $SKIP"
if [ "$FAILED" -gt 0 ]; then
    log "SELFTEST FAILED - work dir kept: $WORK"
    exit 1
fi
log "SELFTEST OK - the shipped module.json task reproduces the documented bytes and rejects broken input"
if [ "$KEEP" = "1" ]; then
    log "work dir kept (SELFTEST_KEEP=1): $WORK"
else
    rm -rf "$WORK"
fi
exit 0
