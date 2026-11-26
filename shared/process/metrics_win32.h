#ifndef PULSE_METRICS_WIN32_H
#define PULSE_METRICS_WIN32_H
#include <windows.h>
#include <stdint.h>

/* Borrowed live process handle only; no PID-based process discovery.
 * CPU ticks are cumulative 100 ns units, sample time is monotonic ms.
 * Private commit and working set are OS observations, not allocator totals.
 * No successful sample if the owned process exited during observation. */
typedef struct {
    uint64_t private_bytes, working_set_bytes, cpu_ticks, sample_ms;
    DWORD handles, pid;
} pulse_process_metrics;
BOOL pulse_process_sample(HANDLE process, pulse_process_metrics *out);
#endif
