# hello-blazorwasm — Blazor WebAssembly on the OpenHarmony SDK

A minimal Blazor WebAssembly app plus the ArkTS ArkWeb host that embeds its publish output into
an OpenHarmony hap. Two steps, one project:

```sh
test/hello-blazorwasm/run-smoke.sh                    # publish the site with the workload SDK
test/hello-blazorwasm/arkts-host/pack-host.sh <site>  # pack + sign the host hap around it
hdc install test/hello-blazorwasm/arkts-host/out/hello-blazorwasm-host-signed.hap
aa start -b com.example.opendotnet -a EntryAbility
```

The host page serves the site from `resources/rawfile/blazor` through
`Web.onInterceptRequest` (no local HTTP server, no network permission) — the same asset-serving
pattern the in-product HybridWebView/BlazorWebView bridge uses. See `arkts-host/README.md`.

## Why the recipe is needed

- The workload's runtime line is `11.0.0-rc.1.26451.109`; the fork's rc.1 Blazor/WebAssembly
  packages are **not** on nuget.org, while the dnceng public `dotnet11` feed carries the rc.2
  flights. `NuGet.config` adds the feed and the project pins the flight
  (`BlazorFlightVersion`, default `11.0.0-rc.2.26459.117`).
- `Directory.Build.targets` moves the `Microsoft.NET.Sdk.WebAssembly.Pack` and
  `Microsoft.AspNetCore.App.Internal.Assets` known-pack versions to that flight;
  `RuntimeFrameworkVersion` follows in the csproj (a command-line `-p:` still wins).
- SDKs without the MSBuild named-pipe fix (sdk-ohos `eng/ohos-install/build/msbuild-pipe-patch`)
  cannot start a task host on OpenHarmony: `/tmp` refuses AF_UNIX binds, every task host dies,
  MSBuild retries 30s x5 and fails with MSB4216; the Roslyn compiler server has the same
  problem (20s then an in-process fallback). `run-smoke.sh` retries with the in-process task
  overrides (`-p:OhosTaskHostOverride=true`) when the first publish hits it. An SDK carrying
  the fix (sdk-ohos `feature/openharmony`, 2026-09-28) passes the first run without overrides.
  Root cause and evidence: runtime-ohos
  `docs/plans/2026-09-28-msbuild-taskhost-pipe-rootcause.md`.

## Publish

```sh
test/hello-blazorwasm/run-smoke.sh                   # untrimmed (~52 MB site); prints the path
test/hello-blazorwasm/run-smoke.sh --trim            # ILLink pass (needs the rc.2 ILLink runtime)
test/hello-blazorwasm/run-smoke.sh --slim            # InvariantGlobalization: drops ICU (~47 MB)
test/hello-blazorwasm/run-smoke.sh --require         # CI mode: a restore SKIP becomes a failure
test/hello-blazorwasm/run-smoke.sh --skip-publish    # verify an existing out/publish only
```

Without `--require`, a publish blocked at restore (feed or pack unavailable) prints `SKIP` and
exits 0, mirroring `test/aot-smoke/run-smoke.sh`.

`--trim` runs ILLink as `Microsoft.NETCore.App 11.0.0-rc.2.26459.117`; a device carrying only
the rc.1 runtime directory needs that rc.2 runtime installed (or the temporary directory copy
from runtime-ohos `docs/plans/2026-09-28-blazor-wasm-on-device-feasibility.md`).

## Host hap

`arkts-host/pack-host.sh <site-dir>` stages `arkts-host/project/`, embeds the site under
`entry/src/main/resources/rawfile/blazor` — materializing the stable static-web-asset names
(`_framework/dotnet.js`, `dotnet.native.js`, `dotnet.runtime.js`) from their fingerprinted
`<name>.<hash>.js` assets per the publish's `*.staticwebassets.endpoints.json` route table,
because the host serves the rawfile tree 1:1 with no route table — builds with hvigor, packs
with the SDK's `ohos_packing_tool` and signs with `hap-sign-tool` (debug material from the
SDK). Output: `arkts-host/out/hello-blazorwasm-host-signed.hap` (~70 MB with the full site).

Two flags serve the device-test kit variant (see `../../docs/blazor-arkweb-kit-handoff.md`):

