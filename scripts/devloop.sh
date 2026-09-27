#!/bin/sh
# devloop.sh - one-command incremental build -> (sign) -> install -> start -> logs loop for a
# .NET OpenHarmony hap. Replaces the IDE Hot Reload loop (the hdc debug bridge is restricted by
# device policy, so an edit is shipped by re-publishing and re-installing the hap instead).
#
# Commands (default all), options and exit codes: usage() below.
# Exit codes: 0 = ok; 1 = a step failed; 2 = usage error; 3 = no hdc / no device (refused).
# Env: HDC (default hdc; may be an absolute path), DOTNET (default dotnet),
#      DEVLOOP_SIGN_TOOL (default scripts/sign-for-device.sh; the selftest stubs it), TMPDIR.
set -e

SCRIPT_VERSION="1 (2026-09-27)"

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { warn "$*"; exit 1; }

usage() {
    cat <<'EOF'
用法: sh devloop.sh [命令] [选项]
  一条命令完成 .NET OpenHarmony hap 的开发闭环：增量 publish ->（可选外部签名）-> 安装 ->
  启动 -> 过滤 hilog。设备策略限制 hdc 调试桥（Hot Reload 不可用），本脚本是该闭环的替代。

命令（默认 all）:
  build     增量 dotnet publish（-p: 属性透传）
  sign      对 publish 出的 -unsigned.hap 做外部签名（需 --sign + 签名材料）
  install   hdc install -r <hap>（--hap 可重复；默认取 publish 输出里最新的 hap）
  start     校验 bundleName 白名单后 hdc shell aa start -a EntryAbility -b <bundleName>
  logs      hdc shell hilog 过滤（--follow 跟随；默认录 --log-seconds 秒后退出）
  all       build ->（--sign）-> install -> start -> logs（默认）

选项:
  --project <dir>          项目目录（默认 <repo>/test/hello-maui-app）
  -f, --framework <tfm>   TFM（默认 net11.0-openharmony26.0）
  -r, --rid <rid>         RID（默认 openharmony-arm64）
  -c, --configuration <c> 配置（默认 Release）
  -p:<k>=<v>               dotnet publish 透传属性（可重复；等价 --property <k>=<v>）
  --property <k>=<v>       同上
  --out-dir <dir>         publish 输出目录（默认 <project>/bin/<cfg>/<tfm>/<rid>）
  --hap <hap>             指定 hap（可重复；install/start/sign 用）
  --bundle <name>         启动用 bundleName（默认从 hap 的 module.json 读取）
  --device <id>           hdc -t <id>（等价每条 hdc 命令都加 -t <id>）
  --watch                 轮询项目源文件时间戳（find -newer；无 inotify），变更后重跑命令
  --interval <sec>        --watch 轮询间隔（默认 2，>= 1）
  --follow                logs 持续跟随 hilog（Ctrl-C 退出；watch 模式下退化为有界录制）
  --log-seconds <n>       logs 非跟随模式的录制秒数（默认 5，>= 1）
  --filter <regex>        logs 过滤正则（默认与 tester-run.sh 的 FILTER_RE 相同）
  --dry-run               只打印计划，不执行任何命令
  -h, --help              本帮助

外部签名（--sign 才需要；转调 sign-for-device.sh --external，复用其校验/口令路径）:
  --sign                        启用签名步骤；未给材料时跳过并用 publish 出的 hap
  --sign-profile <p7b>          调试 profile（必须绑定 --expect-udid 的 UDID）
  --sign-key <p12>              私钥库（--sign-alias 对应的 key）
  --sign-alias <alias>          p12 里的 keyAlias
  --sign-cert <cer>             app 证书链（省略时 sign-for-device.sh 找 p7b 同目录的 *.cer）
  --sign-pwd-file <file>        p12 口令文件（第一行；不落 argv/日志）
  --sign-pwd-input-mode         口令交互输入（hap-sign-tool -pwdInputMode 1）
  --expect-udid <UDID>          签名绑定的设备 UDID（省略时读 hdc shell bm get -u）

健壮性:
  * 没装 hdc / 没有设备：设备步骤直接拒绝（退出码 3）并说明；--dry-run 仍可打印计划。
  * bundleName 进 hdc 命令前按 tester-run.sh 同一规则校验（点分、字母开头 [A-Za-z0-9_]*），
    防止 hap 的 module.json 把 shell 元字符带进 `hdc shell aa start`。
  * 所有路径按带空格处理（不展开未加引号的变量，属性通过 set -- 逐个传递）。
  * 签名口令只以文件/交互方式传递，绝不出现在 argv 或日志。

示例:
  sh devloop.sh                                     # build -> install -> start -> 录 5s hilog
  sh devloop.sh build -p:OpenHarmonyBundleName=com.example.hellomauiapp
  sh devloop.sh install --hap ./out/app.hap --device 1234ABCD
  sh devloop.sh all --sign --sign-profile p.p7b --sign-key k.p12 --sign-alias key0 \
      --sign-cert chain.cer --sign-pwd-file ~/.ohos/pwd --expect-udid <UDID>
  sh devloop.sh --watch --interval 3               # 改文件就重跑整条链
  sh devloop.sh --dry-run --sign --sign-profile p.p7b --sign-key k.p12 --sign-alias key0
EOF
}

