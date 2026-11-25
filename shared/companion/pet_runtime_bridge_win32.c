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
    SCAN_INVENTORY, SCAN_INVENTORY_PENDING, SCAN_LOCK };
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
