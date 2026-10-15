// Off-device unit tests for the Asset Store NDK wrapper (SECURE-STORAGE-ASSET).
// Pure C: compiles and runs on the development host, no device, no NAPI, no OpenHarmony SDK.
// Run through scripts/selftest-host-asset.sh (it also checks the shipped sources are wired into
// CMakeLists.txt/build-host.sh and drives the mutation red control).
//
// The fake asset API records every call and serves one in-memory entry, so the cases pin the
// contract: put sends exactly the six access-policy attributes and copies the alias/secret
// bytes it was given, the service's rejection codes propagate as FAILED with the raw status,
// the local bounds check (alias 1-256, secret 1-1024) rejects before any NDK call, get copies
// whole-or-not-at-all and frees the result set exactly once, NOT_FOUND/absent are NOT_FOUND
// without a free, and an incomplete table (a reduced image) answers UNAVAILABLE without
// calling anything. The base64 bridge (execute) round-trips put/get/remove and maps every
// failure to -1 without touching the out pointer.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "host_asset.h"

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
    int add;
    int remove;
    int query;
    int parse;
    int freeSet;
} FakeCounters;

static FakeCounters g_fake;

// Configuration knobs (see FakeReset) and the captured Add/Remove query.
static int32_t s_addRc;
static int32_t s_removeRc;
static int32_t s_queryRc;
static int s_hasSecretAttr;
static uint32_t s_addAttrCount;
static ohos_host_asset_attr s_addAttrs[8];
static uint32_t s_removeAttrCount;
static ohos_host_asset_attr s_removeAttrs[2];
// The fake store's single entry.
static uint8_t s_storeSecret[OHOS_HOST_ASSET_SECRET_MAX_BYTES];
static size_t s_storeSecretLength;
static int s_storeExists;

// The result set the fake Query hands out: one result whose attrs serve SECRET (and never
// ALIAS), so ParseAttr must be asked for the right tag.
static ohos_host_asset_attr s_queryAttrs[2];
static ohos_host_asset_result s_queryResult;
static ohos_host_asset_attr s_queryResultSetStorage;

static void FakeReset(void) {
    memset(&g_fake, 0, sizeof(g_fake));
    s_addRc = 0;
    s_removeRc = 0;
    s_queryRc = 0;
    s_hasSecretAttr = 1;
    s_addAttrCount = 0;
    s_removeAttrCount = 0;
    s_storeSecretLength = 0;
    s_storeExists = 0;
}

static int NowHasSecretBlob(ohos_host_asset_attr* attr) {
    return attr->tag == (0x3u << 28 | 0x01u);
}

static int32_t FakeAdd(const ohos_host_asset_attr* attributes, uint32_t attrCnt) {
    g_fake.add++;
    s_addAttrCount = attrCnt < 8 ? attrCnt : 8;
    for (uint32_t i = 0; i < s_addAttrCount; i++) {
        s_addAttrs[i] = attributes[i];
    }
    if (s_addRc == 0) {
        // The service copies the secret synchronously (the caller's buffers may go away).
        for (uint32_t i = 0; i < attrCnt; i++) {
            if (NowHasSecretBlob((ohos_host_asset_attr*)&attributes[i])) {
                s_storeSecretLength = attributes[i].value.blob.size;
                memset(s_storeSecret, 0, sizeof(s_storeSecret));
                memcpy(s_storeSecret, attributes[i].value.blob.data, s_storeSecretLength);
                s_storeExists = 1;
            }
        }
    }
    return s_addRc;
}

static int32_t FakeRemove(const ohos_host_asset_attr* query, uint32_t queryCnt) {
    g_fake.remove++;
    s_removeAttrCount = queryCnt < 2 ? queryCnt : 2;
    for (uint32_t i = 0; i < s_removeAttrCount; i++) {
        s_removeAttrs[i] = query[i];
    }
    if (s_removeRc != 0) {
        return s_removeRc;
    }
    if (!s_storeExists) {
        return OHOS_HOST_ASSET_RESULT_NOT_FOUND;
    }
    s_storeExists = 0;
    s_storeSecretLength = 0;
    return 0;
}