```sh
test/hello-blazorwasm/arkts-host/pack-host.sh <site> --slim --unsigned-only
# --slim            drop .br/.gz/.map at embed time (the host serves the uncompressed copies)
# --unsigned-only   stop after packing: hello-blazorwasm-host-unsigned.hap for external signing
# measured: --slim embed of a --slim publish = 213 site files (210 + the 3 default-name copies),
# 26 MB unsigned hap (0 compressed leftovers, 0 ICU), and the hap re-signs cleanly with
# hap-sign-tool sign-app + verify-app
```

`--no-csp` (or `BLZ_HOST_NO_CSP=1`) builds the diagnostic A/B twin without the HTML shell's
`Content-Security-Policy` header (staged copy only; the default keeps the CSP). Run the pair
on a device: a rendering no-CSP twin makes the CSP a contributing cause; a still-dead twin
leaves the CSP out as a blocker (then check the `blazor/<path>` rawfile read path, FIX-BLZ-PATH).

The bundle name defaults to `com.example.opendotnet`; change it with `--bundle`, and sign with
your own material via the `SIGN_*` environment variables when the device does not trust the
OpenHarmony debug root.

## Markers (machine-readable pass criteria)

`wwwroot/index.html` logs `BLZ_BOOT` on window load and `BLZ_ERROR <message>` on script errors;
`Pages/Home.razor` logs `BLZ_RENDERED` after the first render (proof that the WASM runtime
executed .NET code). The ArkTS host forwards every `BLZ_*` console message to hilog, so a
tester checks:

```sh
hilog | grep BlazorWebHost        # expect marker: BLZ_BOOT and marker: BLZ_RENDERED
```

## Verified

2026-09-28, OpenHarmony arm64 device, sdk-ohos `feature/openharmony` (statically linked
OpenSSL SDK, MSBuild pipe patch included):

- publish: default = 642 files / 52 MB; `--slim` = 633 files / 47 MB (ICU dropped);
  trimmed (with the ILLink override) = 753 files / 71 MB; `dotnet build` of a Blazor WASM app
  succeeds with **no task-host retries** on the patched SDK.
- host hap: CompileArkTS, `ohos_packing_tool` pack and `hap-sign-tool sign-app` +
  `verify-app` all pass; the embedded site contains the 899 rawfile members (full variant).
- kit variant: `--slim --unsigned-only` = 213 site files (210 + the 3 default-name copies),
  **26 MB unsigned hap**, no `.br/.gz/.map`, no ICU; the hap re-signs and verifies (26.8 MB
  signed). The FIX-BLZ-JS rebuild carries `_framework/dotnet.js` byte-equal to
  `dotnet.08s0yny1y1.js` (sha256 `25ef2fa5…317c`); kit #31's hap (`36010a9c…ae2e`) predates
  the mapping and lacks it.
- ArkWeb rendering reached the device-test kit: kits #31/#32 rendered nothing because the
  embedded site lacked `_framework/dotnet.js` (the boot script's dynamic import failed:
  `BLZ_ERROR Failed to fetch dynamically imported module`). A manual copy of the fingerprinted
  asset rendered the app (`BLZ_RENDERED`); the embed step now does that for every build, and
  the kit #33 rebuild is the first shipped hap with the mapping. Hand-off spec:
  `../../docs/blazor-arkweb-kit-handoff.md`.
- FIX-BLZ-PATH (2026-09-29): the kit #32 host page's SEC-SCAN-3 refactor returned
  `resources/rawfile/blazor/<x>` to `getRawFileContentSync`, which only accepts the
  rawfile-relative `blazor/<x>`; every read threw and the host answered 404 (kit #31's host
  used `blazor/<x>` and read fine). The fix keeps the boundary judgment on
  `resources/rawfile/blazor/` and restores the `blazor/<x>` return; the node test now asserts
  the namespace (43 checks green). Rebuilds: default sha256 `69de2eea…3174`, `--no-csp` A/B
  twin sha256 `c1ef7e06…a6a7` (both 26 MB, 213 site files, `dotnet.js` byte-equal to
  `dotnet.08s0yny1y1.js`).

`blazor-recipe.yml` (weekly + manual) re-publishes both recipes on a stock x64 runner so
feed/version drift shows up without a device.

## Files

```
hello-blazorwasm.csproj      flight pin + RuntimeFrameworkVersion (see the csproj comments)
Directory.Build.targets     known-pack version overrides + conditional task-host override import
taskhost-overrides.targets  in-process UsingTask registrations (only with OhosTaskHostOverride)
NuGet.config                nuget.org + dnceng public dotnet11 feed
run-smoke.sh                publish + verify driver (SKIP/--require/--slim semantics)
arkts-host/                 ArkTS host project + pack-host.sh (see its README)
```
