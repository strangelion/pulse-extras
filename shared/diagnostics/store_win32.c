#include "store_win32.h"
#include <wchar.h>
#include <string.h>

#define SLOT_COUNT 5u
#define RETAIN_COUNT 4u
#define PATH_CAP 1024u
#define MAX_AGE_TICKS (UINT64_C(30) * 24 * 60 * 60 * 10000000)
#define OWNER_MAGIC UINT64_C(0x31584450534c5550)

typedef struct {
    uint64_t magic, created, modified, bytes;
    DWORD volume, index_high, index_low, reserved;
} record;
_Static_assert(sizeof(record) == 48, "managed diagnostic record layout");

typedef struct {
    HANDLE dump, index;
    record identity;
    BOOL empty, known;
} slot;

static uint64_t ticks(FILETIME t) {
    return ((uint64_t)t.dwHighDateTime << 32) | t.dwLowDateTime;
}

static BOOL name(const wchar_t *root, unsigned id, BOOL index, wchar_t out[PATH_CAP]) {
    int n = swprintf(out, PATH_CAP, L"%ls\\capture-%u.%ls", root, id, index ? L"pdi" : L"dmp");
    return n > 0 && n < (int)PATH_CAP;
}

static BOOL identity(HANDLE file, record *out) {
    BY_HANDLE_FILE_INFORMATION info = {0};
    LARGE_INTEGER zero = {0};
    DWORD got = 0, signature = 0;
    if (GetFileType(file) != FILE_TYPE_DISK || !GetFileInformationByHandle(file, &info) ||
        (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
        info.nNumberOfLinks != 1) return FALSE;
    uint64_t bytes = ((uint64_t)info.nFileSizeHigh << 32) | info.nFileSizeLow;
    if (bytes < sizeof(MINIDUMP_HEADER) || bytes > PULSE_DUMP_MAX_BYTES ||
        !SetFilePointerEx(file, zero, NULL, FILE_BEGIN) ||
        !ReadFile(file, &signature, sizeof(signature), &got, NULL) ||
        got != sizeof(signature) || signature != MINIDUMP_SIGNATURE) return FALSE;
    *out = (record){OWNER_MAGIC, ticks(info.ftCreationTime), ticks(info.ftLastWriteTime),
        bytes, info.dwVolumeSerialNumber, info.nFileIndexHigh, info.nFileIndexLow, 0};
    return out->created != 0 && out->modified != 0;
}

static BOOL valid_index(HANDLE file, record *out) {
    BY_HANDLE_FILE_INFORMATION info = {0};
    DWORD got = 0;
    return GetFileType(file) == FILE_TYPE_DISK && GetFileInformationByHandle(file, &info) &&
        !(info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) &&
        info.nNumberOfLinks == 1 && !info.nFileSizeHigh && info.nFileSizeLow == sizeof(*out) &&
        ReadFile(file, out, sizeof(*out), &got, NULL) && got == sizeof(*out) &&
        out->magic == OWNER_MAGIC && out->reserved == 0;
}

static HANDLE open_file(const wchar_t *path, BOOL *missing) {
    HANDLE file = CreateFileW(path, GENERIC_READ | DELETE, 0, NULL,
        OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    *missing = file == INVALID_HANDLE_VALUE && GetLastError() == ERROR_FILE_NOT_FOUND;
    return file;
}

static void close_slot(slot *s) {
    if (s->dump != INVALID_HANDLE_VALUE) CloseHandle(s->dump);
    if (s->index != INVALID_HANDLE_VALUE) CloseHandle(s->index);
    *s = (slot){.dump = INVALID_HANDLE_VALUE, .index = INVALID_HANDLE_VALUE};
}

static BOOL read_slot(const wchar_t *root, unsigned id, slot *out) {
    wchar_t path[PATH_CAP], meta[PATH_CAP];
    BOOL missing_dump = FALSE, missing_index = FALSE;
    if (!name(root, id, FALSE, path) || !name(root, id, TRUE, meta)) return FALSE;
    out->dump = open_file(path, &missing_dump);
    out->index = open_file(meta, &missing_index);
    out->empty = missing_dump && missing_index;
    if (out->empty) return TRUE;
    record expected;
    out->known = out->dump != INVALID_HANDLE_VALUE && out->index != INVALID_HANDLE_VALUE &&
        identity(out->dump, &out->identity) && valid_index(out->index, &expected) &&
        !memcmp(&expected, &out->identity, sizeof(expected));
    return out->known; /* ambiguous state fails closed, no deletion */
}

static BOOL remove_owned(slot *s) {
    if (!s->known) return FALSE;
    FILE_DISPOSITION_INFO remove = {TRUE};
    if (!SetFileInformationByHandle(s->dump, FileDispositionInfo, &remove, sizeof(remove))) return FALSE;
    if (!CloseHandle(s->dump)) return FALSE;
    s->dump = INVALID_HANDLE_VALUE;
    if (!SetFileInformationByHandle(s->index, FileDispositionInfo, &remove, sizeof(remove))) return FALSE;
    if (!CloseHandle(s->index)) return FALSE;
    s->index = INVALID_HANDLE_VALUE;
    s->known = FALSE;
    s->empty = TRUE;
    return TRUE;
}

static BOOL publish_index(const wchar_t *root, unsigned id, slot *s) {
    wchar_t path[PATH_CAP], meta[PATH_CAP];
    BOOL missing = FALSE;
    if (!name(root, id, FALSE, path) || !name(root, id, TRUE, meta)) return FALSE;
    s->dump = open_file(path, &missing);
    if (s->dump == INVALID_HANDLE_VALUE || !identity(s->dump, &s->identity)) return FALSE;
    /* Exclusive create under the verified current-user directory ACL.
     * The identity record is flushed before any older dump is rotated.
     * If publication is interrupted, the unindexed dump is preserved. */
    s->index = CreateFileW(meta, GENERIC_READ | GENERIC_WRITE | DELETE, 0, NULL,
        CREATE_NEW, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (s->index == INVALID_HANDLE_VALUE) return FALSE;
    DWORD written = 0;
    if (!WriteFile(s->index, &s->identity, sizeof(s->identity), &written, NULL) ||
        written != sizeof(s->identity) || !FlushFileBuffers(s->index)) {
        FILE_DISPOSITION_INFO remove = {TRUE};
        (void)SetFileInformationByHandle(s->index, FileDispositionInfo, &remove, sizeof(remove));
        return FALSE;
    }
    s->known = TRUE;
    s->empty = FALSE;
    return TRUE;
}

BOOL pulse_dump_store_capture(const pulse_dump_backend *backend, HANDLE process,
    const DEBUG_EVENT *event, const wchar_t *root) {
    slot slots[SLOT_COUNT];
    for (unsigned i = 0; i < SLOT_COUNT; ++i)
        slots[i] = (slot){.dump = INVALID_HANDLE_VALUE, .index = INVALID_HANDLE_VALUE};
    BOOL ok = FALSE;
    unsigned free_slot = SLOT_COUNT, count = 0;
    FILETIME time;
    GetSystemTimeAsFileTime(&time);
    uint64_t now = ticks(time);
    for (unsigned i = 0; i < SLOT_COUNT; ++i) {
        if (!read_slot(root, i, &slots[i])) goto done;
        if (slots[i].known) ++count;
        else if (free_slot == SLOT_COUNT) free_slot = i;
    }
    /* An interrupted previous rotation can leave five verified files.
     * Reclaim a verified expired record or finish the previously
     * committed count rotation before admitting a new write. */
    if (free_slot == SLOT_COUNT) {
        for (unsigned i = 0; i < SLOT_COUNT; ++i) {
            uint64_t stamp = slots[i].identity.created;
            if (now >= stamp && now - stamp > MAX_AGE_TICKS) {
                if (!remove_owned(&slots[i])) goto done;
                free_slot = i;
                --count;
                break;
            }
        }
    }
    if (free_slot == SLOT_COUNT && count == SLOT_COUNT) {
        unsigned oldest = 0;
        for (unsigned i = 1; i < SLOT_COUNT; ++i)
            if (slots[i].identity.created < slots[oldest].identity.created) oldest = i;
        if (!remove_owned(&slots[oldest])) goto done;
        free_slot = oldest;
        --count;
    }
    if (free_slot == SLOT_COUNT) goto done;
    wchar_t output[PATH_CAP];
    if (!name(root, free_slot, FALSE, output) ||
        !pulse_dump_capture(backend, process, event, output, PULSE_DUMP_MAX_BYTES) ||
        !publish_index(root, free_slot, &slots[free_slot])) goto done;
    ++count;
    for (unsigned i = 0; i < SLOT_COUNT; ++i) {
        if (i == free_slot || !slots[i].known) continue;
        uint64_t stamp = slots[i].identity.created;
        if (now >= stamp && now - stamp > MAX_AGE_TICKS) {
            if (!remove_owned(&slots[i])) goto done;
            --count;
        }
    }
    while (count > RETAIN_COUNT) {
        unsigned oldest = SLOT_COUNT;
        for (unsigned i = 0; i < SLOT_COUNT; ++i) {
            if (i == free_slot || !slots[i].known) continue;
            if (oldest == SLOT_COUNT || slots[i].identity.created < slots[oldest].identity.created)
                oldest = i;
        }
        if (oldest == SLOT_COUNT || !remove_owned(&slots[oldest])) goto done;
        --count;
    }
    ok = TRUE;
done:
    for (unsigned i = 0; i < SLOT_COUNT; ++i) close_slot(&slots[i]);
    return ok;
}
