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
    return RemoveDirectoryW(root);
}
