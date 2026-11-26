#include "pet_supervisor_win32.h"
#include <wchar.h>
#include <stdlib.h>
#include <string.h>
#include <psapi.h>
#include <bcrypt.h>

#define PATH_CAP 1024u
#define CMD_CAP 2600u
#define STOP_MAX_MS 5000u

/* 0 = none, 1 = legacy singleton, 2 = group. Group identity is worker-owned. */
static LONG live_owner = 0;
static pet_supervisor_group *active_group = NULL;

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
        SetLastError(ERROR_BAD_PATHNAME);
        return INVALID_HANDLE_VALUE;
    }
    return image;
}

/* Use the already pinned handle: no pathname reopen between the hash and
 * process creation. Resolve the OS crypto provider from System32 only,
 * keeping the existing GNU test link commands and MSVC boundary intact. */
static pet_child_result verify_image(HANDLE image, const uint8_t expected[32]) {
    typedef NTSTATUS (WINAPI *open_fn)(BCRYPT_ALG_HANDLE *, LPCWSTR, LPCWSTR, ULONG);
    typedef NTSTATUS (WINAPI *property_fn)(BCRYPT_HANDLE, LPCWSTR, PUCHAR, ULONG, ULONG *, ULONG);
    typedef NTSTATUS (WINAPI *create_fn)(BCRYPT_ALG_HANDLE, BCRYPT_HASH_HANDLE *, PUCHAR, ULONG, PUCHAR, ULONG, ULONG);
    typedef NTSTATUS (WINAPI *data_fn)(BCRYPT_HASH_HANDLE, PUCHAR, ULONG, ULONG);
    typedef NTSTATUS (WINAPI *finish_fn)(BCRYPT_HASH_HANDLE, PUCHAR, ULONG, ULONG);
    typedef NTSTATUS (WINAPI *destroy_fn)(BCRYPT_HASH_HANDLE);
    typedef NTSTATUS (WINAPI *close_fn)(BCRYPT_ALG_HANDLE, ULONG);
    HMODULE module = LoadLibraryExW(L"bcrypt.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module) return PET_CHILD_OS_ERROR;
    open_fn open = (open_fn)GetProcAddress(module, "BCryptOpenAlgorithmProvider");
    property_fn property = (property_fn)GetProcAddress(module, "BCryptGetProperty");
    create_fn create = (create_fn)GetProcAddress(module, "BCryptCreateHash");
    data_fn update = (data_fn)GetProcAddress(module, "BCryptHashData");
    finish_fn finish = (finish_fn)GetProcAddress(module, "BCryptFinishHash");
    destroy_fn destroy = (destroy_fn)GetProcAddress(module, "BCryptDestroyHash");
    close_fn close = (close_fn)GetProcAddress(module, "BCryptCloseAlgorithmProvider");
    pet_child_result result = PET_CHILD_OS_ERROR;
    BCRYPT_ALG_HANDLE algorithm = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    PUCHAR object = NULL;
    DWORD object_size = 0, digest_size = 0, got = 0;
    unsigned char buffer[16384], digest[32];
    LARGE_INTEGER size;
    if (!open || !property || !create || !update || !finish || !destroy || !close ||
        !GetFileSizeEx(image, &size) || size.QuadPart <= 0 ||
        size.QuadPart > 256ll * 1024 * 1024) goto done;
    if (open(&algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0) < 0 ||
        property(algorithm, BCRYPT_OBJECT_LENGTH, (PUCHAR)&object_size, sizeof(object_size), &got, 0) < 0 ||
        got != sizeof(object_size) || !object_size || object_size > 65536 ||
        property(algorithm, BCRYPT_HASH_LENGTH, (PUCHAR)&digest_size, sizeof(digest_size), &got, 0) < 0 ||
        got != sizeof(digest_size) || digest_size != sizeof(digest)) goto done;
    object = malloc(object_size);
    if (!object || create(algorithm, &hash, object, object_size, NULL, 0, 0) < 0) goto done;
    uint64_t remaining = (uint64_t)size.QuadPart;
    while (remaining) {
        DWORD want = remaining > sizeof(buffer) ? (DWORD)sizeof(buffer) : (DWORD)remaining;
        if (!ReadFile(image, buffer, want, &got, NULL) || got != want ||
            update(hash, buffer, got, 0) < 0) goto done;
        remaining -= got;
    }
    if (finish(hash, digest, sizeof(digest), 0) < 0) goto done;
    result = memcmp(digest, expected, sizeof(digest)) == 0 ?
        PET_CHILD_OK : PET_CHILD_UNAPPROVED_IMAGE;
done:
    if (hash && destroy(hash) < 0) result = PET_CHILD_OS_ERROR;
    free(object);
    if (algorithm && close(algorithm, 0) < 0) result = PET_CHILD_OS_ERROR;
    if (!FreeLibrary(module)) result = PET_CHILD_OS_ERROR;
    return result;
}

static void release_child(pet_supervisor *owner) {
    if (!owner || !owner->job) return;
    CloseHandle(owner->job); /* KILL_ON_JOB_CLOSE; never inherited */
    if (owner->process) CloseHandle(owner->process);
    if (owner->stop) CloseHandle(owner->stop);
    if (owner->state_slot) UnmapViewOfFile((const void *)owner->state_slot);
    if (owner->state_mapping) CloseHandle(owner->state_mapping);
    if (owner->state_event) CloseHandle(owner->state_event);
    if (owner->ready_event) CloseHandle(owner->ready_event);
    *owner = (pet_supervisor){0};
}

void pet_child_abandon(pet_supervisor *owner) {
    if (!owner || !owner->job) return;
    release_child(owner);
    InterlockedExchange(&live_owner, 0);
}

/* Strict structured DOS path and package ID. The child performs full
 * package validation and holds the actual asset handles during its lifetime.
 * The caller must supply an independently validated private asset root. */
static BOOL package_args(const wchar_t *directory, const wchar_t *id) {
    if (!directory || !id) return FALSE;
    size_t n = 0;
    while (n < PATH_CAP && directory[n]) ++n;
    if (n < 4 || n >= PATH_CAP ||
        !((directory[0] >= L'A' && directory[0] <= L'Z') ||
          (directory[0] >= L'a' && directory[0] <= L'z')) ||
        directory[1] != L':' || directory[2] != L'\\') return FALSE;
    size_t component = 3;
    for (size_t i = 3; i <= n; ++i) {
        wchar_t ch = directory[i];
        if (ch == L'\\' || !ch) {
            if (i == component || directory[i - 1] == L'.' || directory[i - 1] == L' ') return FALSE;
            component = i + 1;
        } else if (ch < 32 || ch == L'"' || ch == L'/' || ch == L':' ||
            ch == L'*' || ch == L'?' || ch == L'<' || ch == L'>' || ch == L'|') return FALSE;
    }
    wchar_t drive[] = {directory[0], L':', L'\\', 0};
    if (GetDriveTypeW(drive) != DRIVE_FIXED) return FALSE;
    size_t len = 0;
    while (len <= 64 && id[len]) {
        wchar_t ch = id[len];
        if (!((ch >= L'a' && ch <= L'z') || (ch >= L'0' && ch <= L'9') ||
              (len && (ch == L'-' || ch == L'_')))) return FALSE;
        ++len;
    }
    return len && len <= 64 && wcscmp(id, L"builtin") != 0;
}

/* Launch the same already pinned/verified image in a separate diagnostic
 * job. No broad handle inheritance, no host DbgHelp calls. The renderer
 * remains suspended until this monitor confirms debugger attachment. */
static void release_monitor(pet_crash_monitor *monitor) {
    if (!monitor) return;
    if (monitor->job) CloseHandle(monitor->job);
    if (monitor->process) CloseHandle(monitor->process);
    if (monitor->capture_event) CloseHandle(monitor->capture_event);
    *monitor = (pet_crash_monitor){0};
}

static BOOL start_monitor(pet_crash_monitor *monitor, const wchar_t *image,
    HANDLE target, wchar_t *env, const wchar_t *cwd) {
    HANDLE ready = NULL, capture_event = NULL, inherited[3] = {0}, job = NULL;
    PROCESS_INFORMATION child = {0};
    LPPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
    BOOL initialized = FALSE, success = FALSE;
    SIZE_T bytes = 0;
    wchar_t command[CMD_CAP];
    ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    capture_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    job = CreateJobObjectW(NULL, NULL);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
        JOB_OBJECT_LIMIT_ACTIVE_PROCESS | JOB_OBJECT_LIMIT_PROCESS_MEMORY | JOB_OBJECT_LIMIT_JOB_MEMORY;
    limits.BasicLimitInformation.ActiveProcessLimit = 1;
    limits.ProcessMemoryLimit = PET_CHILD_COMMIT_LIMIT;
    limits.JobMemoryLimit = PET_CHILD_COMMIT_LIMIT;
    if (!ready || !capture_event || !job ||
        !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)) ||
        !DuplicateHandle(GetCurrentProcess(), target, GetCurrentProcess(), &inherited[0],
            PROCESS_QUERY_INFORMATION | PROCESS_VM_READ | PROCESS_DUP_HANDLE | SYNCHRONIZE, TRUE, 0) ||
        !DuplicateHandle(GetCurrentProcess(), ready, GetCurrentProcess(), &inherited[1],
            EVENT_MODIFY_STATE, TRUE, 0) ||
        !DuplicateHandle(GetCurrentProcess(), capture_event, GetCurrentProcess(), &inherited[2],
            EVENT_MODIFY_STATE, TRUE, 0)) goto done;
    InitializeProcThreadAttributeList(NULL, 2, 0, &bytes);
    if (!bytes || bytes > 65536) goto done;
    attributes = malloc(bytes);
    if (!attributes || !InitializeProcThreadAttributeList(attributes, 2, 0, &bytes)) goto done;
    initialized = TRUE;
    if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
            inherited, sizeof(inherited), NULL, NULL) ||
        !UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
            &job, sizeof(job), NULL, NULL)) goto done;
    int n = swprintf(command, CMD_CAP, L"\"%ls\" --crash-watch %llu %llu %llu", image,
        (unsigned long long)(uintptr_t)inherited[0], (unsigned long long)(uintptr_t)inherited[1],
        (unsigned long long)(uintptr_t)inherited[2]);
    if (n <= 0 || n >= (int)CMD_CAP) goto done;
    STARTUPINFOEXW startup = {0};
    startup.StartupInfo.cb = sizeof(startup);
    startup.lpAttributeList = attributes;
    if (!CreateProcessW(image, command, NULL, NULL, TRUE,
        EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED |
        CREATE_NO_WINDOW, env, cwd, &startup.StartupInfo, &child)) goto done;
    monitor->job = job; job = NULL;
    monitor->process = child.hProcess;
    monitor->capture_event = capture_event; capture_event = NULL;
    BOOL contained = FALSE;
    if (!IsProcessInJob(child.hProcess, monitor->job, &contained)) goto done;
    if (!contained) { SetLastError(ERROR_ACCESS_DENIED); goto done; }
    DWORD previous = ResumeThread(child.hThread);
    if (previous == (DWORD)-1) goto done;
    if (previous != 1) {
        SetLastError(0x20080000u | (previous & 0xffffu));
        goto done;
    }
    HANDLE waits[] = {ready, child.hProcess};
    DWORD wait = WaitForMultipleObjects(2, waits, FALSE, 3000);
    if (wait == WAIT_OBJECT_0) {
        success = WaitForSingleObject(child.hProcess, 0) == WAIT_TIMEOUT;
        if (!success) SetLastError(ERROR_PROCESS_ABORTED);
    } else if (wait == WAIT_TIMEOUT) {
        SetLastError(ERROR_TIMEOUT);
    } else if (wait == WAIT_OBJECT_0 + 1) {
        DWORD code = 0;
        /* Private watcher startup failures use the Win32 application
         * error bit. Preserve the phase/error through cleanup. */
        if (GetExitCodeProcess(child.hProcess, &code) && (code & 0x20000000u))
            SetLastError(code);
        else
            SetLastError(ERROR_PROCESS_ABORTED);
    }
