/* Synthetic pixels only; no OpenPets dependency or commercial assets. */
#include "../../shared/companion/pet_surface_win32.h"
#include "../../shared/companion/pet_menu_strings_win32.h"
#include "../../shared/companion/pet_idle_policy.h"
#include "../../shared/companion/pet_wardrobe_clock.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(expr) do { if (!(expr)) { \
    fprintf(stderr, "pet surface test failed at line %d (win32=%lu)\n", \
        __LINE__, (unsigned long)GetLastError()); goto cleanup; \
} } while (0)

static size_t pixel_offset(unsigned row, unsigned col, unsigned x, unsigned y) {
    return ((size_t)(row * PET_FRAME_HEIGHT + y) * PET_FRAME_WIDTH * 8u +
        col * PET_FRAME_WIDTH + x) * 4u;
}

static DWORD WINAPI wrong_thread(LPVOID opaque) {
    return pet_surface_close(opaque) == PET_SURFACE_WRONG_THREAD ? 0 : 1;
}

typedef struct {
    size_t live[11], peak[11];
    unsigned denied_kind;
    unsigned cleanup_failures;
} quota_fixture;

static int fixture_reserve(void *userdata, uint32_t kind, size_t amount) {
    quota_fixture *q = userdata;
    if (kind >= 11 || q->denied_kind == kind) return 0;
    const size_t limit = kind == PET_RESOURCE_DIB ? 2u * 384 * 416 * 4 :
        (kind == PET_RESOURCE_MEMORY_DC ? 2u : 1u);
    if (!amount || amount > limit - q->live[kind]) return 0;
    q->live[kind] += amount;
    if (q->live[kind] > q->peak[kind]) q->peak[kind] = q->live[kind];
    return 1;
}

static void fixture_release(void *userdata, uint32_t kind, size_t amount) {
    quota_fixture *q = userdata;
    if (kind >= 11 || !amount || amount > q->live[kind]) {
        ++q->cleanup_failures;
        return;
    }
    q->live[kind] -= amount;
}

static void fixture_failed(void *userdata, uint32_t kind) {
    quota_fixture *q = userdata;
    (void)kind;
    ++q->cleanup_failures;
}

static int fixture_drained(const quota_fixture *q) {
    for (unsigned i = 0; i < 11; ++i) if (q->live[i]) return 0;
    return !q->cleanup_failures;
}

