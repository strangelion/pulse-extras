#ifndef PULSE_PET_WEBP_BUDGET_H
#define PULSE_PET_WEBP_BUDGET_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    void *context;
    uint8_t *(*allocate)(void *, size_t);
    void (*release)(void *, uint8_t *, size_t);
    size_t live;
} pet_webp_budget;

typedef struct {
    uint8_t *raw;
    size_t total;
} pet_webp_block;

/* The shared bridge accepts byte allocations, so align explicitly and
 * preserve the exact allocation length, including padding and metadata. */
static inline void *pet_webp_budget_alloc(pet_webp_budget *budget, size_t count,
    size_t size, int clear) {
    const size_t alignment = _Alignof(max_align_t);
    const size_t overhead = sizeof(pet_webp_block) + alignment - 1;
    if (!budget || !count || !size || count > (SIZE_MAX - overhead) / size)
        return NULL;
    const size_t bytes = count * size, total = bytes + overhead;
    uint8_t *raw = budget->allocate(budget->context, total);
    if (!raw) return NULL;
    uint8_t *payload = raw + sizeof(pet_webp_block);
    const size_t remainder = (uintptr_t)payload % alignment;
    if (remainder) payload += alignment - remainder;
    const pet_webp_block block = {raw, total};
    memcpy(payload - sizeof(block), &block, sizeof(block));
    ++budget->live;
    if (clear) memset(payload, 0, bytes);
    return payload;
}

static inline void pet_webp_budget_free(pet_webp_budget *budget, void *ptr) {
    if (!ptr) return;
    pet_webp_block block;
    memcpy(&block, (uint8_t *)ptr - sizeof(block), sizeof(block));
    budget->release(budget->context, block.raw, block.total);
    --budget->live;
}
#endif
