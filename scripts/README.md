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
| `device-round.sh` | One-command device round over the device-test kit: `.device-lock` mutex -> kit verify (sidecar + `verify-kit.sh --tree-digest`) -> re-sign -> `tester-run` install/start/capture -> first-frame screenshot -> optional Blazor A/B (markers + `/counter` click), dynamic slots (3/5 + destroy/create + `[maui-capacity]` raw), a11y probe, deep-link hot activation -> tester-run v14 probe -> short soak -> evidence tar.gz. `--suite` turns on all optional steps; `--dry-run` only verifies locally and prints the plan. |
| `selftest-device-round.sh` | Local stub-hdc/stub-tester-run/stub-sign selftest for `device-round.sh`: usage codes, dry-run, full `--suite` round with lock + archive assertions, live-lock timeout vs stale-lock reclaim, and `--mode jit` without a JIT hap. |

## Kit-cutting automation (2026-10-08)

| Script | Purpose |
| --- | --- |
| `cut-kit.sh` | Scripted cut of the device-test kit: phases P0 preflight, P1 build, P2 strict verify, P3 bundle + sdk anchor, P4 F4 controlled clobber, P5 values/presign/manifest, P6 CI re-check. Dry-run is the default; `--execute` writes, P4-P6 need `--execute --i-know`, P4 asks for a typed confirmation, and the tester-docs gate fails closed before the build. Resume state lives in `<scratch>/state.env`. |
| `selftest-cut-kit.sh` | Fixture selftest for `cut-kit.sh` (P0 pass/fail, pack drift, stale-docs fail-closed, resume, F4 confirmation gate with no write/network); wired into `preflight.sh` step 1. |