# ---- paths / defaults ----------------------------------------------------------------
# Resolve the repo root before anything else, so the run is identical from any cwd.
_self="$0"
case "$_self" in
    */*) ;;
    *) _self="$(command -v "$_self" 2>/dev/null || printf '%s' "$_self")" ;;
esac
SELF_DIR="$(cd "$(dirname "$_self")" && pwd -P)" || SELF_DIR="$(pwd -P)"
W="$(cd "$SELF_DIR/.." && pwd -P)" || W="$SELF_DIR"

HDC="${HDC:-hdc}"
DOTNET="${DOTNET:-dotnet}"
SIGN_TOOL="${DEVLOOP_SIGN_TOOL:-$W/scripts/sign-for-device.sh}"

COMMAND=""
PROJECT="$W/test/hello-maui-app"
TFM="net11.0-openharmony26.0"
RID="openharmony-arm64"
CFG="Release"
OUTDIR=""
PROPS=""
HAPS=""
BUNDLE=""
DEVICE=""
INTERVAL=2
WATCH=0
FOLLOW=0
LOG_SECS=5
# Same filter as tester-run.sh FILTER_RE (keep the two in sync; --filter overrides).
FILTER_RE='hellomaui|maui|dotnet|openharmonyhost|AppKilledReporter|JsError|appspawn|PROBE'
DRY=0
SIGN=0
SIGN_PROFILE=""
SIGN_KEY=""
SIGN_ALIAS=""
SIGN_CERT=""
SIGN_PWD_FILE=""
SIGN_PWD_INPUT=0
EXPECT_UDID=""
UNSIGNED_HAP=""
SIGNED_HAP=""
INSTALL_LIST=""
MAIN_HAP=""
BUNDLE_RAW=""

# ---- argument parsing -----------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --project)       [ $# -ge 2 ] || { warn "--project 需要一个目录"; usage >&2; exit 2; }; PROJECT="$2"; shift 2 ;;
        -f|--framework)  [ $# -ge 2 ] || { warn "$1 需要一个 TFM"; usage >&2; exit 2; }; TFM="$2"; shift 2 ;;
        -r|--rid)        [ $# -ge 2 ] || { warn "$1 需要一个 RID"; usage >&2; exit 2; }; RID="$2"; shift 2 ;;
        -c|--configuration) [ $# -ge 2 ] || { warn "$1 需要一个配置"; usage >&2; exit 2; }; CFG="$2"; shift 2 ;;
        --out-dir)       [ $# -ge 2 ] || { warn "--out-dir 需要一个目录"; usage >&2; exit 2; }; OUTDIR="$2"; shift 2 ;;
        -p:*)            PROPS="$PROPS
$1"; shift ;;
        --property)
            [ $# -ge 2 ] || { warn "--property 需要 <key>=<value>"; usage >&2; exit 2; }
            case "$2" in ''|-*) warn "--property 需要 <key>=<value>: '$2'"; usage >&2; exit 2 ;; esac
            PROPS="$PROPS
-p:$2"; shift 2 ;;
        --hap)
            [ $# -ge 2 ] || { warn "--hap 需要一个文件"; usage >&2; exit 2; }
            if [ -n "$HAPS" ]; then HAPS="$HAPS
$2"; else HAPS="$2"; fi
            shift 2 ;;
        --bundle)        [ $# -ge 2 ] || { warn "--bundle 需要一个名字"; usage >&2; exit 2; }; BUNDLE="$2"; shift 2 ;;
        --device)        [ $# -ge 2 ] || { warn "--device 需要一个设备 id"; usage >&2; exit 2; }; DEVICE="$2"; shift 2 ;;
        --interval)      [ $# -ge 2 ] || { warn "--interval 需要秒数"; usage >&2; exit 2; }; INTERVAL="$2"; shift 2 ;;
        --log-seconds)   [ $# -ge 2 ] || { warn "--log-seconds 需要秒数"; usage >&2; exit 2; }; LOG_SECS="$2"; shift 2 ;;
        --filter)        [ $# -ge 2 ] || { warn "--filter 需要一个正则"; usage >&2; exit 2; }; FILTER_RE="$2"; shift 2 ;;
        --watch)         WATCH=1; shift ;;
        --follow)        FOLLOW=1; shift ;;
        --dry-run)       DRY=1; shift ;;
        --sign)          SIGN=1; shift ;;
        --sign-profile)  [ $# -ge 2 ] || { warn "--sign-profile 需要一个 p7b"; usage >&2; exit 2; }; SIGN_PROFILE="$2"; shift 2 ;;
        --sign-key)      [ $# -ge 2 ] || { warn "--sign-key 需要一个 p12"; usage >&2; exit 2; }; SIGN_KEY="$2"; shift 2 ;;
        --sign-alias)    [ $# -ge 2 ] || { warn "--sign-alias 需要一个 alias"; usage >&2; exit 2; }; SIGN_ALIAS="$2"; shift 2 ;;
        --sign-cert)     [ $# -ge 2 ] || { warn "--sign-cert 需要一个 cer"; usage >&2; exit 2; }; SIGN_CERT="$2"; shift 2 ;;
        --sign-pwd-file) [ $# -ge 2 ] || { warn "--sign-pwd-file 需要一个文件"; usage >&2; exit 2; }; SIGN_PWD_FILE="$2"; shift 2 ;;
        --sign-pwd-input-mode) SIGN_PWD_INPUT=1; shift ;;
        --expect-udid)   [ $# -ge 2 ] || { warn "--expect-udid 需要一个 UDID"; usage >&2; exit 2; }; EXPECT_UDID="$2"; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        ''|build|sign|install|start|logs|all)
            [ -z "$COMMAND" ] || { warn "只能给一个命令（已有 '$COMMAND'，又来 '$1'）"; usage >&2; exit 2; }
            COMMAND="$1"; shift ;;
        *) warn "未知参数: $1"; usage >&2; exit 2 ;;
    esac
done

[ -n "$COMMAND" ] || COMMAND="all"

# ---- validation -----------------------------------------------------------------------
[ -d "$PROJECT" ] || { warn "--project 不是目录: $PROJECT"; usage >&2; exit 2; }
PROJECT="$(cd "$PROJECT" && pwd -P)"
[ -n "$TFM" ] || { warn "TFM 不能为空"; usage >&2; exit 2; }
[ -n "$RID" ] || { warn "RID 不能为空"; usage >&2; exit 2; }
[ -n "$CFG" ] || { warn "配置不能为空"; usage >&2; exit 2; }
case "$OUTDIR" in
    '') OUTDIR="$PROJECT/bin/$CFG/$TFM/$RID" ;;
    /*) ;;
    *) OUTDIR="$PWD/$OUTDIR" ;;
esac
case "$INTERVAL" in ''|*[!0-9]*) { warn "--interval 需要正整数秒: '$INTERVAL'"; usage >&2; exit 2; } ;; esac
[ "$INTERVAL" -ge 1 ] || { warn "--interval 必须 >= 1"; usage >&2; exit 2; }
case "$LOG_SECS" in ''|*[!0-9]*) { warn "--log-seconds 需要正整数秒: '$LOG_SECS'"; usage >&2; exit 2; } ;; esac
[ "$LOG_SECS" -ge 1 ] || { warn "--log-seconds 必须 >= 1"; usage >&2; exit 2; }
[ -n "$FILTER_RE" ] || { warn "--filter 不能为空"; usage >&2; exit 2; }

if [ "$SIGN" = 1 ]; then
    [ -n "$SIGN_PROFILE" ] || { warn "--sign 需要 --sign-profile <p7b>"; usage >&2; exit 2; }
    [ -n "$SIGN_KEY" ]     || { warn "--sign 需要 --sign-key <p12>"; usage >&2; exit 2; }
    [ -n "$SIGN_ALIAS" ]   || { warn "--sign 需要 --sign-alias <alias>"; usage >&2; exit 2; }
    [ -f "$SIGN_PROFILE" ] || die "--sign-profile 不存在: $SIGN_PROFILE"
    [ -f "$SIGN_KEY" ]     || die "--sign-key 不存在: $SIGN_KEY"
    [ -z "$SIGN_CERT" ] || [ -f "$SIGN_CERT" ] || die "--sign-cert 不存在: $SIGN_CERT"
    [ -z "$SIGN_PWD_FILE" ] || [ -f "$SIGN_PWD_FILE" ] || die "--sign-pwd-file 不存在: $SIGN_PWD_FILE"
else
    if [ -n "$SIGN_PROFILE$SIGN_KEY$SIGN_ALIAS$SIGN_CERT$SIGN_PWD_FILE" ] || [ "$SIGN_PWD_INPUT" = 1 ]; then
        warn "给了签名材料但没有 --sign：签名步骤不会执行（加 --sign 启用）"
    fi
fi

if [ "$DRY" = 1 ]; then
    log "dry-run：只打印计划，不执行任何命令"
fi

# ---- bundle-name validation (same rule as tester-run.sh, security A1) -----------------
# A bundle name reaches `hdc shell aa start -a EntryAbility -b <name>`; hdc joins its argv into
# one device-side shell command line, so a hap's module.json (or --bundle) with shell
# metacharacters would run with hdc-shell privileges. Only the dotted, letter-first
# [A-Za-z0-9_] form is accepted. The first `case` rejects control characters/spaces byte by
# byte (grep -E matches line by line, so a multiline payload would slip past a regex only).
is_safe_bundle_name() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    printf '%s' "$1" | grep -Eq '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'
}

# Never echo a raw bundle name in a log/error: it may carry control characters.
bundle_for_log() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '?' | cut -c1-64
}

# ---- small helpers --------------------------------------------------------------------
# Print a command for a log/plan with only the necessary quoting.
show_cmd() {
    printf '%s' "$1"; shift
    for _sc_a in "$@"; do
        case "$_sc_a" in
            *[!A-Za-z0-9_./:=+@-]*) printf ' "%s"' "$_sc_a" ;;
            *) printf ' %s' "$_sc_a" ;;
        esac
    done
}

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

require_dotnet() {
    command -v "$DOTNET" >/dev/null 2>&1 || die "未找到 dotnet（DOTNET=$DOTNET）；先安装/指向本地 SDK"
}

require_hdc() {
    command -v "$HDC" >/dev/null 2>&1 || die_no_device "未找到 hdc（HDC=$HDC）；连接设备后重试，或先用 --dry-run 看计划"
}

die_no_device() {
    warn "$*"
    exit 3
}

# Refuse device steps without a device, mirroring tester-run.sh: hdc list targets must answer
# and contain --device (when given). --dry-run never needs a device.
require_device() {
    [ "$DRY" = 1 ] && return 0
    require_hdc
    _rd_targets="$("$HDC" list targets 2>&1 || true)"
    _rd_list="$(printf '%s\n' "$_rd_targets" | sed 's/\r$//' | grep -v -e '^[[:space:]]*$' -e '^\[Empty\]$' || true)"
    if [ -z "$_rd_list" ]; then
        die_no_device "hdc list targets 为空（未连接设备）；请连接设备（已开 USB 调试）或 hdc tconn <ip:port>，或先用 --dry-run 看计划"
    fi
    if [ -n "$DEVICE" ]; then
        printf '%s\n' "$_rd_list" | grep -Fxq -e "$DEVICE" \
            || die_no_device "--device $DEVICE 不在 hdc list targets 中（现有: $(printf '%s' "$_rd_list" | tr '\n' ' ')）"
    fi
}

# Newest hap in <dir> matching signed|unsigned|any, printed as an absolute path. Names are read
# line by line (no word splitting), so a path with spaces survives.
pick_hap() {
    _ph_dir="$1"; _ph_want="$2"
    [ -d "$_ph_dir" ] || return 0
    ( cd "$_ph_dir" || exit 1
      ls -1t *.hap 2>/dev/null | while IFS= read -r _ph_f; do
          case "$_ph_want" in
              unsigned)
                  case "$_ph_f" in *-unsigned.hap) printf '%s\n' "$_ph_dir/$_ph_f"; return 0 ;; esac ;;
              signed)
                  case "$_ph_f" in *-unsigned.hap) continue ;; esac
                  printf '%s\n' "$_ph_dir/$_ph_f"; return 0 ;;
              *)  printf '%s\n' "$_ph_dir/$_ph_f"; return 0 ;;
          esac
      done
    ) || true
}

# Read app.bundleName from a hap's module.json (python3 first, unzip fallback). On an unsafe
# name: BUNDLE_UNSAFE=1 and BUNDLE_NAME empty (callers must refuse); BUNDLE_RAW keeps the value
# for the sanitized error message.
read_bundle() {
    _rb_hap="$1"
    BUNDLE_NAME=""
    BUNDLE_RAW=""
    BUNDLE_UNSAFE=0
    if command -v python3 >/dev/null 2>&1; then
        BUNDLE_NAME="$(python3 - "$_rb_hap" <<'PY'
import json, sys, zipfile
try:
    with zipfile.ZipFile(sys.argv[1]) as z:
        d = json.loads(z.read('module.json'))
except Exception as exc:
    sys.stderr.write('module.json 解析失败: %s\n' % exc)
    sys.exit(1)
print(((d.get('app') or {}).get('bundleName') or ''))
PY
        )" || BUNDLE_NAME=""
    elif command -v unzip >/dev/null 2>&1; then
        BUNDLE_NAME="$(unzip -p "$_rb_hap" module.json 2>/dev/null | sed -n 's/.*"bundleName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    fi
    BUNDLE_RAW="$BUNDLE_NAME"
    if [ -n "$BUNDLE_NAME" ] && ! is_safe_bundle_name "$BUNDLE_NAME"; then
        BUNDLE_UNSAFE=1
        BUNDLE_NAME=""
    fi
}

# Resolve the haps the sign/install/start steps operate on:
#   --hap ...            explicit list (validated; single hap required with --sign)
#   else --sign          newest -unsigned.hap in the publish output -> signed later
#   else                 newest signed hap (fallback: any hap) in the publish output
prepare_haps() {
    if [ -n "$INSTALL_LIST" ] && { [ "$SIGN" != 1 ] || [ -n "$SIGNED_HAP" ]; }; then
        return 0
    fi
    if [ -n "$HAPS" ]; then
        _pp_list=""
        _pp_n=0
        while IFS= read -r _pp_h; do
            [ -n "$_pp_h" ] || continue
            [ -f "$_pp_h" ] || die "--hap 不存在: $_pp_h"
            case "$_pp_h" in /*) ;; *) _pp_h="$PWD/$_pp_h" ;; esac
            if [ -n "$_pp_list" ]; then _pp_list="$_pp_list
$_pp_h"; else _pp_list="$_pp_h"; fi
            _pp_n=$((_pp_n + 1))
        done <<EOF
$HAPS
EOF
        [ "$_pp_n" -ge 1 ] || die "--hap 没有可用条目"
        if [ "$SIGN" = 1 ] && [ "$_pp_n" -ne 1 ]; then
            die "--sign 一次只能签一个 hap（--out 只接受单个输入）；当前给了 $_pp_n 个"
        fi
        UNSIGNED_HAP="$_pp_list"
        MAIN_HAP="$(printf '%s\n' "$_pp_list" | head -n1)"
        if [ -z "$SIGNED_HAP" ]; then INSTALL_LIST="$_pp_list"; fi
        return 0
    fi
    if [ "$SIGN" = 1 ] && [ -z "$SIGNED_HAP" ]; then
        UNSIGNED_HAP="$(pick_hap "$OUTDIR" unsigned)"
        if [ -z "$UNSIGNED_HAP" ]; then
            [ "$DRY" = 1 ] && { UNSIGNED_HAP="$OUTDIR/<unsigned hap>"; MAIN_HAP="$UNSIGNED_HAP"; return 0; }
            die "未找到未签名 hap（$OUTDIR/*-unsigned.hap）；先跑 build"
        fi
        MAIN_HAP="$UNSIGNED_HAP"
        return 0
    fi
    if [ -n "$SIGNED_HAP" ]; then
        INSTALL_LIST="$SIGNED_HAP"
        MAIN_HAP="$SIGNED_HAP"
        return 0
    fi
    _pp_pick="$(pick_hap "$OUTDIR" signed)"
    [ -n "$_pp_pick" ] || _pp_pick="$(pick_hap "$OUTDIR" any)"
    if [ -z "$_pp_pick" ]; then
        [ "$DRY" = 1 ] && { INSTALL_LIST="$OUTDIR/<hap>"; MAIN_HAP="$INSTALL_LIST"; return 0; }
        die "输出目录里没有 hap（$OUTDIR）；先跑 build，或用 --hap 指定"
    fi
    INSTALL_LIST="$_pp_pick"
    MAIN_HAP="$_pp_pick"
}

# ---- steps ----------------------------------------------------------------------------
run_build() {
    _rb_cmd="$(show_cmd "$DOTNET" publish "$PROJECT" -f "$TFM" -r "$RID" -c "$CFG")"
    while IFS= read -r _rb_p; do
        [ -n "$_rb_p" ] || continue
        _rb_cmd="$_rb_cmd $_rb_p"
    done <<EOF
$PROPS
EOF
    if [ "$DRY" = 1 ]; then
        log "  [dry-run] build: $_rb_cmd"
        return 0
    fi
    require_dotnet
    log "== build: $_rb_cmd =="
    set -- publish "$PROJECT" -f "$TFM" -r "$RID" -c "$CFG"
    while IFS= read -r _rb_p; do
        [ -n "$_rb_p" ] || continue
        set -- "$@" "$_rb_p"
    done <<EOF
$PROPS
EOF
    "$DOTNET" "$@"
    # A fresh publish invalidates the previous round's signature/pick.
    UNSIGNED_HAP=""
    SIGNED_HAP=""
    INSTALL_LIST=""
    MAIN_HAP=""
    log "   publish 完成 -> $OUTDIR"
}

run_sign() {
    if [ "$SIGN" != 1 ]; then
        log "== sign: 跳过（未给 --sign；使用 publish 出的 hap） =="
        return 0
    fi
    if [ -n "$SIGNED_HAP" ]; then
        INSTALL_LIST="$SIGNED_HAP"
        MAIN_HAP="$SIGNED_HAP"
        log "== sign: 已签名的 hap 仍然有效，跳过（$(basename "$SIGNED_HAP")） =="
        return 0
    fi
    prepare_haps
    _rs_udid="$EXPECT_UDID"
    if [ -z "$_rs_udid" ]; then
        if [ "$DRY" = 1 ]; then
            log "  [dry-run] UDID 将从设备读取（hdc shell bm get -u），或用 --expect-udid 指定"
            _rs_udid="<UDID>"
        else
            require_device
            _rs_udid="$(hdc_cmd shell bm get -u 2>/dev/null | tr -d '\r' | sed -n 's/.*[Uu][Dd][Ii][Dd][^:]*:[[:space:]]*//p' | head -n1)"
            if [ -z "$_rs_udid" ]; then
                _rs_udid="$(hdc_cmd shell bm get -u 2>/dev/null | tr -d '\r' | grep -E -e '^[0-9A-Fa-f]{16,}$' | head -n1)"
            fi
            [ -n "$_rs_udid" ] || die "读不到设备 UDID（hdc shell bm get -u）；用 --expect-udid <UDID> 指定"
        fi
    fi
    case "$_rs_udid" in
        *[!A-Za-z0-9_-]*|'') die "--expect-udid 只接受字母/数字/下划线/连字符: $(bundle_for_log "$_rs_udid")" ;;
    esac
    _rs_udid8="$(printf '%s' "$_rs_udid" | cut -c1-8)"
    _rs_base="$(basename "$UNSIGNED_HAP" .hap)"
    case "$_rs_base" in *-unsigned) _rs_base="${_rs_base%-unsigned}" ;; esac
    _rs_out="$(dirname "$UNSIGNED_HAP")/${_rs_base}-${_rs_udid8}.hap"
    log "== sign: sign-for-device.sh --external（alias $SIGN_ALIAS, UDID ${_rs_udid8}...） =="
    set -- --external --profile "$SIGN_PROFILE" --key "$SIGN_KEY" --key-alias "$SIGN_ALIAS" \
        --expect-udid "$_rs_udid" --unsigned "$UNSIGNED_HAP" --out "$_rs_out"
    [ -z "$SIGN_CERT" ] || set -- "$@" --cert "$SIGN_CERT"
    [ -z "$SIGN_PWD_FILE" ] || set -- "$@" --key-pwd-file "$SIGN_PWD_FILE"
    [ "$SIGN_PWD_INPUT" = 1 ] && set -- "$@" --pwd-input-mode
    if [ "$DRY" = 1 ]; then
        log "  [dry-run] sign: $(show_cmd "sh" "$SIGN_TOOL" "$@")"
        SIGNED_HAP="$_rs_out"
        return 0
    fi
    [ -f "$SIGN_TOOL" ] || die "签名脚本不存在: $SIGN_TOOL"
    sh "$SIGN_TOOL" "$@"
    [ -f "$_rs_out" ] || die "sign-for-device.sh 未产出签名 hap: $_rs_out"
    SIGNED_HAP="$_rs_out"
    INSTALL_LIST="$SIGNED_HAP"
    MAIN_HAP="$SIGNED_HAP"
    log "   已签名 -> $SIGNED_HAP"
}

