#ifndef PULSE_PET_RESOURCES_H
#define PULSE_PET_RESOURCES_H
#include <stddef.h>
#include <stdint.h>

/* Session-local owner, callbacks synchronize shared accounting. NULL is allowed only for the low-level
 * surface unit fixture, which has no runtime owner. */
enum { PET_RESOURCE_FILE = 0, PET_RESOURCE_CODEC = 1, PET_RESOURCE_DIB = 2, PET_RESOURCE_NOTIFY = 3 };
typedef struct {
    void *context;
    int (*reserve)(void *, uint32_t, size_t);
    void (*release)(void *, uint32_t, size_t);
    void (*cleanup_failed)(void *, uint32_t);
} pet_resources;

static inline int pet_reserve(const pet_resources *r, uint32_t kind, size_t amount) {
    return !r || r->reserve(r->context, kind, amount);
}
static inline void pet_release(const pet_resources *r, uint32_t kind, size_t amount) {
    if (r) r->release(r->context, kind, amount);
}
static inline void pet_cleanup_failed(const pet_resources *r, uint32_t kind) {
    if (r) r->cleanup_failed(r->context, kind);
}
#endif
