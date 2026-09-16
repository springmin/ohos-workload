# ohos-workload — minimal OpenHarmony platform workload (W1)

A local, DevEco-less .NET **platform workload** for OpenHarmony, following the
dotnet/android | dotnet/macios model (manifest + Sdk/Ref/Runtime packs). W1 scope:

- platform TFM `net11.0-openharmony<api>` recognized (API levels 20.0 and 26.0),
- a thin `Microsoft.OpenHarmony.Ref` binding (grows into the full surface in W3),
- runtime pack alias to the released `Microsoft.NETCore.App.Runtime.openharmony-arm64`,
- `.hap` packaging is a W2 deliverable (host + ArkTS shell).

## Layout

```
manifests/<sdk-band>/microsoft.net.sdk.openharmony/
    WorkloadManifest.json        # workload + pack ids/versions
    WorkloadManifest.targets     # imports the platform SDK pack (deferred)
    WorkloadDependencies.json    # external toolchain (OpenHarmony SDK)
packs/Microsoft.OpenHarmony.Sdk/<ver>/
    Sdk/Sdk.targets              # platform wiring: TargetPlatformSupported, versions,
                                 # FrameworkReference + KnownFrameworkReference
packs/Microsoft.OpenHarmony.Ref.<api>/<ver>/
    ref/net11.0/Microsoft.OpenHarmony.dll
    data/FrameworkList.xml       # required by ResolveTargetingPackAssets
packs/Microsoft.OpenHarmony.Runtime.<api>.openharmony-arm64/<ver>/
    runtimes/openharmony-arm64/...   # laid out from the released .NET runtime pack
test/hello-lib/                  # TFM build test
scripts/env.sh                   # exports the two workload roots
```

## Use it

```sh
. ./scripts/env.sh                 # DOTNETSDK_WORKLOAD_MANIFEST_ROOTS / _PACK_ROOTS
cd test/hello-lib
dotnet build                       # net11.0-openharmony20.0
dotnet publish -r openharmony-arm64
```

The manifest band directory must match the SDK feature band
(`11.0.100` for release SDKs, `11.0.100-rc.1` for the current preview SDK).

## Install as a workload (no env vars needed)

```sh
./scripts/pack-local-workload.sh                     # packs/* -> .feed/*.nupkg
cp -r manifests/11.0.100-rc.1/microsoft.net.sdk.openharmony \
      ~/.dotnet/sdk-manifests/11.0.100-rc.1/          # the manifest must be visible first
dotnet workload install openharmony --skip-manifest-update --source .feed
dotnet workload list                                  # -> openharmony
```

`dotnet build` / `dotnet publish -r openharmony-arm64` for `net11.0-openharmony<api>`
then work without `DOTNETSDK_WORKLOAD_*` environment variables. To uninstall:

```sh
dotnet workload uninstall openharmony
rm -rf ~/.dotnet/sdk-manifests/11.0.100-rc.1/microsoft.net.sdk.openharmony
```

(Symlinked dotnet roots do not work for this: the muxer resolves the SDK through the
real path, so the workload must be installed into the root that owns the SDK.)

## Ship it as a bundle

```sh
./scripts/pack-workload-bundle.sh          # dist/openharmony-workload-<ver>.tar.gz
```

The bundle (manifest + `feed/*.nupkg` + `install-ohos-workload.sh`) is what the fork's SDK
installer consumes: `install-dotnet-ohos.sh` (in `sdk-ohos/eng/ohos-install`) installs it
automatically when the tarball sits next to the SDK, is published in the same release
(asset `openharmony-workload-*.tar.gz` (legacy `ohos-workload-*.tar.gz` is still accepted)), or is pointed at with `WORKLOAD_BUNDLE=<dir|tar.gz>`.
`ohos-install.sh workload` installs it into an existing SDK; `WORKLOAD_DRY_RUN=1` shows the
plan. `build-ohos-all.sh` collects the bundle into its release outputs
(`OHOS_WORKLOAD_BUNDLE`, or `~/springsources/ohos-workload/dist/` by default).

## Prepare the packs

```sh
. ./scripts/env.sh
./scripts/prepare-packs.sh            # builds the thin ref assembly; downloads the
                                      # released runtime pack (sha256-verified) and lays
                                      # it out as a workload pack
```

## Status (2026-09-16)

- ✅ `dotnet build` and `dotnet publish -r openharmony-arm64` succeed for both
  `net11.0-openharmony20.0` (CI public SDK API level) and `net11.0-openharmony26.0`
  (device SDK API level).
- ✅ The published self-contained app **runs on device** (CoreCLR starts, BCL works;
  `System.Console` remains unsupported on OpenHarmony, so tests write to a file).
- ⏳ `.hap` packaging (W2) — NAPI host + ArkTS shell + `publish -> .hap` target.
