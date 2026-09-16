// Standalone host smoke test (no NAPI), used to validate the hosting paths on device.
// The native host is loaded as a shared library (like the ArkTS shell does) so the
// managed side and this harness share the same instance of the host state.
//   one-shot : test_host <app_dir> <app_assembly_file> [app args...]
//   bridged  : test_host --bridge <app_dir> <app_assembly_file> <context_json>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "openharmony_host.h"

static OhosHostAppHandle* g_event_handle = NULL;

static int (*p_run_app)(const char*, const char*, int, const char* const*);
static int (*p_start_app)(const char*, const char*, const char*, const char*, OhosHostAppHandle**);
static void (*p_notify_lifecycle)(OhosHostAppHandle*, ohos_lifecycle_event);
static void (*p_set_node_content)(OhosHostAppHandle*, void*);
static int (*p_join_app)(OhosHostAppHandle*);

static void LoadHostLibrary(void) {
    void* lib = dlopen("libopenharmonyhost.so", RTLD_NOW);
    if (lib == NULL) {
        fprintf(stderr, "[test_host] dlopen(libopenharmonyhost.so) failed: %s\n", dlerror());
        exit(1);
    }
    p_run_app = (int (*)(const char*, const char*, int, const char* const*))dlsym(lib, "ohos_host_run_app");
    p_start_app = (int (*)(const char*, const char*, const char*, const char*, OhosHostAppHandle**))dlsym(lib, "ohos_host_start_app");
    p_notify_lifecycle = (void (*)(OhosHostAppHandle*, ohos_lifecycle_event))dlsym(lib, "ohos_host_notify_lifecycle");
    p_set_node_content = (void (*)(OhosHostAppHandle*, void*))dlsym(lib, "ohos_host_set_node_content");
    p_join_app = (int (*)(OhosHostAppHandle*))dlsym(lib, "ohos_host_join_app");
    if (p_run_app == NULL || p_start_app == NULL || p_notify_lifecycle == NULL ||
        p_set_node_content == NULL || p_join_app == NULL) {
        fprintf(stderr, "[test_host] host symbols missing\n");
        exit(1);
    }
}

static void* SendEvents(void* arg) {
    (void)arg;
    while (g_event_handle == NULL) {
        usleep(100 * 1000);
    }
    sleep(1);
    p_notify_lifecycle(g_event_handle, OHOS_LIFECYCLE_CREATE);
    p_notify_lifecycle(g_event_handle, OHOS_LIFECYCLE_FOREGROUND);
    sleep(1);
    p_set_node_content(g_event_handle, (void*)0x1234);
    p_notify_lifecycle(g_event_handle, OHOS_LIFECYCLE_BACKGROUND);
    sleep(1);
    p_notify_lifecycle(g_event_handle, OHOS_LIFECYCLE_FOREGROUND);
    p_notify_lifecycle(g_event_handle, OHOS_LIFECYCLE_DESTROY);
    return NULL;
}

static int RunOneShot(int argc, char** argv) {
    int code = p_run_app(argv[1], argv[2], argc - 3, (const char* const*)(argv + 3));
    printf("[test_host] managed exit code = %d\n", code);
    return code;
}

static int RunBridged(int argc, char** argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s --bridge <app_dir> <app_assembly_file> <context_json>\n", argv[0]);
        return 64;
    }
    pthread_t events;
    pthread_create(&events, NULL, SendEvents, NULL);

    int rc = p_start_app(argv[2], argv[3], NULL, argv[4], &g_event_handle);
    if (rc != 0 || g_event_handle == NULL) {
        fprintf(stderr, "[test_host] start_app failed rc=%d\n", rc);
        return 1;
    }
    printf("[test_host] bridge started; events thread active\n");
    fflush(stdout);
    pthread_join(events, NULL);

    int exit_code = p_join_app(g_event_handle);
    printf("[test_host] managed exit code = %d\n", exit_code);
    return exit_code;
}

int main(int argc, char** argv) {
    LoadHostLibrary();
    if (argc >= 2 && strcmp(argv[1], "--bridge") == 0) {
        return RunBridged(argc, argv);
    }
    if (argc < 3) {
        fprintf(stderr, "usage: %s <app_dir> <app_assembly_file> [app args...]\n", argv[0]);
        fprintf(stderr, "       %s --bridge <app_dir> <app_assembly_file> <context_json>\n", argv[0]);
        return 64;
    }
    return RunOneShot(argc, argv);
}
