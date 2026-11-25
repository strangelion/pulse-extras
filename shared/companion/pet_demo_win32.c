#include "pet_demo_win32.h"
#include "pet_config_win32.h"
#include <shellapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include <limits.h>

#define ATLAS_WIDTH 1536u

/* Original geometric fixture, not imported art. Fill each cell in advance
 * once; no disk asset or dependency is required for the default demo. */
static uint8_t *synthetic_atlas(size_t *bytes) {
    *bytes = (size_t)ATLAS_WIDTH * 2288u * 4u;
    uint8_t *atlas = calloc(1, *bytes);
    if (!atlas) return NULL;
    for (unsigned row = 0; row < 11; ++row) {
        for (unsigned col = 0; col < 8; ++col) {
            int bob = (int)(col % 4) * 3;
            for (int y = 0; y < (int)PET_FRAME_HEIGHT; ++y) {
                for (int x = 0; x < (int)PET_FRAME_WIDTH; ++x) {
                    int dx = x - 96, dy = y - 112 + bob;
                    int body = dx * dx * 100 + dy * dy * 80 < 70 * 70 * 100;
                    int ear = y > 27 - bob && y < 85 - bob &&
                        (abs(x - 49) < (y - 26 + bob) / 2 ||
                         abs(x - 143) < (y - 26 + bob) / 2);
                    if (!body && !ear) continue;
                    size_t off = ((size_t)(row * PET_FRAME_HEIGHT + (unsigned)y) * ATLAS_WIDTH +
                        col * PET_FRAME_WIDTH + (unsigned)x) * 4u;
                    uint8_t *p = atlas + off;
                    p[0] = (uint8_t)(row == 3 ? 245 : 184);
                    p[1] = (uint8_t)(row == 3 ? 177 : 215);
                    p[2] = (uint8_t)(row == 3 ? 110 : 232);
                    p[3] = 255;
                    int eye = y >= 90 - bob && y <= 100 - bob &&
                        (abs(x - 72) <= 5 || abs(x - 120) <= 5);
                    if (eye || (abs(dx) < 8 && abs(dy - 4) < 3)) {
                        p[0] = 37; p[1] = 47; p[2] = 61;
                    }
                }
            }
        }
    }
    return atlas;
}

static LONG clamp_long(int64_t value) {
    if (value < LONG_MIN) return LONG_MIN;
    if (value > LONG_MAX) return LONG_MAX;
    return (LONG)value;
}

static int parse_scale(const wchar_t *text, unsigned *value) {
    unsigned n = 0;
    if (!text || !*text) return 0;
    for (; *text; ++text) {
        if (*text < L'0' || *text > L'9' || n > PET_MAX_SCALE) return 0;
        n = n * 10 + (unsigned)(*text - L'0');
    }
    if (n < PET_MIN_SCALE || n > PET_MAX_SCALE) return 0;
    *value = n;
    return 1;
}

static int work_area(POINT point, RECT *work) {
    HMONITOR monitor = MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info = {0};
    info.cbSize = sizeof(info);
    if (!monitor || !GetMonitorInfoW(monitor, &info)) return 0;
    *work = info.rcWork;
    return 1;
}

static int constrain(const pet_surface *surface, POINT anchor, LONG *x, LONG *y) {
    RECT work;
    return work_area(anchor, &work) &&
        pet_clamp_position(&work, surface->width, surface->height, x, y) == PET_SURFACE_OK;
}

/* Only use explicitly inherited wait handles from a trusted launcher.
 * The caller must not supply mutexes, auto-reset events or arbitrary handles. */
static HANDLE parse_stop_handle(const wchar_t *text) {
    uintptr_t n = 0;
    if (!text || !*text) return NULL;
    for (; *text; ++text) {
        if (*text < L'0' || *text > L'9') return NULL;
        unsigned digit = (unsigned)(*text - L'0');
        if (n > (UINTPTR_MAX - digit) / 10) return NULL;
        n = n * 10 + digit;
    }
    if (!n || n > UINTPTR_MAX / 2) return NULL;
    HANDLE handle = (HANDLE)n;
    DWORD flags = 0;
    if (!GetHandleInformation(handle, &flags) || !(flags & HANDLE_FLAG_INHERIT))
        return NULL;
    return handle;
}

static void usage(void) {
    fputs("pulse-pet-demo [--reduced-motion] [--scale 50..200] [--topmost|--no-topmost] [--remember] [--reset-position] [--webp-v1 FILE | --webp-v2 FILE]\n"
        "Left click: wave. Left drag: move. Right click: exit. --smoke: hidden synthetic test.\n", stderr);
}

