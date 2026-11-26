#include "pet_crash_watch_win32.h"
#include "pet_private_root_win32.h"
#include "../diagnostics/store_win32.h"
#include <shlobj.h>
#include <stdlib.h>
#include <wchar.h>

static HANDLE parse_handle(const wchar_t *text) {
    if (!text || !*text) return NULL;
    for (const wchar_t *p = text; *p; ++p)
        if (*p < L'0' || *p > L'9') return NULL;
    wchar_t *end = NULL;
    unsigned long long value = wcstoull(text, &end, 10);
    if (!end || *end || !value || value >= UINTPTR_MAX) return NULL;
    HANDLE handle = (HANDLE)(uintptr_t)value;
    DWORD flags;
    return GetHandleInformation(handle, &flags) ? handle : NULL;
}

static BOOL same_image(HANDLE process) {
    wchar_t image[1024], self[1024];
    DWORD n = 1024, m = GetModuleFileNameW(NULL, self, 1024);
    return m && m < 1024 && QueryFullProcessImageNameW(process, 0, image, &n) &&
        n == m && CompareStringOrdinal(image, (int)n, self, (int)m, TRUE) == CSTR_EQUAL;
}

static BOOL save_crash(const pulse_dump_backend *backend, HANDLE process,
    const DEBUG_EVENT *event, const wchar_t *fixture_parent) {
    PWSTR allocated = NULL;
    const wchar_t *parent = fixture_parent;
    if (!parent) {
        if (FAILED(SHGetKnownFolderPath(&FOLDERID_LocalAppData, 0, NULL, &allocated))) return FALSE;
        parent = allocated;
    }
    pet_private_root lease = {0};
    pet_private_result status = PET_PRIVATE_BUSY;
    /* Multiple opted-in children can crash concurrently. Serialize writers;
     * never wait indefinitely or bypass the shared root lease. */
    for (unsigned attempt = 0; attempt < 20; ++attempt) {
        status = pet_private_diagnostics_open(&lease, parent);
        if (status != PET_PRIVATE_BUSY) break;
        Sleep(100);
    }
    BOOL saved = status == PET_PRIVATE_OK &&
        pulse_dump_store_capture(backend, process, event, lease.path);
    if (pet_private_root_close(&lease) != PET_PRIVATE_OK) saved = FALSE;
    if (allocated) CoTaskMemFree(allocated);
    return saved;
}

/* Application-defined Win32 error: numeric startup phase + low 16 bits
 * of the OS error. No user paths or process memory in diagnostics.
 * This is returned only before readiness acknowledgement. */
static int startup_error(unsigned phase, DWORD code) {
    return (int)(0x20000000u | ((phase & 0xffu) << 16) | (code & 0xffffu));
}

int pet_crash_watch(const wchar_t *process_arg, const wchar_t *ready_arg,
    const wchar_t *capture_arg, const wchar_t *fixture_parent) {
    HANDLE process = parse_handle(process_arg), ready = parse_handle(ready_arg);
    HANDLE capture = parse_handle(capture_arg);
    pulse_dump_backend backend = {0};
    int result = 2;
    DWORD pid = process ? GetProcessId(process) : 0;
    if (!process || !ready || !capture || process == ready || capture == process || capture == ready ||
        !pid || pid == GetCurrentProcessId() ||
        WaitForSingleObject(process, 0) != WAIT_TIMEOUT) {
        result = startup_error(1, ERROR_INVALID_HANDLE);
        goto done;
    }
    if (!same_image(process)) {
        result = startup_error(2, ERROR_BAD_PATHNAME);
        goto done;
    }
    if (!pulse_dump_open(&backend)) {
        result = startup_error(3, GetLastError());
        goto done;
    }
    /* Process was created suspended by the digest-pinned native supervisor;
     * attach while its retained inherited handle prevents PID reuse. */
    if (!DebugActiveProcess(pid)) {
        result = startup_error(4, GetLastError());
        goto done;
    }
    if (!DebugSetProcessKillOnExit(TRUE)) {
        result = startup_error(5, GetLastError());
        goto done;
    }
    if (!SetEvent(ready)) {
        result = startup_error(6, GetLastError());
        goto done;
    }
    BOOL initial_breakpoint = TRUE, fault = FALSE, saved = FALSE;
    for (;;) {
        DEBUG_EVENT event = {0};
        if (!WaitForDebugEvent(&event, 250)) {
            DWORD error = GetLastError();
            if (error == ERROR_SEM_TIMEOUT || error == ERROR_TIMEOUT) continue;
            break;
        }
        DWORD status = DBG_CONTINUE;
        if (event.dwDebugEventCode == CREATE_PROCESS_DEBUG_EVENT && event.u.CreateProcessInfo.hFile)
            CloseHandle(event.u.CreateProcessInfo.hFile);
        if (event.dwDebugEventCode == LOAD_DLL_DEBUG_EVENT && event.u.LoadDll.hFile)
            CloseHandle(event.u.LoadDll.hFile);
        if (event.dwProcessId != pid) break;
        if (event.dwDebugEventCode == EXCEPTION_DEBUG_EVENT) {
            if (initial_breakpoint && event.u.Exception.dwFirstChance &&
                event.u.Exception.ExceptionRecord.ExceptionCode == EXCEPTION_BREAKPOINT) {
                initial_breakpoint = FALSE;
            } else {
                status = DBG_EXCEPTION_NOT_HANDLED;
                if (!event.u.Exception.dwFirstChance && !fault) {
                    fault = TRUE;
                    saved = SetEvent(capture) && save_crash(&backend, process, &event, fixture_parent);
                }
            }
        }
        BOOL exited = event.dwDebugEventCode == EXIT_PROCESS_DEBUG_EVENT;
        if (!ContinueDebugEvent(event.dwProcessId, event.dwThreadId, status)) break;
        if (exited) {
            result = fault ? (saved ? 10 : 2) : 0;
            break;
        }
    }
done:
    pulse_dump_close(&backend);
    if (process) CloseHandle(process);
    if (ready && ready != process) CloseHandle(ready);
    if (capture && capture != process && capture != ready) CloseHandle(capture);
    /* The monitor is a dedicated process; debugger kill-on-exit is a last
     * resort for only its owned renderer if the event loop failed. */
    return result;
}