run_install() {
    if [ "$SIGN" = 1 ] && [ -z "$SIGNED_HAP" ]; then
        run_sign
    fi
    prepare_haps
    [ -n "$INSTALL_LIST" ] || die "没有要安装的 hap"
    log "== install =="
    while IFS= read -r _ri_hap; do
        [ -n "$_ri_hap" ] || continue
        if [ "$DRY" = 1 ]; then
            log "  [dry-run] install: $(hdc_show) install -r \"$_ri_hap\""
            continue
        fi
        require_device
        _ri_log="$TMP/install-$(basename "$_ri_hap").log"
        _ri_rc=0
        hdc_cmd install -r "$_ri_hap" > "$_ri_log" 2>&1 || _ri_rc=$?
        if grep -q -e 'install bundle successfully' "$_ri_log" 2>/dev/null; then
            log "   安装成功: $(basename "$_ri_hap")"
            continue
        fi
        _ri_code="$(sed -n 's/.*code:\([0-9][0-9]*\).*/\1/p' "$_ri_log" 2>/dev/null | head -n1)"
        warn "   安装失败: $(basename "$_ri_hap")（hdc rc=$_ri_rc${_ri_code:+, code:$_ri_code}）"
        case "$_ri_code" in
            9568344)
                warn "     code:9568344 调试 profile 未绑定本设备 UDID -> 用 --sign + --expect-udid 重签后重试" ;;
            9568297)
                warn "     code:9568297 设备 API 低于 minAPIVersion -> 改用对应 API 波段的 hap（-f net11.0-openharmony20.0）" ;;
            *)
                if grep -q -e 'E00C001' -e 'restricted by the organization' "$_ri_log" 2>/dev/null; then
                    warn "     设备策略关闭了 hdc（E00C001）-> 改用文件管理器安装"
                elif grep -qi -e 'sign' "$_ri_log" 2>/dev/null; then
                    warn "     签名校验失败 -> 用 --sign 以设备绑定的 profile 重签后再装"
                else
                    warn "     hdc 原文（$_ri_log）:"
                    sed 's/^/       /' "$_ri_log" | tail -n5 >&2
                fi
                ;;
        esac
        return 1
    done <<EOF
