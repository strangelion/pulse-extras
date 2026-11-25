/* Opt-in, out-of-process diagnostics for the sibling standalone pet only.
 * No attachment by PID, host exception filter, registry or network access. */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <dbghelp.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdint.h>
#include <wchar.h>
#include <string.h>

typedef BOOL (WINAPI *dump_fn)(HANDLE, DWORD, HANDLE, MINIDUMP_TYPE,
    PMINIDUMP_EXCEPTION_INFORMATION, PMINIDUMP_USER_STREAM_INFORMATION,
    PMINIDUMP_CALLBACK_INFORMATION);

typedef struct {
    HANDLE file;
    uint64_t limit;
    BOOL started, finished;
} dump_writer;

/* DbgHelp directs all writes through the callback. The fallback handle is
 * NUL, not the output file; an unsupported callback cannot bypass the cap. */
static BOOL CALLBACK write_dump(PVOID opaque, const PMINIDUMP_CALLBACK_INPUT in,
    PMINIDUMP_CALLBACK_OUTPUT out) {
    dump_writer *writer = opaque;
    switch (in->CallbackType) {
    case IoStartCallback:
        writer->started = TRUE;
        out->Status = S_FALSE;
        return TRUE;
    case IoWriteAllCallback: {
        uint64_t offset = in->Io.Offset;
        DWORD bytes = in->Io.BufferBytes, written = 0;
        LARGE_INTEGER at;
        if (!writer->started || writer->finished ||
            offset > writer->limit || bytes > writer->limit - offset) return FALSE;
        at.QuadPart = (LONGLONG)offset;
        if (!SetFilePointerEx(writer->file, at, NULL, FILE_BEGIN) ||
            (bytes && (!WriteFile(writer->file, in->Io.Buffer, bytes, &written, NULL) ||
                written != bytes))) return FALSE;
        out->Status = S_OK;
        return TRUE;
    }
    case IoFinishCallback:
        writer->finished = TRUE;
        out->Status = S_OK;
        return TRUE;
    default:
        return TRUE;
    }
}

/* File creation is exclusive and uses a protected DACL for the actual
 * current user, not the containing directory's possibly shared ACL. */
static HANDLE private_file(const wchar_t *path) {
    HANDLE token = NULL, file = INVALID_HANDLE_VALUE;
    union { TOKEN_USER user; BYTE bytes[512]; } info;
    union { ACL acl; BYTE bytes[512]; } access;
    SECURITY_DESCRIPTOR sd;
    SECURITY_ATTRIBUTES sa = {sizeof(sa), &sd, FALSE};
    DWORD bytes = 0;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return file;
    if (GetTokenInformation(token, TokenUser, &info, sizeof(info), &bytes) &&
        IsValidSid(info.user.User.Sid) &&
        InitializeAcl(&access.acl, sizeof(access), ACL_REVISION) &&
        AddAccessAllowedAce(&access.acl, ACL_REVISION, FILE_ALL_ACCESS, info.user.User.Sid) &&
        InitializeSecurityDescriptor(&sd, SECURITY_DESCRIPTOR_REVISION) &&
        SetSecurityDescriptorDacl(&sd, TRUE, &access.acl, FALSE) &&
        SetSecurityDescriptorControl(&sd, SE_DACL_PROTECTED, SE_DACL_PROTECTED)) {
        file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE | DELETE, 0, &sa,
            CREATE_NEW, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    }
    CloseHandle(token);
    return file;
}

static BOOL capture(dump_fn dump, HANDLE process, const DEBUG_EVENT *event,
    const wchar_t *path, uint64_t limit) {
    HANDLE thread = OpenThread(THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION,
        FALSE, event->dwThreadId);
    if (!thread) return FALSE;
    CONTEXT context = {0};
    context.ContextFlags = CONTEXT_ALL;
    BOOL have_context = GetThreadContext(thread, &context);
    CloseHandle(thread);
    if (!have_context) return FALSE;
    EXCEPTION_RECORD record = event->u.Exception.ExceptionRecord;
    /* Nested pointers belong to the target address space. */
    record.ExceptionRecord = NULL;
    EXCEPTION_POINTERS pointers = {&record, &context};
    MINIDUMP_EXCEPTION_INFORMATION exception = {event->dwThreadId, &pointers, FALSE};
    HANDLE sink = CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (sink == INVALID_HANDLE_VALUE) return FALSE;
    HANDLE file = private_file(path);
    if (file == INVALID_HANDLE_VALUE) {
        CloseHandle(sink);
        return FALSE;
    }
    dump_writer writer = {file, limit, FALSE, FALSE};
    MINIDUMP_CALLBACK_INFORMATION callback = {write_dump, &writer};
    BOOL ok = dump(process, event->dwProcessId, sink,
        (MINIDUMP_TYPE)(MiniDumpWithFullMemory | MiniDumpWithThreadInfo),
        &exception, NULL, &callback);
    CloseHandle(sink);
    LARGE_INTEGER size, zero = {0};
    DWORD magic = 0, got = 0;
    ok = ok && writer.started && writer.finished &&
        GetFileSizeEx(file, &size) && size.QuadPart >= (LONGLONG)sizeof(MINIDUMP_HEADER) &&
        (uint64_t)size.QuadPart <= limit &&
        SetFilePointerEx(file, zero, NULL, FILE_BEGIN) &&
        ReadFile(file, &magic, sizeof(magic), &got, NULL) &&
        got == sizeof(magic) && magic == MINIDUMP_SIGNATURE && FlushFileBuffers(file);
    if (!ok) {
        FILE_DISPOSITION_INFO remove = {TRUE};
        if (!SetFileInformationByHandle(file, FileDispositionInfo, &remove, sizeof(remove)))
            fputs("Partial dump cleanup failed; inspect the explicitly selected path.\n", stderr);
    }
    if (!CloseHandle(file)) ok = FALSE;
    return ok;
}

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
    HMODULE dll = LoadLibraryExW(L"dbghelp.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!dll) return 2;
    FARPROC address = GetProcAddress(dll, "MiniDumpWriteDump");
    dump_fn dump = NULL;
    _Static_assert(sizeof(dump) == sizeof(address), "Windows function pointer size");
    memcpy(&dump, &address, sizeof(dump));
    int result = 2;
    HANDLE job = CreateJobObjectW(NULL, NULL);
    PROCESS_INFORMATION child = {0};
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
        JOB_OBJECT_LIMIT_ACTIVE_PROCESS | JOB_OBJECT_LIMIT_PROCESS_MEMORY;
    limits.BasicLimitInformation.ActiveProcessLimit = 1;
    limits.ProcessMemoryLimit = (SIZE_T)128u * 1024u * 1024u;
    STARTUPINFOW startup = {0};
    startup.cb = sizeof(startup);
    if (!dump || !job ||
        !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)) ||
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
            if (GetLastError() == ERROR_SEM_TIMEOUT) continue;
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
                    saved = capture(dump, child.hProcess, &event, path, limit);
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
    FreeLibrary(dll);
    return result;
}

int main(void) {
    int argc = 0, result = 2;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    wchar_t path[MAX_PATH];
    uint64_t limit = UINT64_C(256) * 1024 * 1024;
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
