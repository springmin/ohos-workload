#!/bin/sh
# device-round.sh - one-command OpenHarmony device round for the MAUI/Blazor device-test kit.
#
# Folds the delivery-side scratch automation of the kit rounds (#34..#47) into one command:
#   0 lock     exclusive device mutex per the shared protocol: `mkdir .device-lock` + `owner`
#              file, patient retry, stale reclaim (ownerless, mtime > 20 min), release on exit.
#   1 verify   kit tar/dir -> sidecar sha256 + `verify-kit.sh --tree-digest` (SHA256SUMS and
#              KIT OK included); a published tree digest can be pinned with --expect-tree-digest.
#   2 sign     re-sign the kit's unsigned haps for the attached UDID via sign-for-device.sh
#              (main hap + Blazor hosts); an explicit --hap is used as-is unless it is
#              *-unsigned.hap. --mode jit requires --hap (or a *jit* hap in the kit) and warns
#              when the hap is not DeviceCompat (extensionless / exactly-4096 B libs entries).
#   3 core     tester-run.sh (bundled v14 when present) --install --start --capture; canvas
#              line + first-frame screenshot/layout.
#   4 blazor   --blazor | --suite: Blazor A/B (default + -nocsp), re-signed, BLZ_BOOT /
#              BLZ_RENDERED markers via tester-run --blazor-probe, then a controlled click
#              through /counter ("Open the interactive counter" -> "Click me" -> count 0->N).
#   5 slots    --slots | --suite: dynamic slots on the MAUI sample: add the 3rd/4th/5th
#              hybrid by green-button detection (or --slots-clicks), activate A (LRU
#              restore/replay), remove/re-add C (destroy/create); archives the hilog markers
#              `web slot create/destroy`, `web capacity`, `hybrid overlay ...` and the raw
#              `[maui-capacity]` preempt/restore/replay lines.
#   6 a11y     --a11y | --suite: tester-run --a11y-probe (status/nodeCount self-check).
#   7 deeplink --deeplink | --suite: cold + hot `aa start -U app://media/probe?...` and the
#              activation/delivered lines + screenshot.
#   8 probe    bundled tester-run.sh --dry-run (kit contract + version), plus --probes <dir>
#              for a real P1-P4 probe round when the directory is available.
#   9 soak     --soak-min N: short RSS/threads/fd/state sampling (default 5 min, 0 disables),
#              fault-history diff and updateTime comparison.
#  10 archive  summary.txt + steps + every log/screenshot/json under --out -> tar.gz + .sha256.
#
# Reuse: the in-kit verify-kit.sh + tester-run.sh (v14) and scripts/sign-for-device.sh do the
# heavy lifting; this script adds the round umbrella (lock, signing, screenshots, slots,
# deeplink, soak, archive). Robustness: every step is recorded and a failing step never stops
# the remaining ones; hilog is grown to 16M for the round and restored (default 512K) on exit;
# a 10106102 `aa start` result prints the unlock hint. Exit: 0 ok, 1 step failures (archive
# still produced), 2 usage, 3 no device.
#
# Usage: sh device-round.sh --kit <tar|dir> [--mode aot|jit] [--suite] [--out <dir>]
#          [--soak-min N] [--blazor|--slots|--a11y|--deeplink] [--capture N] [--slots-max N]
#          [--slots-clicks "x,y;x,y;..."] [--probes <dir>] [--hap <hap>] [--blazor-hap <hap>]
#          [--expect-tree-digest <hex>] [--device <id>] [--uninstall] [--no-lock] [--dry-run] [-h|--help]
# Env: HDC (default hdc), DEVICE, TESTER_RUN, SIGN_FOR_DEVICE, DEVICE_ROUND_LOCK (lock dir path),
#      DEVICE_ROUND_LOCK_ATTEMPTS (180), DEVICE_ROUND_LOCK_INTERVAL (10 s),
#      DEVICE_ROUND_LOCK_STALE (1200 s), HILOG_RESTORE (default: the size read before growing),
#      DEVICE_ROUND_SOAK_TICK (seconds between soak samples; default 60).
set -u

SCRIPT_VERSION="1 (2026-10-05)"

