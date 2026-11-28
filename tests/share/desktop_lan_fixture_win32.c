
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 4 || strcmp(argv[1], "--managed-cancel-handle")) return 2;
    HANDLE cancel = (HANDLE)(uintptr_t)strtoull(argv[2], NULL, 16);
    setvbuf(stdout, NULL, _IONBF, 0);
    if (!strcmp(argv[3], "discover")) {
        if (argc > 5 && !strcmp(argv[5], "192.0.2.11")) return 0;
        puts("UNVERIFIED 192.0.2.14:45843");
        puts("PAIR_UNVERIFIED 192.0.2.15:45844");
        return 0;
    }
    if (!strcmp(argv[3], "interfaces")) {
        puts("LOCAL 192.0.2.10  \"Fixture\"");
        return 0;
    }
    if (!strcmp(argv[3], "pair-host")) {
        puts("LISTEN 192.0.2.10:45843");
        puts("PAIRCODE 01234567 60");
        if (WaitForSingleObject(cancel, 10000) != WAIT_OBJECT_0) return 3;
        puts("Pulse Share: context canceled");
        return 1;
    }
    if (!strcmp(argv[3], "pair-join")) {
        char line[64];
        puts("PAIRINPUT");
        if (!fgets(line, sizeof(line), stdin) || strncmp(line, "01234567", 8)) return 4;
        SecureZeroMemory(line, sizeof(line));
        puts("Trust device with fixture fingerprint 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
        if (!fgets(line, sizeof(line), stdin) || strncmp(line, "yes", 3)) return 5;
        puts("COMPLETED pairing");
        return 0;
    }
    return 6;
}
