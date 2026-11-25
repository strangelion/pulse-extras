#include "../../shared/companion/pet_config_win32.h"
#include <stdio.h>
#include <wchar.h>
#include <string.h>
#define CHECK(expr) do { if (!(expr)) { \
    fprintf(stderr, "config test failed at line %d\n", __LINE__); goto cleanup; \
} } while (0)

int main(void) {
    int rc = 1;
    HKEY key = NULL;
    DWORD disposition = 0;
    wchar_t path[128];
    CHECK(swprintf(path, 128, L"Software\\PulseExtras-ConfigTest-%lu-%llu",
        (unsigned long)GetCurrentProcessId(), (unsigned long long)GetTickCount64()) > 0);
    CHECK(RegCreateKeyExW(HKEY_CURRENT_USER, path, 0, NULL, REG_OPTION_VOLATILE,
        KEY_QUERY_VALUE | KEY_SET_VALUE, NULL, &key, &disposition) == ERROR_SUCCESS);
    CHECK(disposition == REG_CREATED_NEW_KEY);
    pet_config expected = {-1500, 900, 175, PET_CONFIG_POSITION | PET_CONFIG_REDUCED};
    pet_config actual = {123, 456, 100, 0};
    CHECK(pet_config_load(key, &actual) == PET_CONFIG_MISSING && actual.x == 123);
    CHECK(pet_config_save(key, &expected) == PET_CONFIG_OK);
    CHECK(pet_config_load(key, &actual) == PET_CONFIG_OK);
    CHECK(actual.x == expected.x && actual.y == expected.y &&
        actual.scale == expected.scale && actual.flags == expected.flags);
    expected.scale = 201;
    CHECK(pet_config_save(key, &expected) == PET_CONFIG_INVALID);
    CHECK(pet_config_load(key, &actual) == PET_CONFIG_OK && actual.scale == 175);
    expected.scale = 100;
    expected.flags = 0x8000;
    CHECK(pet_config_save(key, &expected) == PET_CONFIG_INVALID);
    expected.flags = 0;
    DWORD unknown[] = {0x54455050u, 99, 0, 0, 100, 0};
    CHECK(RegSetValueExW(key, PET_CONFIG_VALUE, 0, REG_BINARY,
        (const BYTE *)unknown, sizeof(unknown)) == ERROR_SUCCESS);
    CHECK(pet_config_load(key, &actual) == PET_CONFIG_INVALID && actual.scale == 175);
    CHECK(pet_config_save(key, &expected) == PET_CONFIG_INVALID);
    DWORD bytes = sizeof(unknown), verify[6] = {0}, type = 0;
    CHECK(RegQueryValueExW(key, PET_CONFIG_VALUE, NULL, &type, (BYTE *)verify, &bytes) == ERROR_SUCCESS);
    CHECK(verify[1] == 99);
    CHECK(RegSetValueExW(key, PET_CONFIG_VALUE, 0, REG_DWORD,
        (const BYTE *)unknown, sizeof(DWORD)) == ERROR_SUCCESS);
    CHECK(pet_config_load(key, &actual) == PET_CONFIG_INVALID);
    /* Isolated volatile registry key; never touch real user settings. */
    pet_package_meta meta = {0};
    strcpy(meta.pet_id, "cat");
    meta.count = 2; meta.outfit_count = 2; meta.rule_count = 1;
    strcpy(meta.outfit_ids[0], "night"); strcpy(meta.outfit_ids[1], "winter");
    strcpy(meta.activity_ids[0], "nap"); strcpy(meta.activity_ids[1], "wave");
    pet_preferences prefs = {0}, restored = {0};
    CHECK(pet_preferences_load(key, "cat", &restored) == PET_CONFIG_MISSING);
    CHECK(pet_preferences_capture(&meta, 1, 0, 2, &prefs));
    CHECK(strcmp(prefs.outfit, "night") == 0 && strcmp(prefs.enabled[0], "wave") == 0);
    CHECK(pet_preferences_save(key, &prefs) == PET_CONFIG_OK);
    CHECK(pet_preferences_load(key, "cat", &restored) == PET_CONFIG_OK);
    CHECK(memcmp(&prefs, &restored, sizeof(prefs)) == 0);
    /* Reordered catalogs retain identity, not former numeric positions. */
    strcpy(meta.outfit_ids[0], "winter"); strcpy(meta.outfit_ids[1], "night");
    strcpy(meta.activity_ids[0], "wave"); strcpy(meta.activity_ids[1], "nap");
    unsigned outfit = 99; int automatic = 99; uint32_t enabled = 99;
    CHECK(pet_preferences_apply(&meta, &restored, &outfit, &automatic, &enabled));
    CHECK(outfit == 2 && !automatic && enabled == 1);
    strcpy(meta.outfit_ids[1], "summer"); strcpy(meta.activity_ids[0], "jump");
    CHECK(pet_preferences_apply(&meta, &restored, &outfit, &automatic, &enabled));
    CHECK(outfit == 0 && automatic && enabled == 0);
    /* A temporarily absent outfit must survive unrelated activity edits;
     * conversely preserve an absent activity when only changing outfits. */
    pet_preferences edited = {0};
    CHECK(pet_preferences_update(&meta, 0, 1, 1, &restored, PET_PREF_ACTIVITIES_CHANGED, &edited));
    CHECK(strcmp(edited.outfit, "night") == 0 && strcmp(edited.enabled[0], "jump") == 0);
    CHECK(pet_preferences_update(&meta, 0, 0, 0, &restored, PET_PREF_OUTFIT_CHANGED, &edited));
    CHECK(strcmp(edited.outfit, "default") == 0 && strcmp(edited.enabled[0], "wave") == 0);
    CHECK(!pet_preferences_update(&meta, 0, 0, 0, &restored, 0, &edited));
    CHECK(!pet_preferences_update(&meta, 0, 0, 0, &restored, 4, &edited));
    CHECK(strcmp(edited.outfit, "default") == 0);
    CHECK(pet_preferences_update(&meta, 0, 1, 2, NULL, PET_PREF_ACTIVITIES_CHANGED, &edited));
    CHECK(strcmp(edited.outfit, "auto") == 0 && strcmp(edited.enabled[0], "nap") == 0);
    strcpy(meta.pet_id, "dog");
    CHECK(!pet_preferences_update(&meta, 0, 0, 0, &restored, PET_PREF_OUTFIT_CHANGED, &edited));
    CHECK(!pet_preferences_apply(&meta, &restored, &outfit, &automatic, &enabled));
    CHECK(pet_preferences_capture(&meta, 0, 0, 0, &prefs));
    CHECK(pet_preferences_save(key, &prefs) == PET_CONFIG_OK);
    CHECK(pet_preferences_load(key, "cat", &restored) == PET_CONFIG_OK);
    CHECK(strcmp(restored.outfit, "night") == 0);
    CHECK(pet_preferences_load(key, "dog", &restored) == PET_CONFIG_OK);
    CHECK(strcmp(restored.outfit, "default") == 0);
    /* Fixed-size strings must have canonical zero tails. */
    prefs.outfit[20] = 'x';
    CHECK(pet_preferences_save(key, &prefs) == PET_CONFIG_INVALID);
    prefs.outfit[20] = 0;
    for (unsigned i = 0; i < 14; ++i) {
        memset(prefs.pet, 0, sizeof(prefs.pet));
        CHECK(snprintf(prefs.pet, sizeof(prefs.pet), "pet%u", i) > 0);
        CHECK(pet_preferences_save(key, &prefs) == PET_CONFIG_OK);
    }
    memset(prefs.pet, 0, sizeof(prefs.pet));
    strcpy(prefs.pet, "overflow");
    CHECK(pet_preferences_save(key, &prefs) == PET_CONFIG_INVALID);
    CHECK(pet_preferences_load(key, "cat", &restored) == PET_CONFIG_OK);
    /* Unknown version or corrupt value must survive attempted save. */
    const BYTE bad[] = {'P','P','P','F',99,0,0,0};
    CHECK(RegSetValueExW(key, PET_PREFERENCES_VALUE, 0, REG_BINARY, bad, sizeof(bad)) == ERROR_SUCCESS);
    CHECK(pet_preferences_load(key, "cat", &restored) == PET_CONFIG_INVALID);
    CHECK(strcmp(restored.pet, "cat") == 0);
    CHECK(pet_preferences_save(key, &prefs) == PET_CONFIG_INVALID);
    BYTE unchanged[sizeof(bad)] = {0};
    bytes = sizeof(unchanged);
    CHECK(RegQueryValueExW(key, PET_PREFERENCES_VALUE, NULL, &type, unchanged, &bytes) == ERROR_SUCCESS);
    CHECK(bytes == sizeof(bad) && memcmp(unchanged, bad, sizeof(bad)) == 0);
    CHECK(pet_config_load(key, &actual) == PET_CONFIG_INVALID); /* legacy value untouched */
    /* Gaze is independent of the two intentionally corrupt prior values. */
    int gaze = 1;
    CHECK(pet_gaze_config_load(key, &gaze) == PET_CONFIG_MISSING && gaze == 1);
    CHECK(pet_gaze_config_save(key, 0) == PET_CONFIG_OK);
    CHECK(pet_gaze_config_load(key, &gaze) == PET_CONFIG_OK && gaze == 0);
    CHECK(pet_gaze_config_save(key, 1) == PET_CONFIG_OK);
    CHECK(pet_gaze_config_load(key, &gaze) == PET_CONFIG_OK && gaze == 1);
    CHECK(pet_gaze_config_save(key, 2) == PET_CONFIG_INVALID);
    DWORD bad_gaze[] = {0x455a4750u, 2, 0};
    CHECK(RegSetValueExW(key, PET_GAZE_VALUE, 0, REG_BINARY,
        (const BYTE *)bad_gaze, sizeof(bad_gaze)) == ERROR_SUCCESS);
    CHECK(pet_gaze_config_load(key, &gaze) == PET_CONFIG_INVALID && gaze == 1);
    CHECK(pet_gaze_config_save(key, 0) == PET_CONFIG_INVALID);
    DWORD check_gaze[3] = {0};
    bytes = sizeof(check_gaze);
    CHECK(RegQueryValueExW(key, PET_GAZE_VALUE, NULL, &type,
        (BYTE *)check_gaze, &bytes) == ERROR_SUCCESS);
    CHECK(bytes == sizeof(bad_gaze) && !memcmp(check_gaze, bad_gaze, bytes));
    CHECK(pet_config_load(key, &actual) == PET_CONFIG_INVALID);
    CHECK(pet_preferences_load(key, "cat", &restored) == PET_CONFIG_INVALID);
    rc = 0;
cleanup:
    if (key) RegCloseKey(key);
    if (disposition == REG_CREATED_NEW_KEY) RegDeleteKeyW(HKEY_CURRENT_USER, path);
    return rc;
}
