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
`compileSdkType` after `app.apiReleaseType`, the opt-in `requestPermissions` member and - when
`OpenHarmonyAppLinkHosts` is set - the app-link skill element into `module.abilities[0].skills`
(see "Deep links / activation"), and validates the result as JSON before writing it (only when the
bytes changed). A template with an
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
pure mode 3 also exports `DOTNET_ReadyToRun=0` next to it (CG2-R2R): the interpreter never
executes an R2R image's native code, and while the runtime already forces ReadyToRun off for
`DOTNET_InterpMode >= 2` (`eeconfig.cpp`), the host states the intent at the same decision
point as the other mode-3 switches. The JIT and the mixed modes (1/2) keep the runtime
default. The host logs the decision on every launch path:

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

### JITFORT unlock and the JIT globalization fallback (WX-HOST-PRCTL, 2026-10-03)

The app domain starts with XPM/JITFORT fortification on: anonymous `mmap(RWX)` and anonymous
`mmap(RW)->mprotect(RX)` are refused with `EINVAL`, so CoreCLR cannot allocate executable memory
and CoreLib load fails with `0x800701E7` on both the JIT and the interpreter routes. The host
issues `prctl(0x6a6974, 0, 0)` ("JITFORT off"; the NDK `sys/prctl.h` has no `PR_SET_JITFORT`, so
the literal is defined in `openharmony_host.c`) inside `OhosHostApplyExecMemoryPolicy`, before
hostfxr/coreclr can initialize on either launch path:

- Default on; `DOTNET_OHOS_NO_JITFORT=1` skips it and a failure is never fatal - the launch falls
  through to the existing `xwe=0` route. The one-shot status line
  `OHOS_DOTNET jitfort: rc=<rc> errno=<errno> state=<off|fortified>` goes to hilog/stderr and
  `<filesDir>/dotnet-status.txt`. The exec-memory probe runs after it, so `1=OK 2=OK` witnesses
  the unlocked sandbox.
- An explicit `runtime-mode=aot` payload skips the call (`jitfort: skipped runtime-mode=aot`):
  the NativeAOT route allocates no executable memory and the platform state stays untouched.

The platform contract and the A/B (`jitfort(0,1)` -> `1=22` + CoreLib failure; `jitfort(0,0)` ->
`1=OK` + CoreLib pass) are recorded in `runtime-ohos/docs/plans/2026-10-03-ohos-wx-probe-matrix.md`;
the unlock needs no platform change or ACL. It also complements the W^X selection above: with
JITFORT off, `EnableWriteXorExecute=0` (anonymous RWX) is the working allocator shape.

JIT/interp additionally need globalization: this image ships no system ICU and CoreCLR fail-fasts
in `GlobalizationMode+Settings..cctor` ("Couldn't find a valid ICU package") right after managed
startup, before the first frame. The host's one-shot globalization policy (same call site, same
launch paths) probes `dlopen("libicuuc.so")` and, when it is absent, exports
`DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` for the runtime that starts next; a device that ships
ICU keeps full globalization. `DOTNET_OHOS_ICU=0|1` overrides the probe.
`OHOS_DOTNET globalization: invariant=<0|1> icu=<0|1> source=<probe|env>` records the decision.
The interpreter's existing `DOTNET_UseGCWriteBarrierCopy=0` selection for `InterpMode=3` stays as
is; the JIT keeps the arm64 default (the unlock removes the RWX refusal that motivated the
workaround).

Device round (host built from this tree, kit HAPs repacked and self-signed): the JIT HAP logs
`jitfort rc=0`, probe `1=OK 2=OK`, passes CoreLib, starts MAUI and presents (`canvas presented`,
UI visible); a pre-existing MAUI slice handler race (`Handler is already being set elsewhere`)
still fail-fasts some JIT instances. The interpreter HAP no longer fails with `0x800701E7`; it
now SIGSEGVs (NULL) inside `coreclr_initialize` and has not reached a first frame. The AOT HAP
logs `jitfort: skipped runtime-mode=aot` and presents as before. Evidence: the `wx-prctl/`
device scratch and `runtime-ohos/docs/plans/2026-10-03-ohos-jitfort-enable.md`.

## Runtime mode switch

`-p:OpenHarmonyRuntimeMode=jit|aot|interp` (default `jit`) is the single packaging switch that
selects the launch shape a hap is built for. The value is written to
`libs/<abi>/runtime-mode.txt` inside the hap by the `_OpenHarmonyStageRuntimeMode` target, which
`_OpenHarmonyStageHap` calls after the payload-in-libs staging and before the `OpenHarmonyCodesign`
pass, so the marker travels next to the signed payload and is counted by the
`.dotnet-payload.json` marker written later:

| value | packaging | launch |
|---|---|---|
| `jit` (default) | unchanged: hostfxr + the runtime natives staged from the publish | the host keeps its JIT route (`aot=0`) |
| `aot` | requires `lib<stem>.so` (the NativeAOT application library; `<stem>` is the `app.json` assembly name without `.dll`) in the publish payload; a missing library is a build error naming the aot-haps publish flags (`-p:PublishAot=true -p:PublishAotUsingRuntimePack=true -p:NativeLib=Shared`, see "NativeAOT HAP variant") | the existing `<app_dir>/lib<stem>.so` probe routes to `openharmony_app_main`; when the marked library is missing or unloadable the host logs `runtime-mode=aot but <path> ...; falling back to the JIT route` instead of the silent JIT fall-through |
| `interp` | optional `-p:OpenHarmonyInterpreterPack=<dir>` stages the extracted `ohos-interpreter-pack` (`<dir>/` or `<dir>/native/`: `libcoreclr.so` + `libclrinterpreter.so`) over the publish natives; both files are re-signed by the same codesign pass. Without a pack the stock natives stay and the device-side overlay route still applies | the host sets `DOTNET_InterpMode=3` (and the mode-3 `DOTNET_ReadyToRun=0` R2R opt-out) before coreclr starts, unless `<filesDir>/interp.txt` carries a value |

An invalid `OpenHarmonyRuntimeMode` fails the build (`jit`, `aot` and `interp` are the accepted
values); `OpenHarmonyInterpreterPack` outside `interp` mode fails too.

Host-side precedence (all applied before hostfxr can start coreclr, the same launch point as
`xwe.txt`): a writable-sandbox `<filesDir>/interp.txt` wins (`source=file`, its value is applied
to `DOTNET_InterpMode`), else the packaged marker (`source=manifest`; `interp` selects
`DOTNET_InterpMode=3` plus the mode-3 `DOTNET_ReadyToRun=0` opt-out), else the JIT default
(`source=default`). The effective mode is logged on every launch path (hilog and stderr):

```text
[openharmony-host] start_app: runtime-mode=interp source=manifest
[openharmony-host] start_app: interp=3 source=manifest
```

An absent or unreadable marker keeps the default; one that carries anything other than
`jit|aot|interp` logs `runtime-mode.txt carries an unknown value; keeping jit` and keeps the
default (the packaging already rejects it, so this covers a stale or hand-edited file). The marker
is looked up in the effective `app_dir` first and then in the host library's own directory
(`dladdr`), so the extracted-payload fallback (`<filesDir>/dotnet`) still sees the bundled marker.

Device rounds keep their existing switching files - `xwe.txt` for the W^X A/B and `interp.txt`
for the interpreter round - and `scripts/tester-run.sh --mode-matrix` records their evidence
(`hilog/hilog-execmem.txt`, the `aot_route`/`interp_mode` summary keys). The build switch is what
turns the AOT/interp *variants* into one publish property instead of a manual repack; the JIT /
AOT / interpreter determination card is
`runtime-ohos/docs/plans/2026-09-27-ohos-runtime-mode-determination.md`. The delivery kit's
whole-kit default is `aot` since AOT-DEFAULT (`scripts/make-device-test-kit.sh --runtime-mode`;
see "Distribution default: AOT" below).

Off-device gates: `scripts/selftest-hap-targets.sh` T7 drives the staging target with a fixture
(default marker, invalid value, aot without/with the app library, interpreter pack in both
layouts, pack errors); the interaction suite pins the host parser/precedence/fallback and the pack
contract (`ms-mode` checks); `test/aot-smoke/run-local-smoke.sh` exercises the host branches on a
device host (default/aot/interp markers, the aot fallback and the `interp.txt` override).

## Runtime mode kits

`scripts/make-mode-kit.sh` builds the three switch shapes of one project into per-mode
deliverable directories and verifies each shape before keeping it:

```sh
sh scripts/make-mode-kit.sh --project test/hello-maui-app/hello-maui-app.csproj \
    --tfm net11.0-openharmony26.0 --out-dir /data/storage/el2/base/tmp/opencode/modekit \
    --interp-pack /data/storage/el2/base/tmp/opencode/interp-pack --sign <UDID>
```

`--mode jit|aot|interp` (comma list or repeated; default all three) selects the shapes; `--rid`
defaults to `openharmony-arm64`, `--property <name=value>` forwards extra MSBuild properties (the
switch is appended last, so the kit wins) and `--dry-run` prints the exact commands without
running them.

| mode | publish | assertion before the hap is kept |
|---|---|---|
| `jit` | the default publish | `libs/<abi>/runtime-mode.txt` reads `jit` |
| `aot` | `-p:PublishAot=true -p:PublishAotUsingRuntimePack=true -p:NativeLib=Shared` (the aot-haps recipe) plus `-p:OpenHarmonyUIPage=pages/Index` unless `--property` supplies another page (the UI shell must be staged; see "NativeAOT HAP variant") | marker `aot` and `libs/<abi>/lib<stem>.so` present (`<stem>` = the `app.json` assembly without `.dll`) |
| `interp` | `-p:OpenHarmonyInterpreterPack=<dir>` (an extracted `ohos-interpreter-pack`) | marker `interp` and both swapped `libcoreclr.so` + `libclrinterpreter.so` present |

