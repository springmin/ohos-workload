#!/bin/sh
# tester-run.sh - OpenHarmony MAUI device-test kit: one-command on-device round.
# Standalone tester script, also published as the `tester-run.sh` asset on the device-test-kit
# release; automates the round described by the shipped kit docs:
#   0 locate+verify the kit  extracted kit dir (cwd/--kit-dir) or --kit-tar <tar.gz>: sidecar
#       `sha256sum -c`, then `sh verify-kit.sh` in the kit root, optional --expect-tree-digest
#   1 install   hdc install -r; result code reported with 9568344/9568297/E00C001 hints
#   2 start     aa start -b <module.json bundleName> -a EntryAbility + survival check
#       (pidof / ps fallback)
#   3 capture [<seconds>]  hilog -r, then a filtered recording while the app is started/used
#       (default 30 s); same window records `hilog -t kmsg` -> kmsg/kmsg.log + kmsg-filtered.log
#   4 probes <dir>  install + run probe1..probe4, per-probe hilog capture of the PROBE1..PROBE4
#       lines (kmsg in the same windows); extra-probes <dir>... additionally installs + runs
#       every *.hap of each dir with the same install -> start -> hilog+kmsg window, archiving
#       the captured lines with the P1-P4 ones (probe-all-lines.txt)
#   5 collect+pack  captures, installed-hap module.json, device info (param get + UDID),
#       ELF-signing evidence (xpm_mode, fs-verity require_signatures, hap SoInfoSegment magic
#       count, optional --compare-lib display-sign), app-lib path evidence (hilog greps + bundle
#       libs listing), bootstrap/rawfile failure signatures (hilog-bootstrap.txt + summary
#       counts), device-side payload state (files dir listing + dotnet.marker first line),
#       kit hap self-check (meta/kit-selfcheck.txt: resources.index size, libs/arm64-v8a
#       file count, payload-in-libs marker, abc header version), kit hashes, machine-readable
#       summary; tar -> tester-report-<stamp>.tar.gz
# Safety: dry-run by default. Nothing is installed/started/removed/recorded unless the matching
# flag is given (--install --uninstall --start --capture --probes --extra-probes). Without a
# device (hdc list targets) device steps are refused: with an action flag it stops immediately,
# without one it only verifies the kit locally and prints the plan. --uninstall is explicit and
# never implied. Every bundle name (module.json or KIT_BUNDLE_NAME) is validated as a dotted,
# letter-first [A-Za-z0-9_] name before it can reach an hdc command, so a crafted hap cannot
# smuggle shell metacharacters into `hdc shell aa start -b ...` (A1); uninstall log file names
# are sanitized on top of that.
# Exit codes: 0 = ok (or a dry-run plan printed with a device reachable), 1 = at least one step
# failed (the archive is still produced), 2 = usage error, 3 = no device / refused.
# Usage: sh tester-run.sh [--kit-dir <dir> | --kit-tar <tar.gz>] [--expect-tree-digest <hex>]
#          [--hap <hap>]... [--install] [--uninstall] [--start] [--capture [<seconds>]]
#          [--probes <dir>] [--extra-probes <dir>]... [--compare-lib <path>] [--out <dir>]
#          [--device <id>] [-h|--help]
# Env: HDC (default hdc; may be an absolute path), KIT_BUNDLE_NAME (fallback bundleName when
#      module.json cannot be read), TMPDIR.
set -e

# Bumped with every release repack (随发布重打包递增): the kit release notes' "Bundled
# tester-run.sh" revision.
SCRIPT_VERSION="7 (2026-09-24)"

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
  --extra-probes <dir>       额外安装并运行目录内全部 *.hap（importprobe-a/b/c、importb haps 等），
                             与 P1-P4 相同：逐个 装 -> 启 -> 抓 hilog+kmsg；每个的原始窗口存为
                             probes/extra-<名>-hilog.txt，命中行并入 probes/probe-all-lines.txt；
                             可重复给出，或用逗号分隔多个目录（重复目录只处理一次）