done: ;
    DWORD startup_error = success ? ERROR_SUCCESS : GetLastError();
    if (child.hThread) CloseHandle(child.hThread);
    if (initialized) DeleteProcThreadAttributeList(attributes);
    free(attributes);
    for (unsigned i = 0; i < 3; ++i) if (inherited[i]) CloseHandle(inherited[i]);
    if (ready) CloseHandle(ready);
    if (capture_event) CloseHandle(capture_event);
    if (job) CloseHandle(job);
    if (!success) SetLastError(startup_error ? startup_error : ERROR_GEN_FAILURE);
    return success;
}

static pet_child_result start_child(pet_supervisor *owner, const wchar_t *approved_exe,
    const pet_child_options *options, const wchar_t *directory, const wchar_t *package_id, const wchar_t *expected_sha, const uint8_t *image_sha, pet_crash_monitor *monitor) {
    if (!owner || !options || options->scale < PET_MIN_SCALE ||
        options->scale > PET_MAX_SCALE ||
        (options->smoke && (options->remember || options->reduced || options->topmost)))
        return PET_CHILD_INVALID;
    if (owner->job || owner->process || owner->stop || owner->state_mapping ||
        owner->state_event || owner->state_slot || owner->ready_event) return PET_CHILD_BUSY;
    if ((directory || package_id) && (options->smoke || options->remember ||
        !package_args(directory, package_id))) return PET_CHILD_INVALID;
    if (expected_sha) {
        size_t len = wcslen(expected_sha);
        if (!directory || (len != 64 && len != 193)) return PET_CHILD_INVALID;
        for (size_t i = 0; i < len; ++i) {
            if (len == 193 && i == 64) { if (expected_sha[i] != L':') return PET_CHILD_INVALID; continue; }
            wchar_t ch = expected_sha[i];
            if (!((ch >= L'0' && ch <= L'9') || (ch >= L'a' && ch <= L'f'))) return PET_CHILD_INVALID;
        }
    }
    pet_child_result result = PET_CHILD_OS_ERROR;
    HANDLE image = INVALID_HANDLE_VALUE, job = NULL, stop = NULL;
    HANDLE mapping = NULL, event = NULL, ready = NULL;
    HANDLE inherited[4] = {0};
    volatile LONG *slot = NULL;
    LPPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
    BOOL initialized = FALSE;
    PROCESS_INFORMATION child = {0};
    image = pin_image(approved_exe);
    if (image == INVALID_HANDLE_VALUE) { result = PET_CHILD_INVALID; goto cleanup; }
    if (image_sha) {
        result = verify_image(image, image_sha);
        if (result != PET_CHILD_OK) goto cleanup;
        result = PET_CHILD_OS_ERROR;
    }
    job = CreateJobObjectW(NULL, NULL);
    if (!job) goto cleanup;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    /* Bound committed memory, including decoder/CRT scratch not covered
     * by the application allocator. Configure before creating the child.
     * Failure is fail-closed; never start an unbounded replacement. */
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
        JOB_OBJECT_LIMIT_ACTIVE_PROCESS | JOB_OBJECT_LIMIT_PROCESS_MEMORY |
        JOB_OBJECT_LIMIT_JOB_MEMORY;
    limits.BasicLimitInformation.ActiveProcessLimit = 1;
    limits.ProcessMemoryLimit = PET_CHILD_COMMIT_LIMIT;
    limits.JobMemoryLimit = PET_CHILD_COMMIT_LIMIT;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
        result = PET_CHILD_CONTAINMENT_FAILED; goto cleanup;
    }
    stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!stop || !DuplicateHandle(GetCurrentProcess(), stop, GetCurrentProcess(),
        &inherited[0], SYNCHRONIZE, TRUE, 0)) goto cleanup;
    mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0,
        sizeof(LONG), NULL);
    event = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!mapping || !event) goto cleanup;
    slot = MapViewOfFile(mapping, FILE_MAP_WRITE, 0, 0, sizeof(LONG));
    if (!slot) goto cleanup;
    InterlockedExchange(slot, 1 << 4);
    if (!DuplicateHandle(GetCurrentProcess(), mapping, GetCurrentProcess(),
        &inherited[1], SECTION_MAP_READ, TRUE, 0) ||
        !DuplicateHandle(GetCurrentProcess(), event, GetCurrentProcess(),
        &inherited[2], SYNCHRONIZE, TRUE, 0)) goto cleanup;
    ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!ready || !DuplicateHandle(GetCurrentProcess(), ready, GetCurrentProcess(),
        &inherited[3], EVENT_MODIFY_STATE, TRUE, 0)) goto cleanup;
    SIZE_T bytes = 0;
    InitializeProcThreadAttributeList(NULL, 2, 0, &bytes);
    if (!bytes || bytes > 65536) goto cleanup;
    attributes = malloc(bytes);
    if (!attributes || !InitializeProcThreadAttributeList(attributes, 2, 0, &bytes)) goto cleanup;
    initialized = TRUE;
    if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
        inherited, sizeof(inherited), NULL, NULL) ||
        !UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
        &job, sizeof(job), NULL, NULL)) {
        result = PET_CHILD_CONTAINMENT_FAILED; goto cleanup;
    }

    wchar_t command[CMD_CAP];
    int written = swprintf(command, CMD_CAP, L"\"%ls\" --stop-handle %llu --scale %u%ls%ls%ls --state-map %llu --state-event %llu --ready-event %llu",
        approved_exe, (unsigned long long)(uintptr_t)inherited[0], options->scale,
        options->smoke ? L" --smoke" : (options->reduced ? L" --reduced-motion" : L""),
        options->topmost ? L" --topmost" : L"", options->remember ? L" --remember" : L"",
        (unsigned long long)(uintptr_t)inherited[1], (unsigned long long)(uintptr_t)inherited[2],
        (unsigned long long)(uintptr_t)inherited[3]);
    if (written < 0 || (unsigned)written >= CMD_CAP) { result = PET_CHILD_INVALID; goto cleanup; }
    if (directory) {
        size_t remaining = CMD_CAP - (unsigned)written;
        int appended = swprintf(command + written, remaining, L" --package \"%ls\" %ls", directory, package_id);
        if (appended < 0 || (size_t)appended >= remaining) { result = PET_CHILD_INVALID; goto cleanup; }
        written += appended;
    }
    if (expected_sha) {
        size_t remaining = CMD_CAP - (unsigned)written;
        int appended = swprintf(command + written, remaining, L" %ls %ls", wcslen(expected_sha) == 193 ? L"--expected-fingerprint" : L"--expected-sha256", expected_sha);
        if (appended < 0 || (size_t)appended >= remaining) { result = PET_CHILD_INVALID; goto cleanup; }
    }
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
    if (!IsProcessInJob(child.hProcess, job, &contained)) {
        result = PET_CHILD_CONTAINMENT_FAILED; goto cleanup;
    }
    if (!contained) {
        SetLastError(ERROR_ACCESS_DENIED);
        result = PET_CHILD_CONTAINMENT_FAILED; goto cleanup;
    }
    if (monitor && (!image_sha || !start_monitor(monitor, approved_exe, child.hProcess, env, cwd))) {
        if (!image_sha) SetLastError(ERROR_INVALID_PARAMETER);
        result = PET_CHILD_CONTAINMENT_FAILED; goto cleanup;
    }
    /* DebugActiveProcess may temporarily hold its own suspension while
     * delivering initial debug events. Release only the one suspension
     * that we own (CREATE_SUSPENDED), never loop ResumeThread. The
     * debugger releases its own suspension as events are continued.
     * Normal unmonitored launches still require exactly one.
     * A renderer is not ready until the separate ready event is observed. */
    DWORD previous = ResumeThread(child.hThread);
    if (previous == (DWORD)-1) {
        result = PET_CHILD_CONTAINMENT_FAILED; goto cleanup;
    }
    if (previous != 1 && !(monitor && previous == 2)) {
        /* Application-defined phase 7 records unexpected suspend count.
         * ResumeThread does not set last-error on a successful call. */
        SetLastError(0x20070000u | (previous & 0xffffu));
        result = PET_CHILD_CONTAINMENT_FAILED; goto cleanup;
    }
    owner->job = job; owner->process = child.hProcess; owner->stop = stop;
    owner->state_mapping = mapping; owner->state_event = event;
    owner->ready_event = ready; ready = NULL;
    owner->state_slot = slot; owner->generation = 1; owner->reaction = PET_STATE_IDLE;
    job = NULL; child.hProcess = NULL; stop = NULL;
    mapping = NULL; event = NULL; slot = NULL;
    result = PET_CHILD_OK;
