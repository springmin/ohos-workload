# rc.2 官方包监测（RC2-WATCH）

> **2026-10-13 已触发并落地（完成）**：官方四包 `11.0.0-rc.2.26505.5` 上了 nuget.org，
> pin 切换批次同日执行 —— maui 切片 `1c5ff3cbeb`（四包引用 `26478.12 → 26505.5`；14 处 /
> 8 文件；切片门禁 0 error / 0 IL）、本仓 9 个 test/src 工程同步、三 workflow `MAUI_OHOS_REF`
> → 新 tip、interaction/pixel 删 dnceng feed step、`hello-blazorwasm` flight → 官方
> `11.0.0-rc.2.26504.105`（`NuGet.config` 仅 nuget.org）。排程已停用（保留脚本与手动 dispatch
> 作记录）；详见 `docs/rc2-line-notes.md`。
> 触发条件（历史）：官方 MAUI rc.2（或更新版本）上 nuget.org —— 当时 pin 的
> `Microsoft.Maui.* 11.0.0-rc.2.26478.12` 仍是 dnceng `dotnet11` daily。
> 监测脚本：`scripts/rc2-official-watch.sh`；离线自测：`scripts/selftest-rc2-official-watch.sh`；
> 排程：`.github/workflows/rc2-watch.yml`（每周一 03:17 UTC + 手动 dispatch；**2026-10-13 停用排程**）。

## 触发记录

| 日期 | 源 | 版本 | 结果 |
|---|---|---|---|
| 2026-10-04 | nuget.org / GitHub | `11.0.0-rc.1.26451.6` / `11.0.100-rc.1.26458.5` | WAIT（exit 0） |
| 2026-10-13 | nuget.org（切片四包 Controls / Core / Graphics / AspNetCore.Components.WebView.Maui） | `11.0.0-rc.2.26505.5` | **trigger=yes（exit 10）→ 换 pin 批次执行** |
| 2026-10-13 | GitHub `dotnet/maui` releases | 页面滞后（未作触发依据；以 nuget flat-container 为准） | — |

**结论：已完成**；pin 已切至官方 rc.2，dnceng feed step 已删。历史 pin `11.0.0-rc.2.26478.12`
（dnceng `dotnet11` daily）正式退役。

## 运行

```sh
sh scripts/rc2-official-watch.sh            # 只读轮询，不加参数
sh scripts/selftest-rc2-official-watch.sh   # 离线夹具（file://），不触网
```

- 退出码：`0` = 未出现（继续等）；`10` = 出现（执行换 pin 批次）；`1` = 所有源都取不到（结果未知）；`2` = 用法错误。
  （触发记录见上；再次运行仍会报 exit 10，因为基线以下已落地——重新启用排程/看下一里程碑前先重锚基线。）
- 触发输出引用 `runtime-ohos/docs/plans/2026-09-30-rc2-mainline-adoption.md` §8：换 `MAUI_OHOS_REF`
  （`interaction-regression.yml` / `pixel-regression.yml` / `host-export-contract.yml`）→ 删 dnceng `dotnet11`
  feed step → 门禁 5/5 + 本地套件 → 记录。
- CI 契约：`0` 绿；`10` 红 + warning 注解（即提醒）；`1` 红（网络，非触发）。**排程已停用**
  （2026-10-13，任务完成）；手动 dispatch 仍可运行。

## 备注

- 版本比较基线：nuget `11.0.0-rc.2`、GitHub `11.0.100-rc.2`；比基线新（后续 rc / GA / 更高版本）一律触发。
- 网络：脚本用 `curl -L`（本机 api.nuget.org 会重定向到 nuget.azure.cn；GitHub 直连不稳时按源降级，
  仅当两源全失败才判未知）。
- 换 pin 时同步更新本页状态与 `docs/rc2-line-notes.md`（2026-10-13 已按此更新两处）。
