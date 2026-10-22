#ifndef MASSA_NATIVE_H
#define MASSA_NATIVE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
void mx_blake3(const uint8_t *input, size_t length, uint8_t output[32]);
bool mx_base58check_encode(const uint8_t *payload, size_t length, char *output, size_t *output_length);
bool mx_base58check_decode(const char *input, size_t length, uint8_t *payload, size_t payload_length);
#endif
