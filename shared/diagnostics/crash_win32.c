#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include "crash_win32.h"
#include <string.h>
#include <stddef.h>

/* The pinned GNU dbghelp header omits Io from its input union and places
 * Status outside the output union. The documented Windows SDK ABI is
 * pack(4), with the I/O payload at the input union start and the HRESULT
 * at byte zero of the output union. Copy bytes instead of aliasing an
 * incompatible vendor-header type. This backend is x64-only. */
#pragma pack(push, 4)
typedef struct {
    HANDLE handle;
    ULONG64 offset;
    PVOID buffer;
    ULONG bytes;
} pulse_dump_io;
#pragma pack(pop)
_Static_assert(sizeof(void *) == 8, "x64 DbgHelp ABI");
_Static_assert(offsetof(MINIDUMP_CALLBACK_INPUT, CallbackType) == 12, "callback tag ABI");
_Static_assert(offsetof(MINIDUMP_CALLBACK_INPUT, Thread) == 16, "callback payload ABI");
_Static_assert(offsetof(pulse_dump_io, offset) == 8 &&
    offsetof(pulse_dump_io, buffer) == 16 && offsetof(pulse_dump_io, bytes) == 24 &&
    sizeof(pulse_dump_io) == 28, "callback IO ABI");

static void io_status(PMINIDUMP_CALLBACK_OUTPUT out, HRESULT status) {
    memcpy(out, &status, sizeof(status));
}

BOOL pulse_dump_open(pulse_dump_backend *backend) {
    if (!backend || backend->module || backend->write) return FALSE;
    HMODULE module = LoadLibraryExW(L"dbghelp.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module) return FALSE;
    FARPROC address = GetProcAddress(module, "MiniDumpWriteDump");
    if (!address) {
        FreeLibrary(module);
        return FALSE;
    }
    _Static_assert(sizeof(backend->write) == sizeof(address), "Windows function pointer size");
    memcpy(&backend->write, &address, sizeof(address));
    backend->module = module;
    return TRUE;
}

void pulse_dump_close(pulse_dump_backend *backend) {
    if (!backend) return;
    if (backend->module) FreeLibrary(backend->module);
    *backend = (pulse_dump_backend){0};
}

typedef struct {
    HANDLE file;
    uint64_t limit;
    BOOL started, finished, failed;
} dump_writer;

/* DbgHelp directs all writes through the callback. The fallback handle is
 * NUL, not the output file; an unsupported callback cannot bypass the cap. */
static BOOL CALLBACK write_dump(PVOID opaque, const PMINIDUMP_CALLBACK_INPUT in,
    PMINIDUMP_CALLBACK_OUTPUT out) {
    dump_writer *writer = opaque;
    if (writer->failed) return FALSE;
    switch (in->CallbackType) {
    case IoStartCallback:
        if (writer->started || writer->finished) goto failed;
        writer->started = TRUE;
        io_status(out, S_FALSE);
        return TRUE;
    case IoWriteAllCallback: {
        pulse_dump_io io;
        memcpy(&io, (const unsigned char *)in + offsetof(MINIDUMP_CALLBACK_INPUT, Thread), sizeof(io));
        uint64_t offset = io.offset;
        DWORD bytes = io.bytes, written = 0;
        LARGE_INTEGER at;
        if (!writer->started || writer->finished ||
            offset > writer->limit || bytes > writer->limit - offset) goto failed;
        at.QuadPart = (LONGLONG)offset;
        if (!SetFilePointerEx(writer->file, at, NULL, FILE_BEGIN) ||
            (bytes && (!WriteFile(writer->file, io.buffer, bytes, &written, NULL) ||
                written != bytes))) goto failed;
        io_status(out, S_OK);
        return TRUE;
    }
    case IoFinishCallback:
        if (!writer->started || writer->finished) goto failed;
        writer->finished = TRUE;
        io_status(out, S_OK);
        return TRUE;
    default:
        return TRUE;
    }
failed:
    writer->failed = TRUE;
    io_status(out, E_FAIL);
    return FALSE;
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

BOOL pulse_dump_capture(const pulse_dump_backend *backend, HANDLE process,
    const DEBUG_EVENT *event, const wchar_t *path, uint64_t limit) {
    if (!backend || !backend->module || !backend->write || !process || !event ||
        !path || !*path || !limit || limit > PULSE_DUMP_MAX_BYTES ||
        event->dwDebugEventCode != EXCEPTION_DEBUG_EVENT ||
        event->u.Exception.dwFirstChance || event->dwProcessId == GetCurrentProcessId() ||
        GetProcessId(process) != event->dwProcessId) return FALSE;
    HANDLE thread = OpenThread(THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION,
        FALSE, event->dwThreadId);
    if (!thread) return FALSE;
    CONTEXT context = {0};
    context.ContextFlags = CONTEXT_ALL;
    BOOL have_context = GetProcessIdOfThread(thread) == event->dwProcessId &&
        GetThreadContext(thread, &context);
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
    dump_writer writer = {file, limit, FALSE, FALSE, FALSE};
    MINIDUMP_CALLBACK_INFORMATION callback = {write_dump, &writer};
    BOOL ok = backend->write(process, event->dwProcessId, sink,
        (MINIDUMP_TYPE)(MiniDumpWithFullMemory | MiniDumpWithThreadInfo),
        &exception, NULL, &callback);
    CloseHandle(sink);
    LARGE_INTEGER size, zero = {0};
    DWORD magic = 0, got = 0;
    ok = ok && writer.started && writer.finished && !writer.failed &&
        GetFileSizeEx(file, &size) && size.QuadPart >= (LONGLONG)sizeof(MINIDUMP_HEADER) &&
        (uint64_t)size.QuadPart <= limit &&
        SetFilePointerEx(file, zero, NULL, FILE_BEGIN) &&
        ReadFile(file, &magic, sizeof(magic), &got, NULL) &&
        got == sizeof(magic) && magic == MINIDUMP_SIGNATURE && FlushFileBuffers(file);
    BOOL cleanup_failed = FALSE;
    if (!ok) {
        FILE_DISPOSITION_INFO remove = {TRUE};
        cleanup_failed = !SetFileInformationByHandle(file, FileDispositionInfo, &remove, sizeof(remove));
    }
    if (!CloseHandle(file)) {
        cleanup_failed = TRUE;
        ok = FALSE;
    }
    if (!ok) SetLastError(cleanup_failed ? ERROR_WRITE_FAULT : ERROR_GEN_FAILURE);
    return ok;
}
