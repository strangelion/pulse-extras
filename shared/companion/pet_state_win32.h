#ifndef PULSE_PET_STATE_WIN32_H
#define PULSE_PET_STATE_WIN32_H
#include "pet_surface_win32.h"

/* Private inherited channel V1. A page-backed aligned LONG is the only
 * shared data. Upper 27 bits are a nonzero generation, low 4 bits are an
 * explicit stable reaction code. High bit is reserved. One serialized
 * writer, one reader; no pointers, strings, paths or unbounded queue.
 * The reader maps FILE_MAP_READ only. Windows aligned 32-bit reads are
 * atomic; the writer publishes with InterlockedExchange before SetEvent. */
enum {
    PET_STATE_IDLE = 0, PET_STATE_THINKING = 1, PET_STATE_WORKING = 2,
    PET_STATE_EDITING = 3, PET_STATE_RUNNING = 4, PET_STATE_TESTING = 5,
    PET_STATE_WAITING = 6, PET_STATE_WAVING = 7, PET_STATE_SUCCESS = 8,
    PET_STATE_ERROR = 9, PET_STATE_CELEBRATING = 10
};
#define PET_STATE_MAX_GENERATION 0x07ffffffu

static inline BOOL pet_state_valid(DWORD word) {
    return (word >> 4) >= 1 && (word >> 4) <= PET_STATE_MAX_GENERATION &&
        (word & 15u) <= PET_STATE_CELEBRATING;
}

static inline DWORD pet_state_read(const volatile LONG *slot) {
    return (DWORD)*slot;
}
#endif
