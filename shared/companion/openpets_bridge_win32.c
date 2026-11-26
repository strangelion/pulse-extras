#include "openpets_bridge_win32.h"

uint64_t op_bridge_now(void) {
    return GetTickCount64();
}

op_pipe_result op_bridge_discovery(const wchar_t *directory, void *buffer,
    DWORD capacity, DWORD *count, uint64_t deadline, HANDLE cancel) {
    if (!count) return OP_PIPE_INVALID;
    *count = 0;
    if (!buffer || !capacity || capacity > OP_DISCOVERY_MAX) return OP_PIPE_INVALID;
    SecureZeroMemory(buffer, capacity);
    HANDLE handle = NULL;
    op_pipe_result result = op_open_runtime_directory(directory, &handle, deadline, cancel);
    if (result != OP_PIPE_OK) return result;
    result = op_read_discovery(handle, buffer, capacity, count, deadline, cancel);
    CloseHandle(handle);
    return result;
}

op_pipe_result op_bridge_connect(op_pipe *pipe, const char *endpoint,
    DWORD length, DWORD pid, const wchar_t *image, uint64_t deadline, HANDLE cancel) {
    wchar_t wide[241];
    if (!pipe || pipe->handle || !endpoint || !length || length > 240)
        return OP_PIPE_INVALID;
    for (DWORD i = 0; i < length; ++i) {
        unsigned char c = (unsigned char)endpoint[i];
        if (c < 32 || c > 126) return OP_PIPE_UNTRUSTED;
        wide[i] = (wchar_t)c;
    }
    wide[length] = L'\0';
    HANDLE process = NULL;
    op_pipe_result result = op_open_candidate_process(pid, image, &process, deadline, cancel);
    if (result != OP_PIPE_OK) return result;
    result = op_pipe_open_verified(pipe, wide, process, deadline, cancel);
    CloseHandle(process);
    return result;
}
