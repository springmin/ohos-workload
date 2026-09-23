#!/bin/sh
# Tester-facing self-check for the OpenHarmony MAUI device-test kit ("delivery kit").
# Run it from inside the extracted kit (the directory that holds SHA256SUMS):
#   sh verify-kit.sh                 # current directory must contain SHA256SUMS
#   sh verify-kit.sh <kit-dir>       # or point it at the extracted kit
# Steps: (1) verify every file against SHA256SUMS (sha256sum -c); (2) summarize the five haps
# from their module.json (bundleName, min/target API, requestPermissions) and fail unless all
# carry the expected bundle name (KIT_BUNDLE_NAME, default com.example.hellomauiapp); (3) warn
# (one line) that the four default haps are self-signed and rejected by a real device
# (9568257/9568344 -> re-sign hello-maui-app-unsigned.hap or use a pre-signed kit), plus the
# install options and the self-sign pointer; (4) list the log lines to send back.
# SHA256SUMS lives inside the archive it covers, so it proves internal consistency only:
#   1. check the transfer checksum of the .tar.gz: `sha256sum -c <kit>.tar.gz.sha256`, or let
#      this script check the tarball (--anchor / --anchor-file / KIT_ANCHOR);
#   2. extract the kit;
#   3. bind the exact tree with the published digest: --expect-tree-digest <sha256> (or
#      KIT_TREE_DIGEST); --tree-digest prints the digest for an out-of-band comparison.
# Tree digest: sha256 over the sorted kit contents - one "<file sha256>  <relative path>" line
# per regular file (SHA256SUMS and this script included), LC_ALL=C sorted by relative path and
# hashed again. Only relative path bytes and file contents are inputs (no modes/mtimes/owners/
# dir entries), so a mode-less extraction still matches. Transport leftovers are not content:
# a root-level archive (*.tar.gz/*.tgz/*.tar/*.tar.bz2/*.tar.xz/*.zip/*.7z) and its
# (*.sha256/*.sha1/*.md5/*.sha512) sidecar are skipped (named on stderr), so the common
# "extract in place" layout yields the clean-extraction digest; any other added file (e.g.
# .DS_Store) does change it, by design.
#
# Reuse (P16): step 1's `sha256sum -c` reads every file covered by SHA256SUMS, so the digest
# reuses those just-verified hashes instead of reading the same bytes a second time in one
# run. The reuse only covers entries whose check reported OK and whose inode/size/mtime pair
# was identical before and after the check; everything else (SHA256SUMS itself, docs outside
# the list, moved files) is hashed here from disk. Verification strength is unchanged: no
# hash is trusted unless it was computed against exactly these bytes in this run.
# --anchor does NOT bind the extracted tree (extraction happens outside this script). Both
# checks fail closed: missing/mismatching tarball, non-hex anchor, absent .tar.gz.sha256
# sidecar, non-hex or mismatching tree digest all fail.
# Exit: 0 = kit OK; 1 = checksum/anchor/tree-digest failure, missing/unreadable hap, unexpected
# bundleName, or absent 自签说明.md/签名说明.txt; 2 = SHA256SUMS not found (wrong directory) or
# bad usage. The kit's SHA256SUMS is not in its own list - the outer <kit>.tar.gz.sha256 covers
# it, and the tree digest covers SHA256SUMS itself.
set -e

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

