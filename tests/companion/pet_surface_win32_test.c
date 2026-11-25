/* Synthetic pixels only; no OpenPets dependency or commercial assets. */
#include "../../shared/companion/pet_surface_win32.h"
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

int main(void) {
    int rc = 1;
    const size_t bytes = (size_t)1536 * 2288 * 4;
    uint8_t *atlas = calloc(1, bytes);
    uint8_t *out = malloc(PET_FRAME_BYTES);
    pet_surface surface = {0};
    HANDLE thread = NULL;
    CHECK(atlas && out);
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
    CHECK(pet_surface_move(&surface, 30, 40) == PET_SURFACE_OK);
    RECT actual;
    CHECK(GetWindowRect(surface.window, &actual) && actual.left == 30 && actual.top == 40);
    CHECK(pet_surface_close(&surface) == PET_SURFACE_OK);
    CHECK(pet_surface_open_scaled(&surface, FALSE, FALSE, 50) == PET_SURFACE_OK);
    CHECK(surface.width == 96 && surface.height == 104);
    CHECK(pet_surface_close(&surface) == PET_SURFACE_OK);
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