证据（自动采集、缺失容忍；ELF 判定规则见研究文档 §6，真机失败串见验证报告 §4/§7）:
  每个录制窗口同时执行 hdc shell "hilog -t kmsg" -> kmsg/kmsg.log（并过滤出 kmsg-filtered.log）；
  采集 /proc/sys/kernel/xpm/xpm_mode 与 /proc/sys/fs/verity/require_signatures（路径缺失容忍）；
  统计所装 hap 的 SoInfoSegment magic（0x20e7d20e）命中数，均写入 summary.txt。
  app-lib 路径证据（RM1，研究文档 §8.4；缺失容忍）：从本轮已捕获的 hilog 过滤出
  hilog/hilog-applib.txt（SetAppLibPath|appLibPathKey|NativeLibPath|lib path）与
  hilog/hilog-dlopen.txt（dlopen|cannot find library|openharmonyhost），并采集
  ls -l /data/storage/el1/bundle/libs/arm64/ -> device/app-libs-arm64.txt。
  execmem 证据（FIX-XWE；缺失容忍）：同一批 hilog 窗口过滤 OHOS_DOTNET probe:/xwe= ->
  hilog/hilog-execmem.txt；execmem_capture/execmem_lines 写入 summary。
  bootstrap/rawfile 失败特征（真机报告 §4/§7 的失败串，缺失容忍）：对所有已捕获 hilog 窗口再
  过滤 GetRawFileContent|bootstrap failed|bootstrap retry|BusinessError|900002|900003|
  ZIP entry|destination path|Load native module failed|symbol not found|cannot find library|
  Museum|MUSL-LDSO|check ns accessible -> hilog/hilog-bootstrap.txt；命中计数写入 summary
  （bootstrap_errors/rawfile_errors/libload_errors；未录到窗口记 <unavailable>）。
  设备侧 payload 状态（缺失容忍）：ls -l /data/storage/el2/base/haps/entry/files/ 保留
  dotnet*/payload 行 -> device/payload-files.txt，再读一行 files/dotnet.marker ->
  device/payload-marker.txt；payload_present/payload_files/payload_marker 写入 summary。
  kit 侧 hap 自检（本地，独立于 verify-kit）：每个 kit hap 的 resources.index 有无与大小、
  libs/arm64-v8a 计数、ets/modules.abc 头版本（PANDA 头部 0x0c 起 4 字节）-> meta/kit-selfcheck.txt
  （≤10 行）；kit_index_ok 写入 summary。dry-run 只打印不落盘。
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
  # 5) P1-P4 + 额外探针（importprobe-a/b/c、importb haps 等，每个探针各录 30 秒）
  sh tester-run.sh --kit-dir ./device-test-kit --probes ./probes --extra-probes ./importb-haps
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
EXTRA_PROBES_DIRS=""
KIT_DIR=""
KIT_TAR=""
EXPECT_TREE=""
HAPS=""
COMPARE_LIB=""
FALLBACK_BUNDLE="${KIT_BUNDLE_NAME:-com.example.hellomauiapp}"
BUNDLE=""
BUNDLE_UNSAFE=0
FILTER_RE='hellomaui|maui|dotnet|openharmonyhost|AppKilledReporter|JsError|appspawn|PROBE'
FILTER_KMSG_RE='xpm|unsigned file|fs_security_verity|libopenharmonyhost|hellomauiapp'
FILTER_APPLIB_RE='SetAppLibPath|appLibPathKey|NativeLibPath|lib path'
FILTER_DLOPEN_RE='dlopen|cannot find library|openharmonyhost'
# Host executable-memory policy/probe (FIX-XWE): the W^X decision line and the one-line probe
# result the host writes on the first launch path (tag OHOS_DOTNET).
FILTER_EXECMEM_RE='OHOS_DOTNET probe:|xwe='
# Device findings (bootstrap/rawfile/hap-load failures) reproduce as these signatures; the
# filter is deliberately wider than the summary error counters below.
FILTER_BOOTSTRAP_RE='GetRawFileContent|bootstrap failed|bootstrap retry|BusinessError|900002|900003|ZIP entry|destination path|Load native module failed|symbol not found|cannot find library|Museum|MUSL-LDSO|check ns accessible'
FILTER_BOOTSTRAP_ERR_RE='bootstrap failed|bootstrap .*retry'
FILTER_RAWFILE_ERR_RE='GetRawFileContent|BusinessError|900002|900003|ZIP entry|destination path'
FILTER_LIBLOAD_ERR_RE='Load native module failed|symbol not found|cannot find library|MUSL-LDSO|check ns accessible'
# App sandbox files dir: dotnet/ payload + dotnet.marker (read-only, absence tolerated).
DEV_FILES_DIR='/data/storage/el2/base/haps/entry/files'
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
APPLIB_RESULT="not_captured"
APPLIB_LINES=0
DLOPEN_RESULT="not_captured"
DLOPEN_LINES=0
EXECMEM_RESULT="not_captured"
EXECMEM_LINES=0
APPLIBS_DIR_RESULT="not_captured"
APPLIBS_DIR_LINES=0
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
BOOTSTRAP_RESULT="not_captured"
BOOTSTRAP_LINES=0
BOOTSTRAP_ERRORS="<unavailable>"
RAWFILE_ERRORS="<unavailable>"
LIBLOAD_ERRORS="<unavailable>"
PAYLOAD_PRESENT="<unavailable>"
PAYLOAD_FILES_LINES=0
PAYLOAD_MARKER="<unavailable>"
KIT_INDEX_OK="<unavailable>"

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
        --extra-probes)
            shift
            [ $# -gt 0 ] || { warn "--extra-probes 需要一个目录（可重复给出或用逗号分隔多个）"; usage >&2; exit 2; }
            _ep_rest="$1"
            while [ -n "$_ep_rest" ]; do
                case "$_ep_rest" in
                    *,*) _ep_one="${_ep_rest%%,*}"; _ep_rest="${_ep_rest#*,}" ;;
                    *)   _ep_one="$_ep_rest"; _ep_rest="" ;;
                esac
                _ep_one="${_ep_one%/}"
                [ -n "$_ep_one" ] || { warn "--extra-probes 目录不能为空（逗号分隔时有空项）"; usage >&2; exit 2; }
                if [ -z "$EXTRA_PROBES_DIRS" ]; then
                    EXTRA_PROBES_DIRS="$_ep_one"
                else
                    EXTRA_PROBES_DIRS="$EXTRA_PROBES_DIRS
$_ep_one"
                fi
            done
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

# ---- bundle-name validation (security, A1) -------------------------------------------
# A bundle name is interpolated into `hdc shell aa start -a EntryAbility -b <bundle>` /
# `pidof` / `ps` / uninstall commands. hdc joins its argv into one device-side shell command
# line, so a hap's module.json bundleName (--hap / --extra-probes) or KIT_BUNDLE_NAME with
# shell metacharacters would run with hdc-shell privileges on the device. The only accepted
# shape is the dotted, letter-first [A-Za-z0-9_] form used by the kit's haps.
#
# The first `case` must stay first: it rejects newlines, carriage returns, tabs, every other
# control character and spaces byte by byte. grep -E matches line by line, so a name whose
# second line looks valid would slip through a regex-only check (the PoC payload does).
is_safe_bundle_name() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    printf '%s' "$1" | grep -Eq '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'
}

# A bundle name for logs/errors: never echo the raw value (it can carry control characters
# or shell metacharacters and turn a log line into the next injection).
bundle_for_log() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '?' | cut -c1-64
}

# Gate a bundle name right before it reaches an hdc command (start / pidof / uninstall).
require_safe_bundle_name() {
    is_safe_bundle_name "$1" || die "拒绝执行：bundleName 未通过安全校验（只允许 [A-Za-z][A-Za-z0-9_]* 的点分段形式）: '$(bundle_for_log "$1")'"
}

# KIT_BUNDLE_NAME is the second bundle-name source; it must be valid before it can be used.
require_safe_bundle_name "$FALLBACK_BUNDLE"

# ---- argument validation -------------------------------------------------------------
# --extra-probes: drop directories named twice (repeatable + comma forms are equivalent)
if [ -n "$EXTRA_PROBES_DIRS" ]; then
    _ep_uniq=""
    while IFS= read -r _ep_d; do
        [ -n "$_ep_d" ] || continue
        if ! printf '%s\n' "$_ep_uniq" | grep -Fxq -e "$_ep_d"; then
            if [ -z "$_ep_uniq" ]; then
                _ep_uniq="$_ep_d"
            else
                _ep_uniq="$_ep_uniq
$_ep_d"
            fi
        fi
    done <<EOF
$EXTRA_PROBES_DIRS
EOF
    EXTRA_PROBES_DIRS="$_ep_uniq"
fi

