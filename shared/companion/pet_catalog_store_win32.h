#ifndef PULSE_PET_CATALOG_STORE_WIN32_H
#define PULSE_PET_CATALOG_STORE_WIN32_H
#include <windows.h>
#include <stdint.h>
#include <stddef.h>

/* Caller owns a private, ACL-protected local directory and serializes calls.
 * No user-selected root, arbitrary filenames, scanning or recursive deletion.
 * Payload validation is the Zig PCT1/PCT2 codec's responsibility. */
#define PET_CATALOG_RECORD_MAX 1124u
#define PET_INVENTORY_MAX 131072u
#define PET_REMOVAL_RECEIPT_BYTES 221u
#define PET_HISTORY_MAX (8u + 16u * 72u + 32u)
#define PET_MARKET_CACHE_SLOTS 32u
#define PET_MARKET_CACHE_MAX (4u * 1024u * 1024u + 52u + 64u + 2048u)
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
/* Immutable, fixed-ID receipt namespace. No overwrite or deletion. */
pet_store_result pet_removal_receipt_read(const wchar_t *root, uint64_t id,
    uint8_t *out, size_t capacity, size_t *written);
pet_store_result pet_removal_receipt_write(const wchar_t *root, uint64_t id,
    const uint8_t *data, size_t length);
/* Immutable cleanup intent, same typed PRC1 identity payload. */
pet_store_result pet_cleanup_marker_read(const wchar_t *root, uint64_t id,
    uint8_t *out, size_t capacity, size_t *written);
pet_store_result pet_cleanup_marker_write(const wchar_t *root, uint64_t id,
    const uint8_t *data, size_t length);
/* One fixed, bounded redacted session-history record. */
pet_store_result pet_history_read(const wchar_t *root, uint8_t *out,
    size_t capacity, size_t *written);
pet_store_result pet_history_write(const wchar_t *root, const uint8_t *data, size_t length);
pet_store_result pet_market_cache_read(const wchar_t *root, uint32_t slot,
    uint8_t *out, size_t capacity, size_t *written);
pet_store_result pet_market_cache_write(const wchar_t *root, uint32_t slot,
    const uint8_t *data, size_t length);
#endif
