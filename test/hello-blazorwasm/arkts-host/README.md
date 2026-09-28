# arkts-host — ArkWeb host for a published Blazor site

A minimal ArkTS application (module `entry`, API 26, `compatibleSdkVersion 18`) that serves an
embedded Blazor WebAssembly site from `resources/rawfile` — no local HTTP server, no network
access (the `ohos.permission.INTERNET` request in `module.json5` is only for development
against a real origin).

```
project/            ArkTS sources: EntryAbility + pages/Index.ets (the serving page)
pack-host.sh        stage project/, embed a site, build with hvigor, pack + sign the hap
```

## Serving model

`pages/Index.ets` loads `https://blazor.local/` and answers every request through
`Web.onInterceptRequest` by reading the matching rawfile synchronously
(`ResourceManager.getRawFileContentSync`):

```
https://blazor.local/<path>   ->  resources/rawfile/blazor/<path>
```

- Unknown paths fall back to `blazor/index.html` (client-side routing keeps working).
- MIME types: `text/html`, `text/javascript`, `application/json`, `application/wasm`,
  `application/octet-stream` (wasm .dat / fingerprinted payloads), images and fonts.
- When the request's `Accept-Encoding` carries `br`/`gzip` and the site ships the sibling
  `.br`/`.gz` file, that variant is served with the matching `Content-Encoding` (a full
  publish does; `--slim` embeds without them and the plain files are used).
- `BLZ_*` console messages are forwarded to hilog (`BlazorWebHost ... marker: BLZ_BOOT /
  BLZ_RENDERED / BLZ_ERROR ...`) as machine-readable pass criteria for the tester flow.
- The pattern is the one the in-product HybridWebView/BlazorWebView asset bridge uses
  (`packs/Microsoft.OpenHarmony.Sdk/<ver>/templates/ets/pages/Index.ets`).

The page deliberately keeps the repository's ArKTS source contract: `@kit.*` imports only (no
`@ohos` module imports), no global `getContext()`, no `@ohos.*` dynamic imports.

## Packing

```sh
pack-host.sh <site-dir> [--out <hap>] [--work <dir>] [--bundle <name>] [--slim] [--unsigned-only]
```

`<site-dir>` is the directory containing `index.html` (normally `<publish>/wwwroot`; publish
it with `../run-smoke.sh`). `--slim` drops the `.br`/`.gz`/`.map` siblings at embed time (the
page prefers them only when the request accepts the coding, so dropping them keeps the site
fully servable and take a full publish from 48 MB to a 26 MB hap). `--unsigned-only` stops
after packing and copies the unsigned hap to `--out` (default
`out/hello-blazorwasm-host-unsigned.hap`) for external signing — the device-test kit consumes
this variant. The script:

1. stages `project/` into the work dir and writes `local.properties` + `build-profile.json5`
   (version-nested SDK symlink root, signing material under the SDK's `toolchains/lib`);
2. copies the site to `entry/src/main/resources/rawfile/blazor`;
3. runs hvigor `assembleHap` — **hvigor's own PackageHap failure is tolerated** (toolchains
   that ship only the native `ohos_packing_tool` and no `app_packing_tool.jar` fail there);
   `CompileArkTS` must finish;
4. packs the hvigor intermediates with the SDK's `ohos_packing_tool`;
5. signs with `hap-sign-tool` (`sign-profile` from the SDK's
   `UnsgnedDebugProfileTemplate.json` with the bundle name substituted, then `sign-app` +
   `verify-app`) — skipped with `--unsigned-only`.

Default output: `out/hello-blazorwasm-host-{signed,unsigned}.hap`; the size is dominated by
the embedded site (a full Blazor publish is ~48–70 MB, `--slim` ~26 MB).

### Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `OHOS_SDK_ROOT` / `OHOS_SDK` | newest `~/.harmonybrew/Cellar/ohos-sdk*` | SDK with `toolchains/lib/{ohos_packing_tool,hap-sign-tool}` and the signing material |
| `HVIGOR_JS` | `<repo>/.arkts-build/hvigor/node_modules/@ohos/hvigor/bin/hvigor.js` | hvigor entry point (created by `scripts/build-arkts-shell.sh`) |
| `HVIGOR_NODE` | `~/.harmonybrew/bin/node`, then PATH `node` | node binary override. Every candidate must pass a `node -e "process.exit(0)"` smoke test (mirroring `scripts/build-arkts-shell.sh`): the OpenHarmony environment's `NODE=/data/service/hnp/bin/node` (v24) aborts with a V8 fatal before it runs anything, so a bare `$NODE` is never trusted |
| `NODE_HOME` | `~/.harmonybrew` | `nodejs.dir` in `local.properties` |
| `ARKTS_PLATFORM_VERSION` | `26.0.0` | SDK version directory in the symlink root |
| `SIGN_KEY_ALIAS` | `OpenHarmony Application Release` | app signing alias |
| `SIGN_PROFILE_ALIAS` | `openharmony application profile debug` | profile signing alias |
| `SIGN_KEY_PWD` / `SIGN_STORE_PWD` | `123456` | keystore passwords |

The default signing material is the SDK's standard OpenHarmony debug set, so the hap installs
on a device that trusts the OpenHarmony debug root. Use `--bundle` plus the `SIGN_*` overrides
for other setups.

## Install and run (needs a device with `hdc` and a UI)

```sh
hdc install out/hello-blazorwasm-host-signed.hap
aa start -b com.example.opendotnet -a EntryAbility
hilog | grep BlazorWebHost
```

## Notes / limits

- `onInterceptRequest` builds one response per request synchronously; a 71 MB site loads fine
  because the framework files are read on demand (no full-site buffering).
- `--slim` trades the pre-compressed siblings for size: requests that advertise `br`/`gzip`
  simply fall back to the uncompressed files (rawfile reads make the transfer difference
  invisible in practice).
- ArkWeb rendering has not been exercised on a device with a UI in this workspace; the hap
  compiles, packs, signs and verifies, and the serving path is the in-product one. The
  device-test kit round is the intended verification vehicle (hand-off spec:
  `../../docs/blazor-arkweb-kit-handoff.md`).