case "$CAPTURE_SECS" in ''|*[!0-9]*) die "--capture 的秒数必须是正整数: $CAPTURE_SECS" ;; esac
[ "$CAPTURE_SECS" -ge 1 ] || die "--capture 的秒数必须 >= 1"
case "$OUT" in ''|'/'|'.'|'..') die "无效的 --out 目录: '$OUT'" ;; esac
if [ -n "$KIT_DIR" ] && [ -n "$KIT_TAR" ]; then die "--kit-dir 与 --kit-tar 只能二选一"; fi
if [ -n "$KIT_DIR" ] && [ ! -d "$KIT_DIR" ]; then die "--kit-dir 不是目录: $KIT_DIR"; fi
if [ -n "$KIT_TAR" ] && [ ! -f "$KIT_TAR" ]; then die "--kit-tar 文件不存在: $KIT_TAR"; fi
if [ -n "$PROBES_DIR" ] && [ ! -d "$PROBES_DIR" ]; then die "--probes 目录不存在: $PROBES_DIR"; fi
if [ -n "$EXTRA_PROBES_DIRS" ]; then
    while IFS= read -r _ep_d; do
        [ -n "$_ep_d" ] || continue
        [ -d "$_ep_d" ] || die "--extra-probes 目录不存在: $_ep_d"
    done <<EOF
$EXTRA_PROBES_DIRS
EOF
fi
if [ -n "$EXPECT_TREE" ]; then
    case "$EXPECT_TREE" in *[!0-9a-fA-F]*) die "--expect-tree-digest 不是十六进制 sha256: $EXPECT_TREE" ;; esac
    [ "${#EXPECT_TREE}" -eq 64 ] || die "--expect-tree-digest 需要 64 个十六进制字符"
fi

# kmsg capture target: filled in every recording window (append), scored in step 5
KMSG_RAW="$OUT/kmsg/kmsg.log"

ACTIONS=0
if [ "$INSTALL" = 1 ] || [ "$UNINSTALL" = 1 ] || [ "$START" = 1 ] || [ "$CAPTURE" = 1 ] || [ -n "$PROBES_DIR" ] || [ -n "$EXTRA_PROBES_DIRS" ]; then
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

# Matching-line count of a grep -E pattern in a file: grep -c prints 0 and exits 1 when nothing
# matches, so the count is normalized here (never propagate the rc, callers run under set -e).
match_count() {
    _mc="$(grep -E -c -- "$1" "$2" 2>/dev/null || true)"
    case "$_mc" in
        ''|*[!0-9]*) printf '0' ;;
        *) printf '%s' "$_mc" ;;
    esac
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
        warn "  已拒绝执行设备操作：--install / --uninstall / --start / --capture / --probes / --extra-probes 都不会执行。"
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
    trap - 0 1 2 15
    if [ -n "$HILOG_PID" ]; then kill "$HILOG_PID" >/dev/null 2>&1 || true; fi
    if [ -n "$KMSG_PID" ]; then kill "$KMSG_PID" >/dev/null 2>&1 || true; fi
    if [ -n "$TMP" ] && [ -d "$TMP" ]; then rm -rf "$TMP" || true; fi
}
trap cleanup 0
# A signal must end the round. With `trap cleanup 0 1 2 15` a TERM only ran cleanup and
# the script continued issuing device commands against the removed $TMP (found via the
# selftest: TERM during a capture window kept going into the remaining steps).
trap 'exit 1' 1 2 15
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
    BUNDLE_UNSAFE=0
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
    # Never hand a name from a hap to the rest of the script unvalidated: the callers in
    # step 0 / --uninstall / --extra-probes treat BUNDLE_UNSAFE=1 as a hard reject.
    if [ -n "$BUNDLE" ] && ! is_safe_bundle_name "$BUNDLE"; then
        BUNDLE_UNSAFE=1
        BUNDLE=""
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

# ---- extra-probe helpers (--extra-probes) --------------------------------------------
# Summary key of one extra hap:
#   hello-mauiapp-importprobe-a-unsigned.hap -> importprobe-a
#   hello-maui-app-importb.hap               -> importb
#   hello-maui-app.hap                       -> app
# Sanitized to [A-Za-z0-9._-] so it is safe in summary.txt keys and file names.
extra_probe_key() {
    _ek="$1"
    _ek="${_ek##*/}"
    _ek="${_ek%.hap}"
    case "$_ek" in
        *-unsigned) _ek="${_ek%-unsigned}" ;;
        *-signed)   _ek="${_ek%-signed}" ;;
    esac
    case "$_ek" in
        hello-maui-app-*) _ek="${_ek#hello-maui-app-}" ;;
        hello-maui-app)   _ek="app" ;;
        hello-mauiapp-*)  _ek="${_ek#hello-mauiapp-}" ;;
    esac
    [ -n "$_ek" ] || _ek="probe"
    printf '%s' "$_ek" | tr -c 'A-Za-z0-9._-' '_'
}

# grep -E pattern for the lines of one extra probe: the key with `-` matching `-`/`_`/space
# (importprobe-a -> importprobe[-_ ]?a), plus the leading name token (importprobe) so the
# probe's ability-level lines (TAG=IMPORTPROBE) are kept too.
extra_probe_marker() {
    _em_key="$1"
    _em_full="$(printf '%s' "$_em_key" | sed 's/\./\\./g' | sed 's/-/[-_ ]?/g')"
    _em_pre="${_em_key%%-*}"
    _em_pre="$(printf '%s' "$_em_pre" | sed 's/\./\\./g')"
    if [ "$_em_pre" != "$_em_key" ] && [ "${#_em_pre}" -ge 4 ]; then
        printf '%s|%s' "$_em_full" "$_em_pre"
    else
        printf '%s' "$_em_full"
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
    # The check above read the tarball and compared it against the sidecar, so the verified
    # digest can be taken from that single-line sidecar instead of reading ~90-120 MB again
    # in this same run. Anything unexpected (extra lines, non-hex value) falls back to
    # hashing the file.
    KIT_TAR_SHA=""
    if [ "$(wc -l < "$SIDECAR" | tr -d ' ')" = 1 ]; then
        _sha_cand="$(cut -d' ' -f1 < "$SIDECAR")"
        case "$_sha_cand" in
            *[!0-9a-fA-F]*|'') ;;
            *) [ "${#_sha_cand}" -eq 64 ] && KIT_TAR_SHA="$_sha_cand" ;;
        esac
    fi
    [ -n "$KIT_TAR_SHA" ] || KIT_TAR_SHA="$(sha256sum "$KIT_TAR" | cut -d' ' -f1)"
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

