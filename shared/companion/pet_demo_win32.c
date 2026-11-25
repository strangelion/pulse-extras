#include "pet_demo_win32.h"
#include <shellapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

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

static void usage(void) {
    fputs("pulse-pet-demo [--reduced-motion] [--webp-v1 FILE | --webp-v2 FILE]\n"
        "Left click: wave. Right click: exit. --smoke: hidden synthetic test.\n", stderr);
}

int pet_demo_run(pet_demo_sample_fn sample, pet_demo_validate_fn validate) {
    int rc = 1, argc = 0, reduced = 0, smoke = 0, waving = 0;
    unsigned version = 2;
    const wchar_t *path = NULL;
    uint8_t *atlas = NULL;
    size_t bytes = 0;
    pet_surface surface = {0};
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || !sample || !validate) goto cleanup;
    for (int i = 1; i < argc; ++i) {
        if (wcscmp(argv[i], L"--smoke") == 0 && !smoke) smoke = 1;
        else if (wcscmp(argv[i], L"--reduced-motion") == 0 && !reduced) reduced = 1;
        else if (!path && i + 1 < argc &&
            (wcscmp(argv[i], L"--webp-v1") == 0 || wcscmp(argv[i], L"--webp-v2") == 0)) {
            version = wcscmp(argv[i], L"--webp-v1") == 0 ? 1u : 2u;
            path = argv[++i];
        } else {
            usage();
            goto cleanup;
        }
    }
    if (smoke && (path || reduced)) {
        usage();
        goto cleanup;
    }
    /* Process-local DPI policy before window creation. No host mutation. */
    (void)SetProcessDPIAware();
    atlas = path ? pet_demo_load_webp(path, version, validate, &bytes) : synthetic_atlas(&bytes);
    if (!atlas) goto cleanup;
    if (pet_surface_open(&surface, FALSE, FALSE) != PET_SURFACE_OK) goto cleanup;
    RECT work = {0};
    if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0)) goto cleanup;
    LONG x = work.right - (LONG)PET_FRAME_WIDTH - 24;
    LONG y = work.bottom - (LONG)PET_FRAME_HEIGHT - 24;
    if (x < work.left) x = work.left;
    if (y < work.top) y = work.top;
    uint64_t started = GetTickCount64(), smoke_end = started + 500;
    unsigned last_row = UINT32_MAX, last_column = UINT32_MAX, frames = 0;
    int shown = 0, done = 0;
    if (smoke) waving = 1;
    while (!done) {
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
            if (message.hwnd == surface.window && message.message == WM_LBUTTONUP) {
                waving = 1;
                started = GetTickCount64();
            }
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        if (done || (shown && !IsWindowVisible(surface.window))) break;
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
        DWORD result = MsgWaitForMultipleObjectsEx(0, NULL, wait, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        if (result == WAIT_FAILED) goto cleanup;
    }
    if (smoke && frames < 2) {
        fputs("Hidden smoke test did not advance the animation.\n", stderr);
        goto cleanup;
    }
    rc = 0;
cleanup:
    if (pet_surface_close(&surface) != PET_SURFACE_OK) rc = 1;
    free(atlas);
    if (argv) LocalFree(argv);
    return rc;
}
