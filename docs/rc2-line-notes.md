# rc.2 线交接说明（2026-09-29）

> 面向 kit/测试方与后续维护者。当前产品线 = **rc.2**（SDK `11.0.100-rc.2.26451.112`，
> workload `1.0.0-preview.28`），与上游 rc.2 flight（`.112`）对齐。
> rc.1 线（`11.0.100-rc.2.26451.109` / workload `preview.24`）仍在设备 `~/.dotnet` 保留作回滚。

## 安装（设备）

```sh
# 新目录安装（OHOS 不可覆盖已签名文件：避免复用旧目录）
INSTALL_DIR="$HOME/.dotnet.rc2" sh sdk-ohos/eng/ohos-install/install-dotnet-ohos.sh sdk
# 如需本地文件/离线：install-dotnet-ohos.sh <local.tar.gz>，并
#   TARBALL_SHA256=<sdk tar sha>  WORKLOAD_BUNDLE=<bundle.tar.gz>  WORKLOAD_SHA256=<bundle sha>
# 安装器会自动安装 workload（默认取最新 workload-* release；可用
#   WORKLOAD_BUNDLE / WORKLOAD_RELEASE_TAG 显式指定）
```

**已验证**（`~/.dotnet.rc2-112`，2026-09-29）：`dotnet --info` = `11.0.100-rc.2.26451.112` /
RID `openharmony-arm64`；workload `openharmony 1.0.0-preview.28/11.0.100-rc.2`；
`net11.0-openharmony20.0` build+publish、真机运行 `rc=0`。

## 发布面（sdk-ohos / runtime-ohos releases）

| 资产 | 说明 |
|---|---|
| `dotnet-sdk-11.0.100-rc.2.26451.112-openharmony-arm64.tar.gz` | SDK redist（锚 `c90f758e…`；每次发布重跑会重建 → 锚需重测） |
| `dotnet-runtime-11.0.0-rc.2.26451.112-openharmony-arm64.tar.gz` | runtime（锚 `1e068b05…`） |
| `openharmony-workload-1.0.0-preview.28.tar.gz` / `…-latest.tar.gz` | workload bundle（sha `155960f4…`；同字节，latest 滚动） |
| `selfsign-linux-x64` | 宿主预签工具（x64） |
| `-openharmony` 分发线 | `v11.0.0-rc.2.26451.112-openharmony`（runtime，19 资产）等，镜像自 `-ohos` 线 |

## 已知事项（使用注意）

1. **device selfsign：已重上（设备自建版）** ✓（2026-09-29）：跨构建版曾 SIGSEGV 被撤下；
   现资产 = 在设备上用修复版 SDK 本地 AOT 构建（未签名剥离版，6,321,296 B / `a403a1b4…`）——
   安装器会自动 `bootstrap_selfsign` 后用其签署整个安装树 ✓（端到端实测
   `signed=28 already_signed=1 failed=0`）。`SELFSIGN_SHA256` 已重锚（fail-closed 恢复 ✓）。
   `binary-sign-tool` 回退仍保留；设备上可用实例：
   `~/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_2/bin/binary-sign-tool`
   （`~/.harmonybrew/bin` 的 shim 实测不可靠；安装时把 Cellar 目录前置到 `PATH` 即可）。
2. **publish 产物无 apphost**：OHOS 形态以 SDK muxer 启动：
   `dotnet <app>.dll`（或经工作负载的发布目标产出可执行形态）。
3. **AspNetCore 传递 pack**：`.27` 起 workload 已收编
   `Microsoft.AspNetCore.App.Runtime.openharmony-arm64`（`11.0.0-rc.1.26451.112`），
   纯应用 publish 不再需要 `-p:DisableTransitiveFrameworkReferenceDownloads=true`。
4. **设备侧下载**：直连 GitHub release 资产在部分网络会限速/挂起；优先用
   `https://gh-proxy.com/<url>`（安装器与 CI env 已内置镜像回退）。
5. **构建参数**：rc.2 线派发 CI 时 buildid 会自动取上游 flight revision
   （`20260901.112`；workflow 已按 `runtime_ref` 判定，可省略显式输入）。
6. **设备上 MSBuild 的平台探测缺陷（影响设备本地 AOT/selfsign/打包）**：设备上
   `RuntimeInformation.IsOSPlatform(OSPlatform.Linux)` 为 **false**（fork 运行时把 OHOS 报为
   `OPENHARMONY`），导致 MSBuild 的 `IsUnixLike` 判定为假，所有 `Exec` 写成 **Windows 风格
   `.exec.cmd`**（`setlocal`/`%errorlevel%`），NativeAOT 链接器探针因此误报
   “linker not found”（而 `command -v` 与 NDK clang++ 本体都正常；`_WhereLinker=0`
   全局属性会被探针 Output 覆写）。**修复**：运行时保留规范名 `OPENHARMONY`
   （`IsOSPlatform("openharmony")` 语义不变），同时接受 **`LINUX` 别名**（macOS 同款手法），
   并令 `IsLinux()` 为真（`OperatingSystem.cs`，runtime `fix/ohos-rc2` = `417ab220532`；
   MSBuild 侧 `s_isUnixLike = IsLinux || IsOSX || IsBSD || IsHaiku` 已源码核验）。
   CI 验证 run 36552629066 全绿（冷 57m33s）；**设备实证 ✓**：`OS Platform:
   Linux`、探针 `IsOSPlatform(Linux)=True`、`Exec` rc=0（基线为 False + MSB3073）。
   在此之前，设备本地 AOT 构建（selfsign/bundle 重打）不可用，请用**安装器回退签名**与
   **CI 侧**构建路径。
   **2026-09-29 晚更新**：平台修复已随新 SDK 落地，设备本地 AOT selfsign 构建**已打通**并通过
   安装器端到端验证（自建 selfsign 预置 → `signed=28 already_signed=1 failed=0`，install rc=0
   ✓✓）；配方固化为 sdk `eng/ohos-install/build/build-selfsign-device.sh`（含自检）。
   另修复安装器自签缺陷（`sign_all` 会把签名器自身拿去重签 → ETXTBSY ✗→✓，sdk `c1cd3d89c4`）。
   bundle 重打路径待复测。

## 交接（kit/tester）

- 本线 bundle 的 manifest 版本 `1.0.0-preview.28`，manifest band 由安装器按 SDK 版本推导
  （`11.0.100-rc.2`）——bundle 内容与 band 目录名无关。
- 若测试流程引用旧版本号（`1.0.0-preview.24/25/26/27`），请更新到 `.28`；
  `.28` release 已取代 `.27`（`.25` 已删除；`.26`/`.27` 保留历史）。
- 设备冒烟基线（2026-09-29）：install `rc=0`、签名由回退工具完成、workload list 正确、
  workload-TFM publish + 真机运行通过。
