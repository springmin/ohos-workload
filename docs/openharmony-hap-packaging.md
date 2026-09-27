# OpenHarmony .hap packaging

Reference for `packs/Microsoft.OpenHarmony.Sdk/<version>/targets/OpenHarmony.Hap.targets`, the
`dotnet publish -p:OpenHarmonyHapPackage=true` stage-to-hap pipeline. The targets file carries a
short summary and names the section that applies; this document is the long-form record of the
constraints and decisions behind it. Keep the targets file byte-identical across the
preview.22/23/24 packs (`test/maui-platform-verify`, PG2).

## Stage layout

Packed by the OpenHarmony SDK's `ohos_packing_tool`:

```text
module.json, resources.index, ets/modules.abc,
libs/<abi>/{libopenharmonyhost.so, libc++_shared.so, <.NET runtime *.so>,
            <.NET managed payload: .dll/.json/... subdirectories, .dotnet-payload.json>},
resources/base/..., resources/rawfile/{app.json, dotnet.zip}
```

## module.json generation

`module.json` is produced by the `OpenHarmonyGenerateModuleJson` task (using task in the targets
file) from `templates/module.json.template`: the task reads the whole template, substitutes the
`@NAME@` tokens in their JSON context (a token inside a string is escaped as a JSON string, a bare
token must be a JSON literal such as `60000020` or `true`), inserts `compileSdkVersion`/
`compileSdkType` after `app.apiReleaseType` and the opt-in `requestPermissions` member, and
validates the result as JSON before writing it (only when the bytes changed). A template with an
unknown token, a non-literal bare token or otherwise invalid JSON fails the build instead of
packing a broken manifest. The previous implementation read the template line-by-line and joined
the lines, so a template with any other formatting silently produced invalid JSON.

## Resource index

`resources.index` is compiled by the SDK's `restool` from the staged `resources/` tree and the
same `module.json` that is packed (`_OpenHarmonyGenerateResourceIndex` in the targets file), then
handed to `ohos_packing_tool pack` with `--index-path`. The device `ResourceManager` resolves the
hap's resources through that index; without it the ArkTS shell's rawfile read fails with
`GetRawFileContent failed, name is empty` and the managed bootstrap never starts, so the index is
not optional. The resource ids follow the module.json declarations (`requestPermissions` and the
compileSdk fields included), and restool itself picks the index format from
`module.json`'s `minAPIVersion` (`RestoolV2` for API >= 20, the legacy `Restool` format for the
older bands), so no format flag is needed.

`OpenHarmonyRestool` overrides the restool binary; the default resolution follows the resolved
packing tool (`<toolchain dir>/../restool`, then `<OpenHarmonySdkRoot>/toolchains/restool`). A
missing restool is a build error: a hap without the index installs but cannot read its rawfile
payload. restool also copies the whole `resources/` tree into its output directory
(`<stage>/res-index/`); the index is self-contained, so the copy is deleted and only
`resources.index` is kept. The device-test kit's `verify-kit.sh` asserts the packed index
(present, non-empty, ≤ 1 KiB), the abc header/size, the `libs/arm64-v8a` set, the
payload-in-libs marker (entry assembly, staged file count, dotnet.zip identity) and the
`dotnet.zip` composition per hap, plus the host ELF dependency discipline against
`src/OpenHarmonyHost/host-deps.conf`; `scripts/selftest-verify-kit.sh` drives those
assertions locally without a device (kit #23+).

## Staging directory

`OpenHarmonyHapStageDir` (overridable) selects where the payload is staged before packing. It is
resolved at target execution time - not at evaluation time, when `PublishDir` is still empty -
with these defaults, in order:

1. `$(IntermediateOutputPath)openharmony-hap/` (default; under `obj/`)
2. `$(BaseIntermediateOutputPath)openharmony-hap/` (when `IntermediateOutputPath` is unset)
3. `$(PublishDir)openharmony-hap/` (publish-only project types)

The directory is deleted and recreated for each package, so stale files from an earlier publish
cannot leak into a hap. The property must point somewhere other than the project directory: the
packaging writes `module.json`, `ets/`, `resources/` and `libs/` into it.

## C++ runtime

`libopenharmonyhost.so` links the shared C++ runtime (`DT_NEEDED libc++_shared.so`) and the device
loader refuses a hap whose `libs/<abi>/` lacks the dependency, so the staging copies the SDK's
`libc++_shared.so` next to the host. It is looked up only under explicit roots:
`OpenHarmonySdkRoot` (or `OHOS_SDK_ROOT`), both as `<root>/native/llvm` and with the root itself as
the native root, and `OHOS_NDK`, in the LLVM triple matching `OpenHarmonyAbi`
(arm64-v8a -> aarch64-linux-ohos). Nothing under `$HOME` is probed (a stale homebrew Cellar install
must not satisfy a build silently); callers such as `scripts/make-device-test-kit.sh` resolve the
local Cellar layout and export `OpenHarmonySdkRoot` explicitly. A
missing library is a hard error; `OpenHarmonyLibCxxShared` pins an explicit file.

## Runtime native libraries

The published .NET runtime ships its shared libraries (`libhostfxr.so`, `libhostpolicy.so`,
`libcoreclr.so`, `libclrjit.so`, `libclrgc/gcexp.so`, `libmscordaccore/dbi.so`,
`libSystem.*.Native.so`, ...) in the publish payload, so they would travel inside
`resources/rawfile/dotnet.zip` and the ArkTS shell would extract them into the app data directory
before `start_app`. That extracted copy is NOT covered by the HAP code-signing block
(SoInfoSegment/fs-verity protects `libs/<abi>/**` and `*.an`), and an enforcing device
(XPM/fs-verity) rejects a `dlopen` from the data directory. The staging therefore copies every ELF
`*.so` of the publish directory into `libs/<abi>/` and excludes exactly those file names from
`dotnet.zip` (via `OpenHarmonyDeterministicZip` in the targets file), so each runtime ELF ships once, in the
directory the HAP signature covers - no unsigned duplicate is left in the extracted payload for
the runtime to pick instead (~14 MB saved per arm64 publish).

Resolution of the libs-only set (measured on the OHOS host, not assumed):

- `libhostfxr.so`: the host loads it from its own signed `libs/` directory (`dladdr`, see
  `src/OpenHarmonyHost/openharmony_host.c`), so the libs copy is the one used. For a
  self-contained app, hostfxr then expects `libhostpolicy.so` next to the app config
  (`hostpolicy_resolver.cpp`: muxer mode + self-contained -> `get_directory(app_candidate)`),
  i.e. in the extracted app dir, and dlopens it by path - hostpolicy therefore needs the bridge
  below.
- `libSystem.*.Native.so`, `libmscordaccore/dbi.so`: dlopen'd by name and resolved from the
  loader's app search path, which contains `libs/<abi>/` - with only these files absent from
  `app_dir` a self-contained payload still starts and loads them.
- `libcoreclr.so`: hostpolicy builds the path itself, `file_exists_in_dir(m_app_dir,
  LIBCORECLR_NAME)` (`deps_resolver.cpp`; OpenHarmony apps set `GenerateDependencyFile=false`,
  so this is the only route). Missing -> `Could not resolve CoreCLR path`.
- `libclrjit.so`/`libclrgc.so`: loaded by coreclr from the directory it was loaded from; missing
  there -> `Failed to load JIT compiler`.
- `createdump` (diagnostics only) is a separate ELF that needs `libmscordaccore/dbi` next to it;
  when it cannot find them the dump path degrades, the app is unaffected.

Consequence for a device run: the app dir must expose the four names that are resolved by
directory (`libhostpolicy.so`, `libcoreclr.so`, `libclrjit.so`, `libclrgc/gcexp.so`). The
payload-in-libs staging below satisfies that by construction (the app runs from `libs/<abi>/`
itself); for a hap without it, the host bridges `libs/<abi>/` into the extracted app directory
by symlinking the signed file under the same name before `start_app` (see the bridge block in
`src/OpenHarmonyHost/openharmony_host.c`).

The set is enumerated from the publish directory at target execution time; non-ELF `*.so` entries
are skipped (and stay in the zip), an empty ELF set is a hard error, and the staged libs go
through the same `OpenHarmonyCodesign` pass as the host and `libc++_shared.so`.

## Executable memory (W^X) and the startup probe

Motivation - three independent layers all disable the W^X allocator on this platform:

- The `runtime-ohos` fork defaults `EnableWriteXorExecute` to 0 under `TARGET_OPENHARMONY`
  (`src/coreclr/inc/clrconfigvalues.h`, commit `678ac21836c`): the sandbox refuses `PROT_EXEC`
  on the file-backed mappings the W^X allocator uses, while anonymous executable memory is what
  the JIT can allocate.
- The SDK (sdk-ohos) additionally bakes `System.Runtime.EnableWriteXorExecute=false` into every
  generated runtimeconfig and `DOTNET_EnableWriteXorExecute=0` into the CLI/child-process
  environment (`OpenHarmonyEnvironmentDefaults`), so `dotnet build`/`dotnet run` and their
  apphosts work without a wrapper.
- The host sets `DOTNET_EnableWriteXorExecute` itself, before hostfxr can initialize coreclr on
  either launch path (`ohos_host_run_app`, `ohos_host_start_app`). That is deliberately
  redundant: it also covers a hap built without the SDK's runtimeconfig mapping, and the
  process environment is inherited by every child the runtime spawns.

The host logs the decision on every launch path:

```text
[openharmony-host] start_app: xwe=0 source=default
```

A/B switch - `xwe.txt` in the app's writable sandbox directory (the context's `filesDir`;
when no context is published, `app_dir` or its writable parent, i.e. the `<filesDir>/dotnet`
payload layout): when its first byte is `1`, the host sets `DOTNET_EnableWriteXorExecute=1`
for that launch (`source=file`) and reproduces the platform W^X failure for an evidence round.
Any other content (or no file) keeps the default `0`.

