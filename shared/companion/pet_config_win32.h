#ifndef PULSE_PET_CONFIG_WIN32_H
#define PULSE_PET_CONFIG_WIN32_H
#include "pet_demo_win32.h"

#define PET_CONFIG_KEY L"Software\\PulseExtras\\CompanionDemo"
#define PET_CONFIG_VALUE L"SettingsV1"
#define PET_CONFIG_TOPMOST 1u
#define PET_CONFIG_REDUCED 2u
#define PET_CONFIG_POSITION 4u

typedef struct {
    LONG x, y;
    DWORD scale, flags;
} pet_config;

typedef enum {
    PET_CONFIG_OK, PET_CONFIG_MISSING, PET_CONFIG_INVALID, PET_CONFIG_IO_ERROR
} pet_config_result;

/* One fixed-size, versioned REG_BINARY value. No paths, tokens or secrets.
 * Load does not modify output on failure; save never overwrites an existing
 * invalid/unknown record. The supplied key remains caller-owned. */
pet_config_result pet_config_load(HKEY key, pet_config *config);
pet_config_result pet_config_save(HKEY key, const pet_config *config);

/* Independent, bounded ID-based preferences; legacy SettingsV1 unchanged.
 * No paths, names, timestamps, decoded assets or session failure history. */
#define PET_PREFERENCES_VALUE L"PetPreferencesV1"
#define PET_PREFERENCES_MAX 16u
typedef struct {
    char pet[65], outfit[33], enabled[PET_PACKAGE_MAX][33];
} pet_preferences;

pet_config_result pet_preferences_load(HKEY key, const char *pet_id, pet_preferences *out);
pet_config_result pet_preferences_save(HKEY key, const pet_preferences *prefs);
/* Maps only exact stable IDs in the current admitted catalog. Unknown
 * outfit falls back to creator policy; unknown activities remain off. */
BOOL pet_preferences_apply(const pet_package_meta *meta, const pet_preferences *prefs,
    unsigned *outfit, int *automatic, uint32_t *enabled);
BOOL pet_preferences_capture(const pet_package_meta *meta, unsigned outfit,
    int automatic, uint32_t enabled, pet_preferences *out);
#endif
