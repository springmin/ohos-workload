// Off-device unit tests for the host status helpers (DEVICE-ROUND-57 follow-up).
// Pure C: compiles and runs on the development host, no device, no NAPI, no OpenHarmony SDK.
// Run through scripts/selftest-host-status.sh (it also checks the shipped sources are wired into
// CMakeLists.txt/build-host.sh and drives the mutation red control).
//
// The cases pin the append contract (missing/unwritable directories stay silent, the file is
// created 0600 and appended, control characters are flattened, the 600-character cap adds "...")
// and the exact mode-line shape including the interp/render/xwe token forms the existing
// scripts/tester-run.sh exec-mem readers match.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "host_status.h"

static int g_checks = 0;
static int g_failures = 0;

static void Check(int ok, const char* label) {
    g_checks++;
    if (ok) {
        printf("[PASS] %s\n", label);
    } else {
        g_failures++;
        printf("[FAIL] %s\n", label);
    }
}

static int ReadFile(const char* path, char* out, size_t out_size) {
    FILE* file = fopen(path, "rb");
    if (file == NULL) {
        return 0;
    }
    size_t got = fread(out, 1, out_size - 1, file);
    out[got] = '\0';
    fclose(file);
    return 1;
}

static int FileExists(const char* path) {
    return access(path, F_OK) == 0;
}

// Formats through the shipped helper and answers the formatted line ("" on failure).
static int FormatModeLine(char* out, size_t out_size, const char* caller, const char* interp,
                          const char* interp_source, const char* runtime_mode,
                          const char* mode_source, const char* xwe, const char* xwe_source,
                          const char* r2r, const char* wbcopy) {
    return OhosHostStatusFormatModeLine(out, out_size, caller, interp, interp_source, runtime_mode,
                                        mode_source, xwe, xwe_source, r2r, wbcopy);
}

