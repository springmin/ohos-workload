// Native runtime host for OpenHarmony: loads hostfxr from the published app
// directory and invokes the managed bootstrap (Microsoft.OpenHarmony.Hosting).
#ifndef OPENHARMONY_HOST_H
#define OPENHARMONY_HOST_H

#ifdef __cplusplus
extern "C" {
#endif

// Runs a managed application.
//   app_dir             directory with the published output (libhostfxr.so,
//                       <app>.runtimeconfig.json, Microsoft.OpenHarmony.Hosting.dll)
//   app_assembly_file   app assembly file name inside app_dir (e.g. "hello-app.dll")
//   argc/argv           application arguments (may be NULL/0)
// Returns the managed exit code, or -1 on hosting failure.
int ohos_host_run_app(const char* app_dir, const char* app_assembly_file, int argc, const char* const* argv);

#ifdef __cplusplus
}
#endif

#endif  // OPENHARMONY_HOST_H
