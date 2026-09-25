// dladdr() (GNU source) locates libhostfxr.so next to this library in OhosHostOpenHostfxr;
// the define must precede the first libc header of this translation unit (clang++ already
// predefines it, hence the guard).
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "openharmony_host.h"

#include <sensors/vibrator.h>
#include <network/netmanager/net_connection.h>
#include <network/netmanager/net_connection_type.h>
#include <accesstoken/ability_access_control.h>
#include <inputmethod/inputmethod_controller_capi.h>
#include <inputmethod/inputmethod_inputmethod_proxy_capi.h>
#include <inputmethod/inputmethod_attach_options_capi.h>
#include <native_drawing/drawing_font.h>
#include <native_drawing/drawing_typeface.h>
#include <LocationKit/oh_location.h>
#include <LocationKit/oh_location_type.h>

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <multimedia/image_framework/image/image_source_native.h>
#include <multimedia/image_framework/image/pixelmap_native.h>
#include <native_buffer/buffer_common.h>
#include <native_drawing/drawing_bitmap.h>
#include <native_drawing/drawing_brush.h>
#include <native_drawing/drawing_canvas.h>
#include <inputmethod/inputmethod_controller_capi.h>
#include <inputmethod/inputmethod_inputmethod_proxy_capi.h>
#include <inputmethod/inputmethod_attach_options_capi.h>
#include <native_drawing/drawing_font.h>
#include <native_drawing/drawing_matrix.h>
#include <native_drawing/drawing_path.h>
#include <native_drawing/drawing_pixel_map.h>
#include <native_drawing/drawing_point.h>
#include <native_drawing/drawing_shader_effect.h>
#include <native_drawing/drawing_shadow_layer.h>
#include <native_drawing/drawing_pen.h>
#include <native_drawing/drawing_rect.h>
#include <native_drawing/drawing_text_blob.h>
#include <native_drawing/drawing_types.h>
#include <native_buffer/native_buffer.h>
#include <native_window/external_window.h>
#include <hilog/log.h>
#include <pthread.h>
#include <sys/mman.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "host_optional.h"  // after the NDK headers: it redirects optional API call sites

// NOTE: signature is (argc, argv, host_path, dotnet_root, app_path) — see native/corehost/hostfxr.h.
typedef int (*ohos_main_startupinfo_fn)(const int argc, const char* const* argv,
                                        const char* host_path, const char* dotnet_root,
                                        const char* app_path);

typedef struct {
    size_t size;
    const char* host_path;
    const char* dotnet_root;
} ohos_hostfxr_initialize_parameters;

typedef int (*ohos_initialize_for_runtime_config_fn)(const char*, const ohos_hostfxr_initialize_parameters*, void**);
typedef int (*ohos_get_runtime_delegate_fn)(void*, int, void**);
typedef int (*ohos_close_fn)(void*);
typedef void (*ohos_error_writer_fn)(const char*);
typedef void (*ohos_set_error_writer_fn)(ohos_error_writer_fn);
typedef int (*ohos_load_assembly_and_get_function_pointer_fn)(const char*, const char*, const char*, const char*, void*, void**);

#define OHOS_HDT_LOAD_ASSEMBLY_AND_GET_FUNCTION_POINTER 5

static void ohos_error_writer(const char* message) {
    fprintf(stderr, "[hostfxr] %s\n", message);
}

static int path_join(char* dst, size_t dst_size, const char* dir, const char* file) {
    int written = snprintf(dst, dst_size, "%s/%s", dir, file);
    return written > 0 && (size_t)written < dst_size ? 0 : -1;
}

// --- runtime native library bridge: libs/<abi>/ -> app_dir -----------------------------------
// The HAP code-signing block (SoInfoSegment/fs-verity) covers libs/<abi>/** only, so the .NET
// runtime natives ship there and are excluded from the payload zip. The runtime resolves most of
// them by name through the loader's app search path, but three lookups go by directory (measured;
// see the "Runtime native libraries" header of OpenHarmony.Hap.targets):
//   * libhostpolicy.so   - hostfxr looks next to the app config for a self-contained app,
//   * libcoreclr.so      - hostpolicy builds '<app_dir>/libcoreclr.so' (deps_resolver.cpp),
//   * libclrjit/libclrgc - coreclr loads them from the directory it was loaded from.
// This bridge puts symlinks to the signed libs/<abi>/ files into app_dir; following a symlink
// reads the verity-enabled inode, while the extracted copy the payload used to carry is exactly
// what an enforcing device refuses to dlopen. A regular file already at the destination is a
// stale extraction from an older payload and is replaced. When symlinking is unavailable the file
// is copied instead, with a one-time warning that the copy is not covered by the HAP signing
// block. Best effort by design: a failure never fails the launch, and the outcome is logged once
// (hilog + stderr). Idempotent: an existing link to the same target is counted and kept.
//
// PF4-LIB-BRIDGE-BEGIN: the off-device toy test extracts this block verbatim (minus the leading
// `static`) from the source; keep it self-contained (libc + path_join above only).
//
// Scan/link bounds so a pathological libs directory can never stall a launch.
#define OHOS_RUNTIME_LIB_SCAN_MAX 256
#define OHOS_RUNTIME_LIB_LINK_MAX 64

// Only the runtime natives are bridged; everything else in libs/<abi>/ (the host itself,
// libc++_shared.so) is not looked up in app_dir and stays out. The names are matched from the libs
// directory, so the bridge follows whatever the pack staged instead of a second hard-coded list;
// libclrgc and libclrgcexp are separate builds and both are bridged.
static int OhosHostRuntimeLibName(const char* name) {
    static const char* const prefixes[] = {
        "libhostfxr.", "libhostpolicy.", "libcoreclr.", "libclrjit.", "libclrgc.", "libclrgcexp.",
        "libmscordaccore.", "libmscordbi.", "libSystem.",
    };
    if (name == NULL || name[0] == '.') {
        return 0;  // "." / ".." / dotfiles are never runtime natives
    }
    size_t len = strlen(name);
    if (len <= 3 || strcmp(name + len - 3, ".so") != 0) {
        return 0;  // only shared objects; .a/.bak neighbours are not runtime code
    }
    for (size_t i = 0; i < sizeof(prefixes) / sizeof(prefixes[0]); i++) {
        if (strncmp(name, prefixes[i], strlen(prefixes[i])) == 0) {
            return 1;
        }
    }
    return 0;
}

// Directory this library was loaded from (libs/<abi>/ at runtime), resolved through dladdr on an
// exported entry point (always in .dynsym, unlike a static helper). Returns 0 on success, -1 when
// the path is unknown or does not fit.
static int OhosHostOwnDirectory(char* dir, size_t dir_size) {
    Dl_info own_info;
    if (dir == NULL || dir_size == 0 ||
        dladdr((void*)&ohos_host_run_app, &own_info) == 0 || own_info.dli_fname == NULL) {
        return -1;
    }
    const char* slash = strrchr(own_info.dli_fname, '/');
    if (slash == NULL) {
        return -1;
    }
    size_t len = (size_t)(slash - own_info.dli_fname);
    if (len == 0 || len >= dir_size) {
        return -1;
    }
    memcpy(dir, own_info.dli_fname, len);
    dir[len] = '\0';
    return 0;
}

// One failure line (hilog + stderr) with the errno that caused it.
static void OhosHostLogLibFailure(const char* caller, const char* name, int error) {
    OH_LOG_WARN(LOG_APP,
                "[openharmony-host] %{public}s: runtime lib bridge could not link %{public}s (errno=%{public}d)",
                caller, name, error);
    fprintf(stderr, "[openharmony-host] %s: runtime lib bridge could not link %s (errno=%d)\n",
            caller, name, error);
}

// One-time warning for the copy fallback: an extracted copy is not covered by the HAP signing
// block, so an enforcing device may refuse to dlopen it.
static void OhosHostLogLibCopyWarning(const char* caller, const char* dst, int error) {
    OH_LOG_WARN(LOG_APP,
                "[openharmony-host] %{public}s: symlink(%{public}s) failed (errno=%{public}d); copied the runtime native instead - the copy is not covered by the HAP signing block and an enforcing device may reject it",
                caller, dst, error);
    fprintf(stderr, "[openharmony-host] %s: symlink(%s) failed (errno=%d); copied instead (verity may reject it)\n",
            caller, dst, error);
}

// Streaming copy for the symlink fallback: writes <dst>.tmp and renames it over the destination,
// so a failed copy never leaves a truncated lookalike for the loader to pick. Returns 0 on
// success, -1 otherwise with errno preserved for the caller's message.
static int OhosHostRuntimeLibCopy(const char* src, const char* dst) {
    int in = open(src, O_RDONLY | O_CLOEXEC);
    if (in < 0) {
        return -1;
    }
    char tmp[4096];
    int written = snprintf(tmp, sizeof(tmp), "%s.tmp", dst);
    if (written <= 0 || (size_t)written >= sizeof(tmp)) {
        close(in);
        errno = ENAMETOOLONG;
        return -1;
    }
    unlink(tmp);  // leftover of an interrupted earlier copy
    int out = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (out < 0) {
        close(in);
        return -1;
    }
    int result = 0;
    int saved_errno = 0;
    char buffer[32768];
    while (result == 0) {
        ssize_t got = read(in, buffer, sizeof(buffer));
        if (got < 0) {
            if (errno == EINTR) {
                continue;
            }
            result = -1;
            saved_errno = errno;
            break;
        }
        if (got == 0) {
            break;
        }
        ssize_t done = 0;
        while (done < got) {
            ssize_t put = write(out, buffer + done, (size_t)(got - done));
            if (put < 0) {
                if (errno == EINTR) {
                    continue;
                }
                result = -1;
                saved_errno = errno;
                break;
            }
            done += put;
        }
    }
    if (close(out) != 0 && result == 0) {
        result = -1;
        saved_errno = errno;
    }
    if (result == 0 && rename(tmp, dst) != 0) {
        result = -1;
        saved_errno = errno;
    }
    if (result != 0) {
        unlink(tmp);
    }
    close(in);
    errno = saved_errno;
    return result;
}

// The copy warning is emitted once per process; a second line would be noise.
static int g_runtime_lib_copy_warned = 0;

// Bridges every runtime native found in this library's own directory into app_dir (see the block
// comment above). Never fails the caller; logs one summary plus one line per failure. Called by
// both launch paths before hostfxr is initialized.
static void OhosHostEnsureRuntimeLibs(const char* caller, const char* app_dir) {
    if (caller == NULL || app_dir == NULL || app_dir[0] == '\0') {
        return;
    }
    char libs_dir[4096];
    if (OhosHostOwnDirectory(libs_dir, sizeof(libs_dir)) != 0) {
        return;  // no own directory to bridge from: leave the payload alone
    }
    DIR* libs = opendir(libs_dir);
    if (libs == NULL) {
        return;
    }

    int ensured = 0;
    int copied = 0;
    int failed = 0;
    int scanned = 0;
    char last_failed[128] = "-";
    int last_errno = 0;

    struct dirent* entry;
    while ((entry = readdir(libs)) != NULL) {
        if (++scanned > OHOS_RUNTIME_LIB_SCAN_MAX ||
            ensured + copied + failed >= OHOS_RUNTIME_LIB_LINK_MAX) {
            break;
        }
        const char* name = entry->d_name;
        if (!OhosHostRuntimeLibName(name)) {
            continue;
        }
        char src[4096];
        char dst[4096];
        if (path_join(src, sizeof(src), libs_dir, name) != 0 ||
            path_join(dst, sizeof(dst), app_dir, name) != 0) {
            failed++;
            snprintf(last_failed, sizeof(last_failed), "%s", name);
            last_errno = ENAMETOOLONG;
            OhosHostLogLibFailure(caller, name, ENAMETOOLONG);
            continue;
        }
        if (strcmp(src, dst) == 0) {
            continue;  // payload directory == libs directory (no staging): nothing to bridge
        }
        struct stat src_st;
        if (stat(src, &src_st) != 0 || !S_ISREG(src_st.st_mode)) {
            continue;
        }

        struct stat dst_st;
        if (lstat(dst, &dst_st) == 0) {
            if (S_ISLNK(dst_st.st_mode)) {
                char target[4096];
                ssize_t target_len = readlink(dst, target, sizeof(target) - 1);
                if (target_len >= 0) {
                    target[target_len] = '\0';
                    if (strcmp(target, src) == 0) {
                        ensured++;  // already bridged onto the same signed file
                        continue;
                    }
                }
            }
            if (unlink(dst) != 0) {  // stale extraction or a foreign link
                int error = errno;
                failed++;
                snprintf(last_failed, sizeof(last_failed), "%s", name);
                last_errno = error;
                OhosHostLogLibFailure(caller, name, error);
                continue;
            }
        }
        if (symlink(src, dst) == 0) {
            ensured++;
            continue;
        }
        int symlink_error = errno;
        if (OhosHostRuntimeLibCopy(src, dst) == 0) {
            copied++;
            if (!g_runtime_lib_copy_warned) {
                g_runtime_lib_copy_warned = 1;
                OhosHostLogLibCopyWarning(caller, dst, symlink_error);
            }
            continue;
        }
        failed++;
        last_errno = errno != 0 ? errno : symlink_error;
        snprintf(last_failed, sizeof(last_failed), "%s", name);
        OhosHostLogLibFailure(caller, name, last_errno);
    }
    closedir(libs);

    OH_LOG_INFO(LOG_APP,
                "[openharmony-host] %{public}s: runtime lib bridge in %{public}s: "
                "%{public}d ensured, %{public}d copied, %{public}d failed (last %{public}s errno=%{public}d)",
                caller, app_dir, ensured, copied, failed, last_failed, last_errno);
    fprintf(stderr,
            "[openharmony-host] %s: runtime lib bridge in %s: %d ensured, %d copied, %d failed "
            "(last %s errno=%d)\n",
            caller, app_dir, ensured, copied, failed, last_failed, last_errno);
}
// PF4-LIB-BRIDGE-END

// --- payload-in-libs app_dir resolution -------------------------------------------------------
//
// The packaging stages the whole managed payload into the hap's signed libs/<abi>/ directory
// (see the "Payload in libs" section of the packaging doc). That directory is the only one the
// device's namespace policy allows a later dlopen from (the extracted app data directory is
// refused), so when this library's own directory - resolved through dladdr, the same way
// OhosHostEnsureRuntimeLibs finds the staged runtime natives - carries the entry assembly, it
// supersedes the extracted payload the shell passed in as app_dir. A hap without the staged
// payload (or a plain publish-directory run) has no entry assembly there and keeps the caller's
// app_dir, with the symlink bridge above making the signed runtime natives visible to it.
// Best effort by design: a missing directory or assembly never fails the launch, and the
// outcome is logged once (hilog + stderr) with the used_own=<0|1> own=<own dir> app=<effective>
// markers the device reports key on.
static const char* OhosHostResolveAppDir(const char* caller, const char* app_dir,
                                         const char* entry_file, char* own_dir,
                                         size_t own_dir_size, int* used_own) {
    if (used_own != NULL) {
        *used_own = 0;
    }
    if (app_dir == NULL || entry_file == NULL || entry_file[0] == '\0') {
        return app_dir;
    }
    if (OhosHostOwnDirectory(own_dir, own_dir_size) != 0) {
        return app_dir;  // no own directory to prefer: leave the caller's app_dir alone
    }
    char entry_path[4096];
    struct stat entry_st;
    int own_has_entry = path_join(entry_path, sizeof(entry_path), own_dir, entry_file) == 0 &&
                        stat(entry_path, &entry_st) == 0 && S_ISREG(entry_st.st_mode);
    const char* effective = own_has_entry ? own_dir : app_dir;
    if (own_has_entry && used_own != NULL) {
        *used_own = 1;
    }
    OH_LOG_INFO(LOG_APP,
                "[openharmony-host] %{public}s: app_dir resolution: used_own=%{public}d own=%{public}s app=%{public}s",
                caller != NULL ? caller : "(null)", own_has_entry ? 1 : 0, own_dir, effective);
    fprintf(stderr, "[openharmony-host] %s: app_dir resolution: used_own=%d own=%s app=%s\n",
            caller != NULL ? caller : "(null)", own_has_entry ? 1 : 0, own_dir, effective);
    return effective;
}

// Resolves libhostfxr.so. The HAP code-signing block (SoInfoSegment/fs-verity) covers
// libs/<abi>/** only, so the signed copy staged next to this library (the host itself is
// loaded from libs/<abi>/) is the one an enforcing device accepts; the copy extracted from
// dotnet.zip into app_dir is not covered and stays the last-resort fallback. Candidate order:
//   1. <directory of this library>/libhostfxr.so - libs/<abi>/, resolved through dladdr;
//   2. "libhostfxr.so" - the loader's app library search path, which contains libs/<abi>/;
//   3. <app_dir>/libhostfxr.so - the extracted payload (pre-staging haps and self-contained
//      runs from a plain publish directory).
// `used_path` receives the loaded candidate (or the last candidate tried on failure) for the
// caller's diagnostics. Returns NULL when no candidate could be loaded.
static void* OhosHostOpenHostfxr(const char* caller, const char* app_dir, char* used_path, size_t used_path_size) {
    used_path[0] = '\0';

    char host_dir[4096];
    host_dir[0] = '\0';
    Dl_info own_info;
    if (dladdr((void*)&OhosHostOpenHostfxr, &own_info) != 0 && own_info.dli_fname != NULL) {
        const char* slash = strrchr(own_info.dli_fname, '/');
        if (slash != NULL && (size_t)(slash - own_info.dli_fname) < sizeof(host_dir)) {
            size_t dir_len = (size_t)(slash - own_info.dli_fname);
            memcpy(host_dir, own_info.dli_fname, dir_len);
            host_dir[dir_len] = '\0';
        }
    }

    char host_dir_path[4096];
    char app_dir_path[4096];
    const char* candidates[3];
    int candidate_count = 0;
    if (host_dir[0] != '\0' && path_join(host_dir_path, sizeof(host_dir_path), host_dir, "libhostfxr.so") == 0) {
        candidates[candidate_count++] = host_dir_path;
    }
    candidates[candidate_count++] = "libhostfxr.so";
    if (app_dir != NULL && path_join(app_dir_path, sizeof(app_dir_path), app_dir, "libhostfxr.so") == 0) {
        candidates[candidate_count++] = app_dir_path;
    }

    for (int i = 0; i < candidate_count; i++) {
        void* handle = dlopen(candidates[i], RTLD_NOW | RTLD_LOCAL);
        if (handle != NULL) {
            snprintf(used_path, used_path_size, "%s", candidates[i]);
            return handle;
        }
        const char* dl_error = dlerror();
        fprintf(stderr, "[openharmony-host] %s: dlopen(%s) failed: %s\n", caller, candidates[i],
                dl_error != NULL ? dl_error : "(no dlerror)");
    }
    if (candidate_count > 0) {
        snprintf(used_path, used_path_size, "%s", candidates[candidate_count - 1]);
    }
    return NULL;
}

// ---------------------------------------------------------------------------
// Executable-memory policy (W^X) and the one-shot exec-memory probe
// ---------------------------------------------------------------------------
// CoreCLR defaults EnableWriteXorExecute to 0 on TARGET_OPENHARMONY
// (src/coreclr/inc/clrconfigvalues.h, commit 678ac21836c): the sandbox refuses PROT_EXEC on the
// file-backed mappings the W^X default uses, while anonymous executable memory is what a JIT
// can allocate. The SDK additionally bakes System.Runtime.EnableWriteXorExecute=false into every
// runtimeconfig and exports DOTNET_EnableWriteXorExecute=0 (OpenHarmonyEnvironmentDefaults), so
// this setenv is deliberately redundant: it covers a hap built without the SDK mapping and,
// through the process environment, every child the runtime spawns. The initializing coreclr
// reads the variable when it starts, so setting it before hostfxr runs the app is early enough
// for both launch paths here (run_app and the bridged start_app command-line init).
//
// The A/B switch is an optional "xwe.txt" in the app's writable sandbox directory: first byte
// '1' selects W^X=1 for one experiment, anything else (or no file) keeps the default 0. The
// directory is the context's filesDir when the shell published one, else app_dir itself / its
// parent when writable - the extracted-payload layout is <filesDir>/dotnet, so its parent is
// the files dir. The same lookup receives the one-line probe result appended to
// dotnet-status.txt (next to the managed status lines); a directory that cannot be written
// only costs that append, never the launch.
//
// The probe itself runs once per process, on the first launch path that reaches this block, and
// is best effort: it maps a page with each strategy the runtime could use and records OK or the
// errno of the failing call. One device round then says which strategies the sandbox allows.
#define OHOS_STATUS_LINE_MAX 600

// Appends one flattened, capped status line to <dir>/dotnet-status.txt. Mirrors the managed
// style (OpenHarmonyApp.FlattenCallbackMessage): control characters become spaces, the line is
// capped at OHOS_STATUS_LINE_MAX characters with a trailing "...", one line per message. Never
// fails the caller; the probe runs once per process, so no dedup state is needed here.
static void OhosHostAppendStatusLine(const char* dir, const char* message) {
    if (dir == NULL || dir[0] == '\0' || message == NULL) {
        return;
    }
    char path[4096];
    if (path_join(path, sizeof(path), dir, "dotnet-status.txt") != 0) {
        return;
    }
    char flat[OHOS_STATUS_LINE_MAX + 4];
    size_t length = strlen(message);
    size_t keep = length < OHOS_STATUS_LINE_MAX ? length : OHOS_STATUS_LINE_MAX;
    for (size_t i = 0; i < keep; i++) {
        unsigned char c = (unsigned char)message[i];
        flat[i] = (c < 0x20 || c == 0x7f) ? ' ' : (char)c;
    }
    if (length > keep) {
        flat[keep++] = '.';
        flat[keep++] = '.';
        flat[keep++] = '.';
    }
    flat[keep] = '\0';
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) {
        return;
    }
    (void)!write(fd, flat, keep);
    (void)!write(fd, "\n", 1);
    close(fd);
}

// Minimal extraction of one string value from the compact context JSON the shells send
// (JSON.stringify). Same contract as OhosHostContextNamesAppDir: a textual scan is enough for
// the flat shape, and a false negative only falls back to the app_dir-derived directory.
// Backslash escapes are copied without the backslash (paths do not carry them in practice).
static int OhosHostJsonString(const char* json, const char* key, char* out, size_t out_size) {
    out[0] = '\0';
    if (json == NULL || key == NULL || out_size < 2) {
        return 0;
    }
    char needle[64];
    int written = snprintf(needle, sizeof(needle), "\"%s\"", key);
    if (written <= 0 || (size_t)written >= sizeof(needle)) {
        return 0;
    }
    const char* cursor = strstr(json, needle);
    if (cursor == NULL) {
        return 0;
    }
    cursor = strchr(cursor + written, ':');
    if (cursor == NULL) {
        return 0;
    }
    cursor++;
    while (*cursor == ' ' || *cursor == '\t' || *cursor == '\n' || *cursor == '\r') {
        cursor++;
    }
    if (*cursor != '"') {
        return 0;
    }
    cursor++;
    size_t used = 0;
    while (*cursor != '\0' && *cursor != '"') {
        if (*cursor == '\\' && cursor[1] != '\0') {
            cursor++;
        }
        if (used + 1 >= out_size) {
            out[0] = '\0';
            return 0;
        }
        out[used++] = *cursor++;
    }
    out[used] = '\0';
    return *cursor == '"' && used > 0;
}

