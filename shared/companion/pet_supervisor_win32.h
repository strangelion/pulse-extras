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
    PET_CHILD_OS_ERROR, PET_CHILD_CONTAINMENT_FAILED, PET_CHILD_TIMEOUT,
    PET_CHILD_COUNT_LIMIT, PET_CHILD_STORAGE_LIMIT, PET_CHILD_BUDGET_LIMIT,
    PET_CHILD_SYSTEM_MEMORY
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

/* One process-wide owner mode: legacy singleton OR one worker-owned group.
 * The group is noncopyable and must remain alive until close succeeds.
 * Count includes unconfirmed startup failures and stopping children. */
#define PET_GROUP_MAX 1024u /* Current storage capacity, not config range. */
#define PET_GROUP_CONFIG_MAX 2147483647u
#define PET_GROUP_MEMORY_HEADROOM (512ull * 1024ull * 1024ull)
typedef struct {
    uint64_t id;
    pet_supervisor child;
    BOOL stopping;
} pet_group_slot;
typedef struct {
    unsigned limit, count;
    uint64_t next_id;
    SIZE_T commit_budget;
    pet_group_slot slots[PET_GROUP_MAX];
} pet_supervisor_group;

pet_child_result pet_group_open(pet_supervisor_group *group, unsigned limit, SIZE_T commit_budget);
/* Pure policy, using current owned count and caller-supplied system memory
 * measurements. Does not promise successful process creation. */
pet_child_result pet_group_admission(const pet_supervisor_group *group,
    uint64_t available_physical, uint64_t available_commit);
/* On an error, nonzero id means a possibly live child remains owned;
 * reap or stop it before reclaiming the reservation. */
pet_child_result pet_group_start(pet_supervisor_group *group, const wchar_t *approved_exe,
    const pet_child_options *options, uint64_t *id);
pet_child_result pet_group_publish(pet_supervisor_group *group, uint64_t id, unsigned reaction);
pet_child_result pet_group_status(pet_supervisor_group *group, uint64_t id, BOOL *running, DWORD *exit_code);
typedef struct {
    uint64_t private_bytes, working_set, cpu_100ns, sampled_ms;
    uint32_t handles, pid;
} pet_group_metrics;
SIZE_T pet_group_storage_size(void);
/* Owned process handle only; output valid solely on success. */
pet_child_result pet_group_sample(pet_supervisor_group *group, uint64_t id, pet_group_metrics *out);
/* Nonblocking cooperative stop and forced termination requests. Neither
 * releases the slot. Reap only after the process handle signals. */
pet_child_result pet_group_request_stop(pet_supervisor_group *group, uint64_t id);
pet_child_result pet_group_force_stop(pet_supervisor_group *group, uint64_t id);
pet_child_result pet_group_reap(pet_supervisor_group *group, uint64_t id, DWORD *exit_code);
/* Close rejects any outstanding children; never silently drops ownership. */
pet_child_result pet_group_close(pet_supervisor_group *group);

#endif
