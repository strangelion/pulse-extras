#ifndef PULSE_SHARE_LOCAL_PROTOCOL_WIN32_H
#define PULSE_SHARE_LOCAL_PROTOCOL_WIN32_H
#include <windows.h>
#include <stdint.h>

/* Fixed-size, native-endian Windows x64 private IPC, not a network protocol.
 * The parent owns source, stage and commit. No pathname or command is sent. */
#define SHARE_MAGIC 0x31524853u
#define SHARE_VERSION 1u
#define SHARE_LIMIT (1024ull * 1024ull * 1024ull * 1024ull)
#define SHARE_CHUNK (256u * 1024u)

enum share_result { SHARE_OK = 0, SHARE_PROTOCOL = 1, SHARE_IO = 2,
    SHARE_CANCELLED = 3, SHARE_INTEGRITY = 4, SHARE_DESTINATION = 5,
    SHARE_CONTAINMENT = 6, SHARE_CLEANUP = 7 };
typedef struct {
    uint32_t magic, version;
    uint64_t size;
    uint8_t sha256[32];
} share_request;
typedef struct {
    uint32_t magic, version, status, reserved;
    uint64_t bytes;
} share_reply;
_Static_assert(sizeof(share_request) == 48, "request ABI");
_Static_assert(sizeof(share_reply) == 24, "reply ABI");

static inline BOOL share_read(HANDLE h, void *data, DWORD size) {
    BYTE *p = data;
    while (size) {
        DWORD got = 0;
        if (!ReadFile(h, p, size, &got, NULL) || !got || got > size) return FALSE;
        p += got;
        size -= got;
    }
    return TRUE;
}
static inline BOOL share_write(HANDLE h, const void *data, DWORD size) {
    const BYTE *p = data;
    while (size) {
        DWORD got = 0;
        if (!WriteFile(h, p, size, &got, NULL) || !got || got > size) return FALSE;
        p += got;
        size -= got;
    }
    return TRUE;
}
#endif
