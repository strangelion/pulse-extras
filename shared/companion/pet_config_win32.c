#include "pet_config_win32.h"
#include <string.h>

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


/* All fields byte arrays: fixed on-disk layout independent of alignment.
 * One value caps the number of retained pets; no automatic eviction. */
typedef struct {
    uint8_t magic[4], version, count, reserved[2];
    pet_preferences pets[PET_PREFERENCES_MAX];
} preferences_table;
_Static_assert(sizeof(pet_preferences) == 626, "pet preferences record");
_Static_assert(sizeof(preferences_table) == 10024, "pet preferences table");

static BOOL valid_id(const char *id, size_t capacity) {
    size_t i = 0;
    if (!id || capacity < 2) return FALSE;
    for (; i < capacity && id[i]; ++i) {
        unsigned char ch = (unsigned char)id[i];
        if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) continue;
        if (i && (ch == '-' || ch == '_')) continue;
        return FALSE;
    }
    if (!i || i == capacity) return FALSE;
    for (; i < capacity; ++i) if (id[i]) return FALSE;
    return TRUE;
}

static BOOL all_zero(const void *data, size_t bytes) {
    const uint8_t *p = data;
    for (size_t i = 0; i < bytes; ++i) if (p[i]) return FALSE;
    return TRUE;
}

static BOOL valid_preferences(const pet_preferences *prefs) {
    if (!prefs || !valid_id(prefs->pet, sizeof(prefs->pet)) ||
        strcmp(prefs->pet, "builtin") == 0 || !valid_id(prefs->outfit, sizeof(prefs->outfit))) return FALSE;
    BOOL ended = FALSE;
    for (unsigned i = 0; i < PET_PACKAGE_MAX; ++i) {
        if (!prefs->enabled[i][0]) {
            ended = TRUE;
            if (!all_zero(prefs->enabled[i], sizeof(prefs->enabled[i]))) return FALSE;
            continue;
        }
        if (ended || !valid_id(prefs->enabled[i], sizeof(prefs->enabled[i]))) return FALSE;
        for (unsigned j = 0; j < i; ++j)
            if (strcmp(prefs->enabled[i], prefs->enabled[j]) == 0) return FALSE;
    }
    return TRUE;
}

static pet_config_result read_preferences(HKEY key, preferences_table *table) {
    DWORD bytes = sizeof(*table), type = 0;
    LSTATUS status = RegQueryValueExW(key, PET_PREFERENCES_VALUE, NULL, &type, (BYTE *)table, &bytes);
    if (status == ERROR_FILE_NOT_FOUND) {
        memset(table, 0, sizeof(*table));
        memcpy(table->magic, "PPPF", 4);
        table->version = 1;
        return PET_CONFIG_MISSING;
    }
    if (status == ERROR_MORE_DATA) return PET_CONFIG_INVALID;
    if (status != ERROR_SUCCESS) return PET_CONFIG_IO_ERROR;
    if (type != REG_BINARY || bytes != sizeof(*table) || memcmp(table->magic, "PPPF", 4) ||
        table->version != 1 || table->count > PET_PREFERENCES_MAX ||
        !all_zero(table->reserved, sizeof(table->reserved))) return PET_CONFIG_INVALID;
    for (unsigned i = 0; i < PET_PREFERENCES_MAX; ++i) {
        if (i >= table->count) {
            if (!all_zero(&table->pets[i], sizeof(table->pets[i]))) return PET_CONFIG_INVALID;
            continue;
        }
        if (!valid_preferences(&table->pets[i])) return PET_CONFIG_INVALID;
        for (unsigned j = 0; j < i; ++j)
            if (strcmp(table->pets[i].pet, table->pets[j].pet) == 0) return PET_CONFIG_INVALID;
    }
    return PET_CONFIG_OK;
}

pet_config_result pet_preferences_load(HKEY key, const char *pet_id, pet_preferences *out) {
    if (!key || !pet_id || !out) return PET_CONFIG_INVALID;
    preferences_table table;
    pet_config_result status = read_preferences(key, &table);
    if (status != PET_CONFIG_OK) return status;
    for (unsigned i = 0; i < table.count; ++i) {
        if (strcmp(table.pets[i].pet, pet_id) == 0) {
            *out = table.pets[i];
            return PET_CONFIG_OK;
        }
    }
    return PET_CONFIG_MISSING;
}

pet_config_result pet_preferences_save(HKEY key, const pet_preferences *prefs) {
    if (!key || !valid_preferences(prefs)) return PET_CONFIG_INVALID;
    preferences_table table;
    pet_config_result status = read_preferences(key, &table);
    if (status != PET_CONFIG_OK && status != PET_CONFIG_MISSING) return status;
    unsigned i = 0;
    for (; i < table.count; ++i)
        if (strcmp(table.pets[i].pet, prefs->pet) == 0) break;
    if (i == table.count) {
        if (i == PET_PREFERENCES_MAX) return PET_CONFIG_INVALID;
        ++table.count;
    }
    table.pets[i] = *prefs;
    return RegSetValueExW(key, PET_PREFERENCES_VALUE, 0, REG_BINARY,
        (const BYTE *)&table, sizeof(table)) == ERROR_SUCCESS ? PET_CONFIG_OK : PET_CONFIG_IO_ERROR;
}

