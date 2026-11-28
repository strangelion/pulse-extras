
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *option(int argc, char **argv, const char *name) {
    for (int i = 4; i < argc; i++)
        if (!strcmp(argv[i], name)) return i + 1 < argc ? argv[i + 1] : "";
    return NULL;
}

static int matches(int argc, char **argv, const char *name, const char *value) {
    const char *actual = option(argc, argv, name);
    return actual && !strcmp(actual, value);
}

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
    if (!strcmp(argv[3], "device-prepare")) {
        const char *store = option(argc, argv, "--store"), *spool = option(argc, argv, "--spool");
        if (!store || !spool || !strstr(store, "\\identity") || !strstr(spool, "\\spool") || !strcmp(store, spool))
            return 10;
        puts("DEVICE_READY");
        return 0;
    }
    if (!strcmp(argv[3], "interfaces")) {
        puts("LOCAL 192.0.2.10  \"Fixture\"");
        return 0;
    }
    if (!strcmp(argv[3], "peer-list")) {
        puts("PEER2 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef 客厅电脑");
        return 0;
    }
    if ((!strcmp(argv[3], "send") || !strcmp(argv[3], "receive")) && option(argc, argv, "--sync-clipboard")) {
        char line[64];
        puts("OFFER fixture clipboard until cancelled? Enter yes:");
        if (!fgets(line, sizeof(line), stdin) || strncmp(line, "yes", 3)) return 11;
        puts("CLIPBOARD SYNC active; cancel to stop");
        puts("Fixture sync progress");
        if (WaitForSingleObject(cancel, 10000) != WAIT_OBJECT_0) return 12;
        puts("Pulse Share: context canceled");
        return 1;
    }
    if (!strcmp(argv[3], "send") && option(argc, argv, "--root-service")) {
        char line[64];
        puts("OFFER fixture directory until cancelled? Enter yes:");
        if (!fgets(line, sizeof(line), stdin) || strncmp(line, "yes", 3)) return 13;
        puts("LISTEN 192.0.2.10:45843");
        puts("Fixture directory progress");
        if (WaitForSingleObject(cancel, 10000) != WAIT_OBJECT_0) return 14;
        puts("Pulse Share: context canceled");
        return 1;
    }
    int routed = option(argc, argv, "--routed") != NULL;
    if (routed && (!matches(argc, argv, "--bind", "100.64.1.10") ||
        !matches(argc, argv, "--name", "overlay-test"))) return 7;
    if (!strcmp(argv[3], "pair-host")) {
        if (routed && (!matches(argc, argv, "--allowed-source", "100.64.1.20") ||
            !matches(argc, argv, "--port", "45844"))) return 8;
        puts(routed ? "LISTEN 100.64.1.10:45844" : "LISTEN 192.0.2.10:45843");
        puts("PAIRCODE 01234567 60");
        if (WaitForSingleObject(cancel, 10000) != WAIT_OBJECT_0) return 3;
        puts("Pulse Share: context canceled");
        return 1;
    }
    if (!strcmp(argv[3], "pair-join")) {
        if (routed && !matches(argc, argv, "--peer", "100.64.1.20:45844")) return 9;
        char line[64];
        puts("PAIRINPUT");
        if (!fgets(line, sizeof(line), stdin) || strncmp(line, "01234567", 8)) return 4;
        SecureZeroMemory(line, sizeof(line));
        if (matches(argc, argv, "--peer", "192.0.2.90:45844")) {
            puts("Pulse Share: peer must be a permitted numeric address and port");
            return 1;
        }
        puts("Trust device with fixture fingerprint 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
        if (!fgets(line, sizeof(line), stdin) || strncmp(line, "yes", 3)) return 5;
        puts(routed ? "COMPLETED routed pairing" : "COMPLETED pairing");
        return 0;
    }
    return 6;
}