// Picks the writable sandbox directory that carries xwe.txt and receives the status line: the
// context's filesDir when present and writable, else app_dir itself or its parent when writable
// (the extracted payload lives in <filesDir>/dotnet). Returns 1 and fills `out` when found.
static int OhosHostWritableDir(const char* app_dir, const char* context_json, char* out, size_t out_size) {
    out[0] = '\0';
    char files_dir[4096];
    if (OhosHostJsonString(context_json, "filesDir", files_dir, sizeof(files_dir)) &&
        access(files_dir, W_OK) == 0) {
        snprintf(out, out_size, "%s", files_dir);
        return 1;
    }
    if (app_dir != NULL && app_dir[0] != '\0' && access(app_dir, W_OK) == 0) {
        snprintf(out, out_size, "%s", app_dir);
        return 1;
    }
    if (app_dir != NULL) {
        const char* slash = strrchr(app_dir, '/');
        if (slash != NULL && slash != app_dir) {
            size_t parent_len = (size_t)(slash - app_dir);
            if (parent_len + 1 < out_size) {
                memcpy(out, app_dir, parent_len);
                out[parent_len] = '\0';
                if (access(out, W_OK) == 0) {
                    return 1;
                }
            }
        }
    }
    out[0] = '\0';
    return 0;
}

// First byte of <dir>/xwe.txt == '1' turns W^X back on; every other outcome keeps the default.
static int OhosHostReadXweFile(const char* dir) {
    char path[4096];
    if (dir == NULL || dir[0] == '\0' || path_join(path, sizeof(path), dir, "xwe.txt") != 0) {
        return 0;
    }
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return 0;
    }
    char first = '\0';
    ssize_t got = read(fd, &first, 1);
    close(fd);
    return got == 1 && first == '1';
}

// One probe result token: "OK", or the errno of the failing call.
static void OhosHostProbeToken(char* out, size_t out_size, int err) {
    if (err == 0) {
        snprintf(out, out_size, "OK");
    } else {
        snprintf(out, out_size, "%d", err);
    }
}

// Runs the mapping strategies the runtime may use, once per process. Each step is independent
// and failure is not fatal: the line records which one the sandbox refuses and with which errno.
//   1. anonymous mmap(RWX)                      - the RWX allocator's mapping
//   2. anonymous mmap(RW) -> mprotect(RX)       - the W^X allocator's anonymous fallback
//   3. memfd_create + ftruncate + mmap(RW) -> mprotect(RX) - in-memory file-backed W^X
//   4. temp file mmap(RX)                       - plain file-backed executable mapping
static int g_exec_probe_done = 0;

static void OhosHostProbeExecMemoryOnce(const char* status_dir) {
    if (g_exec_probe_done) {
        return;
    }
    g_exec_probe_done = 1;

    long page = sysconf(_SC_PAGESIZE);
    size_t page_size = page > 0 ? (size_t)page : 4096u;
    char r1[16];
    char r2[16];
    char r3[16];
    char r4[16];

    // 1. anonymous RWX
    {
        void* p = mmap(NULL, page_size, PROT_READ | PROT_WRITE | PROT_EXEC,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED) {
            OhosHostProbeToken(r1, sizeof(r1), errno);
        } else {
            OhosHostProbeToken(r1, sizeof(r1), 0);
            munmap(p, page_size);
        }
    }

    // 2. anonymous RW -> mprotect RX
    {
        void* p = mmap(NULL, page_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED) {
            OhosHostProbeToken(r2, sizeof(r2), errno);
        } else {
            int err = mprotect(p, page_size, PROT_READ | PROT_EXEC) == 0 ? 0 : errno;
            OhosHostProbeToken(r2, sizeof(r2), err);
            munmap(p, page_size);
        }
    }

    // 3. memfd_create -> ftruncate -> mmap RW -> mprotect RX
    {
        int err = 0;
        int fd = memfd_create("ohos-exec-probe", 0);
        if (fd < 0) {
            err = errno;
        } else {
            if (ftruncate(fd, (off_t)page_size) != 0) {
                err = errno;
            } else {
                void* p = mmap(NULL, page_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
                if (p == MAP_FAILED) {
                    err = errno;
                } else {
                    if (mprotect(p, page_size, PROT_READ | PROT_EXEC) != 0) {
                        err = errno;
                    }
                    munmap(p, page_size);
                }
            }
            close(fd);
        }
        OhosHostProbeToken(r3, sizeof(r3), err);
    }

    // 4. temp file mmap RX (the sandbox dir first, then TMPDIR, then /tmp)
    {
        const char* dirs[3];
        int dir_count = 0;
        if (status_dir != NULL && status_dir[0] != '\0') {
            dirs[dir_count++] = status_dir;
        }
        const char* tmp_dir = getenv("TMPDIR");
        if (tmp_dir != NULL && tmp_dir[0] == '/') {
            dirs[dir_count++] = tmp_dir;
        }
        dirs[dir_count++] = "/tmp";

        int err = ENOENT;
        for (int i = 0; i < dir_count; i++) {
            char path[4096];
            if (path_join(path, sizeof(path), dirs[i], "ohos-exec-probe.tmp") != 0) {
                err = ENAMETOOLONG;
                continue;
            }
            int fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0600);
            if (fd < 0) {
                err = errno;
                continue;
            }
            if (ftruncate(fd, (off_t)page_size) != 0) {
                err = errno;
            } else {
                void* p = mmap(NULL, page_size, PROT_READ | PROT_EXEC, MAP_SHARED, fd, 0);
                err = p == MAP_FAILED ? errno : 0;
                if (p != MAP_FAILED) {
                    munmap(p, page_size);
                }
            }
            close(fd);
            unlink(path);
            break;
        }
        OhosHostProbeToken(r4, sizeof(r4), err);
    }

    char line[160];
    snprintf(line, sizeof(line), "OHOS_DOTNET probe: 1=%s 2=%s 3=%s 4=%s", r1, r2, r3, r4);
    OH_LOG_INFO(LOG_APP, "%{public}s", line);
    fprintf(stderr, "[openharmony-host] %s\n", line);
    OhosHostAppendStatusLine(status_dir, line);
}

// Applies the W^X decision and runs the probe. Called before hostfxr can start coreclr on both
// launch paths; the probe itself is one-shot, so a second call only re-reads xwe.txt (the
// pending context adopted during start_app can be the first source of filesDir).
static void OhosHostApplyExecMemoryPolicy(const char* caller, const char* app_dir, const char* context_json) {
    char dir[4096];
    int have_dir = OhosHostWritableDir(app_dir, context_json, dir, sizeof(dir));
    int enabled = have_dir && OhosHostReadXweFile(dir) ? 1 : 0;
    const char* source = enabled ? "file" : "default";

    setenv("DOTNET_EnableWriteXorExecute", enabled ? "1" : "0", 1);
    const char* name = caller != NULL ? caller : "(null)";
    OH_LOG_INFO(LOG_APP, "[openharmony-host] %{public}s: xwe=%{public}d source=%{public}s",
                name, enabled, source);
    fprintf(stderr, "[openharmony-host] %s: xwe=%d source=%s\n", name, enabled, source);
    OhosHostProbeExecMemoryOnce(have_dir ? dir : NULL);
}

// hostfxr is deliberately resolved at run time, never at link time: libhostfxr.so ships both
// in the hap's libs/<abi>/ (the signed copy the HAP code-signing block covers; loaded first,
// see OhosHostOpenHostfxr) and in the app payload (dotnet.zip, extracted by the ArkTS ability
// before start_app; the fallback) while the HAP loader resolves DT_NEEDED entries when the
// shell imports libopenharmonyhost.so at ability load. A -lhostfxr link would therefore make
// the import fail (host === undefined, every shell call unavailable). Keep every hostfxr_*
// call routed through this dlopen/dlsym table; scripts/build-host.sh fails the build if a
// DT_NEEDED on libhostfxr.so appears.
//
// --- NativeAOT payloads (FIX-INTEROP #2) ------------------------------------
// A NativeAOT publish has no hostfxr and no managed assembly: it ships one app library
// (<app_dir>/lib<assembly stem>.so, NativeLib=Shared) whose own
// [UnmanagedCallersOnly(EntryPoint = "openharmony_app_main")] export is the launch surface.
// The host calls that export directly; hostfxr stays the JIT-only route. The library name is
// derived from the assembly file name the shell already passes (MyApp.dll -> libMyApp.so), so
// both payload shapes use the same start_app/run_app arguments.
static int OhosHostAotLibName(char* dst, size_t dst_size, const char* app_assembly_file) {
    const char* name = strrchr(app_assembly_file, '/');
    name = name != NULL ? name + 1 : app_assembly_file;
    const char* dot = strrchr(name, '.');
    size_t stem_len = dot != NULL ? (size_t)(dot - name) : strlen(name);
    if (stem_len == 0) {
        return -1;
    }
    int written = snprintf(dst, dst_size, "lib%.*s.so", (int)stem_len, name);
    return written > 0 && (size_t)written < dst_size ? 0 : -1;
}

// Fills dst with the AOT app library path for this payload. Returns 0 on success; -1 when the
// assembly name cannot form a library name or the path does not fit.
static int OhosHostAotLibPath(char* dst, size_t dst_size, const char* app_dir, const char* app_assembly_file) {
    char lib_name[256];
    if (OhosHostAotLibName(lib_name, sizeof(lib_name), app_assembly_file) != 0) {
        return -1;
    }
    return path_join(dst, dst_size, app_dir, lib_name);
}

// AOT direct launch: dlopen the application's native library and call its own
// [UnmanagedCallersOnly] openharmony_app_main export with the same payload contract the
// hostfxr route uses (line 1 = application path, following lines = arguments). Returns 1 when
// the payload was an AOT app (exit code in *exit_code, library kept loaded: the runtime may own
// process-lifetime state); 0 when there is no AOT library on this launch, so the caller
// continues with the hostfxr route.
static int OhosHostTryRunAotApp(const char* tag, const char* app_dir, const char* app_assembly_file,
                                const char* app_assembly_path, int argc, const char* const* argv,
                                int* exit_code) {
    char lib_path[4096];
    if (OhosHostAotLibPath(lib_path, sizeof(lib_path), app_dir, app_assembly_file) != 0) {
        return 0;
    }
    void* app_lib = dlopen(lib_path, RTLD_NOW | RTLD_LOCAL);
    if (app_lib == NULL) {
        return 0;  // the usual JIT payload: no app library next to the assembly
    }
    int (*entry)(const char*) = (int (*)(const char*))dlsym(app_lib, "openharmony_app_main");
    if (entry == NULL) {
        OH_LOG_WARN(LOG_APP,
                    "[openharmony-host] %{public}s: %{public}s has no openharmony_app_main export; "
                    "falling back to the hostfxr route", tag, lib_path);
        dlclose(app_lib);
        return 0;
    }

    size_t payload_len = strlen(app_assembly_path) + 1;
    for (int i = 0; i < argc; i++) {
        payload_len += strlen(argv[i]) + 1;
    }
    char* payload = (char*)malloc(payload_len);
    if (payload == NULL) {
        dlclose(app_lib);
        return 0;
    }
    char* cursor = payload;
    cursor += sprintf(cursor, "%s", app_assembly_path);
    for (int i = 0; i < argc; i++) {
        cursor += sprintf(cursor, "\n%s", argv[i]);
    }

    OH_LOG_INFO(LOG_APP, "[openharmony-host] %{public}s: NativeAOT payload %{public}s", tag, lib_path);
    *exit_code = entry(payload);
    free(payload);
    // Deliberately no dlclose: the AOT runtime may have started threads or registered atexit
    // work in the library, and the process is a one-shot launch from here.
    return 1;
}

int ohos_host_run_app(const char* app_dir, const char* app_assembly_file, int argc, const char* const* argv) {
    char hostfxr_path[4096];
    char app_assembly_path[4096];
    char own_dir[4096];
    int used_own = 0;
    const char* effective_app_dir =
        OhosHostResolveAppDir("run_app", app_dir, app_assembly_file, own_dir, sizeof(own_dir), &used_own);
    if (effective_app_dir == NULL) {
        return -1;
    }
    if (path_join(app_assembly_path, sizeof(app_assembly_path), effective_app_dir, app_assembly_file) != 0) {
        return -1;
    }

    // hostpolicy/coreclr resolve libhostpolicy/libcoreclr/libclrjit/libclrgc from app_dir, so the
    // signed libs/<abi>/ copies are linked in before hostfxr is initialized (best effort, never
    // fails the launch; see the bridge block above). When the payload ships in libs/<abi>/ the
    // effective app_dir IS the staged directory and there is nothing to bridge.
    if (!used_own) {
        OhosHostEnsureRuntimeLibs("run_app", effective_app_dir);
    }

    // Pin the executable-memory policy (and probe it once) before hostfxr can initialize
    // coreclr. run_app has no context JSON, so xwe.txt is looked up in app_dir / its parent.
    OhosHostApplyExecMemoryPolicy("run_app", effective_app_dir, NULL);

    // NativeAOT payloads launch through their own export; only JIT payloads continue into
    // hostfxr below (see OhosHostTryRunAotApp).
    int aot_exit_code = 0;
    if (OhosHostTryRunAotApp("run_app", effective_app_dir, app_assembly_file, app_assembly_path,
                             argc, argv, &aot_exit_code)) {
        OH_LOG_INFO(LOG_APP, "[openharmony-host] run_app AOT Main exited rc=%{public}d", aot_exit_code);
        return aot_exit_code;
    }

    void* hostfxr = OhosHostOpenHostfxr("run_app", effective_app_dir, hostfxr_path, sizeof(hostfxr_path));
    if (hostfxr == NULL) {
        OH_LOG_ERROR(LOG_APP, "[openharmony-host] run_app: could not load libhostfxr.so (last tried %{public}s)",
                     hostfxr_path);
        return -1;
    }
    OH_LOG_INFO(LOG_APP, "[openharmony-host] run_app: loaded %{public}s", hostfxr_path);

    ohos_set_error_writer_fn set_error_writer =
        (ohos_set_error_writer_fn)dlsym(hostfxr, "hostfxr_set_error_writer");
    if (set_error_writer != NULL) {
        set_error_writer(ohos_error_writer);
    }

    // Preferred entry: same path the apphost uses; supports both framework-dependent
    // and self-contained runtimeconfigs, and runs the application's own Main.
    ohos_main_startupinfo_fn main_startupinfo =
        (ohos_main_startupinfo_fn)dlsym(hostfxr, "hostfxr_main_startupinfo");
    if (main_startupinfo != NULL) {
        const char** app_argv = (const char**)malloc((size_t)(argc + 1) * sizeof(const char*));
        if (app_argv == NULL) {
            return -1;
        }
        app_argv[0] = app_assembly_path;
        for (int i = 0; i < argc; i++) {
            app_argv[i + 1] = argv[i];
        }
        // Same contract as the apphost: dotnet_root comes from the environment (may
        // be NULL for self-contained apps), never from the app directory.
        const char* dotnet_root = getenv("DOTNET_ROOT");
        int exit_code = main_startupinfo(argc + 1, app_argv, app_dir, dotnet_root, app_assembly_path);
        free((void*)app_argv);
        OH_LOG_INFO(LOG_APP, "[openharmony-host] run_app Main exited rc=%{public}d", exit_code);
        return exit_code;
    }

    // Fallback: component hosting (framework-dependent only; self-contained components
    // are not supported by hostfxr). Used when the application publishes a managed
    // entry point through Microsoft.OpenHarmony.Hosting instead of Main.
    ohos_initialize_for_runtime_config_fn initialize =
        (ohos_initialize_for_runtime_config_fn)dlsym(hostfxr, "hostfxr_initialize_for_runtime_config");
    ohos_get_runtime_delegate_fn get_delegate =
        (ohos_get_runtime_delegate_fn)dlsym(hostfxr, "hostfxr_get_runtime_delegate");
    ohos_close_fn close_ctx = (ohos_close_fn)dlsym(hostfxr, "hostfxr_close");
    if (initialize == NULL || get_delegate == NULL || close_ctx == NULL) {
        // Name the missing exports: the dlopen succeeded but the library is not the expected
        // hostfxr, so the device log has to say which entry points are absent (the dlopen
        // failure path above already carries dlerror()).
        fprintf(stderr, "[openharmony-host] hostfxr symbols missing in %s (initialize=%s delegate=%s close=%s)\n",
                hostfxr_path, initialize == NULL ? "missing" : "ok",
                get_delegate == NULL ? "missing" : "ok", close_ctx == NULL ? "missing" : "ok");
        OH_LOG_ERROR(LOG_APP,
                     "[openharmony-host] run_app: hostfxr exports missing in %{public}s "
                     "(initialize_for_runtime_config=%{public}s get_runtime_delegate=%{public}s close=%{public}s)",
                     hostfxr_path, initialize == NULL ? "missing" : "ok",
                     get_delegate == NULL ? "missing" : "ok", close_ctx == NULL ? "missing" : "ok");
        return -1;
    }

    char runtime_config_path[4096];
    {
        const char* dot = strrchr(app_assembly_file, '.');
        size_t stem_len = dot != NULL ? (size_t)(dot - app_assembly_file) : strlen(app_assembly_file);
        int written = snprintf(runtime_config_path, sizeof(runtime_config_path), "%s/%.*s.runtimeconfig.json",
                               app_dir, (int)stem_len, app_assembly_file);
        if (written <= 0 || (size_t)written >= sizeof(runtime_config_path)) {
            return -1;
        }
    }

    char hosting_assembly_path[4096];
    if (path_join(hosting_assembly_path, sizeof(hosting_assembly_path), app_dir, "Microsoft.OpenHarmony.Hosting.dll") != 0) {
        return -1;
    }

    ohos_hostfxr_initialize_parameters params;
    params.size = sizeof(params);
    params.host_path = app_dir;
    params.dotnet_root = app_dir;

    void* ctx = NULL;
    int rc = initialize(runtime_config_path, &params, &ctx);
    if (rc != 0 || ctx == NULL) {
        fprintf(stderr, "[openharmony-host] hostfxr_initialize_for_runtime_config rc=0x%x\n", rc);
        return -1;
    }

    void* loader = NULL;
    rc = get_delegate(ctx, OHOS_HDT_LOAD_ASSEMBLY_AND_GET_FUNCTION_POINTER, &loader);
    if (rc != 0 || loader == NULL) {
        fprintf(stderr, "[openharmony-host] get_runtime_delegate rc=0x%x\n", rc);
        close_ctx(ctx);
        return -1;
    }

    void* entry = NULL;
    rc = ((ohos_load_assembly_and_get_function_pointer_fn)loader)(
        hosting_assembly_path,
        "Microsoft.OpenHarmony.Hosting.OpenHarmonyEntryPoint, Microsoft.OpenHarmony.Hosting",
        "openharmony_app_main", NULL, NULL, &entry);
    if (rc != 0 || entry == NULL) {
        fprintf(stderr, "[openharmony-host] get_function_pointer rc=0x%x\n", rc);
        close_ctx(ctx);
        return -1;
    }

    size_t payload_len = strlen(app_assembly_path) + 1;
    for (int i = 0; i < argc; i++) {
        payload_len += strlen(argv[i]) + 1;
    }
    char* payload = (char*)malloc(payload_len);
    if (payload == NULL) {
        close_ctx(ctx);
        return -1;
    }
    char* cursor = payload;
    cursor += sprintf(cursor, "%s", app_assembly_path);
    for (int i = 0; i < argc; i++) {
        cursor += sprintf(cursor, "\n%s", argv[i]);
    }

    int exit_code = ((int (*)(const char*))entry)(payload);
    free(payload);
    close_ctx(ctx);
    return exit_code;
}

// ---------------------------------------------------------------------------
// Bridged mode: the managed application is started through the command-line
// hostfxr entry point (self-contained friendly) and registers its callbacks
// back into this library; the shell pushes lifecycle/node events into them.
// ---------------------------------------------------------------------------

typedef int (*ohos_initialize_for_dotnet_command_line_fn)(int, const char* const*,
                                                          const ohos_hostfxr_initialize_parameters*,
                                                          void**);
typedef int (*ohos_run_app_fn)(void*);

#define OHOS_MAX_PENDING_LIFECYCLE 32

// Serializes the context slots (g_pending_context_json below and the handle's context_json)
// between the shell thread calling ohos_host_set_app_context and the launch thread running
// ohos_host_start_app. Without it the launch thread can read or free the pending snapshot
// while the setter replaces it (and the setter can free it under the reader).
static pthread_mutex_t g_context_mutex = PTHREAD_MUTEX_INITIALIZER;

// Retired context snapshots: a managed reader may still be copying the pointer returned by
// ohos_host_get_app_context when ohos_host_set_app_context replaces it, so replaced strings
// are retired and freed at join instead of being freed under the reader.
typedef struct OhosRetiredContext {
    char* json;
    struct OhosRetiredContext* next;
} OhosRetiredContext;

struct OhosHostAppHandle {
    void* hostfxr;
    void* ctx;
    int (*run_app)(void*);
    int (*close_ctx)(void*);
    pthread_t thread;
    int exit_code;
    int joined;
    char* context_json;
    OhosRetiredContext* retired_contexts;
    void* node_content;
    // Identity of the NodeContent the shell handed over. A page re-entry publishes a new
    // ArkUI NodeContent while the managed side still holds the previous one; the setter logs
    // the replacement so the rebind is visible in the device log, and the accessibility
    // provider uses the same identity to re-add its CUSTOM node to the new content.
    void* node_content_identity;
    void (*bridge_lifecycle)(int);
    void (*bridge_node)(void*);
    void (*bridge_surface)(void*, int, int, int);
    void (*bridge_touch)(int, float, float, int, int);
    void (*bridge_frame)(int64_t, int64_t);
    void (*bridge_text_input)(const char*);
    void (*bridge_text_submitted)(void);
    void (*bridge_keystore_result)(int request_id, int rc, const char* data_base64);
    void (*bridge_picker_result)(int request_id, int rc, const char* name, const char* data_base64);
    void (*bridge_web_event)(const char* state, const char* url);
    void (*bridge_permission_result)(int request_id, int granted);
    void (*bridge_notification_permission_result)(int request_id, int granted);
    void (*bridge_clipboard_result)(int request_id, int rc, const char* text);
    void (*bridge_clipboard_changed)(void);
    void (*bridge_geocode_result)(int request_id, int rc, const char* json);
    void (*bridge_raw_file_result)(int request_id, int rc, const char* data_base64);
    void (*bridge_raw_file_result_bytes)(int request_id, int rc, const unsigned char* data, size_t length);
    void (*bridge_network_access)(int level);
    void (*bridge_key_event)(int key_code, int event_type);
    void (*bridge_soft_input_change)(int bottom);
    void* surface_window;
    int surface_width;
    int surface_height;
    int surface_state;
    int pending_lifecycle[OHOS_MAX_PENDING_LIFECYCLE];
    int pending_count;
};

// One bridged application per process, matching the ArkTS one-ability model.
static OhosHostAppHandle* g_app = NULL;

// A context published before the app handle exists (the page can appear before the ability's
// bootstrap reaches start_app). start_app adopts this snapshot when it has no context of its
// own; an app-provided context always wins. Guarded by g_context_mutex: start_app takes the
// snapshot out of this slot before using it, so no reader can race a replacement free.
static char* g_pending_context_json = NULL;

// Lifecycle events and the NodeContent handle that arrive before an app handle exists (the
// shell can push ability events while the launch thread is still initializing the runtime).
// They are queued here and transferred to the handle when start_app publishes it, so the
// managed bridge still sees them once it registers. Guarded by g_context_mutex.
static int g_pending_lifecycle[OHOS_MAX_PENDING_LIFECYCLE];
static int g_pending_lifecycle_count = 0;
static void* g_pending_node_content = NULL;

// Bridge callbacks registered by the managed side while no app handle exists. start_app binds
// them to the handle when it publishes g_app (and flushes the queues above to them) instead of
// dropping the registration: the managed bridge registers once and never retries. Guarded by
// g_context_mutex like the queues above.
static void* g_pending_bridge_lifecycle = NULL;
static void* g_pending_bridge_node = NULL;
static void* g_pending_bridge_surface = NULL;

// Defined after the context helpers; used by the failed-launch cleanup in start_app.
static void OhosHostFreeRetiredContexts(OhosHostAppHandle* handle);

// start_app re-entry guard: one bridged application per process, and a second start while the
// first is still initializing would overwrite g_app and leak the first handle.
static int g_launch_in_progress = 0;

