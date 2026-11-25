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

static void cancel_menu(pet_surface *surface, BOOL timeout) {
    if (!surface->menu_timer || surface->menu_cancelled) return;
    surface->menu_cancelled = TRUE;
    if (timeout) pet_note(surface->resources, PET_NOTE_TIMEOUT);
    /* Owner thread, including while TrackPopupMenuEx runs its modal loop. */
    if (!EndMenu()) DefWindowProcW(surface->window, WM_CANCELMODE, 0, 0);
}

static LRESULT CALLBACK pet_window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_NCCREATE) {
        const CREATESTRUCTW *create = (const CREATESTRUCTW *)lparam;
        SetLastError(0);
        if (!SetWindowLongPtrW(window, GWLP_USERDATA, (LONG_PTR)create->lpCreateParams) && GetLastError())
            return FALSE;
    }
    pet_surface *surface = (pet_surface *)GetWindowLongPtrW(window, GWLP_USERDATA);
    if (surface && (message == WM_DISPLAYCHANGE || message == WM_SETTINGCHANGE ||
        message == WM_DPICHANGED)) surface->placement_dirty = TRUE;
    /* These broadcasts can be sent directly to the window procedure,
     * not only retrieved by PeekMessage. Re-evaluate civil-time rules. */
    if (surface && (message == WM_TIMECHANGE || message == WM_SETTINGCHANGE ||
        message == WM_POWERBROADCAST)) surface->schedule_dirty = TRUE;
    if (surface && surface->menu_timer) {
        if (message == WM_MENUSELECT && !(HIWORD(wparam) == 0xffff && !lparam))
            surface->menu_last_input = GetTickCount64();
        if (message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE)
            cancel_menu(surface, FALSE);
        if (message == WM_CANCELMODE || message == WM_CLOSE)
            cancel_menu(surface, FALSE);
        if (message == WM_TIMER && wparam == surface->menu_timer) {
            uint64_t now = GetTickCount64();
            if (surface->menu_stop && WaitForSingleObject(surface->menu_stop, 0) != WAIT_TIMEOUT)
                cancel_menu(surface, FALSE);
            else if (GetForegroundWindow() != window)
                cancel_menu(surface, FALSE);
            else {
                POINT cursor;
                if (GetCursorPos(&cursor)) {
                    if (surface->menu_cursor_known &&
                        (cursor.x != surface->menu_cursor.x || cursor.y != surface->menu_cursor.y))
                        surface->menu_last_input = now;
                    surface->menu_cursor = cursor;
                    surface->menu_cursor_known = TRUE;
                }
                if (pet_menu_idle_expired(surface->menu_last_input, now))
                    cancel_menu(surface, TRUE);
            }
            return 0;
        }
    }
    if (message == WM_NCDESTROY) {
        if (surface && surface->window == window && surface->menu_timer)
            (void)pet_surface_menu_end(surface);
        SetWindowLongPtrW(window, GWLP_USERDATA, 0);
        /* CreateWindowExW can fail before its return value is published.
         * Only a published window transfers its reservation here. */
        if (surface && surface->window == window) {
            surface->window = NULL;
            pet_release(surface->resources, PET_RESOURCE_WINDOW, 1);
        }
    }
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

static HDC create_memory_dc(const pet_resources *resources) {
    if (!pet_reserve(resources, PET_RESOURCE_MEMORY_DC, 1)) return NULL;
    HDC dc = CreateCompatibleDC(NULL);
    if (!dc) pet_release(resources, PET_RESOURCE_MEMORY_DC, 1);
    return dc;
}

static BOOL delete_memory_dc(const pet_resources *resources, HDC dc) {
    if (!dc) return TRUE;
    if (DeleteDC(dc)) {
        pet_release(resources, PET_RESOURCE_MEMORY_DC, 1);
        return TRUE;
    }
    pet_cleanup_failed(resources, PET_RESOURCE_MEMORY_DC);
    return FALSE;
}

static HDC borrow_desktop_dc(const pet_resources *resources) {
    if (!pet_reserve(resources, PET_RESOURCE_DESKTOP_DC, 1)) return NULL;
    HDC dc = GetDC(NULL);
    if (!dc) pet_release(resources, PET_RESOURCE_DESKTOP_DC, 1);
    return dc;
}

static BOOL return_desktop_dc(const pet_resources *resources, HDC dc) {
    if (ReleaseDC(NULL, dc)) {
        pet_release(resources, PET_RESOURCE_DESKTOP_DC, 1);
        return TRUE;
    }
    pet_cleanup_failed(resources, PET_RESOURCE_DESKTOP_DC);
    return FALSE;
}

