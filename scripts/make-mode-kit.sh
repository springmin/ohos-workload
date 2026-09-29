#!/bin/sh
# make-mode-kit.sh - one-command runtime-mode kits: publish one OpenHarmony project as the
# three launch shapes of the MS-MODE packaging switch (OpenHarmonyRuntimeMode), lay every shape
# out as a per-mode deliverable directory and assert the hap really carries that shape.
#
#   out/<mode>/<stem>-<mode>.hap            the installable hap (the publish's signed hap, or
#                                           its unsigned twin when signing was disabled)
#   out/<mode>/<stem>-<mode>-unsigned.hap   the unsigned twin, when the publish produced one
#   out/<mode>/publish.log                  the publish log of that mode
#   out/SHA256SUMS                          every hap, relative paths (`sha256sum -c` from out)
#
# Modes (the value is written to libs/<abi>/runtime-mode.txt inside the hap):
#   jit     the default publish; the hap keeps the stock runtime natives and the JIT route
#   aot     -p:PublishAot=true -p:PublishAotUsingRuntimePack=true -p:NativeLib=Shared (the
#           aot-haps recipe); the hap must carry lib<stem>.so in libs/<abi>/ (stem = the
#           app.json assembly name without .dll). The publish also stages the ArkTS UI shell
#           (-p:OpenHarmonyUIPage=pages/Index by default, override with --property): without a
#           page the hap carries the headless abc (empty main_pages, no XComponent/loadContent)
#           and the MAUI window paints nothing
#   interp  -p:OpenHarmonyRuntimeMode=interp -p:OpenHarmonyInterpreterPack=<dir> (an extracted
#           ohos-interpreter-pack: libcoreclr.so + libclrinterpreter.so under <dir>/ or
#           <dir>/native/); the hap must carry both swapped libraries
#
# Every mode is verified after the publish: a missing or mismatching marker, a missing AOT
# application library and a missing interpreter library all fail the run (non-zero) with the
# offending entry and the fix named. --dry-run prints the exact publish/sign commands instead.
#
# Signing is a sign-for-device.sh passthrough: every argument after --sign goes to
# scripts/sign-for-device.sh (the kit appends --unsigned <hap> --out <tmp>, then replaces the
# mode hap on success), so the sign-for-device discipline holds - keep secrets off argv
# (--pwd-input-mode / --key-pwd-file / OHOS_ENC_PWD, never a raw password).
#
# Usage: scripts/make-mode-kit.sh --project <csproj> --out-dir <dir> [options] [--sign <args...>]
#   see usage() for the full option text. Env: DOTNET=<dotnet>, SIGN_FOR_DEVICE=<script>.
set -e

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

W="$(cd "$(dirname "$0")/.." && pwd)"
DOTNET="${DOTNET:-dotnet}"
# Shared, overridable dotnet environment (MSBuild server/node reuse off, a TMPDIR that can host
# the server socket) for the publishes below; see "Known environment quirks" in
# docs/openharmony-hap-packaging.md.
. "$W/scripts/lib-dotnet-env.sh" "$W"
SIGN_SCRIPT="${SIGN_FOR_DEVICE:-$W/scripts/sign-for-device.sh}"

PROJ=""
OUT=""
RID="openharmony-arm64"
TFM=""
CONF="Release"
MODES="jit aot interp"
PACK=""
ABI=""
STEM=""
HAP_DIR=""
PROPS=""
DRY=0
SIGN=0
SIGN_ARGS=""
MODE_SET=0

