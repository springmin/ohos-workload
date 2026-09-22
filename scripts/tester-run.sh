#!/bin/sh
# tester-run.sh - OpenHarmony MAUI device-test kit: one-command on-device round.
#
# Standalone tester script, also published as the `tester-run.sh` asset on the
# device-test-kit release. It automates the round described by the shipped kit docs:
#
#   0  locate + verify the kit   extracted kit dir (cwd, --kit-dir) or --kit-tar <tar.gz>
#                                (sidecar `sha256sum -c`, then `sh verify-kit.sh` in the
#                                kit root, optional --expect-tree-digest <hex>)
#   1  install                   hdc install -r; the install result code is reported with
#                                9568344 / 9568297 / E00C001 hints
#   2  start                     aa start -b <module.json bundleName> -a EntryAbility, then
#                                a process survival check (pidof / ps fallback)
#   3  capture [<seconds>]       hilog -r, then a filtered hilog recording while the app is
#                                started/used (default 30 s); the same window also records
#                                `hilog -t kmsg` -> kmsg/kmsg.log + kmsg-filtered.log
#   4  probes <dir>              install + run probe1..probe4, per-probe hilog capture of
#                                the PROBE1..PROBE4 lines (kmsg recorded in the same windows)
#   5  collect + pack            captures, module.json of the installed hap, device info
#                                (param get outputs + UDID), ELF-signing evidence (xpm_mode,
#                                fs-verity require_signatures, hap SoInfoSegment magic count,
#                                optional --compare-lib display-sign), kit hashes,
#                                machine-readable summary; tar into
#                                tester-report-<timestamp>.tar.gz
#
# Safety: dry-run by default. Nothing is installed / started / removed / recorded on the
# device unless the matching flag is given (--install --uninstall --start --capture
# --probes). Without a device (hdc list targets) the script refuses device steps: with an
# action flag it stops immediately, with no action flag it only verifies the kit locally
# and prints the plan. --uninstall is explicit and never implied.
#
# Exit codes: 0 = ok (or a dry-run plan was printed with a device reachable),
#             1 = at least one step failed (the archive is still produced),
#             2 = usage error, 3 = no device / refused.
#
# Usage: sh tester-run.sh [--kit-dir <dir> | --kit-tar <tar.gz>] [--expect-tree-digest <hex>]
#          [--hap <hap>]... [--install] [--uninstall] [--start] [--capture [<seconds>]]
#          [--probes <dir>] [--compare-lib <path>] [--out <dir>] [--device <id>] [-h|--help]
#
# Env: HDC (default hdc; may be an absolute path), KIT_BUNDLE_NAME (fallback bundleName
#      when the module.json cannot be read), TMPDIR.
set -e

SCRIPT_VERSION="1 (2026-09-22)"

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { warn "$*"; exit 1; }

usage() {
    cat <<'EOF'
用法: sh tester-run.sh [选项]
  一条命令跑完一轮真机测试：本地校验 kit ->（可选）卸载/安装/启动/抓 hilog/跑探针 -> 打包回传。

交付包（三选一）:
  --kit-dir <dir>            解压后的 kit 目录（含 SHA256SUMS 与 verify-kit.sh）
  --kit-tar <tar.gz>         打包文件（先用同名 .sha256 sidecar 校验，再解压到临时目录）
  （都不给时自动找 ./SHA256SUMS、./device-test-kit/、./device-test-kit.tar.gz；都没有则交互询问）
  --expect-tree-digest <hex> 用发布说明「Integrity」的 tree sha256 绑定解压内容树（可选，建议）

动作（默认全部不执行 = dry-run；给了哪个才做哪个）:
  --install                  真正安装 hap（不加只打印将执行的命令）
  --hap <hap>                用指定 hap 替代 kit 默认包（可重复；主包取第一个）
  --uninstall                先卸载主应用（显式；加了 --probes 时也卸载 4 个探针）
  --start                    启动应用并做存活检查（aa start -a EntryAbility -b <bundle>）
  --capture [<seconds>]      录制过滤后的 hilog + kmsg（默认 30 秒；只启动录制、不做别的）
  --probes <dir>             安装并运行 probe1..probe4（目录内含 4 个探针 hap），逐个抓 PROBE1..4

证据（ELF 代码签名，自动采集；判定规则见研究文档 §6）:
  每个录制窗口同时执行 hdc shell "hilog -t kmsg" -> kmsg/kmsg.log（并过滤出 kmsg-filtered.log）；
  采集 /proc/sys/kernel/xpm/xpm_mode 与 /proc/sys/fs/verity/require_signatures（路径缺失容忍）；
  统计所装 hap 的 SoInfoSegment magic（0x20e7d20e）命中数，均写入 summary.txt。
  --compare-lib <path>       本机对照一个能跑的第三方 app 的 lib：若 PATH 上有
                             binary-sign-tool，就执行 display-sign -inFile <path> 并收下输出

输出:
  --out <dir>                报告目录（默认 ./tester-report）；归档为 <out>-<时间戳>.tar.gz
  --device <id>              指定设备（等价于每条 hdc 命令都加 -t <id>）
  -h, --help                 本帮助

安全:
  * 默认 dry-run：不装、不卸、不启动、不录制，只做本地 kit 校验并打印计划；
  * 没有设备（hdc list targets 为空 / 指定的 --device 不在列表）时拒绝执行设备操作（退出码 3）；
  * 只有 --uninstall 才卸载，且绝不隐式卸载；
  * 退出码：0 成功（或 dry-run 计划）；1 有步骤失败（仍会打包）；2 用法错误；3 无设备/拒绝执行。

环境: HDC（默认 hdc）、KIT_BUNDLE_NAME（读不出 module.json 时的回退 bundle 名）

示例:
  # 1) 预览（安全，不碰设备）
  sh tester-run.sh --kit-tar ./device-test-kit.tar.gz
  # 2) 完整一轮：装 -> 启 -> 录 30 秒 -> 打包
  sh tester-run.sh --kit-dir ./device-test-kit --install --start --capture 30
  # 3) 崩溃排查：安装并运行 4 个探针（每个录 30 秒）
  sh tester-run.sh --kit-dir ./device-test-kit --probes ./probes
  # 4) 只抓 hilog 30 秒（自己在窗口内操作应用）
  sh tester-run.sh --kit-dir ./device-test-kit --capture 30
EOF
}

