#!/bin/sh
# Tester-facing self-check for the OpenHarmony MAUI device-test kit ("delivery kit").
#
# Run it from inside the extracted kit (the directory that holds SHA256SUMS):
#
#   sh verify-kit.sh                 # current directory must contain SHA256SUMS
#   sh verify-kit.sh <kit-dir>       # or point it at the extracted kit
#
# It (1) verifies every file against SHA256SUMS with sha256sum -c, (2) summarizes the five
# haps by reading module.json inside each one (bundleName, min/target API, requestPermissions),
# (3) prints the install options and the 9568344/self-sign pointer, and (4) lists the log lines
# to send back.
#
# Exit code: 0 = kit OK; 1 = a checksum failed, a hap is missing/unreadable, or 自签说明.md is
# absent; 2 = SHA256SUMS not found (wrong directory).
# The kit's own SHA256SUMS is not in its own list - the outer <kit>.tar.gz.sha256 covers it.
set -e

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

usage() {
    cat <<EOF
usage: $0 [kit-dir]

Verifies SHA256SUMS and summarizes the five haps of an extracted device-test kit.
Without an argument the current directory is used (it must contain SHA256SUMS).
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

KIT="${1:-}"
if [ -z "$KIT" ]; then
    if [ -f SHA256SUMS ]; then
        KIT=.
    elif [ -f "$(dirname "$0")/SHA256SUMS" ]; then
        KIT="$(dirname "$0")"
    else
        warn "当前目录没有 SHA256SUMS；请在解压后的交付包内运行，或把包目录作为参数传入"
        usage >&2
        exit 2
    fi
fi
[ -d "$KIT" ] || { warn "kit dir not found: $KIT"; exit 2; }
KIT="$(cd "$KIT" && pwd)"
[ -f "$KIT/SHA256SUMS" ] || { warn "SHA256SUMS not found in: $KIT"; exit 2; }

TMP="$(mktemp -d 2>/dev/null || true)"
if [ -z "$TMP" ]; then
    TMP="${TMPDIR:-/tmp}/verify-kit.$$"
    mkdir -p "$TMP"
fi
trap 'rm -rf "$TMP"' 0 1 2 15

FAIL=0
cd "$KIT"

log "== 1/4 SHA256SUMS 校验（sha256sum -c）"
ENTRIES="$(wc -l < SHA256SUMS | tr -d ' ')"
if [ "$ENTRIES" -eq 0 ]; then
    warn "SHA256SUMS 是空文件，无法校验"
    FAIL=1
else
    sha256sum -c SHA256SUMS > "$TMP/sums.out" 2> "$TMP/sums.err" && SUMS_RC=0 || SUMS_RC=$?
    while IFS= read -r line; do
        case "$line" in
            *": OK") printf '   ok   %s\n' "${line%": OK"}" ;;
            *)       printf '   FAIL %s\n' "$line" >&2 ;;
        esac
    done < "$TMP/sums.out"
    if [ "$SUMS_RC" -eq 0 ]; then
        log "   $ENTRIES 项全部通过（sha256sum -c OK）"
    else
        FAIL=1
        if [ -s "$TMP/sums.err" ]; then
            sed 's/^/   /' "$TMP/sums.err" >&2
        fi
        warn "SHA256SUMS 校验失败：以上 FAIL 项说明文件被改动或传输损坏，请重新下载并解压交付包"
    fi
fi

# The five haps must be present and covered by SHA256SUMS (a truncated sums file would
# otherwise still pass for whatever entries remain).
for h in \
    hello-maui-app.hap \
    hello-maui-app-permissions.hap \
    hello-maui-app-api20.hap \
    hello-maui-app-api20-permissions.hap \
    hello-maui-app-unsigned.hap
do
    grep -Fq "  $h" SHA256SUMS || { warn "SHA256SUMS 未收录 $h"; FAIL=1; }
done
[ -f "自签说明.md" ] || { warn "缺少 自签说明.md（9568344 自签流程指向它）"; FAIL=1; }

