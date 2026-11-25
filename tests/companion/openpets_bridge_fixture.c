/* Real local pipe and private discovery fixture; no real credentials. */
#include "../../shared/companion/openpets_bridge_win32.h"
#include <sddl.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

typedef int (*probe_callback)(const wchar_t *, const wchar_t *, HANDLE);

static PSECURITY_DESCRIPTOR private_descriptor(void) {
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
        swprintf(sddl, 512, L"O:%lsD:P(A;;FA;;;%ls)(A;;FA;;;SY)(A;;FA;;;BA)", sid, sid) > 0)
        ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SDDL_REVISION_1, &sd, NULL);
    if (sid) LocalFree(sid);
    CloseHandle(token);
    return sd;
}

typedef struct {
    op_pipe pipe;
    HANDLE cancel;
} server_context;

static DWORD WINAPI serve(LPVOID opaque) {
    server_context *ctx = opaque;
    OVERLAPPED ov = {0};
    ov.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
    DWORD result = 1;
    if (!ov.hEvent) goto cleanup;
    if (!ConnectNamedPipe(ctx->pipe.handle, &ov)) {
        DWORD err = GetLastError();
        if (err == ERROR_IO_PENDING) {
            HANDLE events[] = {ov.hEvent, ctx->cancel};
            DWORD ignored = 0;
            if (WaitForMultipleObjects(2, events, FALSE, 5000) != WAIT_OBJECT_0) {
                CancelIoEx(ctx->pipe.handle, &ov);
                GetOverlappedResult(ctx->pipe.handle, &ov, &ignored, TRUE);
                goto cleanup;
            }
            if (!GetOverlappedResult(ctx->pipe.handle, &ov, &ignored, FALSE)) goto cleanup;
        } else if (err != ERROR_PIPE_CONNECTED) goto cleanup;
    }
    char request[1024] = {0};
    DWORD total = 0;
    uint64_t deadline = GetTickCount64() + 4000;
    while (total < sizeof(request) - 1) {
        DWORD count = 0;
        if (op_pipe_read(&ctx->pipe, request + total, 1, &count,
            deadline, ctx->cancel) != OP_PIPE_OK || count != 1) goto cleanup;
        if (request[total++] == '\n') break;
    }
    const char expected[] = "{\"id\":\"bridge-1\",\"version\":1,\"token\":\"0123456789abcdef0123456789abcdef\",\"method\":\"hello\",\"params\":{}}\n";
    if (strcmp(request, expected) != 0) goto cleanup;
    const char response[] = "{\"id\":\"bridge-1\",\"ok\":true,\"result\":{\"ok\":true,\"protocol\":\"openpets-ipc\",\"protocolVersion\":1}}\n";
    DWORD sent = 0;
    if (op_pipe_write(&ctx->pipe, response, sizeof(response) - 1, &sent,
        deadline, ctx->cancel) != OP_PIPE_OK || sent != sizeof(response) - 1) goto cleanup;
    /* Flush before close, so unread bytes are not discarded. The fixture
     * owner cancels synchronous I/O if the client fails. */
    if (!FlushFileBuffers(ctx->pipe.handle)) goto cleanup;
    result = 0;
cleanup:
    if (ov.hEvent) CloseHandle(ov.hEvent);
    op_pipe_close(&ctx->pipe);
    return result;
}

#define CHECK(expr) do { if (!(expr)) { \
    fprintf(stderr, "bridge fixture failed at line %d (win32=%lu)\n", \
        __LINE__, (unsigned long)GetLastError()); goto cleanup; \
} } while (0)

