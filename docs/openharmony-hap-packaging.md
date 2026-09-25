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

## Opt-in permissions

Set `OpenHarmonyExtraPermissions` to a `;` or `,` separated list of permission names, e.g. (keep
the quotes - MSBuild splits an unquoted command-line property value at `;` and `,`, or use `%3B` /
`%2C`):

```sh
-p:'OpenHarmonyExtraPermissions="ohos.permission.READ_CONTACTS;ohos.permission.READ_CALENDAR"'
```

or set `OpenHarmonyExtraPermissions` in the project file. When the property is set and non-empty
the generated `module.json` gains the matching minimal
`"requestPermissions":[{"name":"..."}]` array (no usedScene/resources entries). Declaring a
permission here does not grant it: the app still has to request it at runtime
(`abilityAccessCtrl.requestPermissionsFromUser`). Unset/empty keeps `module.json` byte-identical to
the build without the property.

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

The branch changes exactly three things: the SDK root comes from `ARKTS_HARMONY_SDK_ROOT` /
`DEVECO_SDK_HOME` (must carry `<root>/default/openharmony/ets` and `<root>/default/hms/ets`, or the
build fails with the property to set), `runtimeOS` becomes `HarmonyOS`, and `compatibleSdkVersion`
defaults to `6.1.0(23)` (override with `ARKTS_COMPATIBLE_SDK_VERSION`) - the value the device-side
DevEco build used to emit the accepted abc. `externalApiPaths` additionally exposes `hms/ets`, which
is what lets the Share/Scan sinks compile against the real kit types. The abc header gate is
unchanged: `ARKTS_MAX_BC_VERSION` stays `13.0.1.0` (the device runtime ceiling; the DevEco build at
`6.1.0(23)` produced exactly `13.0.1.0`), so a HarmonyOS SDK whose es2abc emits a newer abc still
fails here. On the default flavor the shell compiles the Share/Scan *probe* only: the specifier
stays in a variable and the resolved module is cast to a local structural interface, so a device
without the kit registers no sink and the managed side degrades (see the KIT-IMPL report in
`runtime-ohos/docs/plans/2026-09-24-ohos-kit-gap-analysis.md`).

The branch is scaffold-verified (`--scaffold-only` plus the selftest T14); a full build needs the
HarmonyOS SDK present, which the current build host does not have.

### Templates / abc sync strategy

`OpenHarmonyArktsModulesAbc` defaults to the checked-in prebuilt shells: `templates/ets/modules.ui.abc`
for UI builds (`OpenHarmonyUIPage` set) and `templates/ets/modules.abc` (headless) otherwise; an
explicit `-p:OpenHarmonyArktsModulesAbc=<file>` overrides both. The sources under
`templates/ets/**` and those prebuilt abc files drift apart until a release rebuild:

- **Source change (default flavor)**: rebuild with
  `ARKTS_SHELL_VARIANT=ui scripts/build-arkts-shell.sh` (writes `dist/ets/modules.abc`) and
  `ARKTS_SHELL_VARIANT=headless …` (writes `dist/ets/modules.headless.abc`), then update all three
  preview packs in lockstep: UI -> `templates/ets/modules.ui.abc` and `modules.shell.abc`, headless
  -> `templates/ets/modules.abc`. The script's own gates must pass on each artifact: the abc version
  (`--check-abc`/header read-back <= 13.0.1.0) and the payload-in-libs contract
  (`dotnet-payload`/`bundleCodeDir`/`payload-in-libs`/`dotnet.marker`). The harness pins the three
  `Index.ets` sources byte-identical, so a partial pack update fails `test/maui-platform-verify`.
- **HarmonyOS flavor**: the compiled abc is flavor-specific (the HarmonyOS es2abc/toolchain), so do
  not overwrite the checked-in OpenHarmony abc with it - the default packs must stay buildable
  without the HarmonyOS SDK. Build the flavor and pass the result to the packaging invocation, or
  ship it as a separate pack revision; keep the checked-in `modules*.abc` on the default flavor.
- **Current state (KIT-IMPL, 2026-09-25)**: the preview.22/23/24 `Index.ets` carry the Share/Scan
  probe and compile on the OpenHarmony SDK (224,076 B UI abc, version 13.0.1.0, verified), but the
  checked-in `modules.ui.abc`/`modules.shell.abc` are still the kit #24 build (215,680 B). Until the
  next release rebuild replaces them, a hap that must carry the probe has to pass
  `-p:OpenHarmonyArktsModulesAbc=<freshly built abc>` or wait for that rebuild.

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

## Known follow-ups (scheduled)

- **Task assembly**: the pipeline's UsingTasks are still inline `RoslynCodeTaskFactory` code
  (`OpenHarmonyDeterministicZip`, `OpenHarmonyStageRuntimeLibs`, `OpenHarmonyStagePayloadLibs`,
  `OpenHarmonyWritePayloadMarker`, `OpenHarmonyGenerateModuleJson`). They should move to a
  compiled `Microsoft.OpenHarmony.Tasks.dll` (a first-party net11.0 project referencing the MSBuild
  assemblies, built by `scripts/prepare-packs.sh` and shipped in `packs/*/tools/`) with unit tests
  for the zip determinism and the skip lists. Scheduled with the next SDK/workload release
  (RELEASE-25): it needs the new project, the DLL committed into the three packs and a full hap
  publish re-verification.
- **Functional clean regression**: the FileWrites registration is gated statically (the interaction
  suite and `eng/ohos-install/tests/test-codesign-filewrites.sh`); a `dotnet clean` run over a real
  publish (device kit or a stub-toolchain fixture) is scheduled with RELEASE-25, together with the
  SDK rebuild that carries the codesign-stamp registration.
- **RID graph CI pin**: `scripts/sync-ridgraph.sh` single-sources the pack copies from
  `sdk-ohos/eng/PortableRuntimeIdentifierGraph.openharmony.json`; the cross-repo gate
  (`.github/workflows/ridgraph-sync.yml`) pins the sdk-ohos commit `32e1719359` and must be bumped
  in lockstep with the sync whenever the canonical graph changes.
