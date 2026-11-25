#ifndef PULSE_OPENPETS_TRUST_WIN32_H
#define PULSE_OPENPETS_TRUST_WIN32_H

#include "openpets_pipe_win32.h"

#define OP_DISCOVERY_MAX (16u * 1024u)

/* Worker-only. The caller must provide an independently approved, pinned
 * local runtime directory handle, opened for FILE_LIST_DIRECTORY,
 * FILE_READ_ATTRIBUTES and READ_CONTROL, without delete sharing. This
 * primitive never follows an environment-provided path or opens ancestors.
 * It opens the single literal child ipc.json relative to that handle.
 * On failure count is zero and the supplied buffer is cleared. */
op_pipe_result op_read_discovery(HANDLE directory, void *buffer, DWORD capacity,
    DWORD *count, uint64_t deadline, HANDLE cancel);

/* The approved image path is independently configured, not derived from
 * discovery. Match the live process's token user, session and image path.
 * Return an owned process handle on success, otherwise NULL. This is not
 * executable signature verification or protection against same-user code. */
op_pipe_result op_open_candidate_process(DWORD pid, const wchar_t *approved_image,
    HANDLE *process, uint64_t deadline, HANDLE cancel);

#endif