// Clears the re-entry guard after a failed launch. A successful launch keeps g_app set, which
// rejects a second start on its own.
static void OhosHostEndLaunch(void) {
    pthread_mutex_lock(&g_context_mutex);
    g_launch_in_progress = 0;
    pthread_mutex_unlock(&g_context_mutex);
}

// The XComponent may be created before the application handle exists, so keep the latest
// surface state here and forward it when the bridge registers.
static void* g_surface_window = NULL;
static int g_surface_width = 0;
static int g_surface_height = 0;
static int g_surface_state = -1;
static int g_surface_valid = 0;

static void* OhosAppThread(void* arg) {
    OhosHostAppHandle* handle = (OhosHostAppHandle*)arg;
    fprintf(stderr, "[openharmony-host] run_app entering\n");
    fflush(stderr);
    handle->exit_code = handle->run_app(handle->ctx);
    fprintf(stderr, "[openharmony-host] run_app exited: %d\n", handle->exit_code);
    fflush(stderr);
    OH_LOG_INFO(LOG_APP, "[openharmony-host] app Main exited rc=%{public}d", handle->exit_code);
    return NULL;
}

// Whether a context JSON names a payload directory: the "appDir" key is present and its value
// is a non-empty string. The shells emit compact JSON (JSON.stringify), so the textual check
// is enough to tell a real snapshot from the empty/placeholder one; a false negative only
// keeps the start context (the managed parser still sees both sources).
static int OhosHostContextNamesAppDir(const char* json) {
    if (json == NULL) {
        return 0;
    }
    const char* key = strstr(json, "\"appDir\"");
    if (key == NULL) {
        return 0;
    }
    const char* colon = strchr(key + 8, ':');
    if (colon == NULL) {
        return 0;
    }
    const char* value = colon + 1;
    while (*value == ' ' || *value == '\t' || *value == '\n' || *value == '\r') {
        value++;
    }
    if (*value != '"') {
        return 0;
    }
    value++;
    return *value != '"' && *value != '\0';
}

// Binds a bridge registration to a live handle and delivers everything the handle queued
// before it: the pre-publish lifecycle queue, the pending NodeContent and the current surface.
// The queue fields are copied and cleared under g_context_mutex; the node content is taken over
// and its slot cleared, so a second registration (Attach is one-shot, but a re-register must
// not double-attach) cannot deliver it twice. The managed callbacks run after the unlock: a
// callback may re-enter any host entry, and g_context_mutex never nests and is never held
// across a managed callback (the a11y path uses its own g_a11y_mutex, never this one).
static void OhosHostBindAndFlushBridge(OhosHostAppHandle* handle, void* lifecycle, void* node, void* surface) {
    int pending[OHOS_MAX_PENDING_LIFECYCLE];
    int pending_count = 0;
    void* node_content = NULL;
    int has_surface = 0;
    void* surface_window = NULL;
    int surface_width = 0;
    int surface_height = 0;
    int surface_state = -1;
    pthread_mutex_lock(&g_context_mutex);
    if (handle == NULL || g_app != handle) {
        // Joined (or never published): do not touch the handle, it is not ours anymore.
        pthread_mutex_unlock(&g_context_mutex);
        return;
    }
    handle->bridge_lifecycle = (void (*)(int))lifecycle;
    handle->bridge_node = (void (*)(void*))node;
    handle->bridge_surface = (void (*)(void*, int, int, int))surface;
    pending_count = handle->pending_count;
    for (int i = 0; i < pending_count; i++) {
        pending[i] = handle->pending_lifecycle[i];
    }
    handle->pending_count = 0;
    if (node != NULL && handle->node_content != NULL) {
        node_content = handle->node_content;
        handle->node_content = NULL;
    }
    if (surface != NULL && g_surface_valid) {
        has_surface = 1;
        surface_window = g_surface_window;
        surface_width = g_surface_width;
        surface_height = g_surface_height;
        surface_state = g_surface_state;
    }
    pthread_mutex_unlock(&g_context_mutex);
    if (has_surface) {
        ((void (*)(void*, int, int, int))surface)(surface_window, surface_width, surface_height, surface_state);
    }
    for (int i = 0; i < pending_count; i++) {
        if (lifecycle != NULL) {
            ((void (*)(int))lifecycle)(pending[i]);
        }
    }
    if (node != NULL && node_content != NULL) {
        ((void (*)(void*))node)(node_content);
    }
}

int ohos_host_start_app(const char* app_dir, const char* app_assembly_file,
                        const char* args_json, const char* context_json,
                        OhosHostAppHandle** out_handle) {
    OH_LOG_INFO(LOG_APP, "[openharmony-host] start_app begin dir=%{public}s", app_dir != NULL ? app_dir : "(null)");
    // Reject a second start up front: one bridged application per process (g_app), and until
    // the first launch publishes its handle the guard keeps two launch threads from racing
    // g_app/g_pending_context_json. No state is allocated on a rejected call.
    pthread_mutex_lock(&g_context_mutex);
    if (g_app != NULL || g_launch_in_progress) {
        pthread_mutex_unlock(&g_context_mutex);
        fprintf(stderr, "[openharmony-host] start_app: an app is already running or launching\n");
        return -1;
    }
    g_launch_in_progress = 1;
    pthread_mutex_unlock(&g_context_mutex);

    char hostfxr_path[4096];
    char app_assembly_path[4096];
    char own_dir[4096];
    int used_own = 0;
    const char* effective_app_dir =
        OhosHostResolveAppDir("start_app", app_dir, app_assembly_file, own_dir, sizeof(own_dir), &used_own);
    if (effective_app_dir == NULL) {
        OhosHostEndLaunch();
        return -1;
    }
    if (path_join(app_assembly_path, sizeof(app_assembly_path), effective_app_dir, app_assembly_file) != 0) {
        OhosHostEndLaunch();
        return -1;
    }

    // Same bridge as run_app: hostfxr loads hostpolicy next to the app config and hostpolicy
    // builds '<app_dir>/libcoreclr.so', so app_dir must expose the signed libs/<abi>/ files
    // before initialize (best effort, never fails the launch). When the payload ships in
    // libs/<abi>/ the effective app_dir IS the staged directory and there is nothing to bridge.
    if (!used_own) {
        OhosHostEnsureRuntimeLibs("start_app", effective_app_dir);
    }

    // Pin the executable-memory policy (and probe it once) before hostfxr can start coreclr.
    // The start context carries filesDir on every current shell, so the A/B file and the probe
    // status line land in the app sandbox; a pending context adopted below is re-applied.
    OhosHostApplyExecMemoryPolicy("start_app", effective_app_dir, context_json);

    // Bridged start_app needs the managed bridge (register_bridge calls from the hosting
    // assembly), which a NativeAOT app only provides through its own export and handle
    // management; until that route is designed (FIX-INTEROP #2 documents the one-shot AOT
    // route in run_app), fail with an explicit message instead of a generic hostfxr error.
    char aot_lib_path[4096];
    if (OhosHostAotLibPath(aot_lib_path, sizeof(aot_lib_path), effective_app_dir, app_assembly_file) == 0 &&
        access(aot_lib_path, F_OK) == 0) {
        OH_LOG_ERROR(LOG_APP,
                     "[openharmony-host] start_app: NativeAOT payload %{public}s requires the one-shot "
                     "run_app route; bridged start_app supports JIT payloads only", aot_lib_path);
        OhosHostEndLaunch();
        return -1;
    }

    void* hostfxr = OhosHostOpenHostfxr("start_app", effective_app_dir, hostfxr_path, sizeof(hostfxr_path));
    if (hostfxr == NULL) {
        OH_LOG_ERROR(LOG_APP, "[openharmony-host] start_app: could not load libhostfxr.so (last tried %{public}s)",
                     hostfxr_path);
        OhosHostEndLaunch();
        return -1;
    }
    OH_LOG_INFO(LOG_APP, "[openharmony-host] start_app: loaded %{public}s", hostfxr_path);

    ohos_set_error_writer_fn set_error_writer = (ohos_set_error_writer_fn)dlsym(hostfxr, "hostfxr_set_error_writer");
    if (set_error_writer != NULL) {
        set_error_writer(ohos_error_writer);
    }

    ohos_initialize_for_dotnet_command_line_fn initialize =
        (ohos_initialize_for_dotnet_command_line_fn)dlsym(hostfxr, "hostfxr_initialize_for_dotnet_command_line");
    ohos_close_fn close_ctx = (ohos_close_fn)dlsym(hostfxr, "hostfxr_close");
    ohos_run_app_fn run_app = (ohos_run_app_fn)dlsym(hostfxr, "hostfxr_run_app");
    if (initialize == NULL || close_ctx == NULL || run_app == NULL) {
        // Same contract as run_app: the dlopen handle exists but an entry point is missing, so
        // the log names every export the bridged launch needs.
        fprintf(stderr, "[openharmony-host] hostfxr symbols missing in %s (initialize=%s close=%s run_app=%s)\n",
                hostfxr_path, initialize == NULL ? "missing" : "ok",
                close_ctx == NULL ? "missing" : "ok", run_app == NULL ? "missing" : "ok");
        OH_LOG_ERROR(LOG_APP,
                     "[openharmony-host] start_app: hostfxr exports missing in %{public}s "
                     "(initialize_for_dotnet_command_line=%{public}s close=%{public}s run_app=%{public}s)",
                     hostfxr_path, initialize == NULL ? "missing" : "ok",
                     close_ctx == NULL ? "missing" : "ok", run_app == NULL ? "missing" : "ok");
        OhosHostEndLaunch();
        return -1;
    }

    // A context published before this call (ohos_host_set_app_context while no handle
    // existed) supersedes a start context that is absent or does not name a payload
    // directory: the page can publish before the ability's bootstrap reaches start_app, and
    // the stale start context must not overwrite the explicit publish. The adoption itself
    // happens below, after initialize, under g_context_mutex.
    const char* effective_context = context_json;
    if (effective_context != NULL && effective_context[0] == '\0') {
        effective_context = NULL;
    }

    const char* argv[1] = {app_assembly_path};
    ohos_hostfxr_initialize_parameters params;
    params.size = sizeof(params);
    params.host_path = effective_app_dir;
    params.dotnet_root = getenv("DOTNET_ROOT");

    void* ctx = NULL;
    int rc = initialize(1, argv, &params, &ctx);
    if (rc != 0 || ctx == NULL) {
        fprintf(stderr, "[openharmony-host] initialize_for_dotnet_command_line rc=0x%x\n", rc);
        OH_LOG_ERROR(LOG_APP, "[openharmony-host] start_app: hostfxr command-line init rc=0x%{public}x dir=%{public}s",
                     (unsigned)rc, effective_app_dir != NULL ? effective_app_dir : "(null)");
        OhosHostEndLaunch();
        return -1;
    }

    OhosHostAppHandle* handle = (OhosHostAppHandle*)calloc(1, sizeof(OhosHostAppHandle));
    if (handle == NULL) {
        close_ctx(ctx);
        OhosHostEndLaunch();
        return -1;
    }
    handle->hostfxr = hostfxr;
    handle->ctx = ctx;
    handle->run_app = run_app;
    handle->close_ctx = close_ctx;
    (void)args_json;
    // Resolve the pending context and publish the handle under one lock: a set_app_context
    // that ran before this critical section left its snapshot in the pending slot and is
    // adopted (or freed as superseded) here, one that runs after sees g_app and retires the
    // handle snapshot instead. The launch thread never touches the pending slot outside the
    // lock, so no reader can race a replacement free.
    pthread_mutex_lock(&g_context_mutex);
    char* adopted_pending = NULL;
    if (g_pending_context_json != NULL &&
        (effective_context == NULL || !OhosHostContextNamesAppDir(effective_context))) {
        adopted_pending = g_pending_context_json;
        g_pending_context_json = NULL;
        effective_context = adopted_pending;
    } else if (g_pending_context_json != NULL) {
        // Superseded by a start context that names a payload directory; free it here while
        // the lock guarantees no reader can hold it.
        free(g_pending_context_json);
        g_pending_context_json = NULL;
    }
    if (effective_context != NULL) {
        setenv("OHOS_HOST_APP_CONTEXT", effective_context, 1);
        handle->context_json = strdup(effective_context);
    }
    // The pending snapshot was adopted or superseded; the handle owns its own copy now.
    free(adopted_pending);
    // Events that arrived before the handle existed are transferred to it here (the managed
    // bridge cannot have registered yet: register_bridge requires g_app), and any later event
    // goes straight to the handle's own queue.
    handle->pending_count = g_pending_lifecycle_count;
    for (int i = 0; i < g_pending_lifecycle_count; i++) {
        handle->pending_lifecycle[i] = g_pending_lifecycle[i];
    }
    g_pending_lifecycle_count = 0;
    if (g_pending_node_content != NULL) {
        handle->node_content = g_pending_node_content;
        g_pending_node_content = NULL;
        handle->node_content_identity = handle->node_content;
    }
    // A bridge registered before this handle existed is bound atomically with the publish, so
    // a racing notify sees the real callbacks and never queues an event behind a registration
    // that already happened. The callback values are captured for the post-create flush below
    // and for the failed-launch path, which hands them back for a retry.
    void* pending_lifecycle_cb = g_pending_bridge_lifecycle;
    void* pending_node_cb = g_pending_bridge_node;
    void* pending_surface_cb = g_pending_bridge_surface;
    g_pending_bridge_lifecycle = NULL;
    g_pending_bridge_node = NULL;
    g_pending_bridge_surface = NULL;
    handle->bridge_lifecycle = (void (*)(int))pending_lifecycle_cb;
    handle->bridge_node = (void (*)(void*))pending_node_cb;
    handle->bridge_surface = (void (*)(void*, int, int, int))pending_surface_cb;
    int pending_bridge = pending_lifecycle_cb != NULL || pending_node_cb != NULL || pending_surface_cb != NULL;
    g_app = handle;
    g_launch_in_progress = 0;
    pthread_mutex_unlock(&g_context_mutex);

    // An adopted pending context can be the first source of filesDir (the page published before
    // the ability bootstrap reached start_app). Re-apply the policy with the final snapshot so
    // the A/B file is honored; the probe already ran once on the early call.
    if (handle->context_json != NULL &&
        (context_json == NULL || strcmp(handle->context_json, context_json) != 0)) {
        OhosHostApplyExecMemoryPolicy("start_app", effective_app_dir, handle->context_json);
    }

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_JOINABLE);
    const char* run_sync = getenv("OHOS_HOST_RUN_SYNC");
    if (run_sync != NULL && run_sync[0] == '1') {
        fprintf(stderr, "[openharmony-host] start_app: running the app on the calling thread\n");
        fflush(stderr);
        if (pending_bridge) {
            OhosHostBindAndFlushBridge(handle, pending_lifecycle_cb, pending_node_cb, pending_surface_cb);
        }
        // Hand the handle out first so the shell can push events while the app runs.
        *out_handle = handle;
        handle->exit_code = run_app(ctx);
        handle->joined = 1;
        return 0;
    }
    fprintf(stderr, "[openharmony-host] start_app: launching app thread\n");
    fflush(stderr);
    int thread_rc = pthread_create(&handle->thread, &attr, OhosAppThread, handle);
    pthread_attr_destroy(&attr);
    if (thread_rc != 0) {
        fprintf(stderr, "[openharmony-host] pthread_create failed: %d\n", thread_rc);
        char* context_json = NULL;
        pthread_mutex_lock(&g_context_mutex);
        if (g_app == handle) {
            g_app = NULL;
        }
        // The launch must not consume what it transferred: hand the queued events and the
        // NodeContent back to the pending slots the next start_app adopts, and requeue a
        // pre-launch bridge registration too (the managed side never re-registers it).
        for (int i = 0; i < handle->pending_count && g_pending_lifecycle_count < OHOS_MAX_PENDING_LIFECYCLE; i++) {
            g_pending_lifecycle[g_pending_lifecycle_count++] = handle->pending_lifecycle[i];
        }
        handle->pending_count = 0;
        if (handle->node_content != NULL) {
            g_pending_node_content = handle->node_content;
            handle->node_content = NULL;
        }
        if (pending_bridge) {
            g_pending_bridge_lifecycle = pending_lifecycle_cb;
            g_pending_bridge_node = pending_node_cb;
            g_pending_bridge_surface = pending_surface_cb;
        }
        context_json = handle->context_json;
        handle->context_json = NULL;
        OhosHostFreeRetiredContexts(handle);
        pthread_mutex_unlock(&g_context_mutex);
        close_ctx(ctx);
        free(context_json);
        free(handle);
        return -1;
    }
    if (pending_bridge) {
        // The app thread is live: deliver what the handle queued before the registration was
        // published, exactly like a register_bridge call would.
        OhosHostBindAndFlushBridge(handle, pending_lifecycle_cb, pending_node_cb, pending_surface_cb);
    }

    OH_LOG_INFO(LOG_APP, "[openharmony-host] start_app launched dir=%{public}s", app_dir != NULL ? app_dir : "(null)");
    *out_handle = handle;
    return 0;
}

const char* ohos_host_get_app_context(void) {
    // The snapshot is replaced under g_context_mutex (set_app_context) and freed under it at
    // join, so the getter reads the handle under the same lock. The returned pointer follows
    // the documented contract: owned by the handle, valid until the next publish or join.
    pthread_mutex_lock(&g_context_mutex);
    const char* json = g_app != NULL ? g_app->context_json : NULL;
    pthread_mutex_unlock(&g_context_mutex);
    return json;
}

// Keeps a replaced snapshot alive until join: a managed reader may be copying the string the
// getter returned when the replacement lands. If the bookkeeping node cannot be allocated the
// snapshot is leaked instead of freed under the reader - the safer failure mode.
static void OhosHostRetireContextSnapshot(OhosHostAppHandle* handle, char* json) {
    if (handle == NULL || json == NULL) {
        return;
    }
    OhosRetiredContext* retired = (OhosRetiredContext*)malloc(sizeof(OhosRetiredContext));
    if (retired == NULL) {
        fprintf(stderr, "[openharmony-host] set_app_context: retire node alloc failed; keeping the old snapshot\n");
        return;
    }
    retired->json = json;
    retired->next = handle->retired_contexts;
    handle->retired_contexts = retired;
}

static void OhosHostFreeRetiredContexts(OhosHostAppHandle* handle) {
    OhosRetiredContext* retired = handle->retired_contexts;
    handle->retired_contexts = NULL;
    while (retired != NULL) {
        OhosRetiredContext* next = retired->next;
        free(retired->json);
        free(retired);
        retired = next;
    }
}

// Replays the stored surface state to the registered managed bridge. The managed surface
// callback re-reads the app context before it forwards the event
// (OpenHarmonyBridge.OnSurfaceNative -> RefreshContext), so this is the notification path a
// context re-publish rides. Returns 1 when the bridge callback was invoked.
static int OhosHostReplaySurfaceNotification(void) {
    if (g_app == NULL || g_app->bridge_surface == NULL || !g_surface_valid) {
        return 0;
    }
    if (g_surface_state != (int)OHOS_SURFACE_CREATED && g_surface_state != (int)OHOS_SURFACE_CHANGED) {
        // Only a live surface carries the event the managed side refreshes on; a destroyed
        // one must not be replayed, and the next created/changed event re-reads anyway.
        return 0;
    }
    g_app->bridge_surface(g_surface_window, g_surface_width, g_surface_height, g_surface_state);
    return 1;
}

int ohos_host_notify_context(void) {
    return OhosHostReplaySurfaceNotification();
}

// ---------------------------------------------------------------------------
// Bundle metadata (Essentials IAppInfo version/build/name): the shell publishes the HAP's
// real values once at page load; the managed side reads stored copies.
// ---------------------------------------------------------------------------

static pthread_mutex_t g_bundle_info_mutex = PTHREAD_MUTEX_INITIALIZER;
static char* g_bundle_version = NULL;
static char* g_bundle_build = NULL;
static char* g_bundle_name = NULL;

// The getters hand out a copy in per-thread storage instead of the stored pointer, so a
// re-publish (a page re-entry calls setBundleInfo again) can free the replaced string under
// the mutex without invalidating a reader that is still copying it. The three fields live in
// one per-thread set so the three getters can be used together; the storage hangs off a
// pthread key (freed on thread exit) like the accessibility copies, for dlopen'ed-library
// portability (no __thread/emutls relocations). A thread that cannot have copies gets "".
#define OHOS_BUNDLE_FIELD_COUNT 3

typedef struct OhosBundleCopySet {
    char* fields[OHOS_BUNDLE_FIELD_COUNT];
    size_t sizes[OHOS_BUNDLE_FIELD_COUNT];
} OhosBundleCopySet;

static pthread_key_t g_bundle_copy_key;
static pthread_once_t g_bundle_copy_once = PTHREAD_ONCE_INIT;
static int g_bundle_copy_key_ready = 0;

static void OhosBundleCopySetDestroy(void* value) {
    OhosBundleCopySet* set = (OhosBundleCopySet*)value;
    if (set == NULL) {
        return;
    }
    for (int i = 0; i < OHOS_BUNDLE_FIELD_COUNT; i++) {
        free(set->fields[i]);
    }
    free(set);
}

static void OhosBundleCopyKeyInit(void) {
    g_bundle_copy_key_ready = pthread_key_create(&g_bundle_copy_key, OhosBundleCopySetDestroy) == 0;
}

// Replaces one field and frees the string it replaces (the readers copy under the same mutex,
// so no reader can hold the old pointer any more). Caller does not hold the mutex.
static void OhosHostStoreBundleField(char** slot, const char* value) {
    char* copy = NULL;
    if (value != NULL && value[0] != '\0') {
        copy = strdup(value);
        if (copy == NULL) {
            return;
        }
    }
    pthread_mutex_lock(&g_bundle_info_mutex);
    free(*slot);
    *slot = copy;
    pthread_mutex_unlock(&g_bundle_info_mutex);
}

int ohos_host_set_bundle_info(const char* version, const char* build, const char* name) {
    if (version == NULL || version[0] == '\0' || build == NULL || build[0] == '\0') {
        fprintf(stderr, "[openharmony-host] set_bundle_info: version/build are required\n");
        return -1;
    }
    OhosHostStoreBundleField(&g_bundle_version, version);
    OhosHostStoreBundleField(&g_bundle_build, build);
    OhosHostStoreBundleField(&g_bundle_name, name);
    fprintf(stderr, "[openharmony-host] set_bundle_info: version=%s build=%s\n", version, build);
    return 0;
}

// Copies the named field into the calling thread's set and returns that stable pointer ("" 
// when the field is unset or the per-thread copy cannot be made). The stored string is read
// and copied under the mutex, so the store path may free a replaced value in place.
static const char* OhosHostReadBundleField(char** slot) {
    pthread_once(&g_bundle_copy_once, OhosBundleCopyKeyInit);
    int index = slot == &g_bundle_version ? 0 : (slot == &g_bundle_build ? 1 : 2);
    const char* result = "";
    pthread_mutex_lock(&g_bundle_info_mutex);
    const char* value = *slot != NULL ? *slot : "";
    if (value[0] != '\0' && g_bundle_copy_key_ready) {
        OhosBundleCopySet* set = (OhosBundleCopySet*)pthread_getspecific(g_bundle_copy_key);
        if (set == NULL) {
            set = (OhosBundleCopySet*)calloc(1, sizeof(OhosBundleCopySet));
            if (set != NULL && pthread_setspecific(g_bundle_copy_key, set) != 0) {
                free(set);
                set = NULL;
            }
        }
        if (set != NULL) {
            size_t length = strlen(value) + 1;
            if (set->sizes[index] < length) {
                char* grown = (char*)realloc(set->fields[index], length);
                if (grown != NULL) {
                    set->fields[index] = grown;
                    set->sizes[index] = length;
                }
            }
            if (set->fields[index] != NULL && set->sizes[index] >= length) {
                memcpy(set->fields[index], value, length);
                result = set->fields[index];
            }
        }
    }
    pthread_mutex_unlock(&g_bundle_info_mutex);
    return result;
}

