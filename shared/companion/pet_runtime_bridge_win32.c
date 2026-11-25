/* Versioned C ABI; caller retains its own manager and storage. */
#include "pet_supervisor_win32.h"
#include "pet_private_root_win32.h"
#include "pet_catalog_store_win32.h"
#include <wchar.h>

typedef struct {
    uint32_t version, size;
    SIZE_T (*storage_size)(void);
    pet_child_result (*open)(pet_supervisor_group *, unsigned, SIZE_T);
    pet_child_result (*start)(pet_supervisor_group *, const wchar_t *, const uint8_t *,
        const pet_child_options *, const wchar_t *, const wchar_t *, const wchar_t *, uint64_t *);
    pet_child_result (*request_stop)(pet_supervisor_group *, uint64_t);
    pet_child_result (*force_stop)(pet_supervisor_group *, uint64_t);
    pet_child_result (*reap)(pet_supervisor_group *, uint64_t, DWORD *);
    pet_child_result (*ready)(pet_supervisor_group *, uint64_t, BOOL *);
    pet_child_result (*publish)(pet_supervisor_group *, uint64_t, unsigned);
    pet_child_result (*sample)(pet_supervisor_group *, uint64_t, pet_group_metrics *);
    pet_child_result (*close)(pet_supervisor_group *);
    pet_child_result (*abandon)(pet_supervisor_group *);
} pet_runtime_api_v2;

static const pet_runtime_api_v2 api = {
    2, sizeof(pet_runtime_api_v2), pet_group_storage_size, pet_group_open,
    pet_group_start_approved, pet_group_request_stop, pet_group_force_stop,
    pet_group_reap, pet_group_ready, pet_group_publish, pet_group_sample, pet_group_close, pet_group_abandon
};

/* No pointers returned on an unsupported version or mismatched table size.
 * The caller supplies storage of the declared size; no cross-CRT free. */
__declspec(dllexport) BOOL pulse_companion_runtime_query(uint32_t version,
    uint32_t size, pet_runtime_api_v2 *out) {
    if (!out || version != 2 || size != sizeof(api)) return FALSE;
    *out = api;
    return TRUE;
}

/* Independent versioned lease ABI; all storage belongs to the caller. */
__declspec(dllexport) pet_private_result pulse_companion_private_open_v1(
    pet_private_root *lease, SIZE_T size, const wchar_t *parent) {
    if (!lease || size != sizeof(*lease)) return PET_PRIVATE_INVALID;
    return pet_private_root_open(lease, parent);
}
__declspec(dllexport) pet_private_result pulse_companion_private_close_v1(
    pet_private_root *lease, SIZE_T size) {
    if (!lease || size != sizeof(*lease)) return PET_PRIVATE_INVALID;
    return pet_private_root_close(lease);
}

/* Lease-bound durable store; never expose raw user-supplied paths here.
 * Serialized caller owns the lease. This is a trusted same-process ABI,
 * not a security boundary against arbitrary native code in the host. */
static BOOL live_lease(const pet_private_root *lease, SIZE_T size) {
    return lease && size == sizeof(*lease) && lease->parent &&
        lease->root && lease->lock && lease->path[0];
}
__declspec(dllexport) pet_store_result pulse_companion_store_read_v1(
    const pet_private_root *lease, SIZE_T size, uint64_t id,
    uint8_t *out, SIZE_T capacity, SIZE_T *written) {
    if (!live_lease(lease, size)) return PET_STORE_INVALID;
    return id ? pet_store_read(lease->path, id, out, capacity, written) :
        pet_inventory_read(lease->path, out, capacity, written);
}
__declspec(dllexport) pet_store_result pulse_companion_store_write_v1(
    const pet_private_root *lease, SIZE_T size, uint64_t id,
    const uint8_t *data, SIZE_T length) {
    if (!live_lease(lease, size)) return PET_STORE_INVALID;
    return id ? pet_store_write(lease->path, id, data, length) :
        pet_inventory_write(lease->path, data, length);
}


