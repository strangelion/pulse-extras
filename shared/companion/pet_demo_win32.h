#ifndef PULSE_PET_DEMO_WIN32_H
#define PULSE_PET_DEMO_WIN32_H
#include "pet_surface_win32.h"

typedef struct {
    uint32_t row, column, wait_ms;
} pet_demo_sample;
typedef int (*pet_demo_sample_fn)(uint32_t, uint32_t, uint64_t, int, pet_demo_sample *);
typedef int (*pet_demo_validate_fn)(uint32_t, const uint8_t *, size_t);

/* Explicit local file only. No automatic codec installation or discovery.
 * Returns a malloc-owned tightly packed RGBA8 atlas, or NULL on failure.
 * COM initialization and cleanup are internal, UI thread only. */
uint8_t *pet_demo_load_webp(const wchar_t *path, unsigned version,
    pet_demo_validate_fn validate, size_t *decoded_bytes);
/* The same callback shape takes an activity frame count instead of a
 * Classic version. The activity timeline returns 0 for a frame, 1 for
 * completion, and -1 for invalid metadata. */
typedef int (*pet_activity_sample_fn)(uint32_t, uint32_t, uint64_t, pet_demo_sample *);
uint8_t *pet_demo_load_activity(const wchar_t *path, unsigned frames,
    pet_demo_validate_fn validate, size_t *decoded_bytes);
#define PET_PACKAGE_MAX 16
typedef struct {
    uint32_t frames, fps;
    uint8_t name[161], leaf[80];
} pet_package_item;
typedef struct {
    uint32_t version, count;
    pet_package_item items[PET_PACKAGE_MAX];
} pet_package_meta;
typedef int (*pet_package_parse_fn)(const uint8_t *, size_t,
    const uint8_t *, size_t, pet_package_meta *);
typedef struct {
    pet_package_meta meta;
    HANDLE root, activities, atlas, files[PET_PACKAGE_MAX];
} pet_package;
BOOL pet_package_open(pet_package *package, const wchar_t *folder,
    const wchar_t *id, pet_package_parse_fn parse,
    pet_demo_validate_fn validate, pet_demo_validate_fn validate_activity);
void pet_package_close(pet_package *package);
uint8_t *pet_package_load_atlas(const pet_package *package,
    pet_demo_validate_fn validate, size_t *decoded_bytes);
uint8_t *pet_package_load_activity(const pet_package *package, unsigned index,
    pet_demo_validate_fn validate, size_t *decoded_bytes);
int pet_demo_run(pet_demo_sample_fn sample, pet_demo_validate_fn validate,
    pet_activity_sample_fn sample_activity, pet_demo_validate_fn validate_activity,
    pet_package_parse_fn parse_package);
#endif
