#ifndef PULSE_HTTPS_WIN32_H
#define PULSE_HTTPS_WIN32_H
#include <stdint.h>
#include <stddef.h>
#include <wchar.h>

typedef int (*header_fn)(void *, uint64_t);
typedef int (*chunk_fn)(void *, const uint8_t *, size_t);
typedef int (*cancel_fn)(void *);
enum { HTTP_OK, HTTP_INVALID, HTTP_NETWORK, HTTP_RESPONSE, HTTP_CANCELED, HTTP_LIMIT, HTTP_CLEANUP, HTTP_TIMEOUT };

/* Synchronous worker-only HTTPS GET. Host and resource path MUST already
 * be approved by the product's explicit origin/path policy, never direct UI
 * input. Transport validation is not an SSRF, DNS or provenance policy.
 * No redirects, cookies, auth or compression. Header/chunk callbacks are
 * borrowed and finish before return. Body cap <= 320 MiB; 120 s cooperative
 * deadline plus bounded blocking calls. Never call on the host UI thread. */
int pulse_https_get(const wchar_t *approved_host, const wchar_t *approved_path, size_t cap,
    void *ctx, header_fn headers, chunk_fn chunk, cancel_fn canceled, uint32_t *os_error);
#endif