# Deterministic digest of the extracted kit contents: every regular file under the kit root
# (SHA256SUMS and this script included) contributes one "<file sha256>  <relative path>"
# line; only the relative path bytes and the file contents are inputs (LC_ALL=C byte sort,
# no modes/mtimes/owners/directory entries). Root-level transport leftovers of this kit
# (the outer .tar.gz/.tgz/.tar/.zip archive and its checksum sidecar) are skipped and named
# on stderr, so extracting the tarball in place still matches a clean extraction. Any other
# added file (.DS_Store/Thumbs.db/...) changes the digest. Publisher and tester run this
# same code, so identical path+content bytes produce the identical value anywhere.
# Tree digest lines: reuse the hashes step 1 verified for these exact bytes (the map holds
# the entries of a successful, snapshot-stable SHA256SUMS check) and hash only what the map
# does not cover (SHA256SUMS itself, docs outside the list, files that moved). One awk holds
# the map and the file list; sha256sum is spawned only for the leftovers, because process
# spawns are the expensive part on a device (~40 ms each).
tree_digest() {
    (
        cd "$KIT" || exit 1
        LC_ALL=C
        export LC_ALL
        find . -type f -print | sed 's|^\./||' | LC_ALL=C sort | awk -v map="$TMP/verified.map" '
            BEGIN {
                while ((getline line < map) > 0) {
                    split(line, kv, " ")
                    if (kv[1] != "") verified[kv[1]] = kv[2]
                }
                close(map)
            }
            {
                rel = $0
                if (rel !~ /\// && rel ~ /\.(tar\.gz|tgz|tar|tar\.bz2|tar\.xz|zip|7z|sha256|sha1|md5|sha512)$/) {
                    printf "[tree-digest] 忽略包外传输文件（不计入 tree digest）: %s\n", rel > "/dev/stderr"
                    next
                }
                if (rel in verified) {
                    printf "%s  %s\n", verified[rel], rel
                    next
                }
                safe = rel
                gsub(/\\/, "\\\\", safe)
                gsub(/"/, "\\\"", safe)
                gsub(/\$/, "\\$", safe)
                gsub(/`/, "\\`", safe)
                cmd = "sha256sum -- \"" safe "\""
                if ((cmd | getline out) > 0) {
                    split(out, parts, " ")
                    printf "%s  %s\n", parts[1], rel
                }
                close(cmd)
            }'
    ) | sha256sum | cut -d' ' -f1
}

# One "<name> <inode> <size> <mtime>" line per SHA256SUMS entry that exists, from a single
# awk + single stat pass (a per-file loop would spawn hundreds of processes on a device).
# The caller runs it from inside the kit directory.
sums_stat_snapshot() {
    [ -f SHA256SUMS ] || return 0
    _names="$(awk '{ n=substr($0,67); sub(/^\*/, "", n); sub(/^\.\//, "", n); if (n!="") print n }' SHA256SUMS)"
    [ -n "$_names" ] || return 0
    if command -v xargs >/dev/null 2>&1; then
        printf '%s\n' "$_names" | xargs -r stat -c '%n %i %s %Y' 2>/dev/null || true
    else
        printf '%s\n' "$_names" | while IFS= read -r _name; do
            [ -f "$_name" ] || continue
            printf '%s %s\n' "$_name" "$(stat -c '%i %s %Y' -- "$_name" 2>/dev/null)"
        done
    fi
}

usage() {
    cat <<EOF
usage: $0 [--anchor <sha256-of-tar.gz>] [--anchor-file <path-to.tar.gz>]
          [--tree-digest] [--expect-tree-digest <sha256>] [kit-dir]

Verifies SHA256SUMS and summarizes the five haps of an extracted device-test kit.
Without an argument the current directory is used (it must contain SHA256SUMS).

  --anchor <hex>        also check the .tar.gz on disk against this sha256 (fail closed when
                        it cannot be checked); it does NOT bind the extracted tree
  --anchor-file <path>  the outer tarball used by --anchor (default: <kit-dir>.tar.gz);
                        without --anchor, the adjacent <path>.sha256 is read
  --tree-digest         print the sha256 of the extracted kit contents (sorted relative
                        paths + per-file sha256) to compare with the published value; a
                        root-level transport archive/sidecar (.tar.gz/.tgz/.tar/.zip/
                        .sha256/...) is ignored, other added files are not
  --expect-tree-digest <hex>
                        fail unless the extracted tree matches this digest (the value comes
                        with the delivery, e.g. the release notes)
  env: KIT_ANCHOR, KIT_ANCHOR_FILE, KIT_TREE_DIGEST, KIT_BUNDLE_NAME
EOF
}

KIT=""
ANCHOR="${KIT_ANCHOR:-}"
ANCHOR_FILE="${KIT_ANCHOR_FILE:-}"
TREE_MODE=0
TREE_EXPECT="${KIT_TREE_DIGEST:-}"
# Expected bundle name of the five haps. Pinned to the demo default (ohos-workload bbfa03c:
# hyphens are illegal in app.bundleName; kits built before it carry the hyphenated demo name
# and must be repacked). Override for a kit built with -p:OpenHarmonyBundleName=<other>.
BUNDLE_EXPECT="${KIT_BUNDLE_NAME:-com.example.hellomauiapp}"
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --anchor)
            shift
            [ $# -gt 0 ] || { warn "--anchor 需要一个 sha256"; usage >&2; exit 2; }
            ANCHOR="$1"
            ;;
        --anchor-file)
            shift
            [ $# -gt 0 ] || { warn "--anchor-file 需要一个 tar.gz 路径"; usage >&2; exit 2; }
            ANCHOR_FILE="$1"
            ;;
        --tree-digest) TREE_MODE=1 ;;
        --expect-tree-digest)
            shift
            [ $# -gt 0 ] || { warn "--expect-tree-digest 需要一个 sha256"; usage >&2; exit 2; }
            TREE_EXPECT="$1"
            ;;
        -*) warn "unknown argument: $1"; usage >&2; exit 2 ;;
        *)
            [ -z "$KIT" ] || { warn "unexpected extra argument: $1"; usage >&2; exit 2; }
            KIT="$1"
            ;;
    esac
    shift
