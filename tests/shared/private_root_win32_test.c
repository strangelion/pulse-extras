#include "../../shared/fs/private_root_win32.h"
#include <stdio.h>
#include <wchar.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s (win32=%lu)\n", __LINE__, #x, (unsigned long)GetLastError()); return 1; } } while (0)

int main(void) {
    wchar_t temp[MAX_PATH], created[MAX_PATH], normalized[PULSE_PRIVATE_PATH_CAP + 4];
    DWORD n = GetTempPathW(MAX_PATH, temp);
    CHECK(n && n < MAX_PATH && GetTempFileNameW(temp, L"ppr", 0, created));
    CHECK(DeleteFileW(created) && CreateDirectoryW(created, NULL));
    HANDLE h = CreateFileW(created, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    CHECK(h != INVALID_HANDLE_VALUE);
    n = GetFinalPathNameByHandleW(h, normalized, PULSE_PRIVATE_PATH_CAP + 4, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    CHECK(CloseHandle(h));
    CHECK(n > 4 && n < PULSE_PRIVATE_PATH_CAP && !wcsncmp(normalized, L"\\\\?\\", 4));
    const wchar_t *parent = normalized + 4;
    wchar_t root[PULSE_PRIVATE_PATH_CAP], lock[PULSE_PRIVATE_PATH_CAP], keep[PULSE_PRIVATE_PATH_CAP];
    CHECK(swprintf(root, PULSE_PRIVATE_PATH_CAP, L"%ls\\PulseExtras-SharedFixture", parent) > 0);
    CHECK(swprintf(lock, PULSE_PRIVATE_PATH_CAP, L"%ls\\owner.lock", root) > 0);
    CHECK(swprintf(keep, PULSE_PRIVATE_PATH_CAP, L"%ls\\keep.txt", root) > 0);
    pulse_private_root first = {0}, second = {0};
    CHECK(pulse_private_root_open(&first, parent, L"PulseExtras-../escape") == PULSE_PRIVATE_INVALID);
    CHECK(!first.parent && !first.root && !first.lock);
    CHECK(pulse_private_root_open(&first, parent, L"PulseExtras-SharedFixture") == PULSE_PRIVATE_OK);
    CHECK(!wcscmp(first.path, root) && first.root && first.lock);
    CHECK(pulse_private_root_open(&second, parent, L"PulseExtras-SharedFixture") == PULSE_PRIVATE_BUSY);
    CHECK(!second.parent && !second.root && !second.lock);
    CHECK(pulse_private_root_close(&first) == PULSE_PRIVATE_OK);
    CHECK(pulse_private_root_open(&second, parent, L"PulseExtras-SharedFixture") == PULSE_PRIVATE_OK);
    CHECK(pulse_private_root_close(&second) == PULSE_PRIVATE_OK);
    CHECK(pulse_private_root_close(&second) == PULSE_PRIVATE_OK);
    CHECK(DeleteFileW(lock) && RemoveDirectoryW(root));

    /* An existing inherited ACL is not silently converted into a private
       root. Its unrelated file must survive, and no lock may be created. */
    CHECK(CreateDirectoryW(root, NULL));
    h = CreateFileW(keep, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    CHECK(h != INVALID_HANDLE_VALUE && CloseHandle(h));
    CHECK(pulse_private_root_open(&first, parent, L"PulseExtras-SharedFixture") == PULSE_PRIVATE_INVALID);
    CHECK(!first.parent && !first.root && !first.lock);
    CHECK(GetFileAttributesW(keep) != INVALID_FILE_ATTRIBUTES);
    CHECK(GetFileAttributesW(lock) == INVALID_FILE_ATTRIBUTES);
    CHECK(DeleteFileW(keep) && RemoveDirectoryW(root) && RemoveDirectoryW(parent));
    puts("Private root ACL, exclusive owner, reopen and unsafe existing directory checks passed");
    return 0;
}