usage() {
    cat <<EOF
usage: $0 --project <csproj> --out-dir <dir> [options] [--sign <sign-for-device args...>]

Publishes one project as the jit / aot / interp runtime-mode haps and verifies each shape's
marker (libs/<abi>/runtime-mode.txt) and libraries before keeping it. The out dir gets one
subdirectory per mode plus a SHA256SUMS over every hap.

  --project <csproj>      project to publish (required)
  --out-dir <dir>         artifact root, one subdirectory per mode (required)
  --mode <m[,m...]>       jit | aot | interp or a comma list; repeatable (default: all three)
  --rid <rid>             runtime identifier (default: openharmony-arm64)
  --tfm <tfm>             target framework (-f); required for a multi-targeted project (it is
                          inferred when bin/<configuration>/ holds exactly one framework)
  --configuration <c>     publish configuration (default: Release)
  --interp-pack <dir>     extracted ohos-interpreter-pack for --mode interp (libcoreclr.so +
                          libclrinterpreter.so under <dir>/ or <dir>/native/; required with
                          interp, rejected otherwise)
  --abi <abi>             OpenHarmony ABI used for the in-hap assertions (default from --rid:
                          openharmony-arm64 -> arm64-v8a, openharmony-arm -> armeabi-v7a,
                          openharmony-x64 -> x86_64)
  --assembly <name>       assembly stem (default: the project file stem); the AOT library name
                          is read from the hap's resources/rawfile/app.json when present
  --hap-dir <dir>         publish output dir holding <stem>.hap / <stem>-unsigned.hap
                          (default: <project>/bin/<configuration>/<tfm>/<rid>)
  --property <name=value> extra MSBuild property, repeatable (e.g.
                          --property OpenHarmonyUIPage=pages/Index); the runtime-mode switch is
                          appended after these, so the kit always wins over a passed property.
                          --mode aot also defaults OpenHarmonyUIPage=pages/Index (the prebuilt
                          UI shell's page) unless --property supplies one: an AOT hap without
                          a page ships the headless abc and shows a white window on device
  --dry-run               print the publish/sign commands without running them
  --sign <args...>        re-sign each mode hap in place via scripts/sign-for-device.sh; every
                          argument after --sign is passed through (device mode: a UDID;
                          external material: --external --profile <p7b> --key <p12>
                          --key-alias <alias> --expect-udid <UDID>). Keep secrets off argv
                          (sign-for-device discipline): use --pwd-input-mode or
                          --key-pwd-file, never a raw password.
  -h | --help             this text

Examples:
  sh scripts/make-mode-kit.sh --project test/hello-maui-app/hello-maui-app.csproj \\
      --tfm net11.0-openharmony26.0 --out-dir /data/storage/el2/base/tmp/opencode/modekit \\
      --property OpenHarmonyUIPage=pages/Index \\
      --interp-pack /data/storage/el2/base/tmp/opencode/interp-pack
  sh scripts/make-mode-kit.sh --project test/hello-maui-app/hello-maui-app.csproj \\
      --tfm net11.0-openharmony26.0 --out-dir /data/storage/el2/base/tmp/opencode/modekit \\
      --interp-pack /data/storage/el2/base/tmp/opencode/interp-pack --sign <UDID>
EOF
}

need_value() { # <option>
    [ "$2" -ge 2 ] || { warn "$1 needs a value"; usage >&2; exit 2; }
}

while [ $# -gt 0 ]; do
    case "$1" in
        --project)     need_value "$1" $#; PROJ="$2"; shift 2 ;;
        --out-dir)     need_value "$1" $#; OUT="$2"; shift 2 ;;
        --rid)         need_value "$1" $#; RID="$2"; shift 2 ;;
        --tfm)         need_value "$1" $#; TFM="$2"; shift 2 ;;
        --configuration|--config)
                       need_value "$1" $#; CONF="$2"; shift 2 ;;
        --mode)
            need_value "$1" $#
            # The first --mode replaces the all-three default; later ones extend the selection.
            if [ "$MODE_SET" = 0 ]; then MODES="$2"; MODE_SET=1; else MODES="$MODES $2"; fi
            shift 2 ;;
        --interp-pack) need_value "$1" $#; PACK="$2"; shift 2 ;;
        --abi)         need_value "$1" $#; ABI="$2"; shift 2 ;;
        --assembly)    need_value "$1" $#; STEM="$2"; shift 2 ;;
        --hap-dir)     need_value "$1" $#; HAP_DIR="$2"; shift 2 ;;
        --property)
            need_value "$1" $#
            PROP="$2"
            PROPS="$PROPS$PROP
"
            shift 2 ;;
        --dry-run)     DRY=1; shift ;;
        --sign)
            # Passthrough tail: everything after --sign goes to sign-for-device.sh.
            SIGN=1
            shift
            while [ $# -gt 0 ]; do
                SIGN_ARGS="$SIGN_ARGS${SIGN_ARGS:+
}$1"
                shift
            done
            break ;;
        -h|--help)     usage; exit 0 ;;
        --)            shift; break ;;
        *)             warn "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
done