done

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

FAIL=0

# Optional outer anchor: KIT_ANCHOR/--anchor is the sha256 of the .tar.gz the kit was
# extracted from. It binds the extracted tree to that archive; without it, SHA256SUMS only
# proves internal consistency. Requested-but-uncheckable always fails.
if [ -n "$ANCHOR" ] || [ -n "$ANCHOR_FILE" ]; then
    log "== 0/4 外层锚点校验（tar.gz sha256）"
    if [ -z "$ANCHOR_FILE" ]; then
        for _cand in "$KIT.tar.gz" "$(dirname "$KIT")/$(basename "$KIT").tar.gz"; do
            if [ -f "$_cand" ]; then ANCHOR_FILE="$_cand"; break; fi
        done
    fi
    if [ -z "$ANCHOR_FILE" ] || [ ! -f "$ANCHOR_FILE" ]; then
        warn "找不到外层 tar.gz（候选: $KIT.tar.gz）；用 --anchor-file <path> 指定，或先校验外层再运行"
        FAIL=1
    else
        if [ -z "$ANCHOR" ]; then
            # no digest given: read the published <tarball>.sha256 sidecar
            if [ -f "$ANCHOR_FILE.sha256" ]; then
                ANCHOR="$(cut -d' ' -f1 < "$ANCHOR_FILE.sha256")"
                [ -n "$ANCHOR" ] || { warn "$ANCHOR_FILE.sha256 里没有可用的 sha256"; FAIL=1; }
            else
                warn "未给出 --anchor <sha256>，且 $ANCHOR_FILE.sha256 不存在"
                FAIL=1
            fi
        fi
        case "$ANCHOR" in
            *[!0-9a-fA-F]*) warn "anchor 不是十六进制 sha256: $ANCHOR"; FAIL=1 ;;
            "")             warn "anchor 为空"; FAIL=1 ;;
            *) [ "${#ANCHOR}" -eq 64 ] || { warn "anchor 长度不是 64 个字符: $ANCHOR"; FAIL=1; } ;;
        esac
        if [ -n "$ANCHOR" ] && [ "${#ANCHOR}" -eq 64 ]; then
            case "$ANCHOR" in *[!0-9a-fA-F]*) ;; *)
                _got="$(sha256sum "$ANCHOR_FILE" | cut -d' ' -f1)"
                if [ "$_got" = "$ANCHOR" ]; then
                    log "   anchor OK $ANCHOR_FILE sha256=$_got"
                else
                    warn "anchor 不匹配 — 磁盘上的 .tar.gz 与发布锚点不一致（下载/传输被篡改）"
                    warn "  本项只校验 tar.gz 文件本身，不校验解压后的目录"
                    warn "  expected $ANCHOR"
                    warn "  actual   $_got"
                    FAIL=1
                fi
            ;; esac
        fi
    fi
else
    log "== 0/4 外层锚点：未请求（建议先 sha256sum -c <kit>.tar.gz.sha256 或 --anchor <sha256>）"
fi

# The tree digest is computed after step 1 so it can reuse the hashes that check just
# verified for these exact bytes (see the note at the top); both checks still run, and a
# requested --expect-tree-digest still fails closed.