$INSTALL_LIST
EOF
}

run_start() {
    prepare_haps
    _rs_bundle="$BUNDLE"
    _rs_hap="$MAIN_HAP"
    if [ -z "$_rs_bundle" ]; then
        # A dry-run plan may name the hap the build/sign would produce; do not require it to
        # exist yet (it is not published in this mode).
        if [ "$DRY" = 1 ] && { [ -z "$_rs_hap" ] || [ ! -f "$_rs_hap" ]; }; then
            log "  [dry-run] start: $(hdc_show) shell aa start -a EntryAbility -b \"<hap 的 bundleName>\""
            return 0
        fi
        [ -n "$_rs_hap" ] || die "没有可读的 hap；用 --hap 或 --bundle 指定"
        read_bundle "$_rs_hap"
        if [ "$BUNDLE_UNSAFE" = 1 ]; then
            die "拒绝启动：hap 的 module.json bundleName 未通过白名单校验（只允许 [A-Za-z][A-Za-z0-9_]* 的点分段）: '$(bundle_for_log "$BUNDLE_RAW")'"
        fi
        _rs_bundle="$BUNDLE_NAME"
        if [ -z "$_rs_bundle" ]; then
            die "无法从 $(basename "$_rs_hap") 读出 bundleName（缺 python3/unzip？）；用 --bundle <name> 指定"
        fi
    fi
    if ! is_safe_bundle_name "$_rs_bundle"; then
        die "拒绝启动：bundleName 未通过白名单校验（只允许 [A-Za-z][A-Za-z0-9_]* 的点分段）: '$(bundle_for_log "$_rs_bundle")'"
    fi
    if [ "$DRY" = 1 ]; then
        log "  [dry-run] start: $(hdc_show) shell aa start -a EntryAbility -b \"$_rs_bundle\""
        return 0
    fi
    log "== start: $_rs_bundle =="
    require_device
    _rs_log="$TMP/aa-start-$_rs_bundle.log"
    _rs_rc=0
    hdc_cmd shell aa start -a EntryAbility -b "$_rs_bundle" > "$_rs_log" 2>&1 || _rs_rc=$?
    if grep -qi -e 'success' "$_rs_log" 2>/dev/null; then
        log "   aa start OK"
        return 0
    fi
    warn "   aa start 未确认成功: $_rs_bundle（hdc rc=$_rs_rc）"
    sed 's/^/     /' "$_rs_log" >&2 2>/dev/null || true
    return 1
}