HDC="${HDC:-hdc}"
DEVICE=""
OUT="./tester-report"
CAPTURE=0
CAPTURE_SECS=30
INSTALL=0
UNINSTALL=0
START=0
PROBES_DIR=""
KIT_DIR=""
KIT_TAR=""
EXPECT_TREE=""
HAPS=""
COMPARE_LIB=""
FALLBACK_BUNDLE="${KIT_BUNDLE_NAME:-com.example.hellomauiapp}"
BUNDLE=""
FILTER_RE='hellomaui|maui|dotnet|openharmonyhost|AppKilledReporter|JsError|appspawn|PROBE'
FILTER_KMSG_RE='xpm|unsigned file|fs_security_verity|libopenharmonyhost|hellomauiapp'
DEV_KEYS="const.product.model const.product.brand const.product.name const.product.devicetype const.product.software.version const.ohos.apiversion const.ohos.fullname const.product.cpu.abilist const.build.characteristics"
FAILURES=0
TMP=""
HILOG_PID=""
KMSG_PID=""
KMSG_RAW=""
KMSG_STARTED=0
KMSG_RESULT="not_captured"
KMSG_LINES=0
KMSG_FILTERED_LINES=0
ARCHIVE=""
UDID=""
TREE_DIGEST=""
KIT_SOURCE="dir"
KIT_TAR_SHA=""
MAIN_HAP_SHA=""
START_RC=""
START_RESULT="skipped"
START_ALIVE="n/a"
START_PID=""
CAPTURE_LINES=0
INSTALL_RESULT=""
XPM_MODE="<unavailable>"
VERITY_REQ="<unavailable>"
SOINFO_HITS="<unavailable>"
SOINFO_VERDICT="unavailable"
SOINFO_HAP=""
COMPARE_LIB_RESULT=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --kit-dir)
            shift
            [ $# -gt 0 ] || { warn "--kit-dir 需要一个目录"; usage >&2; exit 2; }
            KIT_DIR="$1"
            ;;
        --kit-tar)
            shift
            [ $# -gt 0 ] || { warn "--kit-tar 需要一个 .tar.gz"; usage >&2; exit 2; }
            KIT_TAR="$1"
            ;;
        --expect-tree-digest)
            shift
            [ $# -gt 0 ] || { warn "--expect-tree-digest 需要一个 sha256"; usage >&2; exit 2; }
            EXPECT_TREE="$1"
            ;;
        --hap)
            shift
            [ $# -gt 0 ] || { warn "--hap 需要一个 hap 路径"; usage >&2; exit 2; }
            [ -f "$1" ] || { warn "--hap 文件不存在: $1"; exit 2; }
            if [ -z "$HAPS" ]; then HAPS="$1"; else HAPS="$HAPS
$1"; fi
            ;;
        --compare-lib)
            shift
            [ $# -gt 0 ] || { warn "--compare-lib 需要一个 .so 路径"; usage >&2; exit 2; }
            COMPARE_LIB="$1"
            ;;
        --install)   INSTALL=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --start)     START=1 ;;
        --capture)
            CAPTURE=1
            if [ $# -gt 1 ]; then
                case "$2" in
                    ''|*[!0-9]*) : ;;
                    *) CAPTURE_SECS="$2"; shift ;;
                esac
            fi
            ;;
        --probes)
            shift
            [ $# -gt 0 ] || { warn "--probes 需要一个目录"; usage >&2; exit 2; }
            PROBES_DIR="$1"
            ;;
        --out)
            shift
            [ $# -gt 0 ] || { warn "--out 需要一个目录"; usage >&2; exit 2; }
            OUT="$1"
            ;;
        --device)
            shift
            [ $# -gt 0 ] || { warn "--device 需要一个设备 id"; usage >&2; exit 2; }
            DEVICE="$1"
            ;;
        *) warn "未知参数: $1"; usage >&2; exit 2 ;;
    esac
    shift
done

# ---- argument validation -------------------------------------------------------------
case "$CAPTURE_SECS" in ''|*[!0-9]*) die "--capture 的秒数必须是正整数: $CAPTURE_SECS" ;; esac
[ "$CAPTURE_SECS" -ge 1 ] || die "--capture 的秒数必须 >= 1"
case "$OUT" in ''|'/'|'.'|'..') die "无效的 --out 目录: '$OUT'" ;; esac
if [ -n "$KIT_DIR" ] && [ -n "$KIT_TAR" ]; then die "--kit-dir 与 --kit-tar 只能二选一"; fi
if [ -n "$KIT_DIR" ] && [ ! -d "$KIT_DIR" ]; then die "--kit-dir 不是目录: $KIT_DIR"; fi
if [ -n "$KIT_TAR" ] && [ ! -f "$KIT_TAR" ]; then die "--kit-tar 文件不存在: $KIT_TAR"; fi
if [ -n "$PROBES_DIR" ] && [ ! -d "$PROBES_DIR" ]; then die "--probes 目录不存在: $PROBES_DIR"; fi
if [ -n "$EXPECT_TREE" ]; then
    case "$EXPECT_TREE" in *[!0-9a-fA-F]*) die "--expect-tree-digest 不是十六进制 sha256: $EXPECT_TREE" ;; esac
    [ "${#EXPECT_TREE}" -eq 64 ] || die "--expect-tree-digest 需要 64 个十六进制字符"
fi

# kmsg capture target: filled in every recording window (append), scored in step 5
KMSG_RAW="$OUT/kmsg/kmsg.log"

ACTIONS=0
if [ "$INSTALL" = 1 ] || [ "$UNINSTALL" = 1 ] || [ "$START" = 1 ] || [ "$CAPTURE" = 1 ] || [ -n "$PROBES_DIR" ]; then
    ACTIONS=1
fi

hdc_cmd() {
    if [ -n "$DEVICE" ]; then
        "$HDC" -t "$DEVICE" "$@"
    else
        "$HDC" "$@"
    fi
}

hdc_show() {
    if [ -n "$DEVICE" ]; then printf 'hdc -t %s' "$DEVICE"; else printf 'hdc'; fi
}