pet_surface_result pet_surface_menu_begin(pet_surface *surface, HANDLE stop) {
    if (!surface || !surface->window || surface->menu_timer) return PET_SURFACE_INVALID;
    if (GetCurrentThreadId() != surface->owner_thread) return PET_SURFACE_WRONG_THREAD;
    if (!pet_reserve(surface->resources, PET_RESOURCE_MENU_TIMER, 1)) return PET_SURFACE_OS_ERROR;
    UINT_PTR timer = SetTimer(surface->window, 1, PET_MENU_CHECK_MS, NULL);
    if (!timer) {
        pet_release(surface->resources, PET_RESOURCE_MENU_TIMER, 1);
        return PET_SURFACE_OS_ERROR;
    }
    surface->menu_timer = timer;
    surface->menu_stop = stop;
    surface->menu_cancelled = FALSE;
    surface->menu_last_input = GetTickCount64();
    surface->menu_cursor_known = GetCursorPos(&surface->menu_cursor);
    return PET_SURFACE_OK;
}

pet_surface_result pet_surface_menu_end(pet_surface *surface) {
    if (!surface) return PET_SURFACE_INVALID;
    if (surface->owner_thread && GetCurrentThreadId() != surface->owner_thread) return PET_SURFACE_WRONG_THREAD;
    if (!surface->menu_timer) return PET_SURFACE_OK;
    UINT_PTR timer = surface->menu_timer;
    surface->menu_timer = 0;
    surface->menu_stop = NULL;
    surface->menu_cursor_known = FALSE;
    if (!KillTimer(surface->window, timer)) {
        pet_cleanup_failed(surface->resources, PET_RESOURCE_MENU_TIMER);
        return PET_SURFACE_OS_ERROR;
    }
    pet_release(surface->resources, PET_RESOURCE_MENU_TIMER, 1);
    return PET_SURFACE_OK;
}

unsigned pet_surface_track_menu(pet_surface *surface, HMENU menu, POINT at, HANDLE stop) {
    if (!surface || !surface->window || !menu || !IsWindowVisible(surface->window) ||
        GetCurrentThreadId() != surface->owner_thread || surface->menu_timer ||
        (stop && WaitForSingleObject(stop, 0) != WAIT_TIMEOUT)) return 0;
    HWND window = surface->window;
    HWND previous = GetForegroundWindow();
    DWORD previous_pid = 0;
    DWORD previous_thread = previous ? GetWindowThreadProcessId(previous, &previous_pid) : 0;
    unsigned command = 0;
    /* Explicit right-click only. Retain WS_EX_NOACTIVATE for normal use.
     * Never bypass the OS foreground policy with input injection. */
    if (previous != window) (void)SetForegroundWindow(window);
    if (GetForegroundWindow() == window &&
        pet_surface_menu_begin(surface, stop) == PET_SURFACE_OK) {
        command = (unsigned)TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
            at.x, at.y, window, NULL);
        if (surface->menu_cancelled) command = 0;
        if (pet_surface_menu_end(surface) != PET_SURFACE_OK) command = 0;
        /* Required foreground-menu dismissal/reopen workaround. */
        if (!PostMessageW(window, WM_NULL, 0, 0))
            pet_note(surface->resources, PET_NOTE_IO_FAILURE);
    } else {
        pet_note(surface->resources, PET_NOTE_BACKPRESSURE);
    }
    /* If an outside click selected a different application, do not steal
     * focus back. Revalidate the saved HWND's process/thread identity. */
    if (previous && previous != window && previous_thread && IsWindow(previous) &&
        GetForegroundWindow() == window) {
        DWORD pid = 0;
        if (GetWindowThreadProcessId(previous, &pid) == previous_thread && pid == previous_pid)
            (void)SetForegroundWindow(previous);
    }
    return command;
}