run_logs() {
    if [ "$FOLLOW" = 1 ] && [ "$WATCH" = 1 ]; then
        warn "watch 模式下 logs 用有界录制（--log-seconds $LOG_SECS）；忽略 --follow"
        FOLLOW=0
    fi
    if [ "$DRY" = 1 ]; then
        if [ "$FOLLOW" = 1 ]; then
            log "  [dry-run] logs: $(hdc_show) shell hilog | grep -E \"$FILTER_RE\"  # 跟随"
        else
            log "  [dry-run] logs: $(hdc_show) shell hilog | grep -E \"$FILTER_RE\"  # 录 ${LOG_SECS}s"
        fi
        return 0
    fi
    require_device
    if [ "$FOLLOW" = 1 ]; then
        log "== logs: hilog 跟随（Ctrl-C 退出） =="
        hdc_cmd shell hilog 2>&1 | grep -E -- "$FILTER_RE" || true
        return 0
    fi
    log "== logs: hilog 过滤（${LOG_SECS}s） =="
    _rl_raw="$TMP/hilog.txt"
    hdc_cmd shell hilog > "$_rl_raw" 2>&1 &
    _rl_pid=$!
    _rl_i=0
    while kill -0 "$_rl_pid" 2>/dev/null; do
        if [ "$_rl_i" -ge "$LOG_SECS" ]; then break; fi
        sleep 1
        _rl_i=$((_rl_i + 1))
    done
    kill "$_rl_pid" 2>/dev/null || true
    wait "$_rl_pid" 2>/dev/null || true
    grep -E -- "$FILTER_RE" "$_rl_raw" || true
}

