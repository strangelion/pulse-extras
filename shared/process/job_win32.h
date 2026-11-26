#ifndef PULSE_JOB_WIN32_H
#define PULSE_JOB_WIN32_H
#include <windows.h>

/* Caller owns the unnamed job. Zero limits mean no corresponding cap.
 * Configure before child creation, never inherit or share the job handle.
 * Closing requests kill-on-close, not confirmed drain. */
BOOL pulse_job_configure(HANDLE job, DWORD max_processes, SIZE_T process_commit, SIZE_T job_commit);
BOOL pulse_job_active(HANDLE job, DWORD *active);
/* Terminate only an owned job, and confirm its active count reaches zero.
 * A failure retains caller ownership. Wait must not run on the host UI. */
BOOL pulse_job_terminate_and_drain(HANDLE job, UINT exit_code, DWORD timeout_ms);
#endif