A missing or mismatching marker, a missing AOT application library, a missing interpreter library
and an incomplete pack all fail the run non-zero, naming the entry and the fix (the pack targets
reject the same inputs at build time; the kit gate also covers a publish whose payload was staged
out of band). The output is `out/<mode>/<stem>-<mode>.hap` (the publish's signed hap, or the
unsigned one when signing is off), `out/<mode>/<stem>-<mode>-unsigned.hap`,
`out/<mode>/publish.log` and an `out/SHA256SUMS` over every hap; a stale hap left from an earlier
publish cannot pass as the new output.

`--sign <args...>` is a `scripts/sign-for-device.sh` passthrough: every argument after `--sign`
goes to the signer and each mode hap is replaced in place only after the signer succeeds (the
`<stem>-<mode>.hap` name is what `tester-run.sh --aot-haps`/`--interp-hap` consume). Keep secrets
off argv - `--pwd-input-mode`, `--key-pwd-file` or `OHOS_ENC_PWD`; the kit itself never adds one.
The local SDK root resolution mirrors `scripts/make-device-test-kit.sh`, and
`OpenHarmonySdkRoot`/`OHOS_SDK_ROOT`/`OHOS_NDK` from the environment always win.

Off-device gate: `scripts/selftest-make-mode-kit.sh` drives the whole surface against a fake
dotnet (no SDK, no real publish): dry-run command shapes for all three modes, the fixture shapes
with their marker/library assertions, the negative gates (aot/interp missing libraries,
mismatching marker, failed and empty publish, incomplete pack, stale hap) and the signing
passthrough (no password on the generated argv, the original hap survives a failed sign).

## Distribution default: AOT (AOT-DEFAULT, 2026-10-03)

`scripts/make-device-test-kit.sh --runtime-mode aot|jit|interp` (env
`DEVICE_TEST_KIT_RUNTIME_MODE`) is the whole-kit MS-MODE switch; **the default is `aot`**. The
decision and its device evidence are
`runtime-ohos/docs/plans/2026-09-27-ohos-runtime-mode-determination.md` §4 and
`2026-10-03-ohos-three-path-baseline.md`: all three paths reach the first frame at the same
frame rhythm, AOT keeps the lowest memory (~255-287 MB vs ~330 MB, flat over 31 min), allocates
no executable memory and needs no hidden `prctl` unlock; JIT is the performance shape whose
release/production domain requires the AGC ACL
(`ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`) or a vendor exemption (the debug/inner
test signing domain gets the host JITFORT unlock by default), and the interpreter is an
experimental independent pack.

| `--runtime-mode` | what the kit carries | default kit dir / out |
|---|---|---|
| `aot` (default) | the 5 MAUI haps published with the NativeAOT recipe (`-p:PublishAot=true -p:PublishAotUsingRuntimePack=true -p:NativeLib=Shared -p:OpenHarmonyRuntimeMode=aot -p:InvariantGlobalization=true` + `OpenHarmonyUIPage`; DEVCOMPAT payload staging and static-web-asset/hybrid staging stay at their defaults). Every hap carries `libs/<abi>/lib<stem>.so` and the marker `libs/<abi>/runtime-mode.txt=aot` | `device-test-kit` / `device-test-kit.tar.gz` |
| `jit` | the previous JIT publish (marker `jit`), kept for the debug/ACL domain | `device-test-kit-jit` / `device-test-kit-jit.tar.gz` |
| `interp` | refused by the kit builder: the interpreter is an independent pack (`ohos-interpreter-pack-*.tar.gz` release asset, or `scripts/make-mode-kit.sh --mode interp --interp-pack <dir>` for a standalone variant) and never rides the main delivery kit | - |

The assembled kit carries a root-level `runtime-mode.txt` (covered by `SHA256SUMS`) whose value
is cross-checked by the shipped verifier against every MAUI hap marker, and `签名说明.txt`
states the shape, the signing-domain boundaries and the JIT ACL requirement. The hap names stay
unchanged (`hello-maui-app*.hap`) so `tester-run.sh` and the shipped docs keep working; the AOT
shape is a payload fact (`lib<stem>.so`, no `libcoreclr.so`, a 9-entry static-web-asset
`dotnet.zip`), not a rename.

`scripts/verify-kit.sh` is mode-aware: it reads each hap's marker (absent = a pre-MS-MODE
JIT kit, judged by the historical JIT contract) and applies the matching expectations - jit
15 `.so` / 258 zip entries, aot >= 3 `.so` with the `app.json`-named `lib<stem>.so` required
and `libcoreclr.so` rejected, interp the jit set plus `libclrinterpreter.so`; the payload
marker's entry-assembly check follows the shape (the aot marker names the `.dll` while the
staged artifact is `lib<stem>.so`). `scripts/selftest-verify-kit.sh` S16 covers the good AOT
kit and its mutants (missing app library, aot marker on a CoreCLR payload, unknown marker,
kit/hap mode disagreement, stripped marker falling back to JIT).

Build-time gates for the AOT switch: `--dry-run` prints the four publish commands of the
selected mode (no dotnet/SDK needed), every published hap is checked for its marker (and the
AOT app library) before it enters the kit, and the verifier's tree digest covers the
`runtime-mode.txt` annotation. The AOT publish keeps the `test/hello-maui-app/publish-aot.sh`
environment contract: `OHOS_AOT_HOOKS` (the rc.2 Exec workaround) is plumbed through when set.

## Blazor WASM ArkWeb kit component (`--with-blazor`)

`scripts/make-device-test-kit.sh --with-blazor` adds two haps to the delivery kit: the
default `hello-blazorwasm-host-unsigned.hap` and its no-CSP A/B twin
`hello-blazorwasm-host-nocsp-unsigned.hap` (FIX-BLZ-PATH), a self-contained ArkTS-only host
(the ArkWeb `Web`
component; the site under `resources/rawfile/blazor` is served through `onInterceptRequest`)
around the `dotnet publish` output of `test/hello-blazorwasm`. The publish doubles as the
offline recipe gate (`--require` turns a restore-level SKIP into a failure; x64 only, no
device/OHOS SDK needed):

```sh
sh test/hello-blazorwasm/run-smoke.sh --require --slim --out "$WORK/blazor"
sh test/hello-blazorwasm/arkts-host/pack-host.sh "$WORK/blazor/publish/wwwroot" \
    --slim --unsigned-only --out "$WORK/hello-blazorwasm-host-unsigned.hap"
sh test/hello-blazorwasm/arkts-host/pack-host.sh "$WORK/blazor/publish/wwwroot" \
    --slim --unsigned-only --no-csp --out "$WORK/hello-blazorwasm-host-nocsp-unsigned.hap"
```

Only the unsigned haps ship (bundle `com.example.opendotnet`; `--blazor-bundle <name>`
overrides it): our debug profile is bound to the example UDID, so a tester re-signs them exactly
like `hello-maui-app-unsigned.hap`. `--slim` drops the `.br/.gz/.map` siblings at embed time
and the slim publish sets `InvariantGlobalization=true` (no `icudt*.dat`); the measured cut is
~26 MB with ~213 embedded site files (210 + the 3 stable-name copies below). The pack consumes
the hvigor toolchain that `scripts/build-arkts-shell.sh` installs once per build host
(`<repo>/.arkts-build`, or `HVIGOR_JS`); without it the kit builder aborts before publishing.

The embed step also materializes the static-web-asset default names. .NET's publish
fingerprints web assets and serves the stable route `_framework/dotnet.js` from
`_framework/dotnet.<hash>.js` through the route table in
`<publish>/*.staticwebassets.endpoints.json`; the ArkWeb host serves the embedded rawfile tree
1:1, with no route table. `pack-host.sh` reads that manifest (falling back to the boot-loader
name convention when it is absent) and copies the stable JS routes (`dotnet.js`,
`dotnet.native.js`, `dotnet.runtime.js`) onto their fingerprinted assets of the same build.
Without `_framework/dotnet.js` the boot script's dynamic import fails with "Failed to fetch
dynamically imported module" and the app never renders — the defect kits #31/#32 shipped; the
kit #33 rebuild is the first with the mapping (`BLZ_BOOT`/`BLZ_RENDERED` confirm the boot
on-device).

The host page reads rawfiles through the rawfile-relative API namespace:
`getRawFileContentSync` accepts `blazor/<path>` and rejects the `resources/rawfile/` spelling.
The request validator still judges the `resources/rawfile/blazor/` boundary (SEC-SCAN-3
S3-AW1) but returns the API path (`blazor/index.html` for the shell fallback; the br/gz
variants follow), and the offline node test pins that namespace — returned values must start
with `blazor/` and never contain `resources/rawfile/` (43 checks). The SEC-SCAN-3 refactor had
returned the boundary spelling, so every read threw and the **kit #32** host answered 404
(FIX-BLZ-PATH). `pack-host.sh --no-csp` (or `BLZ_HOST_NO_CSP=1`) additionally builds the
diagnostic twin without the HTML shell's CSP header (stripped from the staged copy only): a
rendering no-CSP twin makes the CSP a contributing cause; a still-dead twin leaves the CSP out
as a blocker and points at the path fix instead. `pack-host.sh --bad-mime` (or
`BLZ_HOST_BAD_MIME=1`) is the WASM-MIME negative control (staged copy only): the twin serves
`.wasm` as `application/octet-stream`, so the device run must show Emscripten's forwarded
`wasm fallback:` warnings next to `wasm mime: ... -> application/octet-stream`. The default
build logs `wasm mime: ... -> application/wasm` with no fallback line — the application/wasm
contract (C3 in `2026-10-05-ohos-platform-limitations.md`) is therefore a device-verifiable
marker pair rather than a silent fallback.

