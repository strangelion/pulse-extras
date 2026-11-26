#ifndef PULSE_OPENPETS_PIPE_WIN32_H
#define PULSE_OPENPETS_PIPE_WIN32_H

/* Experimental worker-only primitive. No discovery, token handling, process
 * launch, or host integration. The caller must independently authenticate the
 * process and keep its handle open (PROCESS_QUERY_LIMITED_INFORMATION |
 * SYNCHRONIZE) throughout open. PID matching alone does not establish trust. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>

typedef enum {
    OP_PIPE_OK = 0,
    OP_PIPE_UNAVAILABLE,
    OP_PIPE_UNTRUSTED,
    OP_PIPE_TIMEOUT,
    OP_PIPE_CANCELED,
    OP_PIPE_IO_ERROR,
    OP_PIPE_INVALID
} op_pipe_result;

typedef struct {
    HANDLE handle;
} op_pipe;

/* Initialize with {0}; not copyable while open; one worker / operation at a
 * time. Deadlines are absolute GetTickCount64() milliseconds. A cancellation
 * event, if provided, must be a caller-owned manual-reset event kept alive
 * until the call returns. Never close a pipe while a call is active. */
op_pipe_result op_pipe_open_verified(op_pipe *pipe, const wchar_t *name,
    HANDLE trusted_process, uint64_t deadline, HANDLE cancel);
op_pipe_result op_pipe_read(op_pipe *pipe, void *buffer, DWORD capacity,
    DWORD *count, uint64_t deadline, HANDLE cancel);
op_pipe_result op_pipe_write(op_pipe *pipe, const void *buffer, DWORD size,
    DWORD *count, uint64_t deadline, HANDLE cancel);
void op_pipe_close(op_pipe *pipe);

#endif
