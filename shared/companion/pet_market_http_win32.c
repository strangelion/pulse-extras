/* One worker-owned request, fixed official HTTPS origins, no redirects.
 * No file paths or arbitrary headers enter this boundary. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <wchar.h>

typedef int (*header_fn)(void *, uint64_t);
typedef int (*chunk_fn)(void *, const uint8_t *, size_t);
typedef int (*cancel_fn)(void *);

enum { HTTP_OK, HTTP_INVALID, HTTP_NETWORK, HTTP_RESPONSE, HTTP_CANCELED, HTTP_LIMIT, HTTP_CLEANUP, HTTP_TIMEOUT };
static int eq(const uint8_t *s, size_t n, const char *text) {
    return n == strlen(text) && memcmp(s, text, n) == 0;
}
static int prefix(const uint8_t *s, size_t n, const char *text) {
    size_t len = strlen(text);
    return n >= len && memcmp(s, text, len) == 0;
}
static int suffix(const uint8_t *s, size_t n, const char *text) {
    size_t len = strlen(text);
    return n >= len && memcmp(s + n - len, text, len) == 0;
}

int pet_market_http_valid(unsigned kind, const uint8_t *url, size_t length) {
    if (!url || !length || length > 2048 || kind > 3) return 0;
    if (kind == 0) return eq(url, length, "https://openpets.dev/pets/catalog.v3.json");
    const char *base = kind == 1 ? "https://openpets.dev/pets/catalog.v3/" :
        kind == 2 ? "https://openpets.dev/pets/" : "https://zip.openpets.dev/pets/";
    if (!prefix(url, length, base)) return 0;
    size_t start = strlen(base);
    for (size_t j = start; j <= length; ++j) {
        if (j == length || url[j] == '/') {
            if (j == start || eq(url + start, j - start, ".") || eq(url + start, j - start, "..")) return 0;
            start = j + 1;
        } else {
            unsigned ch = url[j];
            if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == '.')) return 0;
        }
    }
    if (kind == 1) return suffix(url, length, ".json");
    if (kind == 2) return suffix(url, length, ".webp") || suffix(url, length, ".png");
    return suffix(url, length, ".zip");
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

__declspec(dllexport) int pet_market_http_get(unsigned kind, const uint8_t *url, size_t length, size_t cap,
    void *ctx, header_fn headers, chunk_fn chunk, cancel_fn canceled, uint32_t *os_error) {
    if (!os_error) return HTTP_INVALID;
    *os_error = 0;
    if (!ctx || !headers || !chunk || !canceled || !cap ||
        cap > (kind == 3 ? 320u * 1024u * 1024u : 4u * 1024u * 1024u) ||
        !pet_market_http_valid(kind, url, length)) return HTTP_INVALID;
    if (canceled(ctx)) return HTTP_CANCELED;
    ULONGLONG start = GetTickCount64();
    const wchar_t *host = kind == 3 ? L"zip.openpets.dev" : L"openpets.dev";
    size_t offset = kind == 3 ? strlen("https://zip.openpets.dev") : strlen("https://openpets.dev");
    wchar_t path[2049];
    for (size_t n = offset; n < length; ++n) path[n - offset] = (wchar_t)url[n];
    path[length - offset] = 0;
    HINTERNET session = NULL, connection = NULL, req = NULL;
    int result = HTTP_NETWORK, stop = HTTP_OK;
    DWORD flags = WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_AUTHENTICATION;
    DWORD header_cap = 32768;
    session = WinHttpOpen(L"PulseExtras-Companion/1", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session || !WinHttpSetTimeouts(session, 5000, 10000, 10000, 10000)) goto cleanup;
    if ((stop = stop_reason(ctx, canceled, start)) != HTTP_OK) { result = stop; goto cleanup; }
    connection = WinHttpConnect(session, host, INTERNET_DEFAULT_HTTPS_PORT, 0);
    if (!connection) goto cleanup;
    req = WinHttpOpenRequest(connection, L"GET", path, NULL, WINHTTP_NO_REFERER,
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
            expected = expected * 10 + (uint64_t)(*p - L'0');
            if (expected > cap) { result = HTTP_LIMIT; goto cleanup; }
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