line_count() {
    if [ -f "$1" ]; then
        wc -l < "$1" | tr -d ' '
    else
        printf '0'
    fi
}

# ---- device gate ---------------------------------------------------------------------
REASON=""
TARGETS=""
if ! command -v "$HDC" >/dev/null 2>&1; then
    REASON="未找到 hdc（HDC=$HDC）"
else
    TARGETS="$("$HDC" list targets 2>&1 || true)"
    LIST="$(printf '%s\n' "$TARGETS" | sed 's/\r$//' | grep -v -e '^[[:space:]]*$' -e '^\[Empty\]$' || true)"
    if [ -z "$LIST" ]; then
        REASON="hdc list targets 为空（未连接设备）"
    elif [ -n "$DEVICE" ]; then
        if ! printf '%s\n' "$LIST" | grep -Fxq -e "$DEVICE"; then
            REASON="--device $DEVICE 不在 hdc list targets 中"
        fi
    fi
fi

DO_DEVICE=0
if [ "$ACTIONS" = 1 ] && [ -z "$REASON" ]; then
    DO_DEVICE=1
fi

if [ -n "$REASON" ]; then
    if [ "$ACTIONS" = 1 ]; then
        warn "无可用设备：$REASON"
        warn "  hdc list targets 输出：${TARGETS:-<空>}"
        warn "  请连接设备（已开 USB 调试）或用 hdc tconn <ip:port> 连接，再用 --device <id> 指定目标。"
        warn "  已拒绝执行设备操作：--install / --uninstall / --start / --capture / --probes 都不会执行。"
        exit 3
    fi
    warn "无可用设备：$REASON"
    warn "  当前是默认 dry-run：只做本地 kit 校验并打印计划，不执行任何设备命令。"
fi

# ---- temp dir + cleanup --------------------------------------------------------------
TMP="$(mktemp -d 2>/dev/null || true)"
if [ -z "$TMP" ]; then
    TMP="${TMPDIR:-/tmp}/tester-run.$$"
    mkdir -p "$TMP"
fi
cleanup() {
    if [ -n "$HILOG_PID" ]; then kill "$HILOG_PID" >/dev/null 2>&1 || true; fi
    if [ -n "$KMSG_PID" ]; then kill "$KMSG_PID" >/dev/null 2>&1 || true; fi
    if [ -n "$TMP" ] && [ -d "$TMP" ]; then rm -rf "$TMP" || true; fi
}
trap cleanup 0 1 2 15
RESULTS="$TMP/results.txt"
: > "$RESULTS"
record() { printf '%s\n' "$*" >> "$RESULTS"; }

stop_hilog() {
    for _sp in "$HILOG_PID" "$KMSG_PID"; do
        [ -n "$_sp" ] || continue
        kill "$_sp" >/dev/null 2>&1 || true
        sleep 1
        kill -9 "$_sp" >/dev/null 2>&1 || true
        wait "$_sp" >/dev/null 2>&1 || true
    done
    HILOG_PID=""
    KMSG_PID=""
}

# ---- kit helpers ---------------------------------------------------------------------
read_bundle() {
    _src="$1"
    BUNDLE=""
    if command -v python3 >/dev/null 2>&1; then
        BUNDLE="$(python3 - "$_src" <<'PY'
import json, sys, zipfile
try:
    with zipfile.ZipFile(sys.argv[1]) as z:
        d = json.loads(z.read('module.json'))
except Exception as exc:
    sys.stderr.write('module.json 解析失败: %s\n' % exc)
    sys.exit(1)
print(((d.get('app') or {}).get('bundleName') or ''))
PY
)" || BUNDLE=""
    elif command -v unzip >/dev/null 2>&1; then
        BUNDLE="$(unzip -p "$_src" module.json 2>/dev/null | sed -n 's/.*"bundleName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    fi
}

extract_module_json() {
    _src="$1"; _dst="$2"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$_src" "$_dst" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    data = z.read('module.json')
open(sys.argv[2], 'wb').write(data)
PY
    elif command -v unzip >/dev/null 2>&1; then
        unzip -p "$_src" module.json > "$_dst"
    else
        return 1
    fi
}

# ---- step 0: locate + verify the kit -------------------------------------------------
log "== 0/5 定位并校验交付包 =="
if [ -n "$KIT_DIR" ]; then
    :
elif [ -n "$KIT_TAR" ]; then
    KIT_SOURCE="tar"
elif [ -f ./SHA256SUMS ] && [ -f ./verify-kit.sh ]; then
    KIT_DIR=.
elif [ -f ./device-test-kit/SHA256SUMS ] && [ -f ./device-test-kit/verify-kit.sh ]; then
    KIT_DIR=./device-test-kit
elif [ -f ./device-test-kit.tar.gz ]; then
    KIT_TAR=./device-test-kit.tar.gz
    KIT_SOURCE="tar"
elif [ -t 0 ]; then
    printf '未找到 kit。请输入解压后的 kit 目录（含 SHA256SUMS）或 kit .tar.gz 路径: ' >&2
    IFS= read -r _ans || die "读不到输入；请用 --kit-dir <dir> 或 --kit-tar <tar.gz> 指定"
    if [ -d "$_ans" ]; then
        KIT_DIR="$_ans"
    elif [ -f "$_ans" ]; then
        KIT_TAR="$_ans"
        KIT_SOURCE="tar"
    else
        die "路径不存在: $_ans（应为解压后的 kit 目录，或 kit .tar.gz）"
    fi
else
    warn "未找到 kit：当前目录没有 SHA256SUMS / device-test-kit / device-test-kit.tar.gz"
    usage >&2
    exit 2
fi

if [ -n "$KIT_TAR" ]; then
    KIT_SOURCE="tar"
    SIDECAR="$KIT_TAR.sha256"
    [ -f "$SIDECAR" ] || die "缺少外层校验文件：$SIDECAR（应为 <kit>.tar.gz.sha256，随 release 一并下载）"
    log "   sha256sum -c $(basename "$SIDECAR")"
    _rc=0
    ( cd "$(dirname "$KIT_TAR")" && sha256sum -c "$(basename "$SIDECAR")" ) || _rc=$?
    [ "$_rc" -eq 0 ] || die "外层 tar.gz 校验失败（见上）；请重新下载 kit 与 sidecar 后再试"
    KIT_TAR_SHA="$(sha256sum "$KIT_TAR" | cut -d' ' -f1)"
    mkdir -p "$TMP/kit"
    log "   解压到临时目录..."
    tar xzf "$KIT_TAR" -C "$TMP/kit" || die "解压失败: $KIT_TAR"
    KIT_DIR="$TMP/kit"