# The SHA256SUMS hashes are reused below (main-hap hash + kit-hap-sha256.txt) instead of
# reading every hap again: verify-kit.sh runs a real sha256sum -c between these two snapshots,
# so if the inode/size/mtime set is identical the recorded hashes describe these exact bytes.
# Any movement anywhere in the kit root disables the reuse and the hashes are computed again.
kit_root_stat_snapshot() {
    # One find + one batched stat pass: a per-file loop costs a process spawn each (~40 ms on
    # device) and would eat the reads this reuse is meant to save.
    ( cd "$KIT_DIR" || exit 1
      if command -v xargs >/dev/null 2>&1; then
          find . -maxdepth 1 -type f -print 2>/dev/null | LC_ALL=C sort | xargs -r stat -c '%n %i %s %Y' 2>/dev/null
      else
          find . -maxdepth 1 -type f -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r _rel; do
              printf '%s %s\n' "$_rel" "$(stat -c '%i %s %Y' -- "$_rel" 2>/dev/null || stat -f '%i %z %m' -- "$_rel" 2>/dev/null || printf nostat)"
          done
      fi ) || true
}

# Verified hashes of the kit haps: from the SHA256SUMS that verify-kit.sh just checked when
# the snapshot proved nothing moved, otherwise from a fresh read (never borrowed across runs).
kit_hap_hashes() {
    if [ "$KIT_SUMS_TRUSTED" = 1 ]; then
        awk '{ n=substr($0,67); sub(/^\*/, "", n); sub(/^\.\//, "", n); if (n ~ /\.hap$/) printf "%s  ./%s\n", substr($0,1,64), n }' \
            "$KIT_DIR/SHA256SUMS" | LC_ALL=C sort -k2
    else
        ( cd "$KIT_DIR" && sha256sum ./*.hap 2>/dev/null ) | LC_ALL=C sort -k2
    fi
}

# Hash of one kit file for the summary: the verified SHA256SUMS entry when available,
# otherwise a direct read (e.g. a --hap path outside the kit).
kit_hash_of() {
    _kh_rel="${1#"$KIT_DIR"/}"
    if [ "$KIT_SUMS_TRUSTED" = 1 ]; then
        _kh="$(awk -v n="./$_kh_rel" '$2 == n { print $1; exit }' "$TMP/kit-hap-sha256.txt")"
        [ -n "$_kh" ] && { printf '%s\n' "$_kh"; return 0; }
    fi
    sha256sum "$1" | cut -d' ' -f1
}

# ---- kit hap self-check (local; complements verify-kit.sh, no heavy re-implementation) ----
# One line per kit hap: resources.index size, libs/arm64-v8a entry count, abc header version
# ("PANDA" magic + version bytes at 0x0c, same shape build-arkts-shell.sh checks). The device
# failure classes it localizes: missing resources.index ("name is empty"), a hap that lost its
# libs, an abc the device runtime rejects. Reading zip central directories is cheap; the files
# stay untouched. Output: at most 10 lines, first line a comment.
kit_selfcheck() {
    printf '# kit hap self-check (tester-run.sh v%s): resources.index / libs/arm64-v8a / payload-in-libs / abc\n' "${SCRIPT_VERSION%% *}"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$KIT_DIR" <<'PY'
import os, sys, zipfile
kit = sys.argv[1]
haps = sorted(n for n in os.listdir(kit) if n.endswith('.hap'))
if not haps:
    print('# no *.hap in the kit root')
for name in haps:
    try:
        with zipfile.ZipFile(os.path.join(kit, name)) as z:
            names = z.namelist()
            idx = z.getinfo('resources.index').file_size if 'resources.index' in names else 'missing'
            libs = sum(1 for n in names if n.startswith('libs/arm64-v8a/') and not n.endswith('/'))
            payload = 'yes' if 'libs/arm64-v8a/.dotnet-payload.json' in names else 'no'
            abc = 'missing'
            for n in sorted(n for n in names if n.endswith('.abc')):
                raw = z.read(n)[:16]
                if raw[:5] == b'PANDA':
                    abc = '%s:%s:%d' % (n, '.'.join(str(b) for b in raw[12:16]), z.getinfo(n).file_size)
                    break
        print('%s index=%s libs=%s payload=%s abc=%s' % (name, idx, libs, payload, abc))
    except Exception as exc:
        print('%s error=%s' % (name, exc))
PY
    elif command -v unzip >/dev/null 2>&1; then
        for _sf in "$KIT_DIR"/*.hap; do
            [ -f "$_sf" ] || continue
            _sname="$(basename "$_sf")"
            _slist="$(unzip -l "$_sf" 2>/dev/null || true)"
            _sidx="$(printf '%s\n' "$_slist" | awk '$NF == "resources.index" { printf "%s", $1; found = 1; exit } END { if (!found) printf "missing" }')"
            _slibs="$(printf '%s\n' "$_slist" | awk '$NF ~ /^libs\/arm64-v8a\/.+/ { n++ } END { print n + 0 }')"
            _spl="no"
            printf '%s\n' "$_slist" | grep -qF -- "libs/arm64-v8a/.dotnet-payload.json" && _spl="yes"
            _sabc="missing"
            _sver="$(unzip -p "$_sf" ets/modules.abc 2>/dev/null | dd bs=1 count=16 2>/dev/null | od -An -v -tu1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) a[++n] = $i } END { if (n >= 16 && a[1] == 80 && a[2] == 65 && a[3] == 78 && a[4] == 68 && a[5] == 65) printf "%d.%d.%d.%d", a[13], a[14], a[15], a[16] }')"
            [ -n "$_sver" ] && _sabc="ets/modules.abc:$_sver"
            printf '%s index=%s libs=%s payload=%s abc=%s\n' "$_sname" "$_sidx" "$_slibs" "$_spl" "$_sabc"
        done
    else
        printf '# kit self-check unavailable (need python3 or unzip)\n'
    fi
}

# kit_index_ok from a kit-selfcheck emission: yes = every hap carries resources.index.
kit_index_ok_of() {
    if [ ! -s "$1" ] || ! grep -Eq '^[^#].*index=' "$1" 2>/dev/null; then
        printf '<unavailable>'
    elif grep -Eq '^[^#].*index=missing' "$1" 2>/dev/null; then
        printf 'no'
    else
        printf 'yes'
    fi
}

KIT_SNAP_BEFORE="$(kit_root_stat_snapshot)"
_rc=0
if [ -n "$EXPECT_TREE" ]; then
    ( cd "$KIT_DIR" && sh verify-kit.sh --tree-digest --expect-tree-digest "$EXPECT_TREE" ) > "$TMP/verify-kit.log" 2>&1 || _rc=$?
else
    ( cd "$KIT_DIR" && sh verify-kit.sh --tree-digest ) > "$TMP/verify-kit.log" 2>&1 || _rc=$?
fi
KIT_SNAP_AFTER="$(kit_root_stat_snapshot)"
cat "$TMP/verify-kit.log"
[ "$_rc" -eq 0 ] || die "kit 自检未通过（verify-kit.sh 退出码 $_rc）；请按上文修复后重试，勿带病安装"
TREE_DIGEST="$(sed -n 's/^.*tree sha256=//p' "$TMP/verify-kit.log" | head -n1)"
KIT_SUMS_TRUSTED=0
# Fail closed: an empty snapshot (stat/xargs unavailable) never arms the reuse.
if [ -n "$KIT_SNAP_BEFORE" ] && [ "$KIT_SNAP_BEFORE" = "$KIT_SNAP_AFTER" ]; then
    KIT_SUMS_TRUSTED=1
fi
if [ "$KIT_SUMS_TRUSTED" = 1 ]; then
    log "   kit 自检 OK（tree digest ${TREE_DIGEST:-<未打印>}；hap 哈希复用本次已校验的 SHA256SUMS）"
else
    log "   kit 自检 OK（tree digest ${TREE_DIGEST:-<未打印>}；校验窗口内文件发生变化，hap 哈希重算）"
fi

# Local hap-level self-check (complements verify-kit.sh, independent of the device): printed in
# every round (dry-run included), archived as meta/kit-selfcheck.txt only in a device round.
kit_selfcheck > "$TMP/kit-selfcheck.txt" 2> "$TMP/kit-selfcheck.err" || true
KIT_INDEX_OK="$(kit_index_ok_of "$TMP/kit-selfcheck.txt")"
log "   kit hap 自检（本地）: kit_index_ok=$KIT_INDEX_OK"
while IFS= read -r _ks_line; do
    log "     $_ks_line"
done < "$TMP/kit-selfcheck.txt"
if [ -s "$TMP/kit-selfcheck.err" ]; then
    warn "   kit hap 自检有 stderr 输出（不影响本轮；见下）"
    while IFS= read -r _ks_err; do
        warn "     $_ks_err"
    done < "$TMP/kit-selfcheck.err"
fi

if [ -n "$HAPS" ]; then
    MAIN_HAP="$(printf '%s\n' "$HAPS" | head -n1)"
else
    MAIN_HAP="$KIT_DIR/hello-maui-app.hap"
fi
[ -f "$MAIN_HAP" ] || die "主 hap 不存在: $MAIN_HAP（API 20 设备请用 --hap <kit>/hello-maui-app-api20.hap）"
read_bundle "$MAIN_HAP"
if [ "$BUNDLE_UNSAFE" = 1 ]; then
    die "主 hap 的 module.json bundleName 未通过安全校验（含控制字符/空格/shell 元字符）；拒绝安装/启动: $MAIN_HAP"
fi
if [ -z "$BUNDLE" ]; then
    warn "无法从主 hap 读出 bundleName（缺 python3/unzip？），回退为 $FALLBACK_BUNDLE（KIT_BUNDLE_NAME 可覆盖）"
    BUNDLE="$FALLBACK_BUNDLE"
fi
require_safe_bundle_name "$BUNDLE"
# One map for the whole run: verified SHA256SUMS values when the snapshot proves the bytes
# did not move, otherwise the fresh sha256sum ./*.hap output (same content the old path wrote
# to meta/kit-hap-sha256.txt, now read once).
kit_hap_hashes > "$TMP/kit-hap-sha256.txt"
MAIN_HAP_SHA="$(kit_hash_of "$MAIN_HAP")"
log "   主 hap:  $MAIN_HAP"
log "   bundle:  $BUNDLE"

# ---- step 0b: uninstall (explicit) ---------------------------------------------------
# Uninstall log file name for a bundle name. The validator above already guarantees the
# alphabet, but the name still builds a path under $OUT/uninstall: refuse anything that
# could leave that directory (a '/', an absolute path, '' , '.' or any '..' segment).
uninstall_log_name() {
    case "$1" in
        ''|.|..|/*|*/*|*..*) die "uninstall 日志文件名不安全（拒绝 / 与 ..）: '$(bundle_for_log "$1")'" ;;
    esac
    case "$1" in
        *[!A-Za-z0-9._-]*) die "uninstall 日志文件名含不安全字符: '$(bundle_for_log "$1")'" ;;
    esac
    printf '%s.txt' "$1"
}