`scripts/verify-kit.sh` asserts the component whenever the hap is present (kit #31+; a kit
without it only logs that fact): `resources/rawfile/blazor/index.html`, at least one
`_framework/*.wasm`, a `blazor.webassembly*.js` boot script, the stable
`_framework/dotnet.js` byte-equal to its `_framework/dotnet.<hash>.js` fingerprint source
(kits #31/#32 fail this one), a PANDA 13.0.1.0
`ets/modules.abc`, the `com.example.opendotnet` bundle, and no site-level `.br/.gz/.map` or
`icudt*.dat` leftovers (the host's own `ets/sourceMaps.map` compile output is not a web asset).
Every deviation FAILs; `KIT_BLAZOR_HAP`/`KIT_BLAZOR_BUNDLE` override the
name/bundle for a kit packed differently.

`scripts/tester-run.sh` v13 adds the matching device probe:

```sh
sh tester-run.sh --kit-dir ./device-test-kit --blazor-probe \
    --blazor-hap ./hello-blazorwasm-host-signed.hap      # your re-signed copy
```

The probe installs the signed hap, launches `com.example.opendotnet`/`EntryAbility`, waits 4 s
and asserts `marker: BLZ_BOOT` (window load) + `marker: BLZ_RENDERED` (Blazor first frame) from
a `hilog -x` dump; the host forwards JS errors as `marker: BLZ_ERROR <msg>`. A failure archives
`blazor/blazor-hilog.txt` + `blazor/blazor-markers.txt` in the tester report and prints the
re-sign hint. Without `--blazor-hap` the probe auto-detects a re-signed `*blazorwasm*.hap` next
to the kit (the shipped unsigned hap is the last resort, warned about up front).

The selftest surface mirrors the contract: `scripts/selftest-verify-kit.sh` S15 drives the 2c
mutants (missing index.html/wasm/boot script, slim leftovers, ICU data, wrong bundle, abc
drift, absent component) and `scripts/selftest-tester-run.sh` S21/S21b drive the probe success
and the missing-marker failure against the stub device.

## Payload in libs

The device's namespace policy allows a `dlopen` only from the app's signed bundle directory
(`/data/storage/el1/bundle/libs/arm64/` on the tester's device; the el2 data directories -
`haps/entry/libs`, `files`, `cache` - are refused). The namespace probe from the kit #22 device
round measured six candidate paths and found exactly one accepted `libcoreclr.so` load: the
bundle `libs/<abi>` directory, matching Huawei's faqs-ndk-development guidance. `hostpolicy`
and `coreclr` resolve `libhostpolicy.so`/`libcoreclr.so`/`libclrjit.so`/`libclrgc*.so` from
`app_dir` (see the previous section), so a payload extracted into the data directory cannot be
used there even though its files are readable. HAP-installed images from 7.0.0.111 on expose the
module libs under `<bundleCodeDir>/<moduleName>/libs/<abi>` (measured on HAD-W32: the host and
the staged AOT image map from `/data/storage/el1/bundle/entry/libs/arm64`), so the shell probes
that module root as well as the flat `<bundleCodeDir>/libs/<abi>` shape (see the consumer
behavior below).

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

- The ArkTS shell probes both bundle libs roots - `<bundleCodeDir>/libs/{arm64,arm,x86_64}` and
  `<bundleCodeDir>/<moduleName>/libs/{arm64,arm,x86_64}` (the module layout measured on
  7.0.0.111+, e.g. `/data/storage/el1/bundle/entry/libs/arm64`) - for the marker, the entry
  assembly (or its NativeAOT `lib<stem>.so`) and a marker naming that assembly. When they match,
  the app starts in place and the `dotnet.zip` copy/inflate is skipped (a payload an earlier kit
  extracted into `filesDir` is removed once); otherwise the shell unpacks exactly as before, P17
  marker logic included.
- `ohos_host_run_app`/`ohos_host_start_app` resolve this library's own directory through
  `dladdr` and use it as `app_dir` when `<own_dir>/<entry assembly>` exists. The outcome is
  logged as `used_own=1 own=<dir> app=<dir>` (or `used_own=0`), and the symlink bridge stays
  the fallback for haps packed without the staged payload.
- An in-place start runs the managed app before the shell page registers its web-command sink
  (the page's `registerWebSink` in `aboutToAppear`), so web commands that arrive in that window
  (the Blazor site registration and the WebView source load) are buffered in the host - bounded
  to 16 commands / 64 KiB, then dropped with one log line - and flushed on registration instead
  of being lost to the race.
- `scripts/verify-kit.sh` asserts the marker per hap: present, the named assembly staged, the
  count equal to the real `libs/<abi>/` file count, `payloadEntries == zipEntries`, and the
  recorded zip sha256 equal to the packed zip bytes. A missing or inconsistent marker is a
  FAIL, because such a hap falls back to the refused data-directory extraction.
- `-p:OpenHarmonyHapPayloadInLibs=false` restores the previous layout (payload only inside
  `dotnet.zip`, no marker), for a rollback without a source change; on an enforcing image
  (>= 7.0.0.111) it is also the second accepted layout when the device-compat rewrite is not
  used (see "Enforcing images" below).

Cost: the payload travels stored (uncompressed) inside the HAP because the packing tool keeps
`libs/**` mmap-friendly; on the reference kit the signed hap grew from ~32.7 MB to ~75.3 MB
(253 payload files, ~38.7 MB) while every other hap entry stayed byte-identical.

### Enforcing images (>= 7.0.0.111) and the device-compat rewrite

Device images from 7.0.0.111 on (measured on HAD-W24 `7.0.0.111(SP3ENTC293E104R2P1log)`, API 26)
enforce a per-file code signature for **every** `libs/<abi>/` entry at install. The per-file
enable (`CODE_SIGN` hilog domain, `EnableCodeSignForFile`) has two traps the payload-in-libs
layout can hit and the tester's 7.0.0.105 image does not:

1. An **extension-less file name** is never listed in the HAP code-sign block: the SDK
   `hap-sign-tool -signCode 1` builds its `NativeLibInfoSegment` from `libs/**` entries that have
   a file extension, so `libs/arm64-v8a/createdump` (the diagnostics ELF) is missing from the
   block while the installer counts it in `entryPathMap`. Install fails with
   `ParseNativeLibSignInfo: Libs signature not found: signMap_ size:<all>, signMapPreSize:1` →
   `enable code signature failed: 8519738` → bm `9568393 verify code signature failed`. The
   HAP-level signature itself verifies (`hap-sign-tool verify-app` succeeds) and the same hap
   installs on 7.0.0.105.
2. A file of **exactly 4096 bytes** (one fs-verity block) fails the fs-verity enable with
   `EnforceCodeSignForFile ... ret = -768` (`CS_ERR_ENABLE`), independent of content
   (4095/4097/8192-byte and `MZ`/ELF/text probes all pass; the reference payload's 4096-byte
   `Microsoft.OpenHarmony.dll` fails).

`OpenHarmonyHapPayloadInLibsDeviceCompat` controls the rewrite and **defaults to `true`**
(DEVCOMPAT-DEFAULT, 2026-10-02): the staging rewrites the **staged libs copy** of such files - an
extension-less ELF is staged as `<name>.so`, any other extension-less file as `<name>.bin`, and a
4096-byte file gets 4 zero padding bytes appended (4096 -> 4100) - so a default publish installs
on an enforcing image out of the box. Every default build states that in one status line
(`OpenHarmony payload-in-libs device compat: enabled ...`) and reports how many entries it
rewrote. The `dotnet.zip` fallback keeps the original names and bytes, the count-based marker
stays valid (the counts do not change on a rename/pad; `payloadBytes` covers the staged bytes),
and the rewrite is applied before the `OpenHarmonyCodesign` pass, so a padded ELF is re-signed.
`-p:OpenHarmonyHapPayloadInLibsDeviceCompat=false` is the escape hatch: the staged libs copy
keeps the previous names/bytes and the task logs a warning naming the incompatible staged files,
so the opt-out cannot ship silently either. Validated on the local
HAD-W24: the kit #34 JIT hap with both rewrites (rename + pad) installs, and the
`-p:OpenHarmonyHapPayloadInLibs=false` layout (payload only in `dotnet.zip`, host symlink bridge)
installs as well. The full evidence and the device-side probe recipe are recorded in the
runtime-ohos plan `docs/plans/2026-09-30-ohos-jit-payload-install-policy.md`.

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

### Hybrid bootstrap script staging (SAMPLE-FIX, 2026-10-03)

`_framework/hybridwebview.js` is not a file in the MAUI packages: it is an embedded resource of
`Microsoft.Maui.dll` (`LogicalName="_framework/hybridwebview.js"` in the slice's Core.csproj).
The managed `OpenHarmonyHybridWebViewHandler` extracts it next to the payload at runtime, which
is enough for the writable `dotnet.zip` extraction tree but not for the payload-in-libs layouts
(JIT DEVCOMPAT and NativeAOT): there the payload root is the read-only bundle `libs/<abi>/`
directory, `File.Create` fails, and the shell answers the stock script with 404 - the reason the
demo hybrid pages carried an inline transport instead.

`_OpenHarmonyStageHybridWebViewScript` (a dependency of `_OpenHarmonyStageHap`, after the Blazor
staging) closes that gap at pack time: the `OpenHarmonyExtractEmbeddedResource` task reads the
resource out of the resolved `Microsoft.Maui.dll` (`@(ReferenceCopyLocalPaths)`, then
`@(RuntimeCopyLocalItems)`/`@(ReferencePath)` fallback; the compile-time ref assembly carries no
resources) and writes it to `<PublishDir>_framework/hybridwebview.js`. The publish root maps to
the payload root in every launch mode, so the file travels in both payload copies - inside
`resources/rawfile/dotnet.zip` and under `libs/<abi>/_framework/` (nested paths preserved) - and
`<AppDir>/_framework/hybridwebview.js` is exactly the path the shell serves for the hybrid
origin. A project without `Microsoft.Maui.dll` skips the target; a package without the resource
warns (the runtime extraction remains the fallback), so the staging cannot fail an unrelated
build. The managed extraction treats an existing file in a read-only payload root as success
instead of logging an extraction failure, and keeps the previous overwrite semantics for the
writable extraction tree.

Verification: the `OpenHarmonyExtractEmbeddedResource` unit checks in
`test/openharmony-tasks-tests` (byte round-trip, idempotence, missing resource/assembly), the
`[verify] sample-fix` pins over the pack targets, the slice handler and the stock-script demo
page, and the device round in runtime-ohos
`docs/plans/2026-10-03-ohos-sample-fix.md` (hybrid C loads the stock script and drives
`window.HybridWebView.SendRawMessage`/`InvokeDotNet`).

### Blazor WebAssembly site staging (B2)

`_OpenHarmonyStageWasmSite` hosts a **published** Blazor WebAssembly site (`dotnet publish` of a
`blazorwasm` app) in any MAUI app: `-p:OpenHarmonyWasmSiteDir=<publish/wwwroot>` copies that
directory (index.html, `_framework/blazor.webassembly*.js`, `dotnet.*.js`, the wasm/ICU payloads)
into the publish payload under `wwwroot`'s sibling `wasmsite/` (`OpenHarmonyWasmSiteRoot`
overrides the name), so the hap extracts it to `<AppDir>/wasmsite`. A set-but-unusable site
directory (missing `index.html`, unsafe root) fails the build; an unset `OpenHarmonyWasmSiteDir`
leaves the target inert, so every other app's payload is byte-identical.

The app arms the shell once with
`OpenHarmonyWebViewHandler.RegisterWasmSite()` (mode `"wasm"` on the shell's `blazor`
registration): requests for `https://blazorwasm.local/` are answered from
`<AppDir>/wasmsite/<path>` with the payload MIME types, **no** Blazor Hybrid bootstrap is
injected (the site's own `_framework/blazor.webassembly*.js` boots the runtime) and the
registration does not load the origin - the `WebView.Source =
OpenHarmonyWebViewHandler.WasmSiteOrigin` load is the single load. The shell forwards the site's
`BLZ_*` console messages to hilog under the `BlazorWebHost` tag (the same verdict channel the
ArkTS Blazor host uses), and the demo `test/hello-maui-wasm` covers the end-to-end wiring.

MAUI WebView 接线（ArkWeb 六小缺口：history/frame/cookie/DOM storage/导航事件/失败清屏）与 B1 复跑
记录（含本机 rc.2 SDK 双偏差 hook、离线门禁数字）见 runtime-ohos
`docs/plans/2026-09-28-ohos-maui-webview-wiring.md`。B2 的实装/设备证据见 runtime-ohos
`docs/plans/2026-09-30-ohos-blazor-wasm-webview-b2.md`。

FIX-WVP（2026-10-01，UI-LOCAL-3）：MAUI 合成器按设备像素布局（`OpenHarmonyWindowHandler.
RequestDisplayDensity` 答复 1），壳 `frame` 命令因此收到像素值，`applyWebFrame` 用 `px2vp`
换算成 ArkUI vp 再定位/缩放；非正宽高的 frame（尚未排布的控件）被忽略、覆盖层保持上次有效
位置（初始整窗），不再被 0 高控件放大到全窗。ArkWeb `Web` 必须在 `XComponent`/`ContentSlot`
（托管表面）之后声明：Stack 后声明者在上，声明在前的覆盖层一直被托管表面盖住（页内白区）。
单覆盖层按注册仲裁：HybridWebView 已注册时，后到的 Blazor 注册只武装 origin、不重载组件，
`https://0.0.0.1/` 保持被服务（此前被 `0.0.0.0` 叠加、hybrid 页零请求）。设备证据与断言见
runtime-ohos `docs/plans/2026-10-01-ohos-webview-overlay.md`。

FIX-BACKSIZE（2026-10-01）：系统 Back 在页面的 `onKeyEvent` 之前被平台消费（FIX-DISMISS 真机
观察到窗口直接收后台），壳页面因此新增 `onBackPress(): boolean`，经 `host.backPressed` ->
`ohos_host_register_back_pressed` -> `OpenHarmonyBridge.BackPressed`（`int (*)(void)` 返回 1 =
已消费）同步询问托管抽屉处理器：FlyoutPage 把 `IsPresented` 写回、Shell 关闭 `FlyoutOpen` 并写回
`FlyoutIsPresented`，无处理器时返回 0，系统默认（收后台）不变。BlazorWebView 侧：切片编译的是
`ViewHandlerOfT.Standard`（`GetDesiredSize` 恒为 `Size.Zero`），而 BlazorWebView 是唯一没有覆写
的 web handler，期望尺寸 0x0 使其父布局排布出 0 高 frame、`PlatformArrange` 发出的 frame 被壳
的退化保护忽略（FIX-WVP）；现按 WebView/HybridWebView 的同一形状覆写（宽=约束，高上限 400）并
尊重显式 `HeightRequest`。新壳 abc 342,160 B（`ffda66da…`），宿主新增 1 个导出（150/150）。

MULTI-OVL（2026-10-02）：多覆盖层共存（上限 N=2）。壳声明两个 ArkWeb 覆盖层，由
`@Builder webOverlay(0/1)` 在 `ContentSlot` 之后实例化（slot 1 叠在 slot 0 上）；每个 web
handler 连接时从托管槽池（`Microsoft.OpenHarmony.Hosting.OpenHarmonyOverlays`，Acquire/Release、
上限 2）领一个 slot，并在命令参数首页携带它（`s<slot>` / `s<slot>\n<arg>`，另见
`OpenHarmonyOverlays.Tag/TagScript`）。壳按 tag 把 frame/load/data/show/back/forward/refresh
落到 `webControllers[slot]`，`hybrid`/`blazor` 注册各带 `slot` 字段并加载各自控制器（FIX-WVP 的
单覆盖层仲裁与其“已注册 hybrid 时 Blazor 只武装不加载”行为被移除）；页事件以 `s<slot>|state`
回传，`__OHNAV|s<slot>|<url>|<id>` 携带槽位，eval 以 `s<slot>\n<script>` 路由。全局命令
（hide/suspend/resume/cookie/cookieGet）保持无 tag，作用于全部覆盖层；无 tag 的命令/事件按
slot 0 处理（旧协议兼容）。宿主签名与导出不变（150/150）。新壳 abc 347,704 B
（`960c4c9c…`；headless 24,324 B 不变）。契约/断言见 `test/maui-platform-verify`（+4 → 559/539）
与 runtime-ohos `docs/plans/2026-10-02-ohos-multi-overlay.md`。

MULTI-OVERLAY-FULL（2026-10-02，彻底方案①）：N=2 槽池上的无限制退化与全通道正确。
托管槽池改为 owner 感知 LRU（`IOpenHarmonyOverlaySlotOwner`）：第三及以后并发的 web
控件不再拿 -1 退回旧协议，而是抢占“未 engaged 优先、其后最久未用”的槽，被抢 handler 收到
`OnOverlaySlotPreempted` 进入 suspend，恢复时按 owner 校验重新 `Acquire`、把 slot 计入注册键并
重放 load/attach（WebView 重发 Source，Hybrid 重注册并重载 `0.0.0.1`，Blazor 重注册并重载
`0.0.0.0`）；slot 只在 owner 匹配时可 Release/Touch（`Acquire(owner)/Release(slot,owner)/
Touch(slot,owner)`）。hybrid 桥状态改为按槽：`hybridBase/Root/DefaultFile/Registered/DocId[]`
与每槽 `hybridFilePath(url, slot)`/serve 日志，同页两个 HybridWebView 各自按槽注册默认文件与
文档 id，消息经 `__OHORIGIN|<url>|<该槽 id>` 路由到正确 handler。invoke 通道全链带槽且不改
宿主签名：壳发 `((slot+1)<<24)|seq` 作为 `notifyHybridInvoke` 的 requestId（与
`OpenHarmonyOverlays.EncodeInvokeRequestId` 一致），托管解码后派发到持有该槽的 handler，
`ohos_host_hwv_invoke_result` 以同一 id 回到该槽挂起的响应；未带槽的旧 id 仍走“最后注册
hybrid”回退。z-order 不再固定 slot1 在上：每槽激活序（用户 `onTouch` 或程序 show/load/注册）
经 `.zIndex(this.webZOrder[slot])` 生效，并用 `s<slot>|activate` 事件刷新托管 LRU；错误事件
的 hide 也按槽生效（`webSlotTagged`）。另修两处全通道缺口：hybrid `__hwv*` 端点接受
`Origin: <hybridOrigin>` + `Sec-Fetch-Site: same-origin` 的 fetch（CEF 把页内 fetch 报成非
main-frame，旧的 isMainFrame 门把合法 invoke 打成 400），并把 `publishAppContext` 的 appDir
解析换成与 EntryAbility 相同的 payload-in-libs 探测（此前无条件下发 `filesDir/dotnet`，让后注册
的 handler 从过期的提取树服务）。宿主签名与导出不变（150/150）。新壳 abc 356,140 B
（`2a90f0d7…`；headless 24,324 B 不变）。契约/断言见 `test/maui-platform-verify`（+4 → 563/543）
与 runtime-ohos `docs/plans/2026-10-02-ohos-multi-overlay.md`（§FULL）。

SLOTS-DYNAMIC（2026-10-03，彻底方案②）：N_max=4 的动态槽池。托管 `OpenHarmonyOverlays` 的
上限可配（`OHOS_OVERLAY_MAX`/`OHOS_OVERLAY_HOT`，默认 4/2，下限 2/上限 8）并接收壳的容量事件
（页面事件 `capacity`/`4`，切片 `OnPageEvent` 路由；容量下调会按 suspend 语义抢占超出容量的
claim）。壳不再固定声明两个覆盖层：`@State webSlots` + `ForEach` 按需实例化，热对 [0,1] 常驻；
动态槽（>=2）由托管池的 `slot ensure\n<k>` 或首个带 `s<k>` 的命令惰性创建，池 `Release` 时以
`slot destroy\n<k>` 立即销毁（省掉空闲 ArkWeb 的引擎/文档内存，重建只付一次组件+加载）；尚未
attached 的命令（frame/load/eval/注册）按槽排队，在 `onControllerAttached` 按序重放。达 N_max
仍无空槽时保持 MULTI-OVERLAY-FULL 的 owner 感知 LRU 抢占，被抢占槽的恢复重放语义不变。宿主
签名与导出不变（151/151）。新壳 abc 368,812 B（`1076a700…`；Index.ets 325,055 B /
`c29640dd…`；headless 24,324 B / `798b2477…` 不变），provenance `ee41386e…`。契约/断言见
`test/maui-platform-verify`（+6 → 584/566）与 runtime-ohos 同一计划的 §DYNAMIC。

AUTODISCONNECT（2026-10-04，KIT44 自验缺口）：**移除 web 控件自动释放槽**。MAUI 在
`Layout.Clear/Remove` 移除了项时不会 `DisconnectHandler`（Element handler 保持连接、平台子视图表
才变化，移除+重挂的状态语义由此保留），kit #44 因此复现「Remove web C 只翻标签、0 条
`web slot destroy`、C 覆盖层仍出画」。切片侧新增 `OpenHarmonyOverlaySlotWatch`（页/ContentView/
Layout handler 在 connect 时订阅元素树的 `DescendantRemoved/DescendantAdded`，断开时退订），把
失联/回归的 web 控件配对到切片本地契约 `IOpenHarmonyOverlaySlotLifetime`
（`OnOverlaySlotDetached`/`OnOverlaySlotAttached`；不放进 hosting 的
`IOpenHarmonyOverlaySlotOwner`，因为设备构建从 workload ref pack 解析该接口，新增成员需先重打
packs）：三个 web handler 在 detach 时 `Release(slot, owner)`（动态槽即 `slot destroy`）并置
`_overlayDetached`，在 attach 或重新 arrange 时按既有 restore 路径重领槽并重放
（WebView 重发 Source / Hybrid 重注册 `0.0.1` / Blazor 重注册 `0.0.0.0`），handler 本身不断开、
再次添加即重建；多级 watcher 重复回调幂等，LRU 抢占语义与槽释放顺序不变。宿主签名与导出不变
（151/151）。无需改壳（abc 仍为 SLOTS-DYNAMIC 的 368,812 B / `1076a700…`）。契约/断言见
`test/maui-platform-verify`（+3 → 587/569：动态槽 detach destroy/claim release/handler kept、
re-add ensure+注册重放、watcher/owner wiring 源钉）。

FIX-A11YBUTTON（2026-10-05，DEV-A11Y 缺口）：**壳 A11Y 自检按钮可达（有/无 web 控件两态）**。
DEV-A11Y 轮发现按钮渲染在窗口正中且被激活的 ArkWeb 覆盖层遮住（dump 中心 bounds
`[1522,987][1606,1033]`），只能经抽屉（suspend）或切 tab（hide）后点击。两个根因：①ArkUI 里
Stack 子组件的 `.align()` 只对齐组件自身内容，子组件位置由 Stack 的 `alignContent` 决定 - 按钮的
`.align(Alignment.BottomStart)` 因此不产生定位效果，落在 Stack 默认的居中位；②Web 覆盖层按激活序
取正 `zIndex`（`@State webZOrder`），而按钮 zIndex 为 0，激活后覆盖层在绘制与命中测试上都盖住按钮。
修复（壳内，两行语义）：按钮改 Edges 绝对定位
`.position({ bottom: 4 + overlayBottomInset(), left: 4 + avoidLeft })`（左下角、含避让区），并
`.zIndex(webZOrderSeq + 1)`；`webZOrderSeq` 由普通字段改为 `@State`，按钮的 zIndex 在每次 web 激活
时刷新、始终比最新覆盖层高 1。宿主/托管不变（无需改壳外代码）。四包
`preview.22/23/24/28` 同步 + provenance；新壳 abc 369,472 B（`a0dbad04…`；Index.ets 325,846 B /
`7d971a5e…`；headless 24,324 B / `798b2477…` 不变），provenance `446f9215…`，源哈希
`483af84a…`。真机（HAD-W32 / OpenHarmony-7.0.0.109）：有 web 控件（Home，`rootWebArea=2`）与
无 web 控件（no-web 变体 hap，web zone 不挂载，`rootWebArea=0`）两态 `uitest` 点按均出自我检
对话框，`accessibilityStatus: 1 (attached - expected)`、`nodeCount=1`，按钮 bounds 左下角
（重签 hap `da48f5c1…` / 变体 `dea55136…`，证据 `fix-a11ybtn/device/`）。契约/断言见
`test/maui-platform-verify`（+1：self-check 绝对定位 + zIndex 源钉，随 INTERP-DRAW2 提交并入
`c31d077`，合流 591/593 floor 573；`verify-kit.sh` 的 ui abc 期望同步为 369472）。

FIX-A11YFLYOUT + FIX-PREEMPT-RAW（2026-10-05）：①**a11y FlyoutPage 分支**（切片，maui-ohos
`OpenHarmonyAccessibility.PushChildren`）：补 `FlyoutPage.Detail`（恒入树）与 `FlyoutPage.Flyout`
（仅 `IsPresented`）两分支，镜像合成器 `ChildEnumerator`；SOAK-JI 的 `nodeCount=1` 定因即
走查止于 FlyoutPage 根（rc.1 的 FlyoutPage 非 `IContentView`）。headless 负控制（移除分支）红线；
真机 probe5 自检对话框 **nodeCount=70**（Home 内容页节点）。②**抢占原文定向导出**（壳
`pollManagedStatus`）：对 `dotnet-status.txt` 自上次轮询的新增段扫描，把
`overlay preempted/restored/replay` 行以 `[maui-capacity]` 前缀直写 hilog（文件 trim 重写时整
文件回退），CEF stderr 挤掉 60 行镜像窗不再丢行。真机低噪声复放「加 C/D/E（第 5 控件抢 A 槽）→
Activate A」取到原文：`preempted: slot 0` →（LRU 级联）`preempted: slot 1` + `restored: slot 1` +
`replay: slot 1`（`fix-a11yflyout/device2/marker-lines.txt`）。四包 preview.22/23/24/28 +
provenance 同步；新壳 abc **370,240 B（`4b439e83…`；Index.ets 326,953 B / `69dc09e0…`；
headless 24,324 B / `798b2477…` 不变）**，provenance `bb5a1758…`；`verify-kit.sh` 的 ui abc
期望同步为 370240。契约/断言见 `test/maui-platform-verify`（+2 → 593/595 floor 575）。

AOT-STARTUP（2026-10-05）：①**根因**（真机 HAD-W32，AOT Main=0 / ms）：Main→Created 31、
Created→XComponent 挂树（`AceXcomponent AttachToMainTree`）~60-90、**attach→surface 228-248**、
surface→present 12-21。等待全在 attach 后：页面 build 声明两个（隐藏的）Web 覆盖层，首个 Web 组件
实例化触发 ArkWeb/CEF 引擎初始化（`WebDelegate::InitWebViewWithSurface`→`CreateNWeb`→
`CefContext::Initialize`）同步阻塞 UI 线程 ~240 ms，XComponent 的 onLoad/surface 回调被推迟到
CEF 结束（`Root node request first frame` 后 CreateNWeb 开始，~250 ms 后才 `triggers onLoad and
OnSurfaceCreated`）。JIT/interp 同样 ~240 ms，但其托管启动更慢（等 surface≈0），只伤 AOT。
②**修复**（壳）：`@State webOverlaysMounted=false`；`ensureWebSlot`（defer/ensure 的唯一漏斗）首用
置 true（并记 `[maui] web overlays mounted on first use`）；build() 的覆盖层 `ForEach` 包在
`if (this.webOverlaysMounted)` 内。声明字面量 `webSlots=[0,1]` / `webSlotCreated=
[true,true,false,false]` 不变，ArkWeb 实例化延后到首用；未被认领的覆盖层零成本。③**宿主**
（`ohos_host_set_app_context`）：相同快照跳过 surface 重放（不同仍重放）。否则壳线程在 onLoad 的
`publishAppContext` 会在 app 线程 `register_bridge` flush 期间重入托管，JIT 死锁（`hidumper -e`
ThreadBlock6S：UI 线程在 OnSurfaceNative × app 线程在 OhosHostBindAndFlushBridge；提前的 surface
把这条老竞态从潜在变成必现）。④**真机 A/B**（同载荷换壳/宿主重签，冷启，AOT 3+3）：AMS→首帧
**796→534（−262 ms）**、Main→首帧 386→149（−237）、attach→surface 239→14；clean 壳复核 534；
JIT 1118→1098、interp 1331→1278（不回归，JIT 新宿主 0 次 THREAD_BLOCK；首帧后 3-10 ms 挂覆盖层、
hybrid 注册/装载照常）。⑤四包 preview.22/23/24/28 + provenance 同步：ui abc **371,860 B
（`88f7c64b…`；Index.ets `2192ab68…`；headless 24,324 B / `798b2477…` 不变）**、provenance
`33f23c87…`；宿主源码 `openharmony_host.c`（`85a071b8…`，本机重建 297,888 B / `7a4984bd…`，
导出 151 不变）。契约/断言见 `test/maui-platform-verify`（+1：覆盖层首用挂载门 + 条件顺序钉）。

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

The branch changes exactly five things: the SDK root comes from `ARKTS_HARMONY_SDK_ROOT` /
`DEVECO_SDK_HOME` (must carry `<root>/default/openharmony/ets` and `<root>/default/hms/ets`, or the
build fails with the property to set), `runtimeOS` becomes `HarmonyOS`, `compatibleSdkVersion`
defaults to `6.1.0(23)` (override with `ARKTS_COMPATIBLE_SDK_VERSION`) - the value the device-side
DevEco build used to emit the accepted abc - the UI variant additionally copies the Map overlay
module `templates/ets/map/MapOverlay.ets` into the project (R2-3 2026-09-26), and the UI variant
rewrites its `Index.ets` copy through `patch_harmony_index_ets` to import that module statically
(MAPFIX 2026-09-28). The static import is what puts the overlay into hvigor's compile graph:
a copied-but-unregistered module resolves nowhere, and HCI-HARMONY-CI measured exactly that
(the abc had no `entry/ets/map/MapOverlay` record and the overlay could only answer capability
bit 1 = 0; forcing the module into the graph by hand first exposed
`10505001 Expected 0 arguments, but got 1` at `MapOverlay.ets:135`, an implicit no-argument
`NodeController` base constructor the proxy passed a `UIContext` to - fixed by taking the
framework `UIContext` in `makeNode` instead). `externalApiPaths` additionally exposes `hms/ets`,
which is what lets the Share/Scan/Map/Live View/CoreSpeech probes and the Map overlay compile
against the real kit types. The abc header gate is unchanged: `ARKTS_MAX_BC_VERSION` stays
`13.0.1.0` (the device runtime ceiling; the DevEco build at `6.1.0(23)` produced exactly
`13.0.1.0`), so a HarmonyOS SDK whose es2abc emits a newer abc still fails here. The emitted
harmony ui abc is gated too: `check_harmony_overlay_abc` (offline twin `--check-overlay-abc`)
requires the `entry/ets/map/MapOverlay` module record plus the compiled
`mapOverlayView`/`markerClick`/`cameraIdle` symbols, so the overlay cannot silently drop out of
the graph again. On the default flavor the shell compiles the Share/Scan *probe* only: the
specifier stays in a variable and the resolved module is cast to a local structural interface, so
a device without the kit registers no sink and the managed side degrades (see the KIT-IMPL report
in `runtime-ohos/docs/plans/2026-09-24-ohos-kit-gap-analysis.md`). The Map overlay follows the
same rule: the default flavor never copies `MapOverlay.ets` and its `Index.ets` source stays
byte-identical (only the harmony branch rewrites its project copy), so the page's dynamic
`./map/MapOverlay` import fails at runtime there and the Map sink reports capability bit 1 = 0.

The branch is scaffold-verified (`--scaffold-only` plus the selftest T14/T17/T18) and was
**re-verified with the overlay compiled on 2026-09-28** with the public DevEco command-line-tools
bundle 6.0.1.251 (HarmonyOS 6.0.1 Release, API 21): `Finished :entry:default@CompileArkTS`, ui
abc `291,628 B / sha256 a637a5136681b803186969ca2753a439735e35bf41c752d1849cbec2a482487b`, abc
version `13.0.1.0`, 0 ArkTS errors, every payload literal, and `ark_disasm` shows the module table
record `.record com.example.hellomauiapp.entry.ets.map.MapOverlay` next to `entryability.EntryAbility`
and `pages.Index` (the earlier R2-3/Live View build reported `263,784 B / d3a7b718...`, which had
no overlay record). There are two supported routes.

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

**CI gate.** `.github/workflows/harmony-flavor.yml` compiles this branch (ui variant) on manual
dispatch, weekly (Monday 03:17 UTC) and pushes to master that touch the flavor surface
(`packs/**/templates/ets/map/**`, `scripts/build-arkts-shell.sh`, `scripts/setup-harmony-sdk.sh`,
or the workflow itself); PRs and other pushes stay excluded because the sha256-pinned
command-line-tools archive is ~2.0 GiB, so it is cached by that sha (`actions/cache`) and a cold
run pays the download while repeat runs only unpack. The job fails red on a download/SDK
verification failure, any ArkTS error, an abc header other than `13.0.1.0`, a missing
Map/Live View/CoreSpeech or payload-in-libs literal, a missing Map overlay module record or
compiled overlay symbol (`HARMONY_REQUIRE_MAP_OVERLAY=1`; MAPFIX 2026-09-28 turned the former
WARN into an enforced gate), or a missing provenance record; the abc and
`harmony-abc-provenance.json` are uploaded as `harmony-abc-<run id>`. The provenance records the
overlay probe (record present, per-symbol presence) alongside the literals and the compile log, so
a regression is visible even before the gate reads it.

**First runner results (2026-09-28, commit `6ce1ec1`).** The push that added the paths trigger ran
`36369308089` (success, 2m55s; cold: cache miss, 2010 MiB hf-mirror download in ~95 s at ~21 MB/s,
unpack ~46 s, `Finished :entry:default@CompileArkTS` in 6 s 74 ms, all 14 literals and the Map
overlay record + 3 symbols present, abc 331,336 B / `34b0a046...` @13.0.1.0, arktsErrors 0,
provenance gate=pass; the cache was saved after the job, 2,048,389,122 B). A manual dispatch on
the same commit (`36369863335`, success, 1m48s) restored that cache (no download, unpack ~50 s)
and reproduced the abc byte-for-byte (`34b0a046...`). The abc is larger than the aarch64
rehearsal's 291,628 B / `a637a513...` pin for the same templates because that host swaps in the
OpenHarmony SDK's arm64 `es2abc` (see Host notes); the gates assert version, literals and the
module record, not byte size.

For the tester machine (DevEco Studio + HarmonyOS SDK) the shortest path is Route A with the
IDE's SDK and hvigor; the existing DevEco fallback still works (create an empty project, copy
`entry/src/main/ets/{entryability,pages,map}` over its sources, `hvigorw assembleHap`, feed the
abc back via `-p:OpenHarmonyArktsModulesAbc`). Expected evidence: the `CompileArkTS` finish
line, abc version `13.0.1.0`, non-zero size, the payload literals (`--check-abc`).

The branch's abc is also shipped as a **packaged HAP variant**: `harmony-haps.tar.gz`
(196,898,796 B / sha256 `9b0506fa...`, re-cut 2026-09-28 on the `device-test-kit` release beside
the kit; the replaced set was 196,118,871 B / `f7a4faa2...`) carries the same five-hap matrix as
`scripts/make-device-test-kit.sh` (26.0/20.0 x optional permission set + unsigned) rebuilt with
`-p:OpenHarmonyArktsModulesAbc=dist/ets/modules.harmony.abc`; only that property differs from the
kit build. Measured with the overlay compiled (MAPFIX): all five haps carry the harmony abc
(291,628 B / `a637a513...`, PANDA `13.0.1.0`) including the `entry/ets/map/MapOverlay` module
record and the `mapOverlayView`/`markerClick`/`cameraIdle` symbols, and pairwise against a control
set built from the same commit without the abc override the only differing file is
`ets/modules.abc` (`module.json` byte-equal to the kit #29 haps, `libs/arm64-v8a` 269 = 14 `.so`
plus 254 payload entries and the marker, in-hap host 285,600 B / `5248c6a9...`, `.codesign` on
all 14 `.so`);
`scripts/verify-harmony-haps.sh <harmony-haps> <control-haps>` reports 102/102 and the kit's
`verify-kit.sh --expected-abc 291628` reports KIT OK. The previous cut (263,784 B / `d3a7b718...`)
was copied but never compiled - its README's "MapOverlay.ets compiled" claim was wrong, and the
overlay could only answer capability bit 1 = 0. This is the only packaged shell with a compiled
`MapOverlay.ets` / LiveView sinks, so its real-device prerequisites are the AGC rows below (map
service + signing fingerprint; Live View TIMER entitlement + device switch); the default-flavor
kit haps keep `281,052 B / 5c06143a...` and `IsOverlayAvailable=false`.

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
`Stack`). `pages/Index.ets` keeps its variable-specifier dynamic import of `'./map/MapOverlay'`
for the default flavor (the module is never copied there, so it fails at runtime and bit 1 stays
0); the harmony build's `patch_harmony_index_ets` step rewrites its project copy to import the
module statically (`../map/MapOverlay`) and take the proxy constructor directly, so hvigor
registers the module and the probe never depends on runtime module resolution. Either way the
page casts the module to local structural interfaces and mounts a `NodeContainer` only while the
managed side created the overlay. The managed side drives it through `OpenHarmonyMap` (create/
show/hide/destroy/region/marker plus the ready/marker-click/camera-idle events) and every call
first checks the availability bits.

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
the log pair) and the runtime mode switch
(`ms-mode`: the `runtime-mode.txt` parser/precedence, the aot fallback and the pack staging
contract),
while `scripts/build-arkts-shell.sh` keeps the abc at
`13.0.1.0`, carries the `./map/MapOverlay`, `registerLiveViewSink`, `notifyLiveViewResult`,
`@kit.LiveViewKit`, `SystemCapability.LiveView.LiveViewService`, `registerTtsSink`,
`notifyTtsResult`, `@kit.CoreSpeechKit`, `SystemCapability.AI.TextToSpeech`,
`notifyTextComposition`, `notifyAnimationReduce`, `@kit.AccessibilityKit` and
`SystemCapability.BarrierFree.Accessibility.Core` literals
in the UI abc plus the common `notifyActivation`/`onNewWant` activation literals (both variants;
the provenance gate; current default-flavor UI abc 281,052 B /
`5c06143a...`, headless 20,916 B / `54a1a201...`) and enforces
the source contract (no `@ohos.*` imports, variable kit specifiers). The host-side gate is
`scripts/build-host.sh` (nm -D: all 143 `host-exports.txt` names present as plain symbols) plus
`scripts/check-host-exports.py --cross-check`; the interaction suite's own contract line is
`[suite] checks=391 total=391 floor=371 assert=True` (the 4 MS-MODE runtime-mode checks, the
10 P2c-DEEPLINK activation checks, the
4 P2b-IMG image checks and the 16 P1b-LIST list checks on the 357/337 P1a-ANIM base).

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
- **Current state (P2c-DEEPLINK, 2026-09-27)**: all three preview packs carry the same sources
  (Share/Scan/Push/Account/Map/Live View/CoreSpeech probes, HUKS-first SecureStorage,
  kit-import migration, feature permission chain, IME composition, the animation-reduce
  observation and the want/activation plumbing) and the abc rebuilt from them
  on the OpenHarmony SDK: UI 281,052 B / sha256
  `5c06143a727dff8e534e357299278f22e3e49ae97419615b113b8d7053a417c7`, headless 20,916 B / sha256
  `54a1a2011cca4a96772b0ed9f99b36ddd7b655fde1e681676669f78ed8138bbb`, both abc version 13.0.1.0
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
covers `ohos_host_draw_image_bytes_sized` in the 143-name contract;
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

### Deep links / activation (P2c-DEEPLINK)

A want (a custom-scheme `app://host/path?query` deep link, an `https://` app link or an
`ohos.want.action.viewData` uri) enters through the ability and reaches managed navigation. The
four decision points:

- **Cold start**: `onCreate` stores the launch want; `bootstrap()` publishes it through
  `host.notifyActivation(payload)` *before* `startApp`. The host queues the payload until the
  managed activation thunk registers (the runtime is still loading) and flushes it on
  registration, so the want cannot race the launch. The payload carries `uri`, `action`,
  `parameters` (the want's parameter record as a JSON string) and the packaging's `linkHosts`.
- **Warm activation**: `onNewWant` forwards a later want through the same NAPI method while the
  app runs; a want that lands before bootstrap published the cold one replaces the pending slot,
  so the app always sees exactly one activation. The shell increments a per-want `sequence`; the
  managed side drops re-delivered or stale sequences and preserves arrival order.
- **Routing**: `OpenHarmonyAppLinks` (maui-ohos) maps `app://host/path?query` to
  `//host/path?query`, and an `https://` link to `//path` only when the host is in the allow-list
  (seeded from app.json `linkHosts`, extendable through `AllowedHttpsHosts`); everything else is
  rejected with a status line. The route goes through `Shell.GoToAsync`, so the existing
  `Navigating` approval chain governs it: a canceled navigation is detected (the current page did
  not move) and recorded, never half-applied; a request that finds no Shell/NavigationPage yet
  stays queued and is retried when the app host reports the window ready. Without a Shell, a
  route registered with `Routing.RegisterRoute` is pushed onto the live `NavigationPage`; an
  unresolved route is ignored with a status line. No path throws into the shell callback.
- **Host manifest / app-link declaration**: `OpenHarmonyAppLinkHosts` (`;`-separated, for example
  `example.com;www.example.com`) is one property feeding both declaration sides of the contract,
  so they cannot drift:
  - `resources/rawfile/app.json` `linkHosts` - the list the ArkTS shell forwards with every
    activation and the managed side enforces (`OpenHarmonyAppLinks.AllowedHttpsHosts` is seeded
    from it and is extendable at run time);
  - `module.json` `abilities[0].skills[].uris` - the app-link skill element
    `OpenHarmonyGenerateModuleJson` appends:
    `{"entities":["entity.system.browsable"],"actions":["ohos.want.action.viewData"],
    "uris":[{"scheme":"https","host":"example.com"},{"scheme":"https","host":"www.example.com"}],
    "domainVerify":true}`. The first (home) skill element stays untouched; hosts are trimmed and
    de-duplicated, and an invalid host (letters/digits/`.`/`-` only, at least one dot) fails the
    build. `domainVerify` comes from `OpenHarmonyAppLinkDomainVerify` (default `true`: the AGC
    App Linking domain gate, expected once the hosts are registered; pass `false` to declare the
    uris before registration). Unset `OpenHarmonyAppLinkHosts` keeps both files at their previous
    bytes - the generated `module.json` stays byte-identical.
  The system delivers an `https://` link only when the signature matches the AGC registration, so
  a self-signed/debug hap still needs an explicit want (`aa start -U`) for the managed route; the
  declaration is locally verifiable (`scripts/selftest-tasks.sh` unit checks +
  `scripts/selftest-hap-targets.sh` T1/T2/T3 fixtures assert the skill bytes and the invalid-host
  rejection, and the T9 fixture stages + packs a real hap offline and asserts the packed
  `module.json` uris/`domainVerify` and `resources/rawfile/app.json` `linkHosts` against the
  `OpenHarmonyAppLinkHosts` property).

Gates: the interaction suite's ten P2c checks pin the shell sources (all three packs
byte-identical), the NAPI method and both C exports, the bounded host queue, the hosting
event/parse and every managed decision point (malformed uri, https allow-list, unknown route,
sequence de-duplication, cold-start pending, Shell approval);
`scripts/build-arkts-shell.sh` keeps the `notifyActivation`/`onNewWant` literals in both variants
and the provenance gate pins the current abc (UI 281,052 B / `5c06143a...`, headless 20,916 B /
`54a1a201...`); the nm export gate covers
`ohos_host_notify_activation`/`ohos_host_register_activation` in the 143-name contract. On-device
`onNewWant`/app-link delivery still needs device verification (the manifest declaration is now
generated and locally asserted).

### WebAuthenticator redirect callbacks (WEB-AUTH)

`Microsoft.Maui.Authentication.WebAuthenticator` (`OpenHarmonyWebAuthenticator` in maui-ohos) runs
the OAuth redirect flow on top of the same activation channel: `AuthenticateAsync` opens
`options.Url` in the external browser through the ability bridge
(`ohos.want.action.viewData`, the Launcher/Browser path) and completes when the redirect want
reaches the managed side (`onNewWant`/cold-start `onCreate` -> `host.notifyActivation` ->
`OpenHarmonyBridge.Activation`), matching the callback route with the MAUI rules
(scheme/host case-insensitive, effective port and a non-root path exact) and parsing the callback
URI through `WebAuthenticatorResult` (query + fragment, `IWebAuthenticatorResponseDecoder`
honoured). Cancellation is the caller's token (MAUI has no built-in timeout), a failed browser
hand-off throws `InvalidOperationException`, and a host without the ability bridge keeps the
documented `FeatureNotSupportedException` degrade. A `form_post` response and
`PrefersEphemeralWebBrowserSession` are not representable (only a URI redirect can reach the
app; `startAbility` has no ephemeral-browser knob) and are noted once per process.

The redirect needs the app's callback route declared in the manifest:

- `OpenHarmonyWebAuthenticatorCallbackUrls` (`;`-separated, for example
  `myapp://callback;otherapp`) appends one browsable/viewData skill element with one uri per
  route to `module.abilities[0].skills`: a full absolute URL contributes scheme + host (+ an
  explicit port), a bare scheme a scheme-only uri. Routes are trimmed and de-duplicated; an
  invalid route, an invalid host or a missing `abilities[0].skills` array fails the build.
  Unset keeps the generated `module.json` byte-identical. When both
  `OpenHarmonyAppLinkHosts` and the callback routes are set, both elements travel in one
  insertion at the skills bracket (order: app-link element, then the callback element), so the
  generated bytes stay deterministic.
- On-device, the browser's redirect to `myapp://callback?...` is dispatched by the system to
  that skill and comes back through the shell as a want; `aa start -U "myapp://callback?..."` is
  the equivalent explicit want for a local round-trip test.

Gates: `scripts/selftest-tasks.sh` unit checks cover the route forms, de-duplication, the
combined insertion and the negative paths; `scripts/selftest-hap-targets.sh` T10 stages and packs
a real hap offline and asserts the packed callback skill next to the app-link skill; the
interaction suite drives the managed flow off-device (see the WebAuthenticator section in
`test/maui-platform-verify/README.md`).

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
    -p:OpenHarmonyUIPage=pages/Index \
    -p:OpenHarmonyHapPackage=true -p:OpenHarmonySdkRoot=$OHOS_SDK
```

- **The UI shell is mandatory and shared with the JIT route: `-p:OpenHarmonyUIPage=pages/Index`.**
  Set, the pack writes `resources/base/profile/main_pages.json` and stages
  `templates/ets/modules.ui.abc` (the ArkTS shell with `XComponent` + `loadContent`); unset, it
  stages the headless `templates/ets/modules.abc` and an empty `main_pages.json`. An AOT publish
  without the property produces a hap with no ArkUI content at all: the MAUI window stays white
  and WMSDecor logs `IsHitTitleBar: uiContent is null`, at the same time the app process, its
  .NET threads and its `start_app` call all look healthy. That is the aot-haps v1/v2 defect,
  fixed by the v3 rebuild (`test/hello-maui-app/AOT.md`; evidence in
  `runtime-ohos/docs/plans/2026-09-29-ohos-local-device-test-runbook.md` §5).
  `scripts/make-device-test-kit.sh` carries the property for every mode (the kit is AOT by
  default since AOT-DEFAULT; `--runtime-mode jit` keeps the JIT kit); `scripts/make-mode-kit.sh
  --mode aot` defaults it unless `--property OpenHarmonyUIPage=<page>` overrides it.

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
  deterministic; no deps.json is shipped. `DebugType=none` keeps a rebuild byte-identical across
  the rc.2 SDK builds (`.109`/`.112`): the portable PDB identity (CodeView GUID, PDB checksum,
  debug-entry timestamp) was the only byte drift, and no PDB is shipped, so the
  `scripts/selftest-tasks.sh` S3 pack gate compares the sources, not the compiler build.
- **Distribution**: `scripts/prepare-packs.sh` builds it and copies it into
  `packs/Microsoft.OpenHarmony.Sdk/<version>/tools/`. The pack targets load it with
  `UsingTask AssemblyFile="$(MSBuildThisFileDirectory)../tools/Microsoft.OpenHarmony.Tasks.dll"`.
  The DLL is committed into all three preview packs (the pack targets must stay byte-identical), and
  `scripts/lint-packs.sh` fails the pack lint when a `UsingTask` reference does not resolve to a file
  the pack actually ships.
- **Tests**: `test/openharmony-tasks-tests/` runs the six classes with a stub `IBuildEngine` (138
  checks: zip determinism/ordinal order/fixed timestamp/skip names, runtime-ELF staging, payload
  staging layout, payload-marker schema + escaping, feature-permission matrix/request-point/strict
  mode, module.json substitution/escaping/insertions/negatives and the app-link skill insertion
  (`OpenHarmonyAppLinkHosts` -> `skills[].uris` + `domainVerify`, invalid/empty host and missing
  anchor negatives)). `scripts/selftest-tasks.sh` builds
  the assembly and the test host, runs the suite, and fails when the committed pack copies drift from
  the freshly built Release assembly (re-run `scripts/prepare-packs.sh`); it is part of the
  `scripts/preflight.sh` repository gates. `scripts/selftest-hap-targets.sh` T1 additionally pins
  the six `UsingTask` entries, the app-link parameter wiring and the absence of inline code, and its
  T2/T3/T5 fixtures run the compiled tasks through the real pack targets.

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

**Concurrent checkouts.** When several agents share one working tree, never `git add -A`; commit
only the paths you own through `sh scripts/commit-paths.sh -m "<message>" -- <path>...`, which
refuses a path with no changes, aborts (restoring the index) when the staged set picks up another
agent's files, and prints the plan with `--dry-run`.

## Known environment quirks

Two host quirks of this OpenHarmony sandbox surface as dotnet "environment failures". Both are
absorbed by `scripts/lib-dotnet-env.sh`, which every script that invokes dotnet sources before
its first call (`preflight.sh`, `devloop.sh`, `prepare-packs.sh`, `make-device-test-kit.sh`,
`make-mode-kit.sh`). The lib defaults (only while a variable is unset or empty, so an operator
can override any of them) `DOTNET_CLI_USE_MSBUILD_SERVER=0` (the switch
this SDK reads), `DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER=1` (the documented name; harmless where
the SDK ignores it), `MSBUILDDISABLENODEREUSE=1`, `DOTNET_CLI_TELEMETRY_OPTOUT=1`,
`DOTNET_NOLOGO=1`, and points `TMPDIR`/`TMP`/`TEMP` at a usable scratch dir (the caller's
`TMPDIR`, else `$DOTNET_ENV_TMPDIR`, else `/data/storage/el2/base/tmp/opencode/t`, else
`<repo>/.tmp`). A candidate whose estimated server socket path (`$TMPDIR/MSBuildServer-<hash>`,
58 characters more) would exceed 100 characters is refused with a warning when a shorter
candidate is usable; the first usable candidate is kept when none fits. The "env hardening"
section of `scripts/selftest-devloop.sh` asserts the defaults, the fallbacks, the length guard
and the environment a real devloop run hands to the dotnet child.

### `/tmp` refuses AF_UNIX sockets, so the MSBuild server cannot start

`/tmp` is its own `hmfs` mount here; ordinary files can be created by this user, but `bind(2)`
on an `AF_UNIX` socket is rejected:

```text
$ mount | grep ' /tmp '
/dev/block/platform/b0000000.hi_pcie/by-name/userdata on /tmp type hmfs (rw,nosuid,nodev,...)
$ stat -c '%U:%G %a' /tmp
1076:expert 2770
$ python3 -c 'import socket; socket.socket(socket.AF_UNIX).bind("/tmp/probe.sock")'
OSError: [Errno 13] Permission denied        # the same bind succeeds under /data/storage/...
```

dotnet's MSBuild server and its reusable nodes talk over named pipes, which on Unix are
`AF_UNIX` sockets at `$TMPDIR/MSBuildServer-<hash>`. With `TMPDIR=/tmp` the CLI cannot reach the
server and falls back:

```text
MSBuild server unavailable: the current server state could not be determined. Falling back to an in-process build.
```

A writable but long `TMPDIR` is a second form of the same failure: the server process dies on
the 108-character domain-socket path limit (the client then waits out its connection timeout),
leaving `$TMPDIR/MSBuildTemp*/MSBuild_pid-*.failure.txt`:

```text
System.ArgumentOutOfRangeException: The path '.../MSBuildServer-...' is of an invalid length for use with
domain sockets on this platform. The length must be between 1 and 108 characters, inclusive.
```

`/data/storage/el2/base/tmp` (84 characters for the socket path) and the default
`/data/storage/el2/base/tmp/opencode/t` (95) stay under the limit and accept sockets; `/tmp`
does not. The guard refuses a writable but over-limit candidate (the measured 108-character
`.../opencode/env-harden/tmp` scratch) and falls back to the short default with a warning. A
`TMPDIR` that does not exist fails the build outright (`MSB1025`, `CreateTempSubdirectory`),
which is why the lib creates the directory it selects.

This is the failure behind kit #30 preflight run 2: the pixel step's `dotnet run -c Release`
internal build printed the server line, waited ~5 minutes and then reported `The build failed`
with `0 Error(s)` - no compiler error, a host wedge (the same tree passed the step in 87 s on
the next run). `scripts/preflight.sh` now retries once automatically with the workaround that
used to be applied by hand (`dotnet build -c Release --no-restore -m:1`, then executing
`bin/Release/net11.0/headless-render.dll`), keeping both attempts as `pixel.log` and
`pixel-fallback*.log`; with the hardened environment the retry should not trigger.

The fallback path itself was exercised by hand on 2026-09-28 (`pixel-guard/pixel-run2.log`):
`dotnet build -c Release --no-restore -m:1` (56 s) plus running `headless-render.dll` (14 s, rc=0)
finished in **70 s total** and printed `PIXEL ASSERTIONS PASSED` (2,399,269 pixel writes; the two
tracked `[KNOWN]` items unchanged), so the retry workaround is proven end-to-end.

### `dotnet restore` wedging in an idle FUTEX wait

An earlier session recorded `dotnet restore` hanging for more than 5 minutes in an idle FUTEX
wait (with nuget.org and with a local-only source, clean `obj/`), while `dotnet build
--no-restore` plus executing the built dll worked - that workaround is the fallback above. It is
the same server handshake wait: the CLI waits for a server that cannot come up. With
`DOTNET_CLI_USE_MSBUILD_SERVER=0` / `MSBUILDDISABLENODEREUSE=1` and a usable `TMPDIR` the CLI
stays in-process, so restore does not enter the wait (an offline `dotnet restore` under
`TMPDIR=/tmp` with the opt-outs completes in ~3 s and prints no server line; the MSBuild server
defaults on and off, `DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER=1` alone does not stop this SDK's
11.0.100-rc.1 from attempting it).

## Known follow-ups (scheduled)

- **Functional clean regression**: the FileWrites registration is gated statically (the interaction
  suite and `eng/ohos-install/tests/test-codesign-filewrites.sh`); a `dotnet clean` run over a real
  publish (device kit or a stub-toolchain fixture) is scheduled with RELEASE-25, together with the
  SDK rebuild that carries the codesign-stamp registration.
- **RID graph CI pin**: `scripts/sync-ridgraph.sh` single-sources the pack copies from
  `sdk-ohos/eng/PortableRuntimeIdentifierGraph.openharmony.json`; the cross-repo gate
  (`.github/workflows/ridgraph-sync.yml`) pins the sdk-ohos commit `97cad7c59a` and must be bumped
  in lockstep with the sync whenever the canonical graph changes.
