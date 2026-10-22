// Bounded glue only. Hashing and Base58Check are delegated to upstream libraries.
#include "MassaNative.h"
#include "../../Vendor/BLAKE3/blake3.h"
#include "../../Vendor/libbase58/libbase58.h"
#include <CommonCrypto/CommonDigest.h>
#include <dispatch/dispatch.h>
#include <string.h>

static bool apple_sha256(void *out, const void *input, size_t length) {
    if (length > UINT32_MAX) return false;
    return CC_SHA256(input, (CC_LONG)length, out) != NULL;
}
static void initialize_base58(void *unused) { b58_sha256_impl = apple_sha256; }
static void prepare_base58(void) {
    static dispatch_once_t once;
    dispatch_once_f(&once, NULL, initialize_base58);
}
void mx_blake3(const uint8_t *input, size_t length, uint8_t output[32]) {
    blake3_hasher hasher;
    blake3_hasher_init(&hasher);
    blake3_hasher_update(&hasher, input, length);
    blake3_hasher_finalize(&hasher, output, 32);
}
bool mx_base58check_encode(const uint8_t *payload, size_t length, char *output, size_t *output_length) {
    if (!payload || (length != 32 && length != 64)) return false;
    prepare_base58();
    return b58check_enc(output, output_length, 0, payload, length);
}
bool mx_base58check_decode(const char *input, size_t length, uint8_t *payload, size_t payload_length) {
    if (!input || !payload || length == 0 || length > 100 || (payload_length != 32 && payload_length != 64)) return false;
    prepare_base58();
    uint8_t decoded[69] = {0};
    size_t expected = payload_length + 5;
    size_t size = expected;
    bool valid = b58tobin(decoded, &size, input, length) && size == expected && b58check(decoded, size, input, length) == 0;
    if (valid) memcpy(payload, decoded + 1, payload_length);
    // The decoded input may be a private seed; do not leave this stack buffer populated.
    memset_s(decoded, sizeof(decoded), 0, sizeof(decoded));
    return valid;
}
