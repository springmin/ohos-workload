// Clipboard NDK read wrapper (PASTEBOARD-FIX).
//
// The pasteboard read used to run in the ArkTS shell (@ohos.pasteboard getDataSync), whose
// read path needs the ACL-level ohos.permission.READ_PASTEBOARD: declaring that permission
// makes the installer reject the bundle ("grant request permissions failed") and without it
// the ArkTS read is refused (always null). The pasteboard NDK (OH_Pasteboard + UDMF plain
// text) reads without the permission on the observed images (the mail reference port's
// device evidence), so the host answers the read ops itself. The shell keeps only the write
// op (setDataSync needs no permission) and the pasteboard 'update' observer.
//
// The NDK entry points arrive as an injected function table: host_optional.c resolves the
// real ones with dlopen/dlsym (libpasteboard.so + libudmf.so are not part of the guaranteed
// image set), the off-device unit test (host_clipboard_test.c) fakes them. That keeps this
// file pure C - no NAPI and no OpenHarmony headers - and the failure semantics unit-testable.
//
// Failure semantics (the managed bridge maps rc != 0 to the clipboard's null/empty shape:
// GetTextAsync -> null, HasText -> false):
//   OK           the primary plain text was copied out; it may be empty (no data/no plain
//                text/non-text MIME all answer the same, matching the shell's old read);
//   UNAVAILABLE  the API table is NULL or incomplete (reduced image without the libraries);
//   FAILED       the pasteboard read failed (the native status lands in *out_status) or the
//                text is over the cap (dropped whole, never truncated - the host's cap rule).
#ifndef OHOS_HOST_CLIPBOARD_H
#define OHOS_HOST_CLIPBOARD_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// The pasteboard + UDMF entry points the read path uses. Exactly the seven calls the read
// needs; every one must be non-NULL for the read to run.
typedef struct ohos_host_pasteboard_api {
    void *(*Pasteboard_Create)(void);
    void (*Pasteboard_Destroy)(void *pasteboard);
    void *(*Pasteboard_GetData)(void *pasteboard, int *status);
    void (*UdmfData_Destroy)(void *data);
    int (*UdmfData_GetPrimaryPlainText)(void *data, void *plain_text);
    void *(*UdsPlainText_Create)(void);
    void (*UdsPlainText_Destroy)(void *plain_text);
    const char *(*UdsPlainText_GetContent)(void *plain_text);
} ohos_host_pasteboard_api;

enum {
    OHOS_HOST_CLIPBOARD_OK = 0,
    OHOS_HOST_CLIPBOARD_UNAVAILABLE = -1,
    OHOS_HOST_CLIPBOARD_FAILED = -2,
};

// Cap of the copied text. A longer plain text is dropped whole (FAILED), mirroring the host's
// control-string rule; the bridge never sees a silently truncated paste.
#define OHOS_HOST_CLIPBOARD_MAX_TEXT_BYTES (1024u * 1024u)

// Reads the pasteboard's primary plain text into out (NUL-terminated; "" when the pasteboard
// has no data, no plain text or a non-text MIME). *out_status receives the native pasteboard
// status code (0 when the table was unavailable). out/out_size must be valid; a NULL out or
// zero size answers UNAVAILABLE without touching memory.
int ohos_host_clipboard_read_plain_text(const ohos_host_pasteboard_api *api,
                                        char *out, size_t out_size, int *out_status);

#ifdef __cplusplus
}
#endif

#endif  // OHOS_HOST_CLIPBOARD_H