/* The catalog is the trusted owned projection of an admitted package.
 * Validate bounds and fixed fields before using them as C strings. */
static BOOL valid_catalog(const pet_package_meta *meta) {
    if (!meta || meta->count > PET_PACKAGE_MAX || meta->outfit_count > PET_PACKAGE_MAX ||
        meta->rule_count > 32 || !valid_id(meta->pet_id, sizeof(meta->pet_id)) ||
        strcmp(meta->pet_id, "builtin") == 0) return FALSE;
    for (unsigned i = 0; i < meta->outfit_count; ++i) {
        if (!valid_id(meta->outfit_ids[i], sizeof(meta->outfit_ids[i])) ||
            strcmp(meta->outfit_ids[i], "auto") == 0 || strcmp(meta->outfit_ids[i], "default") == 0) return FALSE;
        for (unsigned j = 0; j < i; ++j)
            if (strcmp(meta->outfit_ids[i], meta->outfit_ids[j]) == 0) return FALSE;
    }
    for (unsigned i = 0; i < meta->count; ++i) {
        if (!valid_id(meta->activity_ids[i], sizeof(meta->activity_ids[i]))) return FALSE;
        for (unsigned j = 0; j < i; ++j)
            if (strcmp(meta->activity_ids[i], meta->activity_ids[j]) == 0) return FALSE;
    }
    return TRUE;
}

BOOL pet_preferences_apply(const pet_package_meta *meta, const pet_preferences *prefs,
    unsigned *outfit, int *automatic, uint32_t *enabled) {
    if (!valid_catalog(meta) || !valid_preferences(prefs) ||
        !outfit || !automatic || !enabled || strcmp(meta->pet_id, prefs->pet)) return FALSE;
    unsigned selected = 0;
    int auto_mode = meta->rule_count != 0;
    if (strcmp(prefs->outfit, "default") == 0) auto_mode = 0;
    else if (strcmp(prefs->outfit, "auto") != 0) {
        for (unsigned i = 0; i < meta->outfit_count; ++i)
            if (strcmp(meta->outfit_ids[i], prefs->outfit) == 0) {
                selected = i + 1;
                auto_mode = 0;
                break;
            }
    }
    uint32_t mask = 0;
    for (unsigned i = 0; i < meta->count; ++i)
        for (unsigned j = 0; j < PET_PACKAGE_MAX && prefs->enabled[j][0]; ++j)
            if (strcmp(meta->activity_ids[i], prefs->enabled[j]) == 0) mask |= UINT32_C(1) << i;
    *outfit = selected;
    *automatic = auto_mode;
    *enabled = mask;
    return TRUE;
}

BOOL pet_preferences_capture(const pet_package_meta *meta, unsigned outfit,
    int automatic, uint32_t enabled, pet_preferences *out) {
    if (!out || !valid_catalog(meta) || outfit > meta->outfit_count ||
        (enabled & ~((UINT32_C(1) << meta->count) - 1))) return FALSE;
    pet_preferences next = {0};
    memcpy(next.pet, meta->pet_id, sizeof(next.pet));
    const char *id = automatic ? "auto" : (outfit ? meta->outfit_ids[outfit - 1] : "default");
    memcpy(next.outfit, id, strlen(id) + 1);
    unsigned n = 0;
    for (unsigned i = 0; i < meta->count; ++i)
        if (enabled & (UINT32_C(1) << i))
            memcpy(next.enabled[n++], meta->activity_ids[i], sizeof(next.enabled[0]));
    *out = next;
    return TRUE;
}

BOOL pet_preferences_update(const pet_package_meta *meta, unsigned outfit,
    int automatic, uint32_t enabled, const pet_preferences *previous,
    unsigned changed, pet_preferences *out) {
    pet_preferences next;
    if (!out || !changed || (changed & ~(PET_PREF_OUTFIT_CHANGED | PET_PREF_ACTIVITIES_CHANGED)) ||
        !pet_preferences_capture(meta, outfit, automatic, enabled, &next)) return FALSE;
    if (previous) {
        if (!valid_preferences(previous) || strcmp(previous->pet, next.pet)) return FALSE;
        if (!(changed & PET_PREF_OUTFIT_CHANGED))
            memcpy(next.outfit, previous->outfit, sizeof(next.outfit));
        if (!(changed & PET_PREF_ACTIVITIES_CHANGED))
            memcpy(next.enabled, previous->enabled, sizeof(next.enabled));
    }
    *out = next;
    return TRUE;
}
