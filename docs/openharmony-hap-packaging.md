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
additionally exposes `hms/ets`, which is what lets the Share/Scan sinks and the Map overlay
compile against the real kit types. The abc header gate is
unchanged: `ARKTS_MAX_BC_VERSION` stays `13.0.1.0` (the device runtime ceiling; the DevEco build at
`6.1.0(23)` produced exactly `13.0.1.0`), so a HarmonyOS SDK whose es2abc emits a newer abc still
fails here. On the default flavor the shell compiles the Share/Scan *probe* only: the specifier
stays in a variable and the resolved module is cast to a local structural interface, so a device
without the kit registers no sink and the managed side degrades (see the KIT-IMPL report in
`runtime-ohos/docs/plans/2026-09-24-ohos-kit-gap-analysis.md`). The Map overlay follows the same
rule: the default flavor never copies `MapOverlay.ets`, the page's dynamic `./map/MapOverlay`
import fails at runtime there, and the Map sink reports capability bit 1 = 0.

The branch is scaffold-verified (`--scaffold-only` plus the selftest T14); a full build needs the
HarmonyOS SDK present, which the current build host does not have.

### Kit feature probes and AGC prerequisites (Push / Account / Map)

The second batch of HMS Kits (KIT-EXT2, 2026-09-25; Map overlay R2-3, 2026-09-26) rides the same
split: each shell template carries a *probe* that compiles on the OpenHarmony SDK, and only a
runtime that actually provides the kit registers the sink. A device without the kit (or the
default OpenHarmony build) keeps the managed side's documented degradation - no throw, no silent
guess:

| Kit | Managed API | Shell sink / answer | Status map |
|-----|-------------|---------------------|------------|
| Push | `OpenHarmonyPush.GetTokenAsync` / `DeleteTokenAsync` / `IsSupported` | `pushService.getToken()` / `deleteToken()`; `host.notifyPushResult(id, op, rc, token)` | rc 0 = success (token for op 0), -1 = unavailable; positive rc is the Push Kit code, e.g. `1000900010` (AGC push service not enabled / signing profile mismatch), `1000900012` (entitlement not enabled), `1000900011` (no network), `1000900014` (device unsupported) |
| Account | `OpenHarmonyAccount.GetQuickLoginAnonymousPhoneAsync` / `AuthorizeAsync(scopes)` / `IsSupported` | `createAuthorizationWithHuaweiIDRequest()` + `AuthenticationController.executeRequest()`; `host.notifyAccountResult(id, op, rc, payload)` | rc 0 = success (op 0 payload = anonymous phone, op 1 payload = `response.data.authorizationCode`), -1 = unavailable/state mismatch; positive rc is the Account Kit code, e.g. `1001502014` (scope not applied for/approved), `1001500001` (signing fingerprint mismatch), `1001502001` (no Huawei ID signed in), `1001502012` (user cancelled), `1001500003` (scope unsupported) |
| Map | `OpenHarmonyMap.QueryCapabilitiesAsync` / `IsSupported` / `IsOverlayAvailable` / `ShowAsync` / `HideAsync` / `CloseAsync` / `SetRegionAsync` / `AddMarkerAsync` / `Ready`/`MarkerClick`/`CameraIdle` | `@kit.MapKit` + `SystemCapability.Map.Core` probe, then the `MapComponent` overlay driven through `host.registerMapSink` / `host.notifyMapResult(id, op, code, payload)`; bit 0 = kit resolved, bit 1 = overlay module resolved (the harmony build) | flags value (0/1/3), `null` when the sink is unregistered; ops 0 probe / 1 create / 2 destroy / 3 show / 4 hide / 5 set region / 6 add marker, code 0 applied, -1 unavailable, -2 overlay refused; events with id 0 (1 ready, 2 marker click, 3 camera idle) |
| Live View (R2-SHELL-EXT) | `OpenHarmonyLiveView.StartAsync(update)` / `UpdateAsync(update)` / `StopAsync(id)` / `IsSupported` | `canIUse('SystemCapability.LiveView.LiveViewService')` + `@kit.LiveViewKit`; `liveViewManager.isLiveViewEnabled()` then `startLiveView`/`updateLiveView`/`stopLiveView` on the TIMER scene (progress template; `title`/`text`/`progress`/`time` in ms); `host.notifyLiveViewResult(id, op, rc, payload)` | rc 0 = applied, -1 = unavailable or no view the shell owns, -2 = the kit call failed or the args were malformed, -3 = the user's live view switch is off; positive rc is the Live View Kit code (`1003500004` switch off, `1003500005` entitlement not approved, `1003500006` id exists, `1003500011` stale sequence, ...) |

