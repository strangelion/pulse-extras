#ifndef PULSE_OPENPETS_BRIDGE_WIN32_H
#define PULSE_OPENPETS_BRIDGE_WIN32_H
#include "openpets_trust_win32.h"

uint64_t op_bridge_now(void);
op_pipe_result op_bridge_discovery(const wchar_t *directory, void *buffer,
    DWORD capacity, DWORD *count, uint64_t deadline, HANDLE cancel);
op_pipe_result op_bridge_connect(op_pipe *pipe, const char *endpoint,
    DWORD length, DWORD pid, const wchar_t *image, uint64_t deadline, HANDLE cancel);
#endif
