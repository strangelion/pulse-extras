#include "pet_private_root_win32.h"

/* Fixed Companion-owned namespaces. The shared primitive rejects any other
 * name shape, so these compile-time constants are the only admitted roots. */
pet_private_result pet_private_root_open(pet_private_root *lease, const wchar_t *parent) {
    return pulse_private_root_open(lease, parent, L"PulseExtras-Companion");
}

pet_private_result pet_private_diagnostics_open(pet_private_root *lease, const wchar_t *parent) {
    return pulse_private_root_open(lease, parent, L"PulseExtras-Diagnostics");
}

pet_private_result pet_private_root_close(pet_private_root *lease) {
    return pulse_private_root_close(lease);
}
