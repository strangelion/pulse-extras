#include "pet_supervisor_win32.h"
#include <wchar.h>
#include <stdlib.h>

#define PATH_CAP 1024u
#define CMD_CAP 1400u
#define STOP_MAX_MS 5000u

static LONG live_owner = 0;

static HANDLE pin_image(const wchar_t *path) {
    if (!path) return INVALID_HANDLE_VALUE;
    size_t n = 0;
    while (n < PATH_CAP && path[n]) ++n;
    if (n < 8 || n == PATH_CAP || !((path[0] >= L'A' && path[0] <= L'Z') ||
        (path[0] >= L'a' && path[0] <= L'z')) || path[1] != L':' ||
        path[2] != L'\\' || CompareStringOrdinal(path + n - 4, 4, L".exe", 4, TRUE) != CSTR_EQUAL)
        return INVALID_HANDLE_VALUE;
    size_t component = 3;
    for (size_t i = 3; i <= n; ++i) {
        wchar_t c = path[i];
        if (c == L'\\' || !c) {
            if (i == component || path[i - 1] == L'.' || path[i - 1] == L' ')
                return INVALID_HANDLE_VALUE;
            component = i + 1;
        } else if (c < 32 || c == L'"' || c == L'/' || c == L':' ||
            c == L'*' || c == L'?' || c == L'<' || c == L'>' || c == L'|') {
            return INVALID_HANDLE_VALUE;
        }
    }
    wchar_t root[] = {path[0], L':', L'\\', 0};
    if (GetDriveTypeW(root) != DRIVE_FIXED) return INVALID_HANDLE_VALUE;
    HANDLE image = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (image == INVALID_HANDLE_VALUE) return image;
    BY_HANDLE_FILE_INFORMATION info;
    wchar_t actual[PATH_CAP + 4];
    DWORD length = GetFinalPathNameByHandleW(image, actual, PATH_CAP + 4,
        FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (GetFileType(image) != FILE_TYPE_DISK || !GetFileInformationByHandle(image, &info) ||
        info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) ||
        info.nFileSizeHigh || !info.nFileSizeLow || info.nFileSizeLow > 256u * 1024u * 1024u ||
        length != n + 4 || length >= PATH_CAP + 4 ||
        wcsncmp(actual, L"\\\\?\\", 4) != 0 ||
        CompareStringOrdinal(actual + 4, -1, path, -1, TRUE) != CSTR_EQUAL) {
        CloseHandle(image);
        return INVALID_HANDLE_VALUE;
    }
    return image;
}

void pet_child_abandon(pet_supervisor *owner) {
    if (!owner || !owner->job) return;
    CloseHandle(owner->job); /* KILL_ON_JOB_CLOSE; never inherited */
    if (owner->process) CloseHandle(owner->process);
    if (owner->stop) CloseHandle(owner->stop);
    *owner = (pet_supervisor){0};
    InterlockedExchange(&live_owner, 0);
}

