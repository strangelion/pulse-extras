/* Real Windows kernel pipe, synthetic payload only. No OpenPets required. */
#include "../../shared/companion/openpets_pipe_win32.h"
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#define CHECK(expr) do { if (!(expr)) { \
    fprintf(stderr, "pipe test failed at line %d\n", __LINE__); \
    goto cleanup; \
} } while (0)

static DWORD WINAPI signal_cancel(LPVOID event) {
    Sleep(30);
    SetEvent((HANDLE)event);
    return 0;
}

int main(void) {
    int rc = 1;
    HANDLE server = INVALID_HANDLE_VALUE;
    HANDLE cancel = NULL;
    HANDLE worker = NULL;
    HANDLE process = NULL;
    op_pipe client = {0};
    wchar_t name[128];
    wchar_t wrong[128];
    DWORD pid = GetCurrentProcessId();
    DWORD count = 0;
    char buffer[32] = {0};
    unsigned long long nonce = (unsigned long long)GetTickCount64();
    CHECK(swprintf(name, 128, L"\\\\.\\pipe\\openpets-%016llx-%lu",
        nonce, (unsigned long)pid) > 0);
    CHECK(swprintf(wrong, 128, L"\\\\.\\pipe\\openpets-%016llx-%lu",
        nonce, (unsigned long)(pid == 1 ? 2 : 1)) > 0);
    process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
        FALSE, pid);
    CHECK(process != NULL);
    cancel = CreateEventW(NULL, TRUE, FALSE, NULL);
    CHECK(cancel != NULL);

    CHECK(op_pipe_open_verified(&client, wrong, process,
        GetTickCount64() + 2000, cancel) == OP_PIPE_UNTRUSTED);
    CHECK(client.handle == NULL);
    CHECK(op_pipe_open_verified(&client, name, process,
        GetTickCount64(), cancel) == OP_PIPE_TIMEOUT);

    server = CreateNamedPipeW(name, PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
        1, 4096, 4096, 0, NULL);
    CHECK(server != INVALID_HANDLE_VALUE);
    CHECK(op_pipe_open_verified(&client, name, process,
        GetTickCount64() + 2000, cancel) == OP_PIPE_OK);
    CHECK(ConnectNamedPipe(server, NULL) || GetLastError() == ERROR_PIPE_CONNECTED);

    CHECK(op_pipe_write(&client, "hello", 5, &count,
        GetTickCount64() + 2000, cancel) == OP_PIPE_OK && count == 5);
    CHECK(ReadFile(server, buffer, sizeof(buffer), &count, NULL) &&
        count == 5 && memcmp(buffer, "hello", 5) == 0);
    CHECK(WriteFile(server, "world\n", 6, &count, NULL) && count == 6);
    CHECK(op_pipe_read(&client, buffer, sizeof(buffer), &count,
        GetTickCount64() + 2000, cancel) == OP_PIPE_OK &&
        count == 6 && memcmp(buffer, "world\n", 6) == 0);

    /* Empty pipe: pending read must time out, drain, and permit another read. */
    CHECK(op_pipe_read(&client, buffer, sizeof(buffer), &count,
        GetTickCount64() + 30, cancel) == OP_PIPE_TIMEOUT && count == 0);
    worker = CreateThread(NULL, 0, signal_cancel, cancel, 0, NULL);
    CHECK(worker != NULL);
    CHECK(op_pipe_read(&client, buffer, sizeof(buffer), &count,
        GetTickCount64() + 2000, cancel) == OP_PIPE_CANCELED && count == 0);
    CHECK(WaitForSingleObject(worker, 2000) == WAIT_OBJECT_0);
    CloseHandle(worker);
    worker = NULL;
    CHECK(ResetEvent(cancel));
    CHECK(WriteFile(server, "x", 1, &count, NULL) && count == 1);
    CHECK(op_pipe_read(&client, buffer, sizeof(buffer), &count,
        GetTickCount64() + 2000, cancel) == OP_PIPE_OK && count == 1 && buffer[0] == 'x');

    CloseHandle(server);
    server = INVALID_HANDLE_VALUE;
    CHECK(op_pipe_read(&client, buffer, sizeof(buffer), &count,
        GetTickCount64() + 2000, cancel) == OP_PIPE_OK && count == 0);
    op_pipe_close(&client);
    op_pipe_close(&client);
    CHECK(client.handle == NULL);
    rc = 0;
cleanup:
    op_pipe_close(&client);
    if (server != INVALID_HANDLE_VALUE) CloseHandle(server);
    if (worker) {
        WaitForSingleObject(worker, INFINITE);
        CloseHandle(worker);
    }
    if (cancel) CloseHandle(cancel);
    if (process) CloseHandle(process);
    return rc;
}
