/* One worker-owned request, fixed official HTTPS origins, no redirects.
 * No file paths or arbitrary headers enter this boundary. Transport is the
 * shared bounded HTTPS helper; Companion keeps its own origin/kind/size
 * admission policy at this call site. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <wchar.h>
#include "../network/https_win32.h"
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

__declspec(dllexport) int pet_market_http_get(unsigned kind, const uint8_t *url, size_t length, size_t cap,
    void *ctx, header_fn headers, chunk_fn chunk, cancel_fn canceled, uint32_t *os_error) {
    if (!os_error) return HTTP_INVALID;
    *os_error = 0;
    if (!ctx || !headers || !chunk || !canceled || !cap ||
        cap > (kind == 3 ? 320u * 1024u * 1024u : 4u * 1024u * 1024u) ||
        !pet_market_http_valid(kind, url, length)) return HTTP_INVALID;
    const wchar_t *host = kind == 3 ? L"zip.openpets.dev" : L"openpets.dev";
    size_t offset = kind == 3 ? strlen("https://zip.openpets.dev") : strlen("https://openpets.dev");
    wchar_t path[2049];
    if (length - offset >= sizeof(path) / sizeof(path[0])) return HTTP_INVALID;
    for (size_t n = offset; n < length; ++n) path[n - offset] = (wchar_t)url[n];
    path[length - offset] = 0;
    /* The shared helper re-validates host/path grammar but performs no origin
     * admission; pet_market_http_valid above remains the product policy. */
    return pulse_https_get(host, path, cap, ctx, headers, chunk, canceled, os_error);
}