fi

[ -d "$KIT_DIR" ] || die "kit 目录不存在: $KIT_DIR"
[ -f "$KIT_DIR/SHA256SUMS" ] || die "kit 目录没有 SHA256SUMS（不是交付包根目录）: $KIT_DIR"
[ -f "$KIT_DIR/verify-kit.sh" ] || die "kit 目录没有 verify-kit.sh: $KIT_DIR"
KIT_DIR="$(cd "$KIT_DIR" && pwd)"
log "   kit: $KIT_DIR"

_rc=0
if [ -n "$EXPECT_TREE" ]; then
    ( cd "$KIT_DIR" && sh verify-kit.sh --tree-digest --expect-tree-digest "$EXPECT_TREE" ) > "$TMP/verify-kit.log" 2>&1 || _rc=$?
else
    ( cd "$KIT_DIR" && sh verify-kit.sh --tree-digest ) > "$TMP/verify-kit.log" 2>&1 || _rc=$?
fi
cat "$TMP/verify-kit.log"
[ "$_rc" -eq 0 ] || die "kit 自检未通过（verify-kit.sh 退出码 $_rc）；请按上文修复后重试，勿带病安装"
TREE_DIGEST="$(sed -n 's/^.*tree sha256=//p' "$TMP/verify-kit.log" | head -n1)"
log "   kit 自检 OK（tree digest ${TREE_DIGEST:-<未打印>}）"

if [ -n "$HAPS" ]; then
    MAIN_HAP="$(printf '%s\n' "$HAPS" | head -n1)"
else
    MAIN_HAP="$KIT_DIR/hello-maui-app.hap"
fi
[ -f "$MAIN_HAP" ] || die "主 hap 不存在: $MAIN_HAP（API 20 设备请用 --hap <kit>/hello-maui-app-api20.hap）"
read_bundle "$MAIN_HAP"
if [ -z "$BUNDLE" ]; then
    warn "无法从主 hap 读出 bundleName（缺 python3/unzip？），回退为 $FALLBACK_BUNDLE（KIT_BUNDLE_NAME 可覆盖）"
    BUNDLE="$FALLBACK_BUNDLE"
fi
MAIN_HAP_SHA="$(sha256sum "$MAIN_HAP" | cut -d' ' -f1)"
log "   主 hap:  $MAIN_HAP"
log "   bundle:  $BUNDLE"

# ---- step 0b: uninstall (explicit) ---------------------------------------------------
uninstall_one() {
    _ub="$1"; _key="$2"
    _rc=0
    hdc_cmd uninstall "$_ub" > "$OUT/uninstall/$_ub.txt" 2>&1 || _rc=$?
    _out="$(cat "$OUT/uninstall/$_ub.txt" 2>/dev/null || true)"
    case "$_out" in
        *"not installed"*|*"not exist"*|*"not found"*)
            log "   未安装（跳过）: $_ub"
            record "$_key=absent"
            ;;
        *)
            if printf '%s' "$_out" | grep -qi -e 'uninstall.*success'; then
                log "   已卸载: $_ub"
                record "$_key=ok"
            else
                warn "   卸载结果未确认（hdc rc=$_rc）: $_ub（原文: $OUT/uninstall/$_ub.txt）"
                record "$_key=unknown"
                FAILURES=$((FAILURES + 1))
            fi
            ;;
    esac
}

if [ "$UNINSTALL" = 1 ]; then
    log "== 0b/5 卸载（--uninstall，显式） =="
    if [ "$DO_DEVICE" = 0 ]; then
        log "   [dry-run] 将执行: $(hdc_show) uninstall $BUNDLE"
    else
        mkdir -p "$OUT/uninstall"
        uninstall_one "$BUNDLE" "uninstall_main"
        if [ -n "$PROBES_DIR" ]; then
            _i=1
            while [ "$_i" -le 4 ]; do
                uninstall_one "com.example.hellomauiapp.probe$_i" "uninstall_probe$_i"
                _i=$((_i + 1))
            done
        fi
    fi
fi

# ---- step 1: install -----------------------------------------------------------------
install_one() {
    _hap="$1"; _log="$2"
    _rc=0
    hdc_cmd install -r "$_hap" > "$_log" 2>&1 || _rc=$?
    _out="$(cat "$_log" 2>/dev/null || true)"
    _code="$(printf '%s\n' "$_out" | sed -n 's/.*code:\([0-9][0-9]*\).*/\1/p' | head -n1)"
    if printf '%s' "$_out" | grep -q -e 'install bundle successfully'; then
        INSTALL_RESULT="ok"
    elif [ -n "$_code" ]; then
        INSTALL_RESULT="code:$_code"
    else
        INSTALL_RESULT="fail(hdc_rc=$_rc)"
    fi
    case "$INSTALL_RESULT" in
        ok) log "   安装成功: $(basename "$_hap")" ;;
        code:9568344)
            warn "   安装失败 code:9568344（调试 profile 未绑定本设备 UDID）"
            warn "     -> 按 自签说明.md 用自己的证书自签，或把 UDID 回传重签（本归档 device/udid.txt）"
            ;;
        code:9568297)
            warn "   安装失败 code:9568297（minAPIVersion 高于设备 apiCompatibleVersion）"
            warn "     -> API 20 波段设备请改用 hello-maui-app-api20*.hap（--hap 指定）"
            ;;
        *)
            case "$_out" in
                *E00C001*|*'restricted by the organization'*)
                    warn "   安装失败：设备策略关闭了 hdc（E00C001）-> 改用文件管理器安装" ;;
                *[Ss]ignature*|*[Ss]ign*[Vv]erify*)
                    warn "   安装失败：签名校验 -> 按 自签说明.md 用自己的证书重签后再装" ;;
                *)
                    warn "   安装失败（$INSTALL_RESULT，原文: $_log）" ;;
            esac
            ;;
    esac
    [ "$INSTALL_RESULT" = ok ]
}

