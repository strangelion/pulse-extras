#ifndef PULSE_PET_CRASH_WATCH_WIN32_H
#define PULSE_PET_CRASH_WATCH_WIN32_H
#include <wchar.h>

/* Private inherited-handle protocol. No PID/path input for the renderer.
 * Only the synthetic CI executable supplies an isolated fixture parent. */
int pet_crash_watch(const wchar_t *process, const wchar_t *ready, const wchar_t *capture, const wchar_t *fixture_parent);
#endif
