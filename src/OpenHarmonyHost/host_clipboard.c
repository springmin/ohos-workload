// Clipboard NDK read wrapper (see host_clipboard.h for the contract and the failure
// semantics). Pure C: no NAPI, no OpenHarmony headers; the NDK calls arrive through the
// injected table, so this file compiles and runs on the development host.
#include "host_clipboard.h"

#include <string.h>

static int PasteboardApiReady(const ohos_host_pasteboard_api *api) {
    return api != NULL && api->Pasteboard_Create != NULL && api->Pasteboard_Destroy != NULL &&
           api->Pasteboard_GetData != NULL && api->UdmfData_Destroy != NULL &&
           api->UdmfData_GetPrimaryPlainText != NULL && api->UdsPlainText_Create != NULL &&
           api->UdsPlainText_Destroy != NULL && api->UdsPlainText_GetContent != NULL;
}

int ohos_host_clipboard_read_plain_text(const ohos_host_pasteboard_api *api, char *out,
                                        size_t out_size, int *out_status) {
    if (out == NULL || out_size == 0 || !PasteboardApiReady(api)) {
        if (out_status != NULL) {
            *out_status = 0;
        }
        return OHOS_HOST_CLIPBOARD_UNAVAILABLE;
    }
    out[0] = '\0';
    if (out_status != NULL) {
        *out_status = 0;
    }

    void *pasteboard = api->Pasteboard_Create();
    if (pasteboard == NULL) {
        return OHOS_HOST_CLIPBOARD_FAILED;
    }

    int result = OHOS_HOST_CLIPBOARD_OK;
    int status = 0;
    void *data = api->Pasteboard_GetData(pasteboard, &status);
    if (out_status != NULL) {
        *out_status = status;
    }
    if (data == NULL) {
        // A null pointer with status 0 is an empty pasteboard; any other status is a read
        // failure (the caller keeps the managed null/empty semantics either way).
        if (status != 0) {
            result = OHOS_HOST_CLIPBOARD_FAILED;
        }
    } else {
        void *plain = api->UdsPlainText_Create();
        if (plain == NULL) {
            result = OHOS_HOST_CLIPBOARD_FAILED;
        } else {
            // A non-zero code means the data carries no plain-text entry; the old shell read
            // answered that (like a non-text MIME) as an empty string with success. Only the
            // present-but-unusable shape is an error here.
            const char *content =
                api->UdmfData_GetPrimaryPlainText(data, plain) == 0
                    ? api->UdsPlainText_GetContent(plain)
                    : NULL;
            if (content != NULL) {
                size_t length = strlen(content);
                if (length >= out_size) {
                    result = OHOS_HOST_CLIPBOARD_FAILED;  // over the cap: drop whole
                } else {
                    memcpy(out, content, length + 1);
                }
            }
            api->UdsPlainText_Destroy(plain);
        }
        api->UdmfData_Destroy(data);
    }
    api->Pasteboard_Destroy(pasteboard);
    return result;
}
