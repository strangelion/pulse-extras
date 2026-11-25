#include "pet_surface_win32.h"

#define ATLAS_WIDTH (PET_FRAME_WIDTH * 8u)

static unsigned premultiply(unsigned value, unsigned alpha) {
    return (value * alpha + 127u) / 255u;
}

pet_surface_result pet_frame_bgra(const uint8_t *atlas, size_t atlas_bytes,
    unsigned version, unsigned row, unsigned column, uint8_t *out, size_t out_bytes) {
    unsigned rows = version == 1 ? 9u : (version == 2 ? 11u : 0u);
    if (!atlas || !out || !rows || row >= rows || column >= 8u ||
        atlas_bytes != (size_t)ATLAS_WIDTH * PET_FRAME_HEIGHT * rows * 4u ||
        out_bytes != PET_FRAME_BYTES) return PET_SURFACE_INVALID;
    /* Reject overlapping ranges without relational comparisons of pointers
     * to unrelated objects. Check subtraction, not overflowing end pointers. */
    uintptr_t a = (uintptr_t)atlas, b = (uintptr_t)out;
    if ((a <= b && b - a < atlas_bytes) ||
        (b < a && a - b < out_bytes)) return PET_SURFACE_INVALID;
    for (unsigned y = 0; y < PET_FRAME_HEIGHT; ++y) {
        size_t offset = ((size_t)(row * PET_FRAME_HEIGHT + y) * ATLAS_WIDTH +
            column * PET_FRAME_WIDTH) * 4u;
        const uint8_t *src = atlas + offset;
        uint8_t *dst = out + (size_t)y * PET_FRAME_WIDTH * 4u;
        for (unsigned x = 0; x < PET_FRAME_WIDTH; ++x, src += 4, dst += 4) {
            unsigned alpha = src[3];
            dst[0] = (uint8_t)premultiply(src[2], alpha);
            dst[1] = (uint8_t)premultiply(src[1], alpha);
            dst[2] = (uint8_t)premultiply(src[0], alpha);
            dst[3] = (uint8_t)alpha;
        }
    }
    return PET_SURFACE_OK;
}

static const wchar_t class_name[] = L"PulseExtras.Companion.Layered.Experimental.V1";

