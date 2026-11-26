#include "image_win32.h"
#include <wchar.h>
#include <stdlib.h>
#include <string.h>
#include <bcrypt.h>

#define PATH_CAP 1024u

HANDLE pulse_image_pin(const wchar_t *path) {
    if (!path) return INVALID_HANDLE_VALUE;
    size_t n = 0;
    while (n < PATH_CAP && path[n]) ++n;
    if (n < 8 || n == PATH_CAP || !((path[0] >= L'A' && path[0] <= L'Z') ||
        (path[0] >= L'a' && path[0] <= L'z')) || path[1] != L':' ||
        path[2] != L'\\' || CompareStringOrdinal(path + n - 4, 4, L".exe", 4, TRUE) != CSTR_EQUAL)
        return INVALID_HANDLE_VALUE;
    size_t component = 3;
    for (size_t i = 3; i <= n; ++i) {
        wchar_t c = path[i];
        if (c == L'\\' || !c) {
            if (i == component || path[i - 1] == L'.' || path[i - 1] == L' ')
                return INVALID_HANDLE_VALUE;
            component = i + 1;
        } else if (c < 32 || c == L'"' || c == L'/' || c == L':' ||
            c == L'*' || c == L'?' || c == L'<' || c == L'>' || c == L'|') {
            return INVALID_HANDLE_VALUE;
        }
    }
    wchar_t root[] = {path[0], L':', L'\\', 0};
    if (GetDriveTypeW(root) != DRIVE_FIXED) return INVALID_HANDLE_VALUE;
    HANDLE image = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (image == INVALID_HANDLE_VALUE) return image;
    BY_HANDLE_FILE_INFORMATION info;
    wchar_t actual[PATH_CAP + 4];
    DWORD length = GetFinalPathNameByHandleW(image, actual, PATH_CAP + 4,
        FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (GetFileType(image) != FILE_TYPE_DISK || !GetFileInformationByHandle(image, &info) ||
        info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) ||
        info.nNumberOfLinks != 1 || info.nFileSizeHigh || !info.nFileSizeLow || info.nFileSizeLow > 256u * 1024u * 1024u ||
        length != n + 4 || length >= PATH_CAP + 4 ||
        wcsncmp(actual, L"\\\\?\\", 4) != 0 ||
        CompareStringOrdinal(actual + 4, -1, path, -1, TRUE) != CSTR_EQUAL) {
        CloseHandle(image);
        SetLastError(ERROR_BAD_PATHNAME);
        return INVALID_HANDLE_VALUE;
    }
    return image;
}

/* Use the already pinned handle: no pathname reopen between the hash and
 * process creation. Resolve the OS crypto provider from System32 only,
 * keeping the existing GNU test link commands and MSVC boundary intact. */
pulse_image_result pulse_image_verify(HANDLE image, const uint8_t expected[32]) {
    typedef NTSTATUS (WINAPI *open_fn)(BCRYPT_ALG_HANDLE *, LPCWSTR, LPCWSTR, ULONG);
    typedef NTSTATUS (WINAPI *property_fn)(BCRYPT_HANDLE, LPCWSTR, PUCHAR, ULONG, ULONG *, ULONG);
    typedef NTSTATUS (WINAPI *create_fn)(BCRYPT_ALG_HANDLE, BCRYPT_HASH_HANDLE *, PUCHAR, ULONG, PUCHAR, ULONG, ULONG);
    typedef NTSTATUS (WINAPI *data_fn)(BCRYPT_HASH_HANDLE, PUCHAR, ULONG, ULONG);
    typedef NTSTATUS (WINAPI *finish_fn)(BCRYPT_HASH_HANDLE, PUCHAR, ULONG, ULONG);
    typedef NTSTATUS (WINAPI *destroy_fn)(BCRYPT_HASH_HANDLE);
    typedef NTSTATUS (WINAPI *close_fn)(BCRYPT_ALG_HANDLE, ULONG);
    LARGE_INTEGER zero = {0};
    if (!expected || image == NULL || image == INVALID_HANDLE_VALUE ||
        !SetFilePointerEx(image, zero, NULL, FILE_BEGIN)) return PULSE_IMAGE_OS_ERROR;
    HMODULE module = LoadLibraryExW(L"bcrypt.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module) return PULSE_IMAGE_OS_ERROR;
    open_fn open = (open_fn)GetProcAddress(module, "BCryptOpenAlgorithmProvider");
    property_fn property = (property_fn)GetProcAddress(module, "BCryptGetProperty");
    create_fn create = (create_fn)GetProcAddress(module, "BCryptCreateHash");
    data_fn update = (data_fn)GetProcAddress(module, "BCryptHashData");
    finish_fn finish = (finish_fn)GetProcAddress(module, "BCryptFinishHash");
    destroy_fn destroy = (destroy_fn)GetProcAddress(module, "BCryptDestroyHash");
    close_fn close = (close_fn)GetProcAddress(module, "BCryptCloseAlgorithmProvider");
    pulse_image_result result = PULSE_IMAGE_OS_ERROR;
    BCRYPT_ALG_HANDLE algorithm = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    PUCHAR object = NULL;
    DWORD object_size = 0, digest_size = 0, got = 0;
    unsigned char buffer[16384], digest[32];
    LARGE_INTEGER size;
    if (!open || !property || !create || !update || !finish || !destroy || !close ||
        !GetFileSizeEx(image, &size) || size.QuadPart <= 0 ||
        size.QuadPart > 256ll * 1024 * 1024) goto done;
    if (open(&algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0) < 0 ||
        property(algorithm, BCRYPT_OBJECT_LENGTH, (PUCHAR)&object_size, sizeof(object_size), &got, 0) < 0 ||
        got != sizeof(object_size) || !object_size || object_size > 65536 ||
        property(algorithm, BCRYPT_HASH_LENGTH, (PUCHAR)&digest_size, sizeof(digest_size), &got, 0) < 0 ||
        got != sizeof(digest_size) || digest_size != sizeof(digest)) goto done;
    object = malloc(object_size);
    if (!object || create(algorithm, &hash, object, object_size, NULL, 0, 0) < 0) goto done;
    uint64_t remaining = (uint64_t)size.QuadPart;
    while (remaining) {
        DWORD want = remaining > sizeof(buffer) ? (DWORD)sizeof(buffer) : (DWORD)remaining;
        if (!ReadFile(image, buffer, want, &got, NULL) || got != want ||
            update(hash, buffer, got, 0) < 0) goto done;
        remaining -= got;
    }
    if (finish(hash, digest, sizeof(digest), 0) < 0) goto done;
    result = memcmp(digest, expected, sizeof(digest)) == 0 ?
        PULSE_IMAGE_OK : PULSE_IMAGE_MISMATCH;
done:
    if (hash && destroy(hash) < 0) result = PULSE_IMAGE_OS_ERROR;
    free(object);
    if (algorithm && close(algorithm, 0) < 0) result = PULSE_IMAGE_OS_ERROR;
    if (!FreeLibrary(module)) result = PULSE_IMAGE_OS_ERROR;
    return result;
}