TMP="$(mktemp -d 2>/dev/null || true)"
if [ -z "$TMP" ]; then
    TMP="${TMPDIR:-/tmp}/verify-kit.$$"
    mkdir -p "$TMP"
fi
trap 'rm -rf "$TMP"' 0 1 2 15

cd "$KIT"

log "== 1/4 SHA256SUMS 校验（sha256sum -c）"
ENTRIES="$(wc -l < SHA256SUMS | tr -d ' ')"
: > "$TMP/verified.map"
if [ "$ENTRIES" -eq 0 ]; then
    warn "SHA256SUMS 是空文件，无法校验"
    FAIL=1
else
    # First verification is always a real read of every covered file. The inode/size/mtime
    # snapshot around it proves the bytes did not move while being checked, which is what
    # makes the tree digest's reuse of these hashes sound; a moved file drops out of the map
    # and is hashed from disk below.
    SUMS_SNAP_BEFORE="$(sums_stat_snapshot)"
    sha256sum -c SHA256SUMS > "$TMP/sums.out" 2> "$TMP/sums.err" && SUMS_RC=0 || SUMS_RC=$?
    SUMS_SNAP_AFTER="$(sums_stat_snapshot)"
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
    # Fail closed: an empty snapshot (stat/xargs unavailable) never arms the reuse.
    if [ "$SUMS_RC" -eq 0 ] && [ -n "$SUMS_SNAP_BEFORE" ] && [ "$SUMS_SNAP_BEFORE" = "$SUMS_SNAP_AFTER" ]; then
        # A zero exit from sha256sum -c means every entry matched, and the snapshot proves the
        # files did not move across the check, so the recorded hashes describe these bytes.
        awk '{ n=substr($0,67); sub(/^\*/, "", n); sub(/^\.\//, "", n); if (n=="") next; printf "%s %s\n", n, substr($0,1,64) }' \
            SHA256SUMS > "$TMP/verified.map"
    fi
fi

# Optional tree digest: unlike --anchor (which checks the .tar.gz file), this binds the
# extracted kit directory itself. --tree-digest prints it; --expect-tree-digest (or
# KIT_TREE_DIGEST) compares and fails closed. The hashes verified by step 1 for these exact
# bytes are reused instead of being read again (see the header note); SHA256SUMS itself,
# files outside the list and any file whose metadata moved are hashed from disk here.
TREE_DIGEST=""
if [ "$TREE_MODE" = 1 ] || [ -n "$TREE_EXPECT" ]; then
    log "== 1b/4 内容树摘要（tree digest：排序相对路径 + 每文件 sha256）"
    if [ -s "$TMP/verified.map" ]; then
        log "   复用本次已校验的 SHA256SUMS 哈希（同一次运行、失效校验通过，未逐文件重读）"
    else
        warn "   无可复用的本次校验结果，tree digest 逐文件重算（不降低校验强度）"
    fi
    TREE_DIGEST="$(tree_digest)"
    log "   tree sha256=$TREE_DIGEST"
    if [ -n "$TREE_EXPECT" ]; then
        case "$TREE_EXPECT" in
            *[!0-9a-fA-F]*) warn "tree digest 不是十六进制 sha256: $TREE_EXPECT"; FAIL=1 ;;
            "")             warn "tree digest 为空"; FAIL=1 ;;
            *) [ "${#TREE_EXPECT}" -eq 64 ] || { warn "tree digest 长度不是 64 个字符: $TREE_EXPECT"; FAIL=1; } ;;
        esac
        if [ "${#TREE_EXPECT}" -eq 64 ]; then
            case "$TREE_EXPECT" in *[!0-9a-fA-F]*) ;; *)
                if [ "$TREE_DIGEST" = "$TREE_EXPECT" ]; then
                    log "   tree digest OK（解压内容与发布方绑定一致）"
                else
                    warn "tree digest 不匹配 — 解压目录被增删改（或不是发布方绑定的那份 kit）"
                    warn "  expected $TREE_EXPECT"
                    warn "  actual   $TREE_DIGEST"
                    FAIL=1
                fi
            ;; esac
        fi
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
[ -f "签名说明.txt" ] || { warn "缺少 签名说明.txt（自签名 hap 的预期拒绝与重签路径说明）"; FAIL=1; }

