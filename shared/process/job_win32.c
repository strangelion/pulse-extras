#include "job_win32.h"

BOOL pulse_job_configure(HANDLE job, DWORD max_processes, SIZE_T process_commit, SIZE_T job_commit) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    if (!job || job == INVALID_HANDLE_VALUE || (job_commit && process_commit > job_commit)) {
        SetLastError(ERROR_INVALID_PARAMETER);
        return FALSE;
    }
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (max_processes) {
        limits.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
        limits.BasicLimitInformation.ActiveProcessLimit = max_processes;
    }
    if (process_commit) {
        limits.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_PROCESS_MEMORY;
        limits.ProcessMemoryLimit = process_commit;
    }
    if (job_commit) {
        limits.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_JOB_MEMORY;
        limits.JobMemoryLimit = job_commit;
    }
    return SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits));
}

BOOL pulse_job_active(HANDLE job, DWORD *active) {
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info = {0};
    if (!job || job == INVALID_HANDLE_VALUE || !active) {
        SetLastError(ERROR_INVALID_PARAMETER);
        return FALSE;
    }
    if (!QueryInformationJobObject(job, JobObjectBasicAccountingInformation, &info, sizeof(info), NULL))
        return FALSE;
    *active = info.ActiveProcesses;
    return TRUE;
}

BOOL pulse_job_terminate_and_drain(HANDLE job, UINT exit_code, DWORD timeout_ms) {
    DWORD active = 0;
    if (!timeout_ms || timeout_ms > 60000u) {
        SetLastError(ERROR_INVALID_PARAMETER);
        return FALSE;
    }
    if (!pulse_job_active(job, &active)) return FALSE;
    if (!active) return TRUE;
    if (!TerminateJobObject(job, exit_code)) return FALSE;
    ULONGLONG start = GetTickCount64();
    for (;;) {
        if (!pulse_job_active(job, &active)) return FALSE;
        if (!active) return TRUE;
        if (GetTickCount64() - start >= timeout_ms) {
            SetLastError(ERROR_TIMEOUT);
            return FALSE;
        }
        Sleep(10);
    }
}
