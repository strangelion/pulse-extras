#ifndef PULSE_NATIVE_MENU_WIN32_H
#define PULSE_NATIVE_MENU_WIN32_H
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <stddef.h>
#include <wchar.h>

/* Preserve native checked-state and other flags, styling only the selected
 * mutually exclusive option. This works across a separator and does not
 * turn independent toggles into radio items. Failure leaves the checkmark. */
static inline BOOL pulse_menu_mark_radio(HMENU menu, UINT command) {
    MENUITEMINFOW info = {0};
    info.cbSize = sizeof(info);
    info.fMask = MIIM_FTYPE | MIIM_STATE;
    if (!GetMenuItemInfoW(menu, command, FALSE, &info) ||
        !(info.fState & MFS_CHECKED) || (info.fType & MFT_SEPARATOR)) return FALSE;
    info.fMask = MIIM_FTYPE;
    info.fType |= MFT_RADIOCHECK;
    return SetMenuItemInfoW(menu, command, FALSE, &info);
}

/* Convert a validated UTF-8 display name and escape Win32 mnemonic markers.
 * Caller supplies bounded buffers. No allocation or process-wide state.
 * Input and output must not overlap; failure empties the output. */
static inline BOOL pulse_menu_escape_utf8(const char *name, wchar_t *scratch,
    int scratch_count, wchar_t *out, size_t out_count) {
    if (!out || !out_count) return FALSE;
    out[0] = 0;
    if (!name || !scratch || scratch_count <= 0) return FALSE;
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        name, -1, scratch, scratch_count);
    if (!n) return FALSE;
    size_t needed = 1;
    for (int k = 0; k < n - 1; ++k) {
        size_t add = scratch[k] == L'&' ? 2u : 1u;
        if (add > out_count - needed) return FALSE;
        needed += add;
    }
    size_t pos = 0;
    for (int k = 0; k < n - 1; ++k) {
        if (scratch[k] == L'&') out[pos++] = L'&';
        out[pos++] = scratch[k];
    }
    out[pos] = 0;
    return TRUE;
}
#endif
