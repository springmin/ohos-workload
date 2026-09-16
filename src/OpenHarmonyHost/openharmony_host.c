#include "openharmony_host.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

int ohos_host_run_app(const char* app_dir, const char* app_assembly_file, int argc, const char* const* argv) {
    char hostfxr_path[4096];
    char app_assembly_path[4096];
    if (path_join(hostfxr_path, sizeof(hostfxr_path), app_dir, "libhostfxr.so") != 0 ||
        path_join(app_assembly_path, sizeof(app_assembly_path), app_dir, app_assembly_file) != 0) {
        return -1;
    }

    void* hostfxr = dlopen(hostfxr_path, RTLD_NOW | RTLD_LOCAL);
    if (hostfxr == NULL) {
        fprintf(stderr, "[openharmony-host] dlopen(%s) failed: %s\n", hostfxr_path, dlerror());
        return -1;
    }

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
        fprintf(stderr, "[openharmony-host] hostfxr symbols missing\n");
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