[ -n "$PROJ" ] || { warn "--project <csproj> is required"; usage >&2; exit 2; }
[ -n "$OUT" ]  || { warn "--out-dir <dir> is required"; usage >&2; exit 2; }
[ -f "$PROJ" ] || die "project not found: $PROJ"
PROJ_DIR="$(cd "$(dirname "$PROJ")" && pwd)"
PROJ="$PROJ_DIR/$(basename "$PROJ")"
case "$OUT" in
    ""|"/"|"."|"..") warn "invalid out dir: '$OUT'"; exit 2 ;;
esac

# One canonical mode order; flip the line list to a word list and validate.
MODES="$(printf '%s\n' $MODES | tr ',' ' ')"
for _m in $MODES; do
    case "$_m" in
        jit|aot|interp) ;;
        *) warn "unknown runtime mode: '$_m' (use jit, aot or interp)"; exit 2 ;;
    esac
done
_ordered=""
for _m in jit aot interp; do
    for _x in $MODES; do
        case "$_x" in
            "$_m") _ordered="$_ordered $_m"; break ;;
        esac
    done
done
MODES="$(printf '%s' "$_ordered" | sed 's/^ *//; s/ *$//')"
[ -n "$MODES" ] || { warn "no runtime mode selected"; exit 2; }

case " $MODES " in *" interp "*)
    [ -n "$PACK" ] || { warn "--interp-pack <dir> is required for --mode interp (the interpreter pack supplies libcoreclr.so + libclrinterpreter.so)"; exit 2; }
    ;;
esac
if [ -n "$PACK" ]; then
    case " $MODES " in *" interp "*) ;; *)
        warn "--interp-pack is only meaningful with --mode interp (OpenHarmonyInterpreterPack outside interp is a build error in the pack targets too)"; exit 2 ;;
    esac
fi

# The ABI decides the libs/<abi>/ entry names the assertions look for; default from the RID.
if [ -z "$ABI" ]; then
    case "$RID" in
        *-arm64) ABI="arm64-v8a" ;;
        *-arm)   ABI="armeabi-v7a" ;;
        *-x64)   ABI="x86_64" ;;
        *)       ABI="arm64-v8a" ;;
    esac
fi
[ -n "$STEM" ] || STEM="$(basename "$PROJ" .csproj)"

if [ "$DRY" != 1 ]; then
    if [ -x "$DOTNET" ]; then
        :
    elif command -v "$DOTNET" >/dev/null 2>&1; then
        :
    else
        die "dotnet not found: $DOTNET (set DOTNET=)"
    fi
fi
if [ "$SIGN" = 1 ]; then
    [ -f "$SIGN_SCRIPT" ] || die "sign-for-device.sh not found: $SIGN_SCRIPT (set SIGN_FOR_DEVICE=)"
    if [ -n "$SIGN_ARGS" ]; then
        _oifs=$IFS; IFS='
'
        for _a in $SIGN_ARGS; do
            case "$_a" in
                --unsigned|--out|--out-dir)
                    IFS=$_oifs
                    warn "--sign does not accept $_a: make-mode-kit passes it per hap"
                    exit 2 ;;
                --password)
                    warn "--sign carries --password on argv (world-readable); prefer --pwd-input-mode, --key-pwd-file or OHOS_ENC_PWD" ;;
            esac
        done
        IFS=$_oifs
    fi
fi

# Interpreter pack validation matches the pack targets: <dir>/ or <dir>/native/, both files.
pack_file() { # <pack dir> <file name> -> prints the path, non-zero when absent
    for _c in "$1/$2" "$1/native/$2"; do
        [ -f "$_c" ] && { printf '%s' "$_c"; return 0; }
    done
    return 1
}
case " $MODES " in *" interp "*)
    _coreclr="$(pack_file "$PACK" libcoreclr.so || true)"
    _clrinterp="$(pack_file "$PACK" libclrinterpreter.so || true)"
    [ -n "$_coreclr" ] || die "interpreter pack '$PACK' carries no libcoreclr.so (looked in the directory and its native/ subdirectory); extract ohos-interpreter-pack.tar.gz and point --interp-pack at it"
    [ -n "$_clrinterp" ] || die "interpreter pack '$PACK' carries no libclrinterpreter.so (looked in the directory and its native/ subdirectory); extract ohos-interpreter-pack.tar.gz and point --interp-pack at it"
    log "interpreter pack: $_coreclr + $_clrinterp"
    ;;
