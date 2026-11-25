/* Windows CI bridge for the Zig host test; no real Pulse host. */
#include "../../shared/companion/pet_supervisor_win32.h"
#include <limits.h>

_Static_assert(sizeof(pet_supervisor) == 56, "supervisor ABI");
_Static_assert(sizeof(pet_child_options) == 20, "options ABI");

uint32_t pet_host_fixture_path(uint8_t *out, uint32_t capacity) {
    wchar_t path[1024];
    DWORD n = GetFullPathNameW(L"zig-out\\pulse-pet-demo.exe", 1024, path, NULL);
    if (!n || n >= 1024 || !out || capacity > INT_MAX) return 0;
    int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path, (int)n,
        (char *)out, (int)capacity, NULL, NULL);
    return bytes > 0 ? (uint32_t)bytes : 0;
}

int pet_host_fixture_wait(HANDLE process, uint32_t timeout_ms) {
    return process && WaitForSingleObject(process, timeout_ms) == WAIT_OBJECT_0;
}