const char* ohos_host_get_bundle_version(void) {
    return OhosHostReadBundleField(&g_bundle_version);
}

const char* ohos_host_get_bundle_build(void) {
    return OhosHostReadBundleField(&g_bundle_build);
}

const char* ohos_host_get_bundle_name(void) {
    return OhosHostReadBundleField(&g_bundle_name);
}

int ohos_host_set_app_context(const char* json) {
    if (json == NULL || json[0] == '\0') {
        fprintf(stderr, "[openharmony-host] set_app_context: empty context ignored\n");
        return -1;
    }
    char* copy = strdup(json);
    if (copy == NULL) {
        return -1;
    }
    // The pending-vs-live decision is taken under g_context_mutex: start_app publishes g_app
    // under the same lock, so a publish racing the launch either lands in the pending slot the
    // launch adopts or replaces the handle snapshot, never a mix of both.
    pthread_mutex_lock(&g_context_mutex);
    if (g_app == NULL) {
        // No handle yet: keep the snapshot for the next start_app, which adopts it only when
        // it has no context of its own. The lock makes this replacement atomic with the
        // launch thread's adoption in start_app, which takes the pointer out of the slot
        // before using it, so the pending copy has no concurrent reader here.
        free(g_pending_context_json);
        g_pending_context_json = copy;
        pthread_mutex_unlock(&g_context_mutex);
        fprintf(stderr, "[openharmony-host] set_app_context: kept %d bytes for the next start_app\n",
                (int)strlen(copy));
        return 0;
    }
    setenv("OHOS_HOST_APP_CONTEXT", copy, 1);
    OhosHostRetireContextSnapshot(g_app, g_app->context_json);
    g_app->context_json = copy;
    pthread_mutex_unlock(&g_context_mutex);
    int notified = OhosHostReplaySurfaceNotification();
    fprintf(stderr, "[openharmony-host] set_app_context: %d bytes, notified=%d\n",
            (int)strlen(copy), notified);
    return 0;
}

void ohos_host_register_bridge(void* lifecycle, void* node, void* surface) {
    fprintf(stderr, "[openharmony-host] register_bridge lifecycle=%p node=%p surface=%p g_app=%p\n",
            lifecycle, node, surface, (void*)g_app);
    fflush(stderr);
    pthread_mutex_lock(&g_context_mutex);
    OhosHostAppHandle* handle = g_app;
    if (handle == NULL) {
        // The managed side can register before start_app publishes the handle (this used to be
        // a silent no-op the managed bridge never retries). Queue the callbacks like the
        // lifecycle/node-content queues; start_app binds and flushes them on publish.
        g_pending_bridge_lifecycle = lifecycle;
        g_pending_bridge_node = node;
        g_pending_bridge_surface = surface;
        pthread_mutex_unlock(&g_context_mutex);
        return;
    }
    pthread_mutex_unlock(&g_context_mutex);
    // Bind and flush under the queue lock; the callbacks themselves run outside it.
    OhosHostBindAndFlushBridge(handle, lifecycle, node, surface);
}

// --- surface buffer presentation cache --------------------------------------------
// The XComponent surface presents into a native window whose gralloc buffers are stable
// while that window lives, so the fd-backed mapping is cached instead of being rebuilt every
// frame, and the buffer geometry/format/usage are only re-applied when the window or its size
// changed (they are driver-level calls). The cache key is (window, pool generation, fd, size):
// the window and the generation keep a mapping from ever matching another surface's pool, and
// the slot owns a dup() of the buffer fd, so a closed-and-reused fd number from the graphics
// stack cannot alias an old mapping. Mappings are dropped when the window is replaced or
// destroyed or when the geometry changes.
#define OHOS_PRESENT_MAP_MAX 8
typedef struct {
    int fd;              // owned duplicate of the buffer fd; -1 when the slot holds no mapping
    size_t size;
    void* addr;
    void* window;        // the native window the mapping was created for
    uint64_t generation; // g_present_map_generation at insert time (bumped on every invalidation)
    uint64_t last_used;
} OhosPresentMapping;

static OhosPresentMapping g_present_maps[OHOS_PRESENT_MAP_MAX];
static uint64_t g_present_map_clock = 0;
static uint64_t g_present_map_generation = 0;
static void* g_native_window_configured = NULL;
static int g_native_window_width = 0;
static int g_native_window_height = 0;

static void OhosHostPresentMapReleaseAll(void) {
    // Bumping the generation first makes every old entry unmatchable even before it is
    // evicted, so a concurrent frame can never pick up a mapping of the previous pool.
    g_present_map_generation++;
    for (int i = 0; i < OHOS_PRESENT_MAP_MAX; i++) {
        if (g_present_maps[i].addr != NULL) {
            munmap(g_present_maps[i].addr, g_present_maps[i].size);
            g_present_maps[i].addr = NULL;
            g_present_maps[i].size = 0;
        }
        if (g_present_maps[i].fd >= 0) {
            close(g_present_maps[i].fd);
        }
        g_present_maps[i].fd = -1;
        g_present_maps[i].window = NULL;
        g_present_maps[i].generation = 0;
    }
    g_present_map_clock = 0;
}

// Forget which options were last applied to the window; the next configure re-applies them.
static void OhosHostNativeWindowInvalidate(void) {
    g_native_window_configured = NULL;
    g_native_window_width = 0;
    g_native_window_height = 0;
}

// Applies geometry/format/usage only when the window or its size changed. On failure the
// cached state stays invalid so the next frame retries.
static int OhosHostNativeWindowConfigure(void* window, int width, int height) {
    if (!ohos_host_optional_native_window_available()) {
        return -1;  // reported once by the optional-library loader; drawing stays disabled
    }
    if (g_native_window_configured == window && g_native_window_width == width &&
        g_native_window_height == height) {
        return 0;
    }
    if (g_native_window_configured != NULL) {
        // A different shape cannot be served by the mappings of the previous one.
        OhosHostPresentMapReleaseAll();
    }
    uint64_t usage = NATIVEBUFFER_USAGE_CPU_WRITE | NATIVEBUFFER_USAGE_MEM_DMA;
    if (ohos_host_optional_native_window_set_geometry((OHNativeWindow*)window, width, height) != 0 ||
        ohos_host_optional_native_window_set_format((OHNativeWindow*)window,
                                                    NATIVEBUFFER_PIXEL_FMT_RGBA_8888) != 0 ||
        ohos_host_optional_native_window_set_usage((OHNativeWindow*)window, usage) != 0) {
        OhosHostNativeWindowInvalidate();
        return -1;
    }
    g_native_window_configured = window;
    g_native_window_width = width;
    g_native_window_height = height;
    return 0;
}

// Borrowed mapping of the buffer, cached across frames; NULL when the mmap/dup fails (the
// caller still flushes the buffer, it just does not write pixels into it). The cache owns the
// dup'd fd, so it must be released through OhosHostPresentMapReleaseAll (or overridden by a
// newer mapping in the same slot), never by the caller.
static void* OhosHostPresentMapAcquire(void* window, int fd, const void* hint, size_t size) {
    if (window == NULL || fd < 0 || size == 0) {
        return NULL;
    }
    int slot = -1;
    for (int i = 0; i < OHOS_PRESENT_MAP_MAX; i++) {
        OhosPresentMapping* mapping = &g_present_maps[i];
        if (mapping->addr == NULL) {
            if (slot < 0) {
                slot = i;
            }
            continue;
        }
        if (mapping->window == window && mapping->generation == g_present_map_generation &&
            mapping->fd == fd && mapping->size == size) {
            mapping->last_used = ++g_present_map_clock;
            return mapping->addr;
        }
    }
    if (slot < 0) {
        uint64_t oldest = UINT64_MAX;
        for (int i = 0; i < OHOS_PRESENT_MAP_MAX; i++) {
            if (g_present_maps[i].last_used < oldest) {
                oldest = g_present_maps[i].last_used;
                slot = i;
            }
        }
    }
    if (slot < 0) {
        return NULL;
    }
    OhosPresentMapping* mapping = &g_present_maps[slot];
    if (mapping->addr != NULL) {
        munmap(mapping->addr, mapping->size);
        mapping->addr = NULL;
        mapping->size = 0;
    }
    if (mapping->fd >= 0) {
        close(mapping->fd);
        mapping->fd = -1;
    }
    int owned_fd = dup(fd);
    if (owned_fd < 0) {
        return NULL;
    }
    void* addr = mmap((void*)hint, size, PROT_READ | PROT_WRITE, MAP_SHARED, owned_fd, 0);
    if (addr == MAP_FAILED) {
        close(owned_fd);
        mapping->window = NULL;
        mapping->generation = 0;
        return NULL;
    }
    mapping->fd = owned_fd;
    mapping->size = size;
    mapping->addr = addr;
    mapping->window = window;
    mapping->generation = g_present_map_generation;
    mapping->last_used = ++g_present_map_clock;
    return addr;
}

// Copies the packed bitmap rows into a mapped buffer. When the buffer stride matches the
// packed row size this is a single memcpy; otherwise rows are copied one by one. Every
// write stays inside map_size: a handle whose size does not cover the rows (or a bogus
// stride) leaves the rest of the frame untouched instead of writing past the mapping.
static void OhosHostPresentCopyRows(void* dst_ptr, size_t dst_stride, const void* src_ptr,
                                    size_t row_bytes, int rows, size_t map_size) {
    uint8_t* dst = (uint8_t*)dst_ptr;
    const uint8_t* src = (const uint8_t*)src_ptr;
    if (dst_stride == row_bytes) {
        const size_t total = row_bytes * (size_t)rows;
        if (total <= map_size) {
            memcpy(dst, src, total);
        }
        return;
    }
    const size_t copy = row_bytes <= dst_stride ? row_bytes : dst_stride;
    for (int y = 0; y < rows; y++) {
        const size_t offset = (size_t)y * dst_stride;
        if (offset + copy > map_size) {
            break;
        }
        memcpy(dst + offset, src + (size_t)y * row_bytes, copy);
    }
}

// Pairs one RequestBuffer with exactly one FlushBuffer on every exit path: the constructor
// requests, the destructor flushes, so a frame that cannot be filled (a failed mapping, a
// missing handle) still returns the buffer to the graphics stack. The mapping half of the same
// ownership is OhosHostPresentMapAcquire, whose key (window, generation, fd, size) plus the
// slot-owned dup keep a stale mapping from matching a reused fd.
class OhosPresentFrame {
public:
    OhosPresentFrame(OHNativeWindow* window, bool request) : window_(window) {
        if (request &&
            OH_NativeWindow_NativeWindowRequestBuffer(window_, &buffer_, &fence_) != 0) {
            buffer_ = nullptr;
        }
    }
    ~OhosPresentFrame() {
        if (buffer_ != nullptr) {
            Region region = { NULL, 0 };
            OH_NativeWindow_NativeWindowFlushBuffer(window_, buffer_, fence_, region);
        }
    }
    OhosPresentFrame(const OhosPresentFrame&) = delete;
    OhosPresentFrame& operator=(const OhosPresentFrame&) = delete;
    bool valid() const { return buffer_ != nullptr; }
    OHNativeWindowBuffer* buffer() const { return buffer_; }
    BufferHandle* handle() const {
        return buffer_ != nullptr ? OH_NativeWindow_GetBufferHandleFromNative(buffer_) : nullptr;
    }

private:
    OHNativeWindow* window_ = nullptr;
    OHNativeWindowBuffer* buffer_ = nullptr;
    int fence_ = -1;
};

// Draws a frame into the XComponent surface. mode 0 = RGBA gradient (first frame proof),
// mode 1 = solid colour (managed request). Returns 0 on success.
static int OhosDrawFrame(void* window, int width, int height, int mode, unsigned int argb) {
    if (window == NULL || width <= 0 || height <= 0) {
        return -1;
    }
    if (!ohos_host_optional_native_window_available()) {
        return -1;  // reported once by the optional-library loader; frame dropped silently
    }
    if (OhosHostNativeWindowConfigure(window, width, height) != 0) {
        fprintf(stderr, "[openharmony-host] surface: buffer options failed\n");
        return -1;
    }
    OHNativeWindow* native_window = (OHNativeWindow*)window;

    OhosPresentFrame frame(native_window, true);
    if (!frame.valid()) {
        fprintf(stderr, "[openharmony-host] surface: request buffer failed\n");
        return -1;
    }
    BufferHandle* handle = frame.handle();
    if (handle != NULL) {
        // Served from the presentation cache (see above): the slot owns a dup of the fd, so the
        // graphics stack may close its own descriptor without invalidating the mapping, and a
        // reused fd number can never alias another buffer's mapping.
        void* addr = OhosHostPresentMapAcquire(window, handle->fd, handle->virAddr, (size_t)handle->size);
        if (addr != NULL) {
            uint8_t* base = (uint8_t*)addr;
            for (int y = 0; y < height; y++) {
                uint32_t* row = (uint32_t*)(base + (size_t)y * handle->stride);
                for (int x = 0; x < width; x++) {
                    if (mode == 1) {
                        row[x] = argb;
                    } else {
                        uint8_t r = (uint8_t)(255 * x / (width > 1 ? width - 1 : 1));
                        uint8_t g = (uint8_t)(255 * y / (height > 1 ? height - 1 : 1));
                        row[x] = (uint32_t)r | ((uint32_t)g << 8) | ((uint32_t)0x80 << 16) | ((uint32_t)0xff << 24);
                    }
                }
            }
        }
    }
    // frame's destructor flushes the requested buffer exactly once.
    fprintf(stderr, "[openharmony-host] surface: frame drawn (mode=%d %dx%d)\n", mode, width, height);
    fflush(stderr);
    return 0;
}

static void OhosDrawFirstFrame(void* window, int width, int height) {
    OhosDrawFrame(window, width, height, 0, 0);
}

int ohos_host_fill_surface(unsigned int argb) {
    if (!g_surface_valid || g_surface_state == (int)OHOS_SURFACE_DESTROYED) {
        fprintf(stderr, "[openharmony-host] fill_surface: no surface yet\n");
        return -1;
    }
    return OhosDrawFrame(g_surface_window, g_surface_width, g_surface_height, 1, argb);
}

void ohos_host_set_native_window(void* window, int width, int height, ohos_surface_state state) {
    fprintf(stderr, "[openharmony-host] surface state=%d window=%p %dx%d\n",
            (int)state, window, width, height);
    fflush(stderr);
    g_surface_window = window;
    g_surface_width = width;
    g_surface_height = height;
    g_surface_state = (int)state;
    g_surface_valid = 1;
    // The cached present mappings belong to the previous surface's buffer pool; drop
    // them on every surface transition (created/changed/destroyed). The options are
    // re-applied too, since a surface change may have reset them. A surface change is
    // a rare event, so re-mapping the first buffer afterwards costs nothing.
    OhosHostPresentMapReleaseAll();
    OhosHostNativeWindowInvalidate();
    if (state == OHOS_SURFACE_CREATED || state == OHOS_SURFACE_CHANGED) {
        OhosDrawFirstFrame(window, width, height);
    }
    if (g_app != NULL) {
        g_app->surface_window = window;
        g_app->surface_width = width;
        g_app->surface_height = height;
        g_app->surface_state = (int)state;
        if (g_app->bridge_surface != NULL) {
            g_app->bridge_surface(window, width, height, (int)state);
        }
    }
}

void ohos_host_register_text_input(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_text_input = (void (*)(const char*))callback;
    }
}

void ohos_host_register_input(void* touch, void* frame) {
    fprintf(stderr, "[openharmony-host] register_input touch=%p frame=%p g_app=%p\n", touch, frame, (void*)g_app);
    fflush(stderr);
    if (g_app == NULL) {
        return;
    }
    g_app->bridge_touch = (void (*)(int, float, float, int, int))touch;
    g_app->bridge_frame = (void (*)(int64_t, int64_t))frame;
}

void ohos_host_notify_touch(int type, float x, float y, int pointerCount, int pointerId) {
    if (g_app != NULL && g_app->bridge_touch != NULL) {
        g_app->bridge_touch(type, x, y, pointerCount, pointerId);
    }
}

static void (*g_text_input_listener)(int show) = NULL;

void ohos_host_set_text_input_listener(void (*listener)(int show)) {
    g_text_input_listener = listener;
}

void ohos_host_request_text_input(int show) {
    fprintf(stderr, "[openharmony-host] text input request: %d\n", show);
    fflush(stderr);
    if (g_text_input_listener != NULL) {
        g_text_input_listener(show);
    }
}

// ---------------------------------------------------------------------------
// Essentials implemented directly on the OpenHarmony NDK (no ArkTS involved).
// ---------------------------------------------------------------------------

int ohos_host_vibrate(int duration_ms) {
    if (!ohos_host_optional_vibrator_available()) {
        return -1;  // no vibrator library on this image: request dropped
    }
    Vibrator_Attribute attribute;
    attribute.vibratorId = 0;
    attribute.usage = (Vibrator_Usage)0; /* Vibrator_Usage default (unknown) */
    int32_t rc = OH_Vibrator_PlayVibration(duration_ms > 0 ? duration_ms : 100, attribute);
    if (rc != 0) {
        fprintf(stderr, "[openharmony-host] vibrate rc=%d\n", rc);
    }
    return (int)rc;
}

// ---------------------------------------------------------------------------
// Geolocation: a locating session whose callback stores the newest fix.
// ---------------------------------------------------------------------------

static double g_last_latitude = 0.0;
static double g_last_longitude = 0.0;
static double g_last_altitude = 0.0;
static int g_location_has_fix = 0;
static Location_RequestConfig* g_location_config = NULL;

static void OnLocationReported(Location_Info* location, void* userData) {
    (void)userData;
    if (location == NULL) {
        return;
    }
    Location_BasicInfo info = OH_LocationInfo_GetBasicInfo(location);
    g_last_latitude = info.latitude;
    g_last_longitude = info.longitude;
    g_last_altitude = info.altitude;
    g_location_has_fix = 1;
}

int ohos_host_location_start(void) {
    if (!ohos_host_optional_location_available()) {
        return -1;  // no location library on this image: locating stays off
    }
    if (g_location_config == NULL) {
        g_location_config = OH_Location_CreateRequestConfig();
        if (g_location_config == NULL) {
            return -1;
        }
        OH_LocationRequestConfig_SetCallback(g_location_config, OnLocationReported, NULL);
    }
    int32_t rc = OH_Location_StartLocating(g_location_config);
    if (rc != 0) {
        fprintf(stderr, "[openharmony-host] location start rc=%d\n", rc);
    }
    return (int)rc;
}

int ohos_host_location_stop(void) {
    if (g_location_config == NULL) {
        return 0;
    }
    int32_t rc = OH_Location_StopLocating(g_location_config);
    // The request config is the session: destroy it with the stop so a later start rebuilds a
    // fresh one (the old code kept it for the process lifetime, so a page re-entry could never
    // replace the callback or the session state). The newest fix stays readable.
    ohos_host_optional_location_destroy_request_config(g_location_config);
    g_location_config = NULL;
    return (int)rc;
}

int ohos_host_location_get(double* latitude, double* longitude, double* altitude) {
    if (!g_location_has_fix) {
        return 0;
    }
    if (latitude != NULL) *latitude = g_last_latitude;
    if (longitude != NULL) *longitude = g_last_longitude;
    if (altitude != NULL) *altitude = g_last_altitude;
    return 1;
}

// ---------------------------------------------------------------------------
// Soft keyboard: attach an (empty) editor proxy so the platform can show the input method.
// The text callbacks are the next step; this already drives the keyboard from the platform.
// ---------------------------------------------------------------------------

static InputMethod_TextEditorProxy* g_editor_proxy = NULL;
static InputMethod_InputMethodProxy* g_inputmethod_proxy = NULL;

// IME text callback buffer: the host tracks what the keyboard typed so insert/delete can be
// forwarded to the managed bridge as whole-text updates (the existing TextInput contract).
static char g_ime_text[4096] = {0};

static void ImeForwardText(void) {
    if (g_app != NULL && g_app->bridge_text_input != NULL) {
        g_app->bridge_text_input(g_ime_text);
    }
}

// The largest prefix of utf8 that is at most limit bytes and ends on a UTF-8 sequence
// boundary (walks back over continuation bytes whose lead byte was cut off). The IME paths
// use it so a truncated buffer is always valid UTF-8 for the managed TextInput contract.
static size_t ImeUtf8PrefixLength(const char* utf8, size_t limit) {
    size_t take = strlen(utf8);
    if (take > limit) {
        take = limit;
        while (take > 0 && ((unsigned char)utf8[take] & 0xC0) == 0x80) {
            take--;
        }
    }
    return take;
}

static void ImeAppendUtf8(const char* utf8) {
    size_t used = strlen(g_ime_text);
    if (used >= sizeof(g_ime_text) - 1) {
        return;
    }
    size_t take = ImeUtf8PrefixLength(utf8, sizeof(g_ime_text) - 1 - used);
    memcpy(g_ime_text + used, utf8, take);
    g_ime_text[used + take] = '\0';
}

static void ImeDeleteBackward(int32_t length) {
    for (int32_t i = 0; i < length; i++) {
        size_t used = strlen(g_ime_text);
        if (used > 0) {
            /* Back off one UTF-8 sequence. */
            size_t cut = used - 1;
            while (cut > 0 && (g_ime_text[cut] & 0xC0) == 0x80) {
                cut--;
            }
            g_ime_text[cut] = '\0';
        }
    }
}

static void OnImeInsertText(InputMethod_TextEditorProxy* proxy, const char16_t* text, size_t length) {
    (void)proxy;
    if (text == NULL || length == 0) {
        return;
    }
    /* UTF-16 -> UTF-8. Surrogate pairs become one 4-byte sequence, and the loop stops before
       the code point that would not fit together with the terminator, so the buffer never
       ends inside a sequence nor with half of a surrogate pair (BMP-only lone surrogates keep
       the historical pass-through). */
    char utf8[1024];
    size_t out = 0;
    for (size_t i = 0; i < length; i++) {
        uint32_t c = (uint32_t)text[i];
        size_t bytes;
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < length &&
            text[i + 1] >= 0xDC00 && text[i + 1] <= 0xDFFF) {
            c = 0x10000 + ((c - 0xD800) << 10) + ((uint32_t)text[i + 1] - 0xDC00);
            i++;
            bytes = 4;
        } else if (c < 0x80) {
            bytes = 1;
        } else if (c < 0x800) {
            bytes = 2;
        } else {
            bytes = 3;
        }
        if (out + bytes + 1 > sizeof(utf8)) {
            break;   /* no room for this code point and the terminator */
        }
        if (bytes == 4) {
            utf8[out++] = (char)(0xF0 | (c >> 18));
            utf8[out++] = (char)(0x80 | ((c >> 12) & 0x3F));
            utf8[out++] = (char)(0x80 | ((c >> 6) & 0x3F));
            utf8[out++] = (char)(0x80 | (c & 0x3F));
        } else if (bytes == 3) {
            utf8[out++] = (char)(0xE0 | (c >> 12));
            utf8[out++] = (char)(0x80 | ((c >> 6) & 0x3F));
            utf8[out++] = (char)(0x80 | (c & 0x3F));
        } else if (bytes == 2) {
            utf8[out++] = (char)(0xC0 | (c >> 6));
            utf8[out++] = (char)(0x80 | (c & 0x3F));
        } else {
            utf8[out++] = (char)c;
        }
    }
    utf8[out] = '\0';
    ImeAppendUtf8(utf8);
    ImeForwardText();
}

static void OnImeDeleteForward(InputMethod_TextEditorProxy* proxy, int32_t length) {
    (void)proxy;
    (void)length;
    /* Forward deletion at the end of the buffer is a no-op for our single-caret model. */
}

static void OnImeDeleteBackward(InputMethod_TextEditorProxy* proxy, int32_t length) {
    (void)proxy;
    ImeDeleteBackward(length);
    ImeForwardText();
}

static void OnImeGetTextConfig(InputMethod_TextEditorProxy* proxy, InputMethod_TextConfig* config) {
    (void)proxy;
    (void)config;
}

