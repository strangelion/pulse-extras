#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <string.h>
#include "https_win32.h"

/* A deliberately narrow transport grammar, NOT origin approval. */
static int valid_endpoint(const wchar_t *host, const wchar_t *path) {
    if (!host || !path || path[0] != L'/') return 0;
    size_t n = 0;
    while (n < 254 && host[n]) {
        wchar_t c = host[n++];
        if (!((c >= L'a' && c <= L'z') || (c >= L'0' && c <= L'9') || c == L'.' || c == L'-'))
            return 0;
    }
    if (!n || n >= 254 || host[0] == L'.' || host[n-1] == L'.') return 0;
    size_t start = 1;
    for (size_t i = 1; i <= 2048; ++i) {
        wchar_t c = path[i];
        if (!c || c == L'/') {
            size_t len = i - start;
            if (!len || (len == 1 && path[start] == L'.') ||
                (len == 2 && path[start] == L'.' && path[start+1] == L'.')) return 0;
            if (!c) return 1;
            start = i + 1;
        } else if (!((c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') ||
            (c >= L'0' && c <= L'9') || c == L'.' || c == L'-' || c == L'_')) return 0;
    }
    return 0;
}

/* 0 absent, 1 exactly one bounded header, -1 malformed/duplicate. */
static int single_header(HINTERNET req, DWORD query, wchar_t *out, DWORD cap) {
    DWORD bytes = cap * sizeof(wchar_t), index = 0;
    if (!WinHttpQueryHeaders(req, query, WINHTTP_HEADER_NAME_BY_INDEX, out, &bytes, &index))
        return GetLastError() == ERROR_WINHTTP_HEADER_NOT_FOUND ? 0 : -1;
    if (bytes >= cap * sizeof(wchar_t)) return -1;
    out[bytes / sizeof(wchar_t)] = 0;
    wchar_t extra[128];
    DWORD size = sizeof(extra);
    if (WinHttpQueryHeaders(req, query, WINHTTP_HEADER_NAME_BY_INDEX, extra, &size, &index)) return -1;
    return GetLastError() == ERROR_WINHTTP_HEADER_NOT_FOUND ? 1 : -1;
}

static int stop_reason(void *ctx, cancel_fn canceled, ULONGLONG start) {
    if (canceled(ctx)) return HTTP_CANCELED;
    if (GetTickCount64() - start >= 120000) return HTTP_TIMEOUT;
    return HTTP_OK;
}

int pulse_https_get(const wchar_t *approved_host, const wchar_t *approved_path, size_t cap,
    void *ctx, header_fn headers, chunk_fn chunk, cancel_fn canceled, uint32_t *os_error) {
    if (!os_error) return HTTP_INVALID;
    *os_error = 0;
    if (!ctx || !headers || !chunk || !canceled || !cap ||
        cap > 320u * 1024u * 1024u ||
        !valid_endpoint(approved_host, approved_path)) return HTTP_INVALID;
    if (canceled(ctx)) return HTTP_CANCELED;
    ULONGLONG start = GetTickCount64();
    HINTERNET session = NULL, connection = NULL, req = NULL;
    int result = HTTP_NETWORK, stop = HTTP_OK;
    DWORD flags = WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_AUTHENTICATION;
    DWORD header_cap = 32768;
    session = WinHttpOpen(L"PulseExtras/1", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session || !WinHttpSetTimeouts(session, 5000, 10000, 10000, 10000)) goto cleanup;
    if ((stop = stop_reason(ctx, canceled, start)) != HTTP_OK) { result = stop; goto cleanup; }
    connection = WinHttpConnect(session, approved_host, INTERNET_DEFAULT_HTTPS_PORT, 0);
    if (!connection) goto cleanup;
    req = WinHttpOpenRequest(connection, L"GET", approved_path, NULL, WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
    if (!req || !WinHttpSetOption(req, WINHTTP_OPTION_DISABLE_FEATURE, &flags, sizeof(flags)) ||
        !WinHttpSetOption(req, WINHTTP_OPTION_MAX_RESPONSE_HEADER_SIZE, &header_cap, sizeof(header_cap))) goto cleanup;
    /* Do not disable default server certificate/hostname checks. */
    if (!WinHttpSendRequest(req, L"Accept-Encoding: identity\r\n", (DWORD)-1L,
        WINHTTP_NO_REQUEST_DATA, 0, 0, 0)) goto cleanup;
    if ((stop = stop_reason(ctx, canceled, start)) != HTTP_OK) { result = stop; goto cleanup; }
    if (!WinHttpReceiveResponse(req, NULL)) goto cleanup;
    if ((stop = stop_reason(ctx, canceled, start)) != HTTP_OK) { result = stop; goto cleanup; }
    DWORD status = 0, size = sizeof(status);
    if (!WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        WINHTTP_HEADER_NAME_BY_INDEX, &status, &size, WINHTTP_NO_HEADER_INDEX)) goto cleanup;
    result = HTTP_RESPONSE;
    if (status != 200) goto cleanup;
    wchar_t header[128];
    int encoding = single_header(req, WINHTTP_QUERY_CONTENT_ENCODING, header, 128);
    if (encoding < 0 || (encoding && wcscmp(header, L"identity") != 0)) goto cleanup;
    uint64_t expected = 0;
    int has_length = single_header(req, WINHTTP_QUERY_CONTENT_LENGTH, header, 128);
    if (has_length < 0) goto cleanup;
    if (has_length) {
        if (!header[0]) goto cleanup;
        for (const wchar_t *p = header; *p; ++p) {
            if (*p < L'0' || *p > L'9') goto cleanup;
            uint64_t digit = (uint64_t)(*p - L'0');
            if (digit > cap || expected > (cap - digit) / 10u) {
                result = HTTP_LIMIT; goto cleanup;
            }
            expected = expected * 10u + digit;
        }
        if (!expected) goto cleanup;
    }
    if (!headers(ctx, expected)) goto cleanup;
    uint64_t total = 0;
    uint8_t buffer[16 * 1024];
    for (;;) {
        if ((stop = stop_reason(ctx, canceled, start)) != HTTP_OK) { result = stop; goto cleanup; }
        DWORD n = 0;
        if (!WinHttpReadData(req, buffer, sizeof(buffer), &n)) { result = HTTP_NETWORK; goto cleanup; }
        if ((stop = stop_reason(ctx, canceled, start)) != HTTP_OK) { result = stop; goto cleanup; }
        if (!n) break;
        if (n > cap - total) { result = HTTP_LIMIT; goto cleanup; }
        if (expected && n > expected - total) goto cleanup;
        if (!chunk(ctx, buffer, n)) goto cleanup;
        total += n;
    }
    if (!total || (expected && expected != total)) goto cleanup;
    result = HTTP_OK;
cleanup:
    if (result == HTTP_NETWORK) {
        *os_error = GetLastError();
        if (*os_error == ERROR_WINHTTP_TIMEOUT) result = HTTP_TIMEOUT;
    }
    if (result == HTTP_TIMEOUT) *os_error = ERROR_WINHTTP_TIMEOUT;
    if (req && !WinHttpCloseHandle(req)) result = HTTP_CLEANUP;
    if (connection && !WinHttpCloseHandle(connection)) result = HTTP_CLEANUP;
    if (session && !WinHttpCloseHandle(session)) result = HTTP_CLEANUP;
    return result;
}