log "== 1/5 安装 hap（--install） =="
if [ "$INSTALL" = 0 ]; then
    log "   [dry-run] 未加 --install；将执行: $(hdc_show) install -r \"$MAIN_HAP\""
    record "main_install_result=skipped(dry-run)"
elif [ "$DO_DEVICE" = 0 ]; then
    log "   [dry-run] 将执行: $(hdc_show) install -r \"$MAIN_HAP\""
    record "main_install_result=skipped(dry-run)"
else
    mkdir -p "$OUT/install"
    if [ -n "$HAPS" ]; then _hap_list="$HAPS"; else _hap_list="$MAIN_HAP"; fi
    _idx=0
    while IFS= read -r _h; do
        [ -n "$_h" ] || continue
        if [ "$_idx" = 0 ]; then _key="main_install_result"; else _key="extra_install_result$_idx"; fi
        if install_one "$_h" "$OUT/install/$(basename "$_h").log"; then
            record "$_key=ok"
        else
            record "$_key=$INSTALL_RESULT"
            FAILURES=$((FAILURES + 1))
        fi
        _idx=$((_idx + 1))
    done <<EOF
$_hap_list
EOF
fi

# ---- helpers for start / capture -----------------------------------------------------
start_app() {
    _bundle="$1"; _log="$2"
    START_RC=0
    hdc_cmd shell aa start -a EntryAbility -b "$_bundle" > "$_log" 2>&1 || START_RC=$?
    if grep -qi -e 'success' "$_log" 2>/dev/null; then
        START_RESULT="ok"
        log "   aa start OK: $_bundle"
    else
        START_RESULT="fail(hdc_rc=$START_RC)"
        warn "   aa start 未确认成功: $_bundle（原文: $_log）"
    fi
}

proc_alive() {
    _b="$1"
    _p="$(hdc_cmd shell pidof "$_b" 2>/dev/null | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ -z "$_p" ]; then
        _p="$(hdc_cmd shell ps -ef 2>/dev/null | tr -d '\r' | grep -F -e "$_b" | grep -v -e grep | head -n1)"
    fi
    if [ -n "$_p" ]; then
        printf '%s\n' "$_p"
        return 0
    fi
    return 1
}

# ---- ELF-signing evidence helpers (research doc §6) ----------------------------------
# kmsg stream in the same window as hilog; first window truncates, later windows append
kmsg_start() {
    [ -n "$KMSG_RAW" ] || return 0
    mkdir -p "$(dirname "$KMSG_RAW")"
    if [ "$KMSG_STARTED" = 0 ]; then
        : > "$KMSG_RAW"
        KMSG_STARTED=1
    fi
    hdc_cmd shell "hilog -t kmsg" >> "$KMSG_RAW" 2>&1 &
    KMSG_PID=$!
    log "   已开始录制 kmsg -> $KMSG_RAW"
}

# read a device /proc value; missing path / non-numeric output -> <unavailable>
proc_value() {
    _pv="$(hdc_cmd shell "cat $1" 2>/dev/null | tr -d '\r' | sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}')"
    case "$_pv" in
        ''|*[!0-9]*) printf '%s' "<unavailable>" ;;
        *) printf '%s' "$_pv" ;;
    esac
}

# SoInfoSegment magic 0x20e7d20e count (research doc §6.3) on a hap; non-numeric/error -> rc!=0
soinfo_count() {
    [ -f "$1" ] || return 1
    python3 -c 'import re,sys; d=open(sys.argv[1],"rb").read(); print(len(re.findall(bytes.fromhex("20e7d20e"), d)))' "$1" 2>/dev/null || return 1
}

capture_start() {
    _raw="$1"
    mkdir -p "$(dirname "$_raw")"
    hdc_cmd shell hilog -r > "$_raw.clear" 2>&1 || warn "   hilog -r 失败（继续录制）"
    hdc_cmd hilog > "$_raw" 2>&1 &
    HILOG_PID=$!
    kmsg_start
    log "   已开始录制 hilog -> $_raw"
}

capture_stop() {
    stop_hilog
    sleep 1
}

filter_hilog() {
    _raw="$1"; _dst="$2"
    _n=0
    if [ -s "$_raw" ]; then
        _rc=0
        grep -E "$FILTER_RE" "$_raw" > "$_dst" 2>/dev/null || _rc=$?
        if [ "$_rc" -gt 1 ]; then
            warn "   hilog 过滤失败（grep rc=$_rc）"
            : > "$_dst"
        else
            _n="$(line_count "$_dst")"
            if [ "$_rc" -eq 1 ]; then warn "   过滤结果为空（未命中关键字）"; fi
        fi
    else
        warn "   hilog 原始文件为空：hdc hilog 未捕获到数据"
        : > "$_dst"
    fi
    printf '%s' "$_n"
}

# ---- steps 2 + 3: start / capture ----------------------------------------------------
if [ "$START" = 0 ] && [ "$CAPTURE" = 0 ]; then
    log "== 2/5 启动（--start） · 3/5 hilog 录制（--capture） =="
    log "   [dry-run] 未加 --start/--capture；将执行:"
    log "     $(hdc_show) shell aa start -a EntryAbility -b $BUNDLE"
    log "     $(hdc_show) shell hilog -r && $(hdc_show) hilog > hilog/hilog-full.txt   # 录 ${CAPTURE_SECS}s"
    log "     $(hdc_show) shell \"hilog -t kmsg\" >> kmsg/kmsg.log   # 同一窗口（ELF 签名证据）"
    log "     grep -E \"$FILTER_RE\" hilog-full.txt > hilog/hilog-filtered.txt"
    record "start_result=skipped(dry-run)"
    record "capture_result=skipped(dry-run)"