log "== 2/4 五个 hap 一览（读 module.json）"
if command -v python3 >/dev/null 2>&1; then
    python3 - "$KIT" <<'PY' || FAIL=1
import json, os, sys, zipfile

kit = sys.argv[1]
haps = [
    ("hello-maui-app.hap",
     "默认包：API 26 波段，无额外权限（UI/交互/手势/IME/通知/安全区/WebView/无障碍/Hybrid）"),
    ("hello-maui-app-permissions.hap",
     "带权限变体：蓝牙/打印/联系人/日历（验收说明 §4b 的 N1-N4）"),
    ("hello-maui-app-api20.hap",
     "API 20 波段（min=target=60000020，Release）：给 API 20 设备"),
    ("hello-maui-app-api20-permissions.hap",
     "API 20 波段 + 蓝牙/打印/联系人/日历权限"),
    ("hello-maui-app-unsigned.hap",
     "未签名（与默认包同一负载）：按 自签说明.md 用你自己的自动签名安装"),
]
fail = 0
for name, purpose in haps:
    print("  %s  %s" % (name, purpose))
    path = os.path.join(kit, name)
    if not os.path.isfile(path):
        print("      MISS  文件不在交付包内")
        fail = 1
        continue
    try:
        with zipfile.ZipFile(path) as z:
            data = json.loads(z.read("module.json"))
    except Exception as exc:
        print("      BAD   无法读取 module.json (%s)" % exc)
        fail = 1
        continue
    app = data.get("app") or {}
    mod = data.get("module") or {}
    perms = [p.get("name", "?") for p in (mod.get("requestPermissions") or [])]
    print("      bundle=%s  versionName=%s" % (app.get("bundleName", "?"), app.get("versionName", "?")))
    print("      API    min=%s target=%s (%s)" % (app.get("minAPIVersion", "?"),
                                                  app.get("targetAPIVersion", "?"),
                                                  app.get("apiReleaseType", "?")))
    if perms:
        short = ", ".join(p.rsplit(".", 1)[-1] for p in perms)
        print("      权限   requestPermissions=%d [%s]" % (len(perms), short))
    else:
        print("      权限   requestPermissions=0")
sys.exit(1 if fail else 0)
PY
else
    warn "python3 不可用，跳过 hap 摘要（文件完整性已由 SHA256SUMS 覆盖）"
fi

log "== 3/4 安装方式"
log "   文件管理器：把 hap 拷到设备后在文件管理器中打开 → 按提示安装（需开发者模式/允许调试与外部来源安装）"
log "   hdc：hdc list targets && hdc install hello-maui-app.hap"
log "        启动：hdc shell aa start -a EntryAbility -b com.example.hello-maui-app"
log "   报 9568344 install parse profile prop check error：调试 profile 只绑了示例设备 UDID"
log "        二选一：① 按 自签说明.md 用你自己的 DevEco 自动签名；② 回传 UDID（hdc shell bm get -u）由签名方重签"
log "   设备策略报 E00C001 Operation restricted by the organization → 该设备关闭了 hdc，改用文件管理器安装"
log "   API 20 波段设备请装 hello-maui-app-api20*.hap；未签名 hap 自签完成后再装"

log "== 4/4 回传的日志行"
log "   [maui] openharmony build <ver> abi=<arch> provider=<n>    启动早期；provider=0 属预期"
log "   [maui] accessibility provider status=<n>                 1=已附着（理想）；0=启动初值（预期）"
log "   有 hdc：hdc hilog > log.txt（全程录制；失败项标注时间点）"
log "   无 hdc：截图应用日志区（或应用内 A11Y 自检弹窗）"
log "   关键字与 status 对照见 验收说明.md §5b；回传模板见 §6（一页上手：快速开始.md §6）"

if [ "$FAIL" -eq 0 ]; then
    log "KIT OK — 交付包完整，按 快速开始.md 开始测试"
    exit 0
else
    warn "KIT CHECK FAILED — 请先处理上面的 FAIL/WARN 项"
    exit 1
fi
