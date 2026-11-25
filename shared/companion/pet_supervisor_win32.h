#ifndef PULSE_PET_SUPERVISOR_WIN32_H
#define PULSE_PET_SUPERVISOR_WIN32_H
#include "pet_surface_win32.h"

/* Worker-owned, zero-initialized, noncopyable. One child per supervisor.
 * The host must verify its independently approved executable digest/root
 * ACLs before launch (shared/process/trust.zig); this is containment,
 * not an executable approval authority or sandbox. */
typedef struct {
    HANDLE job;
    HANDLE process;
    HANDLE stop;
} pet_supervisor;

typedef enum {
    PET_CHILD_OK = 0, PET_CHILD_INVALID, PET_CHILD_BUSY,
    PET_CHILD_OS_ERROR, PET_CHILD_CONTAINMENT_FAILED, PET_CHILD_TIMEOUT
} pet_child_result;

typedef struct {
    BOOL smoke; /* hidden test only, no persistent settings */
    BOOL remember;
    BOOL reduced;
    BOOL topmost;
    unsigned scale;
} pet_child_options;

pet_child_result pet_child_start(pet_supervisor *owner, const wchar_t *approved_exe,
    const pet_child_options *options);
/* Nonblocking query. A completed child retains ownership until stop/reap. */
pet_child_result pet_child_status(const pet_supervisor *owner, BOOL *running, DWORD *exit_code);
/* Graceful stop, then terminate owned job only. Both waits bounded.
 * forced and exit_code are valid only on confirmed process exit.
 * A failed wait retains ownership so caller may retry or abandon. */
pet_child_result pet_child_stop(pet_supervisor *owner, DWORD grace_ms,
    BOOL *forced, DWORD *exit_code);
/* Last-resort release: closing the private job requests kernel cleanup.
 * No claim of confirmed termination. Safe on a zero owner. */
void pet_child_abandon(pet_supervisor *owner);

#endif
