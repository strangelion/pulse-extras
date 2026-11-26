#include "metrics_win32.h"
#include <psapi.h>

static uint64_t ticks(FILETIME t) {
    return ((uint64_t)t.dwHighDateTime << 32) | t.dwLowDateTime;
}

BOOL pulse_process_sample(HANDLE process, pulse_process_metrics *out) {
    if (!process || process == INVALID_HANDLE_VALUE || !out) {
        SetLastError(ERROR_INVALID_PARAMETER);
        return FALSE;
    }
    DWORD state = WaitForSingleObject(process, 0);
    if (state != WAIT_TIMEOUT) {
        if (state != WAIT_FAILED) SetLastError(ERROR_PROCESS_ABORTED);
        return FALSE;
    }
    PROCESS_MEMORY_COUNTERS_EX memory = {0};
    memory.cb = sizeof(memory);
    DWORD handles = 0, pid = GetProcessId(process);
    FILETIME created, exited, kernel, user;
    if (!pid || !GetProcessMemoryInfo(process, (PROCESS_MEMORY_COUNTERS *)&memory, sizeof(memory)) ||
        !GetProcessHandleCount(process, &handles) ||
        !GetProcessTimes(process, &created, &exited, &kernel, &user)) return FALSE;
    state = WaitForSingleObject(process, 0);
    if (state != WAIT_TIMEOUT) {
        if (state != WAIT_FAILED) SetLastError(ERROR_PROCESS_ABORTED);
        return FALSE;
    }
    *out = (pulse_process_metrics){memory.PrivateUsage, memory.WorkingSetSize,
        ticks(kernel) + ticks(user), GetTickCount64(), handles, pid};
    return TRUE;
}
