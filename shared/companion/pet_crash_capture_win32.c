/* Opt-in, out-of-process diagnostics for the sibling standalone pet only.
 * No attachment by PID, host exception filter, registry or network access. */
#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>
#include "../diagnostics/crash_win32.h"
#include "../process/job_win32.h"
#include <shellapi.h>
#include <stdio.h>
#include <stdint.h>
#include <wchar.h>
#include <string.h>

static BOOL output_path(const wchar_t *arg, wchar_t path[MAX_PATH]) {
    DWORD n = GetFullPathNameW(arg, MAX_PATH, path, NULL);
    if (n < 7 || n >= MAX_PATH || path[1] != L':' || path[2] != L'\\' ||
        wcschr(path + 2, L':') || _wcsicmp(path + n - 4, L".dmp")) return FALSE;
    wchar_t drive[] = {path[0], L':', L'\\', 0};
    if (GetDriveTypeW(drive) != DRIVE_FIXED) return FALSE;
    return GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES &&
        GetLastError() == ERROR_FILE_NOT_FOUND;
}

static BOOL sibling(wchar_t path[MAX_PATH]) {
    DWORD n = GetModuleFileNameW(NULL, path, MAX_PATH);
    if (!n || n >= MAX_PATH) return FALSE;
    wchar_t *name = wcsrchr(path, L'\\');
    static const wchar_t demo[] = L"pulse-pet-demo.exe";
    if (!name || (size_t)(name + 1 - path) + sizeof(demo) / sizeof(demo[0]) > MAX_PATH)
        return FALSE;
    memcpy(name + 1, demo, sizeof(demo));
    return TRUE;
}

static int collect(const wchar_t *path, BOOL smoke, uint64_t limit) {
    wchar_t image[MAX_PATH], command[MAX_PATH + 32];
    if (!sibling(image)) return 2;
    DWORD attributes = GetFileAttributesW(image);
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))) return 2;
    if (swprintf(command, sizeof(command) / sizeof(command[0]), L"\"%ls\"%ls",
        image, smoke ? L" --smoke" : L"") < 0) return 2;
    pulse_dump_backend backend = {0};
    if (!pulse_dump_open(&backend)) return 2;
    int result = 2;
    HANDLE job = CreateJobObjectW(NULL, NULL);
    PROCESS_INFORMATION child = {0};
    STARTUPINFOW startup = {0};
    startup.cb = sizeof(startup);
    if (!job ||
        !pulse_job_configure(job, 1, (SIZE_T)128u * 1024u * 1024u, 0) ||
        !CreateProcessW(image, command, NULL, NULL, FALSE,
            DEBUG_ONLY_THIS_PROCESS | CREATE_SUSPENDED, NULL, NULL, &startup, &child))
        goto cleanup;
    if (!AssignProcessToJobObject(job, child.hProcess) ||
        !DebugSetProcessKillOnExit(TRUE) || ResumeThread(child.hThread) != 1)
        goto cleanup;
    BOOL initial_breakpoint = TRUE, fault = FALSE, saved = FALSE;
    uint64_t deadline = GetTickCount64() + 600000u;
    for (;;) {
        DEBUG_EVENT event = {0};
        if (GetTickCount64() >= deadline) break;
        if (!WaitForDebugEvent(&event, 250)) {
            if (GetLastError() == ERROR_SEM_TIMEOUT || GetLastError() == ERROR_TIMEOUT) continue;
            break;
        }
        DWORD status = DBG_CONTINUE;
        if (event.dwDebugEventCode == CREATE_PROCESS_DEBUG_EVENT) {
            if (event.u.CreateProcessInfo.hFile) CloseHandle(event.u.CreateProcessInfo.hFile);
        } else if (event.dwDebugEventCode == LOAD_DLL_DEBUG_EVENT) {
            if (event.u.LoadDll.hFile) CloseHandle(event.u.LoadDll.hFile);
        }
        if (event.dwProcessId != child.dwProcessId) break;
        if (event.dwDebugEventCode == EXCEPTION_DEBUG_EVENT) {
            if (initial_breakpoint && event.u.Exception.dwFirstChance &&
                event.u.Exception.ExceptionRecord.ExceptionCode == EXCEPTION_BREAKPOINT) {
                initial_breakpoint = FALSE;
            } else {
                status = DBG_EXCEPTION_NOT_HANDLED;
                if (!event.u.Exception.dwFirstChance && !fault) {
                    fault = TRUE;
                    saved = pulse_dump_capture(&backend, child.hProcess, &event, path, limit);
                    if (!saved && GetLastError() == ERROR_WRITE_FAULT)
                        fputs("Dump cleanup or close failed; inspect the selected path.\n", stderr);
                }
            }
        }
        BOOL exited = event.dwDebugEventCode == EXIT_PROCESS_DEBUG_EVENT;
        if (!ContinueDebugEvent(event.dwProcessId, event.dwThreadId, status)) break;
        if (exited) {
            DWORD code = event.u.ExitProcess.dwExitCode;
            result = fault ? (saved ? 10 : 2) : (code == 0 ? 0 : 2);
            break;
        }
    }
cleanup:
    if (child.hProcess) {
        /* Only this explicitly launched, retained child handle is eligible. */
        if (WaitForSingleObject(child.hProcess, 0) != WAIT_OBJECT_0) {
            (void)TerminateProcess(child.hProcess, 1);
            if (WaitForSingleObject(child.hProcess, 3000) != WAIT_OBJECT_0) result = 2;
        }
        CloseHandle(child.hThread);
        CloseHandle(child.hProcess);
    }
    if (job) CloseHandle(job);
    pulse_dump_close(&backend);
    return result;
}

int main(void) {
    int argc = 0, result = 2;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    wchar_t path[MAX_PATH];
    uint64_t limit = PULSE_DUMP_MAX_BYTES;
    BOOL smoke = FALSE, valid = argv && argc >= 2 && output_path(argv[1], path);
    for (int i = 2; valid && i < argc; ++i) {
        if (!smoke && !wcscmp(argv[i], L"--smoke")) smoke = TRUE;
        else if (!wcscmp(argv[i], L"--limit-mib") && i + 1 < argc) {
            wchar_t *end = NULL;
            unsigned long mib = wcstoul(argv[++i], &end, 10);
            if (!end || *end || mib < 1 || mib > 256) valid = FALSE;
            else limit = (uint64_t)mib * 1024 * 1024;
        } else valid = FALSE;
    }
    if (valid) {
        fputs("Opt-in diagnostic: full pet memory may include sensitive data; keep it local.\n", stderr);
        result = collect(path, smoke, limit);
        if (result == 10) fputs("Captured one full-memory pet crash dump.\n", stderr);
        else if (result == 0) fputs("Pet exited normally; no dump created.\n", stderr);
        else fputs("Capture unavailable or child did not exit normally; no success claimed.\n", stderr);
    } else {
        fputs("Usage: pulse-pet-crash-capture NEW.dmp [--smoke] [--limit-mib 1..256]\n", stderr);
    }
    if (argv) LocalFree(argv);
    return result;
}