void ohos_host_keyboard_set_text(const char* utf8) {
    g_ime_text[0] = '\0';
    if (utf8 != NULL) {
        // Truncate to the buffer but back off to a UTF-8 sequence boundary; the old strncpy
        // could hand the managed side a buffer ending in half of a multi-byte character.
        size_t take = ImeUtf8PrefixLength(utf8, sizeof(g_ime_text) - 1);
        memcpy(g_ime_text, utf8, take);
        g_ime_text[take] = '\0';
    }
}

static int EnsureInputMethod(void) {
    if (!ohos_host_optional_ime_available()) {
        return -1;  // reduced image without the API 12+ IME entry points: keyboard stays off
    }
    if (g_inputmethod_proxy != NULL) {
        return 0;
    }
    if (g_editor_proxy == NULL) {
        g_editor_proxy = OH_TextEditorProxy_Create();
        if (g_editor_proxy == NULL) {
            return -1;
        }
        OH_TextEditorProxy_SetInsertTextFunc(g_editor_proxy, OnImeInsertText);
        OH_TextEditorProxy_SetDeleteForwardFunc(g_editor_proxy, OnImeDeleteForward);
        OH_TextEditorProxy_SetDeleteBackwardFunc(g_editor_proxy, OnImeDeleteBackward);
        OH_TextEditorProxy_SetGetTextConfigFunc(g_editor_proxy, OnImeGetTextConfig);
    }
    InputMethod_AttachOptions* options = OH_AttachOptions_Create(false);
    if (options == NULL) {
        return -1;
    }
    InputMethod_ErrorCode rc = OH_InputMethodController_Attach(g_editor_proxy, options, &g_inputmethod_proxy);
    OH_AttachOptions_Destroy(options);
    if (rc != 0) {
        fprintf(stderr, "[openharmony-host] input method attach rc=%d\n", rc);
        g_inputmethod_proxy = NULL;
        // The attach refused the proxy: destroy it instead of keeping a half-bound object for
        // the process lifetime; the next keyboard call builds a fresh one.
        ohos_host_optional_ime_text_editor_proxy_destroy(g_editor_proxy);
        g_editor_proxy = NULL;
        return (int)rc;
    }
    return 0;
}

// Releases the IME attach state. The proxy has to be detached before it is destroyed (the
// platform owns it until detach), and both handles are cleared so a later keyboard call
// re-attaches for the new app/page. Called when the app handle is joined.
static void OhosHostReleaseInputMethod(void) {
    if (g_inputmethod_proxy != NULL) {
        OH_InputMethodController_Detach(g_inputmethod_proxy);
        g_inputmethod_proxy = NULL;
    }
    if (g_editor_proxy != NULL) {
        ohos_host_optional_ime_text_editor_proxy_destroy(g_editor_proxy);
        g_editor_proxy = NULL;
    }
    g_ime_text[0] = '\0';
}

// Drops the system-bridge state that belongs to one app generation (location session, IME
// attach). Called by ohos_host_join_app once the app thread has finished, so the statics cannot
// outlive the handle they were created for; every entry point rebuilds them on demand.
static void OhosHostReleaseAppGenerationState(void) {
    ohos_host_location_stop();
    g_location_has_fix = 0;
    OhosHostReleaseInputMethod();
}

// ---------------------------------------------------------------------------
// Safe area: reported by the shell (window.getWindowAvoidArea) and consumed by the app host.
// ---------------------------------------------------------------------------

static int g_avoid_top = 0;
static int g_avoid_bottom = 0;
static int g_avoid_left = 0;
static int g_avoid_right = 0;

void ohos_host_set_avoid_area(int top, int bottom, int left, int right) {
    g_avoid_top = top > 0 ? top : 0;
    g_avoid_bottom = bottom > 0 ? bottom : 0;
    g_avoid_left = left > 0 ? left : 0;
    g_avoid_right = right > 0 ? right : 0;
    fprintf(stderr, "[openharmony-host] avoid area t=%d b=%d l=%d r=%d\n", g_avoid_top, g_avoid_bottom, g_avoid_left, g_avoid_right);
}

int ohos_host_get_avoid_area(int* top, int* bottom, int* left, int* right) {
    if (top != NULL) *top = g_avoid_top;
    if (bottom != NULL) *bottom = g_avoid_bottom;
    if (left != NULL) *left = g_avoid_left;
    if (right != NULL) *right = g_avoid_right;
    return 1;
}

// ---------------------------------------------------------------------------
// Soft input: the shell reports the keyboard height from the window's
// avoidAreaChange(TYPE_KEYBOARD) observer; the managed safe-area model consumes it for
// SafeAreaEdges.SoftInput/All. The system avoid area above is a separate slot.
// ---------------------------------------------------------------------------

static int g_soft_input_bottom = 0;

void ohos_host_register_soft_input_change(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_soft_input_change = (void (*)(int))callback;
    }
}

void ohos_host_set_soft_input_area(int bottom) {
    int height = bottom > 0 ? bottom : 0;
    if (height == g_soft_input_bottom) {
        return;
    }
    g_soft_input_bottom = height;
    fprintf(stderr, "[openharmony-host] soft input bottom=%d\n", g_soft_input_bottom);
    // Forward the change so the managed layout re-runs (the slice asks for a redraw); the
    // callback runs on the caller's thread, like the other bridge notifications.
    if (g_app != NULL && g_app->bridge_soft_input_change != NULL) {
        g_app->bridge_soft_input_change(g_soft_input_bottom);
    }
}

int ohos_host_get_soft_input_area(int* bottom) {
    if (bottom != NULL) *bottom = g_soft_input_bottom;
    return 1;
}

// ---------------------------------------------------------------------------
// WebView: the shell owns a hidden ArkWeb component; commands drive it and page events come back.
// ---------------------------------------------------------------------------

static void (*g_web_listener)(const char* op, const char* arg) = NULL;

void ohos_host_web_set_listener(void (*listener)(const char*, const char*)) {
    g_web_listener = listener;
}

void ohos_host_web_register_event(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_web_event = (void (*)(const char*, const char*))callback;
    }
}

void ohos_host_web_command(const char* op, const char* arg) {
    if (g_web_listener != NULL) {
        g_web_listener(op != NULL ? op : "", arg != NULL ? arg : "");
    }
}

void ohos_host_web_notify_event(const char* state, const char* url) {
    if (g_app != NULL && g_app->bridge_web_event != NULL) {
        g_app->bridge_web_event(state != NULL ? state : "", url != NULL ? url : "");
    }
}

// ---------------------------------------------------------------------------
// Pickers: requests go to the ArkTS shell (system picker), results come back with the file
// name and its content encoded as base64.
// ---------------------------------------------------------------------------

static void (*g_picker_listener)(int request_id, int kind) = NULL;

void ohos_host_picker_set_listener(void (*listener)(int, int)) {
    g_picker_listener = listener;
}

void ohos_host_picker_register_result(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_picker_result = (void (*)(int, int, const char*, const char*))callback;
    }
}

void ohos_host_picker_request(int request_id, int kind) {
    if (g_picker_listener != NULL) {
        g_picker_listener(request_id, kind);
    }
}

void ohos_host_picker_complete(int request_id, int rc, const char* name, const char* data_base64) {
    if (g_app != NULL && g_app->bridge_picker_result != NULL) {
        g_app->bridge_picker_result(request_id, rc, name, data_base64);
    }
}

// ---------------------------------------------------------------------------
// Raw HAP resources (resources/rawfile/**): the managed side asks for one file through
// ohos_host_raw_file_request (op 0 reads it, op 1 probes existence); the ArkTS shell's
// registerRawFileSink handler runs resourceManager and answers through host.notifyRawFileFd
// (bytes read from the rawfile descriptor, preferred) or host.notifyRawFileResult (base64
// fallback) -> ohos_host_raw_file_result_bytes / ohos_host_raw_file_result. The header
// documents the rc values, both transports and the 8 MiB cap.
// ---------------------------------------------------------------------------

static void (*g_raw_file_listener)(int request_id, int op, const char* name) = NULL;

void ohos_host_raw_file_set_listener(void (*listener)(int, int, const char*)) {
    g_raw_file_listener = listener;
}

void ohos_host_raw_file_register_result(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_raw_file_result = (void (*)(int, int, const char*))callback;
    }
}

void ohos_host_raw_file_register_result_bytes(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_raw_file_result_bytes =
            (void (*)(int, int, const unsigned char*, size_t))callback;
    }
}

int ohos_host_raw_file_bytes_available(void) {
    return (g_app != NULL && g_app->bridge_raw_file_result_bytes != NULL) ? 1 : 0;
}

int ohos_host_raw_file_request(int request_id, int op, const char* name) {
    if (g_raw_file_listener == NULL || name == NULL) {
        return -1;
    }
    g_raw_file_listener(request_id, op, name);
    return 0;
}

void ohos_host_raw_file_result(int request_id, int rc, const char* data_base64) {
    if (g_app != NULL && g_app->bridge_raw_file_result != NULL) {
        g_app->bridge_raw_file_result(request_id, rc, data_base64 != NULL ? data_base64 : "");
    }
}

void ohos_host_raw_file_result_bytes(int request_id, int rc, const unsigned char* data, size_t length) {
    if (g_app != NULL && g_app->bridge_raw_file_result_bytes != NULL) {
        g_app->bridge_raw_file_result_bytes(request_id, rc, data, length);
    }
}

// ---------------------------------------------------------------------------
// Runtime permissions: requests go to the ArkTS shell (abilityAccessCtrl), the granted/
// denied answer comes back through host.permissionResult.
// ---------------------------------------------------------------------------

static void (*g_permission_listener)(const char* permission, int request_id) = NULL;

void ohos_host_permission_set_listener(void (*listener)(const char*, int)) {
    g_permission_listener = listener;
}

void ohos_host_register_permission_result(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_permission_result = (void (*)(int, int))callback;
    }
}

void ohos_host_request_permission(const char* permission, int request_id) {
    if (g_permission_listener != NULL) {
        g_permission_listener(permission != NULL ? permission : "", request_id);
    }
}

void ohos_host_permission_complete(int request_id, int granted) {
    if (g_app != NULL && g_app->bridge_permission_result != NULL) {
        g_app->bridge_permission_result(request_id, granted != 0 ? 1 : 0);
    }
}

// ---------------------------------------------------------------------------
// Notification enablement (MAUI Permissions.PostNotifications): op 0 reads the system enable
// state, op 1 shows the system enable dialog; the shell answers through
// host.notificationPermissionResult -> ohos_host_notification_permission_complete.
// ---------------------------------------------------------------------------

static void (*g_notification_permission_listener)(int op, int request_id) = NULL;

void ohos_host_notification_permission_set_listener(void (*listener)(int, int)) {
    g_notification_permission_listener = listener;
}

void ohos_host_notification_permission_register_result(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_notification_permission_result = (void (*)(int, int))callback;
    }
}

void ohos_host_notification_permission_request(int op, int request_id) {
    if (g_notification_permission_listener != NULL) {
        g_notification_permission_listener(op, request_id);
    }
}

void ohos_host_notification_permission_complete(int request_id, int granted) {
    if (g_app != NULL && g_app->bridge_notification_permission_result != NULL) {
        g_app->bridge_notification_permission_result(request_id, granted != 0 ? 1 : 0);
    }
}

// ---------------------------------------------------------------------------
// Clipboard: requests go to the ArkTS shell (@ohos.pasteboard); the shell answers through
// host.clipboardResult and pushes change notifications through host.notifyClipboardChanged.
// ---------------------------------------------------------------------------

static void (*g_clipboard_listener)(int request_id, int op, const char* text) = NULL;

void ohos_host_clipboard_set_listener(void (*listener)(int, int, const char*)) {
    g_clipboard_listener = listener;
}

void ohos_host_clipboard_register_result(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_clipboard_result = (void (*)(int, int, const char*))callback;
    }
}

void ohos_host_clipboard_request(int request_id, int op, const char* text) {
    if (g_clipboard_listener != NULL) {
        g_clipboard_listener(request_id, op, text != NULL ? text : "");
    }
}

void ohos_host_clipboard_complete(int request_id, int rc, const char* text) {
    if (g_app != NULL && g_app->bridge_clipboard_result != NULL) {
        g_app->bridge_clipboard_result(request_id, rc, text != NULL ? text : "");
    }
}

void ohos_host_clipboard_register_changed(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_clipboard_changed = (void (*)(void))callback;
    }
}

void ohos_host_clipboard_notify_changed(void) {
    if (g_app != NULL && g_app->bridge_clipboard_changed != NULL) {
        g_app->bridge_clipboard_changed();
    }
}

// ---------------------------------------------------------------------------
// Shell search: the managed side publishes the SearchHandler state through
// ohos_host_shell_search_set (a one-way command dispatched by the NAPI shell search sink);
// the shell's search field reports the user's interactions back through
// ohos_host_shell_search_notify, which invokes the managed listener registered here.
// ---------------------------------------------------------------------------

static void (*g_shell_search_listener)(int op, const char* text) = NULL;

void ohos_host_shell_search_set_listener(void (*listener)(int, const char*)) {
    g_shell_search_listener = listener;
}

void ohos_host_shell_search_notify(int op, const char* text) {
    if (g_shell_search_listener != NULL) {
        g_shell_search_listener(op, text != NULL ? text : "");
    }
}

// ---------------------------------------------------------------------------
// Geocoding: requests go to the ArkTS shell (@ohos.geoLocationManager, lazily imported and
// permission-aware); the answer comes back through host.geocodeResult.
// ---------------------------------------------------------------------------

static void (*g_geocode_listener)(int request_id, int op, const char* arg) = NULL;

void ohos_host_geocode_set_listener(void (*listener)(int, int, const char*)) {
    g_geocode_listener = listener;
}

int ohos_host_geocode_request(int op, const char* arg, int request_id) {
    if (arg == NULL || g_geocode_listener == NULL) {
        OH_LOG_WARN(LOG_APP, "[openharmony-host] geocode request dropped: arg=%{public}s listener=%{public}s",
                    arg == NULL ? "null" : "set", g_geocode_listener == NULL ? "missing" : "set");
        return -1;
    }
    g_geocode_listener(request_id, op, arg);
    return 0;
}

void ohos_host_register_geocode_result(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_geocode_result = (void (*)(int, int, const char*))callback;
    }
}

void ohos_host_geocode_complete(int request_id, int rc, const char* json) {
    if (g_app != NULL && g_app->bridge_geocode_result != NULL) {
        g_app->bridge_geocode_result(request_id, rc, json != NULL ? json : "");
    }
}

// ---------------------------------------------------------------------------
// Connectivity: the shell's network observer calls ohos_host_network_access_notify, which
// re-reads the level through the same NDK path as ohos_host_network_access and hands it to
// the managed listener (registered by the managed side).
// ---------------------------------------------------------------------------

void ohos_host_network_access_register(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_network_access = (void (*)(int))callback;
    }
}

void ohos_host_network_access_notify(void) {
    if (g_app != NULL && g_app->bridge_network_access != NULL) {
        g_app->bridge_network_access(ohos_host_network_access());
    }
}

// Connectivity capabilities: the shell's capped bearer-type encoding is parsed here (the NAPI
// wrapper drops a NULL/over-cap payload before calling) and read back by the managed
// ConnectionProfiles through ohos_host_network_capabilities. 0 = unknown/empty.
static int g_net_bearers = 0;
static int g_net_bearers_known = 0;

// Caps mirrored from the shell's encoding: at most 8 entries, each 0..4 (NetBearType).
#define OHOS_MAX_NET_BEARER_ENTRIES 8

void ohos_host_set_network_capabilities(const char* encoded) {
    int mask = 0;
    int entries = 0;
    if (encoded != NULL) {
        const char* cursor = encoded;
        while (*cursor != '\0' && entries < OHOS_MAX_NET_BEARER_ENTRIES) {
            while (*cursor == ',' || *cursor == ' ' || *cursor == '\t') {
                cursor++;
            }
            if (*cursor == '\0') {
                break;
            }
            int value = 0;
            int digits = 0;
            while (*cursor >= '0' && *cursor <= '9') {
                value = (value * 10) + (*cursor - '0');
                if (value > 255) {
                    value = 255;  // saturate; any value outside 0..4 is ignored below
                }
                digits++;
                cursor++;
            }
            if (digits > 0 && value >= 0 && value <= 4) {
                mask |= 1 << value;
            }
            entries++;
            while (*cursor != '\0' && *cursor != ',') {
                cursor++;  // skip a malformed remainder up to the next separator
            }
        }
    }
    g_net_bearers = mask;
    g_net_bearers_known = 1;
    fprintf(stderr, "[openharmony-host] network bearers entries=%d mask=0x%x\n", entries, mask);
}

int ohos_host_network_capabilities(void) {
    if (!ohos_host_optional_net_conn_available()) {
        return 0;  // no NetConn library on this image: no bearer types reported
    }
    if (g_net_bearers_known) {
        return g_net_bearers;
    }
    // No shell push yet: read the NDK default network's bearer types (the same path
    // ohos_host_network_access uses), so a host without the caps-aware shell still answers.
    int32_t hasDefault = 0;
    if (OH_NetConn_HasDefaultNet(&hasDefault) != 0 || hasDefault == 0) {
        return 0;
    }
    NetConn_NetHandle handle;
    if (OH_NetConn_GetDefaultNet(&handle) != 0) {
        return 0;
    }
    NetConn_NetCapabilities capabilities;
    if (OH_NetConn_GetNetCapabilities(&handle, &capabilities) != 0) {
        return 0;
    }
    int mask = 0;
    int32_t bearerCount = capabilities.bearerTypesSize;
    if (bearerCount < 0 || bearerCount > NETCONN_MAX_BEARER_TYPE_SIZE) {
        // A malformed/foreign struct size must not walk past the fixed array.
        bearerCount = NETCONN_MAX_BEARER_TYPE_SIZE;
    }
    for (int32_t i = 0; i < bearerCount; i++) {
        int bearer = (int)capabilities.bearerTypes[i];
        if (bearer >= 0 && bearer <= 4) {
            mask |= 1 << bearer;
        }
    }
    return mask;
}

// Hardware key events: the shell forwards the page's onKeyEvent through host.keyEvent; the
// managed callback registered below receives (keyCode, eventType 0 = down / 1 = up).
void ohos_host_register_key_event(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_key_event = (void (*)(int, int))callback;
    }
}

void ohos_host_key_event(int key_code, int event_type) {
    if (g_app != NULL && g_app->bridge_key_event != NULL) {
        g_app->bridge_key_event(key_code, event_type);
    }
}

int ohos_host_keyboard_show(void) {
    if (EnsureInputMethod() != 0 || g_inputmethod_proxy == NULL) {
        return -1;
    }
    return (int)OH_InputMethodProxy_ShowKeyboard(g_inputmethod_proxy);
}

int ohos_host_keyboard_hide(void) {
    if (g_inputmethod_proxy == NULL) {
        return 0;
    }
    return (int)OH_InputMethodProxy_HideKeyboard(g_inputmethod_proxy);
}

int ohos_host_network_access(void) {
    if (!ohos_host_optional_net_conn_available()) {
        return 1; /* none: no NetConn library on this image */
    }
    int32_t hasDefault = 0;
    if (OH_NetConn_HasDefaultNet(&hasDefault) != 0 || hasDefault == 0) {
        return 1; /* none */
    }
    NetConn_NetHandle handle;
    if (OH_NetConn_GetDefaultNet(&handle) != 0) {
        return 2; /* local */
    }
    NetConn_NetCapabilities capabilities;
    if (OH_NetConn_GetNetCapabilities(&handle, &capabilities) != 0) {
        return 2;
    }
    for (int32_t i = 0; i < capabilities.netCapsSize; i++) {
        if (capabilities.netCaps[i] == NETCONN_NET_CAPABILITY_INTERNET) {
            return 3; /* internet */
        }
    }
    return 2;
}

int ohos_host_check_permission(const char* permission) {
    if (!ohos_host_optional_ability_access_available()) {
        return 0;  // no access-control library on this image: report "not granted"
    }
    if (permission == NULL) {
        return 0;
    }
    return OH_AT_CheckSelfPermission(permission) ? 1 : 0;
}

static void (*g_vibration_listener)(int duration_ms) = NULL;

void ohos_host_set_vibration_listener(void (*listener)(int)) {
    g_vibration_listener = listener;
}

void ohos_host_request_vibration(int duration_ms) {
    if (g_vibration_listener != NULL) {
        g_vibration_listener(duration_ms);
    }
}

static void (*g_keystore_listener)(int request_id, const char* op, const char* alias, const char* data_base64) = NULL;

void ohos_host_keystore_set_listener(void (*listener)(int, const char*, const char*, const char*)) {
    g_keystore_listener = listener;
}

void ohos_host_keystore_register_result(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_keystore_result = (void (*)(int, int, const char*))callback;
    }
}

void ohos_host_keystore_request(int request_id, const char* op, const char* alias, const char* data_base64) {
    if (g_keystore_listener != NULL) {
        g_keystore_listener(request_id, op, alias, data_base64);
    }
}

void ohos_host_keystore_complete(int request_id, int rc, const char* data_base64) {
    if (g_app != NULL && g_app->bridge_keystore_result != NULL) {
        g_app->bridge_keystore_result(request_id, rc, data_base64);
    }
}

void ohos_host_notify_text_submitted(void) {
    if (g_app != NULL && g_app->bridge_text_submitted != NULL) {
        g_app->bridge_text_submitted();
    }
}

void ohos_host_register_text_submitted(void* callback) {
    if (g_app != NULL) {
        g_app->bridge_text_submitted = (void (*)(void))callback;
    }
}

void ohos_host_notify_text_input(const char* utf8) {
    if (g_app != NULL && g_app->bridge_text_input != NULL && utf8 != NULL) {
        g_app->bridge_text_input(utf8);
    }
}

void ohos_host_notify_frame(int64_t timestamp, int64_t targetTimestamp) {
    if (g_app != NULL && g_app->bridge_frame != NULL) {
        g_app->bridge_frame(timestamp, targetTimestamp);
    }
}

void ohos_host_notify_lifecycle(OhosHostAppHandle* handle, ohos_lifecycle_event event) {
    fprintf(stderr, "[openharmony-host] notify evt=%d handle=%p registered=%d\n",
            (int)event, (void*)handle, handle ? (handle->bridge_lifecycle != NULL) : -1);
    fflush(stderr);
    if (handle == NULL) {
        // The NAPI g_handle is written only after start_app returns, so an event pushed while
        // the launch is still initializing arrives with a NULL handle. Resolve it through
        // g_app, or queue it for the handle that start_app is about to publish, instead of
        // dropping the event.
        pthread_mutex_lock(&g_context_mutex);
        handle = g_app;
        if (handle == NULL) {
            if (g_pending_lifecycle_count < OHOS_MAX_PENDING_LIFECYCLE) {
                g_pending_lifecycle[g_pending_lifecycle_count++] = (int)event;
            }
            pthread_mutex_unlock(&g_context_mutex);
            return;
        }
        pthread_mutex_unlock(&g_context_mutex);
    }
    // The registration check and the append must be atomic against register_bridge's flush
    // (both under g_context_mutex): an event that reads "not registered yet" and then appends
    // after the flush would sit in the queue forever, because the managed bridge registers
    // once and never drains it again. The callback runs after the unlock.
    pthread_mutex_lock(&g_context_mutex);
    void (*callback)(int) = handle->bridge_lifecycle;
    if (callback != NULL) {
        pthread_mutex_unlock(&g_context_mutex);
        callback((int)event);
        return;
    }
    if (handle->pending_count < OHOS_MAX_PENDING_LIFECYCLE) {
        handle->pending_lifecycle[handle->pending_count++] = (int)event;
    }
    pthread_mutex_unlock(&g_context_mutex);
}

