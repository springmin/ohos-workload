// Off-device unit tests for the clipboard NDK read wrapper (PASTEBOARD-FIX).
// Pure C: compiles and runs on the development host, no device, no NAPI, no OpenHarmony SDK.
// Run through scripts/selftest-host-clipboard.sh (it also checks the shipped sources are wired
// into CMakeLists.txt/build-host.sh and drives the mutation red control).
//
// The fake pasteboard API records every call, so the cases pin the contract, not just the
// return code: success copies the text byte-exact and destroys every object exactly once
// (plain -> data -> pasteboard), the empty/no-plain-text shapes answer OK with "", a read
// failure carries the native status, an over-cap text is dropped whole, and an incomplete
// table (a reduced image) answers UNAVAILABLE without calling anything.
#include <stdio.h>
#include <string.h>

#include "host_clipboard.h"

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

typedef struct {
    int pasteboardCreate;
    int pasteboardDestroy;
    int getData;
    int dataDestroy;
    int getPrimary;
    int plainCreate;
    int plainDestroy;
    int getContent;
} FakeCounters;

static FakeCounters g_fake;

// Fake configuration: NULL data + status models the pasteboard answer; content models the
// plain text (NULL with getPrimary == 0 models "plain text object with no content").
static void* s_fakeData;
static int s_fakeStatus;
static const char* s_fakeContent;
static int s_fakeGetPrimaryRc;
static int s_fakePlainCreateFails;
static int s_fakeCreateFails;

static void FakeReset(void) {
    memset(&g_fake, 0, sizeof(g_fake));
    s_fakeData = NULL;
    s_fakeStatus = 0;
    s_fakeContent = NULL;
    s_fakeGetPrimaryRc = 0;
    s_fakePlainCreateFails = 0;
    s_fakeCreateFails = 0;
}

static void* FakePasteboardCreate(void) {
    g_fake.pasteboardCreate++;
    return s_fakeCreateFails ? NULL : (void*)&g_fake;
}

static void FakePasteboardDestroy(void* pasteboard) {
    if (pasteboard == (void*)&g_fake) {
        g_fake.pasteboardDestroy++;
    }
}

static void* FakeGetData(void* pasteboard, int* status) {
    (void)pasteboard;
    g_fake.getData++;
    if (status != NULL) {
        *status = s_fakeStatus;
    }
    return s_fakeData;
}

static void FakeDataDestroy(void* data) {
    if (data == (void*)&g_fake) {
        g_fake.dataDestroy++;
    }
}

static int FakeGetPrimary(void* data, void* plain) {
    (void)data;
    (void)plain;
    g_fake.getPrimary++;
    return s_fakeGetPrimaryRc;
}

static void* FakePlainCreate(void) {
    g_fake.plainCreate++;
    return s_fakePlainCreateFails ? NULL : (void*)&g_fake;
}

static void FakePlainDestroy(void* plain) {
    if (plain == (void*)&g_fake) {
        g_fake.plainDestroy++;
    }
}

static const char* FakeGetContent(void* plain) {
    (void)plain;
    g_fake.getContent++;
    return s_fakeContent;
}

static ohos_host_pasteboard_api FakeApi(void) {
    ohos_host_pasteboard_api api;
    api.Pasteboard_Create = FakePasteboardCreate;
    api.Pasteboard_Destroy = FakePasteboardDestroy;
    api.Pasteboard_GetData = FakeGetData;
    api.UdmfData_Destroy = FakeDataDestroy;
    api.UdmfData_GetPrimaryPlainText = FakeGetPrimary;
    api.UdsPlainText_Create = FakePlainCreate;
    api.UdsPlainText_Destroy = FakePlainDestroy;
    api.UdsPlainText_GetContent = FakeGetContent;
    return api;
}

