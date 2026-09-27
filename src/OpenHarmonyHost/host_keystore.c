// Native Universal KeyStore (HUKS) engine behind the managed SecureStorage bridge.
//
// Protocol (the same base64 op/alias/data contract the ArkTS shell sink was designed for):
//   generate -> make sure the AES-256-GCM value key exists (idempotent)
//   encrypt  -> base64(nonce[12] || ciphertext || tag[16])
//   decrypt  -> base64(plaintext); a value sealed on another device or with a dropped key
//               fails here and the managed caller keeps its documented file-key fallback
//   delete   -> drop the key (idempotent); the shell/RemoveAll path asks for it so a cleared
//               store leaves no usable key behind
//
// The key is generated inside the keystore (HUKS-owned, alias-scoped) and every encrypt and
// decrypt runs through an init/update/finish session, so the plaintext key never reaches
// managed memory. Every failure is a return code: nothing throws across the C boundary and the
// managed side decides between the keystore path and the honest per-install file-key fallback.
#include "host_keystore.h"

#include "host_optional.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// AES-256-GCM framing: the sealed blob is nonce || ciphertext || tag. The nonce is random per
// value (96-bit, the GCM default) and the tag is the 16-byte HUKS GCM output.
#define OHOS_KEYSTORE_NONCE_BYTES 12u
#define OHOS_KEYSTORE_TAG_BYTES 16u

static const OhosHostOptionalHuksApi *OhosHostKeystoreHuks(void) {
    ohos_host_optional_ensure();
    return &g_ohos_host_optional.huks;
}

bool OhosHostKeystoreAvailable(void) {
    return OhosHostKeystoreHuks()->available;
}

// Best-effort zeroization of key material and plaintext before the buffer is released.
static void OhosHostKeystoreWipe(void *data, size_t length) {
    volatile uint8_t *bytes = (volatile uint8_t *)data;
    while (length-- > 0) {
        *bytes++ = 0;
    }
}

// Fresh GCM nonce from the kernel entropy pool; a failure disables the keystore path for that
// call instead of falling back to a predictable nonce.
static bool OhosHostKeystoreRandom(uint8_t *buffer, size_t length) {
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) {
        return false;
    }
    size_t filled = 0;
    while (filled < length) {
        ssize_t count = read(fd, buffer + filled, length - filled);
        if (count <= 0) {
            close(fd);
            return false;
        }
        filled += (size_t)count;
    }
    close(fd);
    return true;
}

// ---------------------------------------------------------------------------
// base64 (the managed protocol serializes every payload as standard padded base64).
// ---------------------------------------------------------------------------

static const char kBase64Alphabet[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static char *OhosHostKeystoreBase64Encode(const uint8_t *data, size_t length) {
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
        text[at++] = kBase64Alphabet[(chunk >> 18) & 0x3F];
        text[at++] = kBase64Alphabet[(chunk >> 12) & 0x3F];
        text[at++] = i + 1 < length ? kBase64Alphabet[(chunk >> 6) & 0x3F] : '=';
        text[at++] = i + 2 < length ? kBase64Alphabet[chunk & 0x3F] : '=';
    }
    text[at] = '\0';
    return text;
}

