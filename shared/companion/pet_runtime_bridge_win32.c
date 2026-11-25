/* Versioned C ABI; caller retains its own manager and storage. */
#include "pet_supervisor_win32.h"
#include "pet_private_root_win32.h"
#include "pet_catalog_store_win32.h"
#include <wchar.h>
#include <string.h>

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
    SCAN_RECEIPT, SCAN_RECEIPT_PENDING, SCAN_CLEANUP, SCAN_CLEANUP_PENDING, SCAN_MARKET_ROOT };
#define PET_SCAN_MAX 4096u

static pet_scan_row scan_row(const WIN32_FIND_DATAW *data) {
    const wchar_t *name = data->cFileName;
    pet_scan_row row = {0, SCAN_UNKNOWN, data->dwFileAttributes};
    if (!wcscmp(name, L"inventory.pci")) row.kind = SCAN_INVENTORY;
    else if (!wcscmp(name, L"inventory.pending")) row.kind = SCAN_INVENTORY_PENDING;
    else if (!wcscmp(name, L"owner.lock")) row.kind = SCAN_LOCK;
    else if (!wcscmp(name, L"PulseExtras-Companion")) row.kind = SCAN_MARKET_ROOT;
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
        else if (!wcscmp(name + 20, L".pcl")) row.kind = SCAN_CLEANUP;
        else if (!wcscmp(name + 20, L".pcl.pending")) row.kind = SCAN_CLEANUP_PENDING;
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
#define QUARANTINE_PIN_MAX (USAGE_MAX_FILES + 3u)
typedef struct { HANDLE *handles; SIZE_T capacity, count; BOOL deleting; } usage_pins;

static pet_store_result usage_open_mode(const wchar_t *path, BOOL directory,
    BOOL pin, BOOL deleting, BOOL share_delete, HANDLE *out, BY_HANDLE_FILE_INFORMATION *info) {
    *out = INVALID_HANDLE_VALUE;
    DWORD access = pin ? GENERIC_READ : FILE_READ_ATTRIBUTES;
    if (deleting) access |= DELETE;
    HANDLE file = CreateFileW(path, access, FILE_SHARE_READ | (share_delete ? FILE_SHARE_DELETE : 0),
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
        (deleting && (info->dwFileAttributes & FILE_ATTRIBUTE_READONLY)) ||
        n != wcslen(path) + 4 || n >= PET_PRIVATE_PATH_CAP + 4 ||
        wcsncmp(actual, L"\\\\?\\", 4) ||
        CompareStringOrdinal(actual + 4, -1, path, -1, TRUE) != CSTR_EQUAL) {
        return CloseHandle(file) ? PET_STORE_INVALID : PET_STORE_CLEANUP_FAILED;
    }
    *out = file;
    return PET_STORE_OK;
}

static pet_store_result usage_open(const wchar_t *path, BOOL directory,
    HANDLE *out, BY_HANDLE_FILE_INFORMATION *info) {
    return usage_open_mode(path, directory, FALSE, FALSE, FALSE, out, info);
}

/* Check the opened object rather than a reopened path. Reject named
 * streams, truncated responses and unsupported enumeration. */
static pet_store_result usage_streams(HANDLE file, BOOL directory) {
    union {
        FILE_STREAM_INFO info;
        BYTE bytes[1024];
    } buffer = {0};
    if (!GetFileInformationByHandleEx(file, FileStreamInfo, &buffer, sizeof(buffer))) {
        DWORD error = GetLastError();
        if (error == ERROR_HANDLE_EOF && directory) return PET_STORE_OK;
        if (error == ERROR_MORE_DATA || error == ERROR_INSUFFICIENT_BUFFER)
            return PET_STORE_INVALID;
        return PET_STORE_IO;
    }
    const FILE_STREAM_INFO *stream = &buffer.info;
    const wchar_t default_name[] = L"::$DATA";
    if (stream->NextEntryOffset ||
        stream->StreamNameLength > sizeof(buffer.bytes) - FIELD_OFFSET(FILE_STREAM_INFO, StreamName) ||
        (stream->StreamNameLength != 0 &&
         (stream->StreamNameLength != sizeof(default_name) - sizeof(wchar_t) ||
          wmemcmp(stream->StreamName, default_name, (sizeof(default_name) / sizeof(wchar_t)) - 1))) ||
        (directory && stream->StreamSize.QuadPart != 0))
        return PET_STORE_INVALID;
    return PET_STORE_OK;
}

/* Caller owns every returned handle even when a later admission check
 * fails. Keeping the original opens avoids a close/reopen race. */
static pet_store_result usage_retain(usage_pins *pins, HANDLE file) {
    if (pins->count == pins->capacity)
        return CloseHandle(file) ? PET_STORE_INVALID : PET_STORE_CLEANUP_FAILED;
    pins->handles[pins->count++] = file;
    return PET_STORE_OK;
}

static pet_store_result usage_directory(const wchar_t *path, unsigned depth,
    usage_count *count, usage_pins *pins, uint32_t volume, uint64_t file_index, BOOL share_delete) {
    HANDLE pinned;
    BY_HANDLE_FILE_INFORMATION info;
    pet_store_result result = usage_open_mode(path, TRUE, pins != NULL, pins && pins->deleting, share_delete, &pinned, &info);
    if (result != PET_STORE_OK) return result;
    if (pins) {
        result = usage_retain(pins, pinned);
        if (result != PET_STORE_OK) return result;
        uint64_t actual_id = ((uint64_t)info.nFileIndexHigh << 32) | info.nFileIndexLow;
        if (info.dwVolumeSerialNumber != volume || (!depth && actual_id != file_index))
            return PET_STORE_INVALID;
        result = usage_streams(pinned, TRUE);
        if (result != PET_STORE_OK) return result;
    } else if (!depth && file_index) {
        uint64_t actual_id = ((uint64_t)info.nFileIndexHigh << 32) | info.nFileIndexLow;
        if (info.dwVolumeSerialNumber != volume || actual_id != file_index)
            return CloseHandle(pinned) ? PET_STORE_INVALID : PET_STORE_CLEANUP_FAILED;
    }
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
                result = usage_directory(child, depth + 1u, count, pins, volume, file_index, share_delete);
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
                result = usage_open_mode(child, FALSE, pins != NULL, pins && pins->deleting, share_delete, &file, &info);
                if (result == PET_STORE_OK) {
                    uint64_t bytes = ((uint64_t)info.nFileSizeHigh << 32) | info.nFileSizeLow;
                    if (++count->files > USAGE_MAX_FILES || bytes > USAGE_MAX_FILE_BYTES ||
                        bytes > USAGE_MAX_BYTES - count->bytes ||
                        (pins && info.dwVolumeSerialNumber != volume)) result = PET_STORE_INVALID;
                    else count->bytes += bytes;
                    if (pins) {
                        pet_store_result retained = usage_retain(pins, file);
                        if (retained != PET_STORE_OK) result = retained;
                        else if (result == PET_STORE_OK) result = usage_streams(file, FALSE);
                    } else if (!CloseHandle(file)) result = PET_STORE_CLEANUP_FAILED;
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
    if (!pins && !CloseHandle(pinned)) result = PET_STORE_CLEANUP_FAILED;
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
    pet_store_result result = usage_directory(path, 0, &count, NULL, 0, 0, FALSE);
    if (result == PET_STORE_OK) *bytes = count.bytes;
    return result;
}

/* Bounded read-only pin set. Even on error the caller must close the
 * returned prefix, before releasing the lease or unloading this DLL.
 * Denying write/delete sharing protects opened objects, not creation of
 * new directory entries. This API does not grant deletion permission. */
static pet_store_result pin_quarantine(
    const pet_private_root *lease, SIZE_T size, uint64_t id,
    uint32_t volume, uint64_t file_index, HANDLE *handles,
    SIZE_T capacity, SIZE_T *written, BOOL deleting) {
    if (!written) return PET_STORE_INVALID;
    *written = 0;
    if (!live_lease(lease, size) || !id || !file_index || !handles ||
        capacity != QUARANTINE_PIN_MAX) return PET_STORE_INVALID;
    wchar_t path[PET_PRIVATE_PATH_CAP];
    int n = swprintf(path, PET_PRIVATE_PATH_CAP, L"%ls\\pet-%016llx.removed",
        lease->path, (unsigned long long)id);
    if (n <= 0 || n >= (int)PET_PRIVATE_PATH_CAP) return PET_STORE_INVALID;
    usage_count count = {0};
    usage_pins pins = {handles, capacity, 0, deleting};
    pet_store_result result = usage_directory(path, 0, &count, &pins, volume, file_index, FALSE);
    *written = pins.count;
    return result;
}

__declspec(dllexport) pet_store_result pulse_companion_quarantine_pin_v1(
    const pet_private_root *lease, SIZE_T size, uint64_t id,
    uint32_t volume, uint64_t file_index, HANDLE *handles,
    SIZE_T capacity, SIZE_T *written) {
    return pin_quarantine(lease, size, id, volume, file_index, handles, capacity, written, FALSE);
}

__declspec(dllexport) pet_store_result pulse_companion_cleanup_pin_v1(
    const pet_private_root *lease, SIZE_T size, uint64_t id,
    uint32_t volume, uint64_t file_index, HANDLE *handles,
    SIZE_T capacity, SIZE_T *written) {
    return pin_quarantine(lease, size, id, volume, file_index, handles, capacity, written, TRUE);
}

/* Recheck the bounded namespace against the retained handles. Existing
 * objects cannot be replaced while their sharing pins remain open.
 * This detects additions during the scan, not later same-user insertion.
 * No handle ownership transfer or deletion. */
static pet_store_result recheck_quarantine(
    const pet_private_root *lease, SIZE_T size, uint64_t id,
    uint32_t volume, uint64_t file_index, const HANDLE *handles, SIZE_T count, BOOL deleting) {
    if (!live_lease(lease, size) || !id || !file_index || !handles ||
        count < 3 || count > QUARANTINE_PIN_MAX) return PET_STORE_INVALID;
    wchar_t path[PET_PRIVATE_PATH_CAP];
    int n = swprintf(path, PET_PRIVATE_PATH_CAP, L"%ls\\pet-%016llx.removed",
        lease->path, (unsigned long long)id);
    if (n <= 0 || n >= (int)PET_PRIVATE_PATH_CAP) return PET_STORE_INVALID;
    usage_count usage = {0};
    pet_store_result result = usage_directory(path, 0, &usage, NULL, volume, file_index, deleting);
    if (result != PET_STORE_OK) return result;
    if ((SIZE_T)usage.entries + 1 != count) return PET_STORE_INVALID;
    for (SIZE_T index = 0; index < count; ++index) {
        BY_HANDLE_FILE_INFORMATION info;
        if (!GetFileInformationByHandle(handles[index], &info)) return PET_STORE_IO;
        BOOL directory = !!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY);
        uint64_t actual_id = ((uint64_t)info.nFileIndexHigh << 32) | info.nFileIndexLow;
        if (info.dwVolumeSerialNumber != volume ||
            (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
            (!directory && info.nNumberOfLinks != 1) ||
            (!index && (!directory || actual_id != file_index))) return PET_STORE_INVALID;
        wchar_t actual[PET_PRIVATE_PATH_CAP + 4];
        DWORD len = GetFinalPathNameByHandleW(handles[index], actual, PET_PRIVATE_PATH_CAP + 4,
            FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
        size_t root_len = wcslen(path);
        if (len < root_len + 4 || len >= PET_PRIVATE_PATH_CAP + 4 ||
            wcsncmp(actual, L"\\\\?\\", 4) ||
            CompareStringOrdinal(actual + 4, (int)root_len, path, (int)root_len, TRUE) != CSTR_EQUAL ||
            (index ? actual[root_len + 4] != L'\\' : len != root_len + 4))
            return PET_STORE_INVALID;
        for (SIZE_T other = 0; other < index; ++other)
            if (handles[other] == handles[index]) return PET_STORE_INVALID;
        if (deleting && (info.dwFileAttributes & FILE_ATTRIBUTE_READONLY)) return PET_STORE_INVALID;
        result = usage_streams(handles[index], directory);
        if (result != PET_STORE_OK) return result;
    }
    return PET_STORE_OK;
}

__declspec(dllexport) pet_store_result pulse_companion_quarantine_recheck_v1(
    const pet_private_root *lease, SIZE_T size, uint64_t id,
    uint32_t volume, uint64_t file_index, const HANDLE *handles, SIZE_T count) {
    return recheck_quarantine(lease, size, id, volume, file_index, handles, count, FALSE);
}

__declspec(dllexport) pet_store_result pulse_companion_cleanup_recheck_v1(
    const pet_private_root *lease, SIZE_T size, uint64_t id,
    uint32_t volume, uint64_t file_index, const HANDLE *handles, SIZE_T count) {
    return recheck_quarantine(lease, size, id, volume, file_index, handles, count, TRUE);
}

/* Only verified pinned objects, leaf-first. Never follow new entries. */
__declspec(dllexport) pet_store_result pulse_companion_cleanup_dispose_v1(
    const pet_private_root *lease, SIZE_T size, uint64_t id,
    uint32_t volume, uint64_t file_index, HANDLE *handles, SIZE_T *count,
    const uint8_t *expected, SIZE_T expected_size) {
    if (!count || !expected || expected_size != PET_REMOVAL_RECEIPT_BYTES)
        return PET_STORE_INVALID;
    pet_store_result result = recheck_quarantine(lease, size, id, volume, file_index, handles, *count, TRUE);
    if (result != PET_STORE_OK) return result;
    uint8_t marker[PET_REMOVAL_RECEIPT_BYTES];
    SIZE_T written = 0;
    result = pet_cleanup_marker_read(lease->path, id, marker, sizeof(marker), &written);
    if (result != PET_STORE_OK) return result;
    if (written != expected_size || memcmp(marker, expected, expected_size))
        return PET_STORE_INVALID;
    while (*count) {
        HANDLE file = handles[*count - 1];
        BY_HANDLE_FILE_INFORMATION info;
        if (!GetFileInformationByHandle(file, &info)) return PET_STORE_IO;
        BOOL dir = !!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY);
        if (info.dwVolumeSerialNumber != volume ||
            (info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_READONLY)) ||
            (!dir && info.nNumberOfLinks != 1)) return PET_STORE_INVALID;
        result = usage_streams(file, dir);
        if (result != PET_STORE_OK) return result;
        FILE_DISPOSITION_INFO disposition = {0};
        disposition.DeleteFile = TRUE;
        if (!SetFileInformationByHandle(file, FileDispositionInfo, &disposition, sizeof(disposition)))
            return PET_STORE_IO;
        if (!CloseHandle(file)) return PET_STORE_CLEANUP_FAILED;
        --*count;
    }
    wchar_t path[PET_PRIVATE_PATH_CAP];
    int n = swprintf(path, PET_PRIVATE_PATH_CAP, L"%ls\\pet-%016llx.removed",
        lease->path, (unsigned long long)id);
    if (n <= 0 || n >= (int)PET_PRIVATE_PATH_CAP) return PET_STORE_INVALID;
    if (GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES) return PET_STORE_IO;
    return GetLastError() == ERROR_FILE_NOT_FOUND ? PET_STORE_OK : PET_STORE_IO;
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

__declspec(dllexport) pet_store_result pulse_companion_cleanup_marker_write_v1(
    const pet_private_root *lease, SIZE_T size, uint64_t id,
    const uint8_t *data, SIZE_T length) {
    if (!live_lease(lease, size)) return PET_STORE_INVALID;
    return pet_cleanup_marker_write(lease->path, id, data, length);
}

/* Market cache occupies its own independently ACL-checked nested lease.
 * These exports accept only that lease, not a UI-controlled pathname. */
__declspec(dllexport) pet_store_result pulse_companion_market_read_v1(
    const pet_private_root *lease, SIZE_T size, uint64_t slot,
    uint8_t *out, SIZE_T capacity, SIZE_T *written) {
    if (!live_lease(lease, size) || slot >= PET_MARKET_CACHE_SLOTS)
        return PET_STORE_INVALID;
    return pet_market_cache_read(lease->path, (uint32_t)slot, out, capacity, written);
}
__declspec(dllexport) pet_store_result pulse_companion_market_write_v1(
    const pet_private_root *lease, SIZE_T size, uint64_t slot,
    const uint8_t *data, SIZE_T length) {
    if (!live_lease(lease, size) || slot >= PET_MARKET_CACHE_SLOTS)
        return PET_STORE_INVALID;
    return pet_market_cache_write(lease->path, (uint32_t)slot, data, length);
}
