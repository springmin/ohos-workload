#!/bin/sh
# Builds and assembles the OpenHarmony MAUI device-test kit (the "delivery kit"):
#
#   4 self-signed haps  hello-maui-app.hap                (26.0 band, no extra permissions)
#                       hello-maui-app-permissions.hap    (26.0 band, +5 permissions)
#                       hello-maui-app-api20.hap          (20.0 band, no extra permissions)
#                       hello-maui-app-api20-permissions.hap
#                       -> signed with OUR debug material only (profile bound to the example
#                          UDID): a real device rejects them (9568257 / 9568344). The names are
#                          kept because tester-run.sh and the shipped docs address them, so the
#                          kit-root 签名说明.txt is the unmistakable label ("self-signed:
#                          re-sign or use a pre-signed kit") - do not silently rename again.
#   1 unsigned hap      hello-maui-app-unsigned.hap       (26.0 band, default payload; the
#                                                         re-sign-then-install variant)
#   9 docs            验收说明.md 快速开始.md 真机操作手册.md 文档索引.md 签名与UDID指南.md
#                     自签说明.md 最终状态.md README-交付说明.md 签名说明.txt
#   0/1 meta          目标设备.txt (only with --sign-external: UDID + profile sha256 + method)
#   1 verifier        verify-kit.sh                    (tester self-check: sha256sum -c + hap
#                                                      summary + --tree-digest/--expect-tree-digest)
#   SHA256SUMS        checksum of every hap + doc + verify-kit.sh in the kit
#   <out>.tar.gz      the kit root, packed flat (tar -C <kit> .)
#
# The haps are (re)published from test/hello-maui-app for both API bands with and without
# OpenHarmonyExtraPermissions, using <dist-dir>/ets/modules.abc as the ArkTS shell; each
# publish lands in test/hello-maui-app/bin/Release/<tfm>/openharmony-arm64/ and is copied
# into the kit right away. The 20.0 publishes use the TargetFrameworks/TargetFramework
# override documented in the acceptance doc (test/hello-maui-app multi-targets).
# Signing embeds a timestamp, so a rebuilt kit has fresh hap hashes - SHA256SUMS is always
# regenerated, never carried over.
#
# Usage: scripts/make-device-test-kit.sh [--kit-dir <dir>] [--dist-dir <dir>]
#          [--out <tar.gz>] [--skip-tar] [--publish]
#          [--sign-external <profile> <key> <alias> <expect-udid>]
#
#   --kit-dir <dir>   kit directory (default $DEVICE_TEST_KIT_DIR, else
#                     /data/storage/el2/base/tmp/opencode/device-test-kit)
#   --dist-dir <dir>  repo dist dir holding ets/modules.abc (default <repo>/dist)
#   --out <tar.gz>    tarball (default <kit-dir>.tar.gz)
#   --skip-tar        assemble the kit directory only
#   --publish         publish the tarball via scripts/publish-workload-release.sh
#   --sign-external   pre-sign the assembled haps (including the unsigned variant) with an
#                     external debug profile/key for one device UDID, via
#                     scripts/sign-for-device.sh --external: <profile> is the tester's p7b,
#                     <key> their p12, <alias> the key alias and <expect-udid> the target
#                     device (the p7b must list it or the build fails before signing). The
#                     matching app cert chain (*.cer) must sit next to the p7b or be given
#                     through OHOS_EXT_CERT; the password is asked on the terminal, or
#                     taken from OHOS_KEY_PWD_FILE / piped on stdin. The kit then carries
#                     目标设备.txt (UDID + profile sha256 + method, no secrets).
#
# Env: DOTNET (dotnet host, default: dotnet), RUNTIME_OHOS_PLANS (runtime-ohos docs/plans,
#      default: the sibling checkout's docs/plans), OHOS_EXT_CERT, OHOS_KEY_PWD_FILE
#      (--sign-external only).
#
# The kit directory is rebuilt from scratch in a staging dir and swapped in, so stale
# files cannot leak into SHA256SUMS. scripts/verify-kit.sh is always copied in from the
# repo (a tester can run `sh verify-kit.sh` inside the extracted kit; it is covered by
# SHA256SUMS like every other file). The two kit-only docs (自签说明.md, README-交付说明.md)
# come from the repo source in docs/plans (2026-09-21-ohos-tester-selfsign.md,
# 2026-09-21-ohos-delivery-kit-readme.md); only when that checkout is absent are the kit
# directory copies of a previous run used, so updated repo docs are never shadowed by
# stale kit copies. 签名说明.txt (the self-signed status page: 9568257/9568344 expected,
# re-sign the unsigned variant) is generated here from the heredoc below, so it always
# matches the kit's actual hap names. The operator-facing docs come from docs/plans as well:
# 2026-09-21-ohos-device-run-playbook.md ships as 真机操作手册.md and
# 2026-09-21-ohos-final-status.md ships as 最终状态.md; the SHA256SUMS glob below (*.md)
# picks every shipped doc up, so verify-kit.sh needs no change.
#
# --publish passes the digests of the artifacts just built (DEVICE_TEST_KIT_SHA256 plus
# the bundle's) and --allow-clobber-mismatch, because a rebuilt kit intentionally replaces
# the previously delivered assets; publish-workload-release.sh still verifies each local
# file against the supplied digest and compares it with the published asset digest.
#
# The kit contents tree digest (verify-kit.sh --tree-digest: sorted relative paths + per-file
# sha256 of the assembled kit) is printed here and passed to --publish as
# --kit-tree-digest, so the kit release notes can carry the value a tester binds with
# `sh verify-kit.sh --expect-tree-digest <hex>`. The tarball checksum alone binds only the
# .tar.gz file, not the extracted directory.
set -e

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

