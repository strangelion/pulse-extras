#ifndef PULSE_PET_SUPERVISOR_WIN32_H
#define PULSE_PET_SUPERVISOR_WIN32_H
#include "pet_state_win32.h"

/* Experimental supervised child committed-memory ceiling. This is not
 * the 48 MiB application allocator budget or a working-set limit. */
#define PET_CHILD_COMMIT_LIMIT ((SIZE_T)128u * 1024u * 1024u)

/* Worker-owned, zero-initialized, noncopyable. One child per supervisor.
 * The host must verify its independently approved executable digest/root
 * ACLs before launch (shared/process/trust.zig); this is containment,
 * not an executable approval authority or sandbox. */
typedef struct {
    HANDLE job;
    HANDLE process;
    HANDLE stop;
    HANDLE state_mapping;
    HANDLE state_event;
    volatile LONG *state_slot;
    DWORD generation;
    unsigned reaction;
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
/* Publish a state to the private child channel. Identical states are
 * coalesced. A successful publish means local admission, NOT rendered
 * acknowledgment. Must be serialized with start/status/stop on worker. */
pet_child_result pet_child_publish(pet_supervisor *owner, unsigned reaction);
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