int main(void) {
    int rc = 1;
    const size_t bytes = (size_t)1536 * 2288 * 4;
    uint8_t *atlas = calloc(1, bytes);
    uint8_t *out = malloc(PET_FRAME_BYTES);
    pet_surface surface = {0};
    HANDLE thread = NULL;
    quota_fixture q = {{0}, {0}, UINT32_MAX, 0};
    const pet_resources budget = {&q, fixture_reserve, fixture_release, fixture_failed, NULL};
    CHECK(atlas && out);
    CHECK(pet_wardrobe_wait_ms(0, 0) == 15000);
    CHECK(pet_wardrobe_wait_ms(44, 999) == 15000);
    CHECK(pet_wardrobe_wait_ms(45, 1) == 14999);
    CHECK(pet_wardrobe_wait_ms(59, 999) == 1);
    CHECK(pet_wardrobe_wait_ms(60, 0) == 15000);
    CHECK(pet_wardrobe_wait_ms(59, 1000) == 15000);
    CHECK(!pet_wardrobe_switch_due(0, 0, 1, 0));
    CHECK(!pet_wardrobe_switch_due(1, 1, 1, 0));
    CHECK(pet_wardrobe_switch_due(1, 0, 16, 0));
    CHECK(!pet_wardrobe_switch_due(1, 0, 16, UINT32_C(1) << 16));
    CHECK(!pet_wardrobe_switch_due(1, 0, UINT32_MAX, 0));
    CHECK(pet_wardrobe_switch_due(1, 1, 0, 0));
    pet_idle_policy idle = {0};
    CHECK(pet_idle_delay(0) == 120000 && pet_idle_delay(UINT32_MAX) == 240000);
    CHECK(pet_idle_choose(&idle, 2, 1, 0, 0, 0) == PET_IDLE_NONE && !idle.opportunity);
    pet_idle_toggle(&idle, 0);
    pet_idle_toggle(&idle, 1);
    CHECK(pet_idle_choose(&idle, 2, 1, 10, 0, 0) == PET_IDLE_NONE && idle.opportunity == 120010);
    CHECK(pet_idle_choose(&idle, 2, 1, 120009, 0, 0) == PET_IDLE_NONE);
    CHECK(pet_idle_choose(&idle, 2, 1, 120010, 0, 0) == 0);
    CHECK(!idle.played); /* reservation is not presentation */
    pet_idle_started(&idle, 0, 120010);
    CHECK(pet_idle_choose(&idle, 2, 1, 120020, 0, 0) == PET_IDLE_NONE);
    CHECK(pet_idle_choose(&idle, 2, 1, 240020, 0, 0) == 1);
    pet_idle_started(&idle, 1, 240020);
    CHECK(pet_idle_choose(&idle, 2, 1, 240030, 0, 0) == PET_IDLE_NONE);
    CHECK(pet_idle_choose(&idle, 2, 1, 360030, 0, 0) == PET_IDLE_NONE);
    CHECK(idle.opportunity == 480030); /* activity 0 still cooling down */
    CHECK(pet_idle_choose(&idle, 2, 1, 480030, 0, 0) == 0);
    pet_idle_interrupt(&idle); /* ordinary cancellation preserves history */
    CHECK(idle.played == 3 && !idle.failed);
    pet_idle_failed(&idle, 0);
    CHECK(pet_idle_choose(&idle, 2, 1, 500000, 0, 0) == PET_IDLE_NONE);
    CHECK(pet_idle_choose(&idle, 2, 0, 550000, 0, 0) == PET_IDLE_NONE && !idle.opportunity);
    CHECK(pet_idle_choose(&idle, 2, 1, 600000, 0, 0) == PET_IDLE_NONE);
    CHECK(pet_idle_choose(&idle, 2, 1, 720000, 0, UINT32_MAX) == 1);
    pet_idle_failed(&idle, 1);
    CHECK(pet_idle_choose(&idle, 2, 1, 1000000, 0, 0) == PET_IDLE_NONE && !idle.opportunity);
    pet_language lang = PET_LANGUAGE_SYSTEM;
    CHECK(pet_language_parse(L"zh-CN", &lang) && lang == PET_LANGUAGE_ZH_CN);
    CHECK(!pet_language_parse(L"invalid", &lang) && lang == PET_LANGUAGE_ZH_CN);
    CHECK(pet_language_parse(L"zh-TW", &lang) && lang == PET_LANGUAGE_ZH_TW);
    CHECK(pet_language_parse(L"en-US", &lang) && lang == PET_LANGUAGE_EN_US);
    CHECK(pet_language_parse(L"system", &lang) && lang == PET_LANGUAGE_SYSTEM);
    CHECK(pet_language_resolve(lang, 0x0804) == PET_LANGUAGE_ZH_CN);
    CHECK(pet_language_resolve(lang, 0x0404) == PET_LANGUAGE_ZH_TW);
    CHECK(pet_language_resolve(lang, 0x0c04) == PET_LANGUAGE_ZH_TW);
    CHECK(pet_language_resolve(lang, 0x1004) == PET_LANGUAGE_ZH_CN);
    CHECK(pet_language_resolve(lang, 0x0409) == PET_LANGUAGE_EN_US);
    CHECK(wcscmp(pet_menu_labels(PET_LANGUAGE_ZH_CN, 0x0409).exit, L"退出宠物") == 0);
    CHECK(wcscmp(pet_menu_labels(PET_LANGUAGE_ZH_TW, 0x0804).topmost, L"視窗置頂") == 0);
    CHECK(wcscmp(pet_menu_labels(PET_LANGUAGE_EN_US, 0x0804).size, L"Size") == 0);
    size_t first = pixel_offset(10, 7, 0, 0);
    size_t last = pixel_offset(10, 7, 191, 207);
    atlas[first] = 200; atlas[first + 1] = 100;
    atlas[first + 2] = 50; atlas[first + 3] = 128;
    atlas[last] = 255; atlas[last + 1] = 17;
    atlas[last + 2] = 100; atlas[last + 3] = 255;
    atlas[first + 4] = 255; /* transparent nonzero RGB must be cleared */
    CHECK(pet_frame_bgra(atlas, bytes, 2, 10, 7, out, PET_FRAME_BYTES) == PET_SURFACE_OK);
    CHECK(out[0] == 25 && out[1] == 50 && out[2] == 100 && out[3] == 128);
    CHECK(out[4] == 0 && out[5] == 0 && out[6] == 0 && out[7] == 0);
    CHECK(out[PET_FRAME_BYTES - 4] == 100 && out[PET_FRAME_BYTES - 3] == 17 &&
        out[PET_FRAME_BYTES - 2] == 255 && out[PET_FRAME_BYTES - 1] == 255);
    CHECK(pet_frame_bgra(atlas, bytes, 2, 11, 0, out, PET_FRAME_BYTES) == PET_SURFACE_INVALID);
    CHECK(pet_frame_bgra(atlas, bytes - 1, 2, 10, 7, out, PET_FRAME_BYTES) == PET_SURFACE_INVALID);
    CHECK(pet_frame_bgra(atlas, bytes, 2, 10, 7, atlas, PET_FRAME_BYTES) == PET_SURFACE_INVALID);
    CHECK(pet_frame_bgra(atlas, bytes, 1, 0, 0, out, PET_FRAME_BYTES) == PET_SURFACE_INVALID);

    CHECK(pet_surface_open(&surface, FALSE, TRUE) == PET_SURFACE_OK);
    CHECK(!IsWindowVisible(surface.window));
    CHECK(!surface.schedule_dirty);
    SendMessageW(surface.window, WM_TIMECHANGE, 0, 0);
    CHECK(surface.schedule_dirty);
    surface.schedule_dirty = FALSE;
    SendMessageW(surface.window, WM_SETTINGCHANGE, 0, 0);
    CHECK(surface.schedule_dirty);
    HCURSOR arrow = LoadCursorW(NULL, MAKEINTRESOURCEW(32512));
    CHECK(arrow != NULL);
    CHECK((HCURSOR)GetClassLongPtrW(surface.window, GCLP_HCURSOR) == arrow);
    LONG_PTR styles = GetWindowLongPtrW(surface.window, GWL_EXSTYLE);
    CHECK((styles & (WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT)) ==
        (WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT));
    CHECK(pet_surface_show(&surface, TRUE) == PET_SURFACE_INVALID);
    CHECK(pet_surface_present(&surface, atlas, bytes, 2, 10, 7, 20, 20, 255) == PET_SURFACE_OK);
    CHECK(memcmp(surface.pixels, out, PET_FRAME_BYTES) == 0);
    CHECK(!IsWindowVisible(surface.window));
    CHECK(pet_surface_policy(&surface, TRUE, FALSE) == PET_SURFACE_OK);
    styles = GetWindowLongPtrW(surface.window, GWL_EXSTYLE);
    CHECK((styles & WS_EX_TOPMOST) && !(styles & WS_EX_TRANSPARENT));
    CHECK(pet_surface_policy(&surface, FALSE, TRUE) == PET_SURFACE_OK);
    thread = CreateThread(NULL, 0, wrong_thread, &surface, 0, NULL);
    CHECK(thread);
    CHECK(WaitForSingleObject(thread, 2000) == WAIT_OBJECT_0);
    DWORD status = 1;
    CHECK(GetExitCodeThread(thread, &status) && status == 0);
    CloseHandle(thread);
    thread = NULL;
    CHECK(pet_surface_show(&surface, FALSE) == PET_SURFACE_OK);
    CHECK(pet_surface_close(&surface) == PET_SURFACE_OK);
    CHECK(pet_surface_close(&surface) == PET_SURFACE_OK);
    RECT work = {-1920, -100, 0, 900};
    LONG x = 100, y = -500;
    CHECK(pet_clamp_position(&work, 192, 208, &x, &y) == PET_SURFACE_OK);
    CHECK(x == -192 && y == -100);
    RECT tiny = {-10, -20, 10, 20};
    CHECK(pet_clamp_position(&tiny, 384, 416, &x, &y) == PET_SURFACE_OK);
    CHECK(x == -10 && y == -20);
    CHECK(pet_surface_open_scaled(&surface, FALSE, FALSE, 49) == PET_SURFACE_INVALID);
    CHECK(pet_surface_open_scaled(&surface, FALSE, FALSE, 201) == PET_SURFACE_INVALID);
    CHECK(pet_surface_open_scaled(&surface, FALSE, FALSE, 200) == PET_SURFACE_OK);
    CHECK(surface.width == 384 && surface.height == 416);
    CHECK(pet_surface_present(&surface, atlas, bytes, 2, 10, 7, 20, 20, 255) == PET_SURFACE_OK);
    CHECK(surface.pixels[0] == 25 && surface.pixels[3] == 128);
    CHECK(surface.pixels[4] == 25 && surface.pixels[7] == 128);
    HBITMAP old_bitmap = surface.bitmap;
    CHECK(pet_surface_resize(&surface, 75, atlas, bytes, 2, 11, 7, 20, 20, 255) == PET_SURFACE_INVALID);
    CHECK(surface.bitmap == old_bitmap && surface.width == 384 && surface.height == 416);
    CHECK(pet_surface_resize(&surface, 201, atlas, bytes, 2, 10, 7, 20, 20, 255) == PET_SURFACE_INVALID);
    CHECK(surface.bitmap == old_bitmap);
    CHECK(pet_surface_resize(&surface, 75, atlas, bytes, 2, 10, 7, 20, 20, 255) == PET_SURFACE_OK);
    CHECK(surface.width == 144 && surface.height == 156 && surface.bitmap != old_bitmap);
    CHECK(surface.pixels[0] == 25 && surface.pixels[3] == 128);
    CHECK(pet_surface_resize(&surface, 200, atlas, bytes, 2, 10, 7, 20, 20, 255) == PET_SURFACE_OK);
    CHECK(surface.width == 384 && surface.height == 416);
    old_bitmap = surface.bitmap;
    CHECK(pet_surface_resize(&surface, 200, atlas, bytes - 1, 2, 10, 7, 20, 20, 255) == PET_SURFACE_INVALID);
    CHECK(surface.bitmap == old_bitmap && surface.pixels[0] == 25);
    CHECK(pet_surface_resize(&surface, 200, atlas, bytes, 2, 10, 7, 20, 20, 255) == PET_SURFACE_OK);
    CHECK(surface.bitmap != old_bitmap && surface.pixels[0] == 25);
    CHECK(!IsWindowVisible(surface.window));
    /* Use the existing large allocation as a synthetic four-cell strip.
     * First pixel of the last cell must use strip, not atlas row stride. */
    size_t strip_bytes = (size_t)4 * PET_FRAME_BYTES;
    size_t strip_offset = (size_t)3 * PET_FRAME_WIDTH * 4;
    atlas[strip_offset] = 80; atlas[strip_offset + 1] = 60;
    atlas[strip_offset + 2] = 40; atlas[strip_offset + 3] = 128;
    CHECK(pet_surface_present_activity(&surface, atlas, strip_bytes, 4, 3, 20, 20, 255) == PET_SURFACE_OK);
    CHECK(surface.pixels[0] == 20 && surface.pixels[1] == 30 &&
        surface.pixels[2] == 40 && surface.pixels[3] == 128);
    CHECK(pet_surface_present_activity(&surface, atlas, strip_bytes, 4, 4, 20, 20, 255) == PET_SURFACE_INVALID);
    CHECK(pet_surface_present_activity(&surface, atlas, strip_bytes - 1, 4, 3, 20, 20, 255) == PET_SURFACE_INVALID);
    CHECK(pet_surface_present_activity(&surface, atlas, strip_bytes, 33, 0, 20, 20, 255) == PET_SURFACE_INVALID);
    CHECK(pet_surface_present(&surface, atlas, bytes, 2, 10, 7, 20, 20, 255) == PET_SURFACE_OK);
    CHECK(surface.pixels[0] == 25 && surface.pixels[3] == 128);
    CHECK(pet_surface_move(&surface, 30, 40) == PET_SURFACE_OK);
    RECT actual;
    CHECK(GetWindowRect(surface.window, &actual) && actual.left == 30 && actual.top == 40);
    CHECK(pet_surface_close(&surface) == PET_SURFACE_OK);
    CHECK(pet_surface_open_scaled(&surface, FALSE, FALSE, 50) == PET_SURFACE_OK);
    CHECK(surface.width == 96 && surface.height == 104);
    CHECK(pet_surface_close(&surface) == PET_SURFACE_OK);
    /* Fail at each native admission stage after earlier acquisitions. */
    const unsigned failures[] = {PET_RESOURCE_WINDOW, PET_RESOURCE_MEMORY_DC, PET_RESOURCE_DIB};
    for (unsigned i = 0; i < sizeof(failures) / sizeof(failures[0]); ++i) {
        q.denied_kind = failures[i];
        surface.resources = &budget;
        CHECK(pet_surface_open(&surface, FALSE, FALSE) == PET_SURFACE_OS_ERROR);
        CHECK(fixture_drained(&q));
    }
    q.denied_kind = UINT32_MAX;
    surface.resources = &budget;
    CHECK(pet_surface_open(&surface, FALSE, FALSE) == PET_SURFACE_OK);
    CHECK(pet_surface_present(&surface, atlas, bytes, 2, 10, 7, 20, 20, 255) == PET_SURFACE_OK);
    CHECK(q.live[PET_RESOURCE_WINDOW] == 1 && q.live[PET_RESOURCE_MEMORY_DC] == 1);
    CHECK(q.live[PET_RESOURCE_DESKTOP_DC] == 0);
    HBITMAP committed = surface.bitmap;
    q.denied_kind = PET_RESOURCE_MEMORY_DC;
    CHECK(pet_surface_resize(&surface, 200, atlas, bytes, 2, 10, 7, 20, 20, 255) == PET_SURFACE_OS_ERROR);
    CHECK(surface.bitmap == committed && q.live[PET_RESOURCE_MEMORY_DC] == 1);
    q.denied_kind = PET_RESOURCE_DESKTOP_DC;
    CHECK(pet_surface_resize(&surface, 200, atlas, bytes, 2, 10, 7, 20, 20, 255) == PET_SURFACE_OS_ERROR);
    CHECK(surface.bitmap == committed && q.live[PET_RESOURCE_DIB] == PET_FRAME_BYTES);
    CHECK(q.live[PET_RESOURCE_MEMORY_DC] == 1 && q.live[PET_RESOURCE_DESKTOP_DC] == 0);
    q.denied_kind = UINT32_MAX;
    CHECK(pet_surface_resize(&surface, 200, atlas, bytes, 2, 10, 7, 20, 20, 255) == PET_SURFACE_OK);
    CHECK(q.peak[PET_RESOURCE_MEMORY_DC] == 2 && q.peak[PET_RESOURCE_DESKTOP_DC] == 1);
    CHECK(q.live[PET_RESOURCE_MEMORY_DC] == 1);
    /* Destruction outside close still releases the published window once. */
    CHECK(DestroyWindow(surface.window));
    CHECK(!surface.window && q.live[PET_RESOURCE_WINDOW] == 0);
    CHECK(pet_surface_close(&surface) == PET_SURFACE_OK);
    CHECK(pet_surface_close(&surface) == PET_SURFACE_OK);
    CHECK(fixture_drained(&q));
    rc = 0;
cleanup:
    if (thread) {
        WaitForSingleObject(thread, INFINITE);
        CloseHandle(thread);
    }
    (void)pet_surface_close(&surface);
    free(out);
    free(atlas);
    return rc;
}
