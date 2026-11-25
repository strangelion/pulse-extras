#include "pet_surface_win32.h"

static unsigned premultiply(unsigned value, unsigned alpha) {
    return (value * alpha + 127u) / 255u;
}

static pet_surface_result frame_scaled(const uint8_t *atlas, size_t atlas_bytes,
    unsigned columns, unsigned rows, unsigned row, unsigned column, uint8_t *out,
    size_t out_bytes, unsigned width, unsigned height) {
    if (!atlas || !out ||
        !((columns == 8 && (rows == 9 || rows == 11)) ||
          (rows == 1 && columns >= 4 && columns <= 32)) ||
        row >= rows || column >= columns ||
        atlas_bytes != (size_t)columns * PET_FRAME_WIDTH * PET_FRAME_HEIGHT * rows * 4u ||
        width < PET_FRAME_WIDTH / 2 || width > PET_FRAME_WIDTH * 2 ||
        height < PET_FRAME_HEIGHT / 2 || height > PET_FRAME_HEIGHT * 2 ||
        out_bytes != (size_t)width * height * 4u) return PET_SURFACE_INVALID;
    /* Reject overlapping ranges without relational comparisons of pointers
     * to unrelated objects. Check subtraction, not overflowing end pointers. */
    uintptr_t a = (uintptr_t)atlas, b = (uintptr_t)out;
    if ((a <= b && b - a < atlas_bytes) ||
        (b < a && a - b < out_bytes)) return PET_SURFACE_INVALID;
    for (unsigned y = 0; y < height; ++y) {
        unsigned sy = y * PET_FRAME_HEIGHT / height;
        size_t offset = ((size_t)(row * PET_FRAME_HEIGHT + sy) * (columns * PET_FRAME_WIDTH) +
            column * PET_FRAME_WIDTH) * 4u;
        uint8_t *dst = out + (size_t)y * width * 4u;
        for (unsigned x = 0; x < width; ++x, dst += 4) {
            const uint8_t *src = atlas + offset + (size_t)(x * PET_FRAME_WIDTH / width) * 4u;
            unsigned alpha = src[3];
            dst[0] = (uint8_t)premultiply(src[2], alpha);
            dst[1] = (uint8_t)premultiply(src[1], alpha);
            dst[2] = (uint8_t)premultiply(src[0], alpha);
            dst[3] = (uint8_t)alpha;
        }
    }
    return PET_SURFACE_OK;
}

pet_surface_result pet_frame_bgra(const uint8_t *atlas, size_t atlas_bytes,
    unsigned version, unsigned row, unsigned column, uint8_t *out, size_t out_bytes) {
    return frame_scaled(atlas, atlas_bytes, 8, version == 1 ? 9u : (version == 2 ? 11u : 0u),
        row, column, out, out_bytes,
        PET_FRAME_WIDTH, PET_FRAME_HEIGHT);
}

pet_surface_result pet_clamp_position(const RECT *work, unsigned width,
    unsigned height, LONG *x, LONG *y) {
    if (!work || !x || !y || !width || !height ||
        width > PET_FRAME_WIDTH * 2 || height > PET_FRAME_HEIGHT * 2 ||
        work->right <= work->left || work->bottom <= work->top) return PET_SURFACE_INVALID;
    int64_t max_x = (int64_t)work->right - width;
    int64_t max_y = (int64_t)work->bottom - height;
    if (max_x < work->left) max_x = work->left;
    if (max_y < work->top) max_y = work->top;
    if (*x < work->left) *x = work->left;
    else if (*x > max_x) *x = (LONG)max_x;
    if (*y < work->top) *y = work->top;
    else if (*y > max_y) *y = (LONG)max_y;
    return PET_SURFACE_OK;
}

static const wchar_t class_name[] = L"PulseExtras.Companion.Layered.Experimental.V1";

static LRESULT CALLBACK pet_window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_NCCREATE) {
        const CREATESTRUCTW *create = (const CREATESTRUCTW *)lparam;
        SetWindowLongPtrW(window, GWLP_USERDATA, (LONG_PTR)create->lpCreateParams);
    }
    pet_surface *surface = (pet_surface *)GetWindowLongPtrW(window, GWLP_USERDATA);
    if (surface && (message == WM_DISPLAYCHANGE || message == WM_SETTINGCHANGE ||
        message == WM_DPICHANGED)) surface->placement_dirty = TRUE;
    if (message == WM_NCDESTROY) SetWindowLongPtrW(window, GWLP_USERDATA, 0);
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
    // A null class cursor leaves the previous cursor (including the
    // application-starting spinner) unchanged over this layered window.
    // The shared system arrow is OS-owned; do not destroy it.
    wc.hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32512)); // IDC_ARROW
    if (!wc.hCursor) return FALSE;
    wc.lpszClassName = class_name;
    if (RegisterClassW(&wc)) return TRUE;
    if (GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return FALSE;
    WNDCLASSW existing = {0};
    return GetClassInfoW(module, class_name, &existing) &&
        existing.lpfnWndProc == pet_window_proc && existing.hCursor == wc.hCursor;
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
    return pet_surface_open_scaled(surface, topmost, click_through, 100);
}

