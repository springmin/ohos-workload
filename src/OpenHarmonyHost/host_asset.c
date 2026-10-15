// Asset Store NDK wrapper (see host_asset.h for the contract and the access policy). Pure C:
// no NAPI, no OpenHarmony headers; the NDK calls arrive through the injected table, so this
// file compiles and runs on the development host.
#include "host_asset.h"

#include <stdlib.h>
#include <string.h>

// Attribute tags from asset_type.h: ASSET_TYPE_BYTES = 0x3 << 28, ASSET_TYPE_NUMBER = 0x2 << 28.
#define OHOS_HOST_ASSET_TAG_SECRET (0x3u << 28 | 0x01u)
#define OHOS_HOST_ASSET_TAG_ALIAS (0x3u << 28 | 0x02u)
#define OHOS_HOST_ASSET_TAG_ACCESSIBILITY (0x2u << 28 | 0x03u)
#define OHOS_HOST_ASSET_TAG_AUTH_TYPE (0x2u << 28 | 0x05u)
#define OHOS_HOST_ASSET_TAG_SYNC_TYPE (0x2u << 28 | 0x10u)
#define OHOS_HOST_ASSET_TAG_RETURN_TYPE (0x2u << 28 | 0x40u)
#define OHOS_HOST_ASSET_TAG_CONFLICT_RESOLUTION (0x2u << 28 | 0x44u)

// Asset_Accessibility / Asset_AuthType / Asset_SyncType / Asset_ConflictResolution values.
#define OHOS_HOST_ASSET_ACCESSIBILITY_DEVICE_FIRST_UNLOCKED 1u
#define OHOS_HOST_ASSET_AUTH_TYPE_NONE 0u
#define OHOS_HOST_ASSET_SYNC_TYPE_NEVER 0u
#define OHOS_HOST_ASSET_RETURN_ALL 0u
#define OHOS_HOST_ASSET_CONFLICT_OVERWRITE 0u

// ASSET_INVALID_ARGUMENT: reported when the local bounds check rejects a call before the NDK.
#define OHOS_HOST_ASSET_RESULT_INVALID_ARGUMENT 401

int ohos_host_asset_ready(const ohos_host_asset_api *api) {
    return api != NULL && api->Add != NULL && api->Remove != NULL && api->Query != NULL &&
           api->ParseAttr != NULL && api->FreeResultSet != NULL;
}

static ohos_host_asset_attr OhosHostAssetBlobAttr(uint32_t tag, const void *data, size_t size) {
    ohos_host_asset_attr attr;
    attr.tag = tag;
    attr.value.blob.size = (uint32_t)size;
    attr.value.blob.data = (uint8_t *)(uintptr_t)data;
    return attr;
}

static ohos_host_asset_attr OhosHostAssetNumberAttr(uint32_t tag, uint32_t value) {
    ohos_host_asset_attr attr;
    attr.tag = tag;
    attr.value.u32 = value;
    return attr;
}

int ohos_host_asset_put(const ohos_host_asset_api *api, const char *alias, const uint8_t *secret,
                        size_t secret_length, int32_t *out_status) {
    if (out_status != NULL) {
        *out_status = 0;
    }
    if (!ohos_host_asset_ready(api)) {
        return OHOS_HOST_ASSET_UNAVAILABLE;
    }
    // The service limits (alias 1-256, secret 1-1024 bytes): reject locally so a bad call
    // cannot reach the service and the outcome is identical on every image.
    if (alias == NULL || alias[0] == '\0' || strlen(alias) > OHOS_HOST_ASSET_ALIAS_MAX_BYTES ||
        secret == NULL || secret_length == 0 ||
        secret_length > OHOS_HOST_ASSET_SECRET_MAX_BYTES) {
        if (out_status != NULL) {
            *out_status = OHOS_HOST_ASSET_RESULT_INVALID_ARGUMENT;
        }
        return OHOS_HOST_ASSET_FAILED;
    }
    ohos_host_asset_attr attributes[] = {
        OhosHostAssetBlobAttr(OHOS_HOST_ASSET_TAG_ALIAS, alias, strlen(alias)),
        OhosHostAssetBlobAttr(OHOS_HOST_ASSET_TAG_SECRET, secret, secret_length),
        OhosHostAssetNumberAttr(OHOS_HOST_ASSET_TAG_ACCESSIBILITY,
                                OHOS_HOST_ASSET_ACCESSIBILITY_DEVICE_FIRST_UNLOCKED),
        OhosHostAssetNumberAttr(OHOS_HOST_ASSET_TAG_AUTH_TYPE, OHOS_HOST_ASSET_AUTH_TYPE_NONE),
        OhosHostAssetNumberAttr(OHOS_HOST_ASSET_TAG_SYNC_TYPE, OHOS_HOST_ASSET_SYNC_TYPE_NEVER),
        OhosHostAssetNumberAttr(OHOS_HOST_ASSET_TAG_CONFLICT_RESOLUTION,
                                OHOS_HOST_ASSET_CONFLICT_OVERWRITE),
    };
    int32_t rc = api->Add(attributes, (uint32_t)(sizeof(attributes) / sizeof(attributes[0])));
    if (out_status != NULL) {
        *out_status = rc;
    }
    return rc == 0 ? OHOS_HOST_ASSET_OK : OHOS_HOST_ASSET_FAILED;
}

