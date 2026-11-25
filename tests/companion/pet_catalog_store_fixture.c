#include "../../shared/companion/pet_catalog_store_win32.h"
#include <wchar.h>

/* Test-only isolated runner temp directory. Production roots need ACL
 * validation by the owning extension. No recursive cleanup. */
int pet_catalog_store_fixture_open(wchar_t *out, uint32_t cap) {
    wchar_t temp[MAX_PATH], path[MAX_PATH];
    DWORD n = GetTempPathW(MAX_PATH, temp);
    if (!n || n >= MAX_PATH || !GetTempFileNameW(temp, L"pct", 0, path)) return 0;
    if (!DeleteFileW(path) || !CreateDirectoryW(path, NULL)) return 0;
    HANDLE dir = CreateFileW(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (dir == INVALID_HANDLE_VALUE) { RemoveDirectoryW(path); return 0; }
    wchar_t actual[1028];
    DWORD len = GetFinalPathNameByHandleW(dir, actual, 1028, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    CloseHandle(dir);
    if (len < 5 || len >= 1028 || len - 4 >= cap || wcsncmp(actual, L"\\\\?\\", 4)) {
        RemoveDirectoryW(path); return 0;
    }
    wmemcpy(out, actual + 4, len - 3);
    return 1;
}

int pet_catalog_store_fixture_close(const wchar_t *root) {
    wchar_t file[1024];
    int n = swprintf(file, 1024, L"%ls\\pet-0000000000000001.pct", root);
    if (n <= 0 || n >= 1024) return 0;
    if (!DeleteFileW(file) && GetLastError() != ERROR_FILE_NOT_FOUND) return 0;
    n = swprintf(file, 1024, L"%ls\\inventory.pci", root);
    if (n <= 0 || n >= 1024) return 0;
    if (!DeleteFileW(file) && GetLastError() != ERROR_FILE_NOT_FOUND) return 0;
    return RemoveDirectoryW(root);
}

/* Test-only paths; no user-supplied directories or arbitrary cleanup. */
uint32_t pet_import_fixture_path(unsigned kind, uint8_t *out, uint32_t capacity) {
    wchar_t path[1024];
    DWORD len;
    switch (kind) {
        case 0: len = GetFullPathNameW(L"zig-out\\bin\\pulse-pet-demo.exe", 1024, path, NULL); break;
        case 1: len = GetFullPathNameW(L"zig-out\\import-fixtures\\fixture-v1", 1024, path, NULL); break;
        case 2: len = GetWindowsDirectoryW(path, 1024); break;
        case 3: len = GetFullPathNameW(L"zig-out\\import-fixtures\\fixture-v1.zip", 1024, path, NULL); break;
        default: return 0;
    }
    if (!len || len >= 1024 || capacity > 4096) return 0;
    int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path, (int)len,
        (char *)out, (int)capacity, NULL, NULL);
    return bytes > 0 ? (uint32_t)bytes : 0;
}

uint32_t pet_import_fixture_utf8(const wchar_t *root, uint8_t *out, uint32_t capacity) {
    if (!root || capacity > 4096) return 0;
    size_t len = wcslen(root);
    if (!len || len >= 1024) return 0;
    int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, root, (int)len,
        (char *)out, (int)capacity, NULL, NULL);
    return bytes > 0 ? (uint32_t)bytes : 0;
}

/* Remove only the test's known file set from its fresh isolated root. */
int pet_import_fixture_close(const wchar_t *root) {
    const wchar_t *dirs[] = {L"pet-0000000000000001", L"pet-0000000000000001.pending"};
    const wchar_t *files[] = {L"pet.json", L"spritesheet.webp"};
    wchar_t path[1024];
    for (unsigned i = 0; i < 2; ++i) {
        for (unsigned j = 0; j < 2; ++j) {
            int n = swprintf(path, 1024, L"%ls\\%ls\\%ls", root, dirs[i], files[j]);
            if (n <= 0 || n >= 1024) return 0;
            if (!DeleteFileW(path)) {
                DWORD error = GetLastError();
                if (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND) return 0;
            }
        }
        int n = swprintf(path, 1024, L"%ls\\%ls", root, dirs[i]);
        if (n <= 0 || n >= 1024) return 0;
        if (!RemoveDirectoryW(path)) {
            DWORD error = GetLastError();
            if (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND) return 0;
        }
    }
    return pet_catalog_store_fixture_close(root);
}

/* Test-only cleanup of the fixed cache namespace in a fresh test root. */
int pet_market_cache_fixture_close(const wchar_t *root) {
    wchar_t file[1024];
    for (unsigned slot = 0; slot < PET_MARKET_CACHE_SLOTS; ++slot) {
        int n = swprintf(file, 1024, L"%ls\\market-%02u.cache", root, slot);
        if (n <= 0 || n >= 1024) return 0;
        if (!DeleteFileW(file) && GetLastError() != ERROR_FILE_NOT_FOUND) return 0;
    }
    int n = swprintf(file, 1024, L"%ls\\market.pending", root);
    if (n <= 0 || n >= 1024) return 0;
    if (!DeleteFileW(file) && GetLastError() != ERROR_FILE_NOT_FOUND) return 0;
    return RemoveDirectoryW(root);
}

/* Only the isolated private-root preference fixture uses this cleanup.
 * Do not call on a production root; unknown files prevent directory removal. */
int pet_private_preferences_fixture_close(const wchar_t *parent) {
    wchar_t root[1024], lock[1024];
    int n = swprintf(root, 1024, L"%ls\\PulseExtras-Companion", parent);
    if (n <= 0 || n >= 1024) return 0;
    n = swprintf(lock, 1024, L"%ls\\owner.lock", root);
    if (n <= 0 || n >= 1024) return 0;
    if (!DeleteFileW(lock) && GetLastError() != ERROR_FILE_NOT_FOUND && GetLastError() != ERROR_PATH_NOT_FOUND) return 0;
    if (GetFileAttributesW(root) != INVALID_FILE_ATTRIBUTES &&
        !pet_catalog_store_fixture_close(root)) return 0;
    return RemoveDirectoryW(parent);
}