static int OhosHostKeystoreBase64Value(char c) {
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

static bool OhosHostKeystoreBase64Decode(const char *text, uint8_t **out, size_t *out_length) {
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
        int a = OhosHostKeystoreBase64Value(text[i]);
        int b = OhosHostKeystoreBase64Value(text[i + 1]);
        int c = text[i + 2] == '=' ? -2 : OhosHostKeystoreBase64Value(text[i + 2]);
        int d = text[i + 3] == '=' ? -2 : OhosHostKeystoreBase64Value(text[i + 3]);
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

// ---------------------------------------------------------------------------
// HUKS sessions.
// ---------------------------------------------------------------------------

static struct OH_Huks_ParamSet *OhosHostKeystoreBuildParamSet(
    const struct OH_Huks_Param *params, uint32_t count) {
    const OhosHostOptionalHuksApi *huks = OhosHostKeystoreHuks();
    struct OH_Huks_ParamSet *set = NULL;
    if (huks->InitParamSet(&set).errorCode != OH_HUKS_SUCCESS) {
        return NULL;
    }
    if (count > 0 && huks->AddParams(set, params, count).errorCode != OH_HUKS_SUCCESS) {
        huks->FreeParamSet(&set);
        return NULL;
    }
    if (huks->BuildParamSet(&set).errorCode != OH_HUKS_SUCCESS) {
        huks->FreeParamSet(&set);
        return NULL;
    }
    return set;
}

// The key is created once per install: AES-256 with both purposes on GCM/NoPadding, stored by
// HUKS itself (no storage flag = HUKS-owned).
static bool OhosHostKeystoreEnsureKey(const char *alias) {
    const OhosHostOptionalHuksApi *huks = OhosHostKeystoreHuks();
    struct OH_Huks_Blob alias_blob = {(uint32_t)strlen(alias), (uint8_t *)alias};
    if (huks->IsKeyItemExist(&alias_blob, NULL).errorCode == OH_HUKS_SUCCESS) {
        return true;
    }
    struct OH_Huks_Param params[] = {
        {.tag = OH_HUKS_TAG_ALGORITHM, .uint32Param = OH_HUKS_ALG_AES},
        {.tag = OH_HUKS_TAG_KEY_SIZE, .uint32Param = OH_HUKS_AES_KEY_SIZE_256},
        {.tag = OH_HUKS_TAG_PURPOSE,
         .uint32Param = OH_HUKS_KEY_PURPOSE_ENCRYPT | OH_HUKS_KEY_PURPOSE_DECRYPT},
        {.tag = OH_HUKS_TAG_PADDING, .uint32Param = OH_HUKS_PADDING_NONE},
        {.tag = OH_HUKS_TAG_BLOCK_MODE, .uint32Param = OH_HUKS_MODE_GCM},
    };
    struct OH_Huks_ParamSet *set = OhosHostKeystoreBuildParamSet(
        params, (uint32_t)(sizeof(params) / sizeof(params[0])));
    if (set == NULL) {
        return false;
    }
    OH_Huks_Result generated = huks->GenerateKeyItem(&alias_blob, set, NULL);
    huks->FreeParamSet(&set);
    // A concurrent first use may have generated the key between the probe and the call.
    return generated.errorCode == OH_HUKS_SUCCESS ||
           generated.errorCode == OH_HUKS_ERR_CODE_KEY_ALREADY_EXIST;
}

// Runs one finish-only session (the documented HUKS shape for a single short buffer) and
// returns the heap buffer the keystore produced. `extra` carries the decrypt-only AE tag.
static bool OhosHostKeystoreRunSession(const char *alias, uint32_t purpose, const uint8_t *nonce,
                                       size_t nonce_length, const uint8_t *ae_tag,
                                       size_t ae_tag_length, const uint8_t *in, size_t in_length,
                                       size_t out_capacity, uint8_t **out, size_t *out_length) {
    const OhosHostOptionalHuksApi *huks = OhosHostKeystoreHuks();
    struct OH_Huks_Param params[7];
    uint32_t count = 0;
    params[count++] = (struct OH_Huks_Param){.tag = OH_HUKS_TAG_ALGORITHM,
                                             .uint32Param = OH_HUKS_ALG_AES};
    params[count++] = (struct OH_Huks_Param){.tag = OH_HUKS_TAG_KEY_SIZE,
                                             .uint32Param = OH_HUKS_AES_KEY_SIZE_256};
    params[count++] = (struct OH_Huks_Param){.tag = OH_HUKS_TAG_PURPOSE,
                                             .uint32Param = purpose};
    params[count++] = (struct OH_Huks_Param){.tag = OH_HUKS_TAG_PADDING,
                                             .uint32Param = OH_HUKS_PADDING_NONE};
    params[count++] = (struct OH_Huks_Param){.tag = OH_HUKS_TAG_BLOCK_MODE,
                                             .uint32Param = OH_HUKS_MODE_GCM};
    params[count++] = (struct OH_Huks_Param){
        .tag = OH_HUKS_TAG_NONCE, .blob = {(uint32_t)nonce_length, (uint8_t *)nonce}};
    if (ae_tag != NULL) {
        params[count++] = (struct OH_Huks_Param){
            .tag = OH_HUKS_TAG_AE_TAG, .blob = {(uint32_t)ae_tag_length, (uint8_t *)ae_tag}};
    }
    struct OH_Huks_ParamSet *set = OhosHostKeystoreBuildParamSet(params, count);
    if (set == NULL) {
        return false;
    }
    struct OH_Huks_Blob alias_blob = {(uint32_t)strlen(alias), (uint8_t *)alias};
    uint8_t handle[sizeof(uint64_t)] = {0};
    struct OH_Huks_Blob handle_blob = {(uint32_t)sizeof(handle), handle};
    OH_Huks_Result result = huks->InitSession(&alias_blob, set, &handle_blob, NULL);
    if (result.errorCode != OH_HUKS_SUCCESS) {
        OH_LOG_WARN(LOG_APP,
                    "[openharmony-host] keystore session init failed: rc=%{public}d",
                    result.errorCode);
        huks->FreeParamSet(&set);
        return false;
    }
    uint8_t *buffer = (uint8_t *)malloc(out_capacity == 0 ? 1 : out_capacity);
    if (buffer == NULL) {
        huks->AbortSession(&handle_blob, NULL);
        huks->FreeParamSet(&set);
        return false;
    }
    struct OH_Huks_Blob in_blob = {(uint32_t)in_length, (uint8_t *)in};
    struct OH_Huks_Blob out_blob = {(uint32_t)out_capacity, buffer};
    result = huks->FinishSession(&handle_blob, set, &in_blob, &out_blob);
    huks->FreeParamSet(&set);
    if (result.errorCode != OH_HUKS_SUCCESS) {
        OH_LOG_WARN(LOG_APP,
                    "[openharmony-host] keystore session finish failed: rc=%{public}d",
                    result.errorCode);
        OhosHostKeystoreWipe(buffer, out_capacity);
        free(buffer);
        return false;
    }
    *out = buffer;
    *out_length = out_blob.size;
    return true;
}

static bool OhosHostKeystoreEncrypt(const char *alias, const uint8_t *plain, size_t plain_length,
                                    uint8_t **sealed, size_t *sealed_length) {
    uint8_t nonce[OHOS_KEYSTORE_NONCE_BYTES];
    if (!OhosHostKeystoreRandom(nonce, sizeof(nonce)) || !OhosHostKeystoreEnsureKey(alias)) {
        return false;
    }
    uint8_t *cipher = NULL;
    size_t cipher_length = 0;
    if (!OhosHostKeystoreRunSession(alias, OH_HUKS_KEY_PURPOSE_ENCRYPT, nonce, sizeof(nonce), NULL,
                                    0, plain, plain_length,
                                    plain_length + OHOS_KEYSTORE_TAG_BYTES, &cipher,
                                    &cipher_length)) {
        return false;
    }
    uint8_t *buffer = (uint8_t *)malloc(sizeof(nonce) + cipher_length);
    if (buffer == NULL) {
        OhosHostKeystoreWipe(cipher, cipher_length);
        free(cipher);
        return false;
    }
    memcpy(buffer, nonce, sizeof(nonce));
    memcpy(buffer + sizeof(nonce), cipher, cipher_length);
    OhosHostKeystoreWipe(cipher, cipher_length);
    free(cipher);
    *sealed = buffer;
    *sealed_length = sizeof(nonce) + cipher_length;
    return true;
}

static bool OhosHostKeystoreDecrypt(const char *alias, const uint8_t *sealed, size_t sealed_length,
                                    uint8_t **plain, size_t *plain_length) {
    if (sealed_length < OHOS_KEYSTORE_NONCE_BYTES + OHOS_KEYSTORE_TAG_BYTES) {
        return false;
    }
    const uint8_t *nonce = sealed;
    size_t cipher_length = sealed_length - OHOS_KEYSTORE_NONCE_BYTES - OHOS_KEYSTORE_TAG_BYTES;
    const uint8_t *cipher = sealed + OHOS_KEYSTORE_NONCE_BYTES;
    const uint8_t *tag = sealed + sealed_length - OHOS_KEYSTORE_TAG_BYTES;
    return OhosHostKeystoreRunSession(alias, OH_HUKS_KEY_PURPOSE_DECRYPT, nonce,
                                      OHOS_KEYSTORE_NONCE_BYTES, tag, OHOS_KEYSTORE_TAG_BYTES,
                                      cipher, cipher_length, cipher_length, plain, plain_length);
}

static bool OhosHostKeystoreDelete(const char *alias) {
    const OhosHostOptionalHuksApi *huks = OhosHostKeystoreHuks();
    struct OH_Huks_Blob alias_blob = {(uint32_t)strlen(alias), (uint8_t *)alias};
    OH_Huks_Result result = huks->DeleteKeyItem(&alias_blob, NULL);
    return result.errorCode == OH_HUKS_SUCCESS ||
           result.errorCode == OH_HUKS_ERR_CODE_ITEM_NOT_EXIST;
}

int OhosHostKeystoreExecute(const char *op, const char *alias, const char *data_base64,
                            char **out_data_base64) {
    if (op == NULL || alias == NULL || alias[0] == '\0' || out_data_base64 == NULL) {
        return -1;
    }
    if (!OhosHostKeystoreAvailable()) {
        return -1;
    }
    if (strcmp(op, "generate") == 0) {
        return OhosHostKeystoreEnsureKey(alias) ? 0 : -1;
    }
    if (strcmp(op, "delete") == 0) {
        return OhosHostKeystoreDelete(alias) ? 0 : -1;
    }
    uint8_t *input = NULL;
    size_t input_length = 0;
    if (data_base64 == NULL ||
        !OhosHostKeystoreBase64Decode(data_base64, &input, &input_length)) {
        return -1;
    }
    if (strcmp(op, "encrypt") == 0) {
        uint8_t *sealed = NULL;
        size_t sealed_length = 0;
        bool ok = OhosHostKeystoreEncrypt(alias, input, input_length, &sealed, &sealed_length);
        OhosHostKeystoreWipe(input, input_length);
        free(input);
        if (!ok) {
            return -1;
        }
        char *text = OhosHostKeystoreBase64Encode(sealed, sealed_length);
        OhosHostKeystoreWipe(sealed, sealed_length);
        free(sealed);
        if (text == NULL) {
            return -1;
        }
        *out_data_base64 = text;
        return 0;
    }
    if (strcmp(op, "decrypt") == 0) {
        uint8_t *plain = NULL;
        size_t plain_length = 0;
        bool ok = OhosHostKeystoreDecrypt(alias, input, input_length, &plain, &plain_length);
        OhosHostKeystoreWipe(input, input_length);
        free(input);
        if (!ok) {
            return -1;
        }
        char *text = OhosHostKeystoreBase64Encode(plain, plain_length);
        OhosHostKeystoreWipe(plain, plain_length);
        free(plain);
        if (text == NULL) {
            return -1;
        }
        *out_data_base64 = text;
        return 0;
    }
    OhosHostKeystoreWipe(input, input_length);
    free(input);
    return -1;
}