elif [ "$CAPTURE" = 1 ] && [ "$START" = 1 ]; then
    log "== 2-3/5 启动 + hilog/kmsg 录制（--start --capture ${CAPTURE_SECS}s） =="
    log "   先 hilog -r、再开录、再启动（保证抓到启动日志）"
    mkdir -p "$OUT/start" "$OUT/hilog"
    capture_start "$OUT/hilog/hilog-full.txt"
    sleep 1
    start_app "$BUNDLE" "$OUT/start/aa-start.txt"
    sleep "$CAPTURE_SECS"
    capture_stop
    if _p="$(proc_alive "$BUNDLE")"; then
        START_ALIVE="yes"; START_PID="$_p"
        log "   存活检查（+${CAPTURE_SECS}s）：进程存活 pid=$_p"
    else
        START_ALIVE="no"
        warn "   存活检查（+${CAPTURE_SECS}s）：进程不在了（可能已退出/崩溃）"
    fi
    CAPTURE_LINES="$(filter_hilog "$OUT/hilog/hilog-full.txt" "$OUT/hilog/hilog-filtered.txt")"
    log "   hilog 过滤完成：$(line_count "$OUT/hilog/hilog-full.txt") 行原始 / ${CAPTURE_LINES} 行命中"
    record "start_result=$START_RESULT"
    record "process_alive=$START_ALIVE"
    record "process_pid=${START_PID:-<none>}"
    record "survival_after_seconds=$CAPTURE_SECS"
    record "capture_seconds=$CAPTURE_SECS"
    record "capture_result=ok"
    record "hilog_full_lines=$(line_count "$OUT/hilog/hilog-full.txt")"
    record "hilog_filtered_lines=$CAPTURE_LINES"
    if [ "$START_RESULT" != ok ] || [ "$START_ALIVE" = no ]; then FAILURES=$((FAILURES + 1)); fi
elif [ "$START" = 1 ]; then
    log "== 2/5 启动与存活检查（--start） =="
    mkdir -p "$OUT/start"
    start_app "$BUNDLE" "$OUT/start/aa-start.txt"
    sleep 5
    if _p="$(proc_alive "$BUNDLE")"; then
        START_ALIVE="yes"; START_PID="$_p"
        log "   存活检查（+5s）：进程存活 pid=$_p"
    else
        START_ALIVE="no"
        warn "   存活检查（+5s）：进程不在了（可能已退出/崩溃）"
    fi
    record "start_result=$START_RESULT"
    record "process_alive=$START_ALIVE"
    record "process_pid=${START_PID:-<none>}"
    record "survival_after_seconds=5"
    record "capture_result=skipped(not requested)"
    if [ "$START_RESULT" != ok ] || [ "$START_ALIVE" = no ]; then FAILURES=$((FAILURES + 1)); fi
else
    log "== 3/5 hilog/kmsg 录制（--capture ${CAPTURE_SECS}s，不加 --start） =="
    log "   录制窗口内请手动启动/操作应用（或加 --start 让脚本启动）"
    mkdir -p "$OUT/hilog"
    capture_start "$OUT/hilog/hilog-full.txt"
    sleep "$CAPTURE_SECS"
    capture_stop
    CAPTURE_LINES="$(filter_hilog "$OUT/hilog/hilog-full.txt" "$OUT/hilog/hilog-filtered.txt")"
    log "   hilog 过滤完成：$(line_count "$OUT/hilog/hilog-full.txt") 行原始 / ${CAPTURE_LINES} 行命中"
    record "start_result=skipped(not requested)"
    record "capture_seconds=$CAPTURE_SECS"
    record "capture_result=ok"
    record "hilog_full_lines=$(line_count "$OUT/hilog/hilog-full.txt")"
    record "hilog_filtered_lines=$CAPTURE_LINES"
fi

# ---- step 4: probes ------------------------------------------------------------------
log "== 4/5 探针 P1-P4（--probes） =="
if [ -z "$PROBES_DIR" ]; then
    log "   [dry-run] 未加 --probes；跳过（用法: --probes <含 4 个探针 hap 的目录>）"
    record "probes=skipped(dry-run)"
