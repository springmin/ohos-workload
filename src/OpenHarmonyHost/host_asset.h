// Asset Store NDK wrapper (SECURE-STORAGE-ASSET): the credential backend behind the managed
// SecureStorage bridge.
//
// OH_Asset_* (asset/asset_api.h) stores short secrets in the platform Asset Store: encrypted
// with a device-bound key, looked up by an app-scoped alias, and never written to the app's
// own files, the logs or a plain SQLite row. The managed store prefers it over the HUKS
// keystore path (libasset_ndk.z.so is resolved at runtime by host_optional.c; a reduced image
// without it answers UNAVAILABLE, and the managed layer then refuses the weak fallback unless
// the app explicitly opted out).
//
// The NDK entry points arrive as an injected function table: host_optional.c resolves the real
// ones with dlopen/dlsym, the off-device unit test (host_asset_test.c) fakes them. That keeps
// this file pure C - no NAPI and no OpenHarmony headers - and the failure semantics
// unit-testable. The struct layouts mirror asset_type.h (Asset_Attr / Asset_ResultSet) ABI
// one-to-one, so the pointers host_optional.c resolves can be cast to these types.
//
// Access policy per asset (the mail M4 reference, DEVICE_FIRST_UNLOCKED semantics):
//   ALIAS            the unique per-store per-key name the managed side builds
//   SECRET           the value, 1-1024 bytes (a longer value is rejected and the managed
//                    layer decides between its other strong backends and the refusal)
//   ACCESSIBILITY    DEVICE_FIRST_UNLOCKED (readable after the first unlock, never before)
//   AUTH_TYPE        NONE (no user-authentication prompt)
//   SYNC_TYPE        NEVER (no cloud/device sync)
//   CONFLICT         OVERWRITE (a Set replaces an existing value in one call)
// No ASSET_TAG_IS_PERSISTENT: the value does not survive app uninstall, so no per-app
// STORE_PERSISTENT_DATA permission is involved.

#ifndef OHOS_HOST_ASSET_H
#define OHOS_HOST_ASSET_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ABI mirrors of asset_type.h. Kept hand-written so this header stays free of the OpenHarmony
// sysroot includes and the wrapper compiles (and its unit test runs) on the development host;
// the field order/sizes match Asset_Blob / Asset_Value / Asset_Attr / Asset_Result /
// Asset_ResultSet exactly.
typedef struct {
    uint32_t size;
    uint8_t *data;
} ohos_host_asset_blob;

typedef union {
    bool boolean;
    uint32_t u32;
    ohos_host_asset_blob blob;
} ohos_host_asset_value;

typedef struct {
    uint32_t tag;
    ohos_host_asset_value value;
} ohos_host_asset_attr;

typedef struct {
    uint32_t count;
    ohos_host_asset_attr *attrs;
} ohos_host_asset_result;

typedef struct {
    uint32_t count;
    ohos_host_asset_result *results;
} ohos_host_asset_result_set;

// The six OH_Asset_* entry points the put/get/remove path uses. Every one must be non-NULL for
// the wrapper to run; a reduced image without libasset_ndk.z.so leaves them NULL and the
// wrapper answers OHOS_HOST_ASSET_UNAVAILABLE.
typedef struct ohos_host_asset_api {
    int32_t (*Add)(const ohos_host_asset_attr *attributes, uint32_t attrCnt);
    int32_t (*Remove)(const ohos_host_asset_attr *query, uint32_t queryCnt);
    int32_t (*Query)(const ohos_host_asset_attr *query, uint32_t queryCnt,
                     ohos_host_asset_result_set *resultSet);
    // OH_Asset_ParseAttr: returns a pointer into the result; the attribute (and its blob) must
    // NOT be released separately - OH_Asset_FreeResultSet releases the whole result.
    ohos_host_asset_attr *(*ParseAttr)(const ohos_host_asset_result *result, uint32_t tag);
    void (*FreeResultSet)(ohos_host_asset_result_set *resultSet);
} ohos_host_asset_api;

enum {
    OHOS_HOST_ASSET_OK = 0,
    // Query/remove: no asset matches the alias (ASSET_NOT_FOUND 24000002).
    OHOS_HOST_ASSET_NOT_FOUND = 1,
    // The API table is NULL/incomplete: libasset_ndk.z.so (or an entry point) is missing.
    OHOS_HOST_ASSET_UNAVAILABLE = -2,
    // The op ran and failed; *out_status carries the OH_Asset_* result code.
    OHOS_HOST_ASSET_FAILED = -1,
};

// Limits from the Asset Store service (security_asset argument_check.rs): a violation is
// rejected before the NDK call so the outcome does not depend on service-side validation.
#define OHOS_HOST_ASSET_ALIAS_MAX_BYTES 256u
#define OHOS_HOST_ASSET_SECRET_MAX_BYTES 1024u

// The service's ASSET_NOT_FOUND result code (asset_type.h).
#define OHOS_HOST_ASSET_RESULT_NOT_FOUND 24000002

// True when every entry point of the table resolved.
int ohos_host_asset_ready(const ohos_host_asset_api *api);

// Stores (or overwrites) `secret` under `alias` with the DEVICE_FIRST_UNLOCKED policy.
// Returns OHOS_HOST_ASSET_OK / OHOS_HOST_ASSET_FAILED; *out_status (optional) carries the
// service result code (401 when the local bounds check rejected the call).
int ohos_host_asset_put(const ohos_host_asset_api *api, const char *alias, const uint8_t *secret,
                        size_t secret_length, int32_t *out_status);

// Reads the secret stored under `alias` into `out` (capacity `out_capacity`). The secret is
// copied whole: a value larger than the capacity answers FAILED and `out` stays untouched.
// Returns OK (with *out_length set) / NOT_FOUND / FAILED / UNAVAILABLE.
int ohos_host_asset_get(const ohos_host_asset_api *api, const char *alias, uint8_t *out,
                        size_t out_capacity, size_t *out_length, int32_t *out_status);

// Removes the asset stored under `alias`. Returns OK / NOT_FOUND / FAILED / UNAVAILABLE.
int ohos_host_asset_remove(const ohos_host_asset_api *api, const char *alias, int32_t *out_status);

// The base64 bridge protocol behind ohos_host_asset_request (same shape as the keystore ops):
//   op "put"    data_base64 = base64(value)      -> success carries no data
//   op "get"    -> success sets *out_data_base64 to base64(secret); the caller frees it
//   op "remove"                                  -> success carries no data
// Returns 0 (success), 1 (not found) or -1 (unavailable/failed/unknown op/bad base64); every
// failure leaves *out_data_base64 untouched. *out_status (optional) carries the OH_Asset_*
// result code for the diagnostic log. Unavailable never throws across the boundary.
int ohos_host_asset_execute(const ohos_host_asset_api *api, const char *op, const char *alias,
                            const char *data_base64, char **out_data_base64,
                            int32_t *out_status);

#ifdef __cplusplus
}
#endif

#endif  // OHOS_HOST_ASSET_H