W="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$W/test/hello-maui-app"
DOTNET="${DOTNET:-dotnet}"
DEFAULT_KIT_DIR=/data/storage/el2/base/tmp/opencode/device-test-kit
KIT_DIR="${DEVICE_TEST_KIT_DIR:-$DEFAULT_KIT_DIR}"
DIST_DIR="$W/dist"
RUNTIME_PLANS="${RUNTIME_OHOS_PLANS:-$(dirname "$W")/runtime-ohos/docs/plans}"
VERIFY_KIT_SRC="$W/scripts/verify-kit.sh"
OUT=""
SKIP_TAR=0
PUBLISH=0
SIGN_EXTERNAL=0
EXT_PROFILE=""
EXT_KEY=""
EXT_ALIAS=""
EXT_UDID=""

# Delivery permissions for the two "permissions" variants (acceptance doc 1b).
PERMS="ohos.permission.ACCESS_BLUETOOTH;ohos.permission.PRINT;ohos.permission.READ_CONTACTS;ohos.permission.READ_CALENDAR;ohos.permission.WRITE_CALENDAR"

usage() {
    cat <<EOF
usage: $0 [--kit-dir <dir>] [--dist-dir <dir>] [--out <tar.gz>] [--skip-tar] [--publish]
          [--sign-external <profile> <key> <alias> <expect-udid>]

Builds the 4 self-signed + 1 unsigned demo haps, copies the acceptance/signing/operator docs,
the self-signed status page (签名说明.txt) and the tester self-check script, writes SHA256SUMS
and packs the kit tarball.

The 4 default haps are self-signed with our own debug material, so a real device rejects them
(9568257 / 9568344): only the re-signed hello-maui-app-unsigned.hap (or a --sign-external kit)
is installable. 签名说明.txt states this in the kit root.

--sign-external pre-signs every hap (including the unsigned variant) for one device UDID
with the tester's own debug profile/key; the kit then also carries 目标设备.txt.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --kit-dir)  shift; KIT_DIR="$1" ;;
        --dist-dir) shift; DIST_DIR="$1" ;;
        --out)      shift; OUT="$1" ;;
        --sign-external)
            [ $# -ge 5 ] || { warn "--sign-external needs <profile> <key> <alias> <expect-udid>"; usage >&2; exit 2; }
            EXT_PROFILE="$2"; EXT_KEY="$3"; EXT_ALIAS="$4"; EXT_UDID="$5"
            SIGN_EXTERNAL=1
            shift 4 ;;
        --skip-tar) SKIP_TAR=1 ;;
        --publish)  PUBLISH=1 ;;
        -h|--help)  usage; exit 0 ;;
        *) warn "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
    shift
done

case "$KIT_DIR" in
    ""|"/"|"."|"..") warn "invalid kit dir: '$KIT_DIR'"; exit 2 ;;