cleanup: ;
    DWORD launch_error = result == PET_CHILD_OK ? ERROR_SUCCESS : GetLastError();
    if (child.hProcess) {
        if (monitor && monitor->job) (void)TerminateJobObject(monitor->job, 2);
        TerminateProcess(child.hProcess, 1);
        BOOL target_done = WaitForSingleObject(child.hProcess, STOP_MAX_MS) == WAIT_OBJECT_0;
        BOOL monitor_done = !monitor || !monitor->process ||
            WaitForSingleObject(monitor->process, STOP_MAX_MS) == WAIT_OBJECT_0;
        if (target_done && monitor_done) {
            release_monitor(monitor);
            CloseHandle(child.hProcess);
        } else {
            /* Never claim a failed creation is gone on an ambiguous wait.
             * The group keeps this reservation and owned handles to reap. */
            owner->job = job; job = NULL;
            owner->process = child.hProcess;
            owner->stop = stop; stop = NULL;
        }
    }
    if (child.hThread) CloseHandle(child.hThread);
    if (initialized) DeleteProcThreadAttributeList(attributes);
    free(attributes);
    for (unsigned i = 0; i < 4; ++i) if (inherited[i]) CloseHandle(inherited[i]);
    if (slot) UnmapViewOfFile((const void *)slot);
    if (mapping) CloseHandle(mapping);
    if (event) CloseHandle(event);
    if (ready) CloseHandle(ready);
    if (stop) CloseHandle(stop);
    if (job) CloseHandle(job);
    if (image != INVALID_HANDLE_VALUE) CloseHandle(image);
    if (result != PET_CHILD_OK) SetLastError(launch_error ? launch_error : ERROR_GEN_FAILURE);
    return result;
}

