/* Test-only, synthetic data. Never compiled into the distributed pet. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string.h>

static LONG CALLBACK handled(EXCEPTION_POINTERS *exception) {
    return exception->ExceptionRecord->ExceptionCode == 0xe0420002u ?
        EXCEPTION_CONTINUE_EXECUTION : EXCEPTION_CONTINUE_SEARCH;
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--smoke")) {
        PVOID handler = AddVectoredExceptionHandler(1, handled);
        if (!handler) return 3;
        RaiseException(0xe0420002u, 0, 0, NULL);
        return RemoveVectoredExceptionHandler(handler) ? 0 : 3;
    }
    volatile unsigned char *memory = VirtualAlloc(NULL, 8u * 1024 * 1024,
        MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!memory) return 3;
    for (unsigned i = 0; i < 8u * 1024 * 1024; i += 4096) memory[i] = 42;
    RaiseException(0xe0420001u, EXCEPTION_NONCONTINUABLE, 0, NULL);
    return 3;
}