Host exports (all in the `host-exports.txt` contract, 134 names): `ohos_host_push_{available,request,register_result,result}`,
`ohos_host_account_{available,request,register_result,result}`, `ohos_host_map_{available,command,register_result,result}`
(the R2-3 overlay folded the reserved probe into `ohos_host_map_command(id, op, args)`; the export
count was unchanged there because the overlay reuses the same four Map exports and one answer
callback), and `ohos_host_liveview_{available,request,register_result,result}` (R2-SHELL-EXT).
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

Decision point: **the overlay needs the `ARKTS_SDK_FLAVOR=harmony` shell build plus the AGC map
service AppKey** - the default OpenHarmony SDK build cannot compile the component declaration, and
without the AppKey the map view fails to initialize (logged by `MapOverlay.ets`, no event fires).
So a device/HAP built with the default flavor answers `IsOverlayAvailable=false` even when
`IsSupported=true` (the kit itself resolved): the capability answer distinguishes the two.

AGC / device prerequisites (all external to this repository; the KIT-GAP report
`runtime-ohos/docs/plans/2026-09-24-ohos-kit-gap-analysis.md` tracks them):

- **All four**: HarmonyOS SDK build (`ARKTS_SDK_FLAVOR=harmony`), an HMS device, and an app
  registration in AppGallery Connect whose signing certificate fingerprint and bundle name match
  the build.
- **Push**: enable Push in AGC (增长 > 推送服务) and re-generate the signing profile with the push
  entitlement; no `module.json5` permission is needed for `getToken()`.
- **Account**: apply for the Huawei ID one-tap login permission
  (`quickLoginAnonymousPhone` scope) and reference the resulting scope in the authorization
  request; the anonymous phone is exchanged for the real number on the app's server.
- **Map**: enable the map service in AGC and configure the AppKey (the harmony shell build plus a
  matching bundle name/signing fingerprint); without it the `MapComponent` initialization fails
  and no `Ready` event fires, so `IsOverlayAvailable` stays true (the shell has the overlay) while
  no map is shown. Map data use is subject to the AGC map service terms.
- **Live View (R2-SHELL-EXT)**: apply for the Live View entitlement (实况窗权益) for the scene
  (`TIMER` here) in AGC and keep the user's live view switch on (设置 > 应用和元服务 > 应用名 >
  实况窗); the device-side API also needs the app in the foreground. The scene whitelist and the
  entitlement are the prerequisites for a real card.

Verification without an HMS device: `test/maui-platform-verify` pins the shell probe/sink shape,
the overlay module and its flavor gate, the host/managed contract, the off-device degradation
(`[verify] kit4/kit5/kit6/kit7` for the second batch + overlay, `kit8/kit9/kit10` for Live View)
and the interpreter switch (`pg2 host interp policy`: the `interp.txt` parser, the guarded
`DOTNET_InterpMode` setenv and the log pair),
while `scripts/build-arkts-shell.sh` keeps the abc at
`13.0.1.0`, carries the `./map/MapOverlay`, `registerLiveViewSink`, `notifyLiveViewResult`,
`@kit.LiveViewKit` and `SystemCapability.LiveView.LiveViewService` literals
in the UI abc (the provenance gate) and enforces
the source contract (no `@ohos.*` imports, variable kit specifiers). The host-side gate is
`scripts/build-host.sh` (nm -D: all 134 `host-exports.txt` names present as plain symbols) plus
`scripts/check-host-exports.py --cross-check`.

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
    `SystemCapability.LiveView.LiveViewService`, which the
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
- **Current state (COMP-ARKTS fix, 2026-09-25)**: all three preview packs carry the same sources
  (Share/Scan probe, kit-import migration, feature permission chain) and the abc rebuilt from them
  on the OpenHarmony SDK: UI 234,620 B / sha256 `343253329aab…6e1f2`, headless 18,532 B / sha256
  `d7ec9ca7ee61…38d785`, both abc version 13.0.1.0 with `compatibleSdkVersion 18`.

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

## Known follow-ups (scheduled)

- **Functional clean regression**: the FileWrites registration is gated statically (the interaction
  suite and `eng/ohos-install/tests/test-codesign-filewrites.sh`); a `dotnet clean` run over a real
  publish (device kit or a stub-toolchain fixture) is scheduled with RELEASE-25, together with the
  SDK rebuild that carries the codesign-stamp registration.
- **RID graph CI pin**: `scripts/sync-ridgraph.sh` single-sources the pack copies from
  `sdk-ohos/eng/PortableRuntimeIdentifierGraph.openharmony.json`; the cross-repo gate
  (`.github/workflows/ridgraph-sync.yml`) pins the sdk-ohos commit `97cad7c59a` and must be bumped
  in lockstep with the sync whenever the canonical graph changes.