pet_child_result pet_child_start(pet_supervisor *owner, const wchar_t *approved_exe,
    const pet_child_options *options) {
    if (!owner || !options || options->scale < PET_MIN_SCALE ||
        options->scale > PET_MAX_SCALE ||
        (options->smoke && (options->remember || options->reduced || options->topmost)))
        return PET_CHILD_INVALID;
    if (owner->job || owner->process || owner->stop) return PET_CHILD_BUSY;
    if (InterlockedCompareExchange(&live_owner, 1, 0) != 0) return PET_CHILD_BUSY;

    pet_child_result result = PET_CHILD_OS_ERROR;
    HANDLE image = INVALID_HANDLE_VALUE, job = NULL, stop = NULL, child_stop = NULL;
    LPPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
    BOOL initialized = FALSE;
    PROCESS_INFORMATION child = {0};
    image = pin_image(approved_exe);
    if (image == INVALID_HANDLE_VALUE) { result = PET_CHILD_INVALID; goto cleanup; }
    job = CreateJobObjectW(NULL, NULL);
    if (!job) goto cleanup;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
        JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
    limits.BasicLimitInformation.ActiveProcessLimit = 1;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
        result = PET_CHILD_CONTAINMENT_FAILED; goto cleanup;
    }
    stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!stop || !DuplicateHandle(GetCurrentProcess(), stop, GetCurrentProcess(),
        &child_stop, SYNCHRONIZE, TRUE, 0)) goto cleanup;
    SIZE_T bytes = 0;
    InitializeProcThreadAttributeList(NULL, 2, 0, &bytes);
    if (!bytes || bytes > 65536) goto cleanup;
    attributes = malloc(bytes);
    if (!attributes || !InitializeProcThreadAttributeList(attributes, 2, 0, &bytes)) goto cleanup;
    initialized = TRUE;
    if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
        &child_stop, sizeof(child_stop), NULL, NULL) ||
        !UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
        &job, sizeof(job), NULL, NULL)) {
        result = PET_CHILD_CONTAINMENT_FAILED; goto cleanup;
    }

    wchar_t command[CMD_CAP];
    int written = swprintf(command, CMD_CAP, L"\"%ls\" --stop-handle %llu --scale %u%ls%ls%ls",
        approved_exe, (unsigned long long)(uintptr_t)child_stop, options->scale,
        options->smoke ? L" --smoke" : (options->reduced ? L" --reduced-motion" : L""),
        options->topmost ? L" --topmost" : L"", options->remember ? L" --remember" : L"");
    if (written < 0 || (unsigned)written >= CMD_CAP) { result = PET_CHILD_INVALID; goto cleanup; }
    /* No inherited PATH, credentials or loader variables. Use system cwd;
     * the approved installation directory still must be trusted by caller. */
    wchar_t cwd[PATH_CAP], env[PATH_CAP + 16] = L"SystemRoot=";
    UINT cwd_len = GetSystemDirectoryW(cwd, PATH_CAP);
    UINT root_len = GetWindowsDirectoryW(env + 11, PATH_CAP);
    if (!cwd_len || cwd_len >= PATH_CAP || !root_len || root_len >= PATH_CAP) goto cleanup;
    env[11 + root_len + 1] = 0;
    STARTUPINFOEXW startup = {0};
    startup.StartupInfo.cb = sizeof(startup);
    startup.lpAttributeList = attributes;
    if (!CreateProcessW(approved_exe, command, NULL, NULL, TRUE,
        EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT |
        CREATE_SUSPENDED | CREATE_NO_WINDOW, env, cwd, &startup.StartupInfo, &child)) {
        result = PET_CHILD_CONTAINMENT_FAILED; goto cleanup;
    }
    /* Job-list assignment is atomic with creation, unlike assigning after
     * spawn. Never resume if the kernel did not confirm containment. */
    BOOL contained = FALSE;
    if (!IsProcessInJob(child.hProcess, job, &contained) || !contained ||
        ResumeThread(child.hThread) != 1) {
        result = PET_CHILD_CONTAINMENT_FAILED; goto cleanup;
    }
    owner->job = job; owner->process = child.hProcess; owner->stop = stop;
    job = NULL; child.hProcess = NULL; stop = NULL;
    result = PET_CHILD_OK;
cleanup:
    if (child.hProcess) {
        TerminateProcess(child.hProcess, 1);
        WaitForSingleObject(child.hProcess, STOP_MAX_MS);
        CloseHandle(child.hProcess);
    }
    if (child.hThread) CloseHandle(child.hThread);
    if (initialized) DeleteProcThreadAttributeList(attributes);
    free(attributes);
    if (child_stop) CloseHandle(child_stop);
    if (stop) CloseHandle(stop);
    if (job) CloseHandle(job);
    if (image != INVALID_HANDLE_VALUE) CloseHandle(image);
    if (result != PET_CHILD_OK) InterlockedExchange(&live_owner, 0);
    return result;
}

pet_child_result pet_child_status(const pet_supervisor *owner, BOOL *running, DWORD *exit_code) {
    if (!owner || !owner->job || !owner->process || !running || !exit_code)
        return PET_CHILD_INVALID;
    DWORD state = WaitForSingleObject(owner->process, 0);
    if (state == WAIT_TIMEOUT) { *running = TRUE; *exit_code = 0; return PET_CHILD_OK; }
    if (state != WAIT_OBJECT_0 || !GetExitCodeProcess(owner->process, exit_code))
        return PET_CHILD_OS_ERROR;
    *running = FALSE;
    return PET_CHILD_OK;
}

pet_child_result pet_child_stop(pet_supervisor *owner, DWORD grace_ms,
    BOOL *forced, DWORD *exit_code) {
    if (!owner || !owner->job || !owner->process || !owner->stop ||
        !forced || !exit_code || grace_ms > STOP_MAX_MS) return PET_CHILD_INVALID;
    BOOL killed = FALSE;
    DWORD state = WaitForSingleObject(owner->process, 0);
    if (state == WAIT_TIMEOUT) {
        if (!SetEvent(owner->stop)) return PET_CHILD_OS_ERROR;
        state = WaitForSingleObject(owner->process, grace_ms);
        if (state == WAIT_TIMEOUT) {
            if (!TerminateJobObject(owner->job, 1)) return PET_CHILD_CONTAINMENT_FAILED;
            killed = TRUE;
            state = WaitForSingleObject(owner->process, STOP_MAX_MS);
        }
    }
    if (state == WAIT_TIMEOUT) return PET_CHILD_TIMEOUT;
    if (state != WAIT_OBJECT_0 || !GetExitCodeProcess(owner->process, exit_code))
        return PET_CHILD_OS_ERROR;
    *forced = killed;
    pet_child_abandon(owner);
    return PET_CHILD_OK;
}