esac
[ -n "$OUT" ] || OUT="$(dirname "$KIT_DIR")/$(basename "$KIT_DIR").tar.gz"
if [ "$SKIP_TAR" = 1 ] && [ "$PUBLISH" = 1 ]; then
    warn "--publish needs a tarball (drop --skip-tar)"; exit 2
fi

command -v "$DOTNET" >/dev/null 2>&1 || { warn "dotnet not found: $DOTNET (set DOTNET=)"; exit 1; }
[ -d "$PROJ" ] || { warn "demo project not found: $PROJ"; exit 1; }
[ -f "$DIST_DIR/ets/modules.abc" ] || {
    warn "ArkTS shell not found: $DIST_DIR/ets/modules.abc (run scripts/build-arkts-shell.sh or set --dist-dir)"
    exit 1
}
[ -f "$VERIFY_KIT_SRC" ] || {
    warn "kit verifier not found: $VERIFY_KIT_SRC (expected in a full checkout)"
    exit 1
}

if [ "$SIGN_EXTERNAL" = 1 ]; then
    [ -f "$W/scripts/sign-for-device.sh" ] || { warn "sign-for-device.sh not found under $W/scripts"; exit 1; }
    [ -f "$EXT_PROFILE" ] || { warn "--sign-external profile not found: $EXT_PROFILE"; exit 1; }
    [ -f "$EXT_KEY" ] || { warn "--sign-external key not found: $EXT_KEY"; exit 1; }
    [ -n "$EXT_ALIAS" ] || { warn "--sign-external alias is empty"; exit 1; }
    [ -n "$EXT_UDID" ] || { warn "--sign-external expect-udid is empty"; exit 1; }
    [ -z "${OHOS_EXT_CERT:-}" ] || [ -f "$OHOS_EXT_CERT" ] || { warn "OHOS_EXT_CERT not found: $OHOS_EXT_CERT"; exit 1; }
    [ -z "${OHOS_KEY_PWD_FILE:-}" ] || [ -f "$OHOS_KEY_PWD_FILE" ] || { warn "OHOS_KEY_PWD_FILE not found: $OHOS_KEY_PWD_FILE"; exit 1; }
fi

# Kit-only docs: the repo source (docs/plans mirrors) wins so doc fixes always ship;
# a previous kit directory is only a fallback when the checkout is not available.
SELF_SIGN_SRC="$RUNTIME_PLANS/2026-09-21-ohos-tester-selfsign.md"
[ -f "$SELF_SIGN_SRC" ] || SELF_SIGN_SRC="$KIT_DIR/自签说明.md"
[ -f "$SELF_SIGN_SRC" ] || SELF_SIGN_SRC="$DEFAULT_KIT_DIR/自签说明.md"
KIT_README_SRC="$RUNTIME_PLANS/2026-09-21-ohos-delivery-kit-readme.md"
[ -f "$KIT_README_SRC" ] || KIT_README_SRC="$KIT_DIR/README-交付说明.md"
[ -f "$KIT_README_SRC" ] || KIT_README_SRC="$DEFAULT_KIT_DIR/README-交付说明.md"

need_file() {
    [ -f "$1" ] || { warn "missing input: $1${2:+ ($2)}"; exit 1; }
}

STAGE="$KIT_DIR.stage.$$"
LOG_DIR="$STAGE/.logs"
trap 'rm -rf "$STAGE"' 0 1 2 15
rm -rf "$STAGE"
mkdir -p "$STAGE" "$LOG_DIR"

# publish one band/permissions combination; output stays in the bin dir for copy_hap.
publish_variant() {
    _tfm="$1"; _perms="$2"
    if [ -n "$_perms" ]; then
        log "== publishing $_tfm with extra permissions =="
    else
        log "== publishing $_tfm =="
    fi
    set -- "$PROJ" -c Release -r openharmony-arm64 -m:1 \
        -p:OpenHarmonyUIPage=pages/Index \
        -p:OpenHarmonyArktsModulesAbc="$DIST_DIR/ets/modules.abc" \
        -p:OpenHarmonyHapPackage=true
    if [ "$_tfm" = "net11.0-openharmony20.0" ]; then
        # documented repro for the API 20 band override (the project multi-targets)
        set -- "$@" -p:TargetFrameworks="net11.0-openharmony20.0" -p:TargetFramework="net11.0-openharmony20.0"
    else
        set -- "$@" -f "$_tfm"
    fi
    if [ -n "$_perms" ]; then
        set -- "$@" "-p:OpenHarmonyExtraPermissions=\"$_perms\""
    fi
    _log="$LOG_DIR/publish-$_tfm${_perms:+_permissions}.log"
    if ! "$DOTNET" publish "$@" > "$_log" 2>&1; then
        warn "publish failed: $_tfm (log: $_log)"
        tail -20 "$_log" >&2
        exit 1
    fi
}