Interpreter switch (R2-SHELL-EXT companion) - `interp.txt` in the same directory selects
`DOTNET_InterpMode` for the runtime that starts next (`3` = the pure interpreter of the
published `ohos-interpreter-pack.tar.gz`): the first byte must be a digit, the leading digit
run is the value, and no file leaves the variable as-is (the runtime's own JIT default). The
host logs the decision on every launch path:

```text
[openharmony-host] start_app: interp=3 source=file
```

so a device-side interpreter round only needs the file in the app sandbox - no host or launch
path change. The managed `dotnet-status.txt` line is not duplicated for this switch; the hilog
and stderr forms above are the evidence.

Probe - on the first launch path the host maps one page with each strategy the runtime could
use and emits one line (hilog tag `OHOS_DOTNET`, also appended to `<filesDir>/dotnet-status.txt`
in the managed `600`-character flattened style):

```text
OHOS_DOTNET probe: 1=OK 2=12 3=OK 4=38
```

Each token is `OK` or the `errno` of the failing call:

| # | strategy | what `OK` means |
|---|----------|-----------------|
| 1 | anonymous `mmap(RWX)` | the RWX allocator's mapping (`EnableWriteXorExecute=0`) is available |
| 2 | anonymous `mmap(RW)` -> `mprotect(RX)` | anonymous W^X works without file backing |
| 3 | `memfd_create` + `ftruncate` + `mmap(RW)` -> `mprotect(RX)` | in-memory file-backed W^X works |
| 4 | temp file `mmap(RX)` | plain file-backed executable mapping works (the strict W^X allocator's path) |

Failures never fail the launch; the tokens are collected by `scripts/tester-run.sh` into
`hilog/hilog-execmem.txt` (`OHOS_DOTNET probe:|xwe=`, counts in `summary.txt` as
`execmem_capture`/`execmem_lines`). Typical errnos: `1` EPERM (sandbox policy), `12` ENOMEM,
`13` EACCES (seccomp/SELinux), `38` ENOSYS (the syscall is not implemented on the image). The
probe runs once per process, so a bridged launch that adopts a later context cannot append a
second line.

## Payload in libs

The device's namespace policy allows a `dlopen` only from the app's signed bundle directory
(`/data/storage/el1/bundle/libs/arm64/` on the tester's device; the el2 data directories -
`haps/entry/libs`, `files`, `cache` - are refused). The namespace probe from the kit #22 device
round measured six candidate paths and found exactly one accepted `libcoreclr.so` load: the
bundle `libs/<abi>` directory, matching Huawei's faqs-ndk-development guidance. `hostpolicy`
and `coreclr` resolve `libhostpolicy.so`/`libcoreclr.so`/`libclrjit.so`/`libclrgc*.so` from
`app_dir` (see the previous section), so a payload extracted into the data directory cannot be
used there even though its files are readable.

The packaging therefore stages the whole publish payload into `libs/<abi>/` next to the host
and the runtime natives (`OpenHarmonyStagePayloadLibs` in the targets file): managed
assemblies, `.runtimeconfig.json`/`.deps.json`, satellite resource subdirectories (`de/`,
`zh-Hans/`, ...) and `wwwroot` assets, with the relative layout preserved. The staged files are
covered by the same HAP signing block as the runtime ELFs (SoInfoSegment/fs-verity protects
`libs/<abi>/**`), which is what makes the loader accept them from there. The runtime natives
staged above are skipped by name, so each runtime ELF is copied once; an ELF the payload
carries outside `*.so` (the diagnostics `createdump`) is re-signed by the same
`OpenHarmonyCodesign` pass. `dotnet.zip` keeps every payload entry as well, so a hap carries
both the in-place copy and the extraction fallback.

The target writes `libs/<abi>/.dotnet-payload.json`
(`OpenHarmonyWritePayloadMarker` in the targets file) as the payload identity:

- `assembly`: the entry assembly that must be staged next to the marker,
- `entries`: the number of files in `libs/<abi>/` (marker itself excluded),
- `payloadEntries`/`payloadBytes`: what the staging copied (equals the zip entry count),
- `zipEntries`/`zipSha256`: the identity of the packed `resources/rawfile/dotnet.zip`, so the
  fallback copy is provably the same publish as the staged payload.

Consumer behavior, all backwards compatible:

- The ArkTS shell probes `<bundleCodeDir>/libs/{arm64,arm,x86_64}` for the marker, the entry
  assembly and a marker naming that assembly. When they match, the app starts in place and the
  `dotnet.zip` copy/inflate is skipped (a payload an earlier kit extracted into `filesDir` is
  removed once); otherwise the shell unpacks exactly as before, P17 marker logic included.
- `ohos_host_run_app`/`ohos_host_start_app` resolve this library's own directory through
  `dladdr` and use it as `app_dir` when `<own_dir>/<entry assembly>` exists. The outcome is
  logged as `used_own=1 own=<dir> app=<dir>` (or `used_own=0`), and the symlink bridge stays
  the fallback for haps packed without the staged payload.
- `scripts/verify-kit.sh` asserts the marker per hap: present, the named assembly staged, the
  count equal to the real `libs/<abi>/` file count, `payloadEntries == zipEntries`, and the
  recorded zip sha256 equal to the packed zip bytes. A missing or inconsistent marker is a
  FAIL, because such a hap falls back to the refused data-directory extraction.
- `-p:OpenHarmonyHapPayloadInLibs=false` restores the previous layout (payload only inside
  `dotnet.zip`, no marker), for a rollback without a source change.

Cost: the payload travels stored (uncompressed) inside the HAP because the packing tool keeps
`libs/**` mmap-friendly; on the reference kit the signed hap grew from ~32.7 MB to ~75.3 MB
(253 payload files, ~38.7 MB) while every other hap entry stayed byte-identical.

## Payload determinism

`resources/rawfile/dotnet.zip` is written with a fixed entry order (ordinal path sort) and a fixed
1980-01-01 entry timestamp (`OpenHarmonyDeterministicZip`), so two publishes of identical inputs
produce a byte-identical zip. The OpenHarmony SDK re-signs every ELF under `$(TargetDir)` after
Build and rewrites it with a 4 KB `.codesign` section plus rebuilt section headers (ElfSigner), and
`publish/` is a subdirectory of `$(TargetDir)`: on a reused publish directory that pre-staging
signing pass appends another page to the stale copies on every publish and the drift ends up in
the zip. `_OpenHarmonyResetHapPublishOutputs` removes the publish directory just before
`PrepareForPublish` so the publish copy always repopulates it from the single-signed runtime pack
(and the freshly built managed files); the packaged payload then carries exactly one canonical
`.codesign` section per ELF, as produced by the runtime build.

## API band

`OpenHarmonyMinApiVersion`, `OpenHarmonyTargetApiVersion`, `OpenHarmonyApiReleaseType`,
`OpenHarmonyCompileSdkType` and `OpenHarmonyCompileSdkVersion` all stay overridable. Their
defaults follow the target framework; the numeric band encodes
`<major><minor:02><patch:02><api:03>` (the concatenation's leading zeros are stripped):

- `net11.0-openharmony20.0` -> platform 6.0.0 / API 20 -> min = target = 60000020 (Release); no
  compileSdk fields (BMS then keeps its OpenHarmony default).
- device band (every other TFM, e.g. `net11.0-openharmony26.0`) -> the profile the tester's 2in1
  device family accepted:
  - min 50002014 (platform 5.0.2 / API 14)
  - target 60101024 (platform 6.1.1 / API 24)
  - apiReleaseType Release
  - compileSdkType HarmonyOS, compileSdkVersion 6.0.2.130
  - debug: `OpenHarmonyHapDebug` (still defaults true and stays overridable; the tester's
    profile used false)

The compileSdk fields are emitted into `module.json` only when `OpenHarmonyCompileSdkType` is
non-empty; the API 20 band leaves them empty so its `module.json` stays exactly as before (and BMS
keeps `compileSdkType` OpenHarmony).

`minAPIVersion` is checked at install: it must be <= the device's `apiCompatibleVersion` or the
install fails with bm 9568297 `ERR_APPEXECFWK_INSTALL_SDK_INCOMPATIBLE`. The tester device family
reports `apiCompatibleVersion 50002014`, so the device band defaults to exactly that value; change
it per device with `-p:OpenHarmonyMinApiVersion=<value>`, but never raise it above the target
device's `apiCompatibleVersion`.

## Bundle name

`app.bundleName` accepts only letters, digits, `_` and `.`. A name with any other character (a
hyphen, say) is rejected at install with bm 9568344 "bundle name or module name is invalid". The
`OpenHarmonyBundleName` default strips hyphens from the assembly name,
`_OpenHarmonyValidateBundleName` fails the build early on any remaining illegal character, and an
explicit `-p:OpenHarmonyBundleName=<name>` is validated too.

## Feature permissions

`module.json` `requestPermissions` is generated from a feature matrix, so a feature the app turns
on always ships with the declaration, the request reason and the `usedScene` the platform
requires. Set `OpenHarmonyFeatures` to a `;` or `,` separated list of feature ids (or `all`);
each selected feature expands to the permission entries below. Unset/empty (the default) declares
nothing and leaves `module.json` byte-identical to a build without the property.

| Feature | Permission | Grant mode | Request point in the shell |
| --- | --- | --- | --- |
| `bluetooth` | `ohos.permission.ACCESS_BLUETOOTH` | user_grant | Bluetooth adapter/discovery/GATT sinks |
| `location` | `ohos.permission.APPROXIMATELY_LOCATION` | user_grant | reverse geocoding |
| `clipboard` | `ohos.permission.READ_PASTEBOARD` | user_grant | clipboard get/read (prompt on explicit get only) |
| `contacts` | `ohos.permission.READ_CONTACTS` | user_grant | contacts query sink |
| `calendar-read` | `ohos.permission.READ_CALENDAR` | user_grant | calendar list sink |
| `calendar` | `ohos.permission.READ_CALENDAR` + `ohos.permission.WRITE_CALENDAR` | user_grant | calendar list + add sinks |
| `print` | `ohos.permission.PRINT` | system_grant | print sink (`canIUse('SystemCapability.Print.PrintFramework')` gate) |
| `network` | `ohos.permission.INTERNET` | system_grant | scenario permission: declare it when the app loads network content or calls web services (the shell's network observer and the managed network stack need it) |

```sh
# contacts + calendar read/write + bluetooth (quotes keep MSBuild from splitting at ';')
-p:'OpenHarmonyFeatures="contacts;calendar;bluetooth"'
```

Each emitted entry carries `"reason": "$string:permission_reason_*"` (the reason strings ship in
`templates/resources/base/element/string.json`) and
`"usedScene": {"abilities":["EntryAbility"],"when":"inuse"}` (the ability comes from
`OpenHarmonyAbilityName`).

`OpenHarmonyExtraPermissions` remains as the raw escape hatch: a `;`/`,` separated list of
permission names appended with the historical minimal `{"name":"..."}` form (a name that is in
the feature table inherits its reason/usedScene; an unknown raw name logs a warning because a
user_grant permission declared without a reason can be ignored by the platform). Use it for
permissions the shell requests only through the managed `IPermissions.RequestAsync` sink, which
cannot be derived statically:

```sh
-p:'OpenHarmonyExtraPermissions="ohos.permission.CAMERA"'
```

### Request-point validation (packaging gate)

`_OpenHarmonyResolvePermissions` runs before the hap staging and cross-checks the declaration set
against the permissions the shipped shell can request at runtime (the quoted
`ohos.permission.*` literals in `templates/ets/**/*.ets`):

- a request point no feature declares is a **hard error** (the matrix drifted; add it to the
  feature table or to `OpenHarmonyPermissionsOptOut` with a documented reason);
- an unknown `OpenHarmonyFeatures` id is a hard error naming the known ids;
- a selected feature whose entry has no reason or an invalid `usedScene` is a hard error;
- a request point the app does not declare logs a **high-importance warning** naming the feature
  to enable (the feature answers "unavailable" while undeclared); set
  `OpenHarmonyRequireDeclaredRequestPoints=true` to make it an error.

`OpenHarmonyPermissionsOptOut` (a `;` list) marks request points the app deliberately does not
declare. The manifest describes the shipped shell; an app that passes a custom
`OpenHarmonyArktsModulesAbc` owns its own request points and can opt out of the gate.

Verification status (2026-09-25, no device attached to the build host):

- `scripts/selftest-hap-targets.sh` T5 drives the real pack targets: the bluetooth feature
  resolves to the asserted `module.json` bytes (name/reason/usedScene), `all` emits the eight
  unique permissions once each, an unknown feature id and the strict mode fail, and the raw
  `OpenHarmonyExtraPermissions` path keeps its minimal form plus the warning.
- The generated `module.json` and the `permission_reason_*` strings compile through the SDK
  `restool` (a `resources.index` is produced), so the resource side of the chain accepts the
  feature declarations.
- T6 is the device half: with `OHOS_TEST_HAP=<signed hap>` and an `hdc` device it installs the
  hap and reads the installed `requestPermissions` back through `bm dump`, asserting that every
  entry carries name/reason/usedScene. A full signed `dotnet publish` with these permissions on
  a device remains the device-test-kit path (`scripts/make-device-test-kit.sh`, whose
  `check_permissions` reads the packaged module.json).

Install-time and runtime notes: declaring a permission never grants a user_grant permission - the
managed app still requests it at runtime. `ohos.permission.APPROXIMATELY_LOCATION` is the
permission the reverse-geocoding path requests; whether a device also needs it for
forward-geocoding has not been verified on hardware (no test device) - the shell currently
pre-checks it for reverse geocoding only (SKILL/docs basis: `getAddressesFromLocation` is
`@permission ohos.permission.APPROXIMATELY_LOCATION` in `@ohos.geoLocationManager`; the forward
`getAddressesFromLocationName` carries no `@permission` tag).

## Blazor asset staging (milestone 3.0)

When the project directory contains a `wwwroot` content root, `_OpenHarmonyStageBlazorAssets`
copies it into the publish payload as `wwwroot/**`, so the hap's
`resources/rawfile/dotnet.zip` extracts to `<AppDir>/wwwroot` - the exact
`<base>/<root>/<path>` convention the ArkTS shell already serves for the hybrid origin
(`https://0.0.0.1/`): Blazor's origin `https://0.0.0.0/` is answered from
`<AppDir>/<root>/<request path>`. The framework script is staged alongside as
`wwwroot/_framework/blazor.webview.js` from `@(StaticWebAsset)`, the canonical source the
Razor/static-web-assets publish pipeline produces; a `wwwroot` without that asset is a hard error
naming the fix (the workload does not guess a NuGet-cache copy of a package version the SDK does
not own). A `@(MauiAsset)` list with `wwwroot/<TargetPath>` entries
(`ConvertStaticWebAssetsToMauiAssets`) is consumed too when a MAUI SDK produced it. This is the
OpenHarmony port's stand-in for the MauiAsset consumer, which does not exist in this tree.

NOTE (native model): the OpenHarmony host runs the managed app in-process on CoreCLR, so Blazor
Hybrid here is the native model (like Android/iOS), not the WebAssembly one - the WebView only
needs `blazor.webview.js` and the message transport, and no
`dotnet.js`/`dotnet.native.wasm`/`_*.dll` browser assets are staged. A project without `wwwroot`
is untouched, so its payload stays byte-identical.

## Toolchain resolution

`_OpenHarmonyDetectToolchain` resolves the packing tool from `OpenHarmonyToolchainDir` or
`OpenHarmonySdkRoot`/`OHOS_SDK_ROOT` + `toolchains/lib`; nothing under `$HOME` is probed. When the
toolchain (or `restool`, resolved from the same root) is missing, the build fails with the property
to set. Scripts that build haps for a local homebrew install (`scripts/make-device-test-kit.sh`)
resolve that layout themselves and export `OpenHarmonySdkRoot`, so the pack stays location-neutral.

### HarmonyOS SDK branch (ARKTS_SDK_FLAVOR=harmony)

The shell is compiled by `scripts/build-arkts-shell.sh` against the OpenHarmony SDK by default.
The HMS Kits (Share/Scan/Map/Push/Account) are not part of that SDK: a literal
`import('@kit.ShareKit')` is a hard ArkTS compile error there (`10505001 Cannot find module ...`,
KIT-IMPL probe a, 2026-09-25; `@kit.AdsKit` resolves, so the gate is per-kit). The script therefore
grew an opt-in HarmonyOS branch; the default flavor is unchanged.

```sh
# default (OpenHarmony SDK, runtimeOS OpenHarmony, compatibleSdkVersion 18)
scripts/build-arkts-shell.sh

# opt-in HarmonyOS branch: a DevEco-style SDK root whose default/ carries openharmony/ and hms/
ARKTS_SDK_FLAVOR=harmony \
ARKTS_HARMONY_SDK_ROOT=<sdk root> \          # or DEVECO_SDK_HOME
scripts/build-arkts-shell.sh
```

The branch changes exactly four things: the SDK root comes from `ARKTS_HARMONY_SDK_ROOT` /
`DEVECO_SDK_HOME` (must carry `<root>/default/openharmony/ets` and `<root>/default/hms/ets`, or the
build fails with the property to set), `runtimeOS` becomes `HarmonyOS`, `compatibleSdkVersion`
defaults to `6.1.0(23)` (override with `ARKTS_COMPATIBLE_SDK_VERSION`) - the value the device-side
DevEco build used to emit the accepted abc - and the UI variant additionally copies the Map
overlay module `templates/ets/map/MapOverlay.ets` into the project (R2-3 2026-09-26). `externalApiPaths`
additionally exposes `hms/ets`, which is what lets the Share/Scan/Map/Live View/CoreSpeech
probes and the Map overlay compile against the real kit types. The abc header gate is
unchanged: `ARKTS_MAX_BC_VERSION` stays `13.0.1.0` (the device runtime ceiling; the DevEco build at
`6.1.0(23)` produced exactly `13.0.1.0`), so a HarmonyOS SDK whose es2abc emits a newer abc still
fails here. On the default flavor the shell compiles the Share/Scan *probe* only: the specifier
stays in a variable and the resolved module is cast to a local structural interface, so a device
without the kit registers no sink and the managed side degrades (see the KIT-IMPL report in
`runtime-ohos/docs/plans/2026-09-24-ohos-kit-gap-analysis.md`). The Map overlay follows the same
rule: the default flavor never copies `MapOverlay.ets`, the page's dynamic `./map/MapOverlay`
import fails at runtime there, and the Map sink reports capability bit 1 = 0.

The branch is scaffold-verified (`--scaffold-only` plus the selftest T14/T17) and was
**build-verified on 2026-09-27** with the public DevEco command-line-tools bundle 6.0.1.251
(HarmonyOS 6.0.1 Release, API 21): `Finished :entry:default@CompileArkTS`, ui abc
`273,932 B / sha256 e7290ed11857472aa8f1b60ae984f7c13796a67cb1ec4be78cb873e5ef110b11`, abc
version `13.0.1.0`, 0 ArkTS errors, payload literals present - including the A2-TTS
`registerTtsSink`/`@kit.CoreSpeechKit`/`SystemCapability.AI.TextToSpeech` literals, so the
CoreSpeechKit probe/sink compiles against the real `hms/ets` declarations (the earlier
R2-3/Live View build reported `263,784 B / d3a7b718...`). There are two supported routes.

**Route A - real HarmonyOS SDK.** Obtain the toolchain bundle (hvigor + ohpm + node + the full
`hms` SDK; linux-x64, ~2.0 GiB, public mirrors, sha256-pinned) with
`scripts/setup-harmony-sdk.sh --download <dir>`, or point `ARKTS_HARMONY_SDK_ROOT` at DevEco
Studio's own `<install>/sdk`; then

```sh
ARKTS_SDK_FLAVOR=harmony ARKTS_HARMONY_SDK_ROOT=<sdk> scripts/build-arkts-shell.sh
```

`--print-config` prints the resolved SDK roots, runtimeOS, compatible/target strings, the exact
`externalApiPaths` (on harmony it ends in `<base>/hms/ets`) and the abc ceiling without node or
hvigor. Three version constraints decide success:

- **hvigor must match the SDK.** The mirror-pinned 6.26.4 (the default flavor's toolchain for
  the OpenHarmony SDK 26) is a DevEco-26 toolchain: against a 6.0/6.1 HarmonyOS SDK it stops
  with `00303313 ... DevEco Studio version: 26.0.0` and, once `compileSdkVersion` is removed,
  with `00303312 Cannot find the corresponding SDK version under the specified SDK path`. The
  bundle ships the matching hvigor (6.0.1.251 -> 6.21.1, 6.1.1.300 -> 6.24.4); point the script
  at it with the `HVIGOR_JS` override and set `ARKTS_MODEL_VERSION` to what that hvigor supports
  (6.0.1 for 6.21.1 - 6.0.2 fails with "The supported Hvigor modelVersion is 6.0.1").
- **compatibleSdkVersion must exist in that SDK.** The default `6.1.0(23)` is the device-side
  DevEco value; for the 6.0.1.251 bundle pass `ARKTS_COMPATIBLE_SDK_VERSION=6.0.1(21)` (the
  combined `platform(api)` form is required under runtimeOS HarmonyOS).
- **the abc ceiling is unchanged.** Target API 21 maps to `13.0.1.0` (`ts2abc.js
  --target-api-version 21`), the version the device DevEco build emitted; SDK 26's default is
  `24.0.0.0`, which the device rejects. A build whose es2abc emits a newer abc still fails at
  the end of the script.

Host notes: the bundle is linux-x64, so its native `es2abc`/`restool`/`ark_disasm` do not run
on an aarch64 host - the 2026-09-27 verification stood the arm64 binaries of a local
OpenHarmony SDK in for them (the declarations are architecture-neutral); an x64 Linux build
machine needs none of that. On an OpenHarmony device node also reports `os.type() ===
"HarmonyOS"` / `process.platform === "openharmony"`, so hvigor takes Darwin paths
(`libimage_transcoder_shared.dylib`, which cannot exist there); a wrapper that presents Linux
before loading hvigor fixes it. A complete SDK tree is required: one missing
`native/`/`previewer/`/`toolchains/` fails with `00303168 SDK component missing`.

**Route B - mock SDK (offline).** `scripts/setup-harmony-sdk.sh --mock <dir>` writes the
DevEco layout with stub kit declarations, including the command-line-tools metadata shape (no
`platformVersion` in `ets/oh-uni-package.json`; it lives in `default/sdk-pkg.json` - the script
falls back to it). Use it with `--print-config`, `--scaffold-only`, `--check-bc-version` and the
T14/T17 selftests to verify path resolution, `externalApiPaths` injection,
runtimeOS/compatible-version generation and the abc gate without a compiler. The mock is not a
compiler: its stubs declare no real kit API.

For the tester machine (DevEco Studio + HarmonyOS SDK) the shortest path is Route A with the
IDE's SDK and hvigor; the existing DevEco fallback still works (create an empty project, copy
`entry/src/main/ets/{entryability,pages,map}` over its sources, `hvigorw assembleHap`, feed the
abc back via `-p:OpenHarmonyArktsModulesAbc`). Expected evidence: the `CompileArkTS` finish
line, abc version `13.0.1.0`, non-zero size, the payload literals (`--check-abc`).

The branch's abc is also shipped as a **packaged HAP variant**: `harmony-haps.tar.gz`
(196,118,871 B / sha256 `f7a4faa2553d...`, published 2026-09-27 on the `device-test-kit` release
beside the kit) carries the same five-hap matrix as `scripts/make-device-test-kit.sh` (26.0/20.0 x
optional permission set + unsigned) rebuilt with
`-p:OpenHarmonyArktsModulesAbc=dist/ets/modules.harmony.abc`; only that property differs from the
kit build. Measured: all five haps carry the harmony abc (263,784 B / `d3a7b718...`, PANDA
`13.0.1.0`), the payload shape is untouched (`module.json` byte-equal to the kit #28 haps,
`libs/arm64-v8a` 269 = 14 `.so` + 254 payload + marker, in-hap host 269,216 B / `bb51826e...`,
`.codesign` on all 14 `.so`), the scratch assertion script is 82/82 and the kit's `verify-kit.sh
--expected-abc 263784` reports KIT OK. This is the only packaged shell with `MapOverlay.ets` /
LiveView sinks, so its real-device prerequisites are the AGC rows below (map service + signing
fingerprint; Live View TIMER entitlement + device switch); the default-flavor kit haps keep
`264,136 B / 9020ec5e...` and `IsOverlayAvailable=false`.

### Kit feature probes and AGC prerequisites (Push / Account / Map / Live View / CoreSpeech)

The second batch of HMS Kits (KIT-EXT2, 2026-09-25; Map overlay R2-3, 2026-09-26; Live View
R2-SHELL-EXT and CoreSpeechKit A2-TTS, 2026-09-27) rides the same split: each shell template
carries a *probe* that compiles on the OpenHarmony SDK, and only a runtime that actually
provides the kit registers the sink. A device without the kit (or the default OpenHarmony
build) keeps the managed side's documented degradation - no throw, no silent guess:

| Kit | Managed API | Shell sink / answer | Status map |
|-----|-------------|---------------------|------------|
| Push | `OpenHarmonyPush.GetTokenAsync` / `DeleteTokenAsync` / `IsSupported` | `pushService.getToken()` / `deleteToken()`; `host.notifyPushResult(id, op, rc, token)` | rc 0 = success (token for op 0), -1 = unavailable; positive rc is the Push Kit code, e.g. `1000900010` (AGC push service not enabled / signing profile mismatch), `1000900012` (entitlement not enabled), `1000900011` (no network), `1000900014` (device unsupported) |
| Account | `OpenHarmonyAccount.GetQuickLoginAnonymousPhoneAsync` / `AuthorizeAsync(scopes)` / `IsSupported` | `createAuthorizationWithHuaweiIDRequest()` + `AuthenticationController.executeRequest()`; `host.notifyAccountResult(id, op, rc, payload)` | rc 0 = success (op 0 payload = anonymous phone, op 1 payload = `response.data.authorizationCode`), -1 = unavailable/state mismatch; positive rc is the Account Kit code, e.g. `1001502014` (scope not applied for/approved), `1001500001` (signing fingerprint mismatch), `1001502001` (no Huawei ID signed in), `1001502012` (user cancelled), `1001500003` (scope unsupported) |
| Map | `OpenHarmonyMap.QueryCapabilitiesAsync` / `IsSupported` / `IsOverlayAvailable` / `ShowAsync` / `HideAsync` / `CloseAsync` / `SetRegionAsync` / `AddMarkerAsync` / `Ready`/`MarkerClick`/`CameraIdle` | `@kit.MapKit` + `SystemCapability.Map.Core` probe, then the `MapComponent` overlay driven through `host.registerMapSink` / `host.notifyMapResult(id, op, code, payload)`; bit 0 = kit resolved, bit 1 = overlay module resolved (the harmony build) | flags value (0/1/3), `null` when the sink is unregistered; ops 0 probe / 1 create / 2 destroy / 3 show / 4 hide / 5 set region / 6 add marker, code 0 applied, -1 unavailable, -2 overlay refused; events with id 0 (1 ready, 2 marker click, 3 camera idle) |
| Live View (R2-SHELL-EXT) | `OpenHarmonyLiveView.StartAsync(update)` / `UpdateAsync(update)` / `StopAsync(id)` / `IsSupported` | `canIUse('SystemCapability.LiveView.LiveViewService')` + `@kit.LiveViewKit`; `liveViewManager.isLiveViewEnabled()` then `startLiveView`/`updateLiveView`/`stopLiveView` on the TIMER scene (progress template; `title`/`text`/`progress`/`time` in ms); `host.notifyLiveViewResult(id, op, rc, payload)` | rc 0 = applied, -1 = unavailable or no view the shell owns, -2 = the kit call failed or the args were malformed, -3 = the user's live view switch is off; positive rc is the Live View Kit code (`1003500004` switch off, `1003500005` entitlement not approved, `1003500006` id exists, `1003500011` stale sequence, ...) |
| TextToSpeech (A2-TTS) | `OpenHarmonyTextToSpeech.SpeakAsync(text, options, ct)` / `GetLocalesAsync()` / `Stop()` / `IsSupported` | `canIUse('SystemCapability.AI.TextToSpeech')` + `@kit.CoreSpeechKit`; `textToSpeech.createEngine({language, person: 0, online: 1})` (offline mode, engine cached per language), then `engine.speak(text, {requestId})`; ops 0 create / 1 speak / 2 stop / 3 locales (`listVoices`) / 4 isBusy via `host.registerTtsSink` / `host.notifyTtsResult(id, op, rc, payload)` | rc 0 = applied (speak: the engine reported completion or stop; locales: JSON voice list; isBusy: `"0"`/`"1"`), -1 = unavailable, -2 = the kit call failed, the engine is missing or the args were malformed; positive rc is the CoreSpeechKit code (`1002300001` text empty/out of range, `1002300002` language not supported, `1002300003` person not supported, `1002300005` engine creation failed, `401` arguments) |

Host exports (all in the `host-exports.txt` contract, 137 names): `ohos_host_push_{available,request,register_result,result}`,
`ohos_host_account_{available,request,register_result,result}`, `ohos_host_map_{available,command,register_result,result}`
(the R2-3 overlay folded the reserved probe into `ohos_host_map_command(id, op, args)`; the export
count was unchanged there because the overlay reuses the same four Map exports and one answer
callback), `ohos_host_liveview_{available,request,register_result,result}` (R2-SHELL-EXT), and
`ohos_host_tts_{available,request,register_result,result}` (A2-TTS; the old single-op
`ohos_host_tts_speak` export was replaced by the generic request shape, 134 -> 136 names), and the
standalone `ohos_host_keystore_available` probe (P2a-HUKS; 136 -> 137 names).
Push and Account are asynchronous (the AGC call and the system authorization UI); the Map overlay
commands are asynchronous in the same way (the shell answers when the op was dispatched). Live
View is asynchronous too (the kit call may cross to the live view service): the shell checks
`isLiveViewEnabled()` first, then answers through the same style of callback.

Map's map view is the ArkUI `MapComponent`, not a plain module API: a literal
`import('@kit.MapKit')` is a hard ArkTS compile error on the OpenHarmony SDK and the component
needs a compile-time declaration. Both documented options are now landed: (b) managed capability
discovery - `QueryCapabilitiesAsync`/`IsSupported` over the runtime probe - and (a) the
shell-side `MapComponent` overlay. The overlay lives in the harmony-flavor-only template module
`packs/Microsoft.OpenHarmony.Sdk/<ver>/templates/ets/map/MapOverlay.ets` (literal `@kit.MapKit`
import, `MapComponent` builder mounted through a `NodeController`/`BuilderNode` in the page
`Stack`); `pages/Index.ets` imports it dynamically through the variable specifier
`'./map/MapOverlay'`, casts the resolved module to local structural interfaces, and mounts a
`NodeContainer` only while the managed side created the overlay. The managed side drives it
through `OpenHarmonyMap` (create/show/hide/destroy/region/marker plus the ready/marker-click/
camera-idle events) and every call first checks the availability bits.

Live View keeps the TIMER scene's minimal surface (create/update/stop): the shell builds one
progress-template view per id (`title`/`text`/`progress` 0-100 plus the `timer.time` value in ms),
keeps it between calls so updates increment the sequence and stop targets the same id, and maps
every outcome onto the shared code map. The kit is a plain module API (unlike the MapComponent
overlay), so no harmony-flavor-only module is needed: the probe and sink compile in the default
OpenHarmony shell build and stay unregistered there. A device without the AGC entitlement throws
`1003500005`, and a device with the switch off answers `-3`/`1003500004`; both are passed through
to the managed status.

TextToSpeech keeps the CoreSpeechKit engine op surface (create/speak/stop/locales/isBusy): the
shell creates one engine per language on the first speak (`person` 0, offline mode 1; an empty
locale selects the documented `zh-CN` default), keeps it so stop, the voice list and isBusy share
it, and answers a speak only when the engine reports completion/stop/error - so `SpeakAsync`
completes with the utterance instead of with the dispatch. `Stop()` also resolves every pending
speak (a cancellation or timeout sends the same op), and `GetLocalesAsync()` maps the
`listVoices` payload to MAUI `Locale` values, keeping the device-locale fallback when the sink is
absent. **Decision points for the device handoff: (a) speak - one utterance per
language/voice completes and the locale list enumerates the voices the engine reports
(`zh-CN`/`en-US`, ...); (b) stop - the engine goes silent and a pending `SpeakAsync` completes
without hitting the bridge timeout; (c) locales - `GetLocalesAsync` reports the engine voices
rather than the single fallback locale, and an unsupported language answers `1002300002`
instead of guessing.** The kit needs no AGC entitlement and no `module.json5` permission - the
device's speech capability (and its offline voice data) is the gate, and the default OpenHarmony
build keeps the no-kit degradation documented above.

### SecureStorage (P2a-HUKS, 2026-09-27)

`OpenHarmonySecureStorage` prefers HUKS (Universal KeyStore) and keeps the documented file-key
fallback only when the keystore path fails; `IsHardwareBacked` reports the probe honestly. Unlike
the HMS kit batches above, the keystore engine runs in the host
(`src/OpenHarmonyHost/host_keystore.c`), so the headless shell is covered too, and the ArkTS
`registerKeystoreSink` (`Index.ets`, answers rc=-1 until the kit is wired) stays the fallback
layer for a device whose image lacks the NDK library:

| Layer | Contract |
|-------|----------|
| Managed | `SetAsync` -> `ohos_host_keystore_request(id, "generate"/"encrypt", alias, base64)`; `GetAsync` -> `"decrypt"`; `RemoveAll` -> `"delete"`; a sealed value lands as `k1:<base64(nonce(12) \|\| ciphertext \|\| tag(16))>`; the alias is namespaced `maui.ohos.securestorage.v1.<FNV-1a(path)>` |
| Host | `OhosHostKeystoreAvailable` (libhuks_ndk.z.so through the optional-library dlopen shim) answers in-process with AES-256-GCM: `generateKeyItem` (AES-256, GCM, NoPadding, ENCRYPT+DECRYPT), `initSession`+`finishSession` with `HUKS_TAG_NONCE` / `HUKS_TAG_AE_TAG`, `deleteKeyItem`; `ohos_host_keystore_available()` exposes the probe for the managed status. Only a host without the library forwards the request to the ArkTS sink. |
| Fallback | no HUKS (or a failed op): the per-install file key obfuscates the values (`secure.dat.key` next to the data file) and the one-time status note says so - not hardware-backed, never silent. |

No AGC entitlement and no `module.json5` permission: HUKS is an OpenHarmony core service
(`SystemCapability.Security.Huks.Core`; `@kit.UniversalKeystoreKit` / `@ohos.security.huks` ship
in both the OpenHarmony SDK and the HarmonyOS SDK) and keys are app-scoped. **Device decision
points: (a) restart read-back - the key is HUKS-resident, so a value written by one process
decrypts in a later one; (b) cross-device undecryptable - the key never leaves the keystore and
is alias-scoped, so the same ciphertext fails under another key/device; (c) delete clears key -
`RemoveAll` drops the keystore key, after which the old ciphertext is unrecoverable.** All three
were verified on the dev device (signed aarch64 probe over the host sources: seal in one process,
decrypt in the next; the same blob rejected under a second alias; rejected again after
`delete`). Off-device the interaction suite asserts the fallback: `IsHardwareBacked=false`, the
read/write/remove semantics are unchanged and a malformed `k1:` payload reads as absent.

Decision point: **the overlay needs the `ARKTS_SDK_FLAVOR=harmony` shell build plus the AGC map
service enablement** (checklist row 5; the Android AppKey flow does not apply to the HarmonyOS
`MapComponent`) - the default OpenHarmony SDK build cannot compile the component declaration, and
without the service/bundle/fingerprint match the map view fails to initialize (logged by
`MapOverlay.ets`, no event fires).
So a device/HAP built with the default flavor answers `IsOverlayAvailable=false` even when
`IsSupported=true` (the kit itself resolved): the capability answer distinguishes the two.

AGC / device checklist (all external to this repository; the KIT-GAP report
`runtime-ohos/docs/plans/2026-09-24-ohos-kit-gap-analysis.md` tracks them; values verified
against the official preparation guides and the KIT-* reports, 2026-09-27). Every HMS kit needs
the common rows 1-3 plus its own row:

| # | Item | AGC location | Enable / fill | Signing / profile | Review |
|---|------|--------------|---------------|-------------------|--------|
| 1 | App registration (all kits) | 我的项目 > project > 添加应用, platform HarmonyOS | `bundleName` exactly the build's (`ARKTS_SHELL_BUNDLE_NAME` / the HAP's `OpenHarmonyBundleName`), matching device types | - | none |
| 2 | Signing fingerprint (all kits) | 项目设置 > 常规 > 应用 > SHA256证书/公钥指纹 > 添加公钥指纹（HarmonyOS API 9及以上） | SHA256 of the signing certificate (`.p12`, debug or release); a DevEco debug auto-cert only works when its fingerprint is added | must match the hap's signing material | none |
| 3 | Debug/release Profile (all restricted kits) | 证书、App ID和Profile > Profile | after enabling a service/entitlement, re-apply the Profile (受限权限) and re-sign the hap | the profile carries the capabilities | none |
| 4 | Push (Push Kit) | 我的项目 > 项目 > 增长 > 推送服务 (older UI: 项目设置 > API管理) | enable Push Kit | re-apply the Profile with the push entitlement; no `module.json5` permission is needed for `getToken()` | instant |
| 5 | Map (Map Kit) | 我的项目 > 项目 > 开放能力管理 (older UI: API管理) > 地图服务 | enable 地图服务; HarmonyOS `MapComponent` authenticates through the AGC service + certificate fingerprint (older SDKs additionally use the `client_id` metadata / `agconnect-services.json`; from HarmonyOS 5.0.2(14) the public-key fingerprint + Client ID are documented as no longer required). Note: the Android Map Kit API-key/AppKey flow does **not** apply to the HarmonyOS `MapComponent` | fingerprint must match; debug builds must be manually signed and the Profile re-applied after enabling the service | none (toggle) |
| 6 | Account one-tap login (Account Kit) | AGC unified entitlement entry (我的项目 > project > app > 华为账号服务 / API管理) | apply for the one-tap scope `quickLoginAnonymousPhone` (entitlement name quickLoginMobilePhone); the shell requests it (with `permissions=['serviceauthcode']`) and degrades when it is not approved | fingerprint match; approval can take up to ~24 h to take effect | eligible apps are approved instantly (old flow: days) |
| 7 | Account Client ID | 项目设置 > 常规 > 应用 > Client ID | the shell's request does not reference one today; if the SDK in use asks for it, add `module.json5` metadata `client_id` (the current shell template does not carry it) | - | none |
| 8 | Account server exchange | AGC 项目设置 > 常规 > 应用 > Client Secret | the app's server exchanges the `authorizationCode` for the real phone (`quickLoginAnonymousPhone` is only the anonymous number shown in the UI) | - | none |
| 9 | Live View (实况窗权益) | 我的项目 > 项目 > 增长 > 推送服务 > 实况窗 | apply for the entitlement for the `TIMER` scene (tool apps; scene whitelist); Push service enabled first | entitlement carried by the Profile | manual review (~5 working days; formal approval expects an on-shelf app) |
| 10 | Live View device switch | (device) 设置 > 应用和元服务 > 应用名 > 实况窗 / 通知和状态栏 | the user's live view switch must be on; local create/update needs the app in the foreground | - | none |
| 11 | Share (Share Kit) | - | none: the system share panel (`systemShare`) has no AGC service and no `module.json5` permission | - | none |
| 12 | Scan (Scan Kit, default UI) | - | none: `scanBarcode.startScanForResult` (the shell's path) needs no camera permission; a custom scan UI would add `ohos.permission.CAMERA` | - | none |
| 13 | TTS (CoreSpeechKit) | - | none: no AGC entitlement and no `module.json5` permission for the kit itself (implemented A2-TTS 2026-09-27; see the probe table above); the device-side speech capability and its offline voice data are the gate | - | none |

The per-kit error-code map stays in the table above. A `1000900010`/`1000900012` after enabling
usually means the Profile was not re-applied or the signing fingerprint does not match;
`1001502014` and `1003500005` mean the scope/entitlement is not approved yet. When the Map
overlay is built but the service/fingerprint is wrong, the shell still reports
`IsOverlayAvailable=true` (the module compiled) while no `Ready` event fires and `MapOverlay.ets`
logs the initialization failure.

Verification without an HMS device: `test/maui-platform-verify` pins the shell probe/sink shape,
the overlay module and its flavor gate, the host/managed contract, the off-device degradation
(`[verify] kit4/kit5/kit6/kit7` for the second batch + overlay, `kit8/kit9/kit10` for Live View,
`kit11/kit12/kit13` for CoreSpeech text-to-speech, `kit14` for the HUKS-first SecureStorage) and
the interpreter switch
(`pg2 host interp policy`: the `interp.txt` parser, the guarded `DOTNET_InterpMode` setenv and
the log pair),
while `scripts/build-arkts-shell.sh` keeps the abc at
`13.0.1.0`, carries the `./map/MapOverlay`, `registerLiveViewSink`, `notifyLiveViewResult`,
`@kit.LiveViewKit`, `SystemCapability.LiveView.LiveViewService`, `registerTtsSink`,
`notifyTtsResult`, `@kit.CoreSpeechKit`, `SystemCapability.AI.TextToSpeech`,
`notifyTextComposition`, `notifyAnimationReduce`, `@kit.AccessibilityKit` and
`SystemCapability.BarrierFree.Accessibility.Core` literals
in the UI abc (the provenance gate; current default-flavor UI abc 278,760 B /
`c84fbf34...`, headless 18,532 B) and enforces
the source contract (no `@ohos.*` imports, variable kit specifiers). The host-side gate is
`scripts/build-host.sh` (nm -D: all 141 `host-exports.txt` names present as plain symbols) plus
`scripts/check-host-exports.py --cross-check`; the interaction suite's own contract line is
`[suite] checks=377 total=377 floor=357 assert=True` (the 16 P1b-LIST list checks and the
4 P2b-IMG image checks on the 357/337 P1a-ANIM base).

### Templates / abc sync strategy

`OpenHarmonyArktsModulesAbc` defaults to the checked-in prebuilt shells: `templates/ets/modules.ui.abc`
for UI builds (`OpenHarmonyUIPage` set) and `templates/ets/modules.abc` (headless) otherwise; an
explicit `-p:OpenHarmonyArktsModulesAbc=<file>` overrides both. The former
`modules.shell.abc` duplicate is gone (it was always byte-identical to `modules.ui.abc`).

- **Source change (default flavor)**: rebuild both variants, install, then verify:

  ```sh
  scripts/build-arkts-shell.sh                        # UI    -> dist/ets/modules.abc
  ARKTS_SHELL_VARIANT=headless scripts/build-arkts-shell.sh   # -> dist/ets/modules.headless.abc
  scripts/build-arkts-shell.sh --install-packs        # all three packs + provenance, then the gate
  scripts/build-arkts-shell.sh --check-pack-abc       # re-run the gate alone
  ```

  `--install-packs` copies UI -> `templates/ets/modules.ui.abc` and headless ->
  `templates/ets/modules.abc` in preview.22/23/24 in lockstep and refreshes the
  `templates/ets/abc-provenance.json` record (schema 1: per-variant size, sha256, abc version and
  the source hashes; plus the pinned compiler identity).
- **Gates** (`--check-sources` / `--check-pack-abc`, both wired into the build):
  - source contract: no `@ohos` module/dynamic import, no global `getContext()`, no
    `decodeWithStream()`, no global `focusControl` in `templates/ets/**/*.ets`, and the three
    packs' sources must be byte-identical (the fixture harness pins them too);
  - abc provenance: per variant the recorded size/sha256/abc version, the payload literals
    (`dotnet-payload`/`bundleCodeDir`/`payload-in-libs`/`dotnet.marker`) and the UI literals
    (`ohos_dotnet_surface`/`ohos_dotnet_input`/`__hwvInvokeDotNet`/`./map/MapOverlay`/
    `registerLiveViewSink`/`notifyLiveViewResult`/`@kit.LiveViewKit`/
    `SystemCapability.LiveView.LiveViewService`/`registerTtsSink`/`notifyTtsResult`/
    `@kit.CoreSpeechKit`/`SystemCapability.AI.TextToSpeech`, which the
    headless variant must not carry), the recorded source hashes (a source edit without a rebuild
    fails), the absence of `modules.shell.abc`, byte-identity across the three packs, and - when a
    dist dir is given - the freshly built artifacts against the installed packs.
    `scripts/build-arkts-shell.sh` runs the pack gate automatically after a build once both
    variants exist in `dist/ets`. The `./map/MapOverlay` literal is the page's dynamic overlay
    import: it must survive in the UI abc (R2-3), while the overlay module itself is never part of
    the default-flavor abc (only the harmony branch compiles it). The Live View literals ride the
    same gate (R2-SHELL-EXT): the sink names and the kit specifier must be in the UI abc even
    though the default-flavor runtime never resolves the kit.
- **HarmonyOS flavor**: the compiled abc is flavor-specific (the HarmonyOS es2abc/toolchain), so do
  not overwrite the checked-in OpenHarmony abc with it - the default packs must stay buildable
  without the HarmonyOS SDK. Build the flavor and pass the result to the packaging invocation, or
  ship it as a separate pack revision; keep the checked-in `modules*.abc` on the default flavor.
  The provenance record pins the default flavor and the script refuses to write it from a harmony
  build.
- **Current state (P1a-ANIM, 2026-09-27)**: all three preview packs carry the same sources
  (Share/Scan/Push/Account/Map/Live View/CoreSpeech probes, HUKS-first SecureStorage,
  kit-import migration, feature permission chain, IME composition, the animation-reduce
  observation) and the abc rebuilt from them
  on the OpenHarmony SDK: UI 278,760 B / sha256
  `c84fbf3462def13c17899b69c45674500f5e117a8f39ba460305775e9d1beb35`, headless 18,532 B / sha256
  `d7ec9ca7ee6169a883af490a006005fe73fa7d03c40e178db9f2594c83b8d785`, both abc version 13.0.1.0
  with `compatibleSdkVersion 18`. The harmony-flavor build of the same sources against the
  CoreSpeechKit-capable DevEco SDK is 273,932 B / `e7290ed1…` (see the SDK-branch section; its
  page predates the animation-reduce probe and is rebuilt from the same sources when the flavor
  build next runs).

### Animations/transitions (P1a-ANIM)

The self-drawn route has no per-view ArkUI animation: page transitions, control-state easing and
the minimal shared-element morph run on the managed frame loop (`OpenHarmonyAnimationLoop`,
fed by the XComponent frame callback and by MAUI's ticker). The shell's only role is the system
"reduce animations" setting:

- `pages/Index.ets` resolves `@kit.AccessibilityKit` lazily (variable specifier, typeof-guarded
  - an API 23 surface, so a device whose framework predates it keeps the managed default), reads
  `isAnimationReduceEnabledSync()` once and follows `onAnimationReduceStateChange`, forwarding
  every value as `host.notifyAnimationReduce(0/1)`; the listener unregisters with the page
  through the disposer ledger.
- `src/OpenHarmonyHost/host_napi.cpp` exports `notifyAnimationReduce` and the managed listener
  entry `ohos_host_animation_reduce_set` (export contract: 139 -> 141 names), remembering the
  last value and replaying it to a late listener so the startup order cannot lose it.
- Managed side (`maui-ohos`): `OpenHarmonyMotion.ReduceMotion` gates the page/shared enter
  passes (instant commit) and the control-state channels (snap), and makes
  `OpenHarmonyTicker.SystemEnabled` false, so MAUI's `AnimationManager` stops accepting new
  animations and force-finishes the running ones on the next fire.
- While MAUI animations run, the ticker also keeps a frame-loop registration alive that only
  requests repaints (`OpenHarmonyBridge.RequestRedraw`), because the compositor paints a dirty
  surface only: sampling stays on the ticker's timer, repainting becomes frame-aligned.
- The `--check-pack-abc` literal gate pins `notifyAnimationReduce`, `@kit.AccessibilityKit` and
  `SystemCapability.BarrierFree.Accessibility.Core` in the UI abc (headless must not carry
  them), so a shell rebuilt without the probe fails before packaging.

### Lists (P1b-LIST)

List virtualization stays fully managed (the shared materializer drives the same frame loop as the
rest of the compositor), so P1b-LIST changes no shell or host source: the UI abc stays
278,760 B / `c84fbf34…` and the export contract stays at 141 names. The four decision points:

- **Incremental loading**: `RemainingItemsThreshold`/`RemainingItemsThresholdReached` fires once
  when the visible window enters the threshold zone, and re-arms only after the window leaves the
  zone or the item count changes; a reentrancy guard additionally keeps a handler that grows the
  source from firing per frame.
- **ItemsUpdatingScrollMode**: KeepItemsInView and KeepLastItemInView anchor the first/last
  visible item *by identity* (an index would silently point at a different item when the update
  inserts rows before the viewport) and preserve its screen position, respectively its bottom
  alignment, across the source swap; KeepScrollOffset keeps the raw offset, now clamped to the
  shrunk content end. The window is re-materialized on a source swap and re-arranged when the
  slot projection moves (collapse/span), so stale frames/contexts cannot survive an update.
- **ScrollTo**: `(index, group, position, animate)` honors Start/Center/End/MakeVisible, and
  `animate: true` tweens the offset through the shared frame loop (160-420 ms, ease-out cubic);
  reduced motion snaps to the target. The materializer's window follows every animation step, so
  the virtualized rows track the animated offset.
- **Grouping**: a grouped source can draw a footer row per group (`GroupFooterTemplate`), and
  `OpenHarmonyCollectionViewExtensions.SetGroupCollapsed`/`ToggleGroupCollapsed` hide a group's
  items and footer from the viewport without touching ItemsSource - the rows stay, only the slot
  projection and the offset change (collapsing above the viewport pulls the offset up so the
  content below does not jump). `SetGroupHeaderTogglesCollapse(true)` makes the header row toggle
  its group. The public surface is declared in the net-openharmony API baseline.
- **Physics**: a drag past an edge rubber-bands (bounded to 64 px), a release springs back, and a
  fling that reaches an edge carries its remaining speed into a bounded overshoot before the
  spring settles on the edge; reduced motion clamps instead. The scrollbar's hold/fade parameters
  are settable, reduced motion hides the bar on the hold-expiry frame, and a completed fade now
  re-arms the next one (previously the bar could fade only once per process). The 1,200-item
  check pins the bounded materialization window (13-22 rows) and a ≤1 KiB/step steady-state
  allocation on the scroll frame path.

### Image decoding (P2b-IMG, 2026-09-27)

The draw path no longer decodes an encoded image at full resolution: the managed view asks for a
destination-sized decode and the host passes the request to the platform decoder, so a large
source is never materialised whole. Four decision points (the managed contract and the test seams
are documented in the slice's `docs/openharmony-slice-notes.md`):

- **low-res first**: a destination with a long edge of at least 128 px decodes a coarse preview
  (destination / 8) in the first frame (`OpenHarmonyView.DrawImage` ->
  `OpenHarmonyCanvas.DrawImageBytesSized`) and then requests a redraw;
- **high-res replace**: the next frame decodes at the display size and replaces the preview; the
  host pixelmap cache keys on content hash + length + requested decode size, so the preview and
  display entries coexist in the same LRU (8 entries / 32 MiB decoded-byte budget) and a window
  resize misses once while the stale entry ages out;
- **large images stay bounded**: `ohos_host_draw_image_bytes_sized` clamps each requested edge to
  `OHOS_IMAGE_DECODE_MAX_EDGE` (4096) and asks the decoder for
  `OH_DecodingOptions_SetDesiredSize` (API 12+). The entry points go through the optional-library
  shim and fall back to the full-resolution decode when the image library predates them, so no
  draw path throws;
- **failure placeholder**: a failed decode draws a neutral placeholder for that generation (once,
  no per-frame retry) and a failed display-size decode keeps the visible preview; an older host
  without the sized export keeps the pre-P2b `DrawImageBytes` path.

Local bench (HarmonyOS device, signed aarch64 bench over the same OH_ImageSource entry points;
`LD_LIBRARY_PATH=/system/lib64/ndk:/system/lib64 ./bench_decode decode photo.jpg full 5` and
`... decode photo.jpg 1032 200 5`): a 3.27 MB JPEG (3400x2550) decodes in 86.3 ms at full size vs
63.4 ms at 1032x200, retaining 34.7 MB vs 0.8 MB of decoded bitmap; the 4.77 MB 4000x3000 source
with a 1080x810 target is 117.3 ms vs 88.2 ms and 48.0 MB vs 3.5 MB. Process peak RSS is flat
(~75 MB, the decoder runtime) because the pixelmap allocation is not charged to VmRSS; the
retained decoded bitmap is the meaningful memory delta.

Gates: the interaction suite's four image checks pin the managed preview/final path, the
small-frame single pass, the placeholder rule and the host contract (`[verify] image progressive
decode`, `image small-frame single pass`, `image decode failure`, `image decode host contract`);
`host-deps.conf` learns `OH_DecodingOptions_` for the soft resolution and the nm export gate
covers `ohos_host_draw_image_bytes_sized` in the 141-name contract;
`scripts/check-host-exports.py --cross-check` verifies the managed `LibraryImport` against it.

### Text editing (P0c-TEXT-EDIT)

The slice draws text itself (Skia through the compositor), so Entry/Editor editing is a managed
feature with the ArkTS shell providing the input-method plumbing. The four decision points:

- **Cursor**: a focused entry draws the caret at `CursorPosition` (or the text end when unset)
  using the same cached per-character prefix sums as caret hit testing, so the drawn caret and
  `CursorIndexFromX` cannot disagree. The caret blinks on the platform cadence (500 ms
  visible/hidden) anchored at the last caret-affecting change; a focused entry registers for
  continuous frames (`OpenHarmonyView.NeedsAnimation`), an unfocused one draws no caret and does
  not animate. Entries inside a scrolled view draw correctly because the compositor translates
  the content canvas; a selection drag converts the screen X to content space with the delta
  captured at press.
- **Selection**: the highlight spans `[CursorPosition - SelectionLength, CursorPosition]` (MAUI
  semantics: the caret sits at the selection end) and uses the measured prefix widths, not a
  proportional estimate.
- **Handles**: the two round handles (9 px radius, 24 px touch slop) sit below the text line at
  the measured selection ends. Grabbing one drags only that endpoint (the other stays the drag
  anchor) and writes `CursorPosition`/`SelectionLength` back to the virtual `InputView`, so app
  code sees the same values; a text gesture cancels in-flight inertia and suppresses the release
  fling (`OpenHarmonyScrollPhysics.SuppressReleaseFling`), so adjusting a selection never flings
  the enclosing scroll view.
- **IME composition**: the shell's hidden input forwards the input method's preview text
  (`onChange`'s optional `PreviewText` second argument -> `host.notifyTextComposition(value,
  offset)`) while keeping the committed text on the existing `notifyTextInput` path. The managed
  side draws the preedit at the offset (highlight + underline) with the caret after it and clears
  it on commit (empty preview), advancing the caret to `offset + preedit length` on both the
  platform and the virtual view. The managed caret is pushed back to the shell input
  (`ohos_host_keyboard_set_caret`, delivered as the second argument of the text-input sink post)
  so a composition that starts after a tap/selection uses the same offset. An older host library
  without the composition export keeps working: the shell's `hostCall` guard skips the
  notification and the editor simply shows no preedit.

  Gates: `scripts/build-arkts-shell.sh --check-sources/--check-pack-abc` keep the
  `notifyTextComposition` literal in the UI abc and out of the headless one;
  `scripts/check-host-exports.py --cross-check` and the `build-host.sh` nm gate cover
  `ohos_host_register_text_composition` + `ohos_host_keyboard_set_caret`; the interaction suite
  pins the behavior (`text cursor api` / `text caret blink` / `selection handles` / `selection
  drag inertia` / `text composition`) and the shell/host contract (`text composition shell` /
  `text composition host`). Device-side IME behavior (the preview-text cadence of the system
  input method and composition inside the hidden input) still needs on-device confirmation.

### ArkTS shell conformance (COMP-ARKTS)

The shell sources follow the audit's API conformance set, enforced by `--check-sources` and the
per-variant literal gate:

- **Kit imports only**: every `@ohos.*` import (static and dynamic) is migrated to `@kit.*`
  (`@kit.AbilityKit`, `@kit.ArkUI`, `@kit.ArkTS`, `@kit.ArkWeb`, `@kit.BasicServicesKit`,
  `@kit.CameraKit`, `@kit.ConnectivityKit`, `@kit.CoreFileKit`, `@kit.ImageKit`,
  `@kit.LocalizationKit`, `@kit.LocationKit`, `@kit.MediaLibraryKit`, `@kit.NetworkKit`,
  `@kit.NotificationKit`).
- **`import type` policy**: the optional-kit type imports stay `import type` (and only those).
  Rationale: the ArkTS compiler erases them (no module record in the abc - verified against the
  built artifact), so a device whose framework lacks a kit still loads the page, which is the
  documented device-compat strategy; value imports are only used for kits the page needs to run at
  all (core + statically safe kits).
- **Page context**: `this.getUIContext().getHostContext()` through one private `hostContext()`
  helper replaces all 21 call sites of the global `getContext()`; the build gate rejects the
  global form.
- **Decode**: `util.TextDecoder.create('utf-8').decodeToString(bytes)` through the shared
  `decodeUtf8()` helper replaces `decodeWithStream()` in both ability templates.
- **Pickers**: `picker.DocumentViewPicker(context)` is constructed with the host context;
  `photoAccessHelper.PhotoViewPicker` has no context constructor in this SDK (verified: "Expected
  0 arguments, but got 1"), so it keeps its no-arg form.
- **Syscap/permission entry probes**: print checks
  `canIUse('SystemCapability.Print.PrintFramework')` before importing the kit; geocoding checks
  `isGeocoderAvailable()` and pre-checks `APPROXIMATELY_LOCATION` for the reverse lookup, mapping
  the kit error codes (3301000/801 -> rc -1 unavailable, 3301300/3301400 -> rc -2 query failure;
  the managed side maps every non-zero rc to "no result").
- **Focus**: `this.getUIContext().getFocusController().requestFocus(id)` replaces the global
  `focusControl`.
- **Callback ledger**: display/`commonEvent`/network/bluetooth listeners register a disposer in the
  page's ledger and `aboutToDisappear` runs them; the SDK 26 `NetConnection` has no `off()`, so the
  network observer uses `unregister(callback)` plus a `networkDisposed` guard that makes a late
  callback a no-op (device confirmation pending - see the report note).
- **Overlay avoid-area**: the shell panel, menu handle and A11Y button are inset by the system
  avoid area and the soft-keyboard height; the managed/self-drawn content keeps its existing
  `notifyAvoidArea`/`notifySoftInputArea` -> managed SafeArea padding path.
- **Logging/catch hygiene**: `console.*` is replaced by `hilog` under one domain/tag; catches with
  no use for their binding use the optional binding form.
- **No regex literals in the page**: the static-web-asset fingerprint strip uses
  `new RegExp(...)`; `build()` has no ternary expressions (named helper methods).

## Clean contract

Every target registers the files it creates in `FileWrites` in the same target: the hap staging
tree (`_OpenHarmonyStageHap`), restool's output (`_OpenHarmonyGenerateResourceIndex`), the unsigned
hap (`_OpenHarmonyPackHap`) and the signed hap (`_OpenHarmonySignHap`). `dotnet clean` therefore
removes the packaging residue instead of leaving `obj/.../openharmony-hap/` and the haps in
`bin/<tfm>/<rid>/` behind. The OpenHarmony codesign passes in the SDK
(`_OpenHarmonyCodeSignBuildOutputs`/`PublishOutputs`) register their stamps the same way.

## Extension hook

`_OpenHarmonyStageHap` runs `AfterTargets="Publish"` and consumes
`$(OpenHarmonyAfterPublishDependsOn)` before its own dependencies, so a project can list custom
targets that must run after the SDK's publish copy and before the hap staging (e.g. an asset
generation step whose output the staging packs). The staged `libs/<abi>/` tree is re-signed after
the payload staging and before the payload zip, so the signature always covers the final tree.

## Framework pack resolution (RID default, apphost, AspNetCore band)

Three resolution defaults in the platform pack keep a RID-specific restore working without
per-project switches:

- `Sdk/Sdk.targets` defaults `RuntimeIdentifier` to `openharmony-arm64` for executable projects
  that do not set one. With `SelfContained=true` (the platform default), the SDK inference
  (`Microsoft.NET.RuntimeIdentifierInference.targets`, imported after the workload targets)
  otherwise falls back to the SDK host RID (`NETCoreSdkPortableRuntimeIdentifier =
  ohos-arm64`), which the workload RID graph does not carry: framework-reference processing then
  failed `NETSDK1083: The specified RuntimeIdentifier 'ohos-arm64' is not recognized` before any
  pack could resolve. That hit a plain `dotnet restore` and `dotnet restore -r openharmony-arm64`
  (the CLI puts the RID in the plural `RuntimeIdentifiers`). An explicit `-r`/`RuntimeIdentifier`
  still wins.
- The same file sets `EnableAppHostPackDownload=false`: there is no openharmony apphost pack (the
  .hap host loads hostfxr), but `ResolveAppHosts` still emits apphost `PackageDownload`s for
  every RID in `RuntimeIdentifiers`. With the RID graph mapping openharmony-arm64 to
  linux-musl-arm64, a restore with `-r` requested
  `Microsoft.NETCore.App.Host.linux-musl-arm64` at the unpublished SDK-band version and failed
  NU1102. `UseAppHost` stays false; a project that explicitly turns apphost packs back on keeps
  the SDK behavior.
- `targets/OpenHarmony.PlatformItems.targets` pins the net11.0 `Microsoft.AspNetCore.App`
  `KnownFrameworkReference` (targeting pack and runtime) to the published RC1 GA band
  `11.0.0-rc.1.26425.128`. The SDK's bundled KFR points at an SDK-band daily
  (`11.0.0-rc.1.26452.110`) whose runtime pack was never published: any project that references
  AspNetCore transitively (e.g. the MAUI BlazorWebView packages) failed restore with
  `NU1102: Unable to find package Microsoft.AspNetCore.App.Runtime.linux-musl-arm64 with
  version (= 11.0.0-rc.1.26452.110)` (`Nearest version: 11.0.0-rc.1.26425.128`). The workload RID
  graph (openharmony-arm64 imports linux-musl-arm64, the same mapping the NativeAOT packs use)
  resolves the runtime pack to the linux-musl-arm64 assets; managed assemblies are portable, and
  the ref pack is pinned with the runtime so compile and run come from one published build. The
  pin is scoped to net11.0; the net10.0 KFR already points at a published 10.0.x version.
- `targets/OpenHarmony.PlatformItems.targets` also widens the SDK's AOT `KnownRuntimePack` for
  `Microsoft.NETCore.App` with `openharmony-arm64`. The bundled AOT RID list carries `ohos-arm64`
  and the linux-musl fallbacks but not the platform RID, so an AOT publish of an openharmony TFM
  resolved no `Microsoft.NETCore.App.Runtime.NativeAOT.*` runtime pack and ilc failed with
  `The PrivateSdkAssemblies ItemGroup is required for _ComputeAssembliesToCompileToNative`
  (the `<ILCompiler pack>/runtimes/<rid>/` fallback has no `native/*.dll`). With the RID
  widened, the exact openharmony pack wins over the linux-musl fallback; see "NativeAOT HAP
  variant" below.

Consumer effect: `dotnet restore` and `dotnet publish -r openharmony-arm64` work out of the box
for projects that pull AspNetCore in transitively; `test/hello-maui-app` no longer carries the
`DisableTransitiveFrameworkReferenceDownloads` workaround. A transitive framework pack is
downloaded for restore but not staged into the app output (the demo payload is unchanged); a
*direct* `FrameworkReference` would stage the linux-musl-arm64 shared framework, so apps that
actually host ASP.NET Core on the device still wait for the openharmony-native AspNetCore runtime
pack (aspnetcore-ohos). A clean machine downloads the two RC1 GA packs once; for an offline
build pre-seed them, e.g.:

```sh
curl -fL -o Microsoft.AspNetCore.App.Ref.11.0.0-rc.1.26425.128.nupkg \
  https://api.nuget.org/v3-flatcontainer/microsoft.aspnetcore.app.ref/11.0.0-rc.1.26425.128/microsoft.aspnetcore.app.ref.11.0.0-rc.1.26425.128.nupkg
curl -fL -o Microsoft.AspNetCore.App.Runtime.linux-musl-arm64.11.0.0-rc.1.26425.128.nupkg \
  https://api.nuget.org/v3-flatcontainer/microsoft.aspnetcore.app.runtime.linux-musl-arm64/11.0.0-rc.1.26425.128/microsoft.aspnetcore.app.runtime.linux-musl-arm64.11.0.0-rc.1.26425.128.nupkg
```

Version coupling: the pin is one constant in the three pack copies (identical apart from their
own preview.NN strings). When the SDK band moves, check which AspNetCore GA version that band
publishes and update the pin; `scripts/selftest-packs.sh` T7 gates the evaluated pin, the RID
default and the apphost download opt-out.

## NativeAOT HAP variant

The same `_OpenHarmonyStageHap` pipeline packages a NativeAOT publish. `test/hello-maui-app`
carries the reference implementation: with `-p:PublishAot=true` (or `OpenHarmonyAotApp=true`)
the project switches to `OutputType=Library` + `NativeLib=Shared` and exports its own launch
entry (`[UnmanagedCallersOnly(EntryPoint = "openharmony_app_main")]` in `AotEntry.cs`), matching
the host's AOT route (`docs/aot-single-entry.md`: the host probes `<app_dir>/lib<stem>.so` and
calls the export before hostfxr).

One publish produces both hap variants, like the JIT route:

```sh
dotnet publish test/hello-maui-app/hello-maui-app.csproj \
    -f net11.0-openharmony26.0 -r openharmony-arm64 -c Release \
    -p:PublishAot=true -p:PublishAotUsingRuntimePack=true \
    -p:CopyOutputSymbolsToPublishDirectory=false \
    -p:OpenHarmonyHapPackage=true -p:OpenHarmonySdkRoot=$OHOS_SDK
```

- `PublishAotUsingRuntimePack=true` is required: it is what makes the SDK's framework-reference
  processing pick the AOT `KnownRuntimePack` (widened to openharmony-arm64 in the pack, see
  "Framework pack resolution") instead of falling back to `<ILCompiler pack>/runtimes/<rid>/`.
- Packs: `Microsoft.NETCore.App.Runtime.NativeAOT.openharmony-arm64` (runtime pack) +
  `runtime.openharmony-arm64.Microsoft.DotNet.ILCompiler` (target ilc); the build host also
  needs its own `runtime.<host>-Microsoft.DotNet.ILCompiler` (the AOT-ENABLE mirror,
  `eng/ohos-install/fetch-nativeaot-packs.sh`).
- The publish output is a single `lib<stem>.so` (no managed assemblies, no CoreCLR natives), so
  the staging carries it in `libs/<abi>/`: app library + host + `libc++_shared.so` +
  `.dotnet-payload.json`, all covered by the same `OpenHarmonyCodesign` pass and the HAP
  signature block. `module.json` keeps the shared template (`libIsolation:true`), and
  `resources/rawfile/app.json` keeps naming the entry assembly
  (`hello-maui-app.dll`), which is how the host derives `lib<stem>.so`.
- `-p:CopyOutputSymbolsToPublishDirectory=false` is recommended: the native `.dbg` otherwise
  lands in `libs/` and in `dotnet.zip` and roughly triples the hap size. The symbol file stays
  in `obj/**/native/`.
- IL gate: the reference demo publishes with **0 IL2026/IL3050/IL3051** - the three template
  self-bindings live behind one `[UnconditionalSuppressMessage]` helper (`App.cs`), because the
  string-path `SetBinding` overload and the `Binding(string)` constructor are both annotated
  `RequiresUnreferencedCode` in MAUI. Warnings outside the gate (`IL3000` from the ASP.NET
  BlazorWebView asset loader, MAUI `NETSDK1188` locale warnings) are not trim defects.
- Launch scope: the ArkTS shell starts the bridged route (`start_app`), and the host now serves
  the AOT payload there too (R2-SHELL-EXT): `start_app` probes `<app_dir>/lib<stem>.so` and calls
  `openharmony_app_main` on the bridged app thread (log `aot=1`), so lifecycle/node events and
  the managed `register_bridge` handshake work exactly as for a JIT payload; a missing
  library/symbol/allocation logs `aot=0` and keeps the hostfxr route. `run_app` keeps its
  one-shot probe. The host route is verified locally without a device:
  `test/aot-smoke/run-local-smoke.sh` compiles the fake app and `test_host`, self-signs both with
  `binary-sign-tool -selfSign 1` (an OpenHarmony kernel refuses unsigned ELFs: execve and dlopen
  both return EACCES) and asserts the one-shot payload
  (`<dir>/FakeApp.dll\nalpha\nbeta`, exit 7) plus the bridged payload (`<dir>/FakeApp.dll`, exit 7
  through `test_host --bridge ...`, which is the `start_app` `aot=1` route). Against the real
  publish, `test_host <publish-dir> hello-maui-app.dll` loads the AOT library, runs the app's
  module initializers and bridge registration, then waits for the ArkUI surface (on a host
  without the shared ICU data, set `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` for that run).

## Packaging task assembly

The pipeline's MSBuild tasks are compiled into `Microsoft.OpenHarmony.Tasks.dll` instead of being
defined inline with `RoslynCodeTaskFactory` (task-assembly migration, audit V8):

- **Layout**: `src/Microsoft.OpenHarmony.Tasks/` holds the six task classes
  (`OpenHarmonyDeterministicZip`, `OpenHarmonyStageRuntimeLibs`, `OpenHarmonyStagePayloadLibs`,
  `OpenHarmonyWritePayloadMarker`, `OpenHarmonyResolvePermissions`,
  `OpenHarmonyGenerateModuleJson`). Each class body is the former inline code verbatim, so the task
  parameters, the log/error strings and the produced bytes are unchanged.
- **Target framework**: `netstandard2.0`, so the same assembly loads under the .NET Framework MSBuild
  host (Visual Studio / `MSBuild.exe`, net472+) and under the .NET MSBuild host (`dotnet build`);
  `Microsoft.Build.Framework`/`Microsoft.Build.Utilities.Core` are compile-only references
  (`ExcludeAssets="runtime"`) because the host provides them at task-load time. The assembly is
  deterministic; no deps.json is shipped.
- **Distribution**: `scripts/prepare-packs.sh` builds it and copies it into
  `packs/Microsoft.OpenHarmony.Sdk/<version>/tools/`. The pack targets load it with
  `UsingTask AssemblyFile="$(MSBuildThisFileDirectory)../tools/Microsoft.OpenHarmony.Tasks.dll"`.
  The DLL is committed into all three preview packs (the pack targets must stay byte-identical), and
  `scripts/lint-packs.sh` fails the pack lint when a `UsingTask` reference does not resolve to a file
  the pack actually ships.
- **Tests**: `test/openharmony-tasks-tests/` runs the six classes with a stub `IBuildEngine` (95
  checks: zip determinism/ordinal order/fixed timestamp/skip names, runtime-ELF staging, payload
  staging layout, payload-marker schema + escaping, feature-permission matrix/request-point/strict
  mode, module.json substitution/escaping/insertions/negatives). `scripts/selftest-tasks.sh` builds
  the assembly and the test host, runs the suite, and fails when the committed pack copies drift from
  the freshly built Release assembly (re-run `scripts/prepare-packs.sh`); it is part of the
  `scripts/preflight.sh` repository gates. `scripts/selftest-hap-targets.sh` T1 additionally pins
  the six `UsingTask` entries and the absence of inline code, and its T2/T3/T5 fixtures run the
  compiled tasks through the real pack targets.

## Development loop: devloop.sh

Hot Reload over the IDE debug bridge is not available here: the hdc device policy restricts the
debug channel (`hdc install` / `aa start` / `hilog` still work, the IDE's attach path does not).
The working replacement is an incremental deploy loop - one command publishes the app, re-signs
the hap when the device is not bound to the SDK's profile, installs it, starts `EntryAbility`
and tails the filtered hilog. `scripts/devloop.sh` is that loop; `scripts/selftest-devloop.sh`
drives it against stub `hdc`/`dotnet`/signer binaries with no device (86 checks).

```sh
# one round: publish -> install the newest signed hap -> start -> 5 s filtered hilog
sh scripts/devloop.sh

# incremental publish only, with extra MSBuild properties passed through verbatim
sh scripts/devloop.sh build -p:OpenHarmonyBundleName=com.example.hellomauiapp

# re-sign the -unsigned.hap with external material and deploy the signed hap
sh scripts/devloop.sh all --sign --sign-profile dev.p7b --sign-key dev.p12 \
    --sign-alias key0 --sign-cert chain.cer --sign-pwd-file ~/.ohos/pwd --expect-udid <UDID>

# edit loop: republish + reinstall on every source change (no inotify; find -newer polling)
sh scripts/devloop.sh --watch --interval 3

# plan only (no dotnet/hdc/device needed)
sh scripts/devloop.sh --dry-run --sign --sign-profile dev.p7b --sign-key dev.p12 --sign-alias key0
```

| command | what it runs |
|---|---|
| `build` | `dotnet publish <project> -f net11.0-openharmony26.0 -r openharmony-arm64 -c Release` (+ `-p:` pass-through) |
| `sign` | `scripts/sign-for-device.sh --external ...` on the newest `*-unsigned.hap` (needs `--sign` + material) |
| `install` | `hdc install -r <hap>` (newest signed hap in the publish output, or a `--hap` list) |
| `start` | `hdc shell aa start -a EntryAbility -b <bundle>` after the bundleName whitelist check |
| `logs` | `hdc shell hilog` filtered with tester-run's `FILTER_RE` (`--follow` stays attached) |
| `all` | build -> (sign) -> install -> start -> logs (default) |

Key flags: `--project`, `-f`/`-r`/`-c`, `-p:`/`--property`, `--hap`, `--bundle`, `--device`,
`--out-dir`, `--watch`/`--interval`, `--follow`/`--log-seconds`/`--filter`, `--dry-run`.
Exit codes match tester-run.sh: 0 = ok, 1 = a step failed, 2 = usage error, 3 = no hdc/device.

Division of labour with `tester-run.sh`:

- `devloop.sh` is the developer edit loop: incremental publish, install, start, filtered hilog.
  It never uninstalls, never verifies a kit and produces no archive; `--watch` reruns the selected
  command on source changes (bin/obj/.git pruned, so a rebuild cannot retrigger itself), and a
  failed round keeps polling instead of killing the watcher.
- `tester-run.sh` is the evidence round for a hand-off: kit verification, capture windows
  (hilog + kmsg), probes, device/payload/ELF-signing evidence and the `tester-report-*.tar.gz`
  archive. Use it when someone else has to read the result; use `devloop.sh` while editing.
- Both share the same device-safety posture: the bundleName whitelist (dotted, letter-first
  `[A-Za-z0-9_]`) gates every `aa start`, missing hdc/device refuses the device steps (without
  `--dry-run`), and paths are treated as space-bearing. `--sign` reuses
  `sign-for-device.sh --external`, so the p12 password goes through its file/interactive path and
  never enters argv or logs.

## Known follow-ups (scheduled)

- **Functional clean regression**: the FileWrites registration is gated statically (the interaction
  suite and `eng/ohos-install/tests/test-codesign-filewrites.sh`); a `dotnet clean` run over a real
  publish (device kit or a stub-toolchain fixture) is scheduled with RELEASE-25, together with the
  SDK rebuild that carries the codesign-stamp registration.
- **RID graph CI pin**: `scripts/sync-ridgraph.sh` single-sources the pack copies from
  `sdk-ohos/eng/PortableRuntimeIdentifierGraph.openharmony.json`; the cross-repo gate
  (`.github/workflows/ridgraph-sync.yml`) pins the sdk-ohos commit `97cad7c59a` and must be bumped
  in lockstep with the sync whenever the canonical graph changes.
