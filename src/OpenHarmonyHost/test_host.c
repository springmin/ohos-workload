// Standalone host smoke test (no NAPI): run a published managed app on device.
//   test_host <app_dir> <app_assembly_file> [app args...]
#include <stdio.h>
#include "openharmony_host.h"

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <app_dir> <app_assembly_file> [args...]\n", argv[0]);
        return 64;
    }
    int code = ohos_host_run_app(argv[1], argv[2], argc - 3, (const char* const*)(argv + 3));
    printf("[test_host] managed exit code = %d\n", code);
    return code;
}