# make sure the generated module.json really carries the requested permissions
check_permissions() {
    python3 - "$1" "$PERMS" <<'PY' || { warn "permission check failed: $1"; exit 1; }
import json, sys, zipfile
hap, want = sys.argv[1], sys.argv[2].split(';')
with zipfile.ZipFile(hap) as z:
    got = [p.get('name') for p in json.loads(z.read('module.json'))['module'].get('requestPermissions', [])]
missing = [p for p in want if p not in got]
if missing:
    print('missing permissions: ' + ', '.join(missing), file=sys.stderr)
    sys.exit(1)
PY
}

copy_hap() {
    need_file "$1"
    cp -f "$1" "$STAGE/$2"
    log "hap     $2  $(sha256sum "$1" | cut -d' ' -f1)"
}

copy_doc() {
    need_file "$1"
    cp -f "$1" "$STAGE/$2"
    log "doc     $2  <- $1"
}

copy_tool() {
    need_file "$1"
    cp -f "$1" "$STAGE/$2"
    log "script  $2  <- $1"
}

BIN26="$PROJ/bin/Release/net11.0-openharmony26.0/openharmony-arm64"
BIN20="$PROJ/bin/Release/net11.0-openharmony20.0/openharmony-arm64"

# 26.0 default: also supplies the unsigned 26.0 default hap.
publish_variant net11.0-openharmony26.0 ""
copy_hap "$BIN26/hello-maui-app.hap" "hello-maui-app.hap"
copy_hap "$BIN26/hello-maui-app-unsigned.hap" "hello-maui-app-unsigned.hap"

publish_variant net11.0-openharmony26.0 "$PERMS"
check_permissions "$BIN26/hello-maui-app.hap"
copy_hap "$BIN26/hello-maui-app.hap" "hello-maui-app-permissions.hap"

publish_variant net11.0-openharmony20.0 ""
copy_hap "$BIN20/hello-maui-app.hap" "hello-maui-app-api20.hap"

publish_variant net11.0-openharmony20.0 "$PERMS"
check_permissions "$BIN20/hello-maui-app.hap"
copy_hap "$BIN20/hello-maui-app.hap" "hello-maui-app-api20-permissions.hap"