static LRESULT CALLBACK pet_window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
    /* No system-menu close may accidentally terminate the owning process.
     * Hide the pet; the owner decides when to release the surface. */
    if (message == WM_CLOSE) {
        ShowWindow(window, SW_HIDE);
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

static BOOL ensure_class(HINSTANCE module) {
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = pet_window_proc;
    wc.hInstance = module;
    wc.lpszClassName = class_name;
    if (RegisterClassW(&wc)) return TRUE;
    if (GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return FALSE;
    WNDCLASSW existing = {0};
    return GetClassInfoW(module, class_name, &existing) &&
        existing.lpfnWndProc == pet_window_proc;
}

static pet_surface_result check(const pet_surface *surface) {
    if (!surface || !surface->owner_thread) return PET_SURFACE_INVALID;
    if (GetCurrentThreadId() != surface->owner_thread) return PET_SURFACE_WRONG_THREAD;
    if (!surface->window || !IsWindow(surface->window) ||
        !surface->memory_dc || !surface->bitmap || !surface->pixels)
        return PET_SURFACE_INVALID;
    return PET_SURFACE_OK;
}

pet_surface_result pet_surface_close(pet_surface *surface) {
    if (!surface) return PET_SURFACE_INVALID;
    if (!surface->owner_thread) return PET_SURFACE_OK;
    if (GetCurrentThreadId() != surface->owner_thread) return PET_SURFACE_WRONG_THREAD;
    if (surface->window && IsWindow(surface->window)) {
        if (!DestroyWindow(surface->window)) return PET_SURFACE_OS_ERROR;
    }
    surface->window = NULL;
    if (surface->memory_dc && surface->previous)
        SelectObject(surface->memory_dc, surface->previous);
    /* Deleting the DC first also releases a selected bitmap if restoration
     * failed. Never delete the previous stock bitmap. */
    if (surface->memory_dc) DeleteDC(surface->memory_dc);
    if (surface->bitmap) DeleteObject(surface->bitmap);
    *surface = (pet_surface){0};
    return PET_SURFACE_OK;
}

pet_surface_result pet_surface_open(pet_surface *surface, BOOL topmost, BOOL click_through) {
    if (!surface || surface->owner_thread || surface->window ||
        surface->memory_dc || surface->bitmap || surface->pixels)
        return PET_SURFACE_INVALID;
    surface->owner_thread = GetCurrentThreadId();
    HINSTANCE module = GetModuleHandleW(NULL);
    if (!module || !ensure_class(module)) goto fail;
    DWORD ex = WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
    if (topmost) ex |= WS_EX_TOPMOST;
    if (click_through) ex |= WS_EX_TRANSPARENT;
    surface->window = CreateWindowExW(ex, class_name, L"Pulse companion",
        WS_POPUP, 0, 0, PET_FRAME_WIDTH, PET_FRAME_HEIGHT,
        NULL, NULL, module, NULL);
    if (!surface->window) goto fail;
    surface->memory_dc = CreateCompatibleDC(NULL);
    if (!surface->memory_dc) goto fail;
    BITMAPINFO info = {0};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = PET_FRAME_WIDTH;
    info.bmiHeader.biHeight = -(LONG)PET_FRAME_HEIGHT;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void *pixels = NULL;
    surface->bitmap = CreateDIBSection(surface->memory_dc, &info, DIB_RGB_COLORS,
        &pixels, NULL, 0);
    if (!surface->bitmap || !pixels) goto fail;
    surface->pixels = pixels;
    surface->previous = SelectObject(surface->memory_dc, surface->bitmap);
    if (!surface->previous || surface->previous == HGDI_ERROR) {
        surface->previous = NULL;
        goto fail;
    }
    ZeroMemory(surface->pixels, PET_FRAME_BYTES);
    return PET_SURFACE_OK;
fail:
    (void)pet_surface_close(surface);
    return PET_SURFACE_OS_ERROR;
}

pet_surface_result pet_surface_present(pet_surface *surface, const uint8_t *atlas,
    size_t atlas_bytes, unsigned version, unsigned row, unsigned column,
    LONG x, LONG y, BYTE opacity) {
    pet_surface_result result = check(surface);
    if (result != PET_SURFACE_OK) return result;
    result = pet_frame_bgra(atlas, atlas_bytes, version, row, column,
        surface->pixels, PET_FRAME_BYTES);
    if (result != PET_SURFACE_OK) return result;
    POINT position = {x, y};
    POINT origin = {0, 0};
    SIZE size = {PET_FRAME_WIDTH, PET_FRAME_HEIGHT};
    BLENDFUNCTION blend = {AC_SRC_OVER, 0, opacity, AC_SRC_ALPHA};
    HDC desktop = GetDC(NULL);
    if (!desktop) return PET_SURFACE_OS_ERROR;
    BOOL ok = UpdateLayeredWindow(surface->window, desktop, &position, &size,
        surface->memory_dc, &origin, 0, &blend, ULW_ALPHA);
    ReleaseDC(NULL, desktop);
    if (!ok) return PET_SURFACE_OS_ERROR;
    surface->primed = TRUE;
    return PET_SURFACE_OK;
}

pet_surface_result pet_surface_show(pet_surface *surface, BOOL visible) {
    pet_surface_result result = check(surface);
    if (result != PET_SURFACE_OK) return result;
    if (visible && !surface->primed) return PET_SURFACE_INVALID;
    ShowWindow(surface->window, visible ? SW_SHOWNOACTIVATE : SW_HIDE);
    return PET_SURFACE_OK;
}

pet_surface_result pet_surface_policy(pet_surface *surface, BOOL topmost, BOOL click_through) {
    pet_surface_result result = check(surface);
    if (result != PET_SURFACE_OK) return result;
    SetLastError(0);
    LONG_PTR old = GetWindowLongPtrW(surface->window, GWL_EXSTYLE);
    if (!old && GetLastError()) return PET_SURFACE_OS_ERROR;
    LONG_PTR next = click_through ? old | WS_EX_TRANSPARENT : old & ~(LONG_PTR)WS_EX_TRANSPARENT;
    if (next != old) {
        SetLastError(0);
        if (!SetWindowLongPtrW(surface->window, GWL_EXSTYLE, next) && GetLastError())
            return PET_SURFACE_OS_ERROR;
    }
    if (!SetWindowPos(surface->window, topmost ? HWND_TOPMOST : HWND_NOTOPMOST,
        0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED)) {
        if (next != old) SetWindowLongPtrW(surface->window, GWL_EXSTYLE, old);
        return PET_SURFACE_OS_ERROR;
    }
    return PET_SURFACE_OK;
}
