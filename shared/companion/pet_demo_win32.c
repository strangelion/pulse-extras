#include "pet_demo_win32.h"
#include "pet_config_win32.h"
#include "pet_state_win32.h"
#include "pet_menu_strings_win32.h"
#include "pet_idle_policy.h"
#include "pet_wardrobe_clock.h"
#include "pet_gaze_policy.h"
#include "pet_crash_watch_win32.h"
#include <shellapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <limits.h>

#define ATLAS_WIDTH 1536u

/* Original geometric fixture, not imported art. Fill each cell in advance
 * once; no disk asset or dependency is required for the default demo. */
static uint8_t *synthetic_atlas(const pet_memory *memory, size_t *bytes) {
    *bytes = (size_t)ATLAS_WIDTH * 2288u * 4u;
    uint8_t *atlas = pet_alloc(memory, *bytes);
    if (!atlas) return NULL;
    memset(atlas, 0, *bytes);
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
static HANDLE parse_inherited_handle(const pet_resources *resources, const wchar_t *text,
    HANDLE other_a, HANDLE other_b, HANDLE other_c) {
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
    if (handle != other_a && handle != other_b && handle != other_c && !pet_reserve(resources, PET_RESOURCE_IPC, 1)) {
        if (!CloseHandle(handle)) pet_cleanup_failed(resources, PET_RESOURCE_IPC);
        return NULL;
    }
    return handle;
}

static void close_ipc(const pet_resources *resources, HANDLE handle) {
    if (!handle) return;
    if (CloseHandle(handle)) pet_release(resources, PET_RESOURCE_IPC, 1);
    else pet_cleanup_failed(resources, PET_RESOURCE_IPC);
}

static LSTATUS open_settings(const pet_resources *resources, HKEY *key) {
    *key = NULL;
    if (!pet_reserve(resources, PET_RESOURCE_REGISTRY, 1)) return ERROR_NOT_ENOUGH_MEMORY;
    LSTATUS status = RegOpenKeyExW(HKEY_CURRENT_USER, PET_CONFIG_KEY, 0,
        KEY_QUERY_VALUE | KEY_SET_VALUE, key);
    if (status != ERROR_SUCCESS) {
        *key = NULL;
        pet_release(resources, PET_RESOURCE_REGISTRY, 1);
    }
    return status;
}

static LSTATUS create_settings(const pet_resources *resources, HKEY *key) {
    *key = NULL;
    if (!pet_reserve(resources, PET_RESOURCE_REGISTRY, 1)) return ERROR_NOT_ENOUGH_MEMORY;
    LSTATUS status = RegCreateKeyExW(HKEY_CURRENT_USER, PET_CONFIG_KEY, 0, NULL,
        REG_OPTION_NON_VOLATILE, KEY_QUERY_VALUE | KEY_SET_VALUE, NULL, key, NULL);
    if (status != ERROR_SUCCESS) {
        *key = NULL;
        pet_release(resources, PET_RESOURCE_REGISTRY, 1);
    }
    return status;
}

static void close_settings(const pet_resources *resources, HKEY key) {
    if (!key) return;
    if (RegCloseKey(key) == ERROR_SUCCESS) pet_release(resources, PET_RESOURCE_REGISTRY, 1);
    else pet_cleanup_failed(resources, PET_RESOURCE_REGISTRY);
}

enum {
    MENU_TOPMOST = 100, MENU_REDUCED, MENU_RESET, MENU_INTERACT,
    MENU_EXIT, MENU_GAZE, MENU_ACTIVITY_FIRST = 300, MENU_AUTO_FIRST = 400, MENU_OUTFIT_FIRST = 500, MENU_OUTFIT_AUTO = 517, MENU_SCALE_50 = 200, MENU_SCALE_75, MENU_SCALE_100,
    MENU_SCALE_125, MENU_SCALE_150, MENU_SCALE_200
};

static const unsigned menu_scales[] = {50, 75, 100, 125, 150, 200};

static HMENU tracked_menu(const pet_resources *resources) {
    if (!pet_reserve(resources, PET_RESOURCE_MENU, 1)) return NULL;
    HMENU menu = CreatePopupMenu();
    if (!menu) pet_release(resources, PET_RESOURCE_MENU, 1);
    return menu;
}

static BOOL destroy_menu(const pet_resources *resources, HMENU menu, unsigned count) {
    if (!menu) return TRUE;
    if (!DestroyMenu(menu)) {
        pet_cleanup_failed(resources, PET_RESOURCE_MENU);
        return FALSE;
    }
    pet_release(resources, PET_RESOURCE_MENU, count);
    return TRUE;
}

/* Menu belongs to the pet, not the host. No external commands or hooks.
 * A modal menu can delay cooperative stop until dismissal; the parent
 * still owns the bounded job termination fallback. */
static unsigned pet_menu(const pet_resources *resources, pet_surface *surface, HANDLE stop, POINT at, unsigned scale, int topmost,
    int reduced, int managed, pet_language language, const pet_package *package,
    const pet_idle_policy *idle, unsigned outfit, int auto_outfit, int gaze_supported,
    int gaze_enabled, int display, int *built) {
    if (built) *built = 0;
    unsigned attached = 1;
    pet_menu_strings strings = pet_menu_labels(language, GetUserDefaultUILanguage());
    HMENU menu = tracked_menu(resources);
    HMENU sizes = tracked_menu(resources);
    if (!menu || !sizes) {
        if (menu) destroy_menu(resources, menu, attached);
        if (sizes) destroy_menu(resources, sizes, 1);
        return 0;
    }
    const wchar_t *labels[] = {L"50%", L"75%", L"100%", L"125%", L"150%", L"200%"};
    for (unsigned i = 0; i < sizeof(menu_scales) / sizeof(menu_scales[0]); ++i) {
        if (!AppendMenuW(sizes, MF_STRING | (scale == menu_scales[i] ? MF_CHECKED : 0),
            MENU_SCALE_50 + i, labels[i])) {
            destroy_menu(resources, sizes, 1); destroy_menu(resources, menu, attached); return 0;
        }
    }
    /* Native radio selection makes mutually exclusive sizes distinguishable
     * from the independent toggles below; arbitrary custom scale has no
     * falsely checked preset. The original checked menu remains fallback. */
    for (unsigned i = 0; i < sizeof(menu_scales) / sizeof(menu_scales[0]); ++i) {
        if (scale == menu_scales[i]) {
            (void)pulse_menu_mark_radio(sizes, MENU_SCALE_50 + i);
            break;
        }
    }
    if (!AppendMenuW(menu, MF_POPUP, (UINT_PTR)sizes, strings.size)) {
        destroy_menu(resources, sizes, 1); destroy_menu(resources, menu, attached); return 0;
    }
    ++attached;
    if (package && package->meta.outfit_count) {
        HMENU outfits = tracked_menu(resources);
        if (!outfits) { destroy_menu(resources, menu, attached); return 0; }
        if (package->meta.rule_count &&
            (!AppendMenuW(outfits, MF_STRING | (auto_outfit ? MF_CHECKED : 0),
                MENU_OUTFIT_AUTO, strings.auto_outfit) ||
             !AppendMenuW(outfits, MF_SEPARATOR, 0, NULL))) {
            destroy_menu(resources, outfits, 1); destroy_menu(resources, menu, attached); return 0;
        }
        if (!AppendMenuW(outfits, MF_STRING | (!auto_outfit && !outfit ? MF_CHECKED : 0),
            MENU_OUTFIT_FIRST, strings.default_outfit)) {
            destroy_menu(resources, outfits, 1); destroy_menu(resources, menu, attached); return 0;
        }
        for (unsigned i = 0; i < package->meta.outfit_count; ++i) {
            wchar_t name[161], escaped[321];
            if (!pulse_menu_escape_utf8((const char *)package->meta.outfits[i].name,
                name, 161, escaped, 321)) { destroy_menu(resources, outfits, 1); destroy_menu(resources, menu, attached); return 0; }
            if (!AppendMenuW(outfits, MF_STRING | (!auto_outfit && outfit == i + 1 ? MF_CHECKED : 0),
                MENU_OUTFIT_FIRST + i + 1, escaped)) {
                destroy_menu(resources, outfits, 1); destroy_menu(resources, menu, attached); return 0;
            }
        }
        if (auto_outfit && package->meta.rule_count)
            (void)pulse_menu_mark_radio(outfits, MENU_OUTFIT_AUTO);
        else if (!auto_outfit && outfit <= package->meta.outfit_count)
            (void)pulse_menu_mark_radio(outfits, MENU_OUTFIT_FIRST + outfit);
        if (!AppendMenuW(menu, MF_POPUP, (UINT_PTR)outfits, strings.outfit)) {
            destroy_menu(resources, outfits, 1); destroy_menu(resources, menu, attached); return 0;
        }
        ++attached;
    }
    if (package && package->meta.count) {
        HMENU actions = tracked_menu(resources);
        if (!actions) { destroy_menu(resources, menu, attached); return 0; }
        HMENU automatic = tracked_menu(resources);
        if (!automatic) { destroy_menu(resources, actions, 1); destroy_menu(resources, menu, attached); return 0; }
        for (unsigned i = 0; i < package->meta.count; ++i) {
            wchar_t name[161], escaped[321];
            if (!pulse_menu_escape_utf8((const char *)package->meta.items[i].name,
                name, 161, escaped, 321)) { destroy_menu(resources, automatic, 1); destroy_menu(resources, actions, 1); destroy_menu(resources, menu, attached); return 0; }
            uint32_t bit = pet_idle_bit(i);
            if (!AppendMenuW(actions, MF_STRING |
                    (managed || reduced || ((idle->failed | idle->unavailable) & bit) ? MF_GRAYED : 0),
                    MENU_ACTIVITY_FIRST + i, escaped) ||
                !AppendMenuW(automatic, MF_STRING |
                    (idle->enabled & bit ? MF_CHECKED : 0) |
                    (managed ? MF_GRAYED : 0),
                    MENU_AUTO_FIRST + i, escaped)) {
                destroy_menu(resources, automatic, 1); destroy_menu(resources, actions, 1); destroy_menu(resources, menu, attached); return 0;
            }
        }
        if (!AppendMenuW(menu, MF_POPUP, (UINT_PTR)actions, strings.activities)) {
            destroy_menu(resources, automatic, 1); destroy_menu(resources, actions, 1); destroy_menu(resources, menu, attached); return 0;
        }
        ++attached;
        if (!AppendMenuW(menu, MF_POPUP, (UINT_PTR)automatic, strings.automatic)) {
            destroy_menu(resources, automatic, 1); destroy_menu(resources, menu, attached); return 0;
        }
        ++attached;
    }
    if (!AppendMenuW(menu, MF_SEPARATOR, 0, NULL) ||
        !AppendMenuW(menu, MF_STRING | (topmost ? MF_CHECKED : 0), MENU_TOPMOST, strings.topmost) ||
        !AppendMenuW(menu, MF_STRING | (reduced ? MF_CHECKED : 0), MENU_REDUCED, strings.reduced) ||
        (gaze_supported && !AppendMenuW(menu, MF_STRING | (gaze_enabled ? MF_CHECKED : 0) |
            (reduced ? MF_GRAYED : 0), MENU_GAZE, strings.gaze)) ||
        !AppendMenuW(menu, MF_SEPARATOR, 0, NULL) ||
        !AppendMenuW(menu, MF_STRING, MENU_RESET, strings.reset) ||
        !AppendMenuW(menu, MF_STRING | (managed || reduced ? MF_GRAYED : 0), MENU_INTERACT, strings.interact) ||
        !AppendMenuW(menu, MF_SEPARATOR, 0, NULL) ||
        !AppendMenuW(menu, MF_STRING, MENU_EXIT, strings.exit)) {
        destroy_menu(resources, menu, attached); return 0;
    }
    unsigned command = display ? pet_surface_track_menu(surface, menu, at, stop) : 0;
    if (destroy_menu(resources, menu, attached)) {
        if (built) *built = 1;
    }
    return command;
}

/* Non-cryptographic variation only; no security decisions use this RNG. */
/* Evaluate only the current local civil time. No catch-up of missed
 * rules after suspend, time-zone change or a clock adjustment. */
static unsigned scheduled_outfit(const pet_package *package, pet_schedule_fn schedule,
    uint32_t *delay) {
    SYSTEMTIME local;
    GetLocalTime(&local);
    if (delay) *delay = pet_wardrobe_wait_ms(local.wSecond, local.wMilliseconds);
    unsigned next = schedule(&package->meta, local.wHour * 60u + local.wMinute,
        local.wDayOfWeek, local.wMonth, local.wDay);
    return next <= package->meta.outfit_count ? next : 0;
}

static uint32_t unavailable_activities(const pet_package *package, unsigned outfit) {
    uint32_t mask = 0;
    for (unsigned i = 0; i < package->meta.count; ++i)
        if (!package->meta.items[i].reps[outfit].frames) mask |= pet_idle_bit(i);
    return mask;
}

static uint32_t activity_random(uint32_t *state) {
    uint32_t x = *state ? *state : UINT32_C(0x9e3779b9);
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
}

static void usage(void) {
    fputs("pulse-pet [--reduced-motion] [--gaze|--no-gaze] [--language system|zh-CN|zh-TW|en-US] [--scale 50..200] [--topmost|--no-topmost] [--remember] [--reset-position] [--webp-v1 FILE | --webp-v2 FILE] [--stress-seconds 10..300 [--stress-hidden] [--stress-slot 1..100]] [--activity FILE FRAMES FPS] [--package DIR ID | --check-package DIR ID | --check-package-task DIR ID]\n"
        "Left click: interact. Left drag: move. Right click: menu. --smoke: hidden synthetic test.\n", stderr);
}

typedef struct {
    const pet_memory *memory;
    const pet_package *package;
    pet_demo_validate_fn validate, validate_activity;
    HANDLE event;
    volatile LONG ready;
} native_decode;

static uint8_t *decode_package(void *userdata, uint32_t kind, uint32_t outfit,
    uint32_t index, size_t *bytes) {
    const native_decode *ctx = userdata;
    if (kind == PET_DECODE_OUTFIT)
        return pet_package_load_atlas(ctx->memory, ctx->package, outfit, ctx->validate, bytes);
    if (kind == PET_DECODE_ACTIVITY)
        return pet_package_load_activity(ctx->memory, ctx->package, index, outfit, ctx->validate_activity, bytes);
    *bytes = 0;
    return NULL;
}

static void decode_notify(void *userdata) {
    native_decode *ctx = userdata;
    InterlockedExchange(&ctx->ready, 1);
    if (!SetEvent(ctx->event))
        pet_cleanup_failed(ctx->memory->resource_bridge, PET_RESOURCE_NOTIFY);
}

static int request_decode(const pet_resources *resources, const pet_async *async,
    unsigned kind, unsigned outfit, unsigned index) {
    int ok = async->submit(async->owner, kind, outfit, index) && async->start(async->owner) >= 0;
    pet_note(resources, ok ? PET_NOTE_ADMITTED : PET_NOTE_BACKPRESSURE);
    return ok;
}

/* Worker has signaled or set its atomic ready flag. Join before reading
 * pixels, reset the event after join, then allow another task to start. */
static int take_decode(const pet_async *async, native_decode *ctx, pet_decode_result *out) {
    if (!InterlockedCompareExchange(&ctx->ready, 0, 0)) return -2;
    int result = async->take(async->owner, out);
    if (result == 0) pet_note(ctx->memory->resource_bridge, PET_NOTE_CANCELLED);
    else if (result == 2 || result < 0) pet_note(ctx->memory->resource_bridge, PET_NOTE_IO_FAILURE);
    InterlockedExchange(&ctx->ready, 0);
    if (!ResetEvent(ctx->event)) {
        pet_cleanup_failed(ctx->memory->resource_bridge, PET_RESOURCE_NOTIFY);
        pet_free(ctx->memory, out->pixels, out->bytes);
        *out = (pet_decode_result){0};
        return -1;
    }
    return result;
}

int pet_demo_run(const pet_memory *memory, const pet_async *async, pet_demo_sample_fn sample, pet_demo_validate_fn validate,
    pet_activity_sample_fn sample_activity, pet_demo_validate_fn validate_activity,
    pet_package_parse_fn parse_package, pet_schedule_fn schedule,
    pet_hash_fn hash, pet_fingerprint_fn fingerprint) {
    if (!memory || !memory->context || !memory->allocate || !memory->release || !memory->resource_bridge ||
        !async || !async->owner || !async->bind || !async->submit || !async->start || !async->take ||
        !async->invalidate || !async->busy || !async->stop) return 1;
    int rc = 1, argc = 0, reduced = 0, smoke = 0, stress_hidden = 0, stress_ready = 0;
    unsigned stress_seconds = 0, stress_slot = 0;
    unsigned reaction = PET_STATE_IDLE;
    unsigned version = 2, scale = 100;
    int gaze_enabled = 1, gaze_supported = 0, gaze_writable = 0, gaze_dirty = 0, gaze_set = 0;
    pet_gaze gaze = {.direction = PET_GAZE_NONE};
    double gaze_x = 0.5, gaze_y = 1.0;
    int topmost = 0, scale_set = 0, topmost_set = 0, reduced_set = 0;
    int remember = 0, reset_position = 0, stopped = 0;
    pet_language language = PET_LANGUAGE_SYSTEM;
    int language_set = 0;
    HANDLE stop = NULL, state_map = NULL, state_event = NULL, ready_event = NULL;
    int ready_sent = 0;
    const volatile LONG *state_slot = NULL;
    DWORD last_word = 0;
    int received_testing = 0;
    HKEY settings = NULL;
    pet_config saved = {0, 0, 100, 0};
    int can_save = 0, prefs_writable = 0, prefs_loaded = 0;
    unsigned prefs_dirty = 0;
    pet_preferences restored_prefs = {0};
    const wchar_t *path = NULL, *package_dir = NULL, *package_id = NULL;
    int check_package = 0, check_task = 0, fingerprint_package = 0, async_bound = 0;
    int dual_fingerprint = 0, expected_dual = 0, describe_package = 0;
    const wchar_t *expected_sha = NULL, *stage_root = NULL, *stage_id = NULL;
    HANDLE stage_pin = NULL;
    pet_package package = {0};
    native_decode decode_ctx = {memory, &package, validate, validate_activity, NULL, 0};
    uint8_t *atlas = NULL, *activity = NULL;
    const wchar_t *activity_path = NULL;
    unsigned activity_frames = 0, activity_fps = 0;
    size_t bytes = 0, activity_bytes = 0;
    uint64_t activity_started = 0;
    int activity_displayed = 0;
    pet_idle_policy idle = {0};
    unsigned outfit = 0, schedule_target = 0;
    int auto_outfit = 0;
    uint64_t schedule_due = 0;
    uint32_t rejected_outfits = 0;
    uint32_t outfit_failures[PET_OUTFIT_SLOTS] = {0};
    unsigned active_index = PET_IDLE_NONE;
    uint32_t rng = (uint32_t)GetTickCount64() ^ GetCurrentProcessId();
    pet_surface surface = {0};
    surface.resources = memory->resource_bridge;
    LPWSTR *argv = NULL;
    if (!pet_reserve(memory->resource_bridge, PET_RESOURCE_ARGV, 1)) goto cleanup;
    argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) pet_release(memory->resource_bridge, PET_RESOURCE_ARGV, 1);
    if (!argv || !sample || !validate || !sample_activity || !validate_activity || !parse_package || !schedule) goto cleanup;
    if (argc == 5 && wcscmp(argv[1], L"--crash-watch") == 0) {
        int watch_result = pet_crash_watch(argv[2], argv[3], argv[4], NULL);
        if (LocalFree(argv)) ExitProcess(2);
        pet_release(memory->resource_bridge, PET_RESOURCE_ARGV, 1);
        ExitProcess((UINT)watch_result);
    }
    if (argc == 2 && wcscmp(argv[1], L"--pick-folder") == 0) {
        extern int pet_pick_folder(void);
        rc = pet_pick_folder();
        goto cleanup;
    }
    if (argc == 2 && wcscmp(argv[1], L"--pick-file") == 0) {
        extern int pet_pick_file(void);
        rc = pet_pick_file();
        goto cleanup;
    }
    for (int i = 1; i < argc; ++i) {
        if (wcscmp(argv[i], L"--smoke") == 0 && !smoke) smoke = 1;
        else if (!stress_seconds && wcscmp(argv[i], L"--stress-seconds") == 0 &&
            i + 1 < argc && parse_activity_number(argv[i + 1], 300, &stress_seconds)) ++i;
        else if (!stress_hidden && wcscmp(argv[i], L"--stress-hidden") == 0) stress_hidden = 1;
        else if (!stress_slot && wcscmp(argv[i], L"--stress-slot") == 0 &&
            i + 1 < argc && parse_activity_number(argv[i + 1], 100, &stress_slot)) ++i;
        else if (!gaze_set && (wcscmp(argv[i], L"--gaze") == 0 ||
            wcscmp(argv[i], L"--no-gaze") == 0)) {
            gaze_enabled = wcscmp(argv[i], L"--gaze") == 0;
            gaze_set = 1;
        } else if (!reduced_set && (wcscmp(argv[i], L"--reduced-motion") == 0 ||
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
            (stop = parse_inherited_handle(memory->resource_bridge, argv[i + 1], state_map, state_event, ready_event)) != NULL) ++i;
        else if (wcscmp(argv[i], L"--state-map") == 0 && !state_map && i + 1 < argc &&
            (state_map = parse_inherited_handle(memory->resource_bridge, argv[i + 1], stop, state_event, ready_event)) != NULL) ++i;
        else if (wcscmp(argv[i], L"--state-event") == 0 && !state_event && i + 1 < argc &&
            (state_event = parse_inherited_handle(memory->resource_bridge, argv[i + 1], stop, state_map, ready_event)) != NULL) ++i;
        else if (wcscmp(argv[i], L"--ready-event") == 0 && !ready_event && i + 1 < argc &&
            (ready_event = parse_inherited_handle(memory->resource_bridge, argv[i + 1], stop, state_map, state_event)) != NULL) ++i;
        else if (wcscmp(argv[i], L"--language") == 0 && !language_set && i + 1 < argc &&
            pet_language_parse(argv[i + 1], &language)) {
            language_set = 1;
            ++i;
        } else if (wcscmp(argv[i], L"--scale") == 0 && !scale_set && i + 1 < argc &&
            parse_scale(argv[i + 1], &scale)) {
            scale_set = 1;
            ++i;
        } else if (!expected_sha && (wcscmp(argv[i], L"--expected-sha256") == 0 ||
            wcscmp(argv[i], L"--expected-fingerprint") == 0) && i + 1 < argc) {
            expected_dual = wcscmp(argv[i], L"--expected-fingerprint") == 0;
            expected_sha = argv[++i];
        } else if (!stage_root && wcscmp(argv[i], L"--stage-root") == 0 && i + 2 < argc) {
            stage_root = argv[++i];
            stage_id = argv[++i];
        } else if (!package_dir && i + 2 < argc &&
            (wcscmp(argv[i], L"--package") == 0 || wcscmp(argv[i], L"--check-package") == 0 ||
             wcscmp(argv[i], L"--check-package-task") == 0 ||
             wcscmp(argv[i], L"--fingerprint-package") == 0 || wcscmp(argv[i], L"--fingerprint-package-v2") == 0 ||
             wcscmp(argv[i], L"--describe-package-v1") == 0)) {
            describe_package = wcscmp(argv[i], L"--describe-package-v1") == 0;
            dual_fingerprint = wcscmp(argv[i], L"--fingerprint-package-v2") == 0;
            fingerprint_package = dual_fingerprint || wcscmp(argv[i], L"--fingerprint-package") == 0;
            check_package = describe_package || fingerprint_package || wcscmp(argv[i], L"--check-package") == 0;
            check_task = wcscmp(argv[i], L"--check-package-task") == 0;
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
    if ((describe_package && (!expected_sha || !expected_dual || stage_root)) ||
        (stage_root && (!fingerprint_package || !expected_sha)) ||
        (expected_sha && (!package_dir || wcslen(expected_sha) != (expected_dual ? 193u : 64u))) ||
        (package_dir && (path || activity_path || smoke || (state_map && (!ready_event || remember)))) ||
        ((check_package || check_task) && (stop || remember || reset_position || gaze_set)) ||
        (activity_path && (smoke || state_map ||
            sample_activity(activity_frames, activity_fps, 0, &activity_check) != 0)) ||
        (smoke && (path || reduced_set || topmost_set || remember || reset_position || gaze_set)) ||
        ((stress_hidden || stress_slot) && !stress_seconds) ||
        (stress_seconds && (stress_seconds < 10 || smoke || remember || reset_position ||
            state_map || check_package || check_task || activity_path)) ||
        (reset_position && !remember) || (!!state_map != !!state_event) ||
        (ready_event && (!state_map || ready_event == stop || ready_event == state_map || ready_event == state_event)) ||
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
        if (!pet_reserve(memory->resource_bridge, PET_RESOURCE_IPC, 1)) goto cleanup;
        state_slot = MapViewOfFile(state_map, FILE_MAP_READ, 0, 0, sizeof(LONG));
        if (!state_slot) {
            pet_release(memory->resource_bridge, PET_RESOURCE_IPC, 1);
            goto cleanup;
        }
        last_word = pet_state_read(state_slot);
        if (!pet_state_valid(last_word)) goto cleanup;
        reaction = last_word & 15u;
        if (reaction > PET_STATE_CELEBRATING) goto cleanup;
        received_testing = reaction == PET_STATE_TESTING;
    }
    if (package_dir) {
        uint8_t digest[96];
        if (!pet_package_open(memory, &package, package_dir, package_id, parse_package, validate, validate_activity,
            hash, fingerprint, (fingerprint_package || expected_sha) ? digest : NULL)) {
            fputs("Classic package rejected: metadata, path, inventory or WebP header.\n", stderr);
            goto cleanup;
        }
        if (fingerprint_package || expected_sha) {
            static const char alphabet[] = "0123456789abcdef";
            char hex[194];
            for (unsigned i = 0; i < 96; ++i) {
                unsigned pos = 2 * i + (i >= 32 ? 1 : 0);
                hex[pos] = alphabet[digest[i] >> 4];
                hex[pos + 1] = alphabet[digest[i] & 15];
            }
            hex[64] = ':';
            hex[193] = 0;
            if (expected_sha) {
                for (unsigned i = 0; i < (expected_dual ? 193u : 64u); ++i) {
                    if (expected_sha[i] != (wchar_t)hex[i]) {
                        fputs("Package admission failed at fingerprint-mismatch.\n", stderr);
                        goto cleanup;
                    }
                }
            }
            if (stage_root) {
                wchar_t staged[1024], final[1024];
                uint8_t copied_digest[96];
                if (!pet_package_stage(memory, &package, stage_root, stage_id, staged, final, &stage_pin)) {
                    fputs("Package import failed at stage-copy (pending directory may remain).\n", stderr);
                    goto cleanup;
                }
                pet_package_close(memory, &package);
                if (!pet_package_open(memory, &package, staged, package_id, parse_package, validate, validate_activity,
                    hash, fingerprint, copied_digest) || memcmp(digest, copied_digest, sizeof(digest))) {
                    fputs("Package import failed at stage-verification (pending directory retained).\n", stderr);
                    goto cleanup;
                }
                /* All file and directory handles must be released before the
                 * same-volume rename. Caller-owned root remains pinned. */
                pet_package_close(memory, &package);
                if (!MoveFileExW(staged, final, MOVEFILE_WRITE_THROUGH)) {
                    DWORD publish_error = GetLastError();
                    fprintf(stderr, "Package import failed at stage-publish (Win32 %lu; pending directory retained).\n", (unsigned long)publish_error);
                    goto cleanup;
                }
                if (dual_fingerprint) printf("PULSE_PACKAGE_STAGED_V2 %s\n", hex);
                else printf("PULSE_PACKAGE_STAGED_V1 %.64s\n", hex);
                rc = 0;
                goto cleanup;
            }
            if (describe_package) {
                /* ASCII-only bounded projection; never write a thumbnail or
                 * let the UI read arbitrary paths from package metadata. */
                printf("PULSE_PACKAGE_DETAIL_V1 %u %u %u %u ",
                    (unsigned)package.meta.version, (unsigned)package.meta.count,
                    (unsigned)package.meta.outfit_count, (unsigned)package.meta.rule_count);
                for (size_t i = 0; i < sizeof(package.meta.display_name) && package.meta.display_name[i]; ++i)
                    printf("%02x", (unsigned)package.meta.display_name[i]);
                putchar(' ');
                for (size_t i = 0; i < sizeof(package.meta.description) && package.meta.description[i]; ++i)
                    printf("%02x", (unsigned)package.meta.description[i]);
                putchar('\n');
            } else if (dual_fingerprint) printf("PULSE_PACKAGE_FINGERPRINT_V2 %s\n", hex);
            else if (fingerprint_package) printf("PULSE_PACKAGE_SHA256_V1 %.64s\n", hex);
        }
        version = package.meta.version;
        gaze_x = package.meta.gaze_x;
        gaze_y = package.meta.gaze_y;
        auto_outfit = package.meta.rule_count != 0;
        idle.unavailable = unavailable_activities(&package, outfit);
        if (check_package) { rc = 0; goto cleanup; }
        if (!pet_reserve(memory->resource_bridge, PET_RESOURCE_NOTIFY, 1)) goto cleanup;
        decode_ctx.event = CreateEventW(NULL, TRUE, FALSE, NULL);
        if (!decode_ctx.event) {
            pet_release(memory->resource_bridge, PET_RESOURCE_NOTIFY, 1);
            goto cleanup;
        }
        if (!async->bind(async->owner, &decode_ctx, decode_package, decode_notify)) goto cleanup;
        async_bound = 1;
        if (check_task) {
            if (!request_decode(memory->resource_bridge, async, PET_DECODE_OUTFIT, 0, 0)) goto cleanup;
            DWORD wait_result = WaitForSingleObject(decode_ctx.event, 10000);
            if (wait_result != WAIT_OBJECT_0) {
                pet_note(memory->resource_bridge, wait_result == WAIT_TIMEOUT ? PET_NOTE_TIMEOUT : PET_NOTE_IO_FAILURE);
                goto cleanup;
            }
            pet_decode_result result = {0};
            int status = take_decode(async, &decode_ctx, &result);
            pet_free(memory, result.pixels, result.bytes);
            rc = status == 1 ? 0 : 1;
            goto cleanup;
        }
    }
    gaze_supported = version == 2 && (path || package_dir) && !smoke;
    if (gaze_set && !gaze_supported) { usage(); goto cleanup; }
    gaze_dirty = gaze_set;
    if (remember) {
        LSTATUS status = open_settings(memory->resource_bridge, &settings);
        if (status == ERROR_FILE_NOT_FOUND) {
            /* Defer creation until a clean, visible exit. */
            can_save = 1;
            prefs_writable = package_dir != NULL;
            gaze_writable = gaze_supported;
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
        if (gaze_supported && settings) {
            int previous = 1;
            pet_config_result result = pet_gaze_config_load(settings, &previous);
            gaze_writable = result == PET_CONFIG_OK || result == PET_CONFIG_MISSING;
            if (result == PET_CONFIG_OK && !gaze_set) gaze_enabled = previous;
            if (!gaze_writable) {
                pet_note(memory->resource_bridge, PET_NOTE_IO_FAILURE);
                fputs("Saved gaze preference incompatible or unavailable; preserved.\n", stderr);
            }
        }
        if (package_dir && settings) {
            pet_config_result result = pet_preferences_load(settings, package.meta.pet_id, &restored_prefs);
            prefs_writable = result == PET_CONFIG_OK || result == PET_CONFIG_MISSING;
            if (result == PET_CONFIG_OK) {
                prefs_loaded = pet_preferences_apply(&package.meta, &restored_prefs,
                    &outfit, &auto_outfit, &idle.enabled);
                if (!prefs_loaded) prefs_writable = 0;
            }
            if (!prefs_writable) {
                outfit = 0; auto_outfit = package.meta.rule_count != 0; idle.enabled = 0;
                fputs("Pet preferences unavailable or incompatible; using defaults without overwrite.\n", stderr);
                pet_note(memory->resource_bridge, PET_NOTE_IO_FAILURE);
            }
        }
    }
    /* Process-local DPI policy before window creation. No host mutation. */
    /* Per-monitor awareness keeps the explicit physical pixel scale stable.
     * Use the older system-aware API only if the newer context is unavailable. */
    if (!SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2))
        (void)SetProcessDPIAware();
    atlas = package_dir ? pet_package_load_atlas(memory, &package, outfit, validate, &bytes) :
        (path ? pet_demo_load_webp(memory, path, version, validate, &bytes) : synthetic_atlas(memory, &bytes));
    if (!atlas && package_dir && outfit) {
        /* A restored fixed outfit can fail its full decode after header
         * admission. Preserve the stored preference unless explicitly edited. */
        outfit = 0;
        atlas = pet_package_load_atlas(memory, &package, outfit, validate, &bytes);
        pet_note(memory->resource_bridge, PET_NOTE_IO_FAILURE);
        fputs("Saved outfit decode failed; default appearance retained.\n", stderr);
    }
    if (!atlas) goto cleanup;
    idle.unavailable = unavailable_activities(&package, outfit);
    if (pet_surface_open_scaled(&surface, topmost, FALSE, scale) != PET_SURFACE_OK) goto cleanup;
    if (smoke) {
        /* Synthetic metadata only; do not display a modal menu or save settings. */
        package.meta.outfit_count = 1;
        package.meta.rule_count = 1;
        package.meta.count = 1;
        memcpy(package.meta.outfits[0].name, "Test outfit", sizeof("Test outfit"));
        memcpy(package.meta.items[0].name, "Test activity", sizeof("Test activity"));
        package.meta.items[0].reps[0].frames = 4;
        int built = 0;
        (void)pet_menu(memory->resource_bridge, &surface, stop, (POINT){0, 0},
            scale, topmost, reduced, state_slot != NULL, language, &package, &idle, 0, 1, 1, 1, 0, &built);
        ZeroMemory(&package.meta, sizeof(package.meta));
        if (!built) goto cleanup;
    }
    RECT work = {0};
    if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0)) goto cleanup;
    LONG x = clamp_long((int64_t)work.right - surface.width - 24);
    LONG y = clamp_long((int64_t)work.bottom - surface.height - 24);
    if (!remember && !reset_position && state_slot && !stress_slot) {
        DWORD pid = GetCurrentProcessId();
        x = clamp_long((int64_t)x - (int64_t)(pid % 5u) * 48);
        y = clamp_long((int64_t)y - (int64_t)((pid / 5u) % 3u) * 32);
    }
    if (pet_clamp_position(&work, surface.width, surface.height, &x, &y) != PET_SURFACE_OK)
        goto cleanup;
    if (remember && !reset_position && (saved.flags & PET_CONFIG_POSITION)) {
        x = saved.x; y = saved.y;
        POINT center = {clamp_long((int64_t)x + surface.width / 2),
            clamp_long((int64_t)y + surface.height / 2)};
        if (!constrain(&surface, center, &x, &y)) goto cleanup;
    }
    if (stress_slot) {
        unsigned columns = (unsigned)(work.right - work.left) / surface.width;
        unsigned rows = (unsigned)(work.bottom - work.top) / surface.height;
        if (!columns) columns = 1;
        if (!rows) rows = 1;
        unsigned slot = stress_slot - 1;
        x = clamp_long((int64_t)work.left + (slot % columns) * surface.width);
        y = clamp_long((int64_t)work.top + ((slot / columns) % rows) * surface.height);
        if (pet_clamp_position(&work, surface.width, surface.height, &x, &y) != PET_SURFACE_OK)
            goto cleanup;
    }
    POINT press = {0}, cursor = {0};
    LONG press_x = 0, press_y = 0;
    int pressed = 0, dragged = 0;
    uint64_t started = GetTickCount64(), smoke_end = started + 500;
    uint64_t stress_end = started + (uint64_t)stress_seconds * 1000;
    unsigned last_row = UINT32_MAX, last_column = UINT32_MAX, frames = 0;
    int shown = 0, done = 0, policy_hidden = 0;
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
                    pet_idle_interrupt(&idle);
                    if (async_bound) async->invalidate(async->owner);
                    active_index = PET_IDLE_NONE;
                    /* Opening the menu interrupts optional artwork; restore
                     * the base pose before any live resize. */
                    if (activity || activity_displayed) {
                        pet_free(memory, activity, activity_bytes); activity = NULL; activity_bytes = 0;
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
                    unsigned command = pet_menu(memory->resource_bridge, &surface, stop, cursor, scale, topmost,
                        reduced, 0, language, &package, &idle, outfit, auto_outfit, gaze_supported, gaze_enabled, 1, NULL);
                    /* A modal menu may span a civil-time boundary. */
                    schedule_due = 0;
                    pet_gaze_suspend(&gaze, GetTickCount64());
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
                    } else if (command == MENU_GAZE && gaze_supported && !reduced) {
                        gaze_enabled = !gaze_enabled;
                        gaze_dirty = 1;
                        pet_gaze_reset(&gaze);
                    } else if (command == MENU_OUTFIT_AUTO && package.meta.rule_count) {
                        auto_outfit = 1;
                        rejected_outfits = 0; /* explicit retry */
                        prefs_dirty |= PET_PREF_OUTFIT_CHANGED;
                        schedule_due = 0;
                    } else if (command >= MENU_OUTFIT_FIRST &&
                        command - MENU_OUTFIT_FIRST <= package.meta.outfit_count && package.meta.outfit_count) {
                        unsigned next = command - MENU_OUTFIT_FIRST;
                        if (next == outfit) {
                            auto_outfit = 0;
                            prefs_dirty |= PET_PREF_OUTFIT_CHANGED;
                        } else if (request_decode(memory->resource_bridge, async, PET_DECODE_OUTFIT, next, 0)) {
                            auto_outfit = 0;
                        } else {
                            fputs("Outfit decode admission failed; previous appearance retained.\n", stderr);
                        }
                    } else if (command >= MENU_AUTO_FIRST &&
                        command - MENU_AUTO_FIRST < package.meta.count) {
                        unsigned index = command - MENU_AUTO_FIRST;
                        pet_idle_toggle(&idle, index);
                        prefs_dirty |= PET_PREF_ACTIVITIES_CHANGED;
                    } else if (command >= MENU_ACTIVITY_FIRST &&
                        command - MENU_ACTIVITY_FIRST < package.meta.count && !reduced &&
                        !((idle.failed | idle.unavailable) & pet_idle_bit(command - MENU_ACTIVITY_FIRST))) {
                        unsigned index = command - MENU_ACTIVITY_FIRST;
                        if (!request_decode(memory->resource_bridge, async, PET_DECODE_ACTIVITY, outfit, index))
                            fputs("Activity decode admission failed.\n", stderr);
                    } else if (command == MENU_INTERACT && !reduced) {
                        if (activity_path) {
                            activity = pet_demo_load_activity(memory, activity_path, activity_frames,
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
                    pet_idle_interrupt(&idle);
                    if (async_bound) async->invalidate(async->owner);
                    active_index = PET_IDLE_NONE;
                    if (activity) {
                        pet_free(memory, activity, activity_bytes); activity = NULL; activity_bytes = 0;
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
                            if (!reduced) {
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
        if (done || (shown && !policy_hidden && !IsWindowVisible(surface.window))) break;
        if (pressed && GetCapture() != surface.window) pressed = 0;
        if (surface.placement_dirty) {
            pet_gaze_suspend(&gaze, GetTickCount64());
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
                unsigned command = word & 15u;
                last_word = word;
                if (command == PET_STATE_HIDE || command == PET_STATE_SHOW) {
                    if (!ready_sent || !ready_event || smoke || stress_hidden || !shown) goto cleanup;
                    BOOL visible = command == PET_STATE_SHOW;
                    if (!!IsWindowVisible(surface.window) != !!visible) {
                        if (pet_surface_show(&surface, visible) != PET_SURFACE_OK ||
                            !!IsWindowVisible(surface.window) != !!visible) goto cleanup;
                    }
                    policy_hidden = !visible;
                    if (GetCapture() == surface.window) ReleaseCapture();
                    pressed = dragged = 0;
                    pet_gaze_reset(&gaze);
                    started = now;
                    if (!SetEvent(ready_event)) goto cleanup;
                } else {
                    reaction = command;
                    started = now;
                    if (reaction == PET_STATE_TESTING) received_testing = 1;
                }
            }
        }
        if ((smoke && now >= smoke_end) || (stress_seconds && now >= stress_end)) break;
        if (policy_hidden) {
            /* No frame sampling, gaze, outfit scheduling or new decode work
             * while hidden. Existing bounded decode may finish; consume on
             * resume. Stop/state/message events remain responsive. */
            HANDLE hidden_waits[2] = {stop, state_event};
            DWORD hidden_result = MsgWaitForMultipleObjectsEx(2, hidden_waits, INFINITE,
                QS_ALLINPUT, MWMO_INPUTAVAILABLE);
            if (hidden_result == WAIT_OBJECT_0) { stopped = 1; break; }
            if (hidden_result == WAIT_FAILED || (hidden_result >= WAIT_ABANDONED_0 &&
                hidden_result < WAIT_ABANDONED_0 + 2)) goto cleanup;
            continue;
        }
        if (surface.schedule_dirty) {
            surface.schedule_dirty = FALSE;
            schedule_due = 0;
        }
        if (auto_outfit && now >= schedule_due) {
            uint32_t delay = 0;
            schedule_target = scheduled_outfit(&package, schedule, &delay);
            schedule_due = now + delay;
        }
        if (async_bound && InterlockedCompareExchange(&decode_ctx.ready, 0, 0)) {
            pet_decode_result result = {0};
            int status = take_decode(async, &decode_ctx, &result);
            if (status < 0) goto cleanup;
            if (status == 1 && result.kind == PET_DECODE_OUTFIT && auto_outfit &&
                result.outfit != (schedule_target = scheduled_outfit(&package, schedule, NULL))) {
                /* Wall clock changed while decoding; free rather than commit. */
                pet_note(memory->resource_bridge, PET_NOTE_CANCELLED);
            } else if (status == 1 && result.kind == PET_DECODE_OUTFIT) {
                pet_demo_sample base = {0};
                if (result.outfit <= package.meta.outfit_count && result.pixels &&
                    !sample(version, PET_STATE_IDLE, 0, reduced, &base) &&
                    pet_surface_resize(&surface, scale, result.pixels, result.bytes, version,
                        base.row, base.column, x, y, 255) == PET_SURFACE_OK) {
                    pet_free(memory, atlas, bytes);
                    atlas = result.pixels; bytes = result.bytes;
                    result.pixels = NULL;
                    outfit_failures[outfit] = idle.failed;
                    outfit = result.outfit;
                    pet_gaze_suspend(&gaze, GetTickCount64());
                    if (!auto_outfit) prefs_dirty |= PET_PREF_OUTFIT_CHANGED;
                    idle.failed = outfit_failures[outfit];
                    idle.unavailable = unavailable_activities(&package, outfit);
                    pet_idle_interrupt(&idle);
                    reaction = PET_STATE_IDLE;
                    started = GetTickCount64();
                    last_row = base.row; last_column = base.column;
                } else {
                    if (auto_outfit && result.outfit < PET_OUTFIT_SLOTS)
                        rejected_outfits |= UINT32_C(1) << result.outfit;
                    pet_note(memory->resource_bridge, PET_NOTE_IO_FAILURE);
                    fputs("Outfit switch failed; previous appearance retained.\n", stderr);
                }
            } else if (status == 1 && result.kind == PET_DECODE_ACTIVITY &&
                result.outfit == outfit && result.activity < package.meta.count &&
                !reduced && !pressed && !activity) {
                const pet_package_rep *rep = &package.meta.items[result.activity].reps[outfit];
                if (rep->frames && result.pixels) {
                    activity = result.pixels; activity_bytes = result.bytes;
                    result.pixels = NULL;
                    activity_frames = rep->frames; activity_fps = rep->fps;
                    active_index = result.activity;
                    activity_started = GetTickCount64();
                }
            } else if (status == 2) {
                if (result.kind == PET_DECODE_ACTIVITY && result.outfit == outfit)
                    pet_idle_failed(&idle, result.activity);
                if (result.kind == PET_DECODE_OUTFIT && auto_outfit && result.outfit < PET_OUTFIT_SLOTS)
                    rejected_outfits |= UINT32_C(1) << result.outfit;
                fputs("Package decode failed; previous appearance retained.\n", stderr);
            }
            pet_free(memory, result.pixels, result.bytes);
            if (async->start(async->owner) < 0) {
                pet_note(memory->resource_bridge, PET_NOTE_BACKPRESSURE);
                fputs("Queued decode admission failed.\n", stderr);
            }
            now = GetTickCount64();
        }
        pet_demo_sample point = {0};
        /* Admission follows the actual Classic presentation, not a stale
         * finite reaction code. No new opportunity during capture, reduced
         * motion or an outstanding optional animation. */
        pet_demo_sample base_point = {0};
        if (sample(version, reaction, now - started, reduced, &base_point)) goto cleanup;
        int switch_due = pet_wardrobe_switch_due(auto_outfit, outfit, schedule_target, rejected_outfits);
        if (switch_due && shown && !pressed && !activity && !activity_displayed &&
            base_point.row == 0 && !async->busy(async->owner)) {
            pet_idle_interrupt(&idle);
            if (!request_decode(memory->resource_bridge, async, PET_DECODE_OUTFIT, schedule_target, 0)) {
                /* No frame-rate retry storm. Explicit Auto selection retries. */
                rejected_outfits |= UINT32_C(1) << schedule_target;
                fputs("Scheduled outfit decode admission failed; previous appearance retained.\n", stderr);
            }
        }
        int available = !switch_due && shown && !smoke && !reduced && !pressed &&
            !activity && (!async_bound || !async->busy(async->owner)) && base_point.row == 0;
        uint32_t delay_random = activity_random(&rng);
        uint32_t choice_random = activity_random(&rng);
        unsigned choice = pet_idle_choose(&idle, package.meta.count, available,
            now, delay_random, choice_random);
        if (choice != PET_IDLE_NONE) {
            if (!request_decode(memory->resource_bridge, async, PET_DECODE_ACTIVITY, outfit, choice))
                fputs("Automatic decode admission failed.\n", stderr);
        }
        if (activity) {
            int result = sample_activity(activity_frames, activity_fps,
                now - activity_started, &point);
            if (result != 0) {
                if (result < 0) pet_idle_failed(&idle, active_index);
                active_index = PET_IDLE_NONE;
                pet_idle_interrupt(&idle);
                pet_free(memory, activity, activity_bytes); activity = NULL; activity_bytes = 0;
                reaction = PET_STATE_IDLE;
                started = now;
                if (result < 0) fputs("Invalid activity timeline.\n", stderr);
            }
        }
        if (activity) {
            pet_gaze_reset(&gaze);
            if (!activity_displayed || point.column != last_column) {
                if (pet_surface_present_activity(&surface, activity, activity_bytes,
                    activity_frames, point.column, x, y, 255) != PET_SURFACE_OK)
                    goto cleanup;
                if (!activity_displayed) pet_idle_started(&idle, active_index, GetTickCount64());
                activity_displayed = 1;
                last_column = point.column;
                ++frames;
            }
        } else {
            if (sample(version, reaction, now - started, reduced, &point)) goto cleanup;
            if (pet_gaze_eligible(version, gaze_supported && gaze_enabled, shown, reduced,
                pressed, activity_displayed, point.row)) {
                if (now >= gaze.next) {
                    POINT mouse;
                    RECT bounds;
                    /* Read the actual layered window, not the last requested
                     * position. GetWindowRect is DPI-virtualized for legacy
                     * callers; keep cursor and bounds in the same coordinate
                     * space. In per-monitor mode both are physical pixels. */
                    const DPI_AWARENESS awareness = GetAwarenessFromDpiAwarenessContext(
                        GetThreadDpiAwarenessContext());
                    BOOL cursor_ok = awareness == DPI_AWARENESS_PER_MONITOR_AWARE ?
                        GetPhysicalCursorPos(&mouse) : GetCursorPos(&mouse);
                    if (cursor_ok && GetWindowRect(surface.window, &bounds))
                        (void)pet_gaze_observe_bounds(&gaze, now, mouse.x, mouse.y,
                            bounds.left, bounds.top, bounds.right, bounds.bottom, gaze_x, gaze_y);
                    else {
                        pet_gaze_reset(&gaze);
                        gaze.next = now + PET_GAZE_INTERVAL;
                    }
                }
                if (gaze.direction >= 0) {
                    point.row = 9u + (unsigned)gaze.direction / 8u;
                    point.column = (unsigned)gaze.direction % 8u;
                    point.wait_ms = 0; /* static cell until cursor deadline */
                }
            } else if (gaze.seeded || gaze.moved) pet_gaze_reset(&gaze);
            if (activity_displayed || point.row != last_row || point.column != last_column) {
                if (pet_surface_present(&surface, atlas, bytes, version, point.row,
                    point.column, x, y, 255) != PET_SURFACE_OK) goto cleanup;
                activity_displayed = 0;
                last_row = point.row;
                last_column = point.column;
                ++frames;
            }
        }
        if (!smoke && !stress_hidden && !shown) {
            if (pet_surface_show(&surface, TRUE) != PET_SURFACE_OK) goto cleanup;
            shown = 1;
            /* First presentation must remain default. Immediately revisit
             * a due outfit, even when reduced motion has no frame deadline. */
            if (switch_due) schedule_due = 0;
        }
        if (ready_event && !ready_sent && frames) {
            /* First successful surface presentation, and show for visible
             * mode, precedes the acknowledgment. No reset or polling loop. */
            if (!SetEvent(ready_event)) goto cleanup;
            ready_sent = 1;
        }
        if (stress_seconds && !stress_ready && frames) {
            fputs("Companion stress: ready\n", stderr);
            fflush(stderr);
            stress_ready = 1;
        }
        DWORD wait = point.wait_ms ? point.wait_ms : INFINITE;
        if (pet_gaze_eligible(version, gaze_supported && gaze_enabled, shown, reduced,
            pressed, activity != NULL, base_point.row)) {
            uint64_t delay = gaze.next > now ? gaze.next - now : 0;
            if (delay < wait) wait = (DWORD)delay;
        }
        if (auto_outfit) {
            uint64_t delay = schedule_due > now ? schedule_due - now : 0;
            if (delay < wait) wait = (DWORD)delay;
        }
        if (idle.opportunity) {
            uint64_t delay = idle.opportunity > now ? idle.opportunity - now : 0;
            if (delay < wait) wait = (DWORD)delay;
        }
        if (smoke && (uint64_t)wait > smoke_end - now) wait = (DWORD)(smoke_end - now);
        if (stress_seconds && (uint64_t)wait > stress_end - now) wait = (DWORD)(stress_end - now);
        HANDLE waits[3];
        DWORD count = 0;
        if (stop) waits[count++] = stop;
        if (state_event) waits[count++] = state_event;
        if (async_bound && async->busy(async->owner)) {
            waits[count++] = decode_ctx.event;
            /* Event is the ordinary wake path. A bounded watchdog only
             * while a task exists recovers a failed SetEvent notification. */
            if (wait > 1000) wait = 1000;
        }
        DWORD result = MsgWaitForMultipleObjectsEx(count,
            count ? waits : NULL, wait, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        if (stop && result == WAIT_OBJECT_0) { stopped = 1; break; }
        if (result == WAIT_FAILED || (count && result >= WAIT_ABANDONED_0 && result < WAIT_ABANDONED_0 + count)) goto cleanup;
    }
    if (stress_seconds && !stress_ready) goto cleanup;
    if (smoke && !stopped && (frames < 2 || (state_slot && !received_testing))) {
        fputs("Hidden smoke test did not advance the animation.\n", stderr);
        goto cleanup;
    }
    rc = 0;
    if (remember && shown && (can_save || (prefs_writable && prefs_dirty) ||
        (gaze_writable && gaze_dirty))) {
        if (!settings) (void)create_settings(memory->resource_bridge, &settings);
        pet_config next = {x, y, scale, PET_CONFIG_POSITION |
            (topmost ? PET_CONFIG_TOPMOST : 0) | (reduced ? PET_CONFIG_REDUCED : 0)};
        if (can_save && (!settings || pet_config_save(settings, &next) != PET_CONFIG_OK))
            fputs("Companion settings not saved; existing incompatible data preserved.\n", stderr);
        if (gaze_writable && gaze_dirty &&
            (!settings || pet_gaze_config_save(settings, gaze_enabled) != PET_CONFIG_OK)) {
            pet_note(memory->resource_bridge, PET_NOTE_IO_FAILURE);
            fputs("Gaze preference not saved; existing incompatible data preserved.\n", stderr);
        }
        if (package_dir && prefs_dirty && prefs_writable) {
            pet_preferences prefs;
            if (!settings || !pet_preferences_update(&package.meta, outfit, auto_outfit, idle.enabled,
                prefs_loaded ? &restored_prefs : NULL, prefs_dirty, &prefs) ||
                pet_preferences_save(settings, &prefs) != PET_CONFIG_OK) {
                pet_note(memory->resource_bridge, PET_NOTE_IO_FAILURE);
                fputs("Pet preferences not saved; existing incompatible or full record preserved.\n", stderr);
            }
        }
    }
cleanup:
    /* Joining precedes closing every borrowed file/event and freeing
     * the native context. No worker touches UI or survives this run. */
    if (async_bound) async->stop(async->owner);
    if (decode_ctx.event) {
        if (CloseHandle(decode_ctx.event))
            pet_release(memory->resource_bridge, PET_RESOURCE_NOTIFY, 1);
        else {
            pet_cleanup_failed(memory->resource_bridge, PET_RESOURCE_NOTIFY);
            rc = 1;
        }
    }
    close_settings(memory->resource_bridge, settings);
    if (state_slot) {
        if (UnmapViewOfFile((const void *)state_slot)) pet_release(memory->resource_bridge, PET_RESOURCE_IPC, 1);
        else pet_cleanup_failed(memory->resource_bridge, PET_RESOURCE_IPC);
    }
    if (state_event && state_event != stop) close_ipc(memory->resource_bridge, state_event);
    if (state_map && state_map != stop && state_map != state_event) close_ipc(memory->resource_bridge, state_map);
    if (ready_event && ready_event != stop && ready_event != state_map && ready_event != state_event)
        close_ipc(memory->resource_bridge, ready_event);
    close_ipc(memory->resource_bridge, stop);
    if (surface.window && GetCapture() == surface.window) ReleaseCapture();
    if (pet_surface_close(&surface) != PET_SURFACE_OK) rc = 1;
    pet_free(memory, activity, activity_bytes);
    pet_free(memory, atlas, bytes);
    pet_package_close(memory, &package);
    pet_package_stage_close(memory, stage_pin);
    if (argv) {
        if (!LocalFree(argv)) pet_release(memory->resource_bridge, PET_RESOURCE_ARGV, 1);
        else pet_cleanup_failed(memory->resource_bridge, PET_RESOURCE_ARGV);
    }
    return rc;
}
