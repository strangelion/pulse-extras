/* Independent C-side layout and real DLL lifecycle check, not the Pulse host. */
#include <stddef.h>
#include <stdio.h>
#include <windows.h>
#include "pulse/abi.h"

_Static_assert(PULSE_SDK_PREVIEW == 3, "preview");
_Static_assert(sizeof(PulseStringView) == 16, "string size");
_Static_assert(_Alignof(PulseStringView) == 8, "string alignment");
_Static_assert(offsetof(PulseStringView, length) == 8, "string length");
_Static_assert(sizeof(PulseHostV1) == 24, "host size");
_Static_assert(_Alignof(PulseHostV1) == 8, "host alignment");
_Static_assert(offsetof(PulseHostV1, context) == 8, "host context");
_Static_assert(offsetof(PulseHostV1, query_interface) == 16, "host query");
_Static_assert(sizeof(PulsePluginV1) == 40, "plugin size");
_Static_assert(_Alignof(PulsePluginV1) == 8, "plugin alignment");
_Static_assert(offsetof(PulsePluginV1, instance) == 8, "instance");
_Static_assert(offsetof(PulsePluginV1, activate) == 16, "activate");
_Static_assert(offsetof(PulsePluginV1, deactivate) == 24, "deactivate");
_Static_assert(offsetof(PulsePluginV1, destroy) == 32, "destroy");

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)

int main(int argc, char **argv) {
    CHECK(argc == 2);
    for (int cycle = 0; cycle < 16; ++cycle) {
        HMODULE lib = LoadLibraryExA(argv[1], NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        CHECK(lib);
        PulsePluginSdkPreviewFn preview = (PulsePluginSdkPreviewFn)GetProcAddress(lib, "PulsePluginSdkPreview");
        PulsePluginEntryV1Fn entry = (PulsePluginEntryV1Fn)GetProcAddress(lib, "PulsePluginEntryV1");
        CHECK(preview && entry && preview() == PULSE_SDK_PREVIEW);
        PulseHostV1 host = { sizeof(host), PULSE_ABI_VERSION_1, NULL, NULL };
        PulsePluginV1 out = { .size = sizeof(out), .version = PULSE_ABI_VERSION_1 };
        CHECK(entry(NULL, &out) == PULSE_ERROR_ABI);
        CHECK(entry(&host, NULL) == PULSE_ERROR_ABI);
        out.version = 99;
        CHECK(entry(&host, &out) == PULSE_ERROR_ABI && !out.instance);
        out.version = PULSE_ABI_VERSION_1;
        CHECK(entry(&host, &out) == PULSE_OK);
        CHECK(out.instance && out.activate && out.deactivate && out.destroy);
        CHECK(out.activate(out.instance) == PULSE_OK);
        out.deactivate(out.instance);
        CHECK(out.activate(out.instance) == PULSE_OK);
        out.deactivate(out.instance);
        out.destroy(out.instance);
        CHECK(FreeLibrary(lib));
    }
    puts("C ABI DLL loader: 16 lifecycle cycles passed");
    return 0;
}
