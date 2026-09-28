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
test/hello-blazorwasm/run-smoke.sh                   # untrimmed (63 MB site); prints the path
test/hello-blazorwasm/run-smoke.sh --trim            # ILLink pass (71 MB site)
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
`entry/src/main/resources/rawfile/blazor`, builds with hvigor, packs with the SDK's
`ohos_packing_tool` and signs with `hap-sign-tool` (debug material from the SDK). Output:
`arkts-host/out/hello-blazorwasm-host-signed.hap` (~70 MB with the full site; the site
dominates the size).

The bundle name defaults to `com.example.opendotnet`; change it with `--bundle`, and sign with
your own material via the `SIGN_*` environment variables when the device does not trust the
OpenHarmony debug root.

## Verified

2026-09-28, OpenHarmony arm64 device, sdk-ohos `feature/openharmony` (statically linked
OpenSSL SDK, MSBuild pipe patch included):

- publish: untrimmed site = 636 files / 63 MB; trimmed (with the ILLink override) = 753 files
  / 71 MB; `dotnet build` of a Blazor WASM app succeeds with **no task-host retries** on the
  patched SDK.
- host hap: CompileArkTS, `ohos_packing_tool` pack and `hap-sign-tool sign-app` +
  `verify-app` all pass; the embedded site contains the 899 rawfile members.
- ArkWeb rendering on a device with a UI is still pending (this test tree runs on a headless
  device; `hdc`/`aa` are not available there). The serving path is the same one the MAUI
  BlazorWebView bridge ships, and the publish output was additionally exercised with a
  `python3 -m http.server` + curl check of the MIME types.

## Files

```
hello-blazorwasm.csproj      flight pin + RuntimeFrameworkVersion (see the csproj comments)
Directory.Build.targets     known-pack version overrides + conditional task-host override import
taskhost-overrides.targets  in-process UsingTask registrations (only with OhosTaskHostOverride)
NuGet.config                nuget.org + dnceng public dotnet11 feed
run-smoke.sh                publish + verify driver (SKIP/--require semantics)
arkts-host/                 ArkTS host project + pack-host.sh (see its README)
```
