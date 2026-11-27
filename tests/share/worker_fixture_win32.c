/* Test-only worker fixtures. Never included in a release or the Pulse UI.
 * The second variant reports success after writing incorrect file bytes,
 * proving that the parent does not trust a worker's success receipt. */
#include <windows.h>
#ifdef SHARE_FIXTURE_FALSE_SUCCESS
#include "../../shared/share/local_protocol_win32.h"
#include <shellapi.h>
#include <stdlib.h>
#include <wchar.h>

int main(void) {
    int argc = 0;
    wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || argc != 6) {
        if (argv) LocalFree(argv);
        return 23;
    }
    HANDLE stage = (HANDLE)(uintptr_t)wcstoull(argv[2], NULL, 16);
    HANDLE request = (HANDLE)(uintptr_t)wcstoull(argv[3], NULL, 16);
    HANDLE reply = (HANDLE)(uintptr_t)wcstoull(argv[4], NULL, 16);
    LocalFree(argv);
    share_request msg = {0};
    if (!share_read(request, &msg, sizeof(msg)) || msg.magic != SHARE_MAGIC ||
        msg.version != SHARE_VERSION || !msg.size || msg.size > 4096) return 23;
    BYTE wrong[4096] = {0};
    if (!share_write(stage, wrong, (DWORD)msg.size) || !FlushFileBuffers(stage))
        return 23;
    share_reply result = {SHARE_MAGIC, SHARE_VERSION, SHARE_OK, 0, msg.size};
    if (!share_write(reply, &result, sizeof(result))) return 23;
    return 0;
}
#else
int main(void) {
    ExitProcess(23);
    return 23;
}
#endif
