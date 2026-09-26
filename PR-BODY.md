# feat/payload-zip-optin — sync `verify-kit.sh` with the payload-zip opt-out

## What

The packaging switch `OpenHarmonyHapPayloadZip` (skip `resources/rawfile/dotnet.zip` when the
staged `libs/<abi>/` payload ships) landed for all three preview packs in `fa8a28e`
(`packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.{22,23,24}/targets/OpenHarmony.Hap.targets`,
all three SHA-256 = `390ea1808b1ffbbe403b036671ec1c08739ccaa12afb14ba35d3843cc0e2ad84`). With
payload-in-libs on (default `true`), the zip is a duplicate of the staged payload; opting out
(`-p:OpenHarmonyHapPayloadZip=false`) drops it and clears the marker's zip identity
(`zipEntries=0`, `zipSha256=""`). The opt-out requires `OpenHarmonyHapPayloadInLibs=true`
(hard `<Error>` in the targets when both are off).

This branch carries the companion change `fa8a28e` announced but did not ship: the tester-facing
`scripts/verify-kit.sh` treated the legitimate opt-out pack as a failure
(`payloadEntries != zipEntries` and a missing `zipSha256` were hard FAILs; a missing
`dotnet.zip` was a WARN).

### Changes in this branch

- `scripts/verify-kit.sh`
  - gate the payload↔zip cross-assertions on a marker **zip identity**
    (`zip_identity = zipEntries or zipSha256`); only a marker that names a zip is compared
    against the packed `resources/rawfile/dotnet.zip`;
  - reverse FAIL: marker without a zip identity but the hap still carries `dotnet.zip`;
  - FAIL when the marker names a zip identity but the zip is missing or unreadable;
  - missing `dotnet.zip` downgraded WARN → INFO (printed, never counted as a WARN);
  - header contract comment updated to document both shapes.
- `scripts/selftest-verify-kit.sh`
  - new S15: opt-out shape (no zip + cleared identity) → exit 0 with INFO and no WARN; both
    drift directions (zip without identity, identity without zip) → exit 1 with the new messages.

The targets change itself is already at the branch base (`fa8a28e`, also on `origin/master`
since `72910f7`); no pack file is touched by this branch.

## Why

CDGSS measured a signed-hap saving of **20,205,620 B ≈ 20.2 MB (19.27 MiB)** per shipped variant
(CDGSS §37.2: nozip `71,737,872 B` = `9eeb13e6…` vs zip `91,943,492 B` = `91b89a4a…`; the §32.4
rebuild is `d07544be…`, 91,944,701 B). The default stays `true`; the opt-out is for deliveries
that accept losing the older-shell data-directory extraction fallback. Without the verify-kit
sync, every such delivery fails the kit self-check, and a drifted marker/zip pair would be
reported as a soft WARN instead of a FAIL.

## Verification

| item | result | evidence |
|---|---|---|
| three preview packs byte-identical | `identical=True`; `390ea180…` on preview.22/23/24, on the installed preview.24 and on this worktree | CDGSS §32.1/§32.3; `sha256sum`/`diff -q` |
| default resolves true | `dotnet msbuild CDGSS.Maui/CDGSS.Maui.csproj -getProperty:OpenHarmonyHapPayloadZip` → `true` | CDGSS §32.2 |
| PG2a against this worktree | `pg2 pack runtime libs packs=22,23,24 staged=True elf=True excluded=True order=True identical=True assert=True`; suite `checks=334 total=334 floor=314 assert=True`, EXIT=0 | `/data/storage/el2/base/tmp/opencode/workload-pr-pg2a.log` |
| verify-kit selftest | `checks: 82, failed: 0` (S0–S15) | `sh scripts/selftest-verify-kit.sh` |
| marker shapes of the two variants | nozip `zipEntries=0/zipSha256=""`; zip `zipEntries=292/zipSha256=6cc9780c…` | CDGSS §37.2/§37.3 |

Reproduce (verifier binary built from the identical `Program.cs`; `OHOS_WORKLOAD_ROOT` forces the
worktree sources):

```sh
sh scripts/selftest-verify-kit.sh
OHOS_WORKLOAD_ROOT=$PWD ~/.dotnet/dotnet <ohos-workload>/test/maui-platform-verify/bin/Debug/net11.0/verify.dll
```

## Notes / follow-up

- Not pushed. Branch `feat/payload-zip-optin`, base local `master` `dfbe2a6`; `origin/master`
  (`72910f7`) already contains `fa8a28e`. For an upstream PR, cherry-pick this branch's commit
  onto `origin/master` so the four unrelated local master commits do not ride along.
- Device install/launch/fallback validation is still blocked (`hdc` under MDM); see CDGSS
  §17.1/§28.3.
- Whether to flip the default to `false` remains open (CDGSS §25.4 decision ⑥).
