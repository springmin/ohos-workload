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

## Status (2026-09-16)

- ✅ `dotnet build` for `net11.0-openharmony20.0` succeeds.
- ⏳ `dotnet publish -r openharmony-arm64` — runtime pack layout prepared from the
  release `Microsoft.NETCore.App.Runtime.openharmony-arm64` package.
- ⏳ `.hap` packaging (W2).