# Optional: pre-sign every assembled hap (including the unsigned variant) for one tester
# device, so the kit is installable on their UDID without them self-signing. The external
# profile must list that UDID (sign-for-device.sh fails closed otherwise) and the app cert
# chain must sit next to the p7b or come from OHOS_EXT_CERT; the password comes from the
# terminal, a piped stdin (two lines) or OHOS_KEY_PWD_FILE.
if [ "$SIGN_EXTERNAL" = 1 ]; then
    log "== external pre-signing for UDID $(printf '%s' "$EXT_UDID" | cut -c1-8)... =="
    set -- --external --pwd-input-mode \
        --profile "$EXT_PROFILE" --key "$EXT_KEY" --key-alias "$EXT_ALIAS" \
        --expect-udid "$EXT_UDID" --out-dir "$STAGE"
    [ -z "${OHOS_EXT_CERT:-}" ] || set -- "$@" --cert "$OHOS_EXT_CERT"
    [ -z "${OHOS_KEY_PWD_FILE:-}" ] || set -- "$@" --key-pwd-file "$OHOS_KEY_PWD_FILE"
    for _h in "$STAGE"/*.hap; do
        [ -f "$_h" ] || continue
        set -- "$@" --unsigned "$_h"
    done
    sh "$W/scripts/sign-for-device.sh" "$@"

    _profile_sha="$(sha256sum "$EXT_PROFILE" | cut -d' ' -f1)"
    {
        printf '目标设备 UDID: %s\n' "$EXT_UDID"
        printf '签名方式: 外部材料代签 (hap-sign-tool localSign, alias %s)\n' "$EXT_ALIAS"
        printf 'profile: %s\n' "$(basename "$EXT_PROFILE")"
        printf 'profile sha256: %s\n' "$_profile_sha"
        printf '签名时间: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
        printf '范围: 本包内全部 *.hap（含原 unsigned 变体）均已按上述 UDID 预签名\n'
        printf '说明: 直接按 快速开始.md 安装即可；本文件不含任何密钥、证书或密码\n'
    } > "$STAGE/目标设备.txt"
    log "目标设备.txt: UDID $(printf '%s' "$EXT_UDID" | cut -c1-8)..., profile sha256 $(printf '%s' "$_profile_sha" | cut -c1-16)..."
fi

log "== copying docs =="
copy_doc "$RUNTIME_PLANS/2026-09-19-ohos-hap-acceptance-for-testers.md" "验收说明.md"
copy_doc "$RUNTIME_PLANS/2026-09-20-ohos-tester-quickstart.md" "快速开始.md"
copy_doc "$RUNTIME_PLANS/2026-09-21-ohos-device-run-playbook.md" "真机操作手册.md"
copy_doc "$RUNTIME_PLANS/README.md" "文档索引.md"
copy_doc "$RUNTIME_PLANS/2026-09-19-ohos-signing-and-udid-guide.md" "签名与UDID指南.md"
copy_doc "$SELF_SIGN_SRC" "自签说明.md"
copy_doc "$RUNTIME_PLANS/2026-09-21-ohos-final-status.md" "最终状态.md"
copy_doc "$KIT_README_SRC" "README-交付说明.md"

# Kit-root signing-status page. Written here (not copied from a repo doc) so it always matches
# the kit's actual hap names and stays covered by SHA256SUMS.
log "note    签名说明.txt (self-signed status; generated by the kit builder)"
cat > "$STAGE/签名说明.txt" <<'SIGNNOTE'
OpenHarmony MAUI 设备测试包 — 签名说明（务必先读）
=================================================

一、包内 4 个默认 hap 是【自签名】包
     hello-maui-app.hap
     hello-maui-app-permissions.hap
     hello-maui-app-api20.hap
     hello-maui-app-api20-permissions.hap
   它们用我方调试证书 / 调试 profile 签名（profile 只绑定示例设备 UDID），只证明包内自洽；
   真机安装会被系统拒绝，常见错误码：
     9568257 fail to verify pkcs7 file         —— 设备不信任该签名（含签名块缺失/无效的情况）
     9568344 install parse profile prop check  —— profile 未绑定你的设备 UDID
   这是【预期】结果，不是偶发故障：重试、换安装方式都不会成功。

二、唯一可安装的路径：重签未签名变体
     hello-maui-app-unsigned.hap（与默认包同一负载）
   → 用你自己的华为账号自动签名（完整步骤见 自签说明.md）；签名后的 hap 绑定你的证书与 UDID，
     才能在你的设备上安装。一行示例（路径/密码换成你的）：
       hap-sign-tool sign-app -keyAlias debugKey -signAlg SHA256withECDSA -mode localSign \
         -appCertFile <你的>.cer -profileFile <你的>.p7b \
         -inFile hello-maui-app-unsigned.hap -outFile hello-maui-app-yourself.hap \
         -keystoreFile <你的>.p12 -keyPwd "<key密码>" -keystorePwd "<store密码>"
   也可以回传 UDID（hdc shell bm get -u）由我们重签，或改用发布方的预签包（含 目标设备.txt）。

三、重签安装成功后若“启动即退”
   约 1 秒退出、exit 254，hilog 报
     ReferenceError: Cannot find module 'ets/entryability/EntryAbility' , which is application Entry Point
   这是本版 kit 的 ArkTS 壳 abc 入口 record 缺陷（与宿主/缺库无关），PA1 重建壳后的下一版
   kit 修复；详见交付方文档 docs/plans/2026-09-22-ohos-startup-crash-rootcause.md。
   在修复版 kit 发布前，无需对该错误再跑 P1–P4 探针。

四、校验
   包内 SHA256SUMS 覆盖本文件；整包 sha256 与解压内容树摘要见 release 说明「## Integrity」小节
   （或 .tar.gz.sha256 sidecar）。哈希以发布说明为准，重签/重新打包后必然变化。
SIGNNOTE

if [ "$SIGN_EXTERNAL" = 1 ]; then
    cat >> "$STAGE/签名说明.txt" <<'SIGNNOTE_EXT'

五、本包为预签包（--sign-external）
   全部 hap（含原 unsigned 变体）已按 目标设备.txt 中的 UDID 预签，可直接安装；
   其他设备仍会被拒（9568344）。本文件与 目标设备.txt 均不含密钥、证书或密码。
SIGNNOTE_EXT
fi

log "== copying the tester self-check =="
copy_tool "$VERIFY_KIT_SRC" "verify-kit.sh"

log "== generating SHA256SUMS =="
rm -rf "$LOG_DIR"
(
    cd "$STAGE"
    LC_ALL=C
    export LC_ALL
    sha256sum *.hap *.md verify-kit.sh 签名说明.txt > SHA256SUMS
    if [ -f 目标设备.txt ]; then
        sha256sum 目标设备.txt >> SHA256SUMS
    fi
)
( cd "$STAGE" && sha256sum -c SHA256SUMS >/dev/null ) || { warn "SHA256SUMS self-check failed"; exit 1; }
log "SHA256SUMS: $(wc -l < "$STAGE/SHA256SUMS" | tr -d ' ') entries, sha256sum -c OK"

# swap the freshly assembled kit in (old kit removed only now)
rm -rf "$KIT_DIR"
mv "$STAGE" "$KIT_DIR"
trap - 0 1 2 15
log "kit directory: $KIT_DIR"

# Tree digest of the assembled contents, computed by the shipped verifier itself (so the
# value a tester compares is produced by the same code). --tree-digest also runs the
# in-place SHA256SUMS check; only the "tree sha256=" line is captured, and a failing
# self-check stops the build before anything is packed or published.
TREE_SHA=""
VERIFY_RC=0
VERIFY_OUT="$(sh "$VERIFY_KIT_SRC" --tree-digest "$KIT_DIR" 2>/dev/null)" || VERIFY_RC=$?
if [ "$VERIFY_RC" -eq 0 ]; then
    TREE_SHA="$(printf '%s\n' "$VERIFY_OUT" | sed -n 's/^.*tree sha256=//p' | head -n1)"
fi
[ -n "$TREE_SHA" ] || { warn "could not compute the kit tree digest (verify-kit.sh rc=$VERIFY_RC)"; exit 1; }
log "tree:   sha256=$TREE_SHA"

if [ "$SKIP_TAR" = 0 ]; then
    log "== packing the tarball =="
    rm -f "$OUT"
    tar -czf "$OUT" -C "$KIT_DIR" .
    log "tar:    $OUT"
    log "size:   $(wc -c < "$OUT" | tr -d ' ') bytes"
    log "sha256: $(sha256sum "$OUT" | cut -d' ' -f1)"
else
    log "tar skipped (--skip-tar)"
fi

if [ "$PUBLISH" = 1 ]; then
    log "== publishing the kit (scripts/publish-workload-release.sh) =="
    KIT_SHA="$(sha256sum "$OUT" | cut -d' ' -f1)"
    BUNDLE_VER="$(python3 -c "import json;print(json.load(open('$W/manifests/${SDK_BAND:-11.0.100-rc.1}/microsoft.net.sdk.openharmony/WorkloadManifest.json'))['version'])")"
    BUNDLE="$W/dist/openharmony-workload-$BUNDLE_VER.tar.gz"
    [ -f "$BUNDLE" ] || sh "$W/scripts/pack-workload-bundle.sh" >/dev/null
    BUNDLE_SHA="$(sha256sum "$BUNDLE" | cut -d' ' -f1)"
    log "kit    sha256=$KIT_SHA"
    log "bundle sha256=$BUNDLE_SHA"
    # The rebuild intentionally replaces the kit/bundle assets on the rolling releases;
    # the digests above are handed to the publisher as the expected ones, and the tree
    # digest lands in the kit release notes.
    DEVICE_TEST_KIT="$OUT" DEVICE_TEST_KIT_SHA256="$KIT_SHA" BUNDLE_SHA256="$BUNDLE_SHA" \
    DEVICE_TEST_KIT_TREE_DIGEST="$TREE_SHA" \
        sh "$W/scripts/publish-workload-release.sh" \
            --kit-sha256 "$KIT_SHA" --bundle-sha256 "$BUNDLE_SHA" \
            --kit-tree-digest "$TREE_SHA" --allow-clobber-mismatch
fi

log "== done =="
log "hint:   tester self-check inside the kit: (cd $KIT_DIR && sh verify-kit.sh)"
