#ifndef PULSE_PET_PRIVATE_ROOT_WIN32_H
#define PULSE_PET_PRIVATE_ROOT_WIN32_H
#include <windows.h>
#include <stddef.h>

/* Serialized native worker; parent is the separately approved canonical
 * LocalAppData directory (isolated fixture parent in tests). Never accept a
 * UI-supplied parent. An open lease is not protection from other programs
 * running as the same user, administrators, or hostile ancestor mutation.
 * No recursive cleanup or adoption/repair of an incompatible existing ACL. */
#define PET_PRIVATE_PATH_CAP 1024u
typedef enum {
    PET_PRIVATE_OK = 0, PET_PRIVATE_INVALID, PET_PRIVATE_IO,
    PET_PRIVATE_BUSY, PET_PRIVATE_CLEANUP_FAILED
} pet_private_result;
typedef struct {
    HANDLE parent, root, lock;
    wchar_t path[PET_PRIVATE_PATH_CAP];
} pet_private_root;

/* Zero-initialize lease; retain until all writers and children are drained.
 * On failed cleanup retain any unclosed handles and retry close.
 * Creates only the fixed child and its zero-byte owner lock, never modifies
 * an existing root ACL or truncates an existing lock. */
pet_private_result pet_private_root_open(pet_private_root *lease, const wchar_t *parent);
pet_private_result pet_private_root_close(pet_private_root *lease);
/* Separate fixed private namespace for managed diagnostic files. */
pet_private_result pet_private_diagnostics_open(pet_private_root *lease, const wchar_t *parent);
#endif
