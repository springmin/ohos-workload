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
| 判读标记 | `BLZ_BOOT`（window load）、`BLZ_RENDERED`（Blazor 首帧，.NET→JS interop）、`BLZ_ERROR <msg>`；宿主输出为 `hilog` 的 `BlazorWebHost ... marker: BLZ_* [blz:<nonce>]` |

> **SEC-FIX 增量（2026-09-28 晚，kit #31 之后）：** 宿主页新增请求路径校验（`..`/反斜杠/NUL/
> 绝对路径/编码变体 → 裸 404）与响应安全头（`nosniff`、`Vary`、HTML 最小 CSP），并给每条转发
> 标记盖章按启动随机 nonce（页面 URL 携带、hilog 先公告 `session nonce:`）。`tester-run.sh
> --blazor-probe` 只接受「宿主进程 pid（`pidof <bundle>`）+ 该 nonce」的
> `BlazorWebHost: marker: BLZ_*` 行：另一个进程往 hilog 写 `BLZ_BOOT` 不再能伪造探针通过；
> 旧宿主（无 nonce）降级为 pid+格式过滤并记录 WARN。**当前 kit #31 包内的 hap 仍是修复前的
> 构建**（判读命令 `hilog -x | grep BlazorWebHost` 不变），下一轮 `--with-blazor` 重建后生效。
>
> **FIX-BLZ-JS 增量（2026-09-28 晚，kit #31/#32 之后）：** kit #31/#32 包内的 blazor hap 缺
> `_framework/dotnet.js`，真机首屏因此不渲染。根因：.NET 的静态 web assets 指纹化把稳定名
> `_framework/dotnet.js` 路由到 `_framework/dotnet.<hash>.js`，路由表只在 publish 根目录的
> `*.staticwebassets.endpoints.json` 里；ArkTS 宿主按 rawfile 1:1 直供（没有路由表），于是
> `blazor.webassembly.js` 动态 `import('./dotnet.js')` 失败 →
> `BLZ_ERROR Failed to fetch dynamically imported module`。修复：`pack-host.sh` 在嵌入阶段按
> manifest 复制稳定名（`dotnet.js`/`dotnet.native.js`/`dotnet.runtime.js`，与指纹版同构建同内容；
> 无 manifest 时按 `<name>.<hash>.js` 约定回退），`verify-kit.sh` 2c 新增断言（`dotnet.js`
> 存在且与指纹版逐字节一致——因此 kit #31/#32 的 hap 在旧包自检里会 FAIL，属预期）。
> 已重建 slim unsigned hap 对照：sha256 `25ef2fa577b548015539ddb4c1091ba60f60567f2a3ef8b2202705820657317c`
> （26 MB，213 个站点文件 = 旧的 210 + 3 个默认名；0 压缩/ICU 残留）；kit #31 包内的旧 hap 为
> sha256 `36010a9c80d226ed85ea1ca362ad31562ed4566a7b5cc49debd985da2e33ae2e`（缺 dotnet.js）。
> 修复随 **kit #33** 出货。
>
> **FIX-BLZ-PATH 增量（2026-09-29，kit #32 回归根因）：** SEC-FIX 的路径重构把
> `resolveRawfilePath` 的返回值改成了边界拼写 `resources/rawfile/blazor/<x>`，而
> `ResourceManager.getRawFileContentSync` 只接受 rawfile 相对路径 `blazor/<x>`（kit #31 的旧宿主
> 即用此拼写、设备读取正常，属口径已验证）；kit #32 宿主的所有读取因此抛异常、资源一律 404。修复：
> 安全校验仍以 `resources/rawfile/blazor/` 为边界（语义不变），返回值恢复 `blazor/<x>`
> （`INDEX_FILE='blazor/index.html'`），`readRawFile`/`readNegotiated`/`serveFile` 全程使用 API
> 路径（br/gz 变体同理）；`rawfile-path.test.mjs` 新增「返回值必须以 `blazor/` 开头、绝不包含
> `resources/rawfile/`」断言并保留 12 恶例/9 合法例（43 checks 全绿）。另：`pack-host.sh --no-csp`
> （或 `BLZ_HOST_NO_CSP=1`）构建不带 CSP 头的对照 hap（默认仍带）——若 CSP-off 变体能渲染而默认
> 不能，CSP 是次因；两者都不能渲染则 CSP 非瓶颈、以路径修复为准。重建已验：默认 hap sha256
> `69de2eea62fafb4eebb5ecb722def8f1126ee6fc339ee6e844ed308920523174`，no-csp hap
> `c1ef7e06d04b0108efb0c5e2faeea8082b9865cc0612ef4e278ae852dd46a6a7`（均 26 MB / 213 站点文件；
> `_framework/dotnet.js` 在位且与指纹版逐字节一致；CompileArkTS 通过）。**真机复测归 kit
> #33/tester 轮。**

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
| unsigned hap（FIX-BLZ-JS 重建，随 kit #33） | 26 MB；222 成员（211 framework）；213 站点文件 = 210 + 3 个默认名映射；`dotnet.js` 与 `dotnet.08s0yny1y1.js` 逐字节一致；sha256 `25ef2fa5…317c` |
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
