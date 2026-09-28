# Blazor WebAssembly (ArkWeb) — device-test kit 集成交接（2026-09-28）

**给 kit 会话：** 建议把「Blazor WASM ArkWeb 承载」作为 **kit #31 的可选组件**。Blazor 侧输入已就绪、
并在 OpenHarmony arm64 设备上完成发布/打包/可签性验证（§2）；kit 侧按 §3 接线即可，item 3 的
「真机渲染验证」随该轮 tester 一起闭环。**本文档不含 kit 脚本改动**，kit 侧按需裁剪。

## 1. 交付输入（已提交，见 `test/hello-blazorwasm/`）

| 输入 | 说明 |
| --- | --- |
| `run-smoke.sh [--slim]` | 发布最小 Blazor WASM 站点；`--slim` = `-p:InvariantGlobalization=true`（去掉 ICU 数据），`--require` 供 CI 用 |
| `arkts-host/pack-host.sh <site> --slim --unsigned-only [--out <hap>]` | 把站点内嵌进 ArkTS 宿主（`resources/rawfile/blazor`），`--slim` 再剔除 `.br/.gz/.map`，`--unsigned-only` 只打包不签名 |
| `arkts-host/project/.../Index.ets` | 宿主页：`onInterceptRequest` 直供 rawfile + `br/gzip` 协商 + console 标记转发 hilog |
| 判读标记 | `BLZ_BOOT`（window load）、`BLZ_RENDERED`（Blazor 首帧，.NET→JS interop）、`BLZ_ERROR <msg>`；宿主输出为 `hilog` 的 `BlazorWebHost ... marker: BLZ_*` |

自签注意：bundle 名是 **`com.example.opendotnet`**（`pack-host.sh --bundle` 可改）。tester 侧任何
auto-sign 工程需把 `AppScope/app.json5` 的 bundleName 设为同名，流程与 `自签说明.md` 中
`com.example.mauiapp` 一节完全相同。

## 2. 本机实测（OpenHarmony arm64，2026-09-28）

| 项 | 值 |
| --- | --- |
| 默认发布 | 642 文件 / 47.7 MB（其中 `.br` 8.3 MB、`.gz` 10.8 MB、`.map` 0.4 MB、ICU `.dat` 2.7 MB） |
| `--slim` 发布 | 633 文件 / 47 MB（ICU 已去） |
| `--slim` 内嵌 | 再剔除 423 个 `.br/.gz/.map` → 站点 **210 文件** |
| **unsigned hap（kit 用）** | **26 MB**；219 成员（208 framework）；0 压缩残留、0 ICU 残留；`index.html` 在内 |
| 对照：全量签名 hap | 48 MB（此前的完整站点变体） |
| 可签性 | 该 26 MB unsigned hap 用调试材料 `sign-app` + `verify-app` 成功（签名后 26.8 MB） |
| 编译 | 宿主页含新协商/标记代码，`CompileArkTS` 通过（`ohos_packing_tool` 打包、未签名） |

尺寸预算：kit #29 为 361 MB；+1 个 26 MB unsigned hap ≈ **+7%**。

## 3. kit 侧最小改动清单（建议）

1. **`scripts/make-device-test-kit.sh`**
   - 构建（在已跑过 `scripts/build-arkts-shell.sh` 的机器上，`pack-host.sh` 会用它装的 `.arkts-build`）：
     ```sh
     sh test/hello-blazorwasm/run-smoke.sh --slim --out "$WORK/blazor"
     sh test/hello-blazorwasm/arkts-host/pack-host.sh "$WORK/blazor/publish/wwwroot" \
        --slim --unsigned-only --out "$KIT_DIR/hello-blazorwasm-host-unsigned.hap"
     ```
   - **只发 unsigned 变体**：我们的调试 profile 绑定我们的 UDID，tester 必须重签（与 `hello-maui-app-unsigned` 同逻辑）
   - `pack-host.sh` 自行解析 node（避开设备环境的 `NODE=/data/service/hnp/bin/node` v24，该 node 跑 hvigor 会崩）；ubuntu 构建机用 PATH node 即可
2. **`scripts/verify-kit.sh`**（建议断言，可用 `unzip -l` / Python zipfile）
   - `resources/rawfile/blazor/index.html` 存在
   - `resources/rawfile/blazor/_framework/` ≥1 个 `*.wasm` 与 `blazor.webassembly*.js`
   - `ets/modules.abc`（PANDA magic）、`resources.index`、`module.json` 的 bundle 为 `com.example.opendotnet`
   - 无 `.br/.gz/.map` 与 `icudt*.dat`（`--slim` 生效）
3. **`tester-run.sh`**（可选 probe）
   - `bm install -p <signed>`；`aa start -b com.example.opendotnet -a EntryAbility`
   - 等 3–5 s 后：`hilog -x | grep BlazorWebHost` 断言含 `marker: BLZ_BOOT` 与 `marker: BLZ_RENDERED`
   - 失败时落盘 `hilog -x > blazor-hilog.txt`（便于回传）
4. **文档**
   - `自签说明.md`：加 `com.example.opendotnet` 一条（bundle 名要一致）
   - `验收说明.md` 新增「Blazor 段」：
     - 自动（必过）：两条 `BLZ_*` hilog 标记
     - 人工：首屏显示 “Hello from Blazor WebAssembly”；进入 `/counter` 点击一次 +1；截图 1 张
   - `快速开始.md` / `文档索引.md`：加组件条目；`README-交付说明.md`：里程碑一句
   - `SHA256SUMS`/tar 由脚本生成，无需手改
5. （可选）在 kit 构建机加一条**离线自检**：`sh test/hello-blazorwasm/run-smoke.sh --require --slim` 的
   发布侧不需要设备/OHOS SDK（x64 即可），可做构建期配方体检；仓库另有 `blazor-recipe.yml`
   （每周 + 手动）跑同一配方

## 4. 判读与失败采集（tester 交付话术）

- 自动判读（必过）：
  `hilog -x | grep BlazorWebHost` 出现 `marker: BLZ_BOOT` 与 `marker: BLZ_RENDERED`
- 人工：首屏文本 + Counter 点击 +1 + 截图
- 失败时回传：`hilog -x`（含 `BlazorWebHost` 与 `BLZ_ERROR` 行）+ 截图；如 `bm dump` 可用再附 `bm dump -n com.example.opendotnet`

## 5. 风险 / 未验证

- **ArkWeb 渲染本身未在本工作区验证**（无 UI/`hdc`）——这正是本组件要闭环的；`BLZ_ERROR` 会转发
  JS 错误到 hilog，便于定位是宿主协商问题还是 WASM/ArkWeb 能力问题
- `--slim` 站点不带 `.br/.gz`：宿主协商会自然回退未压缩（功能等价，传输量略增；本地 rawfile 读取无感）
- kit 构建机没有 `.arkts-build`（hvigor 工具链）时，需先跑一次 `scripts/build-arkts-shell.sh`，或把该 hap
  作为预构建输入纳入 kit
- 与 MAUI kit 组件无耦合：这是首个 ArkTS-only hap，`verify-kit.sh` 的现有断言按 hap 分节，新增一节即可
