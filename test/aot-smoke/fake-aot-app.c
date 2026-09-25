// Hand-written stand-in for a NativeAOT application library (see docs/aot-single-entry.md).
// It exports the exact entry point the host looks up and records the payload it receives, so
// the host's AOT direct-launch route can be verified on device without the ilc pack:
//
//   NDK=~/.harmonybrew/Cellar/ohos-sdk/*/native
//   $NDK/llvm/bin/clang++ --target=aarch64-linux-ohos --sysroot=$NDK/sysroot \
//       -fPIC -shared -O1 -o /tmp/aot-smoke/libFakeApp.so fake-aot-app.c
//   $NDK/llvm/bin/clang++ --target=aarch64-linux-ohos --sysroot=$NDK/sysroot \
//       -I src/OpenHarmonyHost -o /tmp/aot-smoke/test_host src/OpenHarmonyHost/test_host.c -ldl
//   cd /tmp/aot-smoke && LD_LIBRARY_PATH=<host so dir>:$NDK/sysroot/usr/lib/aarch64-linux-ohos \
//       ./test_host . FakeApp.dll alpha beta
//   cat payload-received.txt   # => "<abs path>/FakeApp.dll\nalpha\nbeta"
#include <stdio.h>

int openharmony_app_main(const char* payload) {
    FILE* out = fopen("payload-received.txt", "w");
    if (out != NULL) {
        fputs(payload, out);
        fclose(out);
    }
    return 7;  // distinctive exit code the driver must report
}