int main(void) {
    const char* base = getenv("TMPDIR");
    if (base == NULL || base[0] == '\0') {
        base = "/tmp";
    }
    char dir[4096];
    snprintf(dir, sizeof(dir), "%s/host-status-test.XXXXXX", base);
    if (mkdtemp(dir) == NULL) {
        printf("[FAIL] setup: cannot create a temp dir under %s\n", base);
        printf("host-status: 1 checks, 1 failure(s)\n");
        return 1;
    }
    char path[4200];
    snprintf(path, sizeof(path), "%s/dotnet-status.txt", dir);

    // --- missing-directory semantics: silent, no crash, no file ---------------------------
    Check(OhosHostStatusAppendLine(NULL, "x") == 0, "append: NULL dir is refused");
    Check(OhosHostStatusAppendLine("", "x") == 0, "append: empty dir is refused");
    Check(OhosHostStatusAppendLine("/definitely/missing/dir", "x") == 0,
          "append: a missing directory answers 0 without creating anything");
    {
        char too_long[4200];
        memset(too_long, 'a', sizeof(too_long) - 1);
        too_long[sizeof(too_long) - 1] = '\0';
        Check(OhosHostStatusAppendLine(too_long, "x") == 0,
              "append: an over-long directory is refused");
    }
    Check(OhosHostStatusAppendLine(dir, NULL) == 0, "append: NULL message is refused");
    Check(!FileExists(path), "append: none of the refused calls created the file");

    // --- create + append + newline --------------------------------------------------------
    char content[8192];
    Check(OhosHostStatusAppendLine(dir, "first line") == 1, "append: first line reports 1");
    Check(FileExists(path), "append: the file is created on demand");
    Check(ReadFile(path, content, sizeof(content)) && strcmp(content, "first line\n") == 0,
          "append: the file carries exactly the line plus one newline");
    Check(OhosHostStatusAppendLine(dir, "second line") == 1, "append: second line reports 1");
    Check(ReadFile(path, content, sizeof(content)) &&
              strcmp(content, "first line\nsecond line\n") == 0,
          "append: a later call appends after the existing content");
    Check(OhosHostStatusAppendLine(dir, "") == 1, "append: an empty message still terminates a line");
    Check(ReadFile(path, content, sizeof(content)) &&
              strcmp(content, "first line\nsecond line\n\n") == 0,
          "append: the empty message wrote a bare newline");
    unlink(path);

    // --- flattening: control characters become spaces -------------------------------------
    Check(OhosHostStatusAppendLine(dir, "a\tb\rc\nd\x01""e\x7f""f") == 1, "append: control line lands");
    Check(ReadFile(path, content, sizeof(content)) && strcmp(content, "a b c d e f\n") == 0,
          "append: tab/CR/LF/C0/DEL are flattened to spaces");
    unlink(path);

    // --- cap: 600 characters kept, longer lines gain "..." --------------------------------
    {
        char message[1024];
        memset(message, 'x', 600);
        message[600] = '\0';
        Check(OhosHostStatusAppendLine(dir, message) == 1, "cap: an exactly-600 line lands");
        Check(ReadFile(path, content, sizeof(content)) &&
                  strlen(content) == 601 && content[600] == '\n' && strstr(content, "...") == NULL,
              "cap: exactly 600 characters stay unpadded and un-ellipsized");
        memset(message, 'y', 700);
        message[700] = '\0';
        Check(OhosHostStatusAppendLine(dir, message) == 1, "cap: an over-long line lands");
        Check(ReadFile(path, content, sizeof(content)) &&
                  strlen(content) == 601 + 604 && content[600] == '\n' &&
                  strncmp(content + 601, message, 600) == 0 &&
                  strcmp(content + 1201, "...\n") == 0,
              "cap: the over-long line is cut at 600 with a trailing ...");
        unlink(path);
    }

    // --- mode line: exact shape and the source variants -----------------------------------
    {
        char line[OHOS_HOST_STATUS_LINE_MAX + 4];
        Check(FormatModeLine(line, sizeof(line), "start_app", "3", "manifest", "interp",
                             "manifest", "0", "default", "off", "off") == 1,
              "mode: the interp=3 manifest line formats");
        Check(strcmp(line,
                     "OHOS_HOST mode caller=start_app interp=3 source=manifest "
                     "runtime-mode=interp source=manifest xwe=0 source=default r2r=off wbcopy=off") ==
                  0,
              "mode: the interp=3 manifest line has the exact documented shape");
        Check(strstr(line, "interp=3 source=manifest") != NULL &&
                  strstr(line, "runtime-mode=interp source=manifest") != NULL &&
                  strstr(line, "xwe=0 source=default") != NULL,
              "mode: the interp=/runtime-mode=/xwe= token shapes match the tester-run readers");

        Check(FormatModeLine(line, sizeof(line), "run_app", "0", "default", "jit", "default", "0",
                             "default", "default", "default") == 1 &&
                  strcmp(line,
                         "OHOS_HOST mode caller=run_app interp=0 source=default "
                         "runtime-mode=jit source=default xwe=0 source=default "
                         "r2r=default wbcopy=default") == 0,
              "mode: the jit default line formats (switches stay default)");
        Check(FormatModeLine(line, sizeof(line), "start_app", "0", "default", "aot", "manifest",
                             "1", "file", "default", "default") == 1 &&
                  strstr(line, "runtime-mode=aot source=manifest") != NULL &&
                  strstr(line, "xwe=1 source=file") != NULL,
              "mode: the aot manifest line carries the xwe=1 file source");
        Check(FormatModeLine(line, sizeof(line), "start_app", "2", "file", "interp", "file", "0",
                             "default", "default", "default") == 1 &&
                  strstr(line, "interp=2 source=file") != NULL &&
                  strstr(line, "r2r=default wbcopy=default") != NULL,
              "mode: mixed modes keep r2r/wbcopy default");

        // Failure shapes: NULL arguments and a too-small buffer reset the output.
        Check(FormatModeLine(NULL, sizeof(line), "c", "0", "d", "jit", "d", "0", "d", "d", "d") ==
                  0,
              "mode: NULL out is refused");
        Check(FormatModeLine(line, sizeof(line), NULL, "0", "d", "jit", "d", "0", "d", "d", "d") ==
                  0,
              "mode: NULL caller is refused");
        Check(FormatModeLine(line, sizeof(line), "c", NULL, "d", "jit", "d", "0", "d", "d", "d") ==
                  0,
              "mode: NULL interp is refused");
        Check(FormatModeLine(line, sizeof(line), "c", "0", "d", "jit", "d", "0", "d", "d", NULL) ==
                  0,
              "mode: NULL wbcopy is refused");
        line[0] = 'x';
        Check(FormatModeLine(line, 16, "c", "0", "d", "jit", "d", "0", "d", "d", "d") == 0 &&
                  line[0] == '\0',
              "mode: a too-small buffer is refused and the output is reset");
        Check(FormatModeLine(line, 0, "c", "0", "d", "jit", "d", "0", "d", "d", "d") == 0,
              "mode: a zero-size buffer is refused");

        // The formatted line appends and reads back exactly.
        Check(OhosHostStatusAppendLine(dir, line) == 1, "mode: the formatted line appends");
        Check(ReadFile(path, content, sizeof(content)) && strcmp(content, "") != 0 &&
                  content[strlen(content) - 1] == '\n',
              "mode: the appended line reads back");
        unlink(path);
    }

    rmdir(dir);
    printf("host-status: %d checks, %d failure(s)\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