void ohos_host_set_node_content(OhosHostAppHandle* handle, void* node_content) {
    if (handle == NULL) {
        // Same pre-handle window as ohos_host_notify_lifecycle: the shell can hand the
        // NodeContent over before the launch thread publishes the handle. Store it for the
        // handle start_app creates; register_bridge then forwards it to the managed side
        // (OHOS_HOST_APP_CONTEXT-style late delivery).
        pthread_mutex_lock(&g_context_mutex);
        handle = g_app;
        if (handle == NULL) {
            g_pending_node_content = node_content;
            pthread_mutex_unlock(&g_context_mutex);
            return;
        }
        pthread_mutex_unlock(&g_context_mutex);
    }
    // Bind the content under the same lock register_bridge's flush takes, and clear the slot
    // when a live bridge takes it over: whichever side wins the lock delivers exactly once
    // (the flush path also clears, see OhosHostBindAndFlushBridge). The callback itself runs
    // outside the lock; a clear (NULL) still notifies the managed side like before.
    void (*callback)(void*) = NULL;
    pthread_mutex_lock(&g_context_mutex);
    // A new NodeContent (page re-entry) replaces the identity the managed side last saw; log it
    // so a lost accessibility attach on the new page is diagnosable, and keep the newest value
    // for the provider's rebind path.
    if (node_content != NULL && handle->node_content_identity != NULL &&
        handle->node_content_identity != node_content) {
        fprintf(stderr, "[openharmony-host] node content replaced %p -> %p, rebinding the app\n",
                handle->node_content_identity, node_content);
        fflush(stderr);
    }
    handle->node_content_identity = node_content;
    handle->node_content = node_content;
    if (handle->bridge_node != NULL) {
        callback = handle->bridge_node;
        handle->node_content = NULL;
    }
    pthread_mutex_unlock(&g_context_mutex);
    if (callback != NULL) {
        callback(node_content);
    }
}

void* ohos_host_get_node_content(OhosHostAppHandle* handle) {
    return handle != NULL ? handle->node_content : NULL;
}

int ohos_host_join_app(OhosHostAppHandle* handle) {
    if (handle == NULL) {
        return -1;
    }
    // The join itself stays outside g_context_mutex: the app thread may still be inside a
    // managed callback that calls a host entry taking the lock, and blocking there would
    // deadlock the join.
    if (!handle->joined) {
        pthread_join(handle->thread, NULL);
        handle->joined = 1;
    }
    // The app generation is over: release the location session and the IME attach that were
    // created for it (both were process-lifetime statics before, so a re-entered page kept a
    // stale session and the platform proxy forever). A later app/page rebuilds them on demand.
    OhosHostReleaseAppGenerationState();
    // Detach and free under the lock get/set_app_context use: a getter that already resolved
    // g_app is serialized with the free, and a setter that runs after sees g_app == NULL and
    // parks its snapshot in the pending slot instead of touching the freed handle.
    pthread_mutex_lock(&g_context_mutex);
    int exit_code = handle->exit_code;
    // The runtime is intentionally not closed here: managed worker threads may still be
    // running and the application process owns the runtime until it exits.
    if (g_app == handle) {
        g_app = NULL;
    }
    free(handle->context_json);
    OhosHostFreeRetiredContexts(handle);
    free(handle);
    pthread_mutex_unlock(&g_context_mutex);
    return exit_code;
}

// ---------------------------------------------------------------------------
// Drawing bridge: an immediate-mode canvas over the current XComponent surface,
// implemented with native_drawing (the Skia-backed platform 2D API).
// ---------------------------------------------------------------------------

// RAII holder for one OH_Drawing_* handle. The drawing C API hands out untyped pointers whose
// destroy function is per type, and several call sites create more than one object before they
// can fail (the two gradient points, the image rect/sampling set); wrapping every create here
// guarantees that the early-return paths release exactly what they made. openharmony_host.c
// keeps C linkage but is compiled as C++ (see the note in openharmony_host.h), which is what
// makes the scope guard available.
template <typename T>
class OhosDrawingHandle {
public:
    explicit OhosDrawingHandle(void (*destroy)(T*)) : destroy_(destroy) {}
    ~OhosDrawingHandle() { Reset(); }
    OhosDrawingHandle(const OhosDrawingHandle&) = delete;
    OhosDrawingHandle& operator=(const OhosDrawingHandle&) = delete;

    T* Get() const { return handle_; }
    // Takes ownership of handle, releasing whatever was held before.
    void Adopt(T* handle) { Reset(handle); }
    // Gives up ownership without destroying; used when a handle moves into a cache/effect.
    T* Release() {
        T* handle = handle_;
        handle_ = nullptr;
        return handle;
    }
    void Reset(T* handle = nullptr) {
        if (handle_ != nullptr && destroy_ != nullptr) {
            destroy_(handle_);
        }
        handle_ = handle;
    }

private:
    T* handle_ = nullptr;
    void (*destroy_)(T*) = nullptr;
};

static OH_Drawing_Bitmap* g_canvas_bitmap = NULL;

// One owned effect generation. A pixelmap shader does not own its pixelmap, so the state owns
// everything a pattern needs: the shader, its OH_Drawing_PixelMap wrapper and the native
// pixelmap that backs it (plus the shadow layer). Replacing or clearing the effects destroys
// the shader first, dissolves the wrapper, then releases the native pixelmap - the order the
// drawing canvas documents - so no combination of setter/clear can leak or dangle them.
typedef struct {
    OH_Drawing_ShaderEffect* shader;            // owned by the effect state
    OH_Drawing_ShadowLayer* shadow;             // owned by the effect state
    OH_Drawing_PixelMap* shader_pixelmap;       // owned wrapper of an image-pattern shader
    OH_PixelmapNative* shader_native_pixelmap;  // owned native pixelmap behind the wrapper
} OhosEffectState;

static OhosEffectState g_effects;

// Releases the pixelmap pair of a pixelmap shader. The wrapper is dissolved before its native
// pixelmap is released; callers that still hold the shader must destroy it first.
static void OhosEffectReleasePixelMap(void) {
    if (g_effects.shader_pixelmap != NULL) {
        OH_Drawing_PixelMapDissolve(g_effects.shader_pixelmap);
        g_effects.shader_pixelmap = NULL;
    }
    if (g_effects.shader_native_pixelmap != NULL) {
        OH_PixelmapNative_Release(g_effects.shader_native_pixelmap);
        g_effects.shader_native_pixelmap = NULL;
    }
}

static void OhosEffectReleaseAll(void) {
    if (g_effects.shader != NULL) {
        OH_Drawing_ShaderEffectDestroy(g_effects.shader);
        g_effects.shader = NULL;
    }
    OhosEffectReleasePixelMap();
    if (g_effects.shadow != NULL) {
        OH_Drawing_ShadowLayerDestroy(g_effects.shadow);
        g_effects.shadow = NULL;
    }
}

// The effects above are the state the next fill/text brush picks up. The managed canvas
// clears them on every fill-colour assignment (hundreds of times per frame), so
// ohos_host_draw_clear_effects only publishes the logical state: the objects are destroyed
// once, right before the next brush needs them (OhosResolvePendingClear). A brush created
// after the clear never sees the effects either way, and repeated clears collapse into the
// single pending flag instead of touching the Skia objects each time.
static unsigned int g_effect_state_serial = 1;
static int g_effects_clear_pending = 0;
static void OhosFlushFillBrushCache(void);

static void OhosBumpEffectState(void) {
    g_effect_state_serial++;
    if (g_effect_state_serial == 0) {
        g_effect_state_serial = 1;
    }
}

static void OhosResolvePendingClear(void) {
    if (!g_effects_clear_pending) {
        return;
    }
    g_effects_clear_pending = 0;
    // Cached brushes captured the effect objects (shader/shadow) they were built with, so
    // they are dropped before the objects are destroyed.
    OhosFlushFillBrushCache();
    OhosEffectReleaseAll();
}

// --- fill/text brush cache ---------------------------------------------------------
// A brush carries the fill colour plus the effects current at creation time, so it can be
// reused for every later draw with the same (argb, effect generation); the bounded cache
// removes the per-primitive create/destroy. Entries are dropped when the effect generation
// advances (their shader/shadow references are gone) or when the LRU evicts them.
// Single-threaded by contract, like g_canvas itself, so the cache takes no lock.
#define OHOS_FILL_BRUSH_CACHE_MAX 32
typedef struct {
    unsigned int argb;
    unsigned int serial;
    OH_Drawing_Brush* brush;
    uint64_t last_used;
} OhosFillBrushEntry;

static OhosFillBrushEntry g_fill_brushes[OHOS_FILL_BRUSH_CACHE_MAX];
static uint64_t g_fill_brush_clock = 0;

static void OhosFlushFillBrushCache(void) {
    for (int i = 0; i < OHOS_FILL_BRUSH_CACHE_MAX; i++) {
        if (g_fill_brushes[i].brush != NULL) {
            OH_Drawing_BrushDestroy(g_fill_brushes[i].brush);
            g_fill_brushes[i].brush = NULL;
        }
    }
}

// Borrowed brush owned by the cache; valid until the effect state changes.
static OH_Drawing_Brush* OhosFillBrushGet(unsigned int argb) {
    OhosResolvePendingClear();
    const unsigned int serial = g_effect_state_serial;
    int slot = -1;
    for (int i = 0; i < OHOS_FILL_BRUSH_CACHE_MAX; i++) {
        OhosFillBrushEntry* entry = &g_fill_brushes[i];
        if (entry->brush == NULL) {
            if (slot < 0) {
                slot = i;
            }
            continue;
        }
        if (entry->argb == argb && entry->serial == serial) {
            entry->last_used = ++g_fill_brush_clock;
            return entry->brush;
        }
    }
    if (slot < 0) {
        uint64_t oldest = UINT64_MAX;
        for (int i = 0; i < OHOS_FILL_BRUSH_CACHE_MAX; i++) {
            if (g_fill_brushes[i].last_used < oldest) {
                oldest = g_fill_brushes[i].last_used;
                slot = i;
            }
        }
    }
    if (slot < 0) {
        return NULL;
    }
    OhosFillBrushEntry* entry = &g_fill_brushes[slot];
    if (entry->brush != NULL) {
        OH_Drawing_BrushDestroy(entry->brush);
        entry->brush = NULL;
    }
    OH_Drawing_Brush* brush = OH_Drawing_BrushCreate();
    if (brush == NULL) {
        return NULL;
    }
    OH_Drawing_BrushSetColor(brush, (uint32_t)argb);
    if (g_effects.shader != NULL) {
        OH_Drawing_BrushSetShaderEffect(brush, g_effects.shader);
    }
    if (g_effects.shadow != NULL) {
        OH_Drawing_BrushSetShadowLayer(brush, g_effects.shadow);
    }
    entry->argb = argb;
    entry->serial = serial;
    entry->brush = brush;
    entry->last_used = ++g_fill_brush_clock;
    return brush;
}

// Installs a shader (NULL clears it). The previous shader is destroyed, then the previous
// pixelmap pair is released; ownership of the arguments passes to the effect state.
static void OhosSetShaderEffect(OH_Drawing_ShaderEffect* shader, OH_Drawing_PixelMap* drawing_pixelmap,
                                OH_PixelmapNative* native_pixelmap) {
    OhosResolvePendingClear();
    OhosFlushFillBrushCache();
    if (g_effects.shader != NULL) {
        OH_Drawing_ShaderEffectDestroy(g_effects.shader);
        g_effects.shader = NULL;
    }
    OhosEffectReleasePixelMap();
    g_effects.shader = shader;
    g_effects.shader_pixelmap = drawing_pixelmap;
    g_effects.shader_native_pixelmap = native_pixelmap;
    OhosBumpEffectState();
}

static void OhosSetShadowLayer(OH_Drawing_ShadowLayer* shadow) {
    OhosResolvePendingClear();
    OhosFlushFillBrushCache();
    if (g_effects.shadow != NULL) {
        OH_Drawing_ShadowLayerDestroy(g_effects.shadow);
    }
    g_effects.shadow = shadow;
    OhosBumpEffectState();
}

void ohos_host_draw_clear_effects(void) {
    if (g_effects_clear_pending || (g_effects.shader == NULL && g_effects.shadow == NULL)) {
        return;
    }
    g_effects_clear_pending = 1;
    OhosBumpEffectState();
}

void ohos_host_draw_set_linear_gradient(float x0, float y0, float x1, float y1,
                                        const unsigned int* colors, const float* stops, int count) {
    if (colors == NULL || count < 2) {
        return;
    }
    OhosDrawingHandle<OH_Drawing_Point> start(OH_Drawing_PointDestroy);
    OhosDrawingHandle<OH_Drawing_Point> end(OH_Drawing_PointDestroy);
    start.Adopt(OH_Drawing_PointCreate(x0, y0));
    end.Adopt(OH_Drawing_PointCreate(x1, y1));
    if (start.Get() == NULL || end.Get() == NULL) {
        return;  // both guards release whatever was created (the fixed leak: one point survived)
    }
    OH_Drawing_ShaderEffect* shader = OH_Drawing_ShaderEffectCreateLinearGradient(start.Get(), end.Get(),
        (const uint32_t*)colors, stops, (uint32_t)count, CLAMP);
    OhosSetShaderEffect(shader, NULL, NULL);
}

void ohos_host_draw_set_radial_gradient(float cx, float cy, float radius,
                                        const unsigned int* colors, const float* stops, int count) {
    if (colors == NULL || count < 2 || radius <= 0.0f) {
        return;
    }
    OhosDrawingHandle<OH_Drawing_Point> center(OH_Drawing_PointDestroy);
    center.Adopt(OH_Drawing_PointCreate(cx, cy));
    if (center.Get() == NULL) {
        return;
    }
    OH_Drawing_ShaderEffect* shader = OH_Drawing_ShaderEffectCreateRadialGradient(center.Get(), radius,
        (const uint32_t*)colors, stops, (uint32_t)count, CLAMP);
    OhosSetShaderEffect(shader, NULL, NULL);
}

// Adapters for the image-framework release functions: they return an Image_ErrorCode, while the
// drawing scope guard stores a void destroy. The error is ignored exactly like before (the
// release either succeeded or the handle is already gone).
static void OhosImageSourceReleaseHandle(OH_ImageSourceNative* source) {
    (void)OH_ImageSourceNative_Release(source);
}

static void OhosPixelmapReleaseHandle(OH_PixelmapNative* pixelmap) {
    (void)OH_PixelmapNative_Release(pixelmap);
}

int ohos_host_draw_set_image_pattern(const void* data, int length, int tileModeX, int tileModeY,
                                     float scaleX, float scaleY) {
    if (!ohos_host_optional_image_available()) {
        return -1;  // no ImageSource/Pixelmap library on this image: pattern stays off
    }
    if (data == NULL || length <= 0) {
        return -1;
    }
    OhosDrawingHandle<OH_ImageSourceNative> source(OhosImageSourceReleaseHandle);
    OH_ImageSourceNative* created_source = NULL;
    if (OH_ImageSourceNative_CreateFromData((uint8_t*)data, (size_t)length, &created_source) != IMAGE_SUCCESS ||
        created_source == NULL) {
        return -1;
    }
    source.Adopt(created_source);
    OhosDrawingHandle<OH_PixelmapNative> pixelmap(OhosPixelmapReleaseHandle);
    OH_PixelmapNative* created_pixelmap = NULL;
    if (OH_ImageSourceNative_CreatePixelmap(source.Get(), NULL, &created_pixelmap) != IMAGE_SUCCESS ||
        created_pixelmap == NULL) {
        return -1;
    }
    pixelmap.Adopt(created_pixelmap);
    OhosDrawingHandle<OH_Drawing_PixelMap> drawingPixelMap(OH_Drawing_PixelMapDissolve);
    drawingPixelMap.Adopt(OH_Drawing_PixelMapGetFromOhPixelMapNative(pixelmap.Get()));
    if (drawingPixelMap.Get() == NULL) {
        return -1;
    }
    OhosDrawingHandle<OH_Drawing_SamplingOptions> sampling(OH_Drawing_SamplingOptionsDestroy);
    sampling.Adopt(OH_Drawing_SamplingOptionsCreate(FILTER_MODE_LINEAR, MIPMAP_MODE_LINEAR));
    OhosDrawingHandle<OH_Drawing_Matrix> matrix(OH_Drawing_MatrixDestroy);
    if (scaleX != 1.0f || scaleY != 1.0f) {
        matrix.Adopt(OH_Drawing_MatrixCreateScale(scaleX, scaleY, 0, 0));
    }
    OH_Drawing_ShaderEffect* shader = OH_Drawing_ShaderEffectCreatePixelMapShader(
        drawingPixelMap.Get(), (OH_Drawing_TileMode)tileModeX, (OH_Drawing_TileMode)tileModeY,
        sampling.Get(), matrix.Get());
    if (shader == NULL) {
        return -1;  // every guard releases its object; the effect state keeps nothing partial
    }
    // The effect state takes over all three objects: the shader, the wrapper and the native
    // pixelmap (a pixelmap shader does not own its pixelmap). The guards must not release them.
    OhosSetShaderEffect(shader, drawingPixelMap.Release(), pixelmap.Release());
    return 0;
}

void ohos_host_draw_set_shadow(float dx, float dy, float blur, unsigned int argb) {
    OhosSetShadowLayer(OH_Drawing_ShadowLayerCreate(blur, dx, dy, (uint32_t)argb));
}
static OH_Drawing_Canvas* g_canvas = NULL;
static int g_canvas_width = 0;
static int g_canvas_height = 0;

int ohos_host_draw_begin(int width, int height) {
    if (width <= 0 || height <= 0) {
        return -1;
    }
    if (g_canvas != NULL && g_canvas_width == width && g_canvas_height == height) {
        return 0;
    }
    if (g_canvas != NULL) {
        OH_Drawing_CanvasDestroy(g_canvas);
        g_canvas = NULL;
    }
    if (g_canvas_bitmap != NULL) {
        OH_Drawing_BitmapDestroy(g_canvas_bitmap);
        g_canvas_bitmap = NULL;
    }
    g_canvas_bitmap = OH_Drawing_BitmapCreate();
    if (g_canvas_bitmap == NULL) {
        return -1;
    }
    OH_Drawing_BitmapFormat format = { COLOR_FORMAT_RGBA_8888, ALPHA_FORMAT_OPAQUE };
    OH_Drawing_BitmapBuild(g_canvas_bitmap, (uint32_t)width, (uint32_t)height, &format);
    g_canvas = OH_Drawing_CanvasCreate();
    if (g_canvas == NULL) {
        return -1;
    }
    OH_Drawing_CanvasBind(g_canvas, g_canvas_bitmap);
    g_canvas_width = width;
    g_canvas_height = height;
    fprintf(stderr, "[openharmony-host] canvas %dx%d ready\n", width, height);
    return 0;
}

void ohos_host_draw_clear(unsigned int argb) {
    if (g_canvas != NULL) {
        OH_Drawing_CanvasClear(g_canvas, (uint32_t)argb);
    }
}

void ohos_host_draw_rect(int x, int y, int width, int height, unsigned int argb, int filled) {
    if (g_canvas == NULL) {
        return;
    }
    OhosDrawingHandle<OH_Drawing_Rect> rect(OH_Drawing_RectDestroy);
    rect.Adopt(OH_Drawing_RectCreate((float)x, (float)y, (float)(x + width), (float)(y + height)));
    if (rect.Get() == NULL) {
        return;
    }
    if (filled) {
        OH_Drawing_Brush* brush = OhosFillBrushGet(argb);
        if (brush != NULL) {
            OH_Drawing_CanvasAttachBrush(g_canvas, brush);
            OH_Drawing_CanvasDrawRect(g_canvas, rect.Get());
            OH_Drawing_CanvasDetachBrush(g_canvas);
        }
    } else {
        // A failed pen create must not be passed to the Pen setters/draw (a NULL handle there
        // aborts); the rect guard still releases on the early return.
        OhosDrawingHandle<OH_Drawing_Pen> pen(OH_Drawing_PenDestroy);
        pen.Adopt(OH_Drawing_PenCreate());
        if (pen.Get() == NULL) {
            return;
        }
        OH_Drawing_PenSetColor(pen.Get(), (uint32_t)argb);
        OH_Drawing_PenSetWidth(pen.Get(), 2.0f);
        OH_Drawing_CanvasAttachPen(g_canvas, pen.Get());
        OH_Drawing_CanvasDrawRect(g_canvas, rect.Get());
        OH_Drawing_CanvasDetachPen(g_canvas);
    }
}

static OH_Drawing_Typeface* g_custom_typeface = NULL;
// Bumped whenever the typeface changes; the font/blob caches key on it and are dropped
// before the old typeface is destroyed (a cached Font holds it).
static unsigned int g_typeface_serial = 1;

// --- font cache --------------------------------------------------------------------
// draw_text and measure_text both need one font per (size, typeface state); the create
// cost dominates the per-text time once the TextBlob is cached, so the fonts are kept in
// a small LRU. face_serial 0 keys the platform default face (measure_text never applies
// the custom typeface, exactly as before); a non-zero serial keys the custom face.
#define OHOS_FONT_CACHE_MAX 32
typedef struct {
    float size;
    unsigned int face_serial;
    OH_Drawing_Font* font;
    uint64_t last_used;
} OhosFontEntry;

static OhosFontEntry g_fonts[OHOS_FONT_CACHE_MAX];
static uint64_t g_font_clock = 0;

static void OhosFontCacheFlush(void) {
    for (int i = 0; i < OHOS_FONT_CACHE_MAX; i++) {
        if (g_fonts[i].font != NULL) {
            OH_Drawing_FontDestroy(g_fonts[i].font);
            g_fonts[i].font = NULL;
        }
    }
}

// Borrowed font owned by the cache. The caller passes the exact text size it would have
// handed to OH_Drawing_FontSetTextSize.
static OH_Drawing_Font* OhosFontGet(float size, unsigned int face_serial) {
    int slot = -1;
    for (int i = 0; i < OHOS_FONT_CACHE_MAX; i++) {
        OhosFontEntry* entry = &g_fonts[i];
        if (entry->font == NULL) {
            if (slot < 0) {
                slot = i;
            }
            continue;
        }
        if (entry->size == size && entry->face_serial == face_serial) {
            entry->last_used = ++g_font_clock;
            return entry->font;
        }
    }
    if (slot < 0) {
        uint64_t oldest = UINT64_MAX;
        for (int i = 0; i < OHOS_FONT_CACHE_MAX; i++) {
            if (g_fonts[i].last_used < oldest) {
                oldest = g_fonts[i].last_used;
                slot = i;
            }
        }
    }
    if (slot < 0) {
        return NULL;
    }
    OhosFontEntry* entry = &g_fonts[slot];
    if (entry->font != NULL) {
        OH_Drawing_FontDestroy(entry->font);
        entry->font = NULL;
    }
    OH_Drawing_Font* font = OH_Drawing_FontCreate();
    if (font == NULL) {
        return NULL;
    }
    const int apply_custom = face_serial != 0 && g_custom_typeface != NULL;
    if (apply_custom) {
        OH_Drawing_FontSetTypeface(font, g_custom_typeface);
    }
    OH_Drawing_FontSetTextSize(font, size);
    if (apply_custom) {
        OH_Drawing_FontSetTypeface(font, g_custom_typeface);
    }
    entry->size = size;
    entry->face_serial = face_serial;
    entry->font = font;
    entry->last_used = ++g_font_clock;
    return font;
}

// --- TextBlob cache ----------------------------------------------------------------
// Shaping dominates draw_text, so blobs for unchanged labels are kept across frames. The
// key is (text, size, typeface state); entries are bounded by count and by cached text
// bytes with LRU eviction, and text longer than OHOS_TEXT_CACHE_MAX_TEXT is never cached
// (built, drawn and destroyed like before). Single-threaded by contract, like g_canvas.
#define OHOS_TEXT_CACHE_MAX 256
#define OHOS_TEXT_CACHE_BUCKETS 512
#define OHOS_TEXT_CACHE_MAX_BYTES (256u * 1024u)
#define OHOS_TEXT_CACHE_MAX_TEXT 4096u
#define OHOS_TEXT_HASH_BYTES 64u

