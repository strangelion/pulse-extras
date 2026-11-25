/* Versioned C ABI; caller retains its own manager and storage. */
#include "pet_supervisor_win32.h"
#include "pet_private_root_win32.h"
#include "pet_catalog_store_win32.h"

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