log "== 2/4 五个 hap 一览（读 module.json）"
if command -v python3 >/dev/null 2>&1; then
    python3 - "$KIT" "$BUNDLE_EXPECT" "$TMP/kit-bundle" <<'PY' || FAIL=1
import json, os, sys, zipfile

kit = sys.argv[1]
expected = sys.argv[2]
bundle_file = sys.argv[3]
haps = [
    ("hello-maui-app.hap",
     "默认包：API 26 波段，无额外权限（UI/交互/手势/IME/通知/安全区/WebView/无障碍/Hybrid）；"
     "自签名，设备会拒绝，需要重签"),
    ("hello-maui-app-permissions.hap",
     "带权限变体：蓝牙/打印/联系人/日历（验收说明 §4b 的 N1-N4）；自签名，设备会拒绝，需要重签"),
    ("hello-maui-app-api20.hap",
     "API 20 波段（min=target=60000020，Release）：给 API 20 设备；自签名，设备会拒绝，需要重签"),
    ("hello-maui-app-api20-permissions.hap",
     "API 20 波段 + 蓝牙/打印/联系人/日历权限；自签名，设备会拒绝，需要重签"),
    ("hello-maui-app-unsigned.hap",
     "未签名（与默认包同一负载）：本包唯一可重签安装的变体，按 自签说明.md 用你自己的自动签名安装"),
]
fail = 0
bundles = []
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
    bundle = app.get("bundleName", "?")
    if bundle != "?":
        bundles.append(bundle)
    perms = [p.get("name", "?") for p in (mod.get("requestPermissions") or [])]
    print("      bundle=%s  versionName=%s" % (bundle, app.get("versionName", "?")))
    print("      API    min=%s target=%s (%s)" % (app.get("minAPIVersion", "?"),
                                                  app.get("targetAPIVersion", "?"),
                                                  app.get("apiReleaseType", "?")))
    if perms:
        short = ", ".join(p.rsplit(".", 1)[-1] for p in perms)
        print("      权限   requestPermissions=%d [%s]" % (len(perms), short))
    else:
        print("      权限   requestPermissions=0")

with open(bundle_file, "w") as f:
    f.write(bundles[0] if bundles else "")

if sorted(set(bundles)) != [expected]:
    print("      FAIL  bundleName 期望 %s，实际 %s" % (expected, ", ".join(sorted(set(bundles))) or "无"))
    print("            旧 bundle 的 hap（bundle 名含连字符）需按 ohos-workload bbfa03c 重新打包")
    print("            后再交付；确属其他 bundle 时用 KIT_BUNDLE_NAME=<name> 覆盖期望值")
    fail = 1
else:
    print("      bundle 校验 OK：五个 hap 的 bundleName 一致（%s）" % expected)
sys.exit(1 if fail else 0)
PY
    KIT_BUNDLE="$(cat "$TMP/kit-bundle" 2>/dev/null || true)"
    [ -n "$KIT_BUNDLE" ] || KIT_BUNDLE="$BUNDLE_EXPECT"
else
    warn "python3 不可用，跳过 hap 摘要与 bundleName 校验（文件完整性已由 SHA256SUMS 覆盖）"
    KIT_BUNDLE="$BUNDLE_EXPECT"
fi

log "== 3/4 安装方式"
if [ -f 目标设备.txt ]; then
    log "   ★ 本包为预签包：全部 hap 已按 目标设备.txt 的 UDID 预签，可直接安装（其他设备仍被拒 9568344）"
else
    log "   ★ 警告：包内 4 个默认 hap 为【自签名】（仅绑定我方示例 UDID），真机安装会报 9568257/9568344 被拒；必须重签（自签说明.md，签 hello-maui-app-unsigned.hap）或改用发布方预签包"
fi
log "   文件管理器：把 hap 拷到设备后在文件管理器中打开 → 按提示安装（需开发者模式/允许调试与外部来源安装）"
log "   hdc：hdc list targets && hdc install <重签后的 hap>"
log "        启动：hdc shell aa start -a EntryAbility -b $KIT_BUNDLE（bundle 以上方 bundle= 行为准）"
log "   报 9568257 fail to verify pkcs7 file：自签名包的预期拒绝（见 签名说明.txt）—— 先重签再装"
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
