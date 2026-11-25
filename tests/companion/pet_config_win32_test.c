#include "../../shared/companion/pet_config_win32.h"
#include <stdio.h>
#include <wchar.h>
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
    rc = 0;
cleanup:
    if (key) RegCloseKey(key);
    if (disposition == REG_CREATED_NEW_KEY) RegDeleteKeyW(HKEY_CURRENT_USER, path);
    return rc;
}
