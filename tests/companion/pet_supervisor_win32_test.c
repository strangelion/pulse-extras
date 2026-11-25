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
        HANDLE mapping = NULL, event = NULL, ready = NULL;
        for (int i = 3; i + 1 < argc; ++i) {
            if (wcscmp(argv[i], L"--state-map") == 0)
                mapping = (HANDLE)(uintptr_t)wcstoull(argv[++i], NULL, 10);
            else if (wcscmp(argv[i], L"--state-event") == 0)
                event = (HANDLE)(uintptr_t)wcstoull(argv[++i], NULL, 10);
            else if (wcscmp(argv[i], L"--ready-event") == 0)
                ready = (HANDLE)(uintptr_t)wcstoull(argv[++i], NULL, 10);
        }
        LocalFree(argv);
        if (ignore) { Sleep(INFINITE); return 2; }
        if (!mapping || !event || !ready) return 4;
        /* A normal small commit succeeds; one exceeding the entire
         * supervised child cap must be denied by the kernel. */
        void *small = VirtualAlloc(NULL, 65536, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        if (!small) return 9;
        if (!VirtualFree(small, 0, MEM_RELEASE)) return 10;
        void *oversized = VirtualAlloc(NULL, PET_CHILD_COMMIT_LIMIT + 65536,
            MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        if (oversized) { VirtualFree(oversized, 0, MEM_RELEASE); return 11; }
        const volatile LONG *slot = MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, sizeof(LONG));
        if (!slot) return 5;
        /* Child must not be able to map writable memory or signal host event. */
        void *write_view = MapViewOfFile(mapping, FILE_MAP_WRITE, 0, 0, sizeof(LONG));
        if (write_view) { UnmapViewOfFile(write_view); return 6; }
        if (SetEvent(event)) return 7;
        if (WaitForSingleObject(ready, 0) != WAIT_FAILED || !SetEvent(ready)) return 12;
        if (WaitForSingleObject(event, 5000) != WAIT_OBJECT_0) return 8;
        DWORD word = pet_state_read(slot);
        DWORD result = WaitForSingleObject(stop, 10000);
        DWORD final = pet_state_read(slot);
        UnmapViewOfFile((const void *)slot);
        CloseHandle(mapping); CloseHandle(event); CloseHandle(stop); CloseHandle(ready);
        return result == WAIT_OBJECT_0 && pet_state_valid(word) &&
            final == ((3u << 4) | PET_STATE_TESTING) ? 0 : 3;
    }
    int rc = 1;
    pet_supervisor owner = {0}, other = {0};
    pet_child_options options = {.scale = 100};
    wchar_t path[1024];
    DWORD length = GetModuleFileNameW(NULL, path, 1024), code = 99;
    BOOL running = FALSE, forced = FALSE;
    HANDLE observed = NULL;
    static pet_supervisor_group group;
    _Static_assert(PET_GROUP_MAX == 1024u, "manager capacity contract");
    uint64_t a = 0, b = 0, rejected = 0;
    CHECK(length && length < 1024);
    CHECK(pet_child_start(&owner, L"relative.exe", &options) == PET_CHILD_INVALID);
    CHECK(pet_child_start(&owner, path, &options) == PET_CHILD_OK);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    CHECK(QueryInformationJobObject(owner.job, JobObjectExtendedLimitInformation,
        &limits, sizeof(limits), NULL));
    CHECK((limits.BasicLimitInformation.LimitFlags &
        (JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_ACTIVE_PROCESS |
         JOB_OBJECT_LIMIT_PROCESS_MEMORY | JOB_OBJECT_LIMIT_JOB_MEMORY)) ==
        (JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_ACTIVE_PROCESS |
         JOB_OBJECT_LIMIT_PROCESS_MEMORY | JOB_OBJECT_LIMIT_JOB_MEMORY));
    CHECK(limits.BasicLimitInformation.ActiveProcessLimit == 1);
    CHECK(limits.ProcessMemoryLimit == PET_CHILD_COMMIT_LIMIT);
    CHECK(limits.JobMemoryLimit == PET_CHILD_COMMIT_LIMIT);
    CHECK(pet_child_start(&owner, path, &options) == PET_CHILD_BUSY);
    CHECK(pet_child_start(&other, path, &options) == PET_CHILD_BUSY);
    CHECK(pet_child_status(&owner, &running, &code) == PET_CHILD_OK && running);
    CHECK(pet_child_publish(&owner, 99) == PET_CHILD_INVALID);
    CHECK(pet_child_publish(&owner, PET_STATE_THINKING) == PET_CHILD_OK);
    CHECK(pet_child_publish(&owner, PET_STATE_THINKING) == PET_CHILD_OK);
    CHECK(pet_child_publish(&owner, PET_STATE_TESTING) == PET_CHILD_OK);
    CHECK(owner.generation == 3);
    CHECK(WaitForSingleObject(owner.ready_event, 5000) == WAIT_OBJECT_0);
    CHECK(pet_child_stop(&owner, 5000, &forced, &code) == PET_CHILD_OK && !forced && code == 0);
    CHECK(!owner.job && !owner.process && !owner.stop && !owner.state_mapping &&
        !owner.state_event && !owner.state_slot);
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
        CHECK(pet_child_publish(&owner, PET_STATE_TESTING) == PET_CHILD_OK);
        CHECK(WaitForSingleObject(owner.ready_event, 5000) == WAIT_OBJECT_0);
        CHECK(WaitForSingleObject(owner.process, 10000) == WAIT_OBJECT_0);
        CHECK(pet_child_status(&owner, &running, &code) == PET_CHILD_OK && !running && code == 0);
        CHECK(pet_child_stop(&owner, 5000, &forced, &code) == PET_CHILD_OK && !forced && code == 0);
    }
    /* Two live children, one group, distinct state channels. Limit by
     * conservative memory ceiling even though count cap permits 1024. */
    options.smoke = TRUE;
    CHECK(pet_group_open(&group, PET_GROUP_CONFIG_MAX + 1u, PET_CHILD_COMMIT_LIMIT) == PET_CHILD_INVALID);
    CHECK(pet_group_open(&group, PET_GROUP_CONFIG_MAX, PET_CHILD_COMMIT_LIMIT) == PET_CHILD_OK);
    CHECK(group.limit == PET_GROUP_CONFIG_MAX && !group.count);
    CHECK(pet_group_admission(&group, UINT64_MAX, UINT64_MAX) == PET_CHILD_OK);
    CHECK(pet_group_admission(&group, 0, UINT64_MAX) == PET_CHILD_SYSTEM_MEMORY);
    CHECK(pet_group_admission(&group, UINT64_MAX, 0) == PET_CHILD_SYSTEM_MEMORY);
    CHECK(pet_group_close(&group) == PET_CHILD_OK);
    CHECK(pet_group_open(&group, PET_GROUP_CONFIG_MAX, PET_CHILD_COMMIT_LIMIT * 2) == PET_CHILD_OK);
    CHECK(pet_child_start(&other, path, &options) == PET_CHILD_BUSY);
    CHECK(pet_group_start(&group, L"relative.exe", &options, &rejected) == PET_CHILD_INVALID);
    CHECK(!rejected && !group.count);
    CHECK(pet_group_start(&group, path, &options, &a) == PET_CHILD_OK && a);
    CHECK(pet_group_start(&group, path, &options, &b) == PET_CHILD_OK && b > a);
    CHECK(group.count == 2);
    BOOL ready_state = TRUE;
    CHECK(pet_group_ready(&group, a, &ready_state) == PET_CHILD_OK && !ready_state);
    pet_group_metrics ma = {0}, mb = {0};
    CHECK(pet_group_storage_size() == sizeof(group));
    CHECK(pet_group_sample(&group, a, &ma) == PET_CHILD_OK && ma.pid && ma.private_bytes && ma.handles);
    CHECK(pet_group_sample(&group, b, &mb) == PET_CHILD_OK && mb.pid && mb.private_bytes && mb.handles);
    CHECK(ma.pid != mb.pid);
    CHECK(pet_group_start(&group, path, &options, &rejected) == PET_CHILD_BUDGET_LIMIT && !rejected);
    CHECK(pet_group_close(&group) == PET_CHILD_BUSY);
    CHECK(pet_group_publish(&group, a, PET_STATE_THINKING) == PET_CHILD_OK);
    CHECK(pet_group_publish(&group, b, PET_STATE_TESTING) == PET_CHILD_OK);
    CHECK(group.slots[0].child.reaction == PET_STATE_THINKING);
    CHECK(group.slots[1].child.reaction == PET_STATE_TESTING);
    CHECK(pet_group_request_stop(&group, a) == PET_CHILD_OK);
    CHECK(pet_group_reap(&group, a, &code) == PET_CHILD_BUSY && group.count == 2);
    CHECK(pet_group_force_stop(&group, a) == PET_CHILD_OK);
    CHECK(group.count == 2);
    CHECK(WaitForSingleObject(group.slots[0].child.process, 5000) == WAIT_OBJECT_0);
    CHECK(pet_group_reap(&group, a, &code) == PET_CHILD_OK && code == 1 && group.count == 1);
    CHECK(pet_group_publish(&group, a, PET_STATE_IDLE) == PET_CHILD_INVALID);
    CHECK(pet_group_sample(&group, a, &ma) == PET_CHILD_INVALID);
    CHECK(pet_group_status(&group, b, &running, &code) == PET_CHILD_OK && running);
    CHECK(pet_group_force_stop(&group, b) == PET_CHILD_OK);
    CHECK(WaitForSingleObject(group.slots[1].child.process, 5000) == WAIT_OBJECT_0);
    CHECK(pet_group_reap(&group, b, &code) == PET_CHILD_OK && group.count == 0);
    CHECK(pet_group_close(&group) == PET_CHILD_OK);
    CHECK(pet_child_start(&owner, path, &options) == PET_CHILD_OK);
    CHECK(pet_child_stop(&owner, 0, &forced, &code) == PET_CHILD_OK);
    rc = 0;
cleanup:
    /* Fixture only: bounded cleanup on assertion failure; OS closes job
     * handles at test process exit if a wait fails. */
    for (unsigned i = 0; i < PET_GROUP_MAX; ++i) {
        uint64_t id = group.slots[i].id;
        if (id) {
            pet_group_force_stop(&group, id);
            if (WaitForSingleObject(group.slots[i].child.process, 5000) == WAIT_OBJECT_0)
                pet_group_reap(&group, id, &code);
        }
    }
    if (group.limit) pet_group_close(&group);
    pet_child_abandon(&owner);
    pet_child_abandon(&other);
    if (observed) CloseHandle(observed);
    LocalFree(argv);
    return rc;
}
