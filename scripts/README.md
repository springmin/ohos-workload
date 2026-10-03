# ohos-workload scripts

Shell/python helpers for building, packing, signing and verifying the OpenHarmony workload.
`env.sh` exports the two workload roots; the rest are normally run from the repository root.

Rescued from the working scratch on 2026-10-03 (see the inventory in
`runtime-ohos/docs/plans/2026-10-03-ohos-scratch-script-rescue.md`):

| Script | Purpose |
| --- | --- |
| `serve-blazor-wwwroot.py` | Serve a published Blazor `wwwroot` locally with the MIME types ArkWeb needs (`application/wasm`, precompressed `.br`/`.gz`); companion to the `test/hello-blazorwasm/arkts-host` hap. |
| `migrate-dllimport-to-libraryimport.py` | Dry-run/apply `[DllImport]` → `[LibraryImport]` migration for the OHOS interop sources; the result must pass `check-host-exports.py`. |
