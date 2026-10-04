# ohos-workload scripts

Shell/python helpers for building, packing, signing and verifying the OpenHarmony workload.
`env.sh` exports the two workload roots; the rest are normally run from the repository root.

Rescued from the working scratch on 2026-10-03 (see the inventory in
`runtime-ohos/docs/plans/2026-10-03-ohos-scratch-script-rescue.md`):

| Script | Purpose |
| --- | --- |
| `serve-blazor-wwwroot.py` | Serve a published Blazor `wwwroot` locally with the MIME types ArkWeb needs (`application/wasm`, precompressed `.br`/`.gz`); companion to the `test/hello-blazorwasm/arkts-host` hap. |
| `migrate-dllimport-to-libraryimport.py` | Dry-run/apply `[DllImport]` → `[LibraryImport]` migration for the OHOS interop sources; the result must pass `check-host-exports.py`. |
| `framepacing-stats.py` | Frame-pacing report/gate for a device capture: parses the host's 5 s present aggregates and the opt-in managed FPF/FPP probe lines (`-p:FramepacingProbe=true`), dedupes the shell's status-tail repeats and checks `--min-fps`/`--max-gap-ms`. Also parses the opt-in phase probe's FPH summaries (`-p:FramePhaseProbe=true`, test/hello-maui-app/FramePhaseProbe.cs) into a per-phase table. Never count raw `canvas presented` lines for fps (the shell poll repeats them; measured 60 fps as 17.7 fps on 2026-10-03). |
