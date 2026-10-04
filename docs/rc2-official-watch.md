# rc.2 官方包监测（RC2-WATCH，2026-10-04）

> 触发条件（换 pin 批次的 §8）：官方 MAUI rc.2（或更新版本）上 nuget.org —— 当前 pin 的
> `Microsoft.Maui.* 11.0.0-rc.2.26478.12` 仍是 dnceng `dotnet11` daily。
> 监测脚本：`scripts/rc2-official-watch.sh`；离线自测：`scripts/selftest-rc2-official-watch.sh`；
> 排程：`.github/workflows/rc2-watch.yml`（每周一 03:17 UTC + 手动 dispatch）。

## 当前记录（2026-10-04 复核）

| 源 | 现状 | 触发 |
|---|---|---|
| nuget.org（切片四包 Controls / Core / Graphics / AspNetCore.Components.WebView.Maui） | 最新 `11.0.0-rc.1.26451.6`（仅 rc.1） | 否 |
| GitHub `dotnet/maui` releases | 最新 `11.0.100-rc.1.26458.5` | 否 |
| dnceng daily（现 pin 来源） | `11.0.0-rc.2.26478.12`，未上 nuget.org | — |

**结论：等待中（WAIT）**；官方 rc.2 尚未发布。

## 运行

```sh
sh scripts/rc2-official-watch.sh            # 只读轮询，不加参数
sh scripts/selftest-rc2-official-watch.sh   # 离线夹具（file://），不触网
```

- 退出码：`0` = 未出现（继续等）；`10` = 出现（执行换 pin 批次）；`1` = 所有源都取不到（结果未知）；`2` = 用法错误。
- 触发输出引用 `runtime-ohos/docs/plans/2026-09-30-rc2-mainline-adoption.md` §8：换 `MAUI_OHOS_REF`
  （`interaction-regression.yml` / `pixel-regression.yml` / `host-export-contract.yml`）→ 删 dnceng `dotnet11`
  feed step → 门禁 5/5 + 本地套件 → 记录 → pin 与 feed step 同批回滚。
- CI 契约：`0` 绿；`10` 红 + warning 注解（即提醒）；`1` 红（网络，非触发）。

## 备注

- 版本比较基线：nuget `11.0.0-rc.2`、GitHub `11.0.100-rc.2`；比基线新（后续 rc / GA / 更高版本）一律触发。
- 网络：脚本用 `curl -L`（本机 api.nuget.org 会重定向到 nuget.azure.cn；GitHub 直连不稳时按源降级，
  仅当两源全失败才判未知）。
- 换 pin 时同步更新本页状态与 `docs/rc2-line-notes.md`。