int ohos_host_asset_get(const ohos_host_asset_api *api, const char *alias, uint8_t *out,
                        size_t out_capacity, size_t *out_length, int32_t *out_status) {
    if (out_status != NULL) {
        *out_status = 0;
    }
    if (out_length != NULL) {
        *out_length = 0;
    }
    if (!ohos_host_asset_ready(api)) {
        return OHOS_HOST_ASSET_UNAVAILABLE;
    }
    if (alias == NULL || alias[0] == '\0' || strlen(alias) > OHOS_HOST_ASSET_ALIAS_MAX_BYTES ||
        out == NULL || out_capacity == 0) {
        if (out_status != NULL) {
            *out_status = OHOS_HOST_ASSET_RESULT_INVALID_ARGUMENT;
        }
        return OHOS_HOST_ASSET_FAILED;
    }
    ohos_host_asset_attr query[] = {
        OhosHostAssetBlobAttr(OHOS_HOST_ASSET_TAG_ALIAS, alias, strlen(alias)),
        OhosHostAssetNumberAttr(OHOS_HOST_ASSET_TAG_RETURN_TYPE, OHOS_HOST_ASSET_RETURN_ALL),
    };
    ohos_host_asset_result_set result_set;
    result_set.count = 0;
    result_set.results = NULL;
    int32_t rc = api->Query(query, (uint32_t)(sizeof(query) / sizeof(query[0])), &result_set);
    if (out_status != NULL) {
        *out_status = rc;
    }
    if (rc == OHOS_HOST_ASSET_RESULT_NOT_FOUND) {
        return OHOS_HOST_ASSET_NOT_FOUND;
    }
    if (rc != 0) {
        return OHOS_HOST_ASSET_FAILED;
    }
    if (result_set.count == 0 || result_set.results == NULL) {
        // A successful query with nothing in it: the same "absent" answer.
        api->FreeResultSet(&result_set);
        return OHOS_HOST_ASSET_NOT_FOUND;
    }
    int result = OHOS_HOST_ASSET_OK;
    // OH_Asset_ParseAttr's answer is a view into the result set: copy it out before the free,
    // and never release the attribute itself (the docs: FreeResultSet releases the whole
    // result).
    ohos_host_asset_attr *secret = api->ParseAttr(result_set.results, OHOS_HOST_ASSET_TAG_SECRET);
    if (secret == NULL || secret->value.blob.data == NULL || secret->value.blob.size == 0) {
        // A result without a secret is a corrupted read, not an empty value: a Set never
        // stores an empty secret (see the bounds check above).
        result = OHOS_HOST_ASSET_FAILED;
    } else if (secret->value.blob.size > out_capacity) {
        // Copy whole or not at all: a truncated credential would read as a wrong one.
        result = OHOS_HOST_ASSET_FAILED;
    } else {
        memcpy(out, secret->value.blob.data, secret->value.blob.size);
        if (out_length != NULL) {
            *out_length = secret->value.blob.size;
        }
    }
    api->FreeResultSet(&result_set);
    return result;
}

int ohos_host_asset_remove(const ohos_host_asset_api *api, const char *alias,
                           int32_t *out_status) {
    if (out_status != NULL) {
        *out_status = 0;
    }
    if (!ohos_host_asset_ready(api)) {
        return OHOS_HOST_ASSET_UNAVAILABLE;
    }
    if (alias == NULL || alias[0] == '\0' || strlen(alias) > OHOS_HOST_ASSET_ALIAS_MAX_BYTES) {
        if (out_status != NULL) {
            *out_status = OHOS_HOST_ASSET_RESULT_INVALID_ARGUMENT;
        }
        return OHOS_HOST_ASSET_FAILED;
    }
    // The alias alone is the exact match: the stored access-control attributes must not be
    // repeated here, or a mismatch (e.g. after a policy change) would make the entry
    // unremovable.
    ohos_host_asset_attr query[] = {
        OhosHostAssetBlobAttr(OHOS_HOST_ASSET_TAG_ALIAS, alias, strlen(alias)),
    };
    int32_t rc = api->Remove(query, 1);
    if (out_status != NULL) {
        *out_status = rc;
    }
    if (rc == 0) {
        return OHOS_HOST_ASSET_OK;
    }
    if (rc == OHOS_HOST_ASSET_RESULT_NOT_FOUND) {
        return OHOS_HOST_ASSET_NOT_FOUND;
    }
    return OHOS_HOST_ASSET_FAILED;
}

// ---------------------------------------------------------------------------
// base64 (the managed protocol serializes every payload as standard padded base64). The codec
// is self-contained so this module unit-tests off-device without the keystore translation unit.
// ---------------------------------------------------------------------------