run_sequence() {
    case "$COMMAND" in
        build) run_build ;;
        sign)  run_sign ;;
        install) run_install ;;
        start) run_start ;;
        logs)  run_logs ;;
        all)
            run_build
            run_sign
            run_install
            run_start
            run_logs
            ;;
    esac
}

# ---- watch ----------------------------------------------------------------------------
# Timestamp fingerprint without inotify: any source file newer than the stamp file means a
# change. bin/obj/.git/node_modules are pruned so the build's own output cannot retrigger it.
watch_changed() {
    find "$1" \( -name bin -o -name obj -o -name .git -o -name node_modules \) -prune \
        -o -type f -newer "$2" -print 2>/dev/null | head -n1
}

run_watch() {
    _rw_stamp="$TMP/watch.stamp"
    : > "$_rw_stamp"
    if [ "$DRY" = 1 ]; then
        log "  [dry-run] watch: 轮询 $PROJECT（间隔 ${INTERVAL}s，排除 bin/obj），变更后重跑 [$COMMAND]"
        return 0
    fi
    # One round runs in a subshell: a step's die() (a real failure) must not kill the watcher,
    # the next change still retriggers the loop.
    log "watch: 先执行一次 [$COMMAND]，然后轮询 $PROJECT（间隔 ${INTERVAL}s；Ctrl-C 退出）"
    ( run_sequence ) || warn "本轮 [$COMMAND] 有失败；watch 继续"
    while :; do
        _rw_file="$(watch_changed "$PROJECT" "$_rw_stamp")"
        if [ -n "$_rw_file" ]; then
            log "检测到变更: ${_rw_file#"$PROJECT"/}"
            : > "$_rw_stamp"
            ( run_sequence ) || warn "本轮 [$COMMAND] 有失败；watch 继续"
        fi
        sleep "$INTERVAL"
    done
}

# ---- temp dir + main ------------------------------------------------------------------
TMP="$(mktemp -d 2>/dev/null || true)"
if [ -z "$TMP" ]; then
    TMP="${TMPDIR:-/tmp}/devloop.$$"
    mkdir -p "$TMP" || die "无法创建临时目录"
fi
cleanup() {
    trap - 0 1 2 15
    [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup 0
trap 'cleanup; exit 130' 1 2 15

log "devloop $SCRIPT_VERSION: 项目 $PROJECT（$TFM/$RID/$CFG）"
if [ "$DRY" != 1 ]; then
    # Refuse device-touching runs before a multi-minute build when no device is reachable
    # (tester-run.sh does the same for its action flags).
    case "$COMMAND" in
        install|start|logs|all) require_device ;;
        sign) [ "$SIGN" = 1 ] && [ -z "$EXPECT_UDID" ] && require_device ;;
    esac
fi

if [ "$WATCH" = 1 ]; then
    run_watch
    exit 0
fi

run_sequence