/* Read-only top-level scan. Names are reduced to fixed namespace kinds and
 * IDs; never return paths, traverse reparse points or adopt unknown entries.
 * Exact lower-case names only, independently of volume case sensitivity. */
typedef struct {
    uint64_t id;
    uint32_t kind, attributes;
} pet_scan_row;
enum { SCAN_UNKNOWN, SCAN_PACKAGE, SCAN_PENDING, SCAN_PREFERENCE,
    SCAN_INVENTORY, SCAN_INVENTORY_PENDING, SCAN_LOCK, SCAN_QUARANTINE,
    SCAN_RECEIPT, SCAN_RECEIPT_PENDING };
#define PET_SCAN_MAX 4096u

static pet_scan_row scan_row(const WIN32_FIND_DATAW *data) {
    const wchar_t *name = data->cFileName;
    pet_scan_row row = {0, SCAN_UNKNOWN, data->dwFileAttributes};
    if (!wcscmp(name, L"inventory.pci")) row.kind = SCAN_INVENTORY;
    else if (!wcscmp(name, L"inventory.pending")) row.kind = SCAN_INVENTORY_PENDING;
    else if (!wcscmp(name, L"owner.lock")) row.kind = SCAN_LOCK;
    else if (wcslen(name) >= 20 && !wcsncmp(name, L"pet-", 4)) {
        uint64_t id = 0;
        for (size_t i = 4; i < 20; ++i) {
            wchar_t ch = name[i];
            unsigned digit;
            if (ch >= L'0' && ch <= L'9') digit = (unsigned)(ch - L'0');
            else if (ch >= L'a' && ch <= L'f') digit = (unsigned)(ch - L'a' + 10);
            else return row;
            id = (id << 4) | digit;
        }
        if (!id) return row;
        if (!name[20]) row.kind = SCAN_PACKAGE;
        else if (!wcscmp(name + 20, L".pending")) row.kind = SCAN_PENDING;
        else if (!wcscmp(name + 20, L".pct")) row.kind = SCAN_PREFERENCE;
        else if (!wcscmp(name + 20, L".removed")) row.kind = SCAN_QUARANTINE;
        else if (!wcscmp(name + 20, L".prc")) row.kind = SCAN_RECEIPT;
        else if (!wcscmp(name + 20, L".prc.pending")) row.kind = SCAN_RECEIPT_PENDING;
        if (row.kind != SCAN_UNKNOWN) row.id = id;
    }
    return row;
}

__declspec(dllexport) pet_store_result pulse_companion_scan_v1(
    const pet_private_root *lease, SIZE_T size, pet_scan_row *out,
    SIZE_T capacity, SIZE_T *written) {
    if (!written) return PET_STORE_INVALID;
    *written = 0;
    if (!live_lease(lease, size) || !out || !capacity || capacity > PET_SCAN_MAX)
        return PET_STORE_INVALID;
    wchar_t pattern[PET_PRIVATE_PATH_CAP];
    int n = swprintf(pattern, PET_PRIVATE_PATH_CAP, L"%ls\\*", lease->path);
    if (n <= 0 || n >= (int)PET_PRIVATE_PATH_CAP) return PET_STORE_INVALID;
    WIN32_FIND_DATAW data;
    HANDLE find = FindFirstFileW(pattern, &data);
    if (find == INVALID_HANDLE_VALUE) return PET_STORE_IO;
    SIZE_T count = 0;
    pet_store_result result = PET_STORE_OK;
    do {
        if (!wcscmp(data.cFileName, L".") || !wcscmp(data.cFileName, L"..")) continue;
        if (count == capacity) { result = PET_STORE_BUSY; break; }
        out[count++] = scan_row(&data);
    } while (FindNextFileW(find, &data));
    if (result == PET_STORE_OK && GetLastError() != ERROR_NO_MORE_FILES)
        result = PET_STORE_IO;
    if (!FindClose(find)) result = PET_STORE_CLEANUP_FAILED;
    if (result == PET_STORE_OK) *written = count;
    return result;
}

/* Reversible, no-replace rename of a single fixed managed directory.
 * The lease pins the canonical root. This does not walk or delete content.
 * The caller must revalidate inventory and confirm no live child owns it.
 * A same-user process can still mutate this private namespace. */
