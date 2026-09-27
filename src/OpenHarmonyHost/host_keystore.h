// Native Universal KeyStore (HUKS) engine behind the managed SecureStorage bridge.
//
// The managed client (Microsoft.Maui.Platform.OpenHarmonyKeystore) queues base64 requests
// through ohos_host_keystore_request; openharmony_host.c offers each one to this engine first
// and only falls back to the ArkTS shell sink when the device does not ship the HUKS NDK
// library. The value key is generated and kept inside the keystore (AES-256-GCM), so the
// plaintext key never reaches managed memory and another device cannot decrypt the values.

#ifndef OHOS_HOST_KEYSTORE_H
#define OHOS_HOST_KEYSTORE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// True when libhuks_ndk.z.so and every entry point resolved on this device. Cached for the
// process lifetime by the optional-library loader.
bool OhosHostKeystoreAvailable(void);

// Runs one keystore op ("generate" | "encrypt" | "decrypt" | "delete") for the managed
// protocol. On success returns 0 and sets *out_data_base64 to a malloc'd base64 payload (NULL
// for generate/delete; the caller frees it). On failure returns -1 and leaves
// *out_data_base64 untouched. Never throws across the boundary; every error is a return code.
int OhosHostKeystoreExecute(const char *op, const char *alias, const char *data_base64,
                            char **out_data_base64);

#ifdef __cplusplus
}
#endif

#endif  // OHOS_HOST_KEYSTORE_H
