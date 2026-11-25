#include "pet_catalog_store_win32.h"
#include <wchar.h>

#define PATH_CAP 1024u

/* Pin the private root without delete sharing, reject aliases/reparse roots.
 * This is not protection against hostile writers within an approved root;
 * its ACL and exclusive worker ownership are required by contract. */
static HANDLE root_open(const wchar_t *root) {
    if (!root) return INVALID_HANDLE_VALUE;
    size_t n = 0;
    while (n < PATH_CAP && root[n]) ++n;
    if (n < 4 || n >= PATH_CAP - 64 || root[1] != L':' ||
        root[2] != L'\\' || root[n - 1] == L'\\') return INVALID_HANDLE_VALUE;
    wchar_t drive[] = {root[0], L':', L'\\', 0};
    if (GetDriveTypeW(drive) != DRIVE_FIXED) return INVALID_HANDLE_VALUE;
    HANDLE h = CreateFileW(root, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (h == INVALID_HANDLE_VALUE) return h;
    BY_HANDLE_FILE_INFORMATION info;
    wchar_t actual[PATH_CAP + 4];
    DWORD len = GetFinalPathNameByHandleW(h, actual, PATH_CAP + 4, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (!GetFileInformationByHandle(h, &info) || !(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) || len != n + 4 ||
        wcsncmp(actual, L"\\\\?\\", 4) || CompareStringOrdinal(actual + 4, -1, root, -1, TRUE) != CSTR_EQUAL) {
        CloseHandle(h);
        return INVALID_HANDLE_VALUE;
    }
    return h;
}

typedef enum { RECORD_NORMAL, RECORD_CACHE, RECORD_RECEIPT } record_kind;

static size_t record_limit(uint64_t id, record_kind kind) {
    if (kind == RECORD_RECEIPT) return id ? PET_REMOVAL_RECEIPT_BYTES : 0;
    if (kind == RECORD_CACHE) return id < PET_MARKET_CACHE_SLOTS ? PET_MARKET_CACHE_MAX : 0;
    return id ? PET_CATALOG_RECORD_MAX : PET_INVENTORY_MAX;
}

static BOOL names(const wchar_t *root, uint64_t id, record_kind kind, wchar_t *final, wchar_t *temp) {
    if (kind == RECORD_RECEIPT) {
        if (!id) return FALSE;
        int a = swprintf(final, PATH_CAP, L"%ls\\pet-%016llx.prc", root, (unsigned long long)id);
        int b = swprintf(temp, PATH_CAP, L"%ls\\pet-%016llx.prc.pending", root, (unsigned long long)id);
        return a > 0 && a < (int)PATH_CAP && b > 0 && b < (int)PATH_CAP;
    }
    if (kind == RECORD_CACHE) {
        if (id >= PET_MARKET_CACHE_SLOTS) return FALSE;
        int a = swprintf(final, PATH_CAP, L"%ls\\market-%02u.cache", root, (unsigned)id);
        int b = swprintf(temp, PATH_CAP, L"%ls\\market.pending", root);
        return a > 0 && a < (int)PATH_CAP && b > 0 && b < (int)PATH_CAP;
    }
    if (!id) {
        int a = swprintf(final, PATH_CAP, L"%ls\\inventory.pci", root);
        int b = swprintf(temp, PATH_CAP, L"%ls\\inventory.pending", root);
        return a > 0 && a < (int)PATH_CAP && b > 0 && b < (int)PATH_CAP;
    }
    int a = swprintf(final, PATH_CAP, L"%ls\\pet-%016llx.pct", root, (unsigned long long)id);
    int b = swprintf(temp, PATH_CAP, L"%ls\\pet-%016llx.pending", root, (unsigned long long)id);
    return a > 0 && a < (int)PATH_CAP && b > 0 && b < (int)PATH_CAP;
}

static BOOL normal_file(HANDLE h, BY_HANDLE_FILE_INFORMATION *info) {
    return GetFileType(h) == FILE_TYPE_DISK && GetFileInformationByHandle(h, info) &&
        !(info->dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) &&
        info->nNumberOfLinks == 1;
}

static pet_store_result read_record(const wchar_t *root, uint64_t id, record_kind kind,
    uint8_t *out, size_t capacity, size_t *written) {
    if (!written) return PET_STORE_INVALID;
    *written = 0;
    if (!out || !capacity || capacity > record_limit(id, kind)) return PET_STORE_INVALID;
    HANDLE dir = root_open(root);
    if (dir == INVALID_HANDLE_VALUE) return PET_STORE_INVALID;
    wchar_t final[PATH_CAP], temp[PATH_CAP];
    pet_store_result result = PET_STORE_INVALID;
    if (!names(root, id, kind, final, temp)) goto done;
    HANDLE file = CreateFileW(final, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        result = GetLastError() == ERROR_FILE_NOT_FOUND ? PET_STORE_MISSING : PET_STORE_IO;
        goto done;
    }
    BY_HANDLE_FILE_INFORMATION info;
    DWORD got = 0;
    if (normal_file(file, &info) && !info.nFileSizeHigh && info.nFileSizeLow &&
        info.nFileSizeLow <= capacity) {
        result = PET_STORE_IO;
        if (ReadFile(file, out, info.nFileSizeLow, &got, NULL) && got == info.nFileSizeLow) {
            *written = got;
            result = PET_STORE_OK;
        }
    }
    if (!CloseHandle(file)) result = PET_STORE_CLEANUP_FAILED;
done:
    if (!CloseHandle(dir)) result = PET_STORE_CLEANUP_FAILED;
    if (result != PET_STORE_OK) *written = 0;
    return result;
}

static pet_store_result write_record(const wchar_t *root, uint64_t id, record_kind kind,
    const uint8_t *data, size_t length) {
    if (!data || !length || length > record_limit(id, kind) ||
        (kind == RECORD_RECEIPT && length != PET_REMOVAL_RECEIPT_BYTES)) return PET_STORE_INVALID;
    HANDLE dir = root_open(root);
    if (dir == INVALID_HANDLE_VALUE) return PET_STORE_INVALID;
    wchar_t final[PATH_CAP], temp[PATH_CAP];
    pet_store_result result = PET_STORE_INVALID;
    if (!names(root, id, kind, final, temp)) goto done;
    HANDLE prior = CreateFileW(final, FILE_READ_ATTRIBUTES, FILE_SHARE_READ, NULL, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (prior != INVALID_HANDLE_VALUE) {
        BY_HANDLE_FILE_INFORMATION info;
        BOOL safe = normal_file(prior, &info);
        if (!CloseHandle(prior)) { result = PET_STORE_CLEANUP_FAILED; goto done; }
        if (!safe) goto done;
        if (kind == RECORD_RECEIPT) { result = PET_STORE_BUSY; goto done; }
    } else if (GetLastError() != ERROR_FILE_NOT_FOUND) {
        result = PET_STORE_IO; goto done;
    }
    /* Exclusive create: never delete an unknown/stale pending file. */
    HANDLE file = CreateFileW(temp, GENERIC_WRITE, 0, NULL, CREATE_NEW,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        result = GetLastError() == ERROR_FILE_EXISTS ? PET_STORE_BUSY : PET_STORE_IO;
        goto done;
    }
    DWORD written = 0;
    BOOL complete = WriteFile(file, data, (DWORD)length, &written, NULL) &&
        written == length && FlushFileBuffers(file);
    if (!CloseHandle(file)) {
        result = PET_STORE_CLEANUP_FAILED;
        goto done; /* retain pending file; never publish ambiguous write */
    }
    DWORD flags = MOVEFILE_WRITE_THROUGH;
    if (kind != RECORD_RECEIPT) flags |= MOVEFILE_REPLACE_EXISTING;
    if (complete && MoveFileExW(temp, final, flags)) {
        result = PET_STORE_OK;
    } else {
        result = DeleteFileW(temp) ? PET_STORE_IO : PET_STORE_CLEANUP_FAILED;
    }
done:
    if (!CloseHandle(dir)) result = PET_STORE_CLEANUP_FAILED;
    return result;
}

pet_store_result pet_store_read(const wchar_t *root, uint64_t id,
    uint8_t *out, size_t capacity, size_t *written) {
    if (!id) return PET_STORE_INVALID;
    return read_record(root, id, RECORD_NORMAL, out, capacity, written);
}

pet_store_result pet_store_write(const wchar_t *root, uint64_t id,
    const uint8_t *data, size_t length) {
    if (!id) return PET_STORE_INVALID;
    return write_record(root, id, RECORD_NORMAL, data, length);
}

pet_store_result pet_inventory_read(const wchar_t *root, uint8_t *out,
    size_t capacity, size_t *written) {
    return read_record(root, 0, RECORD_NORMAL, out, capacity, written);
}

pet_store_result pet_inventory_write(const wchar_t *root, const uint8_t *data, size_t length) {
    return write_record(root, 0, RECORD_NORMAL, data, length);
}

/* Fixed disposable cache slots; caller reserves this namespace in a separate
 * approved private directory. One shared exclusive pending file bounds
 * leftover interrupted writes and blocks new writes until recovery. */
pet_store_result pet_market_cache_read(const wchar_t *root, uint32_t slot,
    uint8_t *out, size_t capacity, size_t *written) {
    return read_record(root, slot, RECORD_CACHE, out, capacity, written);
}

pet_store_result pet_market_cache_write(const wchar_t *root, uint32_t slot,
    const uint8_t *data, size_t length) {
    return write_record(root, slot, RECORD_CACHE, data, length);
}

pet_store_result pet_removal_receipt_read(const wchar_t *root, uint64_t id,
    uint8_t *out, size_t capacity, size_t *written) {
    return read_record(root, id, RECORD_RECEIPT, out, capacity, written);
}

pet_store_result pet_removal_receipt_write(const wchar_t *root, uint64_t id,
    const uint8_t *data, size_t length) {
    return write_record(root, id, RECORD_RECEIPT, data, length);
}