static const char kAssetBase64Alphabet[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static char *OhosHostAssetBase64Encode(const uint8_t *data, size_t length) {
    size_t text_length = ((length + 2) / 3) * 4;
    char *text = (char *)malloc(text_length + 1);
    if (text == NULL) {
        return NULL;
    }
    size_t at = 0;
    for (size_t i = 0; i < length; i += 3) {
        uint32_t chunk = (uint32_t)data[i] << 16;
        if (i + 1 < length) {
            chunk |= (uint32_t)data[i + 1] << 8;
        }
        if (i + 2 < length) {
            chunk |= (uint32_t)data[i + 2];
        }
        text[at++] = kAssetBase64Alphabet[(chunk >> 18) & 0x3F];
        text[at++] = kAssetBase64Alphabet[(chunk >> 12) & 0x3F];
        text[at++] = i + 1 < length ? kAssetBase64Alphabet[(chunk >> 6) & 0x3F] : '=';
        text[at++] = i + 2 < length ? kAssetBase64Alphabet[chunk & 0x3F] : '=';
    }
    text[at] = '\0';
    return text;
}

static int OhosHostAssetBase64Value(char c) {
    if (c >= 'A' && c <= 'Z') {
        return c - 'A';
    }
    if (c >= 'a' && c <= 'z') {
        return c - 'a' + 26;
    }
    if (c >= '0' && c <= '9') {
        return c - '0' + 52;
    }
    if (c == '+') {
        return 62;
    }
    if (c == '/') {
        return 63;
    }
    return -1;
}

static bool OhosHostAssetBase64Decode(const char *text, uint8_t **out, size_t *out_length) {
    size_t text_length = strlen(text);
    if (text_length % 4 != 0) {
        return false;
    }
    uint8_t *data = (uint8_t *)malloc(text_length == 0 ? 1 : (text_length / 4) * 3);
    if (data == NULL) {
        return false;
    }
    size_t at = 0;
    for (size_t i = 0; i < text_length; i += 4) {
        int a = OhosHostAssetBase64Value(text[i]);
        int b = OhosHostAssetBase64Value(text[i + 1]);
        int c = text[i + 2] == '=' ? -2 : OhosHostAssetBase64Value(text[i + 2]);
        int d = text[i + 3] == '=' ? -2 : OhosHostAssetBase64Value(text[i + 3]);
        // Padding is only legal at the tail (one or two '=' as the final characters).
        if (a < 0 || b < 0 || c == -1 || d == -1 || (c == -2 && d != -2)) {
            free(data);
            return false;
        }
        uint32_t chunk = ((uint32_t)a << 18) | ((uint32_t)b << 12);
        data[at++] = (uint8_t)(chunk >> 16);
        if (c >= 0) {
            chunk |= (uint32_t)c << 6;
            data[at++] = (uint8_t)((chunk >> 8) & 0xFF);
        }
        if (d >= 0) {
            chunk |= (uint32_t)d;
            data[at++] = (uint8_t)(chunk & 0xFF);
        }
    }
    *out = data;
    *out_length = at;
    return true;
}

int ohos_host_asset_execute(const ohos_host_asset_api *api, const char *op, const char *alias,
                            const char *data_base64, char **out_data_base64,
                            int32_t *out_status) {
    if (out_status != NULL) {
        *out_status = 0;
    }
    if (op == NULL || alias == NULL || out_data_base64 == NULL) {
        return -1;
    }
    if (!ohos_host_asset_ready(api)) {
        return -1;
    }
    if (strcmp(op, "remove") == 0) {
        int result = ohos_host_asset_remove(api, alias, out_status);
        if (result == OHOS_HOST_ASSET_OK) {
            return 0;
        }
        if (result == OHOS_HOST_ASSET_NOT_FOUND) {
            return 1;
        }
        return -1;
    }
    if (strcmp(op, "put") == 0) {
        uint8_t *secret = NULL;
        size_t secret_length = 0;
        if (data_base64 == NULL ||
            !OhosHostAssetBase64Decode(data_base64, &secret, &secret_length)) {
            return -1;
        }
        int result = ohos_host_asset_put(api, alias, secret, secret_length, out_status);
        if (secret_length > 0) {
            memset(secret, 0, secret_length);
        }
        free(secret);
        return result == OHOS_HOST_ASSET_OK ? 0 : -1;
    }
    if (strcmp(op, "get") == 0) {
        uint8_t secret[OHOS_HOST_ASSET_SECRET_MAX_BYTES];
        size_t secret_length = 0;
        int result = ohos_host_asset_get(api, alias, secret, sizeof(secret), &secret_length,
                                         out_status);
        if (result == OHOS_HOST_ASSET_NOT_FOUND) {
            return 1;
        }
        if (result != OHOS_HOST_ASSET_OK) {
            return -1;
        }
        char *text = OhosHostAssetBase64Encode(secret, secret_length);
        memset(secret, 0, sizeof(secret));
        if (text == NULL) {
            return -1;
        }
        *out_data_base64 = text;
        return 0;
    }
    return -1;
}
