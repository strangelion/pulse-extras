/* Private temporary directory and synthetic data; no real discovery token. */
#include "../../shared/companion/openpets_trust_win32.h"
#include <sddl.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#define CHECK(expr) do { if (!(expr)) { \
    fprintf(stderr, "trust test failed at line %d (win32=%lu)\n", __LINE__, \
        (unsigned long)GetLastError()); goto cleanup; \
} } while (0)

static PSECURITY_DESCRIPTOR descriptor(int public_read) {
    HANDLE token = NULL;
    union {
        TOKEN_USER align;
        BYTE bytes[sizeof(TOKEN_USER) + SECURITY_MAX_SID_SIZE];
    } data;
    DWORD size = 0;
    LPWSTR sid = NULL;
    PSECURITY_DESCRIPTOR sd = NULL;
    wchar_t sddl[512];
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return NULL;
    if (GetTokenInformation(token, TokenUser, data.bytes, sizeof(data.bytes), &size) &&
        ConvertSidToStringSidW(data.align.User.Sid, &sid) &&
        swprintf(sddl, 512, L"O:%lsD:P(A;;FA;;;%ls)(A;;FA;;;SY)(A;;FA;;;BA)%ls",
            sid, sid, public_read ? L"(A;;FR;;;WD)" : L"") > 0)
        ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl,
            SDDL_REVISION_1, &sd, NULL);
    if (sid) LocalFree(sid);
    CloseHandle(token);
    return sd;
}

static int make_file(const wchar_t *path, PSECURITY_DESCRIPTOR sd, DWORD size) {
    SECURITY_ATTRIBUTES sa = {sizeof(sa), sd, FALSE};
    HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, &sa, CREATE_NEW,
        FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0;
    char bytes[256];
    memset(bytes, 'x', sizeof(bytes));
    int ok = 1;
    while (size) {
        DWORD part = size > sizeof(bytes) ? (DWORD)sizeof(bytes) : size;
        DWORD written = 0;
        if (!WriteFile(file, bytes, part, &written, NULL) || written != part) {
            ok = 0;
            break;
        }
        size -= written;
    }
    CloseHandle(file);
    return ok;
}

int main(void) {
    int rc = 1;
    int directory_created = 0;
    wchar_t temp[MAX_PATH] = {0}, dir[MAX_PATH] = {0};
    wchar_t file[MAX_PATH] = {0}, link[MAX_PATH] = {0};
    wchar_t image[32768];
    DWORD image_len = (DWORD)(sizeof(image) / sizeof(image[0]));
    HANDLE directory = INVALID_HANDLE_VALUE, process = NULL, cancel = NULL;
    PSECURITY_DESCRIPTOR private_sd = descriptor(0), public_sd = descriptor(1);
    BYTE buffer[OP_DISCOVERY_MAX];
    DWORD count = 0;
    CHECK(private_sd && public_sd);
    DWORD temp_len = GetTempPathW(MAX_PATH, temp);
    CHECK(temp_len && temp_len < MAX_PATH);
    CHECK(GetTempFileNameW(temp, L"opt", 0, dir));
    CHECK(DeleteFileW(dir));
    SECURITY_ATTRIBUTES sa = {sizeof(sa), private_sd, FALSE};
    CHECK(CreateDirectoryW(dir, &sa));
    directory_created = 1;
    CHECK(swprintf(file, MAX_PATH, L"%ls\\ipc.json", dir) > 0);
    CHECK(swprintf(link, MAX_PATH, L"%ls\\other.json", dir) > 0);
    directory = CreateFileW(dir, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES |
        READ_CONTROL | SYNCHRONIZE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
        OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    CHECK(directory != INVALID_HANDLE_VALUE);

    CHECK(make_file(file, private_sd, 3));
    CHECK(op_read_discovery(directory, buffer, sizeof(buffer), &count,
        GetTickCount64() + 5000, NULL) == OP_PIPE_OK && count == 3 &&
        memcmp(buffer, "xxx", 3) == 0);
    CHECK(CreateHardLinkW(link, file, NULL));
    CHECK(op_read_discovery(directory, buffer, sizeof(buffer), &count,
        GetTickCount64() + 5000, NULL) == OP_PIPE_UNTRUSTED && count == 0);
    for (size_t i = 0; i < sizeof(buffer); ++i) CHECK(buffer[i] == 0);
    CHECK(DeleteFileW(link));
    CHECK(DeleteFileW(file));

    CHECK(make_file(file, public_sd, 3));
    CHECK(op_read_discovery(directory, buffer, sizeof(buffer), &count,
        GetTickCount64() + 5000, NULL) == OP_PIPE_UNTRUSTED && count == 0);
    CHECK(DeleteFileW(file));
    CHECK(make_file(file, private_sd, OP_DISCOVERY_MAX + 1));
    CHECK(op_read_discovery(directory, buffer, sizeof(buffer), &count,
        GetTickCount64() + 5000, NULL) == OP_PIPE_INVALID && count == 0);
    CHECK(DeleteFileW(file));
    CHECK(make_file(file, private_sd, OP_DISCOVERY_MAX));
    CHECK(op_read_discovery(directory, buffer, sizeof(buffer), &count,
        GetTickCount64() + 5000, NULL) == OP_PIPE_OK && count == sizeof(buffer));
    CHECK(DeleteFileW(file));

    cancel = CreateEventW(NULL, TRUE, TRUE, NULL);
    CHECK(cancel != NULL);
    CHECK(op_read_discovery(directory, buffer, sizeof(buffer), &count,
        GetTickCount64() + 5000, cancel) == OP_PIPE_CANCELED && count == 0);
    CHECK(op_read_discovery(directory, buffer, sizeof(buffer), &count,
        GetTickCount64(), NULL) == OP_PIPE_TIMEOUT && count == 0);
    CHECK(op_read_discovery(directory, buffer, sizeof(buffer), &count,
        GetTickCount64() + 5000, NULL) == OP_PIPE_UNAVAILABLE && count == 0);

    CHECK(QueryFullProcessImageNameW(GetCurrentProcess(), 0, image, &image_len));
    CHECK(op_open_candidate_process(GetCurrentProcessId(), image, &process,
        GetTickCount64() + 5000, NULL) == OP_PIPE_OK && process != NULL);
    CHECK(GetProcessId(process) == GetCurrentProcessId());
    CloseHandle(process);
    process = NULL;
    CHECK(op_open_candidate_process(GetCurrentProcessId(), L"C:\\wrong.exe", &process,
        GetTickCount64() + 5000, NULL) == OP_PIPE_UNTRUSTED && process == NULL);
    CHECK(op_open_candidate_process(GetCurrentProcessId(), image, &process,
        GetTickCount64() + 5000, cancel) == OP_PIPE_CANCELED && process == NULL);
    rc = 0;
cleanup:
    SecureZeroMemory(buffer, sizeof(buffer));
    if (process) CloseHandle(process);
    if (cancel) CloseHandle(cancel);
    if (directory != INVALID_HANDLE_VALUE) CloseHandle(directory);
    if (link[0]) DeleteFileW(link);
    if (file[0]) DeleteFileW(file);
    if (directory_created) RemoveDirectoryW(dir);
    if (private_sd) LocalFree(private_sd);
    if (public_sd) LocalFree(public_sd);
    return rc;
}