int main(void) {
    ohos_host_pasteboard_api api = FakeApi();
    char buffer[64];
    int status = -999;

    // --- happy path: text copied byte-exact, every object destroyed once -------------------
    FakeReset();
    s_fakeData = (void*)&g_fake;
    s_fakeContent = "PASTEBOARD-FIX";
    memset(buffer, 0x7f, sizeof(buffer));
    Check(ohos_host_clipboard_read_plain_text(&api, buffer, sizeof(buffer), &status) ==
              OHOS_HOST_CLIPBOARD_OK,
          "read: plain text answers OK");
    Check(strcmp(buffer, "PASTEBOARD-FIX") == 0, "read: the text is copied byte-exact");
    Check(status == 0, "read: the success status is 0");
    Check(g_fake.pasteboardCreate == 1 && g_fake.getData == 1 && g_fake.plainCreate == 1 &&
              g_fake.getPrimary == 1 && g_fake.getContent == 1,
          "read: each create/get call runs exactly once");
    Check(g_fake.plainDestroy == 1 && g_fake.dataDestroy == 1 && g_fake.pasteboardDestroy == 1,
          "read: plain -> data -> pasteboard are all destroyed");

    // --- empty pasteboard: NULL data with status 0 --------------------------------------
    FakeReset();
    buffer[0] = 'x';
    Check(ohos_host_clipboard_read_plain_text(&api, buffer, sizeof(buffer), &status) ==
              OHOS_HOST_CLIPBOARD_OK,
          "empty: a null answer with status 0 is OK");
    Check(buffer[0] == '\0', "empty: the buffer answers an empty string");
    Check(g_fake.dataDestroy == 0 && g_fake.plainCreate == 0, "empty: no UDMF objects created");
    Check(g_fake.pasteboardDestroy == 1, "empty: the pasteboard handle is destroyed");
    Check(g_fake.getData == 1 && g_fake.getPrimary == 0 && g_fake.getContent == 0,
          "empty: only the get-data call ran");

    // --- read failure: the native status travels out ------------------------------------
    FakeReset();
    s_fakeStatus = 201;  // missing permission class on this platform
    buffer[0] = 'x';
    Check(ohos_host_clipboard_read_plain_text(&api, buffer, sizeof(buffer), &status) ==
              OHOS_HOST_CLIPBOARD_FAILED,
          "failure: a non-zero status with null data is FAILED");
    Check(status == 201, "failure: *out_status carries the native code");
    Check(buffer[0] == '\0', "failure: the buffer stays empty (managed maps rc != 0 to null)");
    Check(g_fake.pasteboardDestroy == 1, "failure: the pasteboard handle is destroyed");
    Check(g_fake.plainCreate == 0 && g_fake.getPrimary == 0,
          "failure: no UDMF plain-text object is created");

    // --- no plain-text entry: answered as empty success (the old shell read shape) -------
    FakeReset();
    s_fakeData = (void*)&g_fake;
    s_fakeGetPrimaryRc = 1;
    buffer[0] = 'x';
    Check(ohos_host_clipboard_read_plain_text(&api, buffer, sizeof(buffer), &status) ==
              OHOS_HOST_CLIPBOARD_OK,
          "no-plain-text: a data record without plain text is OK");
    Check(buffer[0] == '\0', "no-plain-text: the buffer answers an empty string");
    Check(g_fake.plainDestroy == 1 && g_fake.dataDestroy == 1, "no-plain-text: objects destroyed");

    // --- plain text present but no content ----------------------------------------------
    FakeReset();
    s_fakeData = (void*)&g_fake;
    s_fakeContent = NULL;
    buffer[0] = 'x';
    Check(ohos_host_clipboard_read_plain_text(&api, buffer, sizeof(buffer), &status) ==
              OHOS_HOST_CLIPBOARD_OK &&
              buffer[0] == '\0',
          "no-content: a plain-text entry without content is an empty success");

    // --- empty string content ------------------------------------------------------------
    FakeReset();
    s_fakeData = (void*)&g_fake;
    s_fakeContent = "";
    buffer[0] = 'x';
    Check(ohos_host_clipboard_read_plain_text(&api, buffer, sizeof(buffer), &status) ==
              OHOS_HOST_CLIPBOARD_OK &&
              buffer[0] == '\0',
          "empty-content: an empty content string is OK");

    // --- cap boundary: exactly cap-1 copies, exactly cap drops whole ---------------------
    FakeReset();
    s_fakeData = (void*)&g_fake;
    {
        char exact[16];
        s_fakeContent = "0123456789abcde";  // 15 chars: fits exact[] (16 bytes)
        Check(ohos_host_clipboard_read_plain_text(&api, exact, sizeof(exact), &status) ==
                  OHOS_HOST_CLIPBOARD_OK &&
                  strcmp(exact, "0123456789abcde") == 0,
              "cap: a text of out_size-1 bytes copies");
        s_fakeContent = "0123456789abcdef";  // 16 chars: at the cap -> dropped whole
        exact[0] = 'x';
        Check(ohos_host_clipboard_read_plain_text(&api, exact, sizeof(exact), &status) ==
                  OHOS_HOST_CLIPBOARD_FAILED &&
                  exact[0] == '\0',
              "cap: a text at out_size is dropped whole (never truncated)");
    }

    // --- UTF-8 bytes survive the copy ----------------------------------------------------
    FakeReset();
    s_fakeData = (void*)&g_fake;
    s_fakeContent = "\xE5\x89\xAA\xE8\xB4\xB4\xE6\x9D\xBF";  // 剪贴板
    Check(ohos_host_clipboard_read_plain_text(&api, buffer, sizeof(buffer), &status) ==
              OHOS_HOST_CLIPBOARD_OK &&
              strcmp(buffer, "\xE5\x89\xAA\xE8\xB4\xB4\xE6\x9D\xBF") == 0,
          "utf8: multibyte content copies byte-exact");

    // --- sequential reads are independent (no cached state) ------------------------------
    FakeReset();
    s_fakeData = (void*)&g_fake;
    s_fakeContent = "first";
    int first = ohos_host_clipboard_read_plain_text(&api, buffer, sizeof(buffer), &status) ==
                    OHOS_HOST_CLIPBOARD_OK &&
                strcmp(buffer, "first") == 0;
    s_fakeContent = "second";
    int second = ohos_host_clipboard_read_plain_text(&api, buffer, sizeof(buffer), &status) ==
                     OHOS_HOST_CLIPBOARD_OK &&
                 strcmp(buffer, "second") == 0;
    Check(first && second, "read: a second read replaces the previous text");
    Check(g_fake.pasteboardCreate == 2 && g_fake.pasteboardDestroy == 2,
          "read: each read creates and destroys its own pasteboard handle");

    // --- create failures ----------------------------------------------------------------
    FakeReset();
    s_fakeCreateFails = 1;
    Check(ohos_host_clipboard_read_plain_text(&api, buffer, sizeof(buffer), &status) ==
              OHOS_HOST_CLIPBOARD_FAILED,
          "create: a failed pasteboard create is FAILED");
    Check(g_fake.pasteboardDestroy == 0, "create: nothing to destroy when create failed");
    FakeReset();
    s_fakeData = (void*)&g_fake;
    s_fakePlainCreateFails = 1;
    Check(ohos_host_clipboard_read_plain_text(&api, buffer, sizeof(buffer), &status) ==
              OHOS_HOST_CLIPBOARD_FAILED,
          "create: a failed plain-text create is FAILED");
    Check(g_fake.dataDestroy == 1 && g_fake.pasteboardDestroy == 1,
          "create: the already-created objects are still destroyed");

    // --- reduced image: an incomplete table answers UNAVAILABLE --------------------------
    FakeReset();
    {
        ohos_host_pasteboard_api partial = FakeApi();
        partial.Pasteboard_GetData = NULL;
        buffer[0] = 'x';
        Check(ohos_host_clipboard_read_plain_text(&partial, buffer, sizeof(buffer), &status) ==
                  OHOS_HOST_CLIPBOARD_UNAVAILABLE,
              "unavailable: a table with a missing entry is UNAVAILABLE");
        Check(buffer[0] == 'x', "unavailable: the buffer is untouched");
        Check(status == 0, "unavailable: *out_status is 0");
    }
    FakeReset();
    Check(ohos_host_clipboard_read_plain_text(NULL, buffer, sizeof(buffer), &status) ==
              OHOS_HOST_CLIPBOARD_UNAVAILABLE,
          "unavailable: a NULL table is UNAVAILABLE");
    Check(ohos_host_clipboard_read_plain_text(&api, NULL, sizeof(buffer), &status) ==
              OHOS_HOST_CLIPBOARD_UNAVAILABLE &&
              ohos_host_clipboard_read_plain_text(&api, buffer, 0, &status) ==
                  OHOS_HOST_CLIPBOARD_UNAVAILABLE,
          "unavailable: NULL out / zero size are refused without touching memory");
    Check(g_fake.pasteboardCreate == 0, "unavailable: no NDK call runs");

    printf("host-clipboard: %d checks, %d failure(s)\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