static pet_store_result move_quarantine(
    const pet_private_root *lease, SIZE_T size, uint64_t id, BOOL restore,
    uint32_t *volume, uint64_t *file_index) {
    if (!volume || !file_index) return PET_STORE_INVALID;
    *volume = 0;
    *file_index = 0;
    if (!live_lease(lease, size) || !id || (restore != FALSE && restore != TRUE))
        return PET_STORE_INVALID;
    wchar_t normal[PET_PRIVATE_PATH_CAP], removed[PET_PRIVATE_PATH_CAP];
    int a = swprintf(normal, PET_PRIVATE_PATH_CAP, L"%ls\\pet-%016llx",
        lease->path, (unsigned long long)id);
    int b = swprintf(removed, PET_PRIVATE_PATH_CAP, L"%ls\\pet-%016llx.removed",
        lease->path, (unsigned long long)id);
    if (a <= 0 || b <= 0 || a >= (int)PET_PRIVATE_PATH_CAP ||
        b >= (int)PET_PRIVATE_PATH_CAP) return PET_STORE_INVALID;
    const wchar_t *source = restore ? removed : normal;
    const wchar_t *destination = restore ? normal : removed;
    HANDLE file = CreateFileW(source, DELETE | FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (file == INVALID_HANDLE_VALUE) return PET_STORE_IO;
    pet_store_result result = PET_STORE_INVALID;
    BY_HANDLE_FILE_INFORMATION info;
    wchar_t actual[PET_PRIVATE_PATH_CAP + 4];
    DWORD n = GetFinalPathNameByHandleW(file, actual, PET_PRIVATE_PATH_CAP + 4,
        FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (GetFileInformationByHandle(file, &info) &&
        (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
        !(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
        n == wcslen(source) + 4 && n < PET_PRIVATE_PATH_CAP + 4 &&
        !wcsncmp(actual, L"\\\\?\\", 4) &&
        CompareStringOrdinal(actual + 4, -1, source, -1, TRUE) == CSTR_EQUAL) {
        union {
            FILE_RENAME_INFO info;
            unsigned char bytes[sizeof(FILE_RENAME_INFO) + PET_PRIVATE_PATH_CAP * sizeof(wchar_t)];
        } rename;
        ZeroMemory(&rename, sizeof(rename));
        rename.info.ReplaceIfExists = FALSE;
        rename.info.RootDirectory = NULL;
        rename.info.FileNameLength = (DWORD)(wcslen(destination) * sizeof(wchar_t));
        wmemcpy(rename.info.FileName, destination, wcslen(destination) + 1);
        result = SetFileInformationByHandle(file, FileRenameInfo, &rename.info,
            (DWORD)(offsetof(FILE_RENAME_INFO, FileName) + rename.info.FileNameLength + sizeof(wchar_t)))
            ? PET_STORE_OK : PET_STORE_IO;
    }
    if (!CloseHandle(file)) result = PET_STORE_CLEANUP_FAILED;
    if (result == PET_STORE_OK) {
        *volume = info.dwVolumeSerialNumber;
        *file_index = ((uint64_t)info.nFileIndexHigh << 32) | info.nFileIndexLow;
    }
    return result;
}

__declspec(dllexport) pet_store_result pulse_companion_quarantine_v1(
    const pet_private_root *lease, SIZE_T size, uint64_t id, BOOL restore) {
    uint32_t volume;
    uint64_t file_index;
    return move_quarantine(lease, size, id, restore, &volume, &file_index);
}

/* V2 returns identity from the exact rename handle, not a path lookup. */
__declspec(dllexport) pet_store_result pulse_companion_quarantine_v2(
    const pet_private_root *lease, SIZE_T size, uint64_t id, BOOL restore,
    uint32_t *volume, uint64_t *file_index) {
    return move_quarantine(lease, size, id, restore, volume, file_index);
}

/* Logical bytes, not NTFS allocated bytes. Only the known Classic package
 * directory shape is traversed. No content reads, writes or link following.
 * All counters are private until the entire bounded directory is measured. */
#define USAGE_MAX_FILES 290u
#define USAGE_MAX_FILE_BYTES (16ull * 1024ull * 1024ull)
#define USAGE_MAX_BYTES (320ull * 1024ull * 1024ull)
typedef struct { uint64_t bytes; unsigned files, entries; } usage_count;

static pet_store_result usage_open(const wchar_t *path, BOOL directory,
    HANDLE *out, BY_HANDLE_FILE_INFORMATION *info) {
    *out = INVALID_HANDLE_VALUE;
    HANDLE file = CreateFileW(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ,
        NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT |
        (directory ? FILE_FLAG_BACKUP_SEMANTICS : 0), NULL);
    if (file == INVALID_HANDLE_VALUE) return PET_STORE_IO;
    wchar_t actual[PET_PRIVATE_PATH_CAP + 4];
    DWORD n = GetFinalPathNameByHandleW(file, actual, PET_PRIVATE_PATH_CAP + 4,
        FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (GetFileType(file) != FILE_TYPE_DISK ||
        !GetFileInformationByHandle(file, info) ||
        !!(info->dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != !!directory ||
        (info->dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
        (!directory && info->nNumberOfLinks != 1) ||
        n != wcslen(path) + 4 || n >= PET_PRIVATE_PATH_CAP + 4 ||
        wcsncmp(actual, L"\\\\?\\", 4) ||
        CompareStringOrdinal(actual + 4, -1, path, -1, TRUE) != CSTR_EQUAL) {
        return CloseHandle(file) ? PET_STORE_INVALID : PET_STORE_CLEANUP_FAILED;
    }
    *out = file;
    return PET_STORE_OK;
}

static pet_store_result usage_directory(const wchar_t *path, unsigned depth,
    usage_count *count) {
    HANDLE pinned;
    BY_HANDLE_FILE_INFORMATION info;
    pet_store_result result = usage_open(path, TRUE, &pinned, &info);
    if (result != PET_STORE_OK) return result;
    wchar_t pattern[PET_PRIVATE_PATH_CAP], child[PET_PRIVATE_PATH_CAP];
    int n = swprintf(pattern, PET_PRIVATE_PATH_CAP, L"%ls\\*", path);
    HANDLE find = INVALID_HANDLE_VALUE;
    WIN32_FIND_DATAW data;
    BOOL metadata = FALSE, atlas = FALSE;
    if (n <= 0 || n >= (int)PET_PRIVATE_PATH_CAP) result = PET_STORE_INVALID;
    else {
        find = FindFirstFileW(pattern, &data);
        if (find == INVALID_HANDLE_VALUE && GetLastError() != ERROR_FILE_NOT_FOUND)
            result = PET_STORE_IO;
    }
    if (find != INVALID_HANDLE_VALUE) {
        do {
            const wchar_t *name = data.cFileName;
            if (!wcscmp(name, L".") || !wcscmp(name, L"..")) continue;
            if (++count->entries > USAGE_MAX_FILES + 2u ||
                (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
                wcspbrk(name, L"\\/:")) { result = PET_STORE_INVALID; break; }
            n = swprintf(child, PET_PRIVATE_PATH_CAP, L"%ls\\%ls", path, name);
            if (n <= 0 || n >= (int)PET_PRIVATE_PATH_CAP) { result = PET_STORE_INVALID; break; }
            if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                if (depth || (wcscmp(name, L"outfits") && wcscmp(name, L"activities"))) {
                    result = PET_STORE_INVALID; break;
                }
                result = usage_directory(child, depth + 1u, count);
            } else {
                /* The package helper hashes the declared root files but does
                 * not enumerate other root files. A matching fingerprint
                 * must never make an unrelated root file eligible for cleanup. */
                if (!depth) {
                    if (!wcscmp(name, L"pet.json") && !metadata) metadata = TRUE;
                    else if (!wcscmp(name, L"spritesheet.webp") && !atlas) atlas = TRUE;
                    else { result = PET_STORE_INVALID; break; }
                }
                HANDLE file;
                result = usage_open(child, FALSE, &file, &info);
                if (result == PET_STORE_OK) {
                    uint64_t bytes = ((uint64_t)info.nFileSizeHigh << 32) | info.nFileSizeLow;
                    if (++count->files > USAGE_MAX_FILES || bytes > USAGE_MAX_FILE_BYTES ||
                        bytes > USAGE_MAX_BYTES - count->bytes) result = PET_STORE_INVALID;
                    else count->bytes += bytes;
                    if (!CloseHandle(file)) result = PET_STORE_CLEANUP_FAILED;
                }
            }
            if (result != PET_STORE_OK) break;
        } while (FindNextFileW(find, &data));
        if (result == PET_STORE_OK && GetLastError() != ERROR_NO_MORE_FILES)
            result = PET_STORE_IO;
        if (!FindClose(find)) result = PET_STORE_CLEANUP_FAILED;
    }
    if (result == PET_STORE_OK && !depth && (!metadata || !atlas))
        result = PET_STORE_INVALID;
    if (!CloseHandle(pinned)) result = PET_STORE_CLEANUP_FAILED;
    return result;
}

__declspec(dllexport) pet_store_result pulse_companion_quarantine_usage_v1(
    const pet_private_root *lease, SIZE_T size, uint64_t id, uint64_t *bytes) {
    if (!bytes) return PET_STORE_INVALID;
    *bytes = 0;
    if (!live_lease(lease, size) || !id) return PET_STORE_INVALID;
    wchar_t path[PET_PRIVATE_PATH_CAP];
    int n = swprintf(path, PET_PRIVATE_PATH_CAP, L"%ls\\pet-%016llx.removed",
        lease->path, (unsigned long long)id);
    if (n <= 0 || n >= (int)PET_PRIVATE_PATH_CAP) return PET_STORE_INVALID;
    usage_count count = {0};
    pet_store_result result = usage_directory(path, 0, &count);
    if (result == PET_STORE_OK) *bytes = count.bytes;
    return result;
}

/* Read-only current directory identity; not deletion authorization. */
__declspec(dllexport) pet_store_result pulse_companion_quarantine_identity_v1(
    const pet_private_root *lease, SIZE_T size, uint64_t id,
    uint32_t *volume, uint64_t *file_index) {
    if (!volume || !file_index) return PET_STORE_INVALID;
    *volume = 0;
    *file_index = 0;
    if (!live_lease(lease, size) || !id) return PET_STORE_INVALID;
    wchar_t path[PET_PRIVATE_PATH_CAP];
    int n = swprintf(path, PET_PRIVATE_PATH_CAP, L"%ls\\pet-%016llx.removed",
        lease->path, (unsigned long long)id);
    if (n <= 0 || n >= (int)PET_PRIVATE_PATH_CAP) return PET_STORE_INVALID;
    HANDLE file;
    BY_HANDLE_FILE_INFORMATION info;
    pet_store_result result = usage_open(path, TRUE, &file, &info);
    if (result != PET_STORE_OK) return result;
    if (!CloseHandle(file)) return PET_STORE_CLEANUP_FAILED;
    *volume = info.dwVolumeSerialNumber;
    *file_index = ((uint64_t)info.nFileIndexHigh << 32) | info.nFileIndexLow;
    return *file_index ? PET_STORE_OK : PET_STORE_INVALID;
}

/* Independent fixed-ID receipt ABI. The caller owns the typed codec. */
__declspec(dllexport) pet_store_result pulse_companion_receipt_read_v1(
    const pet_private_root *lease, SIZE_T size, uint64_t id,
    uint8_t *out, SIZE_T capacity, SIZE_T *written) {
    if (!live_lease(lease, size)) return PET_STORE_INVALID;
    return pet_removal_receipt_read(lease->path, id, out, capacity, written);
}
__declspec(dllexport) pet_store_result pulse_companion_receipt_write_v1(
    const pet_private_root *lease, SIZE_T size, uint64_t id,
    const uint8_t *data, SIZE_T length) {
    if (!live_lease(lease, size)) return PET_STORE_INVALID;
    return pet_removal_receipt_write(lease->path, id, data, length);
}
