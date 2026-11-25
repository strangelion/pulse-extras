#ifndef PULSE_PET_CATALOG_STORE_WIN32_H
#define PULSE_PET_CATALOG_STORE_WIN32_H
#include <windows.h>
#include <stdint.h>
#include <stddef.h>

/* Caller owns a private, ACL-protected local directory and serializes calls.
 * No user-selected root, arbitrary filenames, scanning or recursive deletion.
 * Payload validation is the Zig PCT1 codec's responsibility. */
#define PET_CATALOG_RECORD_MAX 1119u
#define PET_INVENTORY_MAX 65536u
typedef enum {
    PET_STORE_OK = 0, PET_STORE_MISSING, PET_STORE_INVALID,
    PET_STORE_IO, PET_STORE_BUSY, PET_STORE_CLEANUP_FAILED
} pet_store_result;
pet_store_result pet_store_read(const wchar_t *root, uint64_t id,
    uint8_t *out, size_t capacity, size_t *written);
pet_store_result pet_store_write(const wchar_t *root, uint64_t id,
    const uint8_t *data, size_t length);
pet_store_result pet_inventory_read(const wchar_t *root, uint8_t *out,
    size_t capacity, size_t *written);
pet_store_result pet_inventory_write(const wchar_t *root, const uint8_t *data, size_t length);
#endif
