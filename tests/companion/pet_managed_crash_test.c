#include "../../shared/companion/pet_supervisor_win32.h"
#include <stdio.h>
#include <shellapi.h>
#include <wchar.h>
#include <string.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "managed crash test line %d (Win32 %lu)\n", __LINE__, (unsigned long)GetLastError()); goto done; } } while (0)

static int digit(wchar_t c) {
    if (c >= L'0' && c <= L'9') return c - L'0';
    if (c >= L'a' && c <= L'f') return c - L'a' + 10;
    if (c >= L'A' && c <= L'F') return c - L'A' + 10;
    return -1;
}

int main(void) {
    int argc = 0, rc = 1;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    static pet_supervisor_group group;
    uint8_t hash[32];
    uint64_t a = 0, b = 0, denied = 0;
    DWORD code = 0;
    uint32_t saved = 0, failed = 0;
    pet_child_options normal = {.scale = 100}, fault = {.scale = 125};
    CHECK(argv && argc == 3 && wcslen(argv[2]) == 64);
    for (unsigned i = 0; i < 32; ++i) {
        int high = digit(argv[2][2*i]), low = digit(argv[2][2*i+1]);
        CHECK(high >= 0 && low >= 0);
        hash[i] = (uint8_t)(high * 16 + low);
    }
    CHECK(pet_group_open(&group, 2, 4 * PET_CHILD_COMMIT_LIMIT) == PET_CHILD_OK);
    CHECK(pet_group_crash_policy(&group, TRUE) == PET_CHILD_OK);
    CHECK(pet_group_start(&group, argv[1], &normal, &denied) == PET_CHILD_INVALID && !denied);
    CHECK(pet_group_start_approved(&group, argv[1], hash, &normal, NULL, NULL, NULL, &a) == PET_CHILD_OK && a);
    CHECK(pet_group_start_approved(&group, argv[1], hash, &fault, NULL, NULL, NULL, &b) == PET_CHILD_OK && b > a);
    CHECK(group.count == 2 && group.monitors[0].process && group.monitors[1].process);
    CHECK(pet_group_crash_policy(&group, FALSE) == PET_CHILD_INVALID);
    CHECK(pet_group_request_stop(&group, a) == PET_CHILD_OK);
    CHECK(WaitForSingleObject(group.slots[0].child.process, 15000) == WAIT_OBJECT_0);
    CHECK(WaitForSingleObject(group.monitors[0].process, 15000) == WAIT_OBJECT_0);
    CHECK(pet_group_reap(&group, a, &code) == PET_CHILD_OK && code == 0);
    CHECK(WaitForSingleObject(group.slots[1].child.process, 30000) == WAIT_OBJECT_0);
    CHECK(WaitForSingleObject(group.monitors[1].process, 10000) == WAIT_OBJECT_0);
    CHECK(pet_group_reap(&group, b, &code) == PET_CHILD_OK && code != 0);
    CHECK(pet_group_crash_stats(&group, &saved, &failed) == PET_CHILD_OK && saved == 1 && failed == 0);
    CHECK(!group.count && pet_group_close(&group) == PET_CHILD_OK);
    rc = 0;
done:
    if (group.limit) (void)pet_group_abandon(&group);
    if (argv) LocalFree(argv);
    return rc;
}