pet_child_result pet_child_start(pet_supervisor *owner, const wchar_t *approved_exe,
    const pet_child_options *options) {
    if (!owner || !options || options->scale < PET_MIN_SCALE ||
        options->scale > PET_MAX_SCALE ||
        (options->smoke && (options->remember || options->reduced || options->topmost)))
        return PET_CHILD_INVALID;
    if (owner->job || owner->process || owner->stop || owner->state_mapping ||
        owner->state_event || owner->state_slot || owner->ready_event) return PET_CHILD_BUSY;
    if (InterlockedCompareExchange(&live_owner, 1, 0) != 0) return PET_CHILD_BUSY;
    pet_child_result result = start_child(owner, approved_exe, options, NULL, NULL, NULL, NULL, NULL);
    if (result != PET_CHILD_OK) {
        /* Preserve legacy last-resort cleanup semantics. Group callers use
         * start_child directly and retain ambiguous termination ownership. */
        if (owner->job) release_child(owner);
        InterlockedExchange(&live_owner, 0);
    }
    return result;
}

pet_child_result pet_child_publish(pet_supervisor *owner, unsigned reaction) {
    if (!owner || !owner->job || !owner->process || !owner->state_slot ||
        !owner->state_event || reaction > PET_STATE_SHOW) return PET_CHILD_INVALID;
    DWORD status = WaitForSingleObject(owner->process, 0);
    if (status == WAIT_OBJECT_0) return PET_CHILD_INVALID;
    if (status != WAIT_TIMEOUT) return PET_CHILD_OS_ERROR;
    if (reaction == owner->reaction) return PET_CHILD_OK;
    if (owner->generation >= PET_STATE_MAX_GENERATION) return PET_CHILD_INVALID;
    if (reaction == PET_STATE_HIDE || reaction == PET_STATE_SHOW) {
        /* First frame or preceding visibility command must be acknowledged.
         * A caller must never retry an unconfirmed command blindly. */
        if (!owner->ready_event || WaitForSingleObject(owner->ready_event, 0) != WAIT_OBJECT_0)
            return PET_CHILD_BUSY;
        if (!ResetEvent(owner->ready_event)) return PET_CHILD_OS_ERROR;
    }
    ++owner->generation;
    InterlockedExchange(owner->state_slot, (LONG)((owner->generation << 4) | reaction));
    /* On signaling failure, the state may already be visible. Caller must
     * treat the channel as failed, stop it, and never retry blindly. */
    if (!SetEvent(owner->state_event)) return PET_CHILD_OS_ERROR;
    owner->reaction = reaction;
    return PET_CHILD_OK;
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

/* All group operations are serialized by one worker. The native admission
 * check is a hard safety backstop, not physical memory allocation. */
static pet_group_slot *group_find(pet_supervisor_group *group, uint64_t id) {
    if (!group || group != active_group || !id) return NULL;
    for (unsigned i = 0; i < group->limit && i < PET_GROUP_MAX; ++i)
        if (group->slots[i].id == id) return &group->slots[i];
    return NULL;
}

pet_child_result pet_group_open(pet_supervisor_group *group, unsigned limit, SIZE_T commit_budget) {
    if (!group || !limit || limit > PET_GROUP_CONFIG_MAX || commit_budget < PET_CHILD_COMMIT_LIMIT)
        return PET_CHILD_INVALID;
    if (InterlockedCompareExchange(&live_owner, 2, 0) != 0) return PET_CHILD_BUSY;
    memset(group, 0, sizeof(*group));
    group->limit = limit; group->commit_budget = commit_budget; group->next_id = 1;
    active_group = group;
    return PET_CHILD_OK;
}

pet_child_result pet_group_crash_policy(pet_supervisor_group *group, BOOL enabled) {
    if (!group || group != active_group || group->count || (enabled != FALSE && enabled != TRUE))
        return PET_CHILD_INVALID;
    if (enabled && (group->limit > PET_CRASH_GROUP_MAX ||
        group->commit_budget < 2 * PET_CHILD_COMMIT_LIMIT)) return PET_CHILD_BUDGET_LIMIT;
    group->capture_crashes = enabled;
    return PET_CHILD_OK;
}

pet_child_result pet_group_crash_stats(pet_supervisor_group *group, uint32_t *saved, uint32_t *failed) {
    if (!group || group != active_group || !saved || !failed) return PET_CHILD_INVALID;
    *saved = group->dumps_saved;
    *failed = group->dumps_failed;
    return PET_CHILD_OK;
}

pet_child_result pet_group_admission(const pet_supervisor_group *group,
    uint64_t available_physical, uint64_t available_commit) {
    if (!group || group != active_group) return PET_CHILD_INVALID;
    if (group->count >= group->limit) return PET_CHILD_COUNT_LIMIT;
    if (group->count >= PET_GROUP_MAX) return PET_CHILD_STORAGE_LIMIT;
    SIZE_T per_instance = group->capture_crashes ? 2 * PET_CHILD_COMMIT_LIMIT : PET_CHILD_COMMIT_LIMIT;
    if (group->count >= group->commit_budget / per_instance) return PET_CHILD_BUDGET_LIMIT;
    /* This is a conservative launch guard, not a reservation or guarantee.
     * Other processes can change available memory immediately afterward. */
    const uint64_t need = PET_GROUP_MEMORY_HEADROOM + per_instance;
    if (available_physical < need || available_commit < need) return PET_CHILD_SYSTEM_MEMORY;
    return PET_CHILD_OK;
}

static pet_child_result group_start(pet_supervisor_group *group, const wchar_t *approved_exe,
    const pet_child_options *options, const wchar_t *directory, const wchar_t *package_id, const wchar_t *expected_sha, const uint8_t *image_sha, uint64_t *id) {
    if (!id) return PET_CHILD_INVALID;
    *id = 0;
    if (!group || group != active_group || !options || options->remember || (group->capture_crashes && !image_sha))
        return PET_CHILD_INVALID;
    /* Until per-instance persistence exists, reject shared registry writes. */
    pet_child_result admission = pet_group_admission(group, UINT64_MAX, UINT64_MAX);
    if (admission != PET_CHILD_OK) return admission;
    MEMORYSTATUSEX memory = {0};
    memory.dwLength = sizeof(memory);
    if (!GlobalMemoryStatusEx(&memory)) return PET_CHILD_OS_ERROR;
    admission = pet_group_admission(group, memory.ullAvailPhys, memory.ullAvailPageFile);
    if (admission != PET_CHILD_OK) return admission;
    if (group->next_id == UINT64_MAX) return PET_CHILD_INVALID;
    for (unsigned i = 0; i < group->limit && i < PET_GROUP_MAX; ++i) {
        pet_group_slot *slot = &group->slots[i];
        if (slot->id) continue;
        slot->id = group->next_id++;
        ++group->count;
        pet_child_result result = start_child(&slot->child, approved_exe, options, directory, package_id, expected_sha, image_sha,
            group->capture_crashes ? &group->monitors[i] : NULL);
        if (result != PET_CHILD_OK && !slot->child.process) {
            *slot = (pet_group_slot){0};
            --group->count;
            return result;
        }
        slot->stopping = result != PET_CHILD_OK;
        *id = slot->id;
        return result;
    }
    return PET_CHILD_STORAGE_LIMIT;
}

pet_child_result pet_group_start(pet_supervisor_group *group, const wchar_t *approved_exe,
    const pet_child_options *options, uint64_t *id) {
    return group_start(group, approved_exe, options, NULL, NULL, NULL, NULL, id);
}

pet_child_result pet_group_start_package(pet_supervisor_group *group, const wchar_t *approved_exe,
    const pet_child_options *options, const wchar_t *directory, const wchar_t *package_id, uint64_t *id) {
    if (!id) return PET_CHILD_INVALID;
    *id = 0;
    if (!package_args(directory, package_id) || !options || options->smoke || options->remember)
        return PET_CHILD_INVALID;
    return group_start(group, approved_exe, options, directory, package_id, NULL, NULL, id);
}

pet_child_result pet_group_start_verified_package(pet_supervisor_group *group, const wchar_t *approved_exe,
    const pet_child_options *options, const wchar_t *directory, const wchar_t *package_id,
    const wchar_t *expected_sha, uint64_t *id) {
    if (!id) return PET_CHILD_INVALID;
    *id = 0;
    if (!expected_sha || !package_args(directory, package_id) || !options || options->smoke || options->remember)
        return PET_CHILD_INVALID;
    return group_start(group, approved_exe, options, directory, package_id, expected_sha, NULL, id);
}

pet_child_result pet_group_start_approved(pet_supervisor_group *group, const wchar_t *approved_exe,
    const uint8_t image_sha[32], const pet_child_options *options, const wchar_t *directory,
    const wchar_t *package_id, const wchar_t *expected_sha, uint64_t *id) {
    if (!id) return PET_CHILD_INVALID;
    *id = 0;
    if (!image_sha || !options || ((directory || package_id || expected_sha) &&
        (!package_args(directory, package_id) || options->smoke || options->remember)))
        return PET_CHILD_INVALID;
    return group_start(group, approved_exe, options, directory, package_id, expected_sha, image_sha, id);
}

pet_child_result pet_group_publish(pet_supervisor_group *group, uint64_t id, unsigned reaction) {
    pet_group_slot *slot = group_find(group, id);
    if (!slot || slot->stopping) return PET_CHILD_INVALID;
    return pet_child_publish(&slot->child, reaction);
}

pet_child_result pet_group_status(pet_supervisor_group *group, uint64_t id, BOOL *running, DWORD *exit_code) {
    pet_group_slot *slot = group_find(group, id);
    if (!slot) return PET_CHILD_INVALID;
    return pet_child_status(&slot->child, running, exit_code);
}

pet_child_result pet_group_ready(pet_supervisor_group *group, uint64_t id, BOOL *ready) {
    pet_group_slot *slot = group_find(group, id);
    if (!slot || !ready) return PET_CHILD_INVALID;
    *ready = FALSE;
    if (slot->stopping) return PET_CHILD_OK;
    if (!slot->child.ready_event) return PET_CHILD_OS_ERROR;
    DWORD state = WaitForSingleObject(slot->child.process, 0);
    if (state == WAIT_OBJECT_0) return PET_CHILD_BUSY;
    if (state != WAIT_TIMEOUT) return PET_CHILD_OS_ERROR;
    state = WaitForSingleObject(slot->child.ready_event, 0);
    if (state != WAIT_OBJECT_0 && state != WAIT_TIMEOUT) return PET_CHILD_OS_ERROR;
    *ready = state == WAIT_OBJECT_0;
    return PET_CHILD_OK;
}

SIZE_T pet_group_storage_size(void) { return sizeof(pet_supervisor_group); }

static uint64_t filetime_ticks(FILETIME value) {
    return ((uint64_t)value.dwHighDateTime << 32) | value.dwLowDateTime;
}

pet_child_result pet_group_sample(pet_supervisor_group *group, uint64_t id, pet_group_metrics *out) {
    pet_group_slot *slot = group_find(group, id);
    if (!slot || !out) return PET_CHILD_INVALID;
    *out = (pet_group_metrics){0};
    HANDLE process = slot->child.process;
    if (WaitForSingleObject(process, 0) != WAIT_TIMEOUT) return PET_CHILD_BUSY;
    PROCESS_MEMORY_COUNTERS_EX memory = {0};
    memory.cb = sizeof(memory);
    DWORD handles = 0, pid = GetProcessId(process);
    FILETIME created, exited, kernel, user;
    if (!pid || !GetProcessMemoryInfo(process, (PROCESS_MEMORY_COUNTERS *)&memory, sizeof(memory)) ||
        !GetProcessHandleCount(process, &handles) ||
        !GetProcessTimes(process, &created, &exited, &kernel, &user))
        return PET_CHILD_OS_ERROR;
    if (WaitForSingleObject(process, 0) != WAIT_TIMEOUT) return PET_CHILD_BUSY;
    *out = (pet_group_metrics){memory.PrivateUsage, memory.WorkingSetSize,
        filetime_ticks(kernel) + filetime_ticks(user), GetTickCount64(), handles, pid};
    return PET_CHILD_OK;
}

pet_child_result pet_group_request_stop(pet_supervisor_group *group, uint64_t id) {
    pet_group_slot *slot = group_find(group, id);
    if (!slot || !slot->child.stop) return PET_CHILD_INVALID;
    slot->stopping = TRUE;
    return SetEvent(slot->child.stop) ? PET_CHILD_OK : PET_CHILD_OS_ERROR;
}

pet_child_result pet_group_force_stop(pet_supervisor_group *group, uint64_t id) {
    pet_group_slot *slot = group_find(group, id);
    if (!slot || !slot->child.job) return PET_CHILD_INVALID;
    slot->stopping = TRUE;
    pet_crash_monitor *monitor = &group->monitors[slot - group->slots];
    BOOL monitor_ok = !monitor->job || TerminateJobObject(monitor->job, 2);
    BOOL target_ok = TerminateJobObject(slot->child.job, 1);
    return monitor_ok && target_ok ? PET_CHILD_OK : PET_CHILD_CONTAINMENT_FAILED;
}

pet_child_result pet_group_reap(pet_supervisor_group *group, uint64_t id, DWORD *exit_code) {
    pet_group_slot *slot = group_find(group, id);
    if (!slot || !exit_code) return PET_CHILD_INVALID;
    pet_crash_monitor *monitor = &group->monitors[slot - group->slots];
    /* Bound capture even without an explicit stop. Only owned jobs
     * may be terminated; a timeout remains an abnormal outcome. */
    if (monitor->process && monitor->capture_event &&
        WaitForSingleObject(monitor->process, 0) == WAIT_TIMEOUT) {
        DWORD signaled = WaitForSingleObject(monitor->capture_event, 0);
        if (signaled == WAIT_OBJECT_0) {
            uint64_t now = GetTickCount64();
            if (!monitor->capture_since) monitor->capture_since = now ? now : 1;
            else if (now >= monitor->capture_since && now - monitor->capture_since >= 30000u) {
                if (pet_group_force_stop(group, id) != PET_CHILD_OK) return PET_CHILD_CONTAINMENT_FAILED;
            }
        } else if (signaled != WAIT_TIMEOUT) return PET_CHILD_OS_ERROR;
    }
    BOOL running = FALSE;
    pet_child_result status = pet_child_status(&slot->child, &running, exit_code);
    if (status != PET_CHILD_OK) return status;
    if (running) return PET_CHILD_BUSY;
    if (monitor->process) {
        DWORD state = WaitForSingleObject(monitor->process, 0), code = 0;
        if (state == WAIT_TIMEOUT) return PET_CHILD_BUSY;
        if (state != WAIT_OBJECT_0 || !GetExitCodeProcess(monitor->process, &code)) return PET_CHILD_OS_ERROR;
        if (code == 10) {
            if (group->dumps_saved != UINT32_MAX) ++group->dumps_saved;
        } else if (code != 0) {
            if (group->dumps_failed != UINT32_MAX) ++group->dumps_failed;
        }
        release_monitor(monitor);
    }
    release_child(&slot->child);
    *slot = (pet_group_slot){0};
    --group->count;
    return PET_CHILD_OK;
}

pet_child_result pet_group_close(pet_supervisor_group *group) {
    if (!group || group != active_group) return PET_CHILD_INVALID;
    if (group->count) return PET_CHILD_BUSY;
    active_group = NULL;
    memset(group, 0, sizeof(*group));
    InterlockedExchange(&live_owner, 0);
    return PET_CHILD_OK;
}

/* Terminal shutdown only. Job-close requests kernel termination but is not
 * confirmed reap. Never use this path for normal capacity reclamation. */
pet_child_result pet_group_abandon(pet_supervisor_group *group) {
    if (!group || group != active_group) return PET_CHILD_INVALID;
    for (unsigned i = 0; i < PET_GROUP_MAX; ++i) {
        if (group->slots[i].id) {
            release_monitor(&group->monitors[i]);
            release_child(&group->slots[i].child);
        }
    }
    group->count = 0;
    return pet_group_close(group);
}