pet_surface_result pet_surface_open_scaled(pet_surface *surface, BOOL topmost,
    BOOL click_through, unsigned percent) {
    if (!surface || surface->owner_thread || surface->window ||
        surface->memory_dc || surface->bitmap || surface->pixels ||
        percent < PET_MIN_SCALE || percent > PET_MAX_SCALE)
        return PET_SURFACE_INVALID;
    surface->owner_thread = GetCurrentThreadId();
    surface->width = PET_FRAME_WIDTH * percent / 100;
    surface->height = PET_FRAME_HEIGHT * percent / 100;
    HINSTANCE module = GetModuleHandleW(NULL);
    if (!module || !ensure_class(module)) goto fail;
    DWORD ex = WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
    if (topmost) ex |= WS_EX_TOPMOST;
    if (click_through) ex |= WS_EX_TRANSPARENT;
    surface->window = CreateWindowExW(ex, class_name, L"Pulse companion",
        WS_POPUP, 0, 0, (int)surface->width, (int)surface->height,
        NULL, NULL, module, surface);
    if (!surface->window) goto fail;
    surface->memory_dc = CreateCompatibleDC(NULL);
    if (!surface->memory_dc) goto fail;
    BITMAPINFO info = {0};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = (LONG)surface->width;
    info.bmiHeader.biHeight = -(LONG)surface->height;
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
    ZeroMemory(surface->pixels, (size_t)surface->width * surface->height * 4u);
    return PET_SURFACE_OK;
fail:
    (void)pet_surface_close(surface);
    return PET_SURFACE_OS_ERROR;
}

static pet_surface_result present_grid(pet_surface *surface, const uint8_t *atlas,
    size_t atlas_bytes, unsigned columns, unsigned rows, unsigned row,
    unsigned column, LONG x, LONG y, BYTE opacity) {
    pet_surface_result result = check(surface);
    if (result != PET_SURFACE_OK) return result;
    result = frame_scaled(atlas, atlas_bytes, columns, rows, row, column,
        surface->pixels, (size_t)surface->width * surface->height * 4u,
        surface->width, surface->height);
    if (result != PET_SURFACE_OK) return result;
    POINT position = {x, y};
    POINT origin = {0, 0};
    SIZE size = {(LONG)surface->width, (LONG)surface->height};
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

pet_surface_result pet_surface_present(pet_surface *surface, const uint8_t *atlas,
    size_t atlas_bytes, unsigned version, unsigned row, unsigned column,
    LONG x, LONG y, BYTE opacity) {
    return present_grid(surface, atlas, atlas_bytes, 8,
        version == 1 ? 9u : (version == 2 ? 11u : 0u), row, column, x, y, opacity);
}

pet_surface_result pet_surface_present_activity(pet_surface *surface,
    const uint8_t *strip, size_t strip_bytes, unsigned frames, unsigned column,
    LONG x, LONG y, BYTE opacity) {
    return present_grid(surface, strip, strip_bytes, frames, 1, 0, column, x, y, opacity);
}

pet_surface_result pet_surface_move(pet_surface *surface, LONG x, LONG y) {
    pet_surface_result result = check(surface);
    if (result != PET_SURFACE_OK) return result;
    if (!surface->primed) return PET_SURFACE_INVALID;
    POINT position = {x, y};
    /* Position-only update: no conversion, upload, resize or activation. */
    return UpdateLayeredWindow(surface->window, NULL, &position, NULL, NULL,
        NULL, 0, NULL, 0) ? PET_SURFACE_OK : PET_SURFACE_OS_ERROR;
}

pet_surface_result pet_surface_resize(pet_surface *surface, unsigned percent,
    const uint8_t *atlas, size_t atlas_bytes, unsigned version, unsigned row,
    unsigned column, LONG x, LONG y, BYTE opacity) {
    pet_surface_result result = check(surface);
    if (result != PET_SURFACE_OK) return result;
    if (!surface->primed || percent < PET_MIN_SCALE || percent > PET_MAX_SCALE)
        return PET_SURFACE_INVALID;
    unsigned width = PET_FRAME_WIDTH * percent / 100;
    unsigned height = PET_FRAME_HEIGHT * percent / 100;
    HDC dc = CreateCompatibleDC(NULL);
    if (!dc) return PET_SURFACE_OS_ERROR;
    HBITMAP bitmap = NULL;
    HGDIOBJ previous = NULL;
    void *pixels = NULL;
    BITMAPINFO info = {0};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = (LONG)width;
    info.bmiHeader.biHeight = -(LONG)height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    result = PET_SURFACE_OS_ERROR;
    bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &pixels, NULL, 0);
    if (!bitmap || !pixels) goto cleanup;
    previous = SelectObject(dc, bitmap);
    if (!previous || previous == HGDI_ERROR) { previous = NULL; goto cleanup; }
    result = frame_scaled(atlas, atlas_bytes, 8,
        version == 1 ? 9u : (version == 2 ? 11u : 0u), row, column, pixels,
        (size_t)width * height * 4u, width, height);
    if (result != PET_SURFACE_OK) goto cleanup;
    POINT position = {x, y}, origin = {0, 0};
    SIZE size = {(LONG)width, (LONG)height};
    BLENDFUNCTION blend = {AC_SRC_OVER, 0, opacity, AC_SRC_ALPHA};
    HDC desktop = GetDC(NULL);
    result = PET_SURFACE_OS_ERROR;
    if (!desktop) goto cleanup;
    BOOL ok = UpdateLayeredWindow(surface->window, desktop, &position, &size,
        dc, &origin, 0, &blend, ULW_ALPHA);
    ReleaseDC(NULL, desktop);
    if (!ok) goto cleanup;

    SelectObject(surface->memory_dc, surface->previous);
    DeleteDC(surface->memory_dc);
    DeleteObject(surface->bitmap);
    surface->memory_dc = dc;
    surface->bitmap = bitmap;
    surface->previous = previous;
    surface->pixels = pixels;
    surface->width = width;
    surface->height = height;
    return PET_SURFACE_OK;
cleanup:
    if (previous) SelectObject(dc, previous);
    DeleteDC(dc);
    if (bitmap) DeleteObject(bitmap);
    return result;
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
