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
| `cut-kit.sh` | Scripted cut of the device-test kit: phases P0 preflight, P1 build, P2 strict verify, P3 bundle + sdk anchor, P4 F4 controlled clobber, P5 values/presign/manifest, P6 CI re-check. P3 builds the bundle cumulatively: it auto-resolves the previous published bundle from the sdk-ohos `versions.env` anchor (`=`, `:=` and JSON spellings; local candidate first, sdk-ohos release download otherwise) and fails closed without a seed; `--seed-bundle` overrides (`CUT_KIT_SEED_DIR`/`CUT_KIT_SEED_OFFLINE` tune the search); the sdk re-anchor matches the same three forms and is a no-op when already current. Dry-run is the default; `--execute` writes, P4-P6 need `--execute --i-know`, P4 asks for a typed confirmation, and the tester-docs gate fails closed before the build. P4-P6 dry-runs print the upload clobber plan, the Integrity notes template and the RELEASE-VALUES block and parse the upload/presign/manifest hooks without writing or calling the API. Resume state lives in `<scratch>/state.env`. |
| `selftest-cut-kit.sh` | Fixture selftest for `cut-kit.sh` (P0 pass/fail, pack drift, stale-docs fail-closed, resume, F4 confirmation gate with no write/network, the P3 `=`/`:=`/JSON anchor spellings + cumulative-seed auto/explicit/missing paths, and the P4-P6 dry-run zero-write previews; 185 checks); wired into `preflight.sh` step 1. |

## csc livelock watchdog (2026-10-10)

| Script | Purpose |
| --- | --- |
| `run-with-csc-watchdog.sh` | Wraps a managed build in the runtime-ohos csc livelock watchdog (`scripts/ohos-csc-watchdog.sh`): a csc spinning with frozen I/O is SIGKILLed and the command is rerun once with `DOTNET_PROCESSOR_COUNT=1`; a second stall fails closed. Used by `preflight.sh` steps 4/5 (interaction build, pixel builds); `CSC_WATCHDOG=0` disables it; thresholds default to spin 480 s / idle 300 s. |
| `selftest-csc-watchdog.sh` | Fixture selftest for the wrapper (first-stall rerun, second-stall fail-closed, `CSC_WATCHDOG=0`, no-kill no-retry, missing-rescue passthrough) plus two real-watchdog scenarios with a fixture spun `csc` when the sibling runtime-ohos checkout is present; wired into `preflight.sh` step 1. |

## Release signing + ACL acceptance (2026-10-15)

| Script | Purpose |
| --- | --- |
| `sign-for-device.sh --release` | AGC release signing path (the debug/device paths are unchanged): material from `--profile/--key/--cert` or `OHOS_RELEASE_{P7B,P12,CER,…}` / the `OHOS_RELEASE_DIR` drop dir (default `~/Documents/ohos/release`, the single `*.p7b`/`*.p12`/`*.cer` there is picked); fail-closed preflight (`type=release`, no `debug-info.device-ids`, every hap's bundleName == the profile's, app cert chain contains `distribution-certificate`) before the first `sign-app`; `sign-app -signCode 1`; every output `verify-app`-checked (`-outCertChain/-outProfile`) before it lands as `<hap>-release.hap`; missing material names the file/flag/env. Key alias defaults to `releaseKey` (logged). Workflow + usage: `runtime-ohos/docs/plans/2026-10-04-ohos-release-signing-workflow.md`. |
| `selftest-sign-for-device.sh` | Hermetic selftest for sign-for-device.sh (stub SDK/tool/openssl): T15 covers `--release` material resolution/ambiguity + all refusals + argv + red controls; T16 (SDK-gated) synthesizes a UDID-free release profile with the SDK test keys and signs a real hap end-to-end (independent `verify-app` + `verify-profile` re-check; a real debug profile and a release profile with device-ids are refused); 346 checks. |
| `clipboard-acl-accept.sh` | CLIPBOARD-ACL device acceptance: build the probe (`-p:OpenHarmonyFeatures=clipboard -p:ClipboardProbe=true`) or take `--hap`; fail-closed ACL preflight (the profile must carry `ohos.permission.READ_PASTEBOARD` in `acls.allowed-acls`/`restricted-permissions`); sign via `--sign release` (sign-for-device.sh --release) or `--sign external` (debug/ACL profile, UDID read from the device); install; `bm dump` must report the ACL (or a granted request); the `app://clipboard/write|read` probe must return the marker (a `read null` + `GetPasteDataInner# check permission failed` is the denial signature); evidence + `report.md` land in `--out`; `--dry-run` runs only the ACL preflight and prints the plan; device steps use the shared `.device-lock` and the patched-hdc fallback. |
| `selftest-clipboard-acl-accept.sh` | Offline stub selftest (stub hdc/dotnet/sign-for-device/hap-sign-tool) for the acceptance script: usage contract, ACL gate, happy path, external-UDID flow, 7 red controls (bm dump absent/ungranted, 9568289, sign failure, read null, read null+service denial, missing read line, undeclared hap), `--build` argv, dry-run zero-calls, stale/live device lock; 111 checks. |