uninstall_one() {
    _ub="$1"; _key="$2"
    require_safe_bundle_name "$_ub"
    _ulog="$(uninstall_log_name "$_ub")"
    _rc=0
    hdc_cmd uninstall "$_ub" > "$OUT/uninstall/$_ulog" 2>&1 || _rc=$?
    _out="$(cat "$OUT/uninstall/$_ulog" 2>/dev/null || true)"
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
                warn "   卸载结果未确认（hdc rc=$_rc）: $_ub（原文: $OUT/uninstall/$_ulog）"
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
        if [ -n "$EXTRA_PROBES_DIRS" ]; then
            while IFS= read -r _xd; do
                [ -n "$_xd" ] || continue
                for _xh in "$_xd"/*.hap; do
                    [ -f "$_xh" ] || continue
                    _xkey="$(extra_probe_key "$_xh")"
                    _save_bundle="$BUNDLE"
                    read_bundle "$_xh"
                    _xbundle="$BUNDLE"
                    _xunsafe="$BUNDLE_UNSAFE"
                    BUNDLE="$_save_bundle"
                    if [ "$_xunsafe" = 1 ]; then
                        warn "   拒绝 $(basename "$_xh") 的 bundleName（含不安全字符），跳过卸载"
                        record "uninstall_extraprobe_${_xkey}=unsafe_bundle"
                    elif [ -n "$_xbundle" ]; then
                        uninstall_one "$_xbundle" "uninstall_extraprobe_$_xkey"
                    else
                        warn "   读不出 $(basename "$_xh") 的 bundleName，跳过卸载"
                        record "uninstall_extraprobe_${_xkey}=unknown_bundle"
                    fi
                done
            done <<EOF
$EXTRA_PROBES_DIRS
EOF
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
    require_safe_bundle_name "$_bundle"
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
    require_safe_bundle_name "$_b"
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

# Append the lines of one captured hilog file matching $1 (regex) into $3 (append target).
# No match (grep rc=1) is fine - the evidence is optional; only hard errors warn.
filter_append() {
    _fa_re="$1"; _fa_src="$2"; _fa_dst="$3"
    _fa_rc=0
    grep -E "$_fa_re" "$_fa_src" >> "$_fa_dst" 2>/dev/null || _fa_rc=$?
    if [ "$_fa_rc" -gt 1 ]; then
        warn "   hilog 过滤失败（grep rc=$_fa_rc）: $(basename "$_fa_src")"
    fi
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
if [ -n "$EXTRA_PROBES_DIRS" ]; then
    log "== 4/5 探针 P1-P4（--probes）+ 额外探针（--extra-probes） =="
else
    log "== 4/5 探针 P1-P4（--probes） =="
fi
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

# ---- step 4b: extra probes (--extra-probes) ------------------------------------------
# Every *.hap under each --extra-probes dir runs like a P1-P4 probe: install -> start ->
# hilog+kmsg window -> extracted lines. Install failures (unsigned / signature / api) are
# recorded and skipped; the raw window is archived either way.
if [ -n "$EXTRA_PROBES_DIRS" ]; then
    log "   额外探针目录: $(printf '%s' "$EXTRA_PROBES_DIRS" | tr '\n' ',')"
    mkdir -p "$OUT/probes"
    [ -f "$OUT/probes/probe-all-lines.txt" ] || : > "$OUT/probes/probe-all-lines.txt"
    _xp_seen=""
    while IFS= read -r _xd; do
        [ -n "$_xd" ] || continue
        _xp_dir_haps=0
        for _xh in "$_xd"/*.hap; do
            [ -f "$_xh" ] || continue
            _xp_dir_haps=$((_xp_dir_haps + 1))
            _xkey="$(extra_probe_key "$_xh")"
            _xbase="$_xkey"
            _xn=2
            while printf '%s\n' "$_xp_seen" | grep -Fxq -e "$_xkey"; do
                _xkey="$_xbase-$_xn"
                _xn=$((_xn + 1))
            done
            if [ -z "$_xp_seen" ]; then
                _xp_seen="$_xkey"
            else
                _xp_seen="$_xp_seen
$_xkey"
            fi
            log "   -- extra[$_xkey]: $_xh"
            _save_bundle="$BUNDLE"
            read_bundle "$_xh"
            _xbundle="$BUNDLE"
            _xunsafe="$BUNDLE_UNSAFE"
            BUNDLE="$_save_bundle"
            if [ "$_xunsafe" = 1 ]; then
                warn "   拒绝 $(basename "$_xh") 的 module.json bundleName（含不安全字符），跳过该额外探针"
                record "extraprobe_${_xkey}_result=unsafe_bundle"
                FAILURES=$((FAILURES + 1))
                continue
            fi
            if [ -z "$_xbundle" ]; then
                warn "   读不出 $(basename "$_xh") 的 bundleName，跳过该额外探针"
                record "extraprobe_${_xkey}_result=no_bundle"
                FAILURES=$((FAILURES + 1))
                continue
            fi
            record "extraprobe_${_xkey}_bundle=$_xbundle"
            if ! install_one "$_xh" "$OUT/probes/extra-${_xkey}-install.txt"; then
                warn "   额外探针 $_xkey 安装失败（$INSTALL_RESULT），跳过运行（原文: $OUT/probes/extra-${_xkey}-install.txt）"
                record "extraprobe_${_xkey}_result=install_failed"
                FAILURES=$((FAILURES + 1))
                continue
            fi
            record "extraprobe_${_xkey}_install=ok"
            _raw="$OUT/probes/extra-${_xkey}-hilog.txt"
            capture_start "$_raw"
            sleep 1
            start_app "$_xbundle" "$OUT/probes/extra-${_xkey}-start.txt"
            sleep "$CAPTURE_SECS"
            capture_stop
            if _p="$(proc_alive "$_xbundle")"; then
                record "extraprobe_${_xkey}_alive=yes"
                log "   $_xkey 存活检查（+${CAPTURE_SECS}s）：pid=$_p"
            else
                record "extraprobe_${_xkey}_alive=no"
                log "   $_xkey 存活检查（+${CAPTURE_SECs}s）：进程已退出"
            fi
            _marker="$(extra_probe_marker "$_xbase")"
            _lines="$OUT/probes/extra-${_xkey}-lines.txt"
            _rc=0
            grep -Ei "$_marker" "$_raw" > "$_lines" 2>/dev/null || _rc=$?
            if [ "$_rc" -gt 1 ]; then
                warn "   $_xkey 行过滤失败（grep rc=$_rc）"
                : > "$_lines"
            fi
            _match="marker"
            if [ ! -s "$_lines" ]; then
                # file-name marker missed (renamed hap / different tag): keep the same
                # filtered lines as the main hilog capture so the evidence is archived
                _match="fallback"
                _rc=0
                grep -E "$FILTER_RE" "$_raw" > "$_lines" 2>/dev/null || _rc=$?
                if [ "$_rc" -gt 1 ]; then : > "$_lines"; fi
            fi
            _n="$(line_count "$_lines")"
            _cap_n="$(line_count "$_raw")"
            cat "$_lines" >> "$OUT/probes/probe-all-lines.txt" 2>/dev/null || true
            if [ "$_n" -gt 0 ]; then
                record "extraprobe_${_xkey}_match=$_match"
                record "extraprobe_${_xkey}_capture_lines=$_cap_n"
                record "extraprobe_${_xkey}_lines=$_n"
                record "extraprobe_${_xkey}_result=ok"
                log "   $_xkey 完成：${_n}/${_cap_n} 行（match=$_match，marker: $_marker）-> $_lines"
            else
                warn "   $_xkey 未捕获到有效行（marker: $_marker；原文: $_raw）"
                record "extraprobe_${_xkey}_match=none"
                record "extraprobe_${_xkey}_capture_lines=$_cap_n"
                record "extraprobe_${_xkey}_lines=0"
                record "extraprobe_${_xkey}_result=no_lines"
                FAILURES=$((FAILURES + 1))
            fi
        done
        if [ "$_xp_dir_haps" -eq 0 ]; then
            _xdkey="$(printf '%s' "$_xd" | tr -c 'A-Za-z0-9._-' '_')"
            warn "   $_xd 下没有 *.hap，跳过该目录"
            record "extraprobes_dir_${_xdkey}=no_hap"
            FAILURES=$((FAILURES + 1))
        fi
    done <<EOF
$EXTRA_PROBES_DIRS
EOF
fi

# ---- step 5: collect + pack ----------------------------------------------------------
log "== 5/5 采集与打包 =="
if [ "$DO_DEVICE" = 0 ]; then
    log "   [dry-run] 将采集: hilog+kmsg 捕获、module.json、param get + UDID、kit 哈希、summary.txt"
    log "   [dry-run] 将采集 ELF 签名证据: xpm_mode/require_signatures、SoInfoSegment magic 计数"
    log "   [dry-run] 将采集 app-lib 路径证据: hilog 过滤（appLibPathKey/dlopen）+ bundle libs 目录列表"
    log "   [dry-run] 将采集 execmem 证据（FIX-XWE）: hilog 过滤（OHOS_DOTNET probe:/xwe=）-> hilog/hilog-execmem.txt"
    log "   [dry-run] 将采集 bootstrap/rawfile 失败特征: hilog 再过滤 -> hilog/hilog-bootstrap.txt + summary 计数"
    log "   [dry-run] 将采集 payload 状态: ls -l $DEV_FILES_DIR/ + 读一行 dotnet.marker -> device/payload-*.txt"
    log "   [dry-run] kit hap 自检已在上方打印；设备轮会写入 meta/kit-selfcheck.txt"
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
    cp -f "$TMP/kit-hap-sha256.txt" "$OUT/meta/kit-hap-sha256.txt" 2>/dev/null || true
    cp -f "$TMP/kit-selfcheck.txt" "$OUT/meta/kit-selfcheck.txt" 2>/dev/null || true
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

    # ---- app-lib path evidence (RM1 diagnostics, research doc §8.4; missing lines tolerated) ----
    # Grep every hilog window already captured (the main capture plus each probe window);
    # the registration line may be at DEBUG level (`hilog -b D` when a run comes back empty).
    : > "$OUT/hilog/hilog-applib.txt"
    : > "$OUT/hilog/hilog-dlopen.txt"
    : > "$OUT/hilog/hilog-execmem.txt"
    _al_seen=0
    for _f in "$OUT/hilog/hilog-full.txt" "$OUT/probes"/*-hilog.txt; do
        [ -s "$_f" ] || continue
        _al_seen=1
        filter_append "$FILTER_APPLIB_RE" "$_f" "$OUT/hilog/hilog-applib.txt"
        filter_append "$FILTER_DLOPEN_RE" "$_f" "$OUT/hilog/hilog-dlopen.txt"
        filter_append "$FILTER_EXECMEM_RE" "$_f" "$OUT/hilog/hilog-execmem.txt"
    done
    if [ "$_al_seen" = 1 ]; then
        APPLIB_RESULT="ok"
        DLOPEN_RESULT="ok"
        EXECMEM_RESULT="ok"
        APPLIB_LINES="$(line_count "$OUT/hilog/hilog-applib.txt")"
        DLOPEN_LINES="$(line_count "$OUT/hilog/hilog-dlopen.txt")"
        EXECMEM_LINES="$(line_count "$OUT/hilog/hilog-execmem.txt")"
        if [ "$APPLIB_LINES" -eq 0 ]; then
            warn "   未见 SetAppLibPath/appLibPathKey/NativeLibPath/lib path（日志级别或窗口原因，保留空证据）"
        fi
        if [ "$DLOPEN_LINES" -eq 0 ]; then
            warn "   未见 dlopen/cannot find library/openharmonyhost（同上，保留空证据）"
        fi
        if [ "$EXECMEM_LINES" -eq 0 ]; then
            warn "   未见 OHOS_DOTNET probe/xwe= 行（宿主版本或日志窗口原因，保留空证据）"
        fi
        log "   app-lib 路径 -> $OUT/hilog/hilog-applib.txt（${APPLIB_LINES} 行）/ dlopen -> $OUT/hilog/hilog-dlopen.txt（${DLOPEN_LINES} 行）/ execmem -> $OUT/hilog/hilog-execmem.txt（${EXECMEM_LINES} 行）"
    else
        warn "   app-lib 路径证据未采集（本轮没有 hilog 录制窗口）"
    fi

    # ---- bootstrap/rawfile failure signatures (device report §4; an empty result is fine) ----
    # Same windows as the app-lib greps. The counters feed the summary so a failed round can be
    # localized without opening the raw hilog: bootstrap_errors (bootstrap/retry), rawfile_errors
    # (GetRawFileContent / BusinessError 900002-900003 / ZIP entry / destination path) and
    # libload_errors (namespace / missing symbol / module load).
    : > "$OUT/hilog/hilog-bootstrap.txt"
    _bs_seen=0
    for _f in "$OUT/hilog/hilog-full.txt" "$OUT/probes"/*-hilog.txt; do
        [ -s "$_f" ] || continue
        _bs_seen=1
        filter_append "$FILTER_BOOTSTRAP_RE" "$_f" "$OUT/hilog/hilog-bootstrap.txt"
    done
    if [ "$_bs_seen" = 1 ]; then
        BOOTSTRAP_RESULT="ok"
        BOOTSTRAP_LINES="$(line_count "$OUT/hilog/hilog-bootstrap.txt")"
        BOOTSTRAP_ERRORS="$(match_count "$FILTER_BOOTSTRAP_ERR_RE" "$OUT/hilog/hilog-bootstrap.txt")"
        RAWFILE_ERRORS="$(match_count "$FILTER_RAWFILE_ERR_RE" "$OUT/hilog/hilog-bootstrap.txt")"
        LIBLOAD_ERRORS="$(match_count "$FILTER_LIBLOAD_ERR_RE" "$OUT/hilog/hilog-bootstrap.txt")"
        log "   bootstrap/rawfile 特征 -> $OUT/hilog/hilog-bootstrap.txt（${BOOTSTRAP_LINES} 行；bootstrap_errors=$BOOTSTRAP_ERRORS rawfile_errors=$RAWFILE_ERRORS libload_errors=$LIBLOAD_ERRORS）"
        if [ "$BOOTSTRAP_ERRORS" -gt 0 ] || [ "$RAWFILE_ERRORS" -gt 0 ] || [ "$LIBLOAD_ERRORS" -gt 0 ]; then
            warn "   命中 bootstrap/rawfile/libload 失败特征（原文见 hilog-bootstrap.txt；不影响本轮退出码）"
        fi
    else
        BOOTSTRAP_RESULT="not_captured"
        warn "   bootstrap/rawfile 特征未采集（本轮没有 hilog 录制窗口；summary 计数记 <unavailable>）"
    fi

    # device-side bundle libs listing (research doc §8.4 check 2); absence/empty tolerated.
    # Only stdout lands in the report (a missing dir says so on stderr and must not count as a line).
    APPLIBS_DIR_FILE="$OUT/device/app-libs-arm64.txt"
    _av_rc=0
    hdc_cmd shell "ls -l /data/storage/el1/bundle/libs/arm64/ 2>/dev/null" > "$APPLIBS_DIR_FILE" 2>/dev/null || _av_rc=$?
    APPLIBS_DIR_LINES="$(line_count "$APPLIBS_DIR_FILE")"
    if [ "$APPLIBS_DIR_LINES" -gt 0 ]; then
        APPLIBS_DIR_RESULT="ok"
        log "   bundle libs 目录 -> $APPLIBS_DIR_FILE（${APPLIBS_DIR_LINES} 行）"
    else
        APPLIBS_DIR_RESULT="empty"
        warn "   bundle libs 目录为空（rc=$_av_rc；/data/storage/el1/bundle/libs/arm64/ 不存在或不可读；容忍）"
    fi

    # ---- device-side payload state (dotnet/ unpack; missing dir/marker tolerated) ----
    # The unpacked payload lives in <filesDir>/dotnet and the unpack marker one level up
    # (<filesDir>/dotnet.marker, one JSON line); a half-written payload has no marker. Both
    # reads are read-only and stay as empty evidence on absence.
    PAYLOAD_FILES_FILE="$OUT/device/payload-files.txt"
    PAYLOAD_MARKER_FILE="$OUT/device/payload-marker.txt"
    : > "$PAYLOAD_FILES_FILE"
    : > "$PAYLOAD_MARKER_FILE"
    _pf_rc=0
    hdc_cmd shell "ls -l $DEV_FILES_DIR/ 2>/dev/null" > "$TMP/payload-files.raw" 2>/dev/null || _pf_rc=$?
    grep -E 'dotnet|payload' "$TMP/payload-files.raw" > "$PAYLOAD_FILES_FILE" 2>/dev/null || true
    PAYLOAD_FILES_LINES="$(line_count "$PAYLOAD_FILES_FILE")"
    _marker_line="$(hdc_cmd shell "cat $DEV_FILES_DIR/dotnet.marker 2>/dev/null" 2>/dev/null | tr -d '\r' | sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}')"
    if [ -n "$_marker_line" ]; then
        printf '%s\n' "$_marker_line" > "$PAYLOAD_MARKER_FILE"
        PAYLOAD_MARKER="ok"
    else
        PAYLOAD_MARKER="empty"
    fi
    if [ "$PAYLOAD_FILES_LINES" -gt 0 ] || [ "$PAYLOAD_MARKER" = ok ]; then
        PAYLOAD_PRESENT="yes"
    else
        PAYLOAD_PRESENT="no"
    fi
    log "   payload 状态 -> $PAYLOAD_FILES_FILE（${PAYLOAD_FILES_LINES} 行，rc=$_pf_rc）/ marker=${PAYLOAD_MARKER}（payload_present=$PAYLOAD_PRESENT）"
    if [ "$PAYLOAD_PRESENT" = no ]; then
        warn "   未见 dotnet payload/marker（$DEV_FILES_DIR；首次启动前属正常，缺失容忍）"
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
        if [ -n "$EXTRA_PROBES_DIRS" ]; then
            printf 'extra_probes_dirs=%s\n' "$(printf '%s' "$EXTRA_PROBES_DIRS" | tr '\n' ',')"
        fi
        printf 'main_hap=%s\n' "$MAIN_HAP"
        printf 'main_hap_sha256=%s\n' "$MAIN_HAP_SHA"
        printf 'kmsg_capture=%s\n' "$KMSG_RESULT"
        printf 'kmsg_lines=%s\n' "$KMSG_LINES"
        printf 'kmsg_filtered_lines=%s\n' "$KMSG_FILTERED_LINES"
        printf 'applib_path_capture=%s\n' "$APPLIB_RESULT"
        printf 'applib_path_lines=%s\n' "$APPLIB_LINES"
        printf 'dlopen_capture=%s\n' "$DLOPEN_RESULT"
        printf 'dlopen_lines=%s\n' "$DLOPEN_LINES"
        printf 'execmem_capture=%s\n' "$EXECMEM_RESULT"
        printf 'execmem_lines=%s\n' "$EXECMEM_LINES"
        printf 'app_libs_arm64=%s\n' "$APPLIBS_DIR_RESULT"
        printf 'app_libs_arm64_lines=%s\n' "$APPLIBS_DIR_LINES"
        printf 'bootstrap_capture=%s\n' "$BOOTSTRAP_RESULT"
        printf 'bootstrap_lines=%s\n' "$BOOTSTRAP_LINES"
        printf 'bootstrap_errors=%s\n' "$BOOTSTRAP_ERRORS"
        printf 'rawfile_errors=%s\n' "$RAWFILE_ERRORS"
        printf 'libload_errors=%s\n' "$LIBLOAD_ERRORS"
        printf 'payload_present=%s\n' "$PAYLOAD_PRESENT"
        printf 'payload_files=%s\n' "$PAYLOAD_FILES_LINES"
        printf 'payload_marker=%s\n' "$PAYLOAD_MARKER"
        printf 'kit_index_ok=%s\n' "$KIT_INDEX_OK"
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
log "        归档内已有：hilog/（含 applib/dlopen/bootstrap 过滤）、kmsg/、probes/、meta/module.json、"
log "        meta/kit-selfcheck.txt、device/udid.txt、device/app-libs-arm64.txt、"
log "        device/payload-files.txt、device/payload-marker.txt、summary.txt。"
if [ "$FAILURES" -gt 0 ]; then
    warn "本轮有 $FAILURES 项未通过：详情见 $OUT/summary.txt"
    exit 1
fi
exit 0
