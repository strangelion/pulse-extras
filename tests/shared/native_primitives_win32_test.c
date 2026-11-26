#include "../../shared/process/job_win32.h"
#include "../../shared/process/image_win32.h"
#include "../../shared/network/https_win32.h"
#include "../../shared/pulse/menu_win32.h"
#include <stdio.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s (win32=%lu)\n", __LINE__, #x, (unsigned long)GetLastError()); return 1; } } while (0)
static int header(void *ctx, uint64_t length) { (void)ctx; (void)length; return 1; }
static int chunk(void *ctx, const uint8_t *data, size_t size) { (void)ctx; (void)data; (void)size; return 1; }
static int cancel(void *ctx) { (void)ctx; return 1; }

int main(void) {
    HANDLE job = CreateJobObjectW(NULL, NULL);
    DWORD active = 99;
    CHECK(job && pulse_job_configure(job, 1, 16u * 1024u * 1024u, 32u * 1024u * 1024u));
    CHECK(pulse_job_active(job, &active) && active == 0);
    CHECK(!pulse_job_configure(job, 1, 32u, 16u));
    CHECK(!pulse_job_terminate_and_drain(job, 1, 0));
    CHECK(pulse_job_terminate_and_drain(job, 1, 1000) && CloseHandle(job));
    CHECK(pulse_image_pin(L"relative.exe") == INVALID_HANDLE_VALUE);
    CHECK(pulse_image_verify(INVALID_HANDLE_VALUE, NULL) == PULSE_IMAGE_OS_ERROR);
    wchar_t self[1024];
    DWORD n = GetModuleFileNameW(NULL, self, 1024);
    CHECK(n && n < 1024);
    HANDLE image = pulse_image_pin(self);
    uint8_t wrong[32] = {0};
    CHECK(image != INVALID_HANDLE_VALUE);
    CHECK(pulse_image_verify(image, wrong) == PULSE_IMAGE_MISMATCH);
    CHECK(CloseHandle(image));
    uint32_t os_error = 0;
    int ctx = 0;
    CHECK(pulse_https_get(L"example.invalid", L"/../bad", 64, &ctx, header, chunk, cancel, &os_error) == HTTP_INVALID);
    CHECK(pulse_https_get(L"example.invalid", L"/fixture", 64, &ctx, header, chunk, cancel, &os_error) == HTTP_CANCELED);
    wchar_t scratch[16], out[16];
    CHECK(pulse_menu_escape_utf8("A&B", scratch, 16, out, 16) && !wcscmp(out, L"A&&B"));
    CHECK(!pulse_menu_escape_utf8("A&B", scratch, 16, out, 3) && !out[0]);
    puts("Shared native primitive checks passed");
    return 0;
}