typedef struct OhosTextBlobEntry {
    struct OhosTextBlobEntry* bucket_next;
    struct OhosTextBlobEntry* lru_prev;
    struct OhosTextBlobEntry* lru_next;
    uint64_t hash;
    char* text;
    size_t text_len;
    size_t bytes;  // accounted heap bytes of text (text_len + 1); the eviction subtracts this
    float size;
    unsigned int face_serial;
    OH_Drawing_TextBlob* blob;
} OhosTextBlobEntry;

static OhosTextBlobEntry g_text_blobs[OHOS_TEXT_CACHE_MAX];
static OhosTextBlobEntry* g_text_buckets[OHOS_TEXT_CACHE_BUCKETS];
static OhosTextBlobEntry* g_text_free_list = NULL;
static OhosTextBlobEntry* g_text_lru_head = NULL;
static OhosTextBlobEntry* g_text_lru_tail = NULL;
static size_t g_text_cached_bytes = 0;
static int g_text_cache_ready = 0;

static void OhosTextCacheReset(void) {
    for (int i = 0; i < OHOS_TEXT_CACHE_BUCKETS; i++) {
        g_text_buckets[i] = NULL;
    }
    g_text_free_list = NULL;
    g_text_lru_head = NULL;
    g_text_lru_tail = NULL;
    g_text_cached_bytes = 0;
    for (int i = 0; i < OHOS_TEXT_CACHE_MAX; i++) {
        if (g_text_blobs[i].blob != NULL) {
            OH_Drawing_TextBlobDestroy(g_text_blobs[i].blob);
        }
        free(g_text_blobs[i].text);
        memset(&g_text_blobs[i], 0, sizeof(g_text_blobs[i]));
        g_text_blobs[i].bucket_next = g_text_free_list;
        g_text_free_list = &g_text_blobs[i];
    }
    g_text_cache_ready = 1;
}

static void OhosTextCacheEnsureInit(void) {
    if (!g_text_cache_ready) {
        OhosTextCacheReset();
    }
}

// The full text is compared on lookup, so hashing only a prefix is safe: a collision
// costs one memcmp, never a wrong blob.
static uint64_t OhosTextHash(const char* text, size_t len, float size, unsigned int face_serial) {
    const unsigned char* bytes = (const unsigned char*)text;
    const size_t hashed = len < OHOS_TEXT_HASH_BYTES ? len : OHOS_TEXT_HASH_BYTES;
    uint64_t hash = 1469598103934665603ull;
    for (size_t i = 0; i < hashed; i++) {
        hash ^= bytes[i];
        hash *= 1099511628211ull;
    }
    hash ^= (uint64_t)len;
    hash *= 1099511628211ull;
    uint32_t size_bits = 0;
    memcpy(&size_bits, &size, sizeof(size_bits));
    hash ^= size_bits;
    hash *= 1099511628211ull;
    hash ^= face_serial;
    hash *= 1099511628211ull;
    return hash;
}

static void OhosTextLruUnlink(OhosTextBlobEntry* entry) {
    if (entry->lru_prev != NULL) {
        entry->lru_prev->lru_next = entry->lru_next;
    } else {
        g_text_lru_head = entry->lru_next;
    }
    if (entry->lru_next != NULL) {
        entry->lru_next->lru_prev = entry->lru_prev;
    } else {
        g_text_lru_tail = entry->lru_prev;
    }
    entry->lru_prev = NULL;
    entry->lru_next = NULL;
}

static void OhosTextLruPushFront(OhosTextBlobEntry* entry) {
    entry->lru_prev = NULL;
    entry->lru_next = g_text_lru_head;
    if (g_text_lru_head != NULL) {
        g_text_lru_head->lru_prev = entry;
    }
    g_text_lru_head = entry;
    if (g_text_lru_tail == NULL) {
        g_text_lru_tail = entry;
    }
}

static void OhosTextCacheUnlinkBucket(OhosTextBlobEntry* entry) {
    OhosTextBlobEntry** link = &g_text_buckets[entry->hash & (OHOS_TEXT_CACHE_BUCKETS - 1)];
    while (*link != NULL) {
        if (*link == entry) {
            *link = entry->bucket_next;
            break;
        }
        link = &(*link)->bucket_next;
    }
    entry->bucket_next = NULL;
}

static void OhosTextCacheEvict(OhosTextBlobEntry* entry) {
    OhosTextLruUnlink(entry);
    OhosTextCacheUnlinkBucket(entry);
    if (entry->blob != NULL) {
        OH_Drawing_TextBlobDestroy(entry->blob);
    }
    free(entry->text);
    g_text_cached_bytes -= entry->bytes;
    memset(entry, 0, sizeof(*entry));
    entry->bucket_next = g_text_free_list;
    g_text_free_list = entry;
}

// Borrowed blob; NULL means the caller must build (and later destroy) its own.
static OH_Drawing_TextBlob* OhosTextBlobCacheGet(const char* utf8, size_t len, float size,
                                                 unsigned int face_serial) {
    OhosTextCacheEnsureInit();
    if (len > OHOS_TEXT_CACHE_MAX_TEXT) {
        return NULL;
    }
    const uint64_t hash = OhosTextHash(utf8, len, size, face_serial);
    OhosTextBlobEntry* entry = g_text_buckets[hash & (OHOS_TEXT_CACHE_BUCKETS - 1)];
    while (entry != NULL) {
        if (entry->hash == hash && entry->text_len == len && entry->size == size &&
            entry->face_serial == face_serial && memcmp(entry->text, utf8, len) == 0) {
            OhosTextLruUnlink(entry);
            OhosTextLruPushFront(entry);
            return entry->blob;
        }
        entry = entry->bucket_next;
    }
    return NULL;
}

// Returns 1 when the cache took ownership of the blob.
static int OhosTextBlobCachePut(const char* utf8, size_t len, float size,
                                unsigned int face_serial, OH_Drawing_TextBlob* blob) {
    OhosTextCacheEnsureInit();
    if (len > OHOS_TEXT_CACHE_MAX_TEXT) {
        return 0;  // the same cap as Get: a blob must not be stored and missed
    }
    const size_t bytes = len + 1;
    if (bytes > OHOS_TEXT_CACHE_MAX_BYTES) {
        return 0;
    }
    const uint64_t hash = OhosTextHash(utf8, len, size, face_serial);
    // A key is never stored twice (Get refuses the same key only when it is over the
    // text cap, so a caller can reach Put with an already cached key); replace it.
    OhosTextBlobEntry* existing = g_text_buckets[hash & (OHOS_TEXT_CACHE_BUCKETS - 1)];
    while (existing != NULL) {
        if (existing->hash == hash && existing->text_len == len && existing->size == size &&
            existing->face_serial == face_serial && memcmp(existing->text, utf8, len) == 0) {
            OhosTextCacheEvict(existing);
            break;
        }
        existing = existing->bucket_next;
    }
    while (g_text_cached_bytes + bytes > OHOS_TEXT_CACHE_MAX_BYTES && g_text_lru_tail != NULL) {
        OhosTextCacheEvict(g_text_lru_tail);
    }
    if (g_text_free_list == NULL && g_text_lru_tail != NULL) {
        OhosTextCacheEvict(g_text_lru_tail);
    }
    if (g_text_free_list == NULL) {
        return 0;
    }
    char* copy = (char*)malloc(len + 1);
    if (copy == NULL) {
        return 0;
    }
    memcpy(copy, utf8, len);
    copy[len] = '\0';
    OhosTextBlobEntry* entry = g_text_free_list;
    g_text_free_list = entry->bucket_next;
    memset(entry, 0, sizeof(*entry));
    entry->hash = hash;
    entry->text = copy;
    entry->text_len = len;
    entry->bytes = bytes;
    entry->size = size;
    entry->face_serial = face_serial;
    entry->blob = blob;
    entry->bucket_next = g_text_buckets[hash & (OHOS_TEXT_CACHE_BUCKETS - 1)];
    g_text_buckets[hash & (OHOS_TEXT_CACHE_BUCKETS - 1)] = entry;
    OhosTextLruPushFront(entry);
    g_text_cached_bytes += bytes;
    return 1;
}

// Drops every cached font/blob plus the fill brushes: they all carry either the typeface
// or the effect objects that are about to be replaced.
static void OhosFlushTextCaches(void) {
    OhosFontCacheFlush();
    OhosTextCacheReset();
    OhosFlushFillBrushCache();
}

void ohos_host_set_font_file(const char* path) {
    // The caches are dropped before the old typeface: a cached Font/blob references it.
    OhosFlushTextCaches();
    if (g_custom_typeface != NULL) {
        OH_Drawing_TypefaceDestroy(g_custom_typeface);
        g_custom_typeface = NULL;
    }
    g_typeface_serial++;
    if (g_typeface_serial == 0) {
        g_typeface_serial = 1;
    }
    if (path == NULL || *path == '\0') {
        return;
    }
    g_custom_typeface = OH_Drawing_TypefaceCreateFromFile(path, 0);
    fprintf(stderr, "[openharmony-host] font file %s -> %s\n", path,
            g_custom_typeface != NULL ? "loaded" : "failed");
}

int ohos_host_draw_text(int x, int y, const char* utf8, float size, unsigned int argb) {
    if (g_canvas == NULL || utf8 == NULL || *utf8 == '\0') {
        return -1;
    }
    const size_t len = strlen(utf8);
    const unsigned int face_serial = g_custom_typeface != NULL ? g_typeface_serial : 0u;
    OH_Drawing_TextBlob* blob = OhosTextBlobCacheGet(utf8, len, size, face_serial);
    int cached = blob != NULL;
    if (blob == NULL) {
        OH_Drawing_Font* font = OhosFontGet(size, face_serial);
        if (font == NULL) {
            return -1;
        }
        blob = OH_Drawing_TextBlobCreateFromString(utf8, font, TEXT_ENCODING_UTF8);
        if (blob == NULL) {
            return -1;
        }
        cached = OhosTextBlobCachePut(utf8, len, size, face_serial, blob);
    }
    int rc = -1;
    OH_Drawing_Brush* brush = OhosFillBrushGet(argb);
    if (brush != NULL) {
        OH_Drawing_CanvasAttachBrush(g_canvas, brush);
        OH_Drawing_CanvasDrawTextBlob(g_canvas, blob, (float)x, (float)y);
        OH_Drawing_CanvasDetachBrush(g_canvas);
        rc = 0;
    }
    if (!cached) {
        OH_Drawing_TextBlobDestroy(blob);
    }
    return rc;
}

void ohos_host_draw_polyline(const float* xy, int count, int closed, unsigned int argb, int filled, float stroke_width) {
    if (g_canvas == NULL || xy == NULL || count < 2) {
        return;
    }
    OhosDrawingHandle<OH_Drawing_Path> path(OH_Drawing_PathDestroy);
    path.Adopt(OH_Drawing_PathCreate());
    if (path.Get() == NULL) {
        return;
    }
    OH_Drawing_PathMoveTo(path.Get(), xy[0], xy[1]);
    for (int i = 1; i < count; i++) {
        OH_Drawing_PathLineTo(path.Get(), xy[i * 2], xy[i * 2 + 1]);
    }
    if (closed) {
        OH_Drawing_PathClose(path.Get());
    }
    if (filled) {
        OH_Drawing_Brush* brush = OhosFillBrushGet(argb);
        if (brush != NULL) {
            OH_Drawing_CanvasAttachBrush(g_canvas, brush);
            OH_Drawing_CanvasDrawPath(g_canvas, path.Get());
            OH_Drawing_CanvasDetachBrush(g_canvas);
        }
    } else {
        OhosDrawingHandle<OH_Drawing_Pen> pen(OH_Drawing_PenDestroy);
        pen.Adopt(OH_Drawing_PenCreate());
        if (pen.Get() == NULL) {
            return;
        }
        OH_Drawing_PenSetColor(pen.Get(), (uint32_t)argb);
        OH_Drawing_PenSetWidth(pen.Get(), stroke_width > 0.0f ? stroke_width : 1.0f);
        OH_Drawing_CanvasAttachPen(g_canvas, pen.Get());
        OH_Drawing_CanvasDrawPath(g_canvas, path.Get());
        OH_Drawing_CanvasDetachPen(g_canvas);
    }
}

int ohos_host_measure_text(const char* utf8, float size, int* width, int* height) {
    if (utf8 == NULL || *utf8 == '\0') {
        if (width != NULL) *width = 0;
        if (height != NULL) *height = 0;
        return -1;
    }
    // face_serial 0 keys the platform default face: measure_text has never applied the
    // custom typeface, and that stays so the cached font matches the old per-call font.
    OH_Drawing_Font* font = OhosFontGet(size > 0 ? size : 14.0f, 0u);
    if (font == NULL) {
        return -1;
    }
    float textWidth = 0.0f;
    float textHeight = 0.0f;
    OH_Drawing_Font_Metrics metrics;
    float ascent = OH_Drawing_FontGetMetrics(font, &metrics);
    (void)ascent;
    textHeight = metrics.ascent * -1.0f + metrics.descent;
    OH_Drawing_FontMeasureText(font, utf8, strlen(utf8), TEXT_ENCODING_UTF8, NULL, &textWidth);
    if (width != NULL) *width = (int)(textWidth + 0.5f);
    if (height != NULL) *height = (int)(textHeight + 0.5f);
    return 0;
}

void ohos_host_draw_save(void) {
    if (g_canvas != NULL) {
        OH_Drawing_CanvasSave(g_canvas);
    }
}

void ohos_host_draw_restore(void) {
    if (g_canvas != NULL) {
        OH_Drawing_CanvasRestore(g_canvas);
    }
}

void ohos_host_draw_clip_rect(float x, float y, float width, float height, int subtract) {
    if (g_canvas == NULL) {
        return;
    }
    OH_Drawing_Rect* rect = OH_Drawing_RectCreate(x, y, x + width, y + height);
    if (rect == NULL) {
        return;
    }
    OH_Drawing_CanvasClipRect(g_canvas, rect,
        subtract ? DIFFERENCE : INTERSECT, true);
    OH_Drawing_RectDestroy(rect);
}

void ohos_host_draw_clip_polyline(const float* xy, int count) {
    if (g_canvas == NULL || xy == NULL || count < 2) {
        return;
    }
    OH_Drawing_Path* path = OH_Drawing_PathCreate();
    if (path == NULL) {
        return;
    }
    OH_Drawing_PathMoveTo(path, xy[0], xy[1]);
    for (int i = 1; i < count; i++) {
        OH_Drawing_PathLineTo(path, xy[i * 2], xy[i * 2 + 1]);
    }
    OH_Drawing_PathClose(path);
    OH_Drawing_CanvasClipPath(g_canvas, path, INTERSECT, true);
    OH_Drawing_PathDestroy(path);
}

// --- image decode cache -------------------------------------------------------------
// Managed code re-serializes the image to PNG/JPEG bytes for every draw, so the host sees
// a fresh byte array each frame and there is no stable handle/version to key on: the
// decoded pixelmap is cached by content hash plus length instead. Unchanged bytes hit the
// cache across frames; a reloaded or edited resource changes the bytes, so it misses and
// decodes once. Sources larger than OHOS_IMAGE_HASH_MAX_BYTES are decoded every time (the
// hash cost is bounded) and the LRU cap bounds the retained decoded bitmaps.
#define OHOS_IMAGE_CACHE_MAX 8
#define OHOS_IMAGE_HASH_MAX_BYTES (8u * 1024u * 1024u)
// The decoded bitmaps are the real memory: 8 MiB of compressed data can decode to
// hundreds of MiB, so the cache also holds a decoded-byte budget and evicts by LRU.
#define OHOS_IMAGE_CACHE_MAX_BYTES (32u * 1024u * 1024u)

typedef struct {
    uint64_t hash;
    int length;
    OH_PixelmapNative* pixelmap;
    OH_Drawing_PixelMap* drawing;
    uint32_t width;
    uint32_t height;
    size_t decoded_bytes;
    uint64_t last_used;
} OhosImageCacheEntry;

static OhosImageCacheEntry g_image_cache[OHOS_IMAGE_CACHE_MAX];
static uint64_t g_image_cache_clock = 0;
static size_t g_image_cache_bytes = 0;

// 4-lane 64-bit mix (32 bytes/iteration): the hash runs over every byte of the
// payload on each draw, so it has to stay well above the decode it replaces.
static uint64_t OhosImageHash(const void* data, size_t length) {
    const uint8_t* bytes = (const uint8_t*)data;
    uint64_t h0 = 0x9e3779b97f4a7c15ull;
    uint64_t h1 = 0xbf58476d1ce4e5b9ull;
    uint64_t h2 = 0x94d049bb133111ebull;
    uint64_t h3 = 0x2545f4914f6cdd1dull;
    size_t i = 0;
    for (; i + 32 <= length; i += 32) {
        uint64_t w0 = 0, w1 = 0, w2 = 0, w3 = 0;
        memcpy(&w0, bytes + i, 8);
        memcpy(&w1, bytes + i + 8, 8);
        memcpy(&w2, bytes + i + 16, 8);
        memcpy(&w3, bytes + i + 24, 8);
        h0 = (h0 ^ w0) * 0x9e3779b185ebca87ull;
        h0 ^= h0 >> 32;
        h1 = (h1 ^ w1) * 0xc2b2ae3d27d4eb4full;
        h1 ^= h1 >> 29;
        h2 = (h2 ^ w2) * 0x165667b19e3779f9ull;
        h2 ^= h2 >> 31;
        h3 = (h3 ^ w3) * 0x85ebca77c2b2ae63ull;
        h3 ^= h3 >> 27;
    }
    for (; i + 8 <= length; i += 8) {
        uint64_t word = 0;
        memcpy(&word, bytes + i, sizeof(word));
        h0 = (h0 ^ word) * 0x9e3779b185ebca87ull;
        h0 ^= h0 >> 32;
    }
    for (; i < length; i++) {
        h0 = (h0 ^ bytes[i]) * 0x9e3779b185ebca87ull;
        h0 ^= h0 >> 32;
    }
    uint64_t hash = h0 ^ (h1 * 0x9e3779b97f4a7c15ull) ^ (h2 * 0xc2b2ae3d27d4eb4full) ^
                    (h3 * 0x165667b19e3779f9ull);
    hash ^= (uint64_t)length;
    hash *= 0x9e3779b97f4a7c15ull;
    hash ^= hash >> 32;
    return hash;
}

static void OhosImageCacheRelease(OhosImageCacheEntry* entry) {
    if (entry->drawing != NULL) {
        OH_Drawing_PixelMapDissolve(entry->drawing);
    }
    if (entry->pixelmap != NULL) {
        OH_PixelmapNative_Release(entry->pixelmap);
    }
    g_image_cache_bytes -= entry->decoded_bytes;
    memset(entry, 0, sizeof(*entry));
}

static OhosImageCacheEntry* OhosImageCacheFind(uint64_t hash, int length) {
    for (int i = 0; i < OHOS_IMAGE_CACHE_MAX; i++) {
        OhosImageCacheEntry* entry = &g_image_cache[i];
        if (entry->pixelmap != NULL && entry->hash == hash && entry->length == length) {
            entry->last_used = ++g_image_cache_clock;
            return entry;
        }
    }
    return NULL;
}

// Empty slot after the byte budget is satisfied; NULL when even an empty cache cannot
// hold the decoded image.
static OhosImageCacheEntry* OhosImageCacheReserve(size_t decoded_bytes) {
    if (decoded_bytes > OHOS_IMAGE_CACHE_MAX_BYTES) {
        return NULL;
    }
    while (g_image_cache_bytes + decoded_bytes > OHOS_IMAGE_CACHE_MAX_BYTES) {
        int oldest_slot = -1;
        uint64_t oldest = UINT64_MAX;
        for (int i = 0; i < OHOS_IMAGE_CACHE_MAX; i++) {
            if (g_image_cache[i].pixelmap != NULL && g_image_cache[i].last_used < oldest) {
                oldest = g_image_cache[i].last_used;
                oldest_slot = i;
            }
        }
        if (oldest_slot < 0) {
            break;
        }
        OhosImageCacheRelease(&g_image_cache[oldest_slot]);
    }
    int slot = -1;
    for (int i = 0; i < OHOS_IMAGE_CACHE_MAX; i++) {
        if (g_image_cache[i].pixelmap == NULL) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        uint64_t oldest = UINT64_MAX;
        for (int i = 0; i < OHOS_IMAGE_CACHE_MAX; i++) {
            if (g_image_cache[i].last_used < oldest) {
                oldest = g_image_cache[i].last_used;
                slot = i;
            }
        }
    }
    if (slot < 0) {
        return NULL;
    }
    OhosImageCacheRelease(&g_image_cache[slot]);
    return &g_image_cache[slot];
}

static OH_PixelmapNative* OhosDecodePixelmap(const void* data, int length) {
    if (!ohos_host_optional_image_available()) {
        return NULL;  // no ImageSource/Pixelmap library on this image: decoding stays off
    }
    OH_ImageSourceNative* source = NULL;
    if (OH_ImageSourceNative_CreateFromData((uint8_t*)data, (size_t)length, &source) != IMAGE_SUCCESS || source == NULL) {
        return NULL;
    }
    OH_PixelmapNative* pixelmap = NULL;
    if (OH_ImageSourceNative_CreatePixelmap(source, NULL, &pixelmap) != IMAGE_SUCCESS) {
        pixelmap = NULL;
    }
    OH_ImageSourceNative_Release(source);
    return pixelmap;
}

static void OhosPixelmapQuerySize(OH_PixelmapNative* pixelmap, uint32_t* width, uint32_t* height) {
    *width = 0;
    *height = 0;
    OH_Pixelmap_ImageInfo* info = NULL;
    if (OH_PixelmapImageInfo_Create(&info) != IMAGE_SUCCESS || info == NULL) {
        return;
    }
    if (OH_PixelmapNative_GetImageInfo(pixelmap, info) == IMAGE_SUCCESS) {
        OH_PixelmapImageInfo_GetWidth(info, width);
        OH_PixelmapImageInfo_GetHeight(info, height);
    }
    OH_PixelmapImageInfo_Release(info);
}

int ohos_host_draw_image_bytes(const void* data, int length, float x, float y, float width, float height) {
    if (g_canvas == NULL || data == NULL || length <= 0) {
        return -1;
    }
    const int cacheable = (size_t)length <= OHOS_IMAGE_HASH_MAX_BYTES;
    uint64_t hash = 0;
    OhosImageCacheEntry* entry = NULL;
    if (cacheable) {
        hash = OhosImageHash(data, (size_t)length);
        entry = OhosImageCacheFind(hash, length);
    }
    OH_Drawing_PixelMap* drawing = NULL;
    OH_PixelmapNative* owned_pixelmap = NULL;  // temporary, released at the end when not cached
    uint32_t pixel_width = 0;
    uint32_t pixel_height = 0;
    if (entry != NULL) {
        drawing = entry->drawing;
        pixel_width = entry->width;
        pixel_height = entry->height;
    } else {
        owned_pixelmap = OhosDecodePixelmap(data, length);
        if (owned_pixelmap == NULL) {
            return -1;
        }
        drawing = OH_Drawing_PixelMapGetFromOhPixelMapNative(owned_pixelmap);
        if (drawing != NULL) {
            OhosPixelmapQuerySize(owned_pixelmap, &pixel_width, &pixel_height);
        }
        if (cacheable && drawing != NULL) {
            const size_t decoded_bytes = (size_t)pixel_width * (size_t)pixel_height * 4u;
            OhosImageCacheEntry* slot = OhosImageCacheReserve(decoded_bytes);
            if (slot != NULL) {
                slot->hash = hash;
                slot->length = length;
                slot->pixelmap = owned_pixelmap;
                slot->drawing = drawing;
                slot->width = pixel_width;
                slot->height = pixel_height;
                slot->decoded_bytes = decoded_bytes;
                slot->last_used = ++g_image_cache_clock;
                g_image_cache_bytes += decoded_bytes;
                entry = slot;
                owned_pixelmap = NULL;  // the cache owns both objects now
            }
        }
    }

    int rc = -1;
    if (drawing != NULL) {
        // The source rectangle is the pixelmap's own size, not the destination size: the
        // decoded image is scaled into (x, y, width, height) instead of being sampled
        // against a wrong-sized source.
        const float src_width = pixel_width > 0 ? (float)pixel_width : width;
        const float src_height = pixel_height > 0 ? (float)pixel_height : height;
        OhosDrawingHandle<OH_Drawing_Rect> src(OH_Drawing_RectDestroy);
        OhosDrawingHandle<OH_Drawing_Rect> dst(OH_Drawing_RectDestroy);
        OhosDrawingHandle<OH_Drawing_SamplingOptions> sampling(OH_Drawing_SamplingOptionsDestroy);
        src.Adopt(OH_Drawing_RectCreate(0.0f, 0.0f, src_width, src_height));
        dst.Adopt(OH_Drawing_RectCreate(x, y, x + width, y + height));
        sampling.Adopt(OH_Drawing_SamplingOptionsCreate(FILTER_MODE_LINEAR, MIPMAP_MODE_LINEAR));
        if (src.Get() != NULL && dst.Get() != NULL && sampling.Get() != NULL) {
            OH_Drawing_CanvasDrawPixelMapRect(g_canvas, drawing, src.Get(), dst.Get(), sampling.Get());
            rc = 0;
        }
    }
    if (owned_pixelmap != NULL) {
        // Uncached draw (over the hash cap, or the wrapper failed): drop the temporary
        // wrapper and the decoded pixelmap.
        if (drawing != NULL) {
            OH_Drawing_PixelMapDissolve(drawing);
        }
        OH_PixelmapNative_Release(owned_pixelmap);
    }
    return rc;
}

