/* Synthetic process only. The production pet has no fault injection path. */
#include "../../shared/companion/pet_crash_watch_win32.h"
#include <windows.h>
#include <shellapi.h>
#include <wchar.h>
#include <stdlib.h>

int main(void) {
    int argc = 0;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) return 2;
    if (argc == 5 && !wcscmp(argv[1], L"--crash-watch")) {
        wchar_t parent[1024];
        DWORD n = GetModuleFileNameW(NULL, parent, 1024);
        wchar_t *last = n && n < 1024 ? wcsrchr(parent, L'\\') : NULL;
        if (!last) return 2;
        *last = 0;
        int result = pet_crash_watch(argv[2], argv[3], argv[4], parent);
        LocalFree(argv);
        return result;
    }
    HANDLE stop = NULL, ready = NULL;
    unsigned scale = 0;
    for (int i = 1; i + 1 < argc; ++i) {
        if (!wcscmp(argv[i], L"--stop-handle")) stop = (HANDLE)(uintptr_t)wcstoull(argv[++i], NULL, 10);
        else if (!wcscmp(argv[i], L"--ready-event")) ready = (HANDLE)(uintptr_t)wcstoull(argv[++i], NULL, 10);
        else if (!wcscmp(argv[i], L"--scale")) scale = (unsigned)wcstoul(argv[++i], NULL, 10);
    }
    LocalFree(argv);
    if (!ready || !stop || !SetEvent(ready)) return 2;
    if (scale == 125) {
        Sleep(250);
        volatile unsigned char *memory = VirtualAlloc(NULL, 8u * 1024 * 1024, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        if (!memory) return 3;
        for (unsigned i = 0; i < 8u * 1024 * 1024; i += 4096) memory[i] = 42;
        RaiseException(0xe0420001u, EXCEPTION_NONCONTINUABLE, 0, NULL);
        return 3;
    }
    return WaitForSingleObject(stop, 15000) == WAIT_OBJECT_0 ? 0 : 3;
}