else
    mkdir -p "$OUT/probes"
    : > "$OUT/probes/probe-all-lines.txt"
    _i=1
    while [ "$_i" -le 4 ]; do
        _pb="com.example.hellomauiapp.probe$_i"
        _ph=""
        for _c in "$PROBES_DIR/hello-mauiapp-probe$_i-unsigned.hap" "$PROBES_DIR"/*probe"$_i"*.hap; do
            if [ -f "$_c" ]; then _ph="$_c"; break; fi
        done
        if [ -z "$_ph" ]; then
            warn "   缺 probe$_i 的 hap（找 $PROBES_DIR/*probe$_i*.hap），跳过该探针"
            record "probe${_i}_result=missing_hap"
            FAILURES=$((FAILURES + 1))
            _i=$((_i + 1))
            continue
        fi
        log "   -- probe$_i: $_ph"
        if ! install_one "$_ph" "$OUT/probes/probe$_i-install.txt"; then
            warn "   probe$_i 安装失败（$INSTALL_RESULT），跳过运行"
            record "probe${_i}_result=install_failed"
            FAILURES=$((FAILURES + 1))
            _i=$((_i + 1))
            continue
        fi
        record "probe${_i}_install=ok"
        _raw="$OUT/probes/probe$_i-hilog.txt"
        capture_start "$_raw"
        sleep 1
        start_app "$_pb" "$OUT/probes/probe$_i-start.txt"
        sleep "$CAPTURE_SECS"
        capture_stop
        if _p="$(proc_alive "$_pb")"; then
            record "probe${_i}_alive=yes"
            log "   probe$_i 存活检查（+${CAPTURE_SECS}s）：pid=$_p"
        else
            record "probe${_i}_alive=no"
            log "   probe$_i 存活检查（+${CAPTURE_SECS}s）：进程已退出"
        fi
        _rc=0
        grep -E "PROBE$_i" "$_raw" > "$OUT/probes/probe$_i-lines.txt" 2>/dev/null || _rc=$?
        _n="$(line_count "$OUT/probes/probe$_i-lines.txt")"
        cat "$OUT/probes/probe$_i-lines.txt" >> "$OUT/probes/probe-all-lines.txt" 2>/dev/null || true
        if [ "$_n" -gt 0 ]; then
            log "   probe$_i 完成：${_n} 行 PROBE$_i（$OUT/probes/probe$_i-lines.txt）"
            record "probe${_i}_result=ok"
            record "probe${_i}_lines=$_n"
        else
            warn "   probe$_i 未捕获到 PROBE$_i 行（原文: $_raw）"
            record "probe${_i}_result=no_probe_lines"
            record "probe${_i}_lines=0"
            FAILURES=$((FAILURES + 1))
        fi
        _i=$((_i + 1))
    done
fi

# ---- step 5: collect + pack ----------------------------------------------------------
log "== 5/5 采集与打包 =="
if [ "$DO_DEVICE" = 0 ]; then
    log "   [dry-run] 将采集: hilog+kmsg 捕获、module.json、param get + UDID、kit 哈希、summary.txt"
    log "   [dry-run] 将采集 ELF 签名证据: xpm_mode/require_signatures、SoInfoSegment magic 计数"
    if [ -n "$COMPARE_LIB" ]; then
        log "   [dry-run] 本地对照: binary-sign-tool display-sign -inFile $COMPARE_LIB（若工具在 PATH 上）"
    fi
    log "   [dry-run] 将打包: $(dirname "$OUT")/$(basename "$OUT")-<时间戳>.tar.gz"
else
    mkdir -p "$OUT/meta" "$OUT/device" "$OUT/hilog" "$OUT/kmsg" "$OUT/start" "$OUT/install"
    if extract_module_json "$MAIN_HAP" "$OUT/meta/module.json"; then
        log "   module.json -> $OUT/meta/module.json"
    else
        warn "   无法从 $MAIN_HAP 提取 module.json（缺 python3/unzip）"
    fi
    cp -f "$KIT_DIR/SHA256SUMS" "$OUT/meta/SHA256SUMS"
    cp -f "$TMP/verify-kit.log" "$OUT/meta/verify-kit.log"
    ( cd "$KIT_DIR" && sha256sum ./*.hap ) > "$OUT/meta/kit-hap-sha256.txt" 2>/dev/null || true
    printf 'tester-run.sh version %s\n' "$SCRIPT_VERSION" > "$OUT/meta/tester-run.version.txt"
    if [ -n "$KIT_TAR" ]; then
        printf '%s  %s\n' "$KIT_TAR_SHA" "$(basename "$KIT_TAR")" > "$OUT/meta/kit-tar-sha256.txt"
    fi
    log "   kit 哈希 -> $OUT/meta/（SHA256SUMS、kit-hap-sha256.txt）"

    for _k in $DEV_KEYS; do
        _v="$(hdc_cmd shell param get "$_k" 2>/dev/null | tr -d '\r' | head -n1)"
        printf '%s=%s\n' "$_k" "$_v"
    done > "$OUT/device/param-get.txt"
    hdc_cmd shell bm get -u > "$OUT/device/bm-get-u.txt" 2>&1 || true
    UDID="$(tr -d '\r' < "$OUT/device/bm-get-u.txt" | sed -n 's/.*[Uu][Dd][Ii][Dd][^:]*:[[:space:]]*//p' | head -n1)"
    if [ -z "$UDID" ]; then
        UDID="$(tr -d '\r' < "$OUT/device/bm-get-u.txt" | grep -E -e '^[0-9A-Fa-f]{16,}$' | head -n1)"
    fi
    printf '%s\n' "${UDID:-<unknown>}" > "$OUT/device/udid.txt"
    _model="$(sed -n 's/^const.product.model=//p' "$OUT/device/param-get.txt" | head -n1)"
    _api="$(sed -n 's/^const.ohos.apiversion=//p' "$OUT/device/param-get.txt" | head -n1)"
    _soft="$(sed -n 's/^const.product.software.version=//p' "$OUT/device/param-get.txt" | head -n1)"
    log "   设备信息 -> $OUT/device/（model=$_model api=$_api soft=$_soft udid=${UDID:-<未取到>}）"

    # ---- ELF-signing evidence (research doc §6; read-only, missing paths tolerated) ----
    if [ "$KMSG_STARTED" = 1 ] && [ -s "$KMSG_RAW" ]; then
        _rc=0
        grep -Ei "$FILTER_KMSG_RE" "$KMSG_RAW" > "$OUT/kmsg/kmsg-filtered.log" 2>/dev/null || _rc=$?
        if [ "$_rc" -gt 1 ]; then
            warn "   kmsg 过滤失败（grep rc=$_rc）"
            : > "$OUT/kmsg/kmsg-filtered.log"
        fi
        KMSG_RESULT="ok"
        KMSG_LINES="$(line_count "$KMSG_RAW")"
        KMSG_FILTERED_LINES="$(line_count "$OUT/kmsg/kmsg-filtered.log")"
        if [ "$KMSG_FILTERED_LINES" -eq 0 ]; then
            warn "   kmsg 过滤结果为空（未见 xpm/unsigned file/fs_security_verity 等事件）"
        fi
        log "   kmsg -> $KMSG_RAW（${KMSG_LINES} 行原始 / ${KMSG_FILTERED_LINES} 行命中）"
    elif [ "$KMSG_STARTED" = 1 ]; then
        KMSG_RESULT="empty"
        : > "$OUT/kmsg/kmsg.log"
        : > "$OUT/kmsg/kmsg-filtered.log"
        warn "   kmsg 录制为空（设备可能不暴露 hilog -t kmsg）；保留空证据文件"
    else
        KMSG_RESULT="not_captured"
        : > "$OUT/kmsg/kmsg.log"
        : > "$OUT/kmsg/kmsg-filtered.log"
        warn "   kmsg 未捕获（本轮没有 hilog 录制窗口）"
    fi

    XPM_MODE="$(proc_value /proc/sys/kernel/xpm/xpm_mode)"
    VERITY_REQ="$(proc_value /proc/sys/fs/verity/require_signatures)"
    printf '%s\n' "$XPM_MODE" > "$OUT/device/xpm_mode.txt"
    printf '%s\n' "$VERITY_REQ" > "$OUT/device/require_signatures.txt"
    log "   强制级别: xpm_mode=$XPM_MODE require_signatures=$VERITY_REQ（缺失路径记为 <unavailable>）"

    SOINFO_HAP="$MAIN_HAP"
    SOINFO_HITS="<unavailable>"
    if command -v python3 >/dev/null 2>&1; then
        SOINFO_HITS="$(soinfo_count "$MAIN_HAP" 2>/dev/null || true)"
        [ -n "$SOINFO_HITS" ] || SOINFO_HITS="<error>"
        if [ "$SOINFO_HITS" = 0 ] && [ -z "$HAPS" ]; then
            # no explicit --hap: fall back to the first signed hap found in the kit
            for _c in "$KIT_DIR"/*.hap; do
                [ -f "$_c" ] || continue
                _hv="$(soinfo_count "$_c" 2>/dev/null || true)"
                case "$_hv" in ''|*[!0-9]*) continue ;; esac
                if [ "$_hv" -ge 1 ]; then SOINFO_HITS="$_hv"; SOINFO_HAP="$_c"; break; fi
            done
        fi
    else
        SOINFO_HITS="<unavailable:python3>"
    fi
    case "$SOINFO_HITS" in
        0)  SOINFO_VERDICT="absent(no code signing)" ;;
        ''|*[!0-9]*) SOINFO_VERDICT="unavailable" ;;
        *)  SOINFO_VERDICT="present" ;;
    esac
    log "   SoInfoSegment magic: $SOINFO_HITS hit(s) in $SOINFO_HAP（$SOINFO_VERDICT）"

    COMPARE_LIB_RESULT=""
    if [ -n "$COMPARE_LIB" ]; then
        if ! command -v binary-sign-tool >/dev/null 2>&1; then
            COMPARE_LIB_RESULT="skipped(binary-sign-tool not on PATH)"
            warn "   --compare-lib: PATH 上没有 binary-sign-tool，跳过本地对照（$COMPARE_LIB）"
        elif [ ! -f "$COMPARE_LIB" ]; then
            COMPARE_LIB_RESULT="skipped(file not found)"
            warn "   --compare-lib: 本地文件不存在，跳过对照: $COMPARE_LIB"
        else
            _rc=0
            binary-sign-tool display-sign -inFile "$COMPARE_LIB" > "$OUT/meta/compare-lib-display-sign.txt" 2>&1 || _rc=$?
            _first="$(sed -n '/[^[:space:]]/{p;q;}' "$OUT/meta/compare-lib-display-sign.txt" 2>/dev/null)"
            COMPARE_LIB_RESULT="${_first:-<empty output rc=$_rc>}"
            log "   --compare-lib display-sign: $COMPARE_LIB_RESULT"
        fi
    fi

    {
        printf '# tester-run.sh 摘要（每行 KEY=value；值取第一个 = 之后的内容）\n'
        printf 'script_version=%s\n' "$SCRIPT_VERSION"
        printf 'generated_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
        printf 'dry_run=no\n'
        printf 'device=%s\n' "${DEVICE:-<default>}"
        printf 'udid=%s\n' "${UDID:-<unknown>}"
        printf 'device_model=%s\n' "$_model"
        printf 'device_software=%s\n' "$_soft"
        printf 'device_api=%s\n' "$_api"
        printf 'kit_source=%s\n' "$KIT_SOURCE"
        printf 'kit_dir=%s\n' "$KIT_DIR"
        printf 'kit_tar=%s\n' "$KIT_TAR"
        printf 'kit_tar_sha256=%s\n' "$KIT_TAR_SHA"
        printf 'kit_sidecar_check=ok\n'
        printf 'verify_kit=ok\n'
        printf 'tree_digest=%s\n' "$TREE_DIGEST"
        printf 'expect_tree_digest=%s\n' "$EXPECT_TREE"
        printf 'bundle=%s\n' "$BUNDLE"
        printf 'main_hap=%s\n' "$MAIN_HAP"
        printf 'main_hap_sha256=%s\n' "$MAIN_HAP_SHA"
        printf 'kmsg_capture=%s\n' "$KMSG_RESULT"
        printf 'kmsg_lines=%s\n' "$KMSG_LINES"
        printf 'kmsg_filtered_lines=%s\n' "$KMSG_FILTERED_LINES"
        printf 'xpm_mode=%s\n' "$XPM_MODE"
        printf 'verity_require_signatures=%s\n' "$VERITY_REQ"
        printf 'soinfosegment_hap=%s\n' "$SOINFO_HAP"
        printf 'soinfosegment_magic_hits=%s\n' "$SOINFO_HITS"
        printf 'soinfosegment_magic_verdict=%s\n' "$SOINFO_VERDICT"
        if [ -n "$COMPARE_LIB" ]; then
            printf 'compare_lib=%s\n' "$COMPARE_LIB"
            printf 'compare_lib_display_sign=%s\n' "$COMPARE_LIB_RESULT"
        fi
        cat "$RESULTS" 2>/dev/null || true
        printf 'failures=%s\n' "$FAILURES"
    } > "$OUT/summary.txt"
    log "   摘要 -> $OUT/summary.txt"

    TS="$(date '+%Y%m%d-%H%M%S')"
    ARCHIVE="$(dirname "$OUT")/$(basename "$OUT")-$TS.tar.gz"
    rm -f "$ARCHIVE"
    tar -czf "$ARCHIVE" -C "$(dirname "$OUT")" "$(basename "$OUT")"
    ( cd "$(dirname "$ARCHIVE")" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256" )
    log "   归档 -> $ARCHIVE"
fi

# ---- final ---------------------------------------------------------------------------
if [ "$DO_DEVICE" = 0 ]; then
    log "== dry-run 完成：未执行任何设备操作 =="
    if [ -n "$REASON" ]; then
        log "无设备：$REASON"
        log "  接好设备后重跑；或先用 hdc list targets 查看 id，再用 --device <id> 指定。"
        log "  完整一轮示例: sh tester-run.sh --kit-dir <kit> --install --start --capture 30"
        exit 3
    fi
    log "  完整一轮示例: sh tester-run.sh --kit-dir <kit> --install --start --capture 30"
    exit 0
fi

log "== 完成 =="
log "归档:   $ARCHIVE"
log "sha256: $(cut -d' ' -f1 "$ARCHIVE.sha256")"
log "回传:   把 $ARCHIVE（连同 .sha256）发给交付方 —— 与收到 device-test-kit 相同的渠道"
log "        （邮件/IM/工单）；GitHub 用户可附到 springmin/sdk-ohos 的 issue。"
log "        归档内已有：hilog/、kmsg/、probes/、meta/module.json、device/udid.txt、summary.txt。"
if [ "$FAILURES" -gt 0 ]; then
    warn "本轮有 $FAILURES 项未通过：详情见 $OUT/summary.txt"
    exit 1
fi
exit 0