static int32_t FakeQuery(const ohos_host_asset_attr* query, uint32_t queryCnt,
                         ohos_host_asset_result_set* resultSet) {
    g_fake.query++;
    (void)query;
    (void)queryCnt;
    if (s_queryRc != 0) {
        return s_queryRc;
    }
    if (!s_storeExists) {
        return OHOS_HOST_ASSET_RESULT_NOT_FOUND;
    }
    uint32_t count = 0;
    if (s_hasSecretAttr) {
        s_queryAttrs[count].tag = 0x3u << 28 | 0x01u;  // SECRET
        s_queryAttrs[count].value.blob.size = (uint32_t)s_storeSecretLength;
        s_queryAttrs[count].value.blob.data = s_storeSecret;
        count++;
    }
    s_queryResultSetStorage.tag = 0;
    s_queryResult.count = count;
    s_queryResult.attrs = s_queryAttrs;
    resultSet->count = 1;
    resultSet->results = &s_queryResult;
    return 0;
}

static ohos_host_asset_attr* FakeParseAttr(const ohos_host_asset_result* result, uint32_t tag) {
    g_fake.parse++;
    if (result == NULL || result->count == 0 || result->attrs == NULL) {
        return NULL;
    }
    for (uint32_t i = 0; i < result->count; i++) {
        if (result->attrs[i].tag == tag) {
            return &result->attrs[i];
        }
    }
    return NULL;
}

static void FakeFreeResultSet(ohos_host_asset_result_set* resultSet) {
    g_fake.freeSet++;
    resultSet->count = 0;
    resultSet->results = NULL;
}

static ohos_host_asset_api FakeApi(void) {
    ohos_host_asset_api api;
    api.Add = FakeAdd;
    api.Remove = FakeRemove;
    api.Query = FakeQuery;
    api.ParseAttr = FakeParseAttr;
    api.FreeResultSet = FakeFreeResultSet;
    return api;
}

static int BytesEqual(const uint8_t* a, const uint8_t* b, size_t length) {
    return memcmp(a, b, length) == 0;
}

