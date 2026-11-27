/* Independent Windows-header checks paired with forge.zig's ABI asserts.
 * No actual client launch, credentials or network call. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <stddef.h>
_Static_assert(sizeof(STARTUPINFOW) == 104, "STARTUPINFOW size");
_Static_assert(sizeof(PROCESS_INFORMATION) == 24, "PROCESS_INFORMATION size");
_Static_assert(offsetof(STARTUPINFOW, dwFlags) == 60, "flags offset");
_Static_assert(offsetof(STARTUPINFOW, hStdInput) == 80, "stdin offset");
_Static_assert(offsetof(PROCESS_INFORMATION, dwProcessId) == 16, "pid offset");
_Static_assert(WINHTTP_OPTION_DISABLE_FEATURE == 63, "disable option");
_Static_assert((WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_REDIRECTS |
                WINHTTP_DISABLE_AUTHENTICATION) == 7, "disable mask");
_Static_assert(WINHTTP_FLAG_SECURE == 0x00800000, "secure flag");
_Static_assert((WINHTTP_QUERY_FLAG_NUMBER | WINHTTP_QUERY_STATUS_CODE) ==
               0x20000013, "status query");
int main(void) {
    return 0;
}
