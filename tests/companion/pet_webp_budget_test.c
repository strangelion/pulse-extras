#include "../../shared/companion/pet_webp_budget.h"
#include <assert.h>
#include <stdlib.h>

typedef struct { size_t used, limit, denied; } fixture;
static uint8_t *allocate(void *opaque, size_t bytes) {
    fixture *f = opaque;
    if (bytes > f->limit - f->used) { ++f->denied; return NULL; }
    uint8_t *p = malloc(bytes + 1);
    if (!p) return NULL;
    f->used += bytes;
    return p + 1; /* deliberately misaligned byte allocation */
}
static void release(void *opaque, uint8_t *ptr, size_t bytes) {
    fixture *f = opaque;
    assert(bytes <= f->used);
    f->used -= bytes;
    free(ptr - 1);
}
int main(void) {
    fixture f = {0, 256, 0};
    pet_webp_budget b = {&f, allocate, release, 0};
    uint8_t *p = pet_webp_budget_alloc(&b, 8, 4, 1);
    assert(p && (uintptr_t)p % _Alignof(max_align_t) == 0 && b.live == 1);
    for (size_t i = 0; i < 32; ++i) assert(p[i] == 0);
    memset(p, 0x5a, 32);
    void *q = pet_webp_budget_alloc(&b, 1, 64, 0);
    assert(q && b.live == 2);
    assert(!pet_webp_budget_alloc(&b, SIZE_MAX, 2, 0));
    assert(!pet_webp_budget_alloc(&b, 0, 5, 0));
    assert(!pet_webp_budget_alloc(&b, 1, 256, 0) && f.denied == 1);
    pet_webp_budget_free(&b, NULL);
    pet_webp_budget_free(&b, q);
    pet_webp_budget_free(&b, p);
    assert(!f.used && !b.live);
    return 0;
}
