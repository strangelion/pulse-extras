#ifndef PULSE_PET_SURFACE_WIN32_H
#define PULSE_PET_SURFACE_WIN32_H

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <stddef.h>
#include <stdint.h>
#include "pet_resources.h"

#define PET_FRAME_WIDTH 192u
#define PET_FRAME_HEIGHT 208u
#define PET_FRAME_BYTES (PET_FRAME_WIDTH * PET_FRAME_HEIGHT * 4u)
#define PET_MIN_SCALE 50u
#define PET_MAX_SCALE 200u

typedef enum {
    PET_SURFACE_OK = 0,
    PET_SURFACE_INVALID,
    PET_SURFACE_WRONG_THREAD,
    PET_SURFACE_OS_ERROR
} pet_surface_result;

/* Raw atlas must be a verified, decoded, tightly packed RGBA8 V1/V2 image.
 * Destination must not overlap atlas. Output is one top-down premultiplied
 * BGRA8 cell, matching the Win32 layered-window contract. No allocations. */
pet_surface_result pet_frame_bgra(const uint8_t *atlas, size_t atlas_bytes,
    unsigned version, unsigned row, unsigned column, uint8_t *out, size_t out_bytes);

/* Experimental standalone UI-thread primitive; initialize with {0}.
 * Do not copy while open. Caller owns its dedicated message loop, animation
 * deadlines and process lifetime. No global hooks, renderer thread or timers.
 * Window is initially hidden, nonactivating and absent from the taskbar.
 * Default size is one 192x208 cell; scaled sizes are bounded physical pixels. */
typedef struct {
    HWND window;
    HDC memory_dc;
    HBITMAP bitmap;
    HGDIOBJ previous;
    uint8_t *pixels;
    DWORD owner_thread;
    BOOL primed;
    unsigned width, height;
    BOOL placement_dirty;
    BOOL schedule_dirty;
    const pet_resources *resources;
} pet_surface;

pet_surface_result pet_surface_open(pet_surface *surface, BOOL topmost, BOOL click_through);
pet_surface_result pet_surface_open_scaled(pet_surface *surface, BOOL topmost,
    BOOL click_through, unsigned percent);
pet_surface_result pet_surface_move(pet_surface *surface, LONG x, LONG y);
/* Clamp a top-left point to a work area, including negative monitor
 * coordinates. If the window exceeds the work area, anchor at its origin. */
pet_surface_result pet_clamp_position(const RECT *work, unsigned width,
    unsigned height, LONG *x, LONG *y);
pet_surface_result pet_surface_present(pet_surface *surface, const uint8_t *atlas,
    size_t atlas_bytes, unsigned version, unsigned row, unsigned column,
    LONG x, LONG y, BYTE opacity);
/* Activity strip: one row of 4..32 classic-sized cells. */
pet_surface_result pet_surface_present_activity(pet_surface *surface,
    const uint8_t *strip, size_t strip_bytes, unsigned frames, unsigned column,
    LONG x, LONG y, BYTE opacity);
/* Transactional live resize: create a replacement DIB and present the
 * selected cell before releasing the previous surface. Failure keeps the
 * old bitmap, size and position. UI thread only. */
pet_surface_result pet_surface_resize(pet_surface *surface, unsigned percent,
    const uint8_t *atlas, size_t atlas_bytes, unsigned version, unsigned row,
    unsigned column, LONG x, LONG y, BYTE opacity);
pet_surface_result pet_surface_show(pet_surface *surface, BOOL visible);
pet_surface_result pet_surface_policy(pet_surface *surface, BOOL topmost, BOOL click_through);
pet_surface_result pet_surface_close(pet_surface *surface);

#endif
