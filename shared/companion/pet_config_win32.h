#ifndef PULSE_PET_CONFIG_WIN32_H
#define PULSE_PET_CONFIG_WIN32_H
#include "pet_surface_win32.h"

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

#endif
