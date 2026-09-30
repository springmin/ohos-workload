#!/bin/sh
# lib-dotnet-env.sh - shared dotnet environment defaults for the ohos-workload scripts.
#
# Source it once the repository root is known, before the first `dotnet` call:
#
#     W="$(cd "$(dirname "$0")/.." && pwd)"
#     . "$W/scripts/lib-dotnet-env.sh" "$W"
#
# The host quirks this absorbs (evidence: docs/openharmony-hap-packaging.md, "Known environment
# quirks"):
#   * /tmp is a separate hmfs mount where bind(2) on an AF_UNIX socket is refused with EACCES,
#     so the MSBuild server (a Unix domain socket at $TMPDIR/MSBuildServer-<hash>) cannot start
#     there and each CLI build waits out the server handshake before falling back;
#   * a socket path longer than 108 characters kills the server process ("... is of an invalid
#     length for use with domain sockets on this platform") and the client waits out its
#     connection timeout instead;
#   * a TMPDIR that does not exist fails the build outright (MSB1025, CreateTempSubdirectory).
#   * the Roslyn compiler server (VBCSCompiler) speaks over a socket of the same kind and wedges
#     fresh builds the same way; UseSharedCompilation=false runs csc in-process instead
#     (measured 2026-09-30: a rebuild with nothing up to date hung >300s without it, 6s with it).
#
# Not absorbed here (no safe default): network restores have no timeout of their own and can
# stall for hours on a flaky link; for package-less builds point RestoreConfigFile at a
# minimal/offline config (an empty <packageSources><clear/> suffices).
#
# Defaults, each applied only while the variable is unset or empty, so an operator can override
# any of them (e.g. `TMPDIR=/short sh scripts/preflight.sh`):
#   DOTNET_CLI_USE_MSBUILD_SERVER=0         this SDK's switch: no server process at all
#   DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER=1  the documented switch name (newer SDKs); harmless
#                                           where the SDK does not read it
#   MSBUILDDISABLENODEREUSE=1               never reuse a node wedged by an earlier run
#   DOTNET_CLI_TELEMETRY_OPTOUT=1           no first-run telemetry
#   DOTNET_NOLOGO=1                         stable output (the scripts grep the build logs)
#   UseSharedCompilation=false              Roslyn compiler server off (see the quirks above)
#   TMPDIR/TMP/TEMP                         a writable, socket-capable scratch dir: the caller's
#                                           TMPDIR when usable, else $DOTNET_ENV_TMPDIR, else
#                                           /data/storage/el2/base/tmp/opencode/t, else
#                                           <repo>/.tmp. A candidate whose estimated server
#                                           socket path ($TMPDIR/MSBuildServer-<hash>, measured
#                                           58 characters more) exceeds 100 is refused with a
#                                           warning when a shorter candidate is usable, so a long
#                                           scratch TMPDIR cannot wedge the CLI at the
#                                           108-character AF_UNIX limit. The first usable
#                                           candidate is kept when none fits (a long TMPDIR is
#                                           still better than none).
#
# Args: $1 = repository root (used for the .tmp fallback only). Always returns 0.

DOTNET_CLI_USE_MSBUILD_SERVER="${DOTNET_CLI_USE_MSBUILD_SERVER:-0}"
DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER="${DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER:-1}"
MSBUILDDISABLENODEREUSE="${MSBUILDDISABLENODEREUSE:-1}"
DOTNET_CLI_TELEMETRY_OPTOUT="${DOTNET_CLI_TELEMETRY_OPTOUT:-1}"
DOTNET_NOLOGO="${DOTNET_NOLOGO:-1}"
UseSharedCompilation="${UseSharedCompilation:-false}"
export DOTNET_CLI_USE_MSBUILD_SERVER DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER MSBUILDDISABLENODEREUSE \
    DOTNET_CLI_TELEMETRY_OPTOUT DOTNET_NOLOGO UseSharedCompilation

# A temp dir counts as usable when it exists (or can be created) and a scratch file can be
# written into it; a non-existing path is created, a file at the path or a read-only dir is not.
_ode_usable() {
    [ -n "$1" ] || return 1
    mkdir -p "$1" 2>/dev/null || return 1
    _ode_probe="$1/.dotnet-env.$$"
    : > "$_ode_probe" 2>/dev/null || return 1
    rm -f "$_ode_probe" 2>/dev/null || true
    return 0
}

