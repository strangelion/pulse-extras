#include "openpets_pipe_win32.h"
#include <wchar.h>

#define OP_MAX_IO (16u * 1024u)

/* Exact pinned OpenPets local pipe spelling; no UNC, TCP, alternate pipe
 * namespaces, nested components or custom endpoints. */
static int valid_name(const wchar_t *name, DWORD pid) {
    static const wchar_t prefix[] = L"\\\\.\\pipe\\openpets-";
    size_t i = 0;
    uint64_t number = 0;
    if (!name || !pid) return 0;
    for (; i < (sizeof(prefix) / sizeof(prefix[0])) - 1; ++i)
        if (name[i] != prefix[i]) return 0;
    for (size_t n = 0; n < 16; ++n, ++i) {
        wchar_t c = name[i];
        if (!((c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f')))
            return 0;
    }
    if (name[i++] != L'-' || name[i] < L'1' || name[i] > L'9') return 0;
    for (size_t n = 0; name[i] != L'\0'; ++i, ++n) {
        wchar_t c = name[i];
        if (n == 10 || c < L'0' || c > L'9') return 0;
        number = number * 10 + (uint64_t)(c - L'0');
        if (number > UINT32_MAX) return 0;
    }
    return number == pid;
}

static op_pipe_result gate(uint64_t deadline, HANDLE cancel) {
    if (cancel) {
        DWORD state = WaitForSingleObject(cancel, 0);
        if (state == WAIT_OBJECT_0) return OP_PIPE_CANCELED;
        if (state != WAIT_TIMEOUT) return OP_PIPE_IO_ERROR;
    }
    return GetTickCount64() >= deadline ? OP_PIPE_TIMEOUT : OP_PIPE_OK;
}

static DWORD remaining(uint64_t deadline) {
    uint64_t now = GetTickCount64();
    if (now >= deadline) return 0;
    uint64_t delta = deadline - now;
    return delta >= INFINITE ? INFINITE - 1 : (DWORD)delta;
}

static int process_alive(HANDLE process) {
    return WaitForSingleObject(process, 0) == WAIT_TIMEOUT;
}

void op_pipe_close(op_pipe *pipe) {
    if (!pipe) return;
    if (pipe->handle && pipe->handle != INVALID_HANDLE_VALUE)
        CloseHandle(pipe->handle);
    pipe->handle = NULL;
}

op_pipe_result op_pipe_open_verified(op_pipe *pipe, const wchar_t *name,
    HANDLE trusted_process, uint64_t deadline, HANDLE cancel) {
    if (!pipe || pipe->handle || !trusted_process ||
        trusted_process == INVALID_HANDLE_VALUE) return OP_PIPE_INVALID;
    DWORD pid = GetProcessId(trusted_process);
    if (!pid || !process_alive(trusted_process) || !valid_name(name, pid))
        return OP_PIPE_UNTRUSTED;
    op_pipe_result result = gate(deadline, cancel);
    if (result != OP_PIPE_OK) return result;

    /* No retry loop: a busy/missing companion must degrade immediately.
     * SECURITY_IDENTIFICATION prevents the server impersonating the client
     * for access to other resources. No token has been written yet. */
    HANDLE handle = CreateFileW(name, GENERIC_READ | GENERIC_WRITE, 0, NULL,
        OPEN_EXISTING, FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT |
        SECURITY_IDENTIFICATION, NULL);
    if (handle == INVALID_HANDLE_VALUE) {
        DWORD err = GetLastError();
        if (err == ERROR_FILE_NOT_FOUND || err == ERROR_PIPE_BUSY)
            return OP_PIPE_UNAVAILABLE;
        if (err == ERROR_ACCESS_DENIED) return OP_PIPE_UNTRUSTED;
        return OP_PIPE_IO_ERROR;
    }
    ULONG server_pid = 0;
    if (!GetNamedPipeServerProcessId(handle, &server_pid) ||
        server_pid != pid || !process_alive(trusted_process)) {
        CloseHandle(handle);
        return OP_PIPE_UNTRUSTED;
    }
    result = gate(deadline, cancel);
    if (result != OP_PIPE_OK) {
        CloseHandle(handle);
        return result;
    }
    DWORD mode = PIPE_READMODE_BYTE;
    if (!SetNamedPipeHandleState(handle, &mode, NULL, NULL)) {
        CloseHandle(handle);
        return OP_PIPE_IO_ERROR;
    }
    result = gate(deadline, cancel);
    if (result != OP_PIPE_OK) {
        CloseHandle(handle);
        return result;
    }
    pipe->handle = handle;
    return OP_PIPE_OK;
}

/* OVERLAPPED and buffer must remain alive until completion. CancelIoEx is
 * only a cancellation request; drain even if it reports ERROR_NOT_FOUND
 * (completion raced). A pathological kernel/driver that never completes
 * cancellation may delay return: do not run this on a UI thread or promise
 * a hard wall-clock bound for the drain itself. */
static void cancel_and_drain(HANDLE pipe, OVERLAPPED *overlapped) {
    DWORD ignored = 0;
    (void)CancelIoEx(pipe, overlapped);
    (void)GetOverlappedResult(pipe, overlapped, &ignored, TRUE);
}

static op_pipe_result io_failure(DWORD err, int reading) {
    if (reading && err == ERROR_BROKEN_PIPE) return OP_PIPE_OK;
    if (err == ERROR_OPERATION_ABORTED) return OP_PIPE_CANCELED;
    return OP_PIPE_IO_ERROR;
}

static op_pipe_result transfer(op_pipe *pipe, void *buffer, DWORD size,
    DWORD *count, uint64_t deadline, HANDLE cancel, int reading) {
    if (!count) return OP_PIPE_INVALID;
    *count = 0;
    if (!pipe || !pipe->handle || pipe->handle == INVALID_HANDLE_VALUE ||
        !buffer || size == 0 || size > OP_MAX_IO) return OP_PIPE_INVALID;
    op_pipe_result result = gate(deadline, cancel);
    if (result != OP_PIPE_OK) return result;

    OVERLAPPED overlapped = {0};
    overlapped.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!overlapped.hEvent) return OP_PIPE_IO_ERROR;
    DWORD transferred = 0;
    BOOL immediate = reading
        ? ReadFile(pipe->handle, buffer, size, &transferred, &overlapped)
        : WriteFile(pipe->handle, buffer, size, &transferred, &overlapped);
    if (!immediate) {
        DWORD err = GetLastError();
        if (err != ERROR_IO_PENDING) {
            result = io_failure(err, reading);
            CloseHandle(overlapped.hEvent);
            return result;
        }

        HANDLE events[2] = {overlapped.hEvent, cancel};
        DWORD wait = WaitForMultipleObjects(cancel ? 2 : 1, events, FALSE,
            remaining(deadline));
        if (wait == WAIT_OBJECT_0) {
            if (!GetOverlappedResult(pipe->handle, &overlapped, &transferred, FALSE))
                result = io_failure(GetLastError(), reading);
        } else {
            result = wait == WAIT_TIMEOUT ? OP_PIPE_TIMEOUT :
                (cancel && wait == WAIT_OBJECT_0 + 1 ? OP_PIPE_CANCELED : OP_PIPE_IO_ERROR);
            cancel_and_drain(pipe->handle, &overlapped);
        }
    }
    CloseHandle(overlapped.hEvent);
    if (result == OP_PIPE_OK) result = gate(deadline, cancel);
    if (result == OP_PIPE_OK) {
        if (transferred > size || (!reading && transferred == 0))
            return OP_PIPE_IO_ERROR;
        *count = transferred;
    }
    return result;
}

op_pipe_result op_pipe_read(op_pipe *pipe, void *buffer, DWORD capacity,
    DWORD *count, uint64_t deadline, HANDLE cancel) {
    return transfer(pipe, buffer, capacity, count, deadline, cancel, 1);
}

op_pipe_result op_pipe_write(op_pipe *pipe, const void *buffer, DWORD size,
    DWORD *count, uint64_t deadline, HANDLE cancel) {
    return transfer(pipe, (void *)buffer, size, count, deadline, cancel, 0);
}
