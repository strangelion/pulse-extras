#ifndef PULSE_DIAGNOSTICS_CRASH_WIN32_H
#define PULSE_DIAGNOSTICS_CRASH_WIN32_H
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <dbghelp.h>
#include <stdint.h>

#define PULSE_DUMP_MAX_BYTES (UINT64_C(256) * 1024 * 1024)

typedef BOOL (WINAPI *pulse_dump_fn)(HANDLE, DWORD, HANDLE, MINIDUMP_TYPE,
    PMINIDUMP_EXCEPTION_INFORMATION, PMINIDUMP_USER_STREAM_INFORMATION,
    PMINIDUMP_CALLBACK_INFORMATION);

/* Zero-initialize, own on one diagnostic worker, and close after all
 * captures. DbgHelp is single-threaded: never share this object across
 * workers or use it concurrently with other DbgHelp calls in this process.
 * This backend is for a separate collector process, not a Pulse DLL. */
typedef struct {
    HMODULE module;
    pulse_dump_fn write;
} pulse_dump_backend;

BOOL pulse_dump_open(pulse_dump_backend *backend);
void pulse_dump_close(pulse_dump_backend *backend);

/* Caller owns a stopped/debugged child process and its second-chance
 * exception event. No process discovery/attach or host exception filter.
 * Output is a caller-selected new path in a trusted private local directory.
 * Only one capture at a time. Failure never overwrites existing evidence. */
BOOL pulse_dump_capture(const pulse_dump_backend *backend, HANDLE process,
    const DEBUG_EVENT *event, const wchar_t *path, uint64_t limit);
#endif