# ---- paths / defaults ----------------------------------------------------------------
SELF="$0"
case "$SELF" in
    */*) ;;
    *) SELF="$(command -v "$SELF" 2>/dev/null || printf '%s' "$SELF")" ;;
esac
SELF_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd -P)" || SELF_DIR="."
HDC="${HDC:-hdc}"
DEVICE="${DEVICE:-}"
TESTER_RUN="${TESTER_RUN:-}"
SIGN_SCRIPT="${SIGN_FOR_DEVICE:-$SELF_DIR/sign-for-device.sh}"
if command -v timeout >/dev/null 2>&1; then TMO="timeout"; else TMO=""; fi

KIT_ARG=""
EXPECT_TREE=""
HAP=""
MODE="aot"
CAPTURE=30
SOAK_MIN=5
SLOTS_MAX=3
SLOTS_CLICKS=""
OPT_BLAZOR=0
OPT_SLOTS=0
OPT_A11Y=0
OPT_DEEPLINK=0
PROBES_DIR=""
BLAZOR_HAP=""
BLAZOR_BUNDLE="${BLAZOR_BUNDLE:-com.example.opendotnet}"
OUT="./device-round-report"
DRY_RUN=0
NO_LOCK=0
DO_UNINSTALL=0
UNINSTALL_FLAG=""

RUNLOG=""
STEPS_FILE=""
OUT=""
TMP=""
ARCHIVE=""
FAILURES=0
LOCK_HELD=0
LOCK_PATH=""
HILOG_GREW=0
HILOG_RESTORE_SIZE=""
STREAM_PID=""
HAVE_PY=0
UDID=""
DEVICE_MODEL=""
DEVICE_SOFT=""
KIT_SOURCE=""
KIT_TAR=""
KIT_DIR=""
KIT_TAR_SHA=""
KIT_SIDECAR=""
USE_ANCHOR=0
TREE_DIGEST=""
BUNDLE="com.example.hellomauiapp"
MAIN_HAP=""
MAIN_HAP_SHA=""
MAIN_HAP_SIGNED="no"
MODE_CHECK=""
LOCK_HINT=0
APP_PID=""

log() { _l="[$(date '+%H:%M:%S')] $*"; printf '%s\n' "$_l"; [ -z "$RUNLOG" ] || printf '%s\n' "$_l" >> "$RUNLOG"; }
warn() { _l="[$(date '+%H:%M:%S')] WARN: $*"; printf '%s\n' "$_l" >&2; [ -z "$RUNLOG" ] || printf '%s\n' "$_l" >> "$RUNLOG"; }
die() { warn "$*"; exit 2; }
step() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STEPS_FILE"; }
fail_step() { step "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); }

usage() {
    cat <<'EOF'
用法: sh device-round.sh --kit <device-test-kit.tar.gz|解包目录> [选项]

一轮真机取证（一条命令）：锁 -> 资产核验 -> 重签 -> 装/启/首帧 -> [Blazor A/B] ->
[动态槽 3/5 + destroy/create + [maui-capacity]] -> [a11y 探针] -> [深链热激活] ->
tester-run v14 probe -> [短 soak] -> 证据归档 tar。

交付包:
  --kit <tar|dir>             kit tar.gz 或解压目录（必填；tar 会校验同名 .sha256 sidecar）
  --expect-tree-digest <hex>  发布说明「Integrity」的内容树 sha256（绑定解压内容，可选）

模式与资产:
  --mode aot|jit              默认 aot（用 kit 的 hello-maui-app 件）；jit 需 --hap
                              （或 kit 内 *jit* hap），并检查 DeviceCompat 布局（见下）
  --hap <hap>                 主 hap 覆盖；*-unsigned.hap 会先用 sign-for-device.sh 重签
  --blazor-hap <hap>          只跑一个 Blazor 变体（已签路径直接用，unsigned 会重签）

步骤开关（默认只跑核心 + tester-run probe + soak；--suite = 四个都开）:
  --blazor                    Blazor A/B：重签 + BLZ_BOOT/BLZ_RENDERED + /counter 受控点击
  --slots                     动态槽：加 3/4/5 控件（绿块定位）、Activate A、destroy/create、
                              归档 `[maui-capacity]` 抢占/恢复/重放原文
  --a11y                      a11y 自检探针（tester-run --a11y-probe）
  --deeplink                  深链冷/热激活（aa start -U app://media/probe?...）
  --suite                     等价于 --blazor --slots --a11y --deeplink

参数:
  --capture <secs>            核心 hilog 录制窗口（默认 30）
  --soak-min <min>            短 soak 采样分钟数（默认 5；0 关闭）
  --slots-max <n>             最多添加的动态 web 控件数（默认 3 = C/D/E，按绿块发现）
  --slots-clicks "x,y;x,y"    显式点击序列（跳过绿块定位；每步隔 8 s）
  --probes <dir>              额外跑 tester-run --probes（P1-P4；目录含 4 个 probe hap）
  --uninstall                 安装前先卸载主应用（换签/换包遇到 9568286 时用；显式）
  --out <dir>                 报告目录（默认 ./device-round-report）；归档为 <out>-<时间戳>.tar.gz
  --device <id>               hdc 目标（等价每条命令加 -t <id>）
  --no-lock                   跳过 .device-lock 互斥（单人独占机器时用）
  --dry-run                   只打印计划并做本地资产核验；不碰设备、不取锁
  -h, --help                  本帮助

锁协议: mkdir <lock>（默认 /data/storage/el2/base/tmp/opencode/.device-lock，可设
  DEVICE_ROUND_LOCK）-> 写入 owner；重试 DEVICE_ROUND_LOCK_ATTEMPTS 次 x INTERVAL 秒；
  owner 缺失且 mtime 超过 STALE 秒视为陈旧锁并回收；退出/信号时仅释放自己的锁。
退出码: 0 全部通过（或 dry-run 计划）；1 有步骤失败（仍会归档）；2 用法错误；3 无设备。
EOF
}

# ---- argument parsing ----------------------------------------------------------------
need_val() { [ "$1" -ge 2 ] || { warn "$2 需要一个值"; usage >&2; exit 2; }; }
is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --kit) need_val $# "--kit"; KIT_ARG="$2"; shift ;;
        --expect-tree-digest) need_val $# "--expect-tree-digest"; EXPECT_TREE="$2"; shift ;;
        --hap) need_val $# "--hap"; HAP="$2"; shift ;;
        --mode) need_val $# "--mode"; MODE="$2"; shift ;;
        --capture) need_val $# "--capture"; CAPTURE="$2"; shift ;;
        --soak-min) need_val $# "--soak-min"; SOAK_MIN="$2"; shift ;;
        --slots-max) need_val $# "--slots-max"; SLOTS_MAX="$2"; shift ;;
        --slots-clicks) need_val $# "--slots-clicks"; SLOTS_CLICKS="$2"; shift ;;
        --probes) need_val $# "--probes"; PROBES_DIR="$2"; shift ;;
        --blazor-hap) need_val $# "--blazor-hap"; BLAZOR_HAP="$2"; shift ;;
        --blazor-bundle) need_val $# "--blazor-bundle"; BLAZOR_BUNDLE="$2"; shift ;;
        --out) need_val $# "--out"; OUT="$2"; shift ;;
        --device) need_val $# "--device"; DEVICE="$2"; shift ;;
        --blazor) OPT_BLAZOR=1 ;;
        --slots) OPT_SLOTS=1 ;;
        --a11y) OPT_A11Y=1 ;;
        --deeplink) OPT_DEEPLINK=1 ;;
        --suite) OPT_BLAZOR=1; OPT_SLOTS=1; OPT_A11Y=1; OPT_DEEPLINK=1 ;;
        --uninstall) DO_UNINSTALL=1 ;;
        --no-lock) NO_LOCK=1 ;;
        --dry-run) DRY_RUN=1 ;;
        *) warn "未知参数: $1"; usage >&2; exit 2 ;;
    esac
    shift
done

[ -n "$KIT_ARG" ] || { warn "--kit 必填（tar.gz 或解压目录）"; usage >&2; exit 2; }
case "$MODE" in aot|jit) ;; *) warn "--mode 只支持 aot|jit: $MODE"; exit 2 ;; esac
is_int "$CAPTURE" || { warn "--capture 需要秒数: $CAPTURE"; exit 2; }
is_int "$SOAK_MIN" || { warn "--soak-min 需要分钟数: $SOAK_MIN"; exit 2; }
is_int "$SLOTS_MAX" || { warn "--slots-max 需要整数: $SLOTS_MAX"; exit 2; }
[ -n "$OUT" ] || OUT="./device-round-report"

# ---- device helpers ------------------------------------------------------------------
hdc_cmd() {
    if [ -n "$DEVICE" ]; then
        if [ -n "$TMO" ]; then "$TMO" "${HDC_TIMEOUT:-180}" "$HDC" -t "$DEVICE" "$@"; else "$HDC" -t "$DEVICE" "$@"; fi
    else
        if [ -n "$TMO" ]; then "$TMO" "${HDC_TIMEOUT:-180}" "$HDC" "$@"; else "$HDC" "$@"; fi
    fi
}
hd()  { hdc_cmd shell "$1" 2>/dev/null || true; }
hdr() { hd "$1" | tr -d '\r'; }
dev_pid() {
    _p="$(hdr "pidof $BUNDLE" | awk '{print $1; exit}')"
    if [ -z "$_p" ]; then
        _p="$(hdr "ps -ef" | awk -v b="$BUNDLE" '$NF == b {print $2; exit}')"
    fi
    printf '%s' "$_p"
}
device_targets() {
    case "$HDC" in
        */*) [ -x "$HDC" ] || return 1 ;;
        *) command -v "$HDC" >/dev/null 2>&1 || return 1 ;;
    esac
    if [ -n "$TMO" ]; then
        _t="$("$TMO" 30 "$HDC" list targets 2>&1 | tr -d '\r' | grep -v -e '^[[:space:]]*$' -e '^\[Empty\]$' || true)"
    else
        _t="$("$HDC" list targets 2>&1 | tr -d '\r' | grep -v -e '^[[:space:]]*$' -e '^\[Empty\]$' || true)"
    fi
    printf '%s\n' "$_t"
}
device_reason() {
    _t="$(device_targets)" || { printf '未找到 hdc（HDC=%s）' "$HDC"; return 0; }
    [ -n "$_t" ] || { printf 'hdc list targets 为空（未连接设备）'; return 0; }
    if [ -n "$DEVICE" ] && ! printf '%s\n' "$_t" | grep -Fq -- "$DEVICE"; then
        printf '设备 %s 不在 hdc list targets 中' "$DEVICE"; return 0
    fi
    return 1
}
aa_start() { # $1 = extra args string (may be empty)
    _o=""
    if [ -n "$1" ]; then _o="$(hd "aa start -b $BUNDLE -a EntryAbility $1")"; else _o="$(hd "aa start -b $BUNDLE -a EntryAbility")"; fi
    case "$_o" in
        *10106102*) LOCK_HINT=1; warn "aa start 返回 10106102：设备疑似锁屏/息屏，请解锁后重跑（已尝试 power-shell wakeup）" ;;
    esac
    printf '%s\n' "$_o"
}
ensure_app() {
    _p="$(dev_pid)"
    if [ -z "$_p" ]; then aa_start "" >/dev/null 2>&1; sleep 5; _p="$(dev_pid)"; fi
    [ -n "$_p" ] || return 1
    # Bring the kit app to the foreground (hot activation; a no-op when it already is) so
    # uitest/screenshot target its window, not another bundle left in front by an earlier step.
    aa_start "" >/dev/null 2>&1 || true
    sleep 1
    return 0
}
shot() { # <dir> <name> -> <dir>/<name>.jpeg
    _dev="/data/local/tmp/device-round-$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '_').jpeg"
    mkdir -p "$1"
    hd "snapshot_display -f $_dev" >/dev/null 2>&1
    hdc_cmd file recv "$_dev" "$1/$2.jpeg" >/dev/null 2>&1
}
dump() { # <dir> <name> -> <dir>/<name>.json
    _dev="/data/local/tmp/device-round-$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '_').json"
    mkdir -p "$1"
    hd "uitest dumpLayout -p $_dev" >/dev/null 2>&1
    hdc_cmd file recv "$_dev" "$1/$2.json" >/dev/null 2>&1
    [ -s "$1/$2.json" ]
}
count_marker() { _c="$(grep -acF -- "$2" "$1" 2>/dev/null)" || :; printf '%s' "${_c:-0}"; }
sumval() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1; }
hash_of() { [ -f "$1" ] && sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
stop_stream() {
    [ -n "$STREAM_PID" ] || return 0
    if command -v pkill >/dev/null 2>&1; then pkill -P "$STREAM_PID" >/dev/null 2>&1 || true; fi
    kill "$STREAM_PID" >/dev/null 2>&1 || true
    kill -9 "$STREAM_PID" >/dev/null 2>&1 || true
    STREAM_PID=""
}

# ---- layout text helpers (python3, tolerant) -----------------------------------------
layout_find() { # <json> <text> [exact|contains] -> "x y"
    [ "$HAVE_PY" = 1 ] || return 1
    python3 - "$1" "$2" "${3:-exact}" <<'PY' 2>/dev/null
import json, re, sys
try:
    with open(sys.argv[1], encoding='utf-8') as fh:
        tree = json.load(fh)
except Exception:
    sys.exit(1)
needle, mode = sys.argv[2], sys.argv[3]
stack = [tree]
while stack:
    node = stack.pop()
    if isinstance(node, list):
        stack.extend(node); continue
    if not isinstance(node, dict):
        continue
    attrs = node.get('attributes') if isinstance(node.get('attributes'), dict) else node
    text = attrs.get('text'); bounds = attrs.get('bounds')
    if isinstance(text, str) and isinstance(bounds, str):
        hit = (text == needle) if mode == 'exact' else (needle in text)
        if hit:
            nums = re.findall(r'-?\d+\s*,\s*-?\d+', bounds)
            if len(nums) >= 2:
                x1, y1 = (int(v) for v in nums[0].split(','))
                x2, y2 = (int(v) for v in nums[1].split(','))
                print('%d %d' % ((x1 + x2) // 2, (y1 + y2) // 2))
                sys.exit(0)
    children = node.get('children')
    if isinstance(children, list):
        stack.extend(children)
sys.exit(1)
PY
}
layout_click_text() { # <dir> <dump-name> <text> [exact|contains]
    _xy="$(layout_find "$1/$2.json" "$3" "${4:-contains}")" || return 1
    hd "uitest uiInput click $_xy" >/dev/null 2>&1 || true
    log "   click '$3' -> $_xy"
    return 0
}

# ---- hap info (bundle / runtime mode / DeviceCompat) ---------------------------------
hap_info() {
    if [ "$HAVE_PY" = 1 ]; then
        python3 - "$1" <<'PY' 2>/dev/null
import json, sys, zipfile
try:
    with zipfile.ZipFile(sys.argv[1]) as z:
        d = json.loads(z.read('module.json'))
        print('bundle=' + (((d.get('app') or {}).get('bundleName')) or ''))
        mode = ''
        for n in z.namelist():
            parts = n.split('/')
            if len(parts) == 3 and parts[0] == 'libs' and parts[2] == 'runtime-mode.txt':
                mode = z.read(n).decode('utf-8', 'replace').strip(); break
        print('mode=' + (mode or '<absent>'))
except Exception:
    print('bundle='); print('mode=<unavailable>'); sys.exit(1)
PY
    else
        _b="$(unzip -p "$1" module.json 2>/dev/null | sed -n 's/.*"bundleName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
        _m="$(unzip -p "$1" libs/arm64-v8a/runtime-mode.txt 2>/dev/null | head -n1 | tr -d ' \r\n')"
        printf 'bundle=%s\nmode=%s\n' "$_b" "${_m:-<absent>}"
    fi
}
jit_devcompat() { # prints "ok" or "no" + offending entries
    [ "$HAVE_PY" = 1 ] || { printf 'unknown\n'; return 0; }
    python3 - "$1" <<'PY' 2>/dev/null
import sys, zipfile
bad = []
try:
    with zipfile.ZipFile(sys.argv[1]) as z:
        for n in z.namelist():
            if not n.startswith('libs/') or n.endswith('/'):
                continue
            base = n.rsplit('/', 1)[-1]
            if '.' not in base:
                bad.append('noext:' + n)
            elif z.getinfo(n).file_size == 4096:
                bad.append('size4096:' + n)
except Exception:
    print('unknown'); sys.exit(0)
if bad:
    print('no')
    for b in bad[:5]:
        print('  ' + b)
else:
    print('ok')
PY
}

# ---- lock protocol -------------------------------------------------------------------
lock_owner() { cat "$LOCK_PATH/owner" 2>/dev/null; }
lock_ours() { lock_owner | grep -q "device-round.sh $$ " 2>/dev/null; }
lock_acquire() {
    _attempts="${DEVICE_ROUND_LOCK_ATTEMPTS:-180}"
    _interval="${DEVICE_ROUND_LOCK_INTERVAL:-10}"
    _stale="${DEVICE_ROUND_LOCK_STALE:-1200}"
    _i=0
    while ! mkdir "$LOCK_PATH" 2>/dev/null; do
        if [ ! -f "$LOCK_PATH/owner" ]; then
            _mt="$(stat -c %Y "$LOCK_PATH" 2>/dev/null || stat -f %m "$LOCK_PATH" 2>/dev/null || printf '0')"
            _now="$(date '+%s')"
            if [ "${_mt:-0}" -gt 0 ] 2>/dev/null && [ $((_now - _mt)) -gt "$_stale" ]; then
                warn "回收陈旧锁（owner 缺失且 mtime 超过 ${_stale}s）: $LOCK_PATH"
                rm -rf "$LOCK_PATH" 2>/dev/null || true
                continue
            fi
        fi
        _i=$((_i + 1))
        if [ "$_i" -gt "$_attempts" ]; then
            warn "设备锁等待超时（${_attempts}x${_interval}s）: $LOCK_PATH owner=$(lock_owner)"
            return 1
        fi
        [ $((_i % 12)) -eq 0 ] && log "   wait lock #$_i owner=$(lock_owner)"
        sleep "$_interval"
    done
    printf 'device-round.sh %s %s\n' "$$" "$(date '+%F %T')" > "$LOCK_PATH/owner" 2>/dev/null || true
    LOCK_HELD=1
    log "设备锁已获取: $LOCK_PATH"
    return 0
}
lock_release() {
    [ "$LOCK_HELD" = 1 ] || return 0
    if lock_ours || [ ! -f "$LOCK_PATH/owner" ]; then
        rm -rf "$LOCK_PATH" 2>/dev/null || true
        LOCK_HELD=0
        log "设备锁已释放: $LOCK_PATH"
    else
        warn "锁 owner 已变（$(lock_owner)），不释放：$LOCK_PATH"
        LOCK_HELD=0
    fi
}

# ---- hilog buffer handling -----------------------------------------------------------
hilog_size_of() { hd "hilog -g" | sed -n 's/.*app buffer size is //p' | head -n1; }
hilog_norm() { printf '%s' "$1" | sed 's/\.0\([A-Za-z]\)$/\1/'; }
hilog_grow() {
    _before="$(hilog_size_of)"
    HILOG_RESTORE_SIZE="$(hilog_norm "${HILOG_RESTORE:-${_before:-512K}}")"
    [ -n "$HILOG_RESTORE_SIZE" ] || HILOG_RESTORE_SIZE="512K"
    hd "hilog -G 16M" >/dev/null 2>&1 || warn "hilog -G 16M 失败（继续；512K 环可能丢行）"
    HILOG_GREW=1
    log "hilog 调至 16M（退出时还原 $HILOG_RESTORE_SIZE）"
}
hilog_restore() {
    [ "$HILOG_GREW" = 1 ] || return 0
    hd "hilog -G $HILOG_RESTORE_SIZE" >/dev/null 2>&1 || warn "hilog 还原 -G $HILOG_RESTORE_SIZE 失败（请手工还原）"
    HILOG_GREW=0
}

# ---- cleanup -------------------------------------------------------------------------
cleanup() {
    trap - 0 1 2 15
    stop_stream
    [ "$HILOG_GREW" = 0 ] || hilog_restore
    [ "$LOCK_HELD" = 0 ] || lock_release
    if [ -n "$TMP" ] && [ -d "$TMP" ]; then rm -rf "$TMP" 2>/dev/null || true; fi
}

# ---- kit resolution + verify ---------------------------------------------------------
resolve_kit() {
    if [ -d "$KIT_ARG" ]; then
        KIT_SOURCE="dir"
        KIT_DIR="$(cd "$KIT_ARG" && pwd -P)"
        KIT_TAR=""
        [ -f "$KIT_DIR/SHA256SUMS" ] || die "kit 目录没有 SHA256SUMS（不是交付包根目录）: $KIT_DIR"
        [ -f "$KIT_DIR/verify-kit.sh" ] || die "kit 目录没有 verify-kit.sh: $KIT_DIR"
        # Adjacent outer tarball + sidecar (if any) feed verify-kit's anchor check.
        if [ -f "$KIT_DIR.tar.gz" ] && [ -f "$KIT_DIR.tar.gz.sha256" ]; then
            KIT_TAR="$KIT_DIR.tar.gz"
            USE_ANCHOR=1
        fi
    elif [ -f "$KIT_ARG" ]; then
        KIT_SOURCE="tar"
        KIT_TAR="$(cd "$(dirname "$KIT_ARG")" && pwd -P)/$(basename "$KIT_ARG")"
        mkdir -p "$OUT/verify"
        if [ -f "$KIT_TAR.sha256" ]; then
            if (cd "$(dirname "$KIT_TAR")" && sha256sum -c "$(basename "$KIT_TAR").sha256") > "$OUT/verify/sidecar.txt" 2>&1; then
                KIT_SIDECAR="ok"
                USE_ANCHOR=1
            else
                KIT_SIDECAR="mismatch"
                die "tar sidecar 校验失败（$KIT_TAR.sha256）；重新下载后再试"
            fi
        else
            KIT_SIDECAR="missing"
            warn "未找到 $KIT_TAR.sha256（sidecar）；继续用包内 SHA256SUMS 校验"
        fi
        KIT_TAR_SHA="$(hash_of "$KIT_TAR")"
        mkdir -p "$TMP/kit"
        log "解压 kit tar -> $TMP/kit"
        tar xzf "$KIT_TAR" -C "$TMP/kit" || die "解压失败: $KIT_TAR"
        KIT_DIR="$TMP/kit"
    else
        die "--kit 既不是目录也不是文件: $KIT_ARG"
    fi
}

verify_kit_step() {
    mkdir -p "$OUT/verify"
    _rc=0
    if [ -n "$EXPECT_TREE" ]; then
        if [ "$USE_ANCHOR" = 1 ]; then
            (cd "$KIT_DIR" && sh verify-kit.sh --tree-digest --expect-tree-digest "$EXPECT_TREE" --anchor-file "$KIT_TAR") > "$OUT/verify/verify-kit.log" 2>&1 || _rc=$?
        else
            (cd "$KIT_DIR" && sh verify-kit.sh --tree-digest --expect-tree-digest "$EXPECT_TREE") > "$OUT/verify/verify-kit.log" 2>&1 || _rc=$?
        fi
    else
        if [ "$USE_ANCHOR" = 1 ]; then
            (cd "$KIT_DIR" && sh verify-kit.sh --tree-digest --anchor-file "$KIT_TAR") > "$OUT/verify/verify-kit.log" 2>&1 || _rc=$?
        else
            (cd "$KIT_DIR" && sh verify-kit.sh --tree-digest) > "$OUT/verify/verify-kit.log" 2>&1 || _rc=$?
        fi
    fi
    TREE_DIGEST="$(sed -n 's/^.*tree sha256=//p' "$OUT/verify/verify-kit.log" | head -n1)"
    if [ "$_rc" -eq 0 ] && grep -q 'KIT OK' "$OUT/verify/verify-kit.log" 2>/dev/null; then
        [ "$USE_ANCHOR" = 1 ] && KIT_SIDECAR="${KIT_SIDECAR:-ok}"
        step verify ok "tree=${TREE_DIGEST:-?} sums=ok sidecar=${KIT_SIDECAR:-n/a}"
        log "资产核验 OK（tree ${TREE_DIGEST:-<未打印>}）"
        return 0
    fi
    fail_step verify failed "verify-kit rc=$_rc tree=${TREE_DIGEST:-?}（详见 $OUT/verify/verify-kit.log）"
    warn "资产核验失败（rc=$_rc）；后续步骤跳过。原文见 $OUT/verify/verify-kit.log"
    return 1
}

# ---- main hap resolution + signing ---------------------------------------------------
sign_one() { # <unsigned> <out> [bundle]
    [ -x "$SIGN_SCRIPT" ] || [ -f "$SIGN_SCRIPT" ] || { warn "找不到签名脚本: $SIGN_SCRIPT"; return 1; }
    [ -n "$UDID" ] || { warn "未取到设备 UDID，无法重签"; return 1; }
    _dir="$(dirname "$2")"; mkdir -p "$_dir"
    _rc=0
    if [ -n "${3:-}" ]; then
        sh "$SIGN_SCRIPT" "$UDID" --bundle "$3" --unsigned "$1" --out "$2" > "$2.log" 2>&1 || _rc=$?
    else
        sh "$SIGN_SCRIPT" "$UDID" --unsigned "$1" --out "$2" > "$2.log" 2>&1 || _rc=$?
    fi
    if [ "$_rc" -eq 0 ] && [ -s "$2" ]; then
        log "   重签 OK: $2"
        return 0
    fi
    warn "   重签失败（rc=$_rc）: $1（日志 $2.log）"
    return 1
}

resolve_main_hap() {
    MAIN_HAP=""
    if [ "$DRY_RUN" = 1 ]; then
        MAIN_HAP="${HAP:-$KIT_DIR/hello-maui-app.hap}"
        _bi="$(hap_info "$MAIN_HAP" 2>/dev/null || true)"
        _b="$(printf '%s\n' "$_bi" | sed -n 's/^bundle=//p')"
        [ -n "$_b" ] && BUNDLE="$_b"
        MODE_CHECK="$(printf '%s\n' "$_bi" | sed -n 's/^mode=//p')"
        return 0
    fi
    if [ -n "$HAP" ]; then
        [ -f "$HAP" ] || { fail_step install_start failed "--hap 不存在: $HAP"; return 1; }
        case "$HAP" in
            *-unsigned.hap)
                _signed="$OUT/sign/$(basename "$HAP" .hap)-local.hap"
                if sign_one "$HAP" "$_signed"; then MAIN_HAP="$_signed"; MAIN_HAP_SIGNED=yes; fi
                ;;
            *) MAIN_HAP="$HAP" ;;
        esac
    fi
    if [ -z "$MAIN_HAP" ] && [ "$MODE" = aot ]; then
        _u="$KIT_DIR/hello-maui-app-unsigned.hap"
        if [ -f "$_u" ]; then
            _signed="$OUT/sign/hello-maui-app-local.hap"
            if sign_one "$_u" "$_signed"; then MAIN_HAP="$_signed"; MAIN_HAP_SIGNED=yes; fi
        fi
        [ -n "$MAIN_HAP" ] || MAIN_HAP="$KIT_DIR/hello-maui-app.hap"
    fi
    if [ -z "$MAIN_HAP" ] && [ "$MODE" = jit ]; then
        for _c in "$KIT_DIR"/*.hap; do
            [ -f "$_c" ] || continue
            case "$(hap_info "$_c" | sed -n 's/^mode=//p')" in
                jit)
                    case "$_c" in
                        *-unsigned.hap)
                            _signed="$OUT/sign/$(basename "$_c" .hap)-local.hap"
                            if sign_one "$_c" "$_signed"; then MAIN_HAP="$_signed"; MAIN_HAP_SIGNED=yes; fi ;;
                        *) MAIN_HAP="$_c" ;;
                    esac
                    break ;;
            esac
        done
    fi
    if [ -z "$MAIN_HAP" ]; then
        fail_step install_start failed "mode=$MODE 找不到可用主 hap（JIT 需 --hap 或 kit 内 *jit* hap；重出包用 -p:OpenHarmonyHapPayloadInLibsDeviceCompat=true）"
        warn "mode=$MODE 没有可用主 hap：JIT 变体需自建（DeviceCompat）并用 --hap 指过来；跳过设备主流程"
        return 1
    fi
    [ -f "$MAIN_HAP" ] || { fail_step install_start failed "主 hap 不存在: $MAIN_HAP"; return 1; }
    MAIN_HAP_SHA="$(hash_of "$MAIN_HAP")"
    _bi="$(hap_info "$MAIN_HAP")"
    _b="$(printf '%s\n' "$_bi" | sed -n 's/^bundle=//p')"
    MODE_CHECK="$(printf '%s\n' "$_bi" | sed -n 's/^mode=//p')"
    if [ -n "$_b" ]; then BUNDLE="$_b"; fi
    if [ "$MODE" = jit ]; then
        _dc="$(jit_devcompat "$MAIN_HAP")"
        case "$_dc" in
            ok) log "   JIT DeviceCompat 布局检查: OK" ;;
            no) warn "JIT hap 不是 DeviceCompat 布局（本机 enforcing 镜像可能报 9568393）："; printf '%s\n' "$_dc" | sed 's/^/     /' | while IFS= read -r _ln; do warn "$_ln"; done
                warn "     重出包: -p:OpenHarmonyHapPayloadInLibsDeviceCompat=true（preview.28 起默认 true）或 -p:OpenHarmonyHapPayloadInLibs=false" ;;
            *) warn "JIT DeviceCompat 布局检查跳过（缺 python3）" ;;
        esac
    fi
    log "主 hap: $MAIN_HAP（sha ${MAIN_HAP_SHA:0:12}… mode=$MODE_CHECK bundle=$BUNDLE signed=$MAIN_HAP_SIGNED）"
    return 0
}

# ---- step runners --------------------------------------------------------------------
tester_run_probe_step() { # --dry-run contract probe + optional real --probes
    mkdir -p "$OUT/tester-run-probe"
    _tv="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$TESTER_RUN" 2>/dev/null | head -n1)"
    _rc=0
    run_tester --kit-dir "$KIT_DIR" --dry-run --out "$OUT/tester-run-probe/plan" > "$OUT/tester-run-probe/plan.log" 2>&1 || _rc=$?
    if [ -n "$PROBES_DIR" ]; then
        _prc=0
        run_tester --kit-dir "$KIT_DIR" --probes "$PROBES_DIR" --out "$OUT/tester-run-probe/probes" > "$OUT/tester-run-probe/probes.log" 2>&1 || _prc=$?
        if [ "$_prc" -eq 0 ]; then
            step tester_run_probe ok "v=${_tv:-?} probes=ok dir=$PROBES_DIR"
        else
            fail_step tester_run_probe failed "v=${_tv:-?} probes rc=$_prc"
        fi
        return 0
    fi
    if [ "$_rc" -eq 0 ] && grep -q '完整一轮示例' "$OUT/tester-run-probe/plan.log" 2>/dev/null; then
        step tester_run_probe ok "v=${_tv:-?} dry-run plan"
    else
        fail_step tester_run_probe failed "v=${_tv:-?} rc=$_rc（详见 $OUT/tester-run-probe/plan.log）"
    fi
}
run_tester() { # tester-run passthrough with the optional --device
    if [ -n "$DEVICE" ]; then "$TESTER_RUN" --device "$DEVICE" "$@"; else "$TESTER_RUN" "$@"; fi
}

core_step() {
    mkdir -p "$OUT/core"
    _rc=0
    run_tester --kit-dir "$KIT_DIR" $UNINSTALL_FLAG --install --start --capture "$CAPTURE" --hap "$MAIN_HAP" \
        --out "$OUT/core/tester-run" > "$OUT/core/tester-run.log" 2>&1 || _rc=$?
    _sum="$OUT/core/tester-run/summary.txt"
    _alive="$(sumval "$_sum" process_alive)"
    if [ "$_rc" -eq 0 ] && [ "$_alive" = yes ]; then
        step install_start ok "tester_run rc=0 alive=yes pid=$(sumval "$_sum" process_pid) runtime_mode=$(sumval "$_sum" runtime_mode)"
    else
        fail_step install_start failed "tester_run rc=$_rc alive=${_alive:-?}（详见 $OUT/core/tester-run.log）"
    fi
    # first frame: canvas line in the captured hilog, else one more direct dump
    _ff=0
    if grep -aq 'canvas presented' "$OUT/core/tester-run/hilog/hilog-full.txt" 2>/dev/null; then _ff=1; fi
    if [ "$_ff" = 0 ]; then
        hd "hilog -x" > "$OUT/frames/hilog-first.txt" 2>&1 || true
        grep -aq 'canvas presented' "$OUT/frames/hilog-first.txt" 2>/dev/null && _ff=1
    fi
    shot "$OUT/frames" first
    dump "$OUT/frames" first
    shot "$OUT/frames" home
    if [ "$_ff" = 1 ]; then
        step first_frame ok "canvas presented + frames/first.jpeg"
    else
        fail_step first_frame timeout "未在窗口内看到 canvas presented（截图仍已归档）"
    fi
    APP_PID="$(dev_pid)"
    return 0
}

blazor_step() {
    [ -n "$UDID" ] || { step blazor skipped "no UDID"; return 0; }
    : > "$TMP/blazor-variants.txt"
    if [ -n "$BLAZOR_HAP" ]; then
        printf 'custom:%s\n' "$BLAZOR_HAP" >> "$TMP/blazor-variants.txt"
    else
        [ -f "$KIT_DIR/hello-blazorwasm-host-unsigned.hap" ] && printf 'default:%s\n' "$KIT_DIR/hello-blazorwasm-host-unsigned.hap" >> "$TMP/blazor-variants.txt"
        [ -f "$KIT_DIR/hello-blazorwasm-host-nocsp-unsigned.hap" ] && printf 'nocsp:%s\n' "$KIT_DIR/hello-blazorwasm-host-nocsp-unsigned.hap" >> "$TMP/blazor-variants.txt"
    fi
    [ -s "$TMP/blazor-variants.txt" ] || { step blazor skipped "kit 内无 Blazor hap"; return 0; }
    _ok=0; _total=0; _notes=""
    while IFS= read -r _line; do
        [ -n "$_line" ] || continue
        _v="${_line%%:*}"; _u="${_line#*:}"
        _dir="$OUT/blazor/$_v"; mkdir -p "$_dir"
        _signed="$_u"
        case "$_u" in
            *-unsigned.hap)
                _signed="$_dir/signed.hap"
                sign_one "$_u" "$_signed" "$BLAZOR_BUNDLE" || { fail_step blazor failed "$_v 重签失败"; continue; } ;;
        esac
        _trc=0
        run_tester --kit-dir "$KIT_DIR" --blazor-probe --blazor-hap "$_signed" --blazor-bundle "$BLAZOR_BUNDLE" \
            --out "$_dir/probe" > "$_dir/probe.log" 2>&1 || _trc=$?
        _sum="$_dir/probe/summary.txt"
        _boot="$(sumval "$_sum" blazor_boot)"
        _rend="$(sumval "$_sum" blazor_rendered)"
        _total=$((_total + 1))
        if [ "$_boot" != yes ] || [ "$_rend" != yes ]; then
            fail_step blazor failed "$_v markers boot=${_boot:-?} rendered=${_rend:-?} rc=$_trc"
            continue
        fi
        _click="skipped(no-python3)"
        if [ "$HAVE_PY" = 1 ]; then
            _click=failed
            if dump "$_dir" click-home && layout_click_text "$_dir" click-home "Open the interactive counter" contains; then
                sleep 2
                dump "$_dir" click-counter || true
                if layout_click_text "$_dir" click-counter "Click me" contains; then
                    sleep 2
                    dump "$_dir" click-count || true
                    _cnt="$(grep -o 'Current count: [0-9]*' "$_dir/click-count.json" 2>/dev/null | head -n1)"
                    case "$_cnt" in
                        'Current count: '*)
                            _n="$(printf '%s' "$_cnt" | tr -dc '0-9')"
                            if [ "${_n:-0}" -ge 1 ] 2>/dev/null; then _click="ok(${_cnt})"; else _click="partial(${_cnt})"; fi ;;
                        *) _click="partial(no-count)" ;;
                    esac
                fi
            fi
            shot "$_dir" final
        fi
        _ok=$((_ok + 1))
        _notes="$_notes $_v=ok:${_click}"
        step blazor ok "$_v boot=yes rendered=yes click=$_click"
    done < "$TMP/blazor-variants.txt"
    log "Blazor A/B 完成: total=$_total ok=$_ok$_notes"
    return 0
}

# ---- dynamic slots (green-button detection) -----------------------------------------
app_rect() { # MAUI window rect from WindowManagerService -> "x1 y1 x2 y2" (empty when absent)
    _label="${BUNDLE##*.}"
    [ -n "$_label" ] || _label="$BUNDLE"
    hdr "hidumper -s WindowManagerService -a '-a'" | grep -a "$_label" | head -n1 \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "[") {print $(i+1), $(i+2), $(i+3), $(i+4); exit}}'
}
green_roles() { # <jpeg> [x1 y1 x2 y2] -> ROLE x y lines (scan may be clipped to the app window)
    [ "$HAVE_PY" = 1 ] || return 1
    python3 - "$1" "${2:-}" <<'PY' 2>/dev/null
import sys
try:
    from PIL import Image
except Exception:
    sys.exit(1)
im = Image.open(sys.argv[1]).convert('RGB')
W, H = im.size
bx1, by1, bx2, by2 = 0, 0, W, H
if len(sys.argv) > 2 and sys.argv[2].strip():
    try:
        p = [int(v) for v in sys.argv[2].split()]
        if len(p) == 4:
            bx1, by1, bx2, by2 = max(0, p[0]), max(0, p[1]), min(W, p[2]), min(H, p[3])
    except Exception:
        pass
px = im.load()
mask = [[False] * H for _ in range(W)]
for y in range(by1, by2, 2):
    for x in range(bx1, bx2, 2):
        r, g, b = px[x, y]
        if 20 <= r <= 130 and 130 <= g <= 220 and 60 <= b <= 170 and (g - r) >= 40 and (g - b) >= 20:
            mask[x][y] = True
seen = [[False] * H for _ in range(W)]
boxes = []
for y in range(by1, by2, 2):
    for x in range(bx1, bx2, 2):
        if not mask[x][y] or seen[x][y]:
            continue
        stack = [(x, y)]; seen[x][y] = True; xs = []; ys = []
        while stack:
            cx, cy = stack.pop(); xs.append(cx); ys.append(cy)
            for dx, dy in ((2, 0), (-2, 0), (0, 2), (0, -2)):
                nx, ny = cx + dx, cy + dy
                if bx1 <= nx < bx2 and by1 <= ny < by2 and not seen[nx][ny] and mask[nx][ny]:
                    seen[nx][ny] = True; stack.append((nx, ny))
        if len(xs) * 4 < 4000:
            continue
        boxes.append((min(xs), min(ys), max(xs), max(ys)))
boxes.sort(key=lambda b: (b[1], b[0]))
wide = [b for b in boxes if (b[2] - b[0]) >= 1500]
narrow = [b for b in boxes if (b[2] - b[0]) < 1000]
row1y = min((b[1] for b in wide), default=10 ** 9)
row1 = sorted([b for b in narrow if b[1] <= row1y], key=lambda b: b[0])
if len(row1) >= 1:
    b = row1[0]; print('ACT_A %d %d' % ((b[0] + b[2]) // 2, (b[1] + b[3]) // 2))
if len(row1) >= 2:
    b = row1[1]; print('ACT_B %d %d' % ((b[0] + b[2]) // 2, (b[1] + b[3]) // 2))
if len(row1) >= 3:
    b = row1[2]; print('ADD_C %d %d' % ((b[0] + b[2]) // 2, (b[1] + b[3]) // 2))
wide = sorted(wide, key=lambda b: b[1])
if len(wide) >= 3:
    b = wide[1]; print('ADD_D %d %d' % ((b[0] + b[2]) // 2, (b[1] + b[3]) // 2))
    b = wide[2]; print('ADD_E %d %d' % ((b[0] + b[2]) // 2, (b[1] + b[3]) // 2))
print('BOXES %d ROW1 %d WIDE %d' % (len(boxes), len(row1), len(wide)))
PY
}
slots_click_role() { # <dir> <tag> <role> <sleep>
    shot "$1" "$2"
    _roles="$(green_roles "$1/$2.jpeg" "$(app_rect)")" || { warn "slots: 绿块定位失败（PIL/截图）"; return 1; }
    _xy="$(printf '%s\n' "$_roles" | awk -v r="$3" '$1 == r {print $2 " " $3; exit}')"
    [ -n "$_xy" ] || { warn "slots: $2 未找到按钮角色 $3"; return 1; }
    _clk="$(hd "uitest uiInput click $_xy")"
    case "$_clk" in *10106102*) LOCK_HINT=1; warn "slots click 返回 10106102（锁屏？）" ;; esac
    log "   slots: $3 -> $_xy"
    sleep "$4"
    return 0
}
slots_step() {
    if [ -n "$SLOTS_CLICKS" ]; then
        _slots_explicit
        return 0
    fi
    if [ "$HAVE_PY" != 1 ] || ! python3 -c 'import PIL' >/dev/null 2>&1; then
        step slots skipped "no python3/PIL UI driver（可用 --slots-clicks x,y;... 显式驱动）"
        return 0
    fi
    ensure_app >/dev/null 2>&1 || { step slots skipped "app not running"; return 0; }
    mkdir -p "$OUT/slots"
    _ui=0; _ui_ok=0
    while [ "$_ui" -lt 3 ]; do
        ensure_app >/dev/null 2>&1 || true
        sleep 2
        shot "$OUT/slots" "precheck-$_ui"
        _roles="$(green_roles "$OUT/slots/precheck-$_ui.jpeg" "$(app_rect)")" || _roles=""
        if printf '%s\n' "$_roles" | grep -q '^ACT_A ' && printf '%s\n' "$_roles" | grep -q '^ADD_C '; then
            _ui_ok=1
            break
        fi
        warn "slots: 窗口未就绪/被其他窗口遮挡（第 $((_ui + 1)) 次）；重新前台化重试"
        aa_start "" >/dev/null 2>&1 || true
        _ui=$((_ui + 1))
    done
    if [ "$_ui_ok" != 1 ]; then
        step slots skipped "窗口 3 次未就绪（绿块未找到 A/C；可能被其他窗口遮挡）"
        return 0
    fi
    hd "hilog -r" >/dev/null 2>&1 || true
    (hdc_cmd shell hilog > "$OUT/slots/stream.txt" 2>&1) & STREAM_PID=$!
    sleep 1
    if slots_click_role "$OUT/slots" s1-add-c ADD_C 8; then :
    else
        step slots skipped "未找到 Add web C 按钮（绿块定位）；3 控件/destroy 未跑"
        stop_stream
        return 0
    fi
    shot "$OUT/slots" s2-added-c; dump "$OUT/slots" s2-added-c || true
    slots_click_role "$OUT/slots" s3-add-d ADD_D 8 && { shot "$OUT/slots" s4-added-d; dump "$OUT/slots" s4-added-d || true; } || true
    slots_click_role "$OUT/slots" s5-add-e ADD_E 10 && { shot "$OUT/slots" s6-added-e; dump "$OUT/slots" s6-added-e || true; } || true
    slots_click_role "$OUT/slots" s7-activate-a ACT_A 10 && { shot "$OUT/slots" s8-activated-a; dump "$OUT/slots" s8-activated-a || true; } || true
    slots_click_role "$OUT/slots" s9-remove-c ADD_C 8 && { shot "$OUT/slots" s10-removed-c; dump "$OUT/slots" s10-removed-c || true; } || true
    slots_click_role "$OUT/slots" s11-readd-c ADD_C 8 && { shot "$OUT/slots" s12-readded-c; dump "$OUT/slots" s12-readded-c || true; } || true
    sleep 2
    stop_stream
    _create="$(count_marker "$OUT/slots/stream.txt" 'web slot create')"
    _destroy="$(count_marker "$OUT/slots/stream.txt" 'web slot destroy')"
    _capacity="$(count_marker "$OUT/slots/stream.txt" 'web capacity')"
    _preempt="$(count_marker "$OUT/slots/stream.txt" 'hybrid overlay preempted')"
    _restore="$(count_marker "$OUT/slots/stream.txt" 'hybrid overlay restored')"
    _replay="$(count_marker "$OUT/slots/stream.txt" 'hybrid overlay replay')"
    _mc="$(count_marker "$OUT/slots/stream.txt" '[maui-capacity]')"
    {
        printf 'web slot create=%s\nweb slot destroy=%s\nweb capacity=%s\n' "$_create" "$_destroy" "$_capacity"
        printf 'hybrid overlay preempted=%s restored=%s replay=%s\n' "$_preempt" "$_restore" "$_replay"
        printf '[maui-capacity]=%s\n' "$_mc"
    } > "$OUT/slots/markers.txt"
    grep -aE 'web slot (create|destroy)|web capacity|hybrid overlay (preempted|restored|replay)|\[maui-capacity\]' \
        "$OUT/slots/stream.txt" > "$OUT/slots/marker-lines.txt" 2>/dev/null || true
    if [ "$_create" -gt 0 ] && [ "$_destroy" -gt 0 ]; then
        step slots ok "create=$_create destroy=$_destroy capacity=$_capacity capacity_raw=$_mc preempt=$_preempt restore=$_restore replay=$_replay"
    elif [ "${_create:-0}" -gt 0 ] 2>/dev/null || [ "${_destroy:-0}" -gt 0 ] 2>/dev/null; then
        step slots partial "create=$_create destroy=$_destroy capacity=$_capacity capacity_raw=$_mc"
    else
        fail_step slots failed "点击已执行但无 slot 标记（create=0 destroy=0；见 slots/stream.txt）"
    fi
    return 0
}
slots_explicit() {
    mkdir -p "$OUT/slots"
    ensure_app >/dev/null 2>&1 || { step slots skipped "app not running"; return 0; }
    hd "hilog -r" >/dev/null 2>&1 || true
    (hdc_cmd shell hilog > "$OUT/slots/stream.txt" 2>&1) & STREAM_PID=$!
    sleep 1
    _i=0
    _rest="$SLOTS_CLICKS"
    while [ -n "$_rest" ]; do
        case "$_rest" in
            *';'*) _one="${_rest%%;*}"; _rest="${_rest#*;}" ;;
            *) _one="$_rest"; _rest="" ;;
        esac
        _one="$(printf '%s' "$_one" | tr -d ' ')"
        [ -n "$_one" ] || continue
        _x="${_one%%,*}"; _y="${_one#*,}"
        case "$_x$_y" in ''|*[!0-9]*) warn "slots-clicks 非法坐标: $_one"; continue ;; esac
        _i=$((_i + 1))
        _clk="$(hd "uitest uiInput click $_x $_y")"
        case "$_clk" in *10106102*) LOCK_HINT=1; warn "slots click 返回 10106102（锁屏？）" ;; esac
        log "   slots: explicit #$_i -> ($_x,$_y)"
        sleep 8
        shot "$OUT/slots" "x$_i"
    done
    sleep 2
    stop_stream
    _create="$(count_marker "$OUT/slots/stream.txt" 'web slot create')"
    _destroy="$(count_marker "$OUT/slots/stream.txt" 'web slot destroy')"
    _mc="$(count_marker "$OUT/slots/stream.txt" '[maui-capacity]')"
    step slots partial "explicit clicks=$_i create=$_create destroy=$_destroy capacity_raw=$_mc"
    return 0
}

a11y_step() {
    ensure_app >/dev/null 2>&1 || { step a11y skipped "app not running"; return 0; }
    mkdir -p "$OUT/a11y"
    _rc=0
    run_tester --kit-dir "$KIT_DIR" --a11y-probe --out "$OUT/a11y/tester-run" > "$OUT/a11y/tester-run.log" 2>&1 || _rc=$?
    _sum="$OUT/a11y/tester-run/summary.txt"
    _sc="$(sumval "$_sum" a11y_selfcheck)"
    _st="$(sumval "$_sum" a11y_provider_status)"
    _nc="$(sumval "$_sum" a11y_node_count)"
    if [ "$_sc" = ok ]; then
        step a11y ok "status=${_st:-?} node_count=${_nc:-?}"
    else
        step a11y partial "selfcheck=${_sc:-?} status=${_st:-?} node_count=${_nc:-?} rc=$_rc"
    fi
    return 0
}

deeplink_step() {
    mkdir -p "$OUT/deeplink"
    _pid_before="$(dev_pid)"
    hd "aa force-stop $BUNDLE" >/dev/null 2>&1
    sleep 1
    hd "hilog -r" >/dev/null 2>&1 || true
    _cold="$(aa_start "-U 'app://media/probe?from=dr-cold'")"
    printf '%s\n' "$_cold" > "$OUT/deeplink/cold-start.txt"
    _i=0
    while [ -z "$(dev_pid)" ] && [ "$_i" -lt 30 ]; do sleep 1; _i=$((_i + 1)); done
    sleep 3
    hd "hilog -x" > "$OUT/deeplink/cold-hilog.txt" 2>&1 || true
    grep -aE 'activation|delivered=' "$OUT/deeplink/cold-hilog.txt" > "$OUT/deeplink/cold-lines.txt" 2>/dev/null || true
    _pid_cold="$(dev_pid)"
    _hot="$(aa_start "-U 'app://media/probe?from=dr-hot'")"
    printf '%s\n' "$_hot" > "$OUT/deeplink/hot-start.txt"
    sleep 3
    hd "hilog -x" > "$OUT/deeplink/hot-hilog.txt" 2>&1 || true
    grep -aE 'activation|delivered=' "$OUT/deeplink/hot-hilog.txt" > "$OUT/deeplink/hot-lines.txt" 2>/dev/null || true
    shot "$OUT/deeplink" hot
    _pid_after="$(dev_pid)"
    _deliv="$(grep -ac 'delivered=1' "$OUT/deeplink/hot-lines.txt" 2>/dev/null || true)"
    _act="$(grep -ac 'activation' "$OUT/deeplink/hot-lines.txt" 2>/dev/null || true)"
    if [ "${_deliv:-0}" -gt 0 ] 2>/dev/null; then
        step deeplink ok "hot delivered=1 lines=$_act pid $_pid_before->$_pid_cold->$_pid_after"
    elif [ "${_act:-0}" -gt 0 ] 2>/dev/null; then
        step deeplink partial "hot activation 行见但未见 delivered=1（uri 路由可能未注册；见 deeplink/hot-lines.txt）"
    else
        fail_step deeplink failed "未见 activation/hot delivered 行（见 deeplink/hot-hilog.txt）"
    fi
    return 0
}

soak_step() {
    [ "$SOAK_MIN" -ge 1 ] || { step soak skipped "soak-min=0"; return 0; }
    ensure_app >/dev/null 2>&1 || { step soak skipped "app not running"; return 0; }
    mkdir -p "$OUT/soak"
    _pid0="$(dev_pid)"
    printf '%s\n' "$_pid0" > "$OUT/soak/pid-start.txt"
    hd "hidumper -e --list $BUNDLE" 2>/dev/null | grep -aE 'hellomauiapp|CppCrash|AppInputBlock|AppFreeze|JSCRASH' | sort > "$OUT/soak/fault-before.txt" 2>/dev/null || true
    _ut0="$(hdr "bm dump -n $BUNDLE" | sed -n 's/.*"updateTime": *\([0-9]*\).*/\1/p' | head -n1)"
    printf 'minute,wall,pid,vmrss_kb,threads,fd,state,power\n' > "$OUT/soak/samples.csv"
    _lost=0
    _k=0
    while [ "$_k" -le "$SOAK_MIN" ]; do
        _pid="$(dev_pid)"
        _wall="$(date '+%T')"
        if [ -z "$_pid" ]; then
            _lost=$((_lost + 1))
            printf '%s,%s,NA,NA,NA,NA,NA,NA\n' "$_k" "$_wall" >> "$OUT/soak/samples.csv"
            warn "soak t=${_k}min: pid 丢失，重启应用"
            aa_start "" >/dev/null 2>&1
            sleep 10
        else
            _st="$(hd "cat /proc/$_pid/status" 2>/dev/null)"
            _rss="$(printf '%s\n' "$_st" | awk '/VmRSS/{print $2; exit}')"
            _thr="$(printf '%s\n' "$_st" | awk '/Threads/{print $2; exit}')"
            _fd="$(hdr "ls /proc/$_pid/fd 2>/dev/null" | grep -c . || true)"
            [ -n "$_fd" ] || _fd="NA"
            _pw="$(hdr "hidumper -s PowerManagerService -a '-a'" | sed -n 's/.*Current State: *\([A-Za-z]*\).*/\1/p' | head -n1)"
            printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$_k" "$_wall" "${_pid:-NA}" "${_rss:-NA}" "${_thr:-NA}" "${_fd:-NA}" "NA" "${_pw:-NA}" >> "$OUT/soak/samples.csv"
            log "   soak t=${_k}min pid=$_pid rss=${_rss:-?}kB threads=${_thr:-?} fd=${_fd:-?} power=${_pw:-?}"
        fi
        [ "$_k" -lt "$SOAK_MIN" ] && sleep "${DEVICE_ROUND_SOAK_TICK:-60}"
        _k=$((_k + 1))
    done
    _pidE="$(dev_pid)"
    if [ -n "$_pidE" ]; then
        hd "hidumper --mem-smaps $_pidE" > "$OUT/soak/smaps-end.txt" 2>&1 || true
        grep -a 'entry/libs/arm64/lib' "$OUT/soak/smaps-end.txt" > "$OUT/soak/maps-applibs.txt" 2>/dev/null || true
    fi
    hd "hidumper -e --list $BUNDLE" 2>/dev/null | grep -aE 'hellomauiapp|CppCrash|AppInputBlock|AppFreeze|JSCRASH' | sort > "$OUT/soak/fault-after.txt" 2>/dev/null || true
    comm -13 "$OUT/soak/fault-before.txt" "$OUT/soak/fault-after.txt" > "$OUT/soak/fault-new.txt" 2>/dev/null || true
    _new="$(count_marker "$OUT/soak/fault-new.txt" '')"
    _ut1="$(hdr "bm dump -n $BUNDLE" | sed -n 's/.*"updateTime": *\([0-9]*\).*/\1/p' | head -n1)"
    {
        printf 'pid_start=%s\npid_end=%s\npid_lost=%s\nfault_new=%s\nupdate_time_start=%s\nupdate_time_end=%s\n' \
            "${_pid0:-NA}" "${_pidE:-NA}" "$_lost" "$_new" "${_ut0:-NA}" "${_ut1:-NA}"
    } > "$OUT/soak/meta.txt"
    if [ "$_new" -gt 0 ] 2>/dev/null; then
        fail_step soak failed "fault_new=$_new pid_lost=$_lost（见 soak/fault-new.txt）"
    elif [ "$_lost" -gt 0 ]; then
        step soak partial "minutes=$SOAK_MIN pid_lost=$_lost fault_new=0"
    else
        step soak ok "minutes=$SOAK_MIN pid_lost=0 fault_new=0"
    fi
    return 0
}

# ---- summary / plan / archive --------------------------------------------------------
write_summary() {
    {
        printf '# device-round.sh 摘要（每行 KEY=value）\n'
        printf 'script_version=%s\n' "$SCRIPT_VERSION"
        printf 'generated_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
        printf 'dry_run=%s\n' "$DRY_RUN"
        printf 'device=%s\n' "${DEVICE:-<default>}"
        printf 'udid=%s\n' "${UDID:-<unknown>}"
        printf 'device_model=%s\n' "${DEVICE_MODEL:-<unavailable>}"
        printf 'device_software=%s\n' "${DEVICE_SOFT:-<unavailable>}"
        printf 'kit_source=%s\n' "$KIT_SOURCE"
        printf 'kit_tar=%s\n' "${KIT_TAR:-<none>}"
        printf 'kit_tar_sha256=%s\n' "${KIT_TAR_SHA:-<n/a>}"
        printf 'kit_sidecar=%s\n' "${KIT_SIDECAR:-n/a}"
        printf 'kit_dir=%s\n' "$KIT_DIR"
        printf 'tree_digest=%s\n' "${TREE_DIGEST:-<unavailable>}"
        printf 'expect_tree_digest=%s\n' "${EXPECT_TREE:-<none>}"
        printf 'mode=%s\n' "$MODE"
        printf 'main_hap=%s\n' "${MAIN_HAP:-<none>}"
        printf 'main_hap_sha256=%s\n' "${MAIN_HAP_SHA:-<n/a>}"
        printf 'main_hap_signed=%s\n' "$MAIN_HAP_SIGNED"
        printf 'runtime_mode=%s\n' "${MODE_CHECK:-<unavailable>}"
        printf 'bundle=%s\n' "$BUNDLE"
        printf 'tester_run=%s\n' "${TESTER_RUN:-<none>}"
        printf 'lock=%s\n' "${LOCK_PATH:-<none>}"
        printf 'lock_hint_10106102=%s\n' "$LOCK_HINT"
        printf 'steps_file=%s\n' "$STEPS_FILE"
        printf 'failures=%s\n' "$FAILURES"
        printf 'archive=%s\n' "${ARCHIVE:-<none>}"
        cat "$STEPS_FILE" 2>/dev/null | while IFS='	' read -r _n _s _r; do
            printf 'step_%s=%s\n' "$_n" "$_s"
        done
    } > "$OUT/summary.txt"
    step_list_to_text
}
step_list_to_text() {
    : > "$OUT/steps.txt"
    cat "$STEPS_FILE" 2>/dev/null | while IFS='	' read -r _n _s _r; do
        printf '%s: %s — %s\n' "$_n" "$_s" "$_r" >> "$OUT/steps.txt"
    done
}
archive_round() {
    write_summary
    _ts="$(date '+%Y%m%d-%H%M%S')"
    ARCHIVE="$(dirname "$OUT")/$(basename "$OUT")-$_ts.tar.gz"
    rm -f "$ARCHIVE"
    tar -czf "$ARCHIVE" -C "$(dirname "$OUT")" "$(basename "$OUT")" || { warn "归档失败: $ARCHIVE"; return 1; }
    (cd "$(dirname "$ARCHIVE")" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256") 2>/dev/null || true
    log "证据归档 -> $ARCHIVE"
    return 0
}

print_plan() {
    log "== dry-run 计划（本地资产核验已完成；不执行任何设备命令、不取锁） =="
    log "   kit:      $KIT_DIR (source=$KIT_SOURCE, tree=${TREE_DIGEST:-?})"
    log "   main:     ${MAIN_HAP:-<aid 解析后确定>} (mode=$MODE bundle=$BUNDLE)"
    log "   tester-run: ${TESTER_RUN:-<none>}"
    log "   1) 取锁:   mkdir ${LOCK_PATH:-<lock>} + owner；重试 ${DEVICE_ROUND_LOCK_ATTEMPTS:-180}x${DEVICE_ROUND_LOCK_INTERVAL:-10}s"
    log "   2) 重签:   $SIGN_SCRIPT <udid> --unsigned <kit>/*-unsigned.hap --out $OUT/sign/"
    log "   3) 核心:   sh tester-run.sh --kit-dir <kit> --install --start --capture $CAPTURE --hap <main> --out $OUT/core/tester-run"
    log "      + canvas 行 / snapshot_display 首帧 / uitest dumpLayout"
    [ "$OPT_BLAZOR" = 1 ] && log "   4) Blazor: 重签 default+nocsp -> tester-run --blazor-probe -> 点击 /counter（BLZ_BOOT/BLZ_RENDERED）"
    [ "$OPT_SLOTS" = 1 ] && log "   5) 动态槽: 绿块定位 Add web C/D/E -> Activate A -> Remove/Re-add C；归档 [maui-capacity] 原文"
    [ "$OPT_A11Y" = 1 ] && log "   6) a11y:   tester-run --a11y-probe（status/nodeCount）"
    [ "$OPT_DEEPLINK" = 1 ] && log "   7) 深链:   aa force-stop -> aa start -U app://media/probe?from=dr-cold -> 运行中 -U ...dr-hot"
    log "   8) probe:  sh tester-run.sh --dry-run（v14 契约）${PROBES_DIR:+ + --probes $PROBES_DIR}"
    log "   9) soak:   ${SOAK_MIN} min RSS/线程/fd 采样${SOAK_MIN:+（0=关）}"
    log "  10) 归档:   $OUT/ -> <out>-<时间戳>.tar.gz（log/截图/json/summary）"
    log "   dry-run 完成：未执行任何设备操作"
    return 0
}

# ---- device preflight ----------------------------------------------------------------
device_preflight() {
    _reason="$(device_reason)"
    if [ -n "$_reason" ]; then
        warn "无可用设备：$_reason"
        step device failed "$_reason"
        return 3
    fi
    if [ "$NO_LOCK" = 1 ]; then
        step lock skipped "--no-lock"
    else
        if ! lock_acquire; then
            fail_step lock timeout "$LOCK_PATH owner=$(lock_owner)"
            return 1
        fi
        step lock ok "$LOCK_PATH"
    fi
    UDID="$(hdr "bm get --udid" | grep -E '^[0-9A-Fa-f]{64}$' | tail -n1)"
    DEVICE_MODEL="$(hdr "param get const.product.model" | head -n1)"
    DEVICE_SOFT="$(hdr "param get const.ohos.fullname" | head -n1)"
    log "设备: ${DEVICE_MODEL:-?} / ${DEVICE_SOFT:-?} UDID=${UDID:-<unavailable>}"
    hd "power-shell wakeup" >/dev/null 2>&1 || true
    hd "power-shell timeout -o 21600000" >/dev/null 2>&1 || true
    hilog_grow
    return 0
}

# ---- main ----------------------------------------------------------------------------
main() {
    mkdir -p "$OUT"
    OUT="$(cd "$OUT" && pwd -P)"
    RUNLOG="$OUT/device-round.log"
    STEPS_FILE="$OUT/steps.tsv"
    : > "$RUNLOG"; : > "$STEPS_FILE"
    command -v python3 >/dev/null 2>&1 && HAVE_PY=1
    TMP="$(mktemp -d 2>/dev/null || true)"
    if [ -z "$TMP" ]; then TMP="${TMPDIR:-/tmp}/device-round.$$"; mkdir -p "$TMP"; fi
    trap cleanup 0
    trap 'exit 1' 1 2 15
    LOCK_PATH="${DEVICE_ROUND_LOCK:-}"
    if [ -z "$LOCK_PATH" ]; then
        if [ -d /data/storage/el2/base/tmp/opencode ] && [ -w /data/storage/el2/base/tmp/opencode ]; then
            LOCK_PATH="/data/storage/el2/base/tmp/opencode/.device-lock"
        else
            LOCK_PATH="${TMPDIR:-/tmp}/.device-lock"
        fi
    fi
    log "device-round.sh $SCRIPT_VERSION"
    log "kit:       $KIT_ARG"
    log "out:       $OUT"
    log "mode:      $MODE  capture: ${CAPTURE}s  soak: ${SOAK_MIN}min  锁: $LOCK_PATH"
    [ "$DO_UNINSTALL" = 1 ] && UNINSTALL_FLAG="--uninstall"

    resolve_kit
    TESTER_RUN="${TESTER_RUN:-$KIT_DIR/tester-run.sh}"
    [ -f "$TESTER_RUN" ] || TESTER_RUN="$SELF_DIR/tester-run.sh"
    if [ ! -f "$TESTER_RUN" ]; then
        fail_step verify failed "找不到 tester-run.sh（kit 内或 $SELF_DIR）"
        archive_round
        exit 1
    fi
    log "tester-run: $TESTER_RUN ($(sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$TESTER_RUN" | head -n1))"

    if ! verify_kit_step; then
        [ "$DRY_RUN" = 1 ] && { print_plan; exit 1; }
        archive_round
        exit 1
    fi

    if [ "$DRY_RUN" = 1 ]; then
        resolve_main_hap || true
        print_plan
        exit 0
    fi

    device_preflight
    _prc=$?
    if [ "$_prc" -ne 0 ]; then
        archive_round
        exit "$_prc"
    fi
    if ! resolve_main_hap; then
        archive_round
        exit 1
    fi

    core_step
    [ "$OPT_BLAZOR" = 1 ] && blazor_step
    [ "$OPT_SLOTS" = 1 ] && slots_step
    [ "$OPT_A11Y" = 1 ] && a11y_step
    [ "$OPT_DEEPLINK" = 1 ] && deeplink_step
    tester_run_probe_step
    soak_step

    archive_round
    log "== 完成：$(grep -c . "$STEPS_FILE" 2>/dev/null || echo 0) 步，failures=$FAILURES =="
    while IFS='	' read -r _n _s _r; do
        log "   $_n: $_s — $_r"
    done < "$STEPS_FILE"
    [ "$FAILURES" -gt 0 ] && exit 1
    exit 0
}

main "$@"