int op_bridge_fixture(probe_callback callback) {
    int rc = 1, made_dir = 0;
    wchar_t temp[MAX_PATH] = {0}, directory[MAX_PATH] = {0}, file[MAX_PATH] = {0};
    wchar_t image[32768], pipe_name[128], bad_dir[MAX_PATH + 16];
    DWORD image_len = (DWORD)(sizeof(image) / sizeof(image[0]));
    HANDLE file_handle = INVALID_HANDLE_VALUE, worker = NULL, canceled = NULL;
    server_context ctx = {{NULL}, NULL};
    PSECURITY_DESCRIPTOR sd = private_descriptor();
    DWORD pid = GetCurrentProcessId(), count = 0, exit_code = 1;
    unsigned long long nonce = (unsigned long long)GetTickCount64();
    char json[512];
    CHECK(sd && callback);
    DWORD len = GetTempPathW(MAX_PATH, temp);
    CHECK(len && len < MAX_PATH);
    CHECK(GetTempFileNameW(temp, L"opb", 0, directory));
    CHECK(DeleteFileW(directory));
    SECURITY_ATTRIBUTES sa = {sizeof(sa), sd, FALSE};
    CHECK(CreateDirectoryW(directory, &sa));
    made_dir = 1;
    CHECK(swprintf(file, MAX_PATH, L"%ls\\ipc.json", directory) > 0);
    CHECK(swprintf(bad_dir, MAX_PATH + 16, L"%ls\\..", directory) > 0);
    CHECK(QueryFullProcessImageNameW(GetCurrentProcess(), 0, image, &image_len));
    CHECK(swprintf(pipe_name, 128, L"\\\\.\\pipe\\openpets-%016llx-%lu",
        nonce, (unsigned long)pid) > 0);
    int json_len = snprintf(json, sizeof(json),
        "{\"protocol\":\"openpets-ipc\",\"protocolVersion\":1,\"endpoint\":\"\\\\\\\\.\\\\pipe\\\\openpets-%016llx-%lu\",\"token\":\"0123456789abcdef0123456789abcdef\",\"appVersion\":\"0.0.0\",\"pid\":%lu,\"platform\":\"win32\"}",
        nonce, (unsigned long)pid, (unsigned long)pid);
    CHECK(json_len > 0 && (size_t)json_len < sizeof(json));
    file_handle = CreateFileW(file, GENERIC_WRITE, 0, &sa, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    CHECK(file_handle != INVALID_HANDLE_VALUE);
    CHECK(WriteFile(file_handle, json, (DWORD)json_len, &count, NULL) && count == (DWORD)json_len);
    CloseHandle(file_handle);
    file_handle = INVALID_HANDLE_VALUE;
    canceled = CreateEventW(NULL, TRUE, TRUE, NULL);
    CHECK(canceled);
    CHECK(callback(directory, image, canceled) == 2);
    CHECK(callback(bad_dir, image, NULL) == 3);
    CHECK(callback(directory, L"C:\\wrong.exe", NULL) == 3);

    ctx.cancel = CreateEventW(NULL, TRUE, FALSE, NULL);
    CHECK(ctx.cancel);
    ctx.pipe.handle = CreateNamedPipeW(pipe_name,
        PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
        1, 4096, 4096, 0, &sa);
    CHECK(ctx.pipe.handle != INVALID_HANDLE_VALUE);
    worker = CreateThread(NULL, 0, serve, &ctx, 0, NULL);
    CHECK(worker);
    CHECK(callback(directory, image, NULL) == 0);
    CHECK(WaitForSingleObject(worker, 5000) == WAIT_OBJECT_0);
    CHECK(GetExitCodeThread(worker, &exit_code) && exit_code == 0);
    rc = 0;
cleanup:
    if (worker) {
        SetEvent(ctx.cancel);
        CancelSynchronousIo(worker);
        WaitForSingleObject(worker, INFINITE);
        CloseHandle(worker);
    }
    op_pipe_close(&ctx.pipe);
    if (ctx.cancel) CloseHandle(ctx.cancel);
    if (canceled) CloseHandle(canceled);
    if (file_handle != INVALID_HANDLE_VALUE) CloseHandle(file_handle);
    if (file[0]) DeleteFileW(file);
    if (made_dir) RemoveDirectoryW(directory);
    if (sd) LocalFree(sd);
    return rc;
}
