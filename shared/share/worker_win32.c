#include "local_protocol_win32.h"
#include <shellapi.h>
#include <stdlib.h>
#include <errno.h>
#include <wchar.h>

extern int share_receive_begin(uint64_t size, const uint8_t expected[32]);
extern int share_receive_chunk(uint64_t offset, const uint8_t *bytes, uint32_t len);
extern int share_receive_verify(void);

static HANDLE parse_handle(const wchar_t *text) {
    if (!text || !*text || wcslen(text) > 16) return NULL;
    for (const wchar_t *p = text; *p; ++p)
        if (!((*p >= L'0' && *p <= L'9') || (*p >= L'a' && *p <= L'f'))) return NULL;
    wchar_t *end = NULL;
    errno = 0;
    unsigned long long value = wcstoull(text, &end, 16);
    HANDLE h = (HANDLE)(uintptr_t)value;
    DWORD flags = 0;
    return !errno && end && !*end && h && h != INVALID_HANDLE_VALUE &&
        GetHandleInformation(h, &flags) ? h : NULL;
}

int share_worker_run(void) {
    int argc = 0;
    wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    HANDLE h[5] = {0};
    if (!argv || argc != 6) {
        if (argv) LocalFree(argv);
        return SHARE_PROTOCOL;
    }
    for (int i = 0; i < 5; ++i) {
        h[i] = parse_handle(argv[i+1]);
        if (!h[i]) { LocalFree(argv); return SHARE_PROTOCOL; }
        for (int j = 0; j < i; ++j)
            if (h[i] == h[j]) { LocalFree(argv); return SHARE_PROTOCOL; }
    }
    LocalFree(argv);
    HANDLE source = h[0], stage = h[1], request = h[2], reply = h[3], cancel = h[4];
    if (GetFileType(source) != FILE_TYPE_DISK || GetFileType(stage) != FILE_TYPE_DISK ||
        GetFileType(request) != FILE_TYPE_PIPE || GetFileType(reply) != FILE_TYPE_PIPE)
        return SHARE_PROTOCOL;
    share_request msg = {0};
    share_reply result = {SHARE_MAGIC, SHARE_VERSION, SHARE_PROTOCOL, 0, 0};
    BYTE *buffer = NULL;
    LARGE_INTEGER size;
    if (!share_read(request, &msg, sizeof(msg)) ||
        msg.magic != SHARE_MAGIC || msg.version != SHARE_VERSION || msg.size > SHARE_LIMIT)
        goto done;
    if (!GetFileSizeEx(source, &size) || size.QuadPart < 0 ||
        (uint64_t)size.QuadPart != msg.size ||
        !GetFileSizeEx(stage, &size) || size.QuadPart != 0) goto done;
    if (!share_receive_begin(msg.size, msg.sha256)) goto done;
    buffer = malloc(SHARE_CHUNK);
    result.status = SHARE_IO;
    if (!buffer) goto done;
    while (result.bytes < msg.size) {
        DWORD signal = WaitForSingleObject(cancel, 0);
        if (signal != WAIT_TIMEOUT) {
            result.status = signal == WAIT_OBJECT_0 ? SHARE_CANCELLED : SHARE_PROTOCOL;
            goto done;
        }
        uint64_t left = msg.size - result.bytes;
        DWORD n = left > SHARE_CHUNK ? SHARE_CHUNK : (DWORD)left;
        if (!share_read(source, buffer, n) || !share_write(stage, buffer, n)) goto done;
        if (!share_receive_chunk(result.bytes, buffer, n)) {
            result.status = SHARE_INTEGRITY;
            goto done;
        }
        result.bytes += n;
    }
    if (WaitForSingleObject(cancel, 0) != WAIT_TIMEOUT) {
        result.status = SHARE_CANCELLED;
        goto done;
    }
    if (!share_receive_verify()) { result.status = SHARE_INTEGRITY; goto done; }
    if (!FlushFileBuffers(stage)) goto done;
    result.status = SHARE_OK;
done:
    free(buffer);
    if (!share_write(reply, &result, sizeof(result))) return SHARE_IO;
    for (int i = 0; i < 5; ++i) CloseHandle(h[i]);
    return (int)result.status;
}
