#ifndef PULSE_PRIVATE_ROOT_WIN32_H
#define PULSE_PRIVATE_ROOT_WIN32_H
#include <windows.h>
#include <stddef.h>

/* Serialized native worker; parent is the separately approved canonical
 * LocalAppData directory (isolated fixture parent in tests). Never accept a
 * UI-supplied parent. An open lease is not protection from other programs
 * running as the same user, administrators, or hostile ancestor mutation.
 * No recursive cleanup or adoption/repair of an incompatible existing ACL. */
#define PULSE_PRIVATE_PATH_CAP 1024u
typedef enum {
    PULSE_PRIVATE_OK = 0, PULSE_PRIVATE_INVALID, PULSE_PRIVATE_IO,
    PULSE_PRIVATE_BUSY, PULSE_PRIVATE_CLEANUP_FAILED
} pulse_private_result;
typedef struct {
    HANDLE parent, root, lock;
    wchar_t path[PULSE_PRIVATE_PATH_CAP];
} pulse_private_root;

/* Zero-initialize lease; retain until all writers and children are drained.
 * On failed cleanup retain any unclosed handles and retry close.
 * Creates only the fixed child and its zero-byte owner lock, never modifies
 * an existing root ACL or truncates an existing lock. */
/* Namespace is a trusted compile-time product constant, not user input.
 * Only PulseExtras- followed by ASCII alphanumeric/hyphen is admitted. */
pulse_private_result pulse_private_root_open(pulse_private_root *lease, const wchar_t *parent, const wchar_t *name);
pulse_private_result pulse_private_root_close(pulse_private_root *lease);

#endif