esac

# The publish output dir the haps land in. Resolve the framework first: publish -f is mandatory
# for a multi-targeted project, and the default hap path embeds the framework.
if [ -z "$HAP_DIR" ]; then
    if [ -z "$TFM" ] && [ "$DRY" != 1 ]; then
        _found=""
        for _d in "$PROJ_DIR/bin/$CONF"/*/; do
            [ -d "$_d" ] || continue
            _found="$_found $(basename "$_d")"
        done
        _n=$(printf '%s\n' $_found | grep -c . || true)
        if [ "$_n" -eq 1 ]; then
            TFM="$(printf '%s' $_found)"
            log "target framework inferred from bin/$CONF: $TFM"
        else
            warn "cannot infer --tfm ($_n framework dirs under $PROJ_DIR/bin/$CONF); pass --tfm <tfm> or --hap-dir <publish dir>"
            exit 2
        fi
    fi
fi

# zip readers: python3 when available, the unzip CLI otherwise (at least one is required only
# when a hap has to be asserted, i.e. outside --dry-run).
if [ "$DRY" != 1 ]; then
    if command -v python3 >/dev/null 2>&1; then
        ZIP_TOOL=python3
    elif command -v unzip >/dev/null 2>&1; then
        ZIP_TOOL=unzip
    else
        ZIP_TOOL=""
        die "need python3 or unzip to assert the hap payload"
    fi
fi

zip_read() { # <zip> <entry> -> entry text (empty when absent)
    if [ "$ZIP_TOOL" = python3 ]; then
        python3 - "$1" "$2" <<'PY' || true
import sys, zipfile
try:
    sys.stdout.write(zipfile.ZipFile(sys.argv[1]).read(sys.argv[2]).decode("utf-8", "replace"))
except KeyError:
    pass
PY
    else
        unzip -p "$1" "$2" 2>/dev/null || true
    fi
}

zip_entry_size() { # <zip> <entry> -> size in bytes (empty when absent)
    if [ "$ZIP_TOOL" = python3 ]; then
        python3 - "$1" "$2" <<'PY' || true
import sys, zipfile
try:
    print(zipfile.ZipFile(sys.argv[1]).getinfo(sys.argv[2]).file_size)
except KeyError:
    pass
PY
    else
        unzip -l "$1" 2>/dev/null | awk -v n="$2" '$NF == n && $1 ~ /^[0-9]+$/ { print $1; exit }' || true
    fi
}

aot_stem() { # <hap> -> the lib<stem>.so stem the host derives (app.json assembly)
    _appjson="$(zip_read "$1" resources/rawfile/app.json)"
    if [ -n "$_appjson" ]; then
        _asm="$(printf '%s' "$_appjson" | sed -n 's/.*"assembly"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        case "$_asm" in
            *.dll) printf '%s' "${_asm%.dll}"; return 0 ;;
        esac
    fi
    printf '%s' "$STEM"
}

print_cmd() {
    _line=""
    for _a in "$@"; do
        case "$_a" in
            *[!A-Za-z0-9_./:=+-]*) _q="'$(printf '%s' "$_a" | sed "s/'/'\\\\''/g")'" ;;
            *) _q="$_a" ;;
        esac
        _line="$_line $_q"
    done
    printf '+%s\n' "$_line"
}

# verify_mode <mode> <hap> <label>: the marker must equal the mode and the mode's libraries must
# be in libs/<abi>/. Fails the run with the offending entry named.
verify_mode() {
    _mode="$1"; _hap="$2"; _label="$3"
    _marker="$(zip_read "$_hap" "libs/$ABI/runtime-mode.txt" | tr -d '\r\n')"
    if [ -z "$_marker" ]; then
        die "$_mode: $_hap carries no libs/$ABI/runtime-mode.txt (a pre-MS-MODE hap, or --abi is wrong: $ABI)"
    fi
    [ "$_marker" = "$_mode" ] || die "$_mode: $_hap carries runtime-mode.txt='$_marker' (expected '$_mode'); rebuild with -p:OpenHarmonyRuntimeMode=$_mode"
    case "$_mode" in
        aot)
            _stem="$(aot_stem "$_hap")"
            _size="$(zip_entry_size "$_hap" "libs/$ABI/lib$_stem.so" || true)"
            [ -n "$_size" ] && [ "$_size" -gt 0 ] || die "$_mode: $_hap carries no libs/$ABI/lib$_stem.so (the NativeAOT application library); publish the AOT variant with -p:PublishAot=true -p:PublishAotUsingRuntimePack=true -p:NativeLib=Shared or switch to --mode jit"
            log "$_mode: $_label $_hap (marker=$_marker, lib$_stem.so $_size B)" ;;
        interp)
            for _lib in libcoreclr.so libclrinterpreter.so; do
                _size="$(zip_entry_size "$_hap" "libs/$ABI/$_lib" || true)"
                [ -n "$_size" ] && [ "$_size" -gt 0 ] || die "$_mode: $_hap carries no libs/$ABI/$_lib; extract ohos-interpreter-pack.tar.gz and point --interp-pack at it (the pack stages both files over the publish natives)"
            done
            log "$_mode: $_label $_hap (marker=$_marker, libcoreclr.so + libclrinterpreter.so staged)" ;;
        *)
            log "$_mode: $_label $_hap (marker=$_marker)" ;;
    esac
}

# props_has <name>: 0 when --property already carries <name>=... (line-wise, so a prefix of a
# longer property name never matches)
props_has() {
    case "
$PROPS
" in
        *"
$1="*) return 0 ;;
    esac
    return 1
}

publish_mode() {
    _mode="$1"
    _od="$OUT/$_mode"
    set -- "$DOTNET" publish "$PROJ" -c "$CONF" -r "$RID" -m:1 -p:OpenHarmonyHapPackage=true
    [ -z "$TFM" ] || set -- "$@" -f "$TFM"
    if [ -n "$PROPS" ]; then
        _oifs=$IFS; IFS='
'
        for _p in $PROPS; do
            [ -n "$_p" ] || continue
            set -- "$@" "-p:$_p"
        done
        IFS=$_oifs
    fi
    # The mode switch goes last so the kit's value wins over a property passed in --property.
    case "$_mode" in
        jit)    set -- "$@" -p:OpenHarmonyRuntimeMode=jit ;;
        aot)    set -- "$@" -p:PublishAot=true -p:PublishAotUsingRuntimePack=true -p:NativeLib=Shared \
                             -p:CopyOutputSymbolsToPublishDirectory=false -p:OpenHarmonyRuntimeMode=aot
                # The AOT hap must carry the UI shell: without OpenHarmonyUIPage the pack stages
                # templates/ets/modules.abc (headless) and an empty main_pages.json, so the hap
                # has no XComponent/loadContent and the device paints a white window (the
                # aot-haps v1/v2 blank-window root cause). pages/Index is the prebuilt UI
                # shell's page; a caller-supplied --property OpenHarmonyUIPage=... wins.
                props_has OpenHarmonyUIPage || set -- "$@" -p:OpenHarmonyUIPage=pages/Index ;;
        interp) set -- "$@" -p:OpenHarmonyRuntimeMode=interp -p:OpenHarmonyInterpreterPack="$PACK" ;;
    esac
    if [ "$DRY" = 1 ]; then
        print_cmd "$@"
        return 0
    fi

    _dir="$HAP_DIR"
    [ -n "$_dir" ] || _dir="$PROJ_DIR/bin/$CONF/$TFM/$RID"
    rm -rf "$_od"
    mkdir -p "$_od"
    # A stale hap from an earlier publish must not pass as this run's output: drop the two
    # expected names and require the publish to write at least one again.
    rm -f "$_dir/$STEM.hap" "$_dir/$STEM-unsigned.hap"
    log "== publish $_mode =="
    if ! "$@" > "$_od/publish.log" 2>&1; then
        warn "publish failed ($_mode); last lines of $_od/publish.log:"
        tail -n 30 "$_od/publish.log" >&2
        exit 1
    fi

    _signed=""; _unsigned=""
    [ -f "$_dir/$STEM.hap" ] && _signed="$_dir/$STEM.hap"
    [ -f "$_dir/$STEM-unsigned.hap" ] && _unsigned="$_dir/$STEM-unsigned.hap"
    if [ -z "$_signed$_unsigned" ]; then
        warn "publish ($_mode) produced no hap under $_dir (looked for $STEM.hap / $STEM-unsigned.hap)"
        exit 1
    fi
    if [ -n "$_signed" ]; then
        _src="$_signed"; _label=signed
    else
        _src="$_unsigned"; _label=unsigned
    fi
    cp -f "$_src" "$_od/$STEM-$_mode.hap"
    [ -z "$_unsigned" ] || cp -f "$_unsigned" "$_od/$STEM-$_mode-unsigned.hap"
    verify_mode "$_mode" "$_od/$STEM-$_mode.hap" "$_label"
}

sign_mode() {
    _mode="$1"
    _hap="$2"
    _tmp="$_hap.signed.$$"
    set -- sh "$SIGN_SCRIPT"
    if [ -n "$SIGN_ARGS" ]; then
        _oifs=$IFS; IFS='
'
        for _a in $SIGN_ARGS; do
            set -- "$@" "$_a"
        done
        IFS=$_oifs
    fi
    set -- "$@" --unsigned "$_hap" --out "$_tmp"
    if [ "$DRY" = 1 ]; then
        print_cmd "$@"
        print_cmd mv -f "$_tmp" "$_hap"
        return 0
    fi
    log "== sign $_mode =="
    if ! "$@"; then
        rm -f "$_tmp"
        warn "signing failed ($_mode): $_hap"
        exit 1
    fi
    if [ ! -f "$_tmp" ]; then
        rm -f "$_tmp"
        warn "the signer produced no output for $_hap"
        exit 1
    fi
    mv -f "$_tmp" "$_hap"
    log "signed $_mode: $_hap"
}

# The hap targets resolve the toolchain explicitly: OpenHarmonySdkRoot / OHOS_SDK_ROOT, or
# OHOS_NDK, or an explicit OpenHarmonyLibCxxShared. Nothing under $HOME is probed by the pack, so
# this script resolves the local homebrew Cellar layout once (like scripts/make-device-test-kit.sh)
# and exports it; an explicit environment always wins.
resolve_ohos_sdk_root() {
    if [ -n "${OpenHarmonySdkRoot:-}" ] || [ -n "${OHOS_SDK_ROOT:-}" ] || [ -n "${OHOS_NDK:-}" ]; then
        return 0
    fi
    _candidate=""
    for _dir in "$HOME"/.harmonybrew/Cellar/ohos-sdk/*/; do
        [ -x "${_dir}toolchains/lib/ohos_packing_tool" ] && _candidate="${_dir%/}"
    done
    if [ -z "$_candidate" ]; then
        warn "no OpenHarmony SDK root found: set OpenHarmonySdkRoot (or OHOS_SDK_ROOT/OHOS_NDK) to the SDK root that contains toolchains/lib and toolchains/restool"
        return 0
    fi
    export OpenHarmonySdkRoot="$_candidate"
    export OHOS_SDK_ROOT="${OHOS_SDK_ROOT:-$_candidate}"
    export OHOS_NDK="${OHOS_NDK:-$_candidate/native}"
    log "OpenHarmony SDK root: $OpenHarmonySdkRoot"
}

