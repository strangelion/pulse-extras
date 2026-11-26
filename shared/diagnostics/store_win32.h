#ifndef PULSE_DIAGNOSTICS_STORE_WIN32_H
#define PULSE_DIAGNOSTICS_STORE_WIN32_H
#include "crash_win32.h"

/* Caller holds the exclusive verified private diagnostic root lease.
 * Fixed namespace: four completed records plus one transaction slot,
 * each <= 256 MiB; unknown or mismatched files are never removed.
 * On failure retain ambiguous evidence; do not overwrite existing files. */
BOOL pulse_dump_store_capture(const pulse_dump_backend *backend, HANDLE process,
    const DEBUG_EVENT *event, const wchar_t *root);
#endif
