#ifndef PULSE_PET_RESOURCES_H
#define PULSE_PET_RESOURCES_H
#include <stddef.h>
#include <stdint.h>

/* Session-local owner, callbacks synchronize shared accounting. NULL is allowed only for the low-level
 * surface unit fixture, which has no runtime owner. */
enum { PET_RESOURCE_FILE = 0, PET_RESOURCE_CODEC = 1, PET_RESOURCE_DIB = 2, PET_RESOURCE_NOTIFY = 3,
    PET_RESOURCE_IPC = 4, PET_RESOURCE_REGISTRY = 5, PET_RESOURCE_MENU = 6, PET_RESOURCE_ARGV = 7,
    PET_RESOURCE_WINDOW = 8, PET_RESOURCE_MEMORY_DC = 9, PET_RESOURCE_DESKTOP_DC = 10 };
/* Fixed diagnostic wire codes, no caller-provided strings or paths. */
enum { PET_NOTE_ADMITTED = 0, PET_NOTE_BACKPRESSURE = 1, PET_NOTE_CANCELLED = 2,
    PET_NOTE_IO_FAILURE = 3, PET_NOTE_TIMEOUT = 4 };
typedef struct {
    void *context;
    int (*reserve)(void *, uint32_t, size_t);
    void (*release)(void *, uint32_t, size_t);
    void (*cleanup_failed)(void *, uint32_t);
    void (*note)(void *, uint32_t);
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
static inline void pet_note(const pet_resources *r, uint32_t kind) {
    if (r && r->note) r->note(r->context, kind);
}
#endif