int pet_demo_run(pet_demo_sample_fn sample, pet_demo_validate_fn validate) {
    int rc = 1, argc = 0, reduced = 0, smoke = 0, waving = 0;
    unsigned version = 2, scale = 100;
    int topmost = 0, scale_set = 0, topmost_set = 0, reduced_set = 0;
    int remember = 0, reset_position = 0, stopped = 0;
    HANDLE stop = NULL;
    HKEY settings = NULL;
    pet_config saved = {0, 0, 100, 0};
    int can_save = 0;
    const wchar_t *path = NULL;
    uint8_t *atlas = NULL;
    size_t bytes = 0;
    pet_surface surface = {0};
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || !sample || !validate) goto cleanup;
    for (int i = 1; i < argc; ++i) {
        if (wcscmp(argv[i], L"--smoke") == 0 && !smoke) smoke = 1;
        else if (!reduced_set && (wcscmp(argv[i], L"--reduced-motion") == 0 ||
            wcscmp(argv[i], L"--motion") == 0)) {
            reduced = wcscmp(argv[i], L"--reduced-motion") == 0;
            reduced_set = 1;
        } else if (!topmost_set && (wcscmp(argv[i], L"--topmost") == 0 ||
            wcscmp(argv[i], L"--no-topmost") == 0)) {
            topmost = wcscmp(argv[i], L"--topmost") == 0;
            topmost_set = 1;
        } else if (wcscmp(argv[i], L"--remember") == 0 && !remember) remember = 1;
        else if (wcscmp(argv[i], L"--reset-position") == 0 && !reset_position) reset_position = 1;
        else if (wcscmp(argv[i], L"--stop-handle") == 0 && !stop && i + 1 < argc &&
            (stop = parse_stop_handle(argv[i + 1])) != NULL) ++i;
        else if (wcscmp(argv[i], L"--scale") == 0 && !scale_set && i + 1 < argc &&
            parse_scale(argv[i + 1], &scale)) {
            scale_set = 1;
            ++i;
        } else if (!path && i + 1 < argc &&
            (wcscmp(argv[i], L"--webp-v1") == 0 || wcscmp(argv[i], L"--webp-v2") == 0)) {
            version = wcscmp(argv[i], L"--webp-v1") == 0 ? 1u : 2u;
            path = argv[++i];
        } else {
            usage();
            goto cleanup;
        }
    }
    if ((smoke && (path || reduced_set || topmost_set || remember || reset_position)) ||
        (reset_position && !remember)) {
        usage();
        goto cleanup;
    }
    if (stop) {
        DWORD state = WaitForSingleObject(stop, 0);
        if (state == WAIT_OBJECT_0) { rc = 0; goto cleanup; }
        if (state != WAIT_TIMEOUT) goto cleanup;
    }
    if (remember) {
        LSTATUS status = RegOpenKeyExW(HKEY_CURRENT_USER, PET_CONFIG_KEY, 0,
            KEY_QUERY_VALUE | KEY_SET_VALUE, &settings);
        if (status == ERROR_FILE_NOT_FOUND) {
            /* Defer creation until a clean, visible exit. */
            can_save = 1;
        } else if (status == ERROR_SUCCESS) {
            pet_config_result result = pet_config_load(settings, &saved);
            can_save = result == PET_CONFIG_OK || result == PET_CONFIG_MISSING;
            if (result == PET_CONFIG_OK) {
                if (!scale_set) scale = saved.scale;
                if (!topmost_set) topmost = (saved.flags & PET_CONFIG_TOPMOST) != 0;
                if (!reduced_set) reduced = (saved.flags & PET_CONFIG_REDUCED) != 0;
            }
        }
        if (!can_save) fputs("Saved companion settings unavailable or incompatible; using defaults without overwrite.\n", stderr);
    }
    /* Process-local DPI policy before window creation. No host mutation. */
    /* Per-monitor awareness keeps the explicit physical pixel scale stable.
     * Use the older system-aware API only if the newer context is unavailable. */
    if (!SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2))
        (void)SetProcessDPIAware();
    atlas = path ? pet_demo_load_webp(path, version, validate, &bytes) : synthetic_atlas(&bytes);
    if (!atlas) goto cleanup;
    if (pet_surface_open_scaled(&surface, topmost, FALSE, scale) != PET_SURFACE_OK) goto cleanup;
    RECT work = {0};
    if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0)) goto cleanup;
    LONG x = clamp_long((int64_t)work.right - surface.width - 24);
    LONG y = clamp_long((int64_t)work.bottom - surface.height - 24);
    if (pet_clamp_position(&work, surface.width, surface.height, &x, &y) != PET_SURFACE_OK)
        goto cleanup;
    if (remember && !reset_position && (saved.flags & PET_CONFIG_POSITION)) {
        x = saved.x; y = saved.y;
        POINT center = {clamp_long((int64_t)x + surface.width / 2),
            clamp_long((int64_t)y + surface.height / 2)};
        if (!constrain(&surface, center, &x, &y)) goto cleanup;
    }
    POINT press = {0}, cursor = {0};
    LONG press_x = 0, press_y = 0;
    int pressed = 0, dragged = 0;
    uint64_t started = GetTickCount64(), smoke_end = started + 500;
    unsigned last_row = UINT32_MAX, last_column = UINT32_MAX, frames = 0;
    int shown = 0, done = 0;
    if (smoke) waving = 1;
    while (!done) {
        if (stop) {
            DWORD state = WaitForSingleObject(stop, 0);
            if (state == WAIT_OBJECT_0) { stopped = 1; break; }
            if (state != WAIT_TIMEOUT) goto cleanup;
        }
        MSG message;
        /* Bound message processing per iteration so input cannot starve the
         * timeline or the smoke-test deadline. */
        for (unsigned n = 0; n < 64 && PeekMessageW(&message, NULL, 0, 0, PM_REMOVE); ++n) {
            if (message.message == WM_QUIT ||
                (message.hwnd == surface.window &&
                 (message.message == WM_CLOSE || message.message == WM_RBUTTONUP))) {
                done = 1;
                break;
            }
            if (message.hwnd == surface.window) {
                if (message.message == WM_LBUTTONDOWN && GetCursorPos(&press)) {
                    press_x = x;
                    press_y = y;
                    dragged = 0;
                    SetCapture(surface.window);
                    pressed = GetCapture() == surface.window;
                } else if (message.message == WM_MOUSEMOVE && pressed &&
                    GetCapture() == surface.window && GetCursorPos(&cursor)) {
                    int64_t dx = (int64_t)cursor.x - press.x;
                    int64_t dy = (int64_t)cursor.y - press.y;
                    if (dragged || dx > 4 || dx < -4 || dy > 4 || dy < -4) {
                        dragged = 1;
                        LONG nx = clamp_long((int64_t)press_x + dx);
                        LONG ny = clamp_long((int64_t)press_y + dy);
                        if (!constrain(&surface, cursor, &nx, &ny)) goto cleanup;
                        if (nx != x || ny != y) {
                            if (pet_surface_move(&surface, nx, ny) != PET_SURFACE_OK) goto cleanup;
                            x = nx; y = ny;
                        }
                    }
                } else if (message.message == WM_LBUTTONUP && pressed) {
                    if (GetCapture() == surface.window) {
                        ReleaseCapture();
                        if (!dragged) {
                            waving = 1;
                            started = GetTickCount64();
                        }
                    }
                    pressed = 0;
                }
            }
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        if (done || (shown && !IsWindowVisible(surface.window))) break;
        if (pressed && GetCapture() != surface.window) pressed = 0;
        if (surface.placement_dirty) {
            surface.placement_dirty = FALSE;
            POINT center = {clamp_long((int64_t)x + surface.width / 2),
                clamp_long((int64_t)y + surface.height / 2)};
            LONG nx = x, ny = y;
            if (!constrain(&surface, center, &nx, &ny)) goto cleanup;
            if (nx != x || ny != y) {
                if (surface.primed && pet_surface_move(&surface, nx, ny) != PET_SURFACE_OK)
                    goto cleanup;
                x = nx; y = ny;
            }
        }
        uint64_t now = GetTickCount64();
        if (smoke && now >= smoke_end) break;
        pet_demo_sample point = {0};
        if (sample(version, (uint32_t)waving, now - started, reduced, &point)) goto cleanup;
        if (point.row != last_row || point.column != last_column) {
            if (pet_surface_present(&surface, atlas, bytes, version, point.row,
                point.column, x, y, 255) != PET_SURFACE_OK) goto cleanup;
            last_row = point.row;
            last_column = point.column;
            ++frames;
        }
        if (!smoke && !shown) {
            if (pet_surface_show(&surface, TRUE) != PET_SURFACE_OK) goto cleanup;
            shown = 1;
        }
        DWORD wait = point.wait_ms ? point.wait_ms : INFINITE;
        if (smoke && (uint64_t)wait > smoke_end - now) wait = (DWORD)(smoke_end - now);
        DWORD result = MsgWaitForMultipleObjectsEx(stop ? 1 : 0,
            stop ? &stop : NULL, wait, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        if (stop && result == WAIT_OBJECT_0) { stopped = 1; break; }
        if (result == WAIT_FAILED || (stop && result == WAIT_ABANDONED_0)) goto cleanup;
    }
    if (smoke && !stopped && frames < 2) {
        fputs("Hidden smoke test did not advance the animation.\n", stderr);
        goto cleanup;
    }
    rc = 0;
    if (remember && can_save && shown) {
        if (!settings && RegCreateKeyExW(HKEY_CURRENT_USER, PET_CONFIG_KEY, 0, NULL,
            REG_OPTION_NON_VOLATILE, KEY_QUERY_VALUE | KEY_SET_VALUE, NULL, &settings,
            NULL) != ERROR_SUCCESS) settings = NULL;
        pet_config next = {x, y, scale, PET_CONFIG_POSITION |
            (topmost ? PET_CONFIG_TOPMOST : 0) | (reduced ? PET_CONFIG_REDUCED : 0)};
        if (!settings || pet_config_save(settings, &next) != PET_CONFIG_OK)
            fputs("Companion settings not saved; existing incompatible data preserved.\n", stderr);
    }
cleanup:
    if (settings) RegCloseKey(settings);
    if (stop) CloseHandle(stop);
    if (surface.window && GetCapture() == surface.window) ReleaseCapture();
    if (pet_surface_close(&surface) != PET_SURFACE_OK) rc = 1;
    free(atlas);
    if (argv) LocalFree(argv);
    return rc;
}
