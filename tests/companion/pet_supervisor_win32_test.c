#include "../../shared/companion/pet_supervisor_win32.h"
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include <shellapi.h>

#define CHECK(expr) do { if (!(expr)) { \
    fprintf(stderr, "supervisor test failed at line %d (win32=%lu)\n", \
        __LINE__, (unsigned long)GetLastError()); goto cleanup; \
} } while (0)

int main(void) {
    int argc = 0;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) return 1;
    /* The test binary is also a controlled fixture child. The smoke flag
     * makes it deliberately ignore cooperative shutdown. */
    if (argc > 1 && wcscmp(argv[1], L"--stop-handle") == 0) {
        HANDLE stop = (HANDLE)(uintptr_t)wcstoull(argv[2], NULL, 10);
        BOOL ignore = argc > 5 && wcscmp(argv[5], L"--smoke") == 0;
        LocalFree(argv);
        if (ignore) { Sleep(INFINITE); return 2; }
        DWORD result = WaitForSingleObject(stop, 10000);
        CloseHandle(stop);
        return result == WAIT_OBJECT_0 ? 0 : 3;
    }
    int rc = 1;
    pet_supervisor owner = {0}, other = {0};
    pet_child_options options = {.scale = 100};
    wchar_t path[1024];
    DWORD length = GetModuleFileNameW(NULL, path, 1024), code = 99;
    BOOL running = FALSE, forced = FALSE;
    HANDLE observed = NULL;
    CHECK(length && length < 1024);
    CHECK(pet_child_start(&owner, L"relative.exe", &options) == PET_CHILD_INVALID);
    CHECK(pet_child_start(&owner, path, &options) == PET_CHILD_OK);
    CHECK(pet_child_start(&owner, path, &options) == PET_CHILD_BUSY);
    CHECK(pet_child_start(&other, path, &options) == PET_CHILD_BUSY);
    CHECK(pet_child_status(&owner, &running, &code) == PET_CHILD_OK && running);
    CHECK(pet_child_stop(&owner, 5000, &forced, &code) == PET_CHILD_OK && !forced && code == 0);
    CHECK(!owner.job && !owner.process && !owner.stop);
    options.smoke = TRUE;
    CHECK(pet_child_start(&owner, path, &options) == PET_CHILD_OK);
    CHECK(pet_child_stop(&owner, 0, &forced, &code) == PET_CHILD_OK && forced && code == 1);
    CHECK(pet_child_start(&owner, path, &options) == PET_CHILD_OK);
    CHECK(DuplicateHandle(GetCurrentProcess(), owner.process, GetCurrentProcess(),
        &observed, SYNCHRONIZE, FALSE, 0));
    pet_child_abandon(&owner);
    CHECK(WaitForSingleObject(observed, 5000) == WAIT_OBJECT_0);
    CloseHandle(observed);
    observed = NULL;
    /* Also launch the actual demo, if supplied, without showing a window. */
    if (argc == 2) {
        CHECK(pet_child_start(&owner, argv[1], &options) == PET_CHILD_OK);
        CHECK(pet_child_stop(&owner, 5000, &forced, &code) == PET_CHILD_OK && !forced && code == 0);
    }
    rc = 0;
cleanup:
    pet_child_abandon(&owner);
    pet_child_abandon(&other);
    if (observed) CloseHandle(observed);
    LocalFree(argv);
    return rc;
}