int main(void) {
    FakeReset();
    ohos_host_asset_api api = FakeApi();

    // ---- readiness -----------------------------------------------------------------------
    Check(!ohos_host_asset_ready(NULL), "ready: NULL table answers not-ready");
    ohos_host_asset_api empty;
    memset(&empty, 0, sizeof(empty));
    Check(!ohos_host_asset_ready(&empty), "ready: empty table answers not-ready");
    ohos_host_asset_api onlyAdd;
    memset(&onlyAdd, 0, sizeof(onlyAdd));
    onlyAdd.Add = FakeAdd;
    Check(!ohos_host_asset_ready(&onlyAdd), "ready: an Add-only table is not ready");
    ohos_host_asset_api partial = FakeApi();
    partial.Query = NULL;
    Check(!ohos_host_asset_ready(&partial), "ready: a missing Query makes the table unusable");
    partial = FakeApi();
    partial.ParseAttr = NULL;
    Check(!ohos_host_asset_ready(&partial), "ready: a missing ParseAttr makes the table unusable");
    partial = FakeApi();
    partial.FreeResultSet = NULL;
    Check(!ohos_host_asset_ready(&partial),
          "ready: a missing FreeResultSet makes the table unusable");
    Check(ohos_host_asset_ready(&api), "ready: the complete table is ready");

    // ---- put: the six access-policy attributes -------------------------------------------
    FakeReset();
    const char* alias = "maui.ohos.securestorage.asset.v1.abc.def";
    const uint8_t secret[] = "s3cret-token";
    int32_t status = -1;
    int put = ohos_host_asset_put(&api, alias, secret, sizeof(secret) - 1, &status);
    Check(put == OHOS_HOST_ASSET_OK && status == 0, "put: success answers OK with status 0");
    Check(g_fake.add == 1 && s_addAttrCount == 6, "put: one Add call with six attributes");
    Check(s_addAttrs[0].tag == (0x3u << 28 | 0x02u) &&
              s_addAttrs[0].value.blob.size == strlen(alias) &&
              BytesEqual(s_addAttrs[0].value.blob.data, (const uint8_t*)alias, strlen(alias)),
          "put: attribute 0 is the alias blob (exact bytes)");
    Check(s_addAttrs[1].tag == (0x3u << 28 | 0x01u) &&
              s_addAttrs[1].value.blob.size == sizeof(secret) - 1 &&
              BytesEqual(s_addAttrs[1].value.blob.data, secret, sizeof(secret) - 1),
          "put: attribute 1 is the secret blob (exact bytes)");
    Check(s_addAttrs[2].tag == (0x2u << 28 | 0x03u) && s_addAttrs[2].value.u32 == 1,
          "put: attribute 2 is ACCESSIBILITY=DEVICE_FIRST_UNLOCKED");
    Check(s_addAttrs[3].tag == (0x2u << 28 | 0x05u) && s_addAttrs[3].value.u32 == 0,
          "put: attribute 3 is AUTH_TYPE=NONE");
    Check(s_addAttrs[4].tag == (0x2u << 28 | 0x10u) && s_addAttrs[4].value.u32 == 0,
          "put: attribute 4 is SYNC_TYPE=NEVER");
    Check(s_addAttrs[5].tag == (0x2u << 28 | 0x44u) && s_addAttrs[5].value.u32 == 0,
          "put: attribute 5 is CONFLICT_RESOLUTION=OVERWRITE");
    Check(s_storeExists == 1 && s_storeSecretLength == sizeof(secret) - 1 &&
              BytesEqual(s_storeSecret, secret, s_storeSecretLength),
          "put: the service got the exact secret bytes");

    // ---- put: rejection propagates the raw status ----------------------------------------
    FakeReset();
    s_addRc = 24000008;  // ASSET_DATABASE_ERROR
    status = 0;
    put = ohos_host_asset_put(&api, alias, secret, sizeof(secret) - 1, &status);
    Check(put == OHOS_HOST_ASSET_FAILED && status == 24000008,
          "put: a service rejection is FAILED with the raw status");
    Check(g_fake.add == 1 && !s_storeExists, "put: a rejected write stores nothing");

    // ---- put: the local bounds check (no NDK call) ---------------------------------------
    FakeReset();
    status = 0;
    put = ohos_host_asset_put(&api, "", secret, sizeof(secret) - 1, &status);
    Check(put == OHOS_HOST_ASSET_FAILED && status == 401 && g_fake.add == 0,
          "put: an empty alias is rejected locally with 401");
    char long_alias[OHOS_HOST_ASSET_ALIAS_MAX_BYTES + 2];
    memset(long_alias, 'a', sizeof(long_alias) - 1);
    long_alias[sizeof(long_alias) - 1] = '\0';
    status = 0;
    put = ohos_host_asset_put(&api, long_alias, secret, sizeof(secret) - 1, &status);
    Check(put == OHOS_HOST_ASSET_FAILED && status == 401 && g_fake.add == 0,
          "put: an over-256-byte alias is rejected locally with 401");
    status = 0;
    put = ohos_host_asset_put(&api, alias, (const uint8_t*)"", 0, &status);
    Check(put == OHOS_HOST_ASSET_FAILED && status == 401 && g_fake.add == 0,
          "put: an empty secret is rejected locally with 401");
    uint8_t long_secret[OHOS_HOST_ASSET_SECRET_MAX_BYTES + 1];
    memset(long_secret, 's', sizeof(long_secret));
    status = 0;
    put = ohos_host_asset_put(&api, alias, long_secret, sizeof(long_secret), &status);
    Check(put == OHOS_HOST_ASSET_FAILED && status == 401 && g_fake.add == 0,
          "put: an over-1024-byte secret is rejected locally with 401");
    // The exact limits pass.
    FakeReset();
    char limit_alias[OHOS_HOST_ASSET_ALIAS_MAX_BYTES + 1];
    memset(limit_alias, 'a', OHOS_HOST_ASSET_ALIAS_MAX_BYTES);
    limit_alias[OHOS_HOST_ASSET_ALIAS_MAX_BYTES] = '\0';
    status = 0;
    put = ohos_host_asset_put(&api, limit_alias, long_secret, 1024, &status);
    Check(put == OHOS_HOST_ASSET_OK && g_fake.add == 1,
          "put: the exact 256/1024 limits are accepted");

    // ---- put: an incomplete table is UNAVAILABLE and calls nothing ------------------------
    FakeReset();
    status = 0;
    put = ohos_host_asset_put(&partial, alias, secret, sizeof(secret) - 1, &status);
    Check(put == OHOS_HOST_ASSET_UNAVAILABLE && g_fake.add == 0 && status == 0,
          "put: an incomplete table answers UNAVAILABLE without touching the NDK");

    // ---- get: success, whole copy, exactly one free --------------------------------------
    FakeReset();
    s_storeExists = 1;
    s_storeSecretLength = sizeof(secret) - 1;
    memcpy(s_storeSecret, secret, s_storeSecretLength);
    uint8_t buffer[64];
    memset(buffer, 0xEE, sizeof(buffer));
    size_t length = 0;
    status = -1;
    int get = ohos_host_asset_get(&api, alias, buffer, sizeof(buffer), &length, &status);
    Check(get == OHOS_HOST_ASSET_OK && status == 0 && length == sizeof(secret) - 1 &&
              BytesEqual(buffer, secret, sizeof(secret) - 1),
          "get: success copies the exact secret bytes and sets the length");
    Check(g_fake.query == 1 && g_fake.parse == 1 && g_fake.freeSet == 1,
          "get: one query/parse and exactly one FreeResultSet");

    // ---- get: buffer too small is FAILED and writes nothing -------------------------------
    FakeReset();
    s_storeExists = 1;
    s_storeSecretLength = sizeof(secret) - 1;
    memcpy(s_storeSecret, secret, s_storeSecretLength);
    memset(buffer, 0xEE, sizeof(buffer));
    length = 123;
    get = ohos_host_asset_get(&api, alias, buffer, 4, &length, &status);
    Check(get == OHOS_HOST_ASSET_FAILED && length == 0 && buffer[0] == 0xEE && buffer[3] == 0xEE,
          "get: a too-small buffer answers FAILED and never truncates");
    Check(g_fake.freeSet == 1, "get: the failed copy still frees the result set");

    // ---- get: a result without a secret is FAILED -----------------------------------------
    FakeReset();
    s_storeExists = 1;
    s_storeSecretLength = sizeof(secret) - 1;
    s_hasSecretAttr = 0;
    get = ohos_host_asset_get(&api, alias, buffer, sizeof(buffer), &length, &status);
    Check(get == OHOS_HOST_ASSET_FAILED && g_fake.freeSet == 1,
          "get: a result without a secret is FAILED (and the result set is freed)");

    // ---- get: not found and the local rejection -------------------------------------------
    FakeReset();
    s_storeExists = 0;
    memset(buffer, 0xEE, sizeof(buffer));
    length = 42;
    status = -1;
    get = ohos_host_asset_get(&api, alias, buffer, sizeof(buffer), &length, &status);
    Check(get == OHOS_HOST_ASSET_NOT_FOUND && status == OHOS_HOST_ASSET_RESULT_NOT_FOUND &&
              length == 0 && g_fake.freeSet == 0,
          "get: an absent asset answers NOT_FOUND with the raw status and no free");
    FakeReset();
    s_queryRc = 24000009;  // ASSET_CRYPTO_ERROR
    status = 0;
    get = ohos_host_asset_get(&api, alias, buffer, sizeof(buffer), &length, &status);
    Check(get == OHOS_HOST_ASSET_FAILED && status == 24000009 && g_fake.freeSet == 0,
          "get: a query failure propagates as FAILED with the raw status");
    FakeReset();
    status = 0;
    get = ohos_host_asset_get(&api, "", buffer, sizeof(buffer), &length, &status);
    Check(get == OHOS_HOST_ASSET_FAILED && status == 401 && g_fake.query == 0,
          "get: an empty alias is rejected locally with 401");

    // ---- remove ---------------------------------------------------------------------------
    FakeReset();
    s_storeExists = 1;
    s_storeSecretLength = 3;
    status = -1;
    int remove = ohos_host_asset_remove(&api, alias, &status);
    Check(remove == OHOS_HOST_ASSET_OK && status == 0 && !s_storeExists,
          "remove: success answers OK and drops the entry");
    Check(g_fake.remove == 1 && s_removeAttrCount == 1 &&
              s_removeAttrs[0].tag == (0x3u << 28 | 0x02u) &&
              BytesEqual(s_removeAttrs[0].value.blob.data, (const uint8_t*)alias, strlen(alias)),
          "remove: one alias-only query with the exact bytes");
    FakeReset();
    status = 0;
    remove = ohos_host_asset_remove(&api, alias, &status);
    Check(remove == OHOS_HOST_ASSET_NOT_FOUND && status == OHOS_HOST_ASSET_RESULT_NOT_FOUND,
          "remove: an absent asset answers NOT_FOUND");
    FakeReset();
    s_removeRc = 24000010;  // ASSET_IPC_ERROR
    status = 0;
    remove = ohos_host_asset_remove(&api, alias, &status);
    Check(remove == OHOS_HOST_ASSET_FAILED && status == 24000010,
          "remove: a failure propagates as FAILED with the raw status");
    FakeReset();
    status = 0;
    remove = ohos_host_asset_remove(&api, "", &status);
    Check(remove == OHOS_HOST_ASSET_FAILED && status == 401 && g_fake.remove == 0,
          "remove: an empty alias is rejected locally with 401");
    FakeReset();
    remove = ohos_host_asset_remove(&partial, alias, NULL);
    Check(remove == OHOS_HOST_ASSET_UNAVAILABLE && g_fake.remove == 0,
          "remove: an incomplete table answers UNAVAILABLE");

    // ---- execute: the base64 bridge protocol ----------------------------------------------
    FakeReset();
    char* out = NULL;
    int32_t exec_status = -1;
    Check(ohos_host_asset_execute(&api, "put", alias, "aGVsbG8=", &out, &exec_status) == 0 &&
              out == NULL && exec_status == 0,
          "execute put: success answers 0/status 0 and leaves the out pointer untouched");
    Check(s_storeExists == 1 && s_storeSecretLength == 5 &&
              BytesEqual(s_storeSecret, (const uint8_t*)"hello", 5),
          "execute put: the base64 payload decodes to the exact secret");
    Check(ohos_host_asset_execute(&api, "get", alias, "", &out, &exec_status) == 0 &&
              out != NULL && strcmp(out, "aGVsbG8=") == 0 && exec_status == 0,
          "execute get: success answers the base64 secret");
    free(out);
    out = NULL;
    Check(ohos_host_asset_execute(&api, "remove", alias, "", &out, &exec_status) == 0 &&
              !s_storeExists && exec_status == 0,
          "execute remove: success answers 0 and drops the entry");
    Check(ohos_host_asset_execute(&api, "remove", alias, "", &out, &exec_status) == 1 &&
              exec_status == OHOS_HOST_ASSET_RESULT_NOT_FOUND,
          "execute remove: an absent asset answers not-found (1) with the raw status");
    Check(ohos_host_asset_execute(&api, "get", alias, "", &out, &exec_status) == 1 &&
              out == NULL,
          "execute get: a removed asset answers not-found (1)");
    FakeReset();
    s_addRc = 24000009;
    Check(ohos_host_asset_execute(&api, "put", alias, "aGVsbG8=", &out, &exec_status) == -1 &&
              exec_status == 24000009,
          "execute put: a service rejection answers -1 with the raw status");
    Check(ohos_host_asset_execute(&api, "put", alias, "not-base64!", &out, NULL) == -1,
          "execute put: malformed base64 answers -1");
    Check(ohos_host_asset_execute(&api, "rotate", alias, "", &out, NULL) == -1,
          "execute: an unknown op answers -1");
    Check(ohos_host_asset_execute(&partial, "get", alias, "", &out, NULL) == -1,
          "execute: an unavailable table answers -1");
    Check(ohos_host_asset_execute(&api, "put", alias, "aGVsbG8=", NULL, NULL) == -1,
          "execute: a NULL out pointer answers -1");

    printf("host-asset: %d checks, %d failure(s)\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
