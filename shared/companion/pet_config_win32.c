#include "pet_config_win32.h"

#define PET_CONFIG_MAGIC 0x54455050u
#define PET_CONFIG_VERSION 1u

/* Native Windows little-endian DWORD record, not a raw padded C struct. */
static int valid_config(const pet_config *config) {
    return config && config->scale >= PET_MIN_SCALE && config->scale <= PET_MAX_SCALE &&
        !(config->flags & ~(PET_CONFIG_TOPMOST | PET_CONFIG_REDUCED | PET_CONFIG_POSITION));
}

pet_config_result pet_config_load(HKEY key, pet_config *config) {
    if (!key || !config) return PET_CONFIG_INVALID;
    DWORD data[6] = {0}, bytes = sizeof(data), type = 0;
    LSTATUS status = RegQueryValueExW(key, PET_CONFIG_VALUE, NULL, &type,
        (BYTE *)data, &bytes);
    if (status == ERROR_FILE_NOT_FOUND) return PET_CONFIG_MISSING;
    if (status == ERROR_MORE_DATA) return PET_CONFIG_INVALID;
    if (status != ERROR_SUCCESS) return PET_CONFIG_IO_ERROR;
    if (type != REG_BINARY || bytes != sizeof(data) ||
        data[0] != PET_CONFIG_MAGIC || data[1] != PET_CONFIG_VERSION)
        return PET_CONFIG_INVALID;
    pet_config candidate = {(LONG)data[2], (LONG)data[3], data[4], data[5]};
    if (!valid_config(&candidate)) return PET_CONFIG_INVALID;
    *config = candidate;
    return PET_CONFIG_OK;
}

pet_config_result pet_config_save(HKEY key, const pet_config *config) {
    if (!key || !valid_config(config)) return PET_CONFIG_INVALID;
    pet_config previous;
    pet_config_result result = pet_config_load(key, &previous);
    if (result != PET_CONFIG_OK && result != PET_CONFIG_MISSING) return result;
    DWORD data[] = {PET_CONFIG_MAGIC, PET_CONFIG_VERSION, (DWORD)config->x,
        (DWORD)config->y, config->scale, config->flags};
    return RegSetValueExW(key, PET_CONFIG_VALUE, 0, REG_BINARY,
        (const BYTE *)data, sizeof(data)) == ERROR_SUCCESS ? PET_CONFIG_OK : PET_CONFIG_IO_ERROR;
}