if [ "$DRY" != 1 ]; then
    resolve_ohos_sdk_root
fi

if [ "$DRY" != 1 ]; then
    mkdir -p "$OUT"
    OUT="$(cd "$OUT" && pwd)"
    log "mode kit: project=$PROJ rid=$RID config=$CONF abi=$ABI modes=$(printf '%s' "$MODES" | tr ' ' ',')"
    log "out: $OUT"
fi

for _m in $MODES; do
    publish_mode "$_m"
    if [ "$SIGN" = 1 ]; then
        sign_mode "$_m" "$OUT/$_m/$STEM-$_m.hap"
    fi
done

if [ "$DRY" = 1 ]; then
    log "dry run: nothing was published or signed"
    exit 0
fi

# SHA256SUMS over every hap, relative to the out dir (verify from there: sha256sum -c SHA256SUMS).
if [ -z "$(find "$OUT" -type f -name '*.hap' -print 2>/dev/null)" ]; then
    die "no hap under $OUT to checksum"
fi
( cd "$OUT" && find . -type f -name '*.hap' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS )
log "== mode kit =="
for _m in $MODES; do
    log "  $_m: $OUT/$_m/$STEM-$_m.hap"
done
log "sha256sums: $OUT/SHA256SUMS ($(wc -l < "$OUT/SHA256SUMS" | tr -d ' ') hap(s)); verify: (cd $OUT && sha256sum -c SHA256SUMS)"
