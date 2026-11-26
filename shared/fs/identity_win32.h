#ifndef PULSE_FILE_IDENTITY_WIN32_H
#define PULSE_FILE_IDENTITY_WIN32_H
#include <windows.h>
#include <wchar.h>

#define PULSE_FILE_PATH_CAP 1024u

/* Inspect an already opened handle with FILE_FLAG_OPEN_REPARSE_POINT.
 * Require the normalized local DOS path, expected object kind, and a
 * single-link regular file. Case policy is explicit. No ancestor or
 * ACL audit is implied; hold handles and validate parent policy separately.
 * The caller retains ownership. Raw Win32 errors remain available. */
static inline BOOL pulse_file_observe(HANDLE file, const wchar_t *expected,
    BOOL directory, BOOL ignore_case, BY_HANDLE_FILE_INFORMATION *out) {
    if (!file || file == INVALID_HANDLE_VALUE || !expected || !out) {
        SetLastError(ERROR_INVALID_PARAMETER);
        return FALSE;
    }
    size_t n = 0;
    while (n < PULSE_FILE_PATH_CAP && expected[n]) ++n;
    if (n < 3 || n == PULSE_FILE_PATH_CAP || expected[1] != L':' || expected[2] != L'\\') {
        SetLastError(ERROR_BAD_PATHNAME);
        return FALSE;
    }
    BY_HANDLE_FILE_INFORMATION info;
    if (GetFileType(file) != FILE_TYPE_DISK) {
        SetLastError(ERROR_INVALID_DATA);
        return FALSE;
    }
    if (!GetFileInformationByHandle(file, &info)) return FALSE;
    wchar_t actual[PULSE_FILE_PATH_CAP + 4];
    DWORD len = GetFinalPathNameByHandleW(file, actual, PULSE_FILE_PATH_CAP + 4,
        FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (!len) return FALSE;
    if ((info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
        !!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != !!directory ||
        (!directory && info.nNumberOfLinks != 1) ||
        len != n + 4 || len >= PULSE_FILE_PATH_CAP + 4 ||
        wcsncmp(actual, L"\\\\?\\", 4) ||
        CompareStringOrdinal(actual + 4, -1, expected, -1, ignore_case) != CSTR_EQUAL) {
        SetLastError(ERROR_BAD_PATHNAME);
        return FALSE;
    }
    *out = info;
    return TRUE;
}
#endif
