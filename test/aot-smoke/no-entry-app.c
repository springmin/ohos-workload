// Negative-control stand-in for the AOT probe (see docs/aot-single-entry.md and fake-aot-app.c):
// a library that loads fine but has NO openharmony_app_main export, so the host must log
// `aot=0`, close it and keep the hostfxr route instead of failing the launch. Used by
// test/aot-smoke/run-local-smoke.sh to exercise the R2-SHELL-EXT fallback branch on a host
// without a JIT payload: start_app then fails cleanly on the missing hostfxr, which is the
// expected outcome, while a crash or an `aot=1` line would fail the check.
int not_the_aot_entry(void) {
    return 0;
}
