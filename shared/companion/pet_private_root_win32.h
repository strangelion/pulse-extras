#ifndef PULSE_PET_PRIVATE_ROOT_WIN32_H
#define PULSE_PET_PRIVATE_ROOT_WIN32_H
#include "../fs/private_root_win32.h"

/* Companion product wrapper over the shared private-root lease. The shared
 * module owns canonical observation, exact-DACL approval and the exclusive
 * owner lock; Companion keeps its fixed namespace constants and API names.
 * An open lease is not protection from other programs running as the same
 * user, administrators, or hostile ancestor mutation. */
typedef pulse_private_root pet_private_root;
typedef pulse_private_result pet_private_result;

#define PET_PRIVATE_PATH_CAP PULSE_PRIVATE_PATH_CAP
#define PET_PRIVATE_OK PULSE_PRIVATE_OK
#define PET_PRIVATE_INVALID PULSE_PRIVATE_INVALID
#define PET_PRIVATE_IO PULSE_PRIVATE_IO
#define PET_PRIVATE_BUSY PULSE_PRIVATE_BUSY
#define PET_PRIVATE_CLEANUP_FAILED PULSE_PRIVATE_CLEANUP_FAILED

/* Zero-initialize lease; retain until all writers and children are drained.
 * On failed cleanup retain any unclosed handles and retry close. */
pet_private_result pet_private_root_open(pet_private_root *lease, const wchar_t *parent);
pet_private_result pet_private_root_close(pet_private_root *lease);
/* Separate fixed private namespace for managed diagnostic files. */
pet_private_result pet_private_diagnostics_open(pet_private_root *lease, const wchar_t *parent);

#endif