# The MSBuild server pipe is $TMPDIR/MSBuildServer-<43-char hash>; the measured suffix is 58
# characters and the AF_UNIX path limit is 108 (the server dies at the limit while the client
# waits out its timeout). The soft limit below leaves 8 characters of headroom: a candidate over
# it loses to a shorter usable candidate, with a warning naming the refused path.
_ODE_SERVER_SUFFIX_LEN=58
_ODE_SOCKET_SOFT_LIMIT=100
_ODE_DEFAULT_TMP=/data/storage/el2/base/tmp/opencode/t

_ode_warn() { printf 'lib-dotnet-env: WARN: %s\n' "$*" >&2; }

# Two passes: a short-and-usable candidate wins (the first pass never touches an over-limit
# candidate, so an unused TMPDIR is not created just because it is long); only when none fits
# does the second pass keep the highest-priority usable candidate, over-limit or not.
_ode_tmp=""
_ode_repo_tmp="${1:-$PWD}/.tmp"
for _ode_dir in "${TMPDIR:-}" "${DOTNET_ENV_TMPDIR:-$_ODE_DEFAULT_TMP}" "$_ode_repo_tmp"; do
    [ -n "$_ode_dir" ] || continue
    [ "$(( ${#_ode_dir} + _ODE_SERVER_SUFFIX_LEN ))" -le "$_ODE_SOCKET_SOFT_LIMIT" ] || continue
    if _ode_usable "$_ode_dir"; then
        _ode_tmp="$_ode_dir"
        break
    fi
done
if [ -z "$_ode_tmp" ]; then
    for _ode_dir in "${TMPDIR:-}" "${DOTNET_ENV_TMPDIR:-$_ODE_DEFAULT_TMP}" "$_ode_repo_tmp"; do
        [ -n "$_ode_dir" ] || continue
        if _ode_usable "$_ode_dir"; then
            _ode_tmp="$_ode_dir"
            break
        fi
    done
fi
if [ -n "$_ode_tmp" ]; then
    if [ "$(( ${#_ode_tmp} + _ODE_SERVER_SUFFIX_LEN ))" -gt "$_ODE_SOCKET_SOFT_LIMIT" ]; then
        # No short candidate was usable (e.g. no /data mount and a deep checkout): say so once -
        # a too-long TMPDIR is still better than none.
        _ode_warn "no usable scratch dir stays under the $_ODE_SOCKET_SOFT_LIMIT-character MSBuild server socket estimate; using '$_ode_tmp' (estimated $(( ${#_ode_tmp} + _ODE_SERVER_SUFFIX_LEN )) chars, hard AF_UNIX limit 108)"
    fi
    for _ode_dir in "${TMPDIR:-}" "${DOTNET_ENV_TMPDIR:-}"; do
        [ -n "$_ode_dir" ] || continue
        [ "$_ode_tmp" != "$_ode_dir" ] || continue
        [ "$(( ${#_ode_dir} + _ODE_SERVER_SUFFIX_LEN ))" -gt "$_ODE_SOCKET_SOFT_LIMIT" ] || continue
        _ode_warn "'$_ode_dir' is too long for the MSBuild server socket (estimated $(( ${#_ode_dir} + _ODE_SERVER_SUFFIX_LEN )) chars > $_ODE_SOCKET_SOFT_LIMIT); using '$_ode_tmp' instead"
    done
else
    _ode_warn "no usable scratch dir found (the caller's TMPDIR, DOTNET_ENV_TMPDIR and <repo>/.tmp all failed the write probe)"
fi
if [ -n "$_ode_tmp" ]; then
    TMPDIR="$(cd "$_ode_tmp" && pwd -P)" || TMPDIR="$_ode_tmp"
    # TMP/TEMP are not read by dotnet on Unix, but child tools and ported scripts use them.
    [ -n "${TMP:-}" ] || TMP="$TMPDIR"
    [ -n "${TEMP:-}" ] || TEMP="$TMPDIR"
    export TMPDIR TMP TEMP
    # The repo .tmp fallback is scratch: ignore its contents from inside itself, so the
    # fallback never depends on (or edits) the repository .gitignore.
    if [ "$_ode_tmp" = "$_ode_repo_tmp" ] && [ ! -f "$_ode_tmp/.gitignore" ]; then
        printf '*\n' > "$_ode_tmp/.gitignore" 2>/dev/null || true
    fi
fi
unset _ode_tmp _ode_repo_tmp _ode_dir _ode_probe