int ohos_host_draw_present(void) {
    if (g_canvas == NULL || !g_surface_valid || g_surface_state == (int)OHOS_SURFACE_DESTROYED) {
        return -1;
    }
    if (!ohos_host_optional_native_window_available()) {
        return -1;  // reported once by the optional-library loader; present dropped silently
    }
    OHNativeWindow* native_window = (OHNativeWindow*)g_surface_window;
    int width = g_canvas_width;
    int height = g_canvas_height;
    void* pixels = OH_Drawing_BitmapGetPixels(g_canvas_bitmap);
    if (native_window == NULL || pixels == NULL) {
        return -1;
    }
    if (OhosHostNativeWindowConfigure(native_window, width, height) != 0) {
        return -1;
    }
    OhosPresentFrame frame(native_window, true);
    if (!frame.valid()) {
        return -1;
    }
    BufferHandle* handle = frame.handle();
    if (handle != NULL && handle->fd >= 0 && handle->size > 0 && handle->stride > 0) {
        void* addr = OhosHostPresentMapAcquire(native_window, handle->fd, handle->virAddr, (size_t)handle->size);
        if (addr != NULL) {
            OhosHostPresentCopyRows(addr, (size_t)handle->stride, pixels,
                                    (size_t)width * 4, height, (size_t)handle->size);
        }
    }
    // frame's destructor flushes the requested buffer exactly once.
    fprintf(stderr, "[openharmony-host] canvas presented (%dx%d)\n", width, height);
    return 0;
}


// ---------------------------------------------------------------------------
// Sensor Kit (NDK sensors/oh_sensor.h): subscribe/unsubscribe and forward one
// reading per event to the managed listener set by the runtime.
// ---------------------------------------------------------------------------
#include <sensors/oh_sensor.h>

static Sensor_SubscriptionId* g_sensor_id = NULL;
static Sensor_SubscriptionAttribute* g_sensor_attr = NULL;
static Sensor_Subscriber* g_sensor_subscriber = NULL;
// The listener carries four components: ORIENTATION (256) reports Euler angles in data[0..2],
// while ROTATION_VECTOR (259) additionally reports the scalar part in data[3] (w defaults to
// 1.0 for three-component payloads such as accelerometer/gyroscope/barometer readings).
static void (*g_sensor_listener)(int type, float x, float y, float z, float w, long long timestamp) = NULL;

static void OhosSensorEventCallback(Sensor_Event* event) {
    if (event == NULL || g_sensor_listener == NULL) {
        return;
    }
    Sensor_Type type = SENSOR_TYPE_ACCELEROMETER;
    OH_SensorEvent_GetType(event, &type);
    float* data = NULL;
    uint32_t length = 0;
    OH_SensorEvent_GetData(event, &data, &length);
    int64_t timestamp = 0;
    OH_SensorEvent_GetTimestamp(event, &timestamp);
    float x = (data != NULL && length > 0) ? data[0] : 0.0f;
    float y = (data != NULL && length > 1) ? data[1] : 0.0f;
    float z = (data != NULL && length > 2) ? data[2] : 0.0f;
    float w = (data != NULL && length > 3) ? data[3] : 1.0f;
    g_sensor_listener((int)type, x, y, z, w, (long long)timestamp);
}

void ohos_host_sensor_set_listener(void* listener) {
    g_sensor_listener = (void (*)(int, float, float, float, float, long long))listener;
}

void ohos_host_sensor_stop(void);

int ohos_host_sensor_is_supported(int type) {
    if (!ohos_host_optional_sensor_available()) {
        return 0;  // no sensor library on this image: nothing is supported
    }
    uint32_t capacity = 32;
    Sensor_Info** infos = OH_Sensor_CreateInfos(capacity);
    if (infos == NULL) {
        return 0;
    }
    uint32_t count = capacity;
    if (OH_Sensor_GetInfos(infos, &count) != SENSOR_SUCCESS) {
        OH_Sensor_DestroyInfos(infos, capacity);
        return 0;
    }
    int supported = 0;
    for (uint32_t i = 0; i < count; i++) {
        Sensor_Type current = SENSOR_TYPE_ACCELEROMETER;
        if (OH_SensorInfo_GetType(infos[i], &current) == SENSOR_SUCCESS && (int)current == type) {
            supported = 1;
            break;
        }
    }
    OH_Sensor_DestroyInfos(infos, capacity);
    return supported;
}

int ohos_host_sensor_start(int type, int interval_ms) {
    if (!ohos_host_optional_sensor_available()) {
        return -1;  // no sensor library on this image: subscription stays off
    }
    ohos_host_sensor_stop();
    Sensor_SubscriptionId* id = OH_Sensor_CreateSubscriptionId();
    Sensor_SubscriptionAttribute* attr = OH_Sensor_CreateSubscriptionAttribute();
    Sensor_Subscriber* subscriber = OH_Sensor_CreateSubscriber();
    if (id == NULL || attr == NULL || subscriber == NULL) {
        ohos_host_sensor_stop();
        return -1;
    }
    OH_SensorSubscriptionId_SetType(id, (Sensor_Type)type);
    OH_SensorSubscriptionAttribute_SetSamplingInterval(attr, interval_ms * 1000000LL);
    OH_SensorSubscriber_SetCallback(subscriber, OhosSensorEventCallback);
    Sensor_Result result = OH_Sensor_Subscribe(id, attr, subscriber);
    if (result != SENSOR_SUCCESS) {
        OH_Sensor_DestroySubscriptionId(id);
        OH_Sensor_DestroySubscriptionAttribute(attr);
        OH_Sensor_DestroySubscriber(subscriber);
        return (int)result;
    }
    g_sensor_id = id;
    g_sensor_attr = attr;
    g_sensor_subscriber = subscriber;
    return 0;
}

void ohos_host_sensor_stop(void) {
    if (g_sensor_id != NULL && g_sensor_subscriber != NULL) {
        OH_Sensor_Unsubscribe(g_sensor_id, g_sensor_subscriber);
    }
    if (g_sensor_id != NULL) {
        OH_Sensor_DestroySubscriptionId(g_sensor_id);
        g_sensor_id = NULL;
    }
    if (g_sensor_attr != NULL) {
        OH_Sensor_DestroySubscriptionAttribute(g_sensor_attr);
        g_sensor_attr = NULL;
    }
    if (g_sensor_subscriber != NULL) {
        OH_Sensor_DestroySubscriber(g_sensor_subscriber);
        g_sensor_subscriber = NULL;
    }
}


// ---------------------------------------------------------------------------
// Notification Kit: forwards a publish request to the ArkTS shell through the
// NAPI layer (the shell registers a sink with registerNotificationSink).
// ---------------------------------------------------------------------------
#ifdef __cplusplus
extern "C"
#endif
void OhosNotifyNotification(int id, const char* title, const char* text);

int ohos_host_notification_show(int id, const char* title, const char* text) {
    if (title == NULL) {
        return -1;
    }
    OhosNotifyNotification(id, title, text != NULL ? text : "");
    return 0;
}


// ---------------------------------------------------------------------------
// Pinch input: the shell reports phase/scale/centre; the managed listener set
// through ohos_host_register_pinch receives them.
// ---------------------------------------------------------------------------
static void (*g_pinch_listener)(int phase, double scale, float x, float y) = NULL;

void ohos_host_register_pinch(void* callback) {
    g_pinch_listener = (void (*)(int, double, float, float))callback;
}

#ifdef __cplusplus
extern "C"
#endif
void OhosNotifyPinch(int phase, double scale, float x, float y) {
    if (g_pinch_listener != NULL) {
        g_pinch_listener(phase, scale, x, y);
    }
}


// ---------------------------------------------------------------------------
// Accessibility: the runtime publishes a shadow node tree every frame. The
// provider callbacks in the NAPI layer read it back through the accessors
// below and turn it into ArkUI accessibility element information.
// ---------------------------------------------------------------------------
#include <stdlib.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

// Argument order is the publish contract shared with the managed DllImport and the NAPI
// consumer; see the declarations in openharmony_host.h before touching this struct or the
// signatures below. Absent values: hint may be NULL, a range is only valid when
// range_min <= range_max (NaN compares false), checked is -1 when unknown/not applicable.
typedef struct OhosAccessibilityNode {
    int id;
    int parent_id;
    char* role;
    char* text;
    char* description;
    char* hint;
    float x, y, width, height;
    int flags;
    int actions;
    double range_min, range_max, range_current;
    int checked;
} OhosAccessibilityNode;

static OhosAccessibilityNode* g_a11y_nodes = NULL;
static int g_a11y_capacity = 0;
static int g_a11y_fill = 0;
static int g_a11y_count = 0;

// Serializes the shadow node table between the managed publisher (begin/node/commit on the
// app thread) and the NAPI accessibility provider (count/get on the ArkUI thread).
static pthread_mutex_t g_a11y_mutex = PTHREAD_MUTEX_INITIALIZER;

// The getter must never hand the interned node strings to the provider: begin frees the whole
// table while the provider is still forwarding the fields to the ArkUI setters (A11yFillElement
// in host_napi.cpp). Each get copies the strings under g_a11y_mutex into per-thread storage
// that stays valid until the next get on that thread, so a concurrent publish can free the
// table without invalidating the caller's fill. The storage hangs off a pthread key instead of
// __thread on purpose: the host library is dlopen'ed, and the OpenHarmony toolchain lowers
// __thread to emulated TLS (libc++_shared's __emutls_get_address), while the key needs no
// TLS relocations; its destructor frees the copies when the thread exits.
#define OHOS_A11Y_COPY_SLOTS 4

typedef struct OhosA11yCopySet {
    char* strings[OHOS_A11Y_COPY_SLOTS];
    size_t sizes[OHOS_A11Y_COPY_SLOTS];
} OhosA11yCopySet;

static pthread_key_t g_a11y_copy_key;
static pthread_once_t g_a11y_copy_once = PTHREAD_ONCE_INIT;
static int g_a11y_copy_key_ready = 0;

static void OhosA11yCopySetDestroy(void* value) {
    OhosA11yCopySet* set = (OhosA11yCopySet*)value;
    if (set == NULL) {
        return;
    }
    for (int i = 0; i < OHOS_A11Y_COPY_SLOTS; i++) {
        free(set->strings[i]);
    }
    free(set);
}

static void OhosA11yCopyKeyInit(void) {
    g_a11y_copy_key_ready = pthread_key_create(&g_a11y_copy_key, OhosA11yCopySetDestroy) == 0;
}

// Caller holds g_a11y_mutex. Returns NULL when the thread cannot have copies (all string
// outputs then report the field as absent, which is the safe failure mode).
static OhosA11yCopySet* OhosA11yCopySetForThread(void) {
    pthread_once(&g_a11y_copy_once, OhosA11yCopyKeyInit);
    if (!g_a11y_copy_key_ready) {
        return NULL;
    }
    OhosA11yCopySet* set = (OhosA11yCopySet*)pthread_getspecific(g_a11y_copy_key);
    if (set == NULL) {
        set = (OhosA11yCopySet*)calloc(1, sizeof(OhosA11yCopySet));
        if (set == NULL || pthread_setspecific(g_a11y_copy_key, set) != 0) {
            free(set);
            return NULL;
        }
    }
    return set;
}

static const char* OhosA11yCopyString(OhosA11yCopySet* set, int slot, const char* value) {
    if (set == NULL || value == NULL) {
        return NULL;
    }
    size_t length = strlen(value) + 1;
    if (set->sizes[slot] < length) {
        char* grown = (char*)realloc(set->strings[slot], length);
        if (grown == NULL) {
            return NULL;   // report the field as absent rather than a dangling pointer
        }
        set->strings[slot] = grown;
        set->sizes[slot] = length;
    }
    memcpy(set->strings[slot], value, length);
    return set->strings[slot];
}

static char* OhosA11yString(const char* value) {
    if (value == NULL) {
        return NULL;
    }
    size_t length = strlen(value) + 1;
    char* copy = (char*)malloc(length);
    if (copy != NULL) {
        memcpy(copy, value, length);
    }
    return copy;
}

// Caller holds g_a11y_mutex (begin is the only caller). The node array itself is kept: the
// strings of the previous publish are released here, the slots are overwritten by the next
// publish and the array is only reallocated when the new count needs more room.
static void OhosA11yFreeNodeStrings(void) {
    if (g_a11y_nodes != NULL) {
        for (int i = 0; i < g_a11y_fill; i++) {
            free(g_a11y_nodes[i].role);
            free(g_a11y_nodes[i].text);
            free(g_a11y_nodes[i].description);
            free(g_a11y_nodes[i].hint);
            g_a11y_nodes[i].role = NULL;
            g_a11y_nodes[i].text = NULL;
            g_a11y_nodes[i].description = NULL;
            g_a11y_nodes[i].hint = NULL;
        }
    }
    g_a11y_fill = 0;
    g_a11y_count = 0;
}

// id -> index map over the published table, filled by ohos_host_accessibility_node as each
// slot is written, so the provider's id lookups are O(1) instead of a linear scan. Open
// addressing with linear probing; node ids are positive and 0 marks an empty slot. The arrays
// are kept for the process lifetime and only grow. If a grow ever fails, the map is marked
// incomplete and lookups fall back to the scan, so a query never misses a published node.
static int* g_a11y_id_keys = NULL;
static int* g_a11y_id_values = NULL;
static int g_a11y_id_capacity = 0;
static int g_a11y_id_used = 0;
static int g_a11y_id_complete = 1;

static size_t OhosA11yIdSlot(int id, int capacity) {
    return ((size_t)(unsigned int)id * 2654435761u) & (size_t)(capacity - 1);
}

// Caller holds g_a11y_mutex.
static void OhosA11yIndexClear(void) {
    if (g_a11y_id_keys != NULL) {
        memset(g_a11y_id_keys, 0, (size_t)g_a11y_id_capacity * sizeof(int));
    }
    g_a11y_id_used = 0;
    g_a11y_id_complete = 1;
}

// Caller holds g_a11y_mutex. Doubles the table once the load factor would pass 1/2.
static int OhosA11yIndexGrow(void) {
    int new_capacity = g_a11y_id_capacity == 0 ? 64 : g_a11y_id_capacity * 2;
    int* keys = (int*)calloc((size_t)new_capacity, sizeof(int));
    int* values = (int*)malloc((size_t)new_capacity * sizeof(int));
    if (keys == NULL || values == NULL) {
        free(keys);
        free(values);
        return -1;
    }
    for (int i = 0; i < g_a11y_id_capacity; i++) {
        int id = g_a11y_id_keys[i];
        if (id == 0) {
            continue;
        }
        size_t slot = OhosA11yIdSlot(id, new_capacity);
        while (keys[slot] != 0) {
            slot = (slot + 1) & (size_t)(new_capacity - 1);
        }
        keys[slot] = id;
        values[slot] = g_a11y_id_values[i];
    }
    free(g_a11y_id_keys);
    free(g_a11y_id_values);
    g_a11y_id_keys = keys;
    g_a11y_id_values = values;
    g_a11y_id_capacity = new_capacity;
    return 0;
}

// Caller holds g_a11y_mutex. The first node published under an id wins, matching the linear
// scan this map replaces.
static void OhosA11yIndexInsert(int id, int index) {
    if (id <= 0) {
        return;   // ids are positive; the empty-slot marker is 0
    }
    if ((g_a11y_id_used + 1) * 2 > g_a11y_id_capacity && OhosA11yIndexGrow() != 0) {
        g_a11y_id_complete = 0;
        return;
    }
    size_t slot = OhosA11yIdSlot(id, g_a11y_id_capacity);
    while (g_a11y_id_keys[slot] != 0) {
        if (g_a11y_id_keys[slot] == id) {
            return;
        }
        slot = (slot + 1) & (size_t)(g_a11y_id_capacity - 1);
    }
    g_a11y_id_keys[slot] = id;
    g_a11y_id_values[slot] = index;
    g_a11y_id_used++;
}

int ohos_host_accessibility_begin(int count) {
    pthread_mutex_lock(&g_a11y_mutex);
    // The provider cannot observe the cleared table: g_a11y_count drops to 0 here and is only
    // raised again by commit, and the getter refuses an index outside [0, count).
    OhosA11yFreeNodeStrings();
    OhosA11yIndexClear();
    if (count <= 0) {
        pthread_mutex_unlock(&g_a11y_mutex);
        return 0;
    }
    if (g_a11y_capacity < count) {
        OhosAccessibilityNode* grown =
            (OhosAccessibilityNode*)realloc(g_a11y_nodes, (size_t)count * sizeof(OhosAccessibilityNode));
        if (grown == NULL) {
            pthread_mutex_unlock(&g_a11y_mutex);
            return -1;
        }
        g_a11y_nodes = grown;
        g_a11y_capacity = count;
    }
    pthread_mutex_unlock(&g_a11y_mutex);
    return 0;
}

// 16 arguments, in this exact order: id, parent_id, role, text, description, hint,
// x, y, width, height, flags, actions, range_min, range_max, range_current, checked.
// The order is mirrored by the managed DllImport (maui-ohos OpenHarmonyAccessibility.cs)
// and asserted off-device by the interaction harness; see openharmony_host.h.
int ohos_host_accessibility_node(int id, int parent_id, const char* role, const char* text,
                                 const char* description, const char* hint,
                                 float x, float y, float width, float height,
                                 int flags, int actions,
                                 double range_min, double range_max, double range_current,
                                 int checked) {
    pthread_mutex_lock(&g_a11y_mutex);
    if (g_a11y_nodes == NULL || g_a11y_fill >= g_a11y_capacity) {
        pthread_mutex_unlock(&g_a11y_mutex);
        return -1;
    }
    int index = g_a11y_fill;
    OhosAccessibilityNode* node = &g_a11y_nodes[index];
    node->id = id;
    node->parent_id = parent_id;
    node->role = OhosA11yString(role);
    node->text = OhosA11yString(text);
    node->description = OhosA11yString(description);
    node->hint = OhosA11yString(hint);
    node->x = x;
    node->y = y;
    node->width = width;
    node->height = height;
    node->flags = flags;
    node->actions = actions;
    node->range_min = range_min;
    node->range_max = range_max;
    node->range_current = range_current;
    node->checked = checked;
    g_a11y_fill = index + 1;
    OhosA11yIndexInsert(id, index);
    pthread_mutex_unlock(&g_a11y_mutex);
    return 0;
}

int ohos_host_accessibility_commit(void) {
    pthread_mutex_lock(&g_a11y_mutex);
    g_a11y_count = g_a11y_fill;
    int count = g_a11y_count;
    pthread_mutex_unlock(&g_a11y_mutex);
    return count;
}

int ohos_host_accessibility_count(void) {
    pthread_mutex_lock(&g_a11y_mutex);
    int count = g_a11y_count;
    pthread_mutex_unlock(&g_a11y_mutex);
    return count;
}

// Published node count for the shell's accessibility self-check (host.accessibilityNodeCount).
// Same value as ohos_host_accessibility_count; the distinct name keeps the publish-contract
// reflection described above from mistaking this symbol for the 16-argument publish function.
int ohos_host_accessibility_node_count(void) {
    return ohos_host_accessibility_count();
}

// Index of the published node with this id, or -1 when no committed node carries it. O(1)
// through the id map the publisher maintains; when the map could not be grown, this falls
// back to the linear scan the map replaces. Does not read any node field, so the caller can
// follow up with exactly one ohos_host_accessibility_get for the record it needs.
int ohos_host_accessibility_index_of(int id) {
    pthread_mutex_lock(&g_a11y_mutex);
    int index = -1;
    if (id > 0 && g_a11y_count > 0) {
        if (!g_a11y_id_complete) {
            for (int i = 0; i < g_a11y_count; i++) {
                if (g_a11y_nodes[i].id == id) {
                    index = i;
                    break;
                }
            }
        } else if (g_a11y_id_capacity > 0) {
            size_t slot = OhosA11yIdSlot(id, g_a11y_id_capacity);
            while (g_a11y_id_keys[slot] != 0) {
                if (g_a11y_id_keys[slot] == id) {
                    int candidate = g_a11y_id_values[slot];
                    if (candidate >= 0 && candidate < g_a11y_count) {
                        index = candidate;
                    }
                    break;
                }
                slot = (slot + 1) & (size_t)(g_a11y_id_capacity - 1);
            }
        }
    }
    pthread_mutex_unlock(&g_a11y_mutex);
    return index;
}

// Mirrors ohos_host_accessibility_node: 17 arguments, same order plus the output pointers
// (index first, then the 16 published fields). See openharmony_host.h. The string outputs
// point at per-thread copies taken under the table lock (OhosA11yCopySetForThread), not at
// the interned node fields, so begin can free the table while the provider fills its element.
int ohos_host_accessibility_get(int index, int* id, int* parent_id, const char** role,
                                const char** text, const char** description, const char** hint,
                                float* x, float* y, float* width, float* height,
                                int* flags, int* actions,
                                double* range_min, double* range_max, double* range_current,
                                int* checked) {
    pthread_mutex_lock(&g_a11y_mutex);
    if (g_a11y_nodes == NULL || index < 0 || index >= g_a11y_count) {
        pthread_mutex_unlock(&g_a11y_mutex);
        return -1;
    }
    OhosAccessibilityNode* node = &g_a11y_nodes[index];
    OhosA11yCopySet* copies = OhosA11yCopySetForThread();
    if (id != NULL) *id = node->id;
    if (parent_id != NULL) *parent_id = node->parent_id;
    if (role != NULL) *role = OhosA11yCopyString(copies, 0, node->role);
    if (text != NULL) *text = OhosA11yCopyString(copies, 1, node->text);
    if (description != NULL) *description = OhosA11yCopyString(copies, 2, node->description);
    if (hint != NULL) *hint = OhosA11yCopyString(copies, 3, node->hint);
    if (x != NULL) *x = node->x;
    if (y != NULL) *y = node->y;
    if (width != NULL) *width = node->width;
    if (height != NULL) *height = node->height;
    if (flags != NULL) *flags = node->flags;
    if (actions != NULL) *actions = node->actions;
    if (range_min != NULL) *range_min = node->range_min;
    if (range_max != NULL) *range_max = node->range_max;
    if (range_current != NULL) *range_current = node->range_current;
    if (checked != NULL) *checked = node->checked;
    pthread_mutex_unlock(&g_a11y_mutex);
    return 0;
}

#ifdef __cplusplus
}
#endif
