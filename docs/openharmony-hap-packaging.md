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
libs/<abi>/{libopenharmonyhost.so, libc++_shared.so, <.NET runtime *.so>},
resources/base/..., resources/rawfile/{app.json, dotnet.zip}
```

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
(present, non-empty, ≤ 1 KiB), the abc header/size, the `libs/arm64-v8a` set and the
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
`libc++_shared.so` next to the host. It is looked up under the SDK roots the targets file already
knows - `OpenHarmonySdkRoot` (or `OHOS_SDK_ROOT`), both as `<root>/native/llvm` and with the root
itself as the native root, `OHOS_NDK`, and the harmonybrew Cellar install
`_OpenHarmonyDetectToolchain` falls back to - in the LLVM triple matching `OpenHarmonyAbi`
(arm64-v8a -> aarch64-linux-ohos). A
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
directory (`libhostpolicy.so`, `libcoreclr.so`, `libclrjit.so`, `libclrgc/gcexp.so`). The shell
extracts only what the zip carries, so before the next device round the host has to bridge
`libs/<abi>/` into the app directory (symlink the signed file under the same name before
`start_app`) or `hostpolicy_resolver`/`deps_resolver` need a `libs/<abi>` lookup. Until that
bridge exists a hap built by this target only starts where the app dir still carries those four
files (i.e. a payload that was not excluded).

The set is enumerated from the publish directory at target execution time; non-ELF `*.so` entries
are skipped (and stay in the zip), an empty ELF set is a hard error, and the staged libs go
through the same `OpenHarmonyCodesign` pass as the host and `libc++_shared.so`.

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
`wwwroot/_framework/blazor.webview.js`: the project's static web assets (`@(StaticWebAsset)`) are
the canonical source when the Razor/static-web-assets pipeline ran, otherwise it is read from the
NuGet cache
(`$(NuGetPackageRoot)microsoft.aspnetcore.components.webview/*/staticwebassets/`); a
`@(MauiAsset)` list with `wwwroot/<TargetPath>` entries (`ConvertStaticWebAssetsToMauiAssets`) is
consumed too when a MAUI SDK produced it. This is the OpenHarmony port's stand-in for the
MauiAsset consumer, which does not exist in this tree.

NOTE (native model): the OpenHarmony host runs the managed app in-process on CoreCLR, so Blazor
Hybrid here is the native model (like Android/iOS), not the WebAssembly one - the WebView only
needs `blazor.webview.js` and the message transport, and no
`dotnet.js`/`dotnet.native.wasm`/`_*.dll` browser assets are staged. A project without `wwwroot`
is untouched, so its payload stays byte-identical.
