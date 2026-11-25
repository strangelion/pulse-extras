#ifndef PULSE_PET_DEMO_WIN32_H
#define PULSE_PET_DEMO_WIN32_H
#include "pet_surface_win32.h"

/* Owned by Zig main for this entire synchronous run. C returns the exact
 * original size to the same domain; no libc fallback. */
typedef struct {
    void *context;
    uint8_t *(*allocate)(void *, size_t);
    void (*release)(void *, uint8_t *, size_t);
    const pet_resources *resource_bridge;
} pet_memory;

static inline uint8_t *pet_alloc(const pet_memory *memory, size_t bytes) {
    return bytes ? memory->allocate(memory->context, bytes) : NULL;
}

static inline void pet_free(const pet_memory *memory, uint8_t *ptr, size_t bytes) {
    if (ptr) memory->release(memory->context, ptr, bytes);
}


typedef struct {
    uint32_t row, column, wait_ms;
} pet_demo_sample;
typedef int (*pet_demo_sample_fn)(uint32_t, uint32_t, uint64_t, int, pet_demo_sample *);
typedef int (*pet_demo_validate_fn)(uint32_t, const uint8_t *, size_t);

/* Explicit local file only. No automatic codec installation or discovery.
 * Returns a memory-domain-owned tightly packed RGBA8 atlas, or NULL on failure.
 * COM initialization and cleanup are internal to the calling thread. */
uint8_t *pet_demo_load_webp(const pet_memory *memory, const wchar_t *path, unsigned version,
    pet_demo_validate_fn validate, size_t *decoded_bytes);
/* The same callback shape takes an activity frame count instead of a
 * Classic version. The activity timeline returns 0 for a frame, 1 for
 * completion, and -1 for invalid metadata. */
typedef int (*pet_activity_sample_fn)(uint32_t, uint32_t, uint64_t, pet_demo_sample *);
uint8_t *pet_demo_load_activity(const pet_memory *memory, const wchar_t *path, unsigned frames,
    pet_demo_validate_fn validate, size_t *decoded_bytes);
#define PET_PACKAGE_MAX 16
#define PET_OUTFIT_SLOTS 17
typedef struct {
    uint32_t frames, fps;
    uint8_t leaf[80];
} pet_package_rep;
typedef struct {
    uint8_t name[161];
    pet_package_rep reps[PET_OUTFIT_SLOTS];
} pet_package_item;
typedef struct {
    uint8_t name[161], leaf[80];
} pet_package_outfit;
typedef struct {
    uint32_t outfit, flags, time_from, time_to, days, date_from, date_to;
} pet_schedule_rule;
typedef struct {
    uint32_t version, count, outfit_count;
    pet_package_item items[PET_PACKAGE_MAX];
    pet_package_outfit outfits[PET_PACKAGE_MAX];
    uint32_t rule_count;
    pet_schedule_rule rules[32];
    char pet_id[65], outfit_ids[PET_PACKAGE_MAX][33], activity_ids[PET_PACKAGE_MAX][33];
    float gaze_x, gaze_y;
} pet_package_meta;
_Static_assert(sizeof(pet_package_rep) == 88, "package representation ABI");
_Static_assert(sizeof(pet_package_item) == 1660, "package item ABI");
_Static_assert(sizeof(pet_schedule_rule) == 28, "schedule rule ABI");
_Static_assert(sizeof(pet_package_meta) == 32460, "package metadata ABI");
typedef uint32_t (*pet_schedule_fn)(const pet_package_meta *, uint32_t, uint32_t, uint32_t, uint32_t);
typedef int (*pet_package_parse_fn)(const pet_memory *, const uint8_t *, size_t,
    const uint8_t *, size_t, pet_package_meta *);
typedef struct {
    pet_package_meta meta;
    HANDLE root, activities, wardrobe, atlas;
    HANDLE outfit_files[PET_PACKAGE_MAX];
    HANDLE files[PET_PACKAGE_MAX][PET_OUTFIT_SLOTS];
} pet_package;
#define PET_FINGERPRINT_MAX_FILES 290u
typedef struct {
    uint8_t path[96];
    uint64_t size;
    uint8_t digest[32];
} pet_fingerprint_file;
typedef void (*pet_hash_fn)(const uint8_t *, size_t, uint8_t *);
typedef int (*pet_fingerprint_fn)(const pet_fingerprint_file *, size_t, uint8_t *);
BOOL pet_package_open(const pet_memory *memory, pet_package *package, const wchar_t *folder,
    const wchar_t *id, pet_package_parse_fn parse,
    pet_demo_validate_fn validate, pet_demo_validate_fn validate_activity,
    pet_hash_fn hash, pet_fingerprint_fn fingerprint, uint8_t *digest);
void pet_package_close(const pet_memory *memory, pet_package *package);
uint8_t *pet_package_load_atlas(const pet_memory *memory, const pet_package *package, unsigned outfit,
    pet_demo_validate_fn validate, size_t *decoded_bytes);
uint8_t *pet_package_load_activity(const pet_memory *memory, const pet_package *package, unsigned index, unsigned outfit,
    pet_demo_validate_fn validate, size_t *decoded_bytes);
/* All control callbacks are UI-owner only. Decode/notify run on the
 * shared worker. Native context and its borrowed handles outlive stop. */
enum { PET_DECODE_OUTFIT = 0, PET_DECODE_ACTIVITY = 1 };
typedef struct {
    uint32_t kind, outfit, activity;
    uint8_t *pixels;
    size_t bytes;
} pet_decode_result;
typedef uint8_t *(*pet_decode_fn)(void *, uint32_t, uint32_t, uint32_t, size_t *);
typedef void (*pet_decode_notify_fn)(void *);
typedef struct {
    void *owner;
    int (*bind)(void *, void *, pet_decode_fn, pet_decode_notify_fn);
    int (*submit)(void *, uint32_t, uint32_t, uint32_t);
    int (*start)(void *);
    int (*take)(void *, pet_decode_result *);
    void (*invalidate)(void *);
    int (*busy)(void *);
    void (*stop)(void *);
} pet_async;
int pet_demo_run(const pet_memory *memory, const pet_async *async, pet_demo_sample_fn sample, pet_demo_validate_fn validate,
    pet_activity_sample_fn sample_activity, pet_demo_validate_fn validate_activity,
    pet_package_parse_fn parse_package, pet_schedule_fn schedule,
    pet_hash_fn hash, pet_fingerprint_fn fingerprint);
#endif
