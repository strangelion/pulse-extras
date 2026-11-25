#include "pet_demo_win32.h"
#include "pet_config_win32.h"
#include "pet_state_win32.h"
#include "pet_menu_strings_win32.h"
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

static int parse_activity_number(const wchar_t *text, unsigned limit, unsigned *value) {
    unsigned n = 0;
    if (!text || !*text) return 0;
    for (; *text; ++text) {
        if (*text < L'0' || *text > L'9' || n > limit) return 0;
        n = n * 10 + (unsigned)(*text - L'0');
    }
    if (!n || n > limit) return 0;
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
static HANDLE parse_inherited_handle(const wchar_t *text) {
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

enum {
    MENU_TOPMOST = 100, MENU_REDUCED, MENU_RESET, MENU_INTERACT,
    MENU_EXIT, MENU_ACTIVITY_FIRST = 300, MENU_SCALE_50 = 200, MENU_SCALE_75, MENU_SCALE_100,
    MENU_SCALE_125, MENU_SCALE_150, MENU_SCALE_200
};

static const unsigned menu_scales[] = {50, 75, 100, 125, 150, 200};

/* Menu belongs to the pet, not the host. No external commands or hooks.
 * A modal menu can delay cooperative stop until dismissal; the parent
 * still owns the bounded job termination fallback. */
static unsigned pet_menu(HWND window, POINT at, unsigned scale, int topmost,
    int reduced, int managed, pet_language language, const pet_package *package) {
    pet_menu_strings strings = pet_menu_labels(language, GetUserDefaultUILanguage());
    HMENU menu = CreatePopupMenu();
    HMENU sizes = CreatePopupMenu();
    if (!menu || !sizes) {
        if (menu) DestroyMenu(menu);
        if (sizes) DestroyMenu(sizes);
        return 0;
    }
    const wchar_t *labels[] = {L"50%", L"75%", L"100%", L"125%", L"150%", L"200%"};
    for (unsigned i = 0; i < sizeof(menu_scales) / sizeof(menu_scales[0]); ++i) {
        if (!AppendMenuW(sizes, MF_STRING | (scale == menu_scales[i] ? MF_CHECKED : 0),
            MENU_SCALE_50 + i, labels[i])) {
            DestroyMenu(sizes); DestroyMenu(menu); return 0;
        }
    }
    if (!AppendMenuW(menu, MF_POPUP, (UINT_PTR)sizes, strings.size)) {
        DestroyMenu(sizes); DestroyMenu(menu); return 0;
    }
    if (package && package->meta.count) {
        HMENU actions = CreatePopupMenu();
        if (!actions) { DestroyMenu(menu); return 0; }
        for (unsigned i = 0; i < package->meta.count; ++i) {
            wchar_t name[161], escaped[321];
            int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                (const char *)package->meta.items[i].name, -1, name, 161);
            if (!n) { DestroyMenu(actions); DestroyMenu(menu); return 0; }
            size_t j = 0;
            for (int k = 0; k < n - 1; ++k) {
                if (name[k] == L'&') escaped[j++] = L'&';
                escaped[j++] = name[k];
            }
            escaped[j] = 0;
            if (!AppendMenuW(actions, MF_STRING | (managed || reduced ? MF_GRAYED : 0),
                MENU_ACTIVITY_FIRST + i, escaped)) {
                DestroyMenu(actions); DestroyMenu(menu); return 0;
            }
        }
        if (!AppendMenuW(menu, MF_POPUP, (UINT_PTR)actions, strings.activities)) {
            DestroyMenu(actions); DestroyMenu(menu); return 0;
        }
    }
    if (!AppendMenuW(menu, MF_STRING | (topmost ? MF_CHECKED : 0), MENU_TOPMOST, strings.topmost) ||
        !AppendMenuW(menu, MF_STRING | (reduced ? MF_CHECKED : 0), MENU_REDUCED, strings.reduced) ||
        !AppendMenuW(menu, MF_STRING, MENU_RESET, strings.reset) ||
        !AppendMenuW(menu, MF_STRING | (managed || reduced ? MF_GRAYED : 0), MENU_INTERACT, strings.interact) ||
        !AppendMenuW(menu, MF_SEPARATOR, 0, NULL) ||
        !AppendMenuW(menu, MF_STRING, MENU_EXIT, strings.exit)) {
        DestroyMenu(menu); return 0;
    }
    unsigned command = (unsigned)TrackPopupMenuEx(menu,
        TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
        at.x, at.y, window, NULL);
    DestroyMenu(menu); /* also destroys attached submenu */
    return command;
}

static void usage(void) {
    fputs("pulse-pet-demo [--reduced-motion] [--language system|zh-CN|zh-TW|en-US] [--scale 50..200] [--topmost|--no-topmost] [--remember] [--reset-position] [--webp-v1 FILE | --webp-v2 FILE] [--activity FILE FRAMES FPS] [--package DIR ID | --check-package DIR ID]\n"
        "Left click: interact. Left drag: move. Right click: menu. --smoke: hidden synthetic test.\n", stderr);
}

int pet_demo_run(pet_demo_sample_fn sample, pet_demo_validate_fn validate,
    pet_activity_sample_fn sample_activity, pet_demo_validate_fn validate_activity,
    pet_package_parse_fn parse_package) {
    int rc = 1, argc = 0, reduced = 0, smoke = 0;
    unsigned reaction = PET_STATE_IDLE;
    unsigned version = 2, scale = 100;
    int topmost = 0, scale_set = 0, topmost_set = 0, reduced_set = 0;
    int remember = 0, reset_position = 0, stopped = 0;
    pet_language language = PET_LANGUAGE_SYSTEM;
    int language_set = 0;
    HANDLE stop = NULL, state_map = NULL, state_event = NULL;
    const volatile LONG *state_slot = NULL;
    DWORD last_word = 0;
    int received_testing = 0;
    HKEY settings = NULL;
    pet_config saved = {0, 0, 100, 0};
    int can_save = 0;
    const wchar_t *path = NULL, *package_dir = NULL, *package_id = NULL;
    int check_package = 0;
    pet_package package = {0};
    uint8_t *atlas = NULL, *activity = NULL;
    const wchar_t *activity_path = NULL;
    unsigned activity_frames = 0, activity_fps = 0;
    size_t bytes = 0, activity_bytes = 0;
    uint64_t activity_started = 0;
    int activity_displayed = 0;
    pet_surface surface = {0};
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || !sample || !validate || !sample_activity || !validate_activity || !parse_package) goto cleanup;
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
            (stop = parse_inherited_handle(argv[i + 1])) != NULL) ++i;
        else if (wcscmp(argv[i], L"--state-map") == 0 && !state_map && i + 1 < argc &&
            (state_map = parse_inherited_handle(argv[i + 1])) != NULL) ++i;
        else if (wcscmp(argv[i], L"--state-event") == 0 && !state_event && i + 1 < argc &&
            (state_event = parse_inherited_handle(argv[i + 1])) != NULL) ++i;
        else if (wcscmp(argv[i], L"--language") == 0 && !language_set && i + 1 < argc &&
            pet_language_parse(argv[i + 1], &language)) {
            language_set = 1;
            ++i;
        } else if (wcscmp(argv[i], L"--scale") == 0 && !scale_set && i + 1 < argc &&
            parse_scale(argv[i + 1], &scale)) {
            scale_set = 1;
            ++i;
        } else if (!package_dir && i + 2 < argc &&
            (wcscmp(argv[i], L"--package") == 0 || wcscmp(argv[i], L"--check-package") == 0)) {
            check_package = wcscmp(argv[i], L"--check-package") == 0;
            package_dir = argv[++i];
            package_id = argv[++i];
        } else if (!activity_path && i + 3 < argc &&
            wcscmp(argv[i], L"--activity") == 0 &&
            parse_activity_number(argv[i + 2], 32, &activity_frames) &&
            parse_activity_number(argv[i + 3], 12, &activity_fps)) {
            activity_path = argv[i + 1];
            i += 3;
        } else if (!path && i + 1 < argc &&
            (wcscmp(argv[i], L"--webp-v1") == 0 || wcscmp(argv[i], L"--webp-v2") == 0)) {
            version = wcscmp(argv[i], L"--webp-v1") == 0 ? 1u : 2u;
            path = argv[++i];
        } else {
            usage();
            goto cleanup;
        }
    }
    pet_demo_sample activity_check = {0};
    if ((package_dir && (path || activity_path || smoke || state_map)) ||
        (check_package && (stop || remember || reset_position)) ||
        (activity_path && (smoke || state_map ||
            sample_activity(activity_frames, activity_fps, 0, &activity_check) != 0)) ||
        (smoke && (path || reduced_set || topmost_set || remember || reset_position)) ||
        (reset_position && !remember) || (!!state_map != !!state_event) ||
        (state_map && (!stop || state_map == stop || state_event == stop || state_map == state_event))) {
        usage();
        goto cleanup;
    }
    if (stop) {
        DWORD state = WaitForSingleObject(stop, 0);
        if (state == WAIT_OBJECT_0) { rc = 0; goto cleanup; }
        if (state != WAIT_TIMEOUT) goto cleanup;
    }
    if (state_map) {
        state_slot = MapViewOfFile(state_map, FILE_MAP_READ, 0, 0, sizeof(LONG));
        if (!state_slot) goto cleanup;
        last_word = pet_state_read(state_slot);
        if (!pet_state_valid(last_word)) goto cleanup;
        reaction = last_word & 15u;
        received_testing = reaction == PET_STATE_TESTING;
    }
    if (package_dir) {
        if (!pet_package_open(&package, package_dir, package_id, parse_package, validate, validate_activity)) {
            fputs("Classic package rejected: metadata, path, inventory or WebP header.\n", stderr);
            goto cleanup;
        }
        version = package.meta.version;
        if (check_package) { rc = 0; goto cleanup; }
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
    atlas = package_dir ? pet_package_load_atlas(&package, validate, &bytes) :
        (path ? pet_demo_load_webp(path, version, validate, &bytes) : synthetic_atlas(&bytes));
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
    unsigned interaction = 0;
    if (smoke && !state_slot) reaction = PET_STATE_WAVING;
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
                (message.hwnd == surface.window && message.message == WM_CLOSE)) {
                done = 1;
                break;
            }
            if (message.hwnd == surface.window) {
                if (message.message == WM_RBUTTONUP && !smoke && shown && GetCursorPos(&cursor)) {
                    if (GetCapture() == surface.window) ReleaseCapture();
                    pressed = 0;
                    /* Opening the menu interrupts optional artwork; restore
                     * the base pose before any live resize. */
                    if (activity || activity_displayed) {
                        free(activity); activity = NULL; activity_bytes = 0;
                        activity_displayed = 0;
                        reaction = PET_STATE_IDLE;
                        started = GetTickCount64();
                        pet_demo_sample base = {0};
                        if (sample(version, reaction, 0, reduced, &base) ||
                            pet_surface_present(&surface, atlas, bytes, version,
                                base.row, base.column, x, y, 255) != PET_SURFACE_OK)
                            goto cleanup;
                        last_row = base.row; last_column = base.column;
                    }
                    unsigned command = pet_menu(surface.window, cursor, scale, topmost,
                        reduced, state_slot != NULL, language, &package);
                    /* Check the owner signal immediately after the modal menu. */
                    if (stop && WaitForSingleObject(stop, 0) == WAIT_OBJECT_0) {
                        stopped = 1; done = 1; break;
                    }
                    if (command == MENU_EXIT) { done = 1; break; }
                    if (command == MENU_TOPMOST) {
                        if (pet_surface_policy(&surface, !topmost, FALSE) == PET_SURFACE_OK)
                            topmost = !topmost;
                        else fputs("Pet z-order update failed.\n", stderr);
                    } else if (command == MENU_REDUCED) {
                        reduced = !reduced;
                        started = GetTickCount64();
                        if (!state_slot) reaction = PET_STATE_IDLE;
                    } else if (command >= MENU_ACTIVITY_FIRST &&
                        command - MENU_ACTIVITY_FIRST < package.meta.count && !state_slot && !reduced) {
                        unsigned index = command - MENU_ACTIVITY_FIRST;
                        activity_frames = package.meta.items[index].frames;
                        activity_fps = package.meta.items[index].fps;
                        activity = pet_package_load_activity(&package, index, validate_activity, &activity_bytes);
                        if (activity) activity_started = GetTickCount64();
                        else fputs("Package activity decode failed; base pose retained.\n", stderr);
                    } else if (command == MENU_INTERACT && !state_slot && !reduced) {
                        if (activity_path) {
                            activity = pet_demo_load_activity(activity_path, activity_frames,
                                validate_activity, &activity_bytes);
                            if (activity) activity_started = GetTickCount64();
                        }
                        if (!activity) {
                            reaction = (++interaction & 1u) ? PET_STATE_WAVING : PET_STATE_SUCCESS;
                            started = GetTickCount64();
                        }
                    } else if (command == MENU_RESET) {
                        RECT area;
                        if (work_area(cursor, &area)) {
                            LONG nx = clamp_long((int64_t)area.right - surface.width - 24);
                            LONG ny = clamp_long((int64_t)area.bottom - surface.height - 24);
                            if (pet_clamp_position(&area, surface.width, surface.height, &nx, &ny) == PET_SURFACE_OK &&
                                pet_surface_move(&surface, nx, ny) == PET_SURFACE_OK) {
                                x = nx; y = ny;
                            } else fputs("Pet position reset failed.\n", stderr);
                        }
                    } else if (command >= MENU_SCALE_50 && command <= MENU_SCALE_200) {
                        unsigned next = menu_scales[command - MENU_SCALE_50];
                        unsigned width = PET_FRAME_WIDTH * next / 100;
                        unsigned height = PET_FRAME_HEIGHT * next / 100;
                        LONG nx = clamp_long((int64_t)x + surface.width - width);
                        LONG ny = clamp_long((int64_t)y + surface.height - height);
                        RECT area;
                        POINT anchor = {clamp_long((int64_t)x + surface.width / 2),
                            clamp_long((int64_t)y + surface.height / 2)};
                        if (next != scale && work_area(anchor, &area)) {
                            if (pet_clamp_position(&area, width, height, &nx, &ny) == PET_SURFACE_OK &&
                                pet_surface_resize(&surface, next, atlas, bytes, version,
                                    last_row, last_column, nx, ny, 255) == PET_SURFACE_OK) {
                                x = nx; y = ny; scale = next;
                            } else fputs("Pet resize failed; previous surface retained.\n", stderr);
                        }
                    }
                } else if (message.message == WM_LBUTTONDOWN && GetCursorPos(&press)) {
                    if (activity) {
                        free(activity); activity = NULL; activity_bytes = 0;
                        reaction = PET_STATE_IDLE;
                        started = GetTickCount64();
                    }
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
                            if (!state_slot && !reduced) {
                                reaction = (++interaction & 1u) ? PET_STATE_WAVING : PET_STATE_SUCCESS;
                                started = GetTickCount64();
                            }
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
        if (state_slot) {
            DWORD word = pet_state_read(state_slot);
            if (!pet_state_valid(word) || (word >> 4) < (last_word >> 4)) goto cleanup;
            if (word != last_word) {
                if ((word >> 4) == (last_word >> 4)) goto cleanup;
                reaction = word & 15u;
                started = now;
                last_word = word;
                if (reaction == PET_STATE_TESTING) received_testing = 1;
            }
        }
        if (smoke && now >= smoke_end) break;
        pet_demo_sample point = {0};
        if (activity) {
            int result = sample_activity(activity_frames, activity_fps,
                now - activity_started, &point);
            if (result != 0) {
                free(activity); activity = NULL; activity_bytes = 0;
                reaction = PET_STATE_IDLE;
                started = now;
                if (result < 0) fputs("Invalid activity timeline.\n", stderr);
            }
        }
        if (activity) {
            if (!activity_displayed || point.column != last_column) {
                if (pet_surface_present_activity(&surface, activity, activity_bytes,
                    activity_frames, point.column, x, y, 255) != PET_SURFACE_OK)
                    goto cleanup;
                activity_displayed = 1;
                last_column = point.column;
                ++frames;
            }
        } else {
            if (sample(version, reaction, now - started, reduced, &point)) goto cleanup;
            if (activity_displayed || point.row != last_row || point.column != last_column) {
                if (pet_surface_present(&surface, atlas, bytes, version, point.row,
                    point.column, x, y, 255) != PET_SURFACE_OK) goto cleanup;
                activity_displayed = 0;
                last_row = point.row;
                last_column = point.column;
                ++frames;
            }
        }
        if (!smoke && !shown) {
            if (pet_surface_show(&surface, TRUE) != PET_SURFACE_OK) goto cleanup;
            shown = 1;
        }
        DWORD wait = point.wait_ms ? point.wait_ms : INFINITE;
        if (smoke && (uint64_t)wait > smoke_end - now) wait = (DWORD)(smoke_end - now);
        HANDLE waits[2] = {stop, state_event};
        DWORD count = state_event ? 2 : (stop ? 1 : 0);
        DWORD result = MsgWaitForMultipleObjectsEx(count,
            count ? waits : NULL, wait, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        if (stop && result == WAIT_OBJECT_0) { stopped = 1; break; }
        if (result == WAIT_FAILED || (count && result >= WAIT_ABANDONED_0 && result < WAIT_ABANDONED_0 + count)) goto cleanup;
    }
    if (smoke && !stopped && (frames < 2 || (state_slot && !received_testing))) {
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
    if (state_slot) UnmapViewOfFile((const void *)state_slot);
    if (state_event && state_event != stop) CloseHandle(state_event);
    if (state_map && state_map != stop && state_map != state_event) CloseHandle(state_map);
    if (stop) CloseHandle(stop);
    if (surface.window && GetCapture() == surface.window) ReleaseCapture();
    if (pet_surface_close(&surface) != PET_SURFACE_OK) rc = 1;
    free(activity);
    free(atlas);
    pet_package_close(&package);
    if (argv) LocalFree(argv);
    return rc;
}