pet_surface_result pet_surface_close(pet_surface *surface) {
    if (!surface) return PET_SURFACE_INVALID;
    if (!surface->owner_thread) return PET_SURFACE_OK;
    if (GetCurrentThreadId() != surface->owner_thread) return PET_SURFACE_WRONG_THREAD;
    BOOL timer_ok = pet_surface_menu_end(surface) == PET_SURFACE_OK;
    if (surface->window) {
        if (!IsWindow(surface->window) || !DestroyWindow(surface->window)) {
            pet_cleanup_failed(surface->resources, PET_RESOURCE_WINDOW);
            return PET_SURFACE_OS_ERROR;
        }
        if (surface->window) {
            /* A successful destroy must have synchronously delivered NCDESTROY. */
            pet_cleanup_failed(surface->resources, PET_RESOURCE_WINDOW);
            surface->window = NULL;
            return PET_SURFACE_OS_ERROR;
        }
    }
    if (surface->memory_dc && surface->previous)
        SelectObject(surface->memory_dc, surface->previous);
    /* Deleting the DC first also releases a selected bitmap if restoration
     * failed. Never delete the previous stock bitmap. */
    BOOL ok = delete_memory_dc(surface->resources, surface->memory_dc);
    if (surface->bitmap) {
        if (DeleteObject(surface->bitmap))
            pet_release(surface->resources, PET_RESOURCE_DIB, (size_t)surface->width * surface->height * 4u);
        else {
            pet_cleanup_failed(surface->resources, PET_RESOURCE_DIB);
            ok = FALSE;
        }
    }
    *surface = (pet_surface){0};
    return ok && timer_ok ? PET_SURFACE_OK : PET_SURFACE_OS_ERROR;
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
    if (!pet_reserve(surface->resources, PET_RESOURCE_WINDOW, 1)) goto fail;
    surface->window = CreateWindowExW(ex, class_name, L"Pulse companion",
        WS_POPUP, 0, 0, (int)surface->width, (int)surface->height,
        NULL, NULL, module, surface);
    if (!surface->window) {
        pet_release(surface->resources, PET_RESOURCE_WINDOW, 1);
        goto fail;
    }
    surface->memory_dc = create_memory_dc(surface->resources);
    if (!surface->memory_dc) goto fail;
    BITMAPINFO info = {0};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = (LONG)surface->width;
    info.bmiHeader.biHeight = -(LONG)surface->height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void *pixels = NULL;
    size_t dib_bytes = (size_t)surface->width * surface->height * 4u;
    if (!pet_reserve(surface->resources, PET_RESOURCE_DIB, dib_bytes)) goto fail;
    surface->bitmap = CreateDIBSection(surface->memory_dc, &info, DIB_RGB_COLORS,
        &pixels, NULL, 0);
    if (!surface->bitmap) {
        pet_release(surface->resources, PET_RESOURCE_DIB, dib_bytes);
        goto fail;
    }
    if (!pixels) goto fail;
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
    HDC desktop = borrow_desktop_dc(surface->resources);
    if (!desktop) return PET_SURFACE_OS_ERROR;
    BOOL ok = UpdateLayeredWindow(surface->window, desktop, &position, &size,
        surface->memory_dc, &origin, 0, &blend, ULW_ALPHA);
    (void)return_desktop_dc(surface->resources, desktop);
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
    HDC dc = create_memory_dc(surface->resources);
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
    size_t dib_bytes = (size_t)width * height * 4u;
    if (!pet_reserve(surface->resources, PET_RESOURCE_DIB, dib_bytes)) goto cleanup;
    bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &pixels, NULL, 0);
    if (!bitmap) {
        pet_release(surface->resources, PET_RESOURCE_DIB, dib_bytes);
        goto cleanup;
    }
    if (!pixels) goto cleanup;
    previous = SelectObject(dc, bitmap);
    if (!previous || previous == HGDI_ERROR) { previous = NULL; goto cleanup; }
    result = frame_scaled(atlas, atlas_bytes, 8,
        version == 1 ? 9u : (version == 2 ? 11u : 0u), row, column, pixels,
        (size_t)width * height * 4u, width, height);
    if (result != PET_SURFACE_OK) goto cleanup;
    POINT position = {x, y}, origin = {0, 0};
    SIZE size = {(LONG)width, (LONG)height};
    BLENDFUNCTION blend = {AC_SRC_OVER, 0, opacity, AC_SRC_ALPHA};
    HDC desktop = borrow_desktop_dc(surface->resources);
    result = PET_SURFACE_OS_ERROR;
    if (!desktop) goto cleanup;
    BOOL ok = UpdateLayeredWindow(surface->window, desktop, &position, &size,
        dc, &origin, 0, &blend, ULW_ALPHA);
    (void)return_desktop_dc(surface->resources, desktop);
    if (!ok) goto cleanup;

    SelectObject(surface->memory_dc, surface->previous);
    (void)delete_memory_dc(surface->resources, surface->memory_dc);
    if (DeleteObject(surface->bitmap))
        pet_release(surface->resources, PET_RESOURCE_DIB, (size_t)surface->width * surface->height * 4u);
    else pet_cleanup_failed(surface->resources, PET_RESOURCE_DIB);
    surface->memory_dc = dc;
    surface->bitmap = bitmap;
    surface->previous = previous;
    surface->pixels = pixels;
    surface->width = width;
    surface->height = height;
    return PET_SURFACE_OK;
cleanup:
    if (previous) SelectObject(dc, previous);
    (void)delete_memory_dc(surface->resources, dc);
    if (bitmap) {
        if (DeleteObject(bitmap)) pet_release(surface->resources, PET_RESOURCE_DIB, dib_bytes);
        else pet_cleanup_failed(surface->resources, PET_RESOURCE_DIB);
    }
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
