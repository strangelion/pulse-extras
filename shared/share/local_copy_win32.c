/* Explicit local developer harness, never started by Pulse UI.
 * Only the parent opens files; it owns the stage and commits after a second
 * digest verification. No network, elevated privileges or remote paths. */
/* Zig's Windows target supplies this macro. Do not override its SDK target. */
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0602
#endif
#include "local_protocol_win32.h"
#include "../fs/identity_win32.h"
#include "../process/image_win32.h"
#include "../process/job_win32.h"
#include <bcrypt.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define CAP PULSE_FILE_PATH_CAP
#define WAIT_LIMIT_MS 300000u
#define WORKER_COMMIT (64u * 1024u * 1024u)

static HANDLE cancel_event = NULL;

static BOOL WINAPI console_cancel(DWORD event) {
    if (event != CTRL_C_EVENT && event != CTRL_BREAK_EVENT) return FALSE;
    return cancel_event && SetEvent(cancel_event);
}

static void close_handle(HANDLE *h) {
    if (*h && *h != INVALID_HANDLE_VALUE) CloseHandle(*h);
    *h = NULL;
}

static BOOL leaf_ok(const wchar_t *name) {
    size_t n = wcslen(name);
    if (!n || n > 255 || name[n-1] == L'.' || name[n-1] == L' ') return FALSE;
    for (size_t i = 0; i < n; ++i)
        if (name[i] < 32 || wcschr(L"\\/:*?\"<>|", name[i])) return FALSE;
    wchar_t stem[256] = {0};
    size_t k = 0;
    while (k < n && name[k] != L'.') { stem[k] = name[k]; ++k; }
    while (k && stem[k-1] == L' ') stem[--k] = 0;
    const wchar_t *reserved[] = {L"CON", L"PRN", L"AUX", L"NUL", L"CONIN$", L"CONOUT$"};
    for (size_t i = 0; i < sizeof(reserved)/sizeof(reserved[0]); ++i)
        if (CompareStringOrdinal(stem, -1, reserved[i], -1, TRUE) == CSTR_EQUAL) return FALSE;
    if (k == 4 && (CompareStringOrdinal(stem, 3, L"COM", 3, TRUE) == CSTR_EQUAL ||
                   CompareStringOrdinal(stem, 3, L"LPT", 3, TRUE) == CSTR_EQUAL) &&
        ((stem[3] >= L'0' && stem[3] <= L'9') || stem[3] == 0xb9 ||
          stem[3] == 0xb2 || stem[3] == 0xb3)) return FALSE;
    return TRUE;
}

/* Strict absolute local DOS paths, no normalization of aliases or traversal. */
static BOOL path_ok(const wchar_t *path) {
    size_t n = wcslen(path);
    if (n < 4 || n >= CAP - 64 || path[1] != L':' || path[2] != L'\\' ||
        !((path[0] >= L'A' && path[0] <= L'Z') || (path[0] >= L'a' && path[0] <= L'z')))
        return FALSE;
    wchar_t drive[] = {path[0], L':', L'\\', 0};
    if (GetDriveTypeW(drive) != DRIVE_FIXED) return FALSE;
    const wchar_t *p = path + 3;
    while (*p) {
        const wchar_t *end = wcschr(p, L'\\');
        size_t len = end ? (size_t)(end-p) : wcslen(p);
        wchar_t part[256] = {0};
        if (!len || len >= 256) return FALSE;
        memcpy(part, p, len * sizeof(wchar_t));
        if (!leaf_ok(part)) return FALSE;
        if (!end) return TRUE;
        p = end + 1;
    }
    return FALSE;
}

static BOOL parse_digest(const wchar_t *value, uint8_t digest[32]) {
    if (wcslen(value) != 64) return FALSE;
    for (size_t i = 0; i < 32; ++i) {
        unsigned v = 0;
        for (size_t j = 0; j < 2; ++j) {
            wchar_t c = value[i*2+j];
            if (c >= L'0' && c <= L'9') v = v*16 + (unsigned)(c-L'0');
            else if (c >= L'a' && c <= L'f') v = v*16 + (unsigned)(c-L'a'+10);
            else return FALSE;
        }
        digest[i] = (uint8_t)v;
    }
    return TRUE;
}

static BOOL hash_file(HANDLE file, uint64_t expected, uint8_t digest[32]) {
    BCRYPT_ALG_HANDLE algorithm = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    BYTE *object = NULL, *buffer = NULL;
    DWORD obj_size = 0, got = 0;
    LARGE_INTEGER zero = {0}, actual;
    BOOL ok = FALSE;
    if (!GetFileSizeEx(file, &actual) || actual.QuadPart < 0 ||
        (uint64_t)actual.QuadPart != expected || expected > SHARE_LIMIT ||
        !SetFilePointerEx(file, zero, NULL, FILE_BEGIN)) goto done;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0) < 0 ||
        BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, (BYTE *)&obj_size,
                           sizeof(obj_size), &got, 0) < 0 ||
        got != sizeof(obj_size) || !obj_size || obj_size > 65536) goto done;
    object = malloc(obj_size);
    buffer = malloc(SHARE_CHUNK);
    if (!object || !buffer ||
        BCryptCreateHash(algorithm, &hash, object, obj_size, NULL, 0, 0) < 0) goto done;
    for (uint64_t left = expected; left;) {
        if (WaitForSingleObject(cancel_event, 0) != WAIT_TIMEOUT) goto done;
        DWORD n = left > SHARE_CHUNK ? SHARE_CHUNK : (DWORD)left;
        if (!share_read(file, buffer, n) || BCryptHashData(hash, buffer, n, 0) < 0) goto done;
        left -= n;
    }
    ok = BCryptFinishHash(hash, digest, 32, 0) >= 0 &&
        SetFilePointerEx(file, zero, NULL, FILE_BEGIN);
done:
    if (hash && BCryptDestroyHash(hash) < 0) ok = FALSE;
    if (algorithm && BCryptCloseAlgorithmProvider(algorithm, 0) < 0) ok = FALSE;
    free(object);
    free(buffer);
    return ok;
}

/* New same-directory staging object, owner-only protected ACL, no overwrite.
 * A successful final file keeps this ACL; no permissions are broadened. */
static HANDLE create_stage(const wchar_t *directory, wchar_t path[CAP]) {
    HANDLE token = NULL, file = INVALID_HANDLE_VALUE;
    union { TOKEN_USER align; BYTE bytes[1024]; } user;
    union { ACL align; BYTE bytes[sizeof(ACL)+sizeof(ACCESS_ALLOWED_ACE)+SECURITY_MAX_SID_SIZE]; } acl;
    SECURITY_DESCRIPTOR sd;
    DWORD got = 0;
    uint8_t random[16];
    wchar_t hex[33] = {0};
    const wchar_t digits[] = L"0123456789abcdef";
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return file;
    if (!GetTokenInformation(token, TokenUser, user.bytes, sizeof(user.bytes), &got)) goto done;
    PSID sid = ((TOKEN_USER *)user.bytes)->User.Sid;
    if (!sid || !IsValidSid(sid) || !InitializeAcl((PACL)acl.bytes, sizeof(acl.bytes), ACL_REVISION) ||
        !AddAccessAllowedAce((PACL)acl.bytes, ACL_REVISION, FILE_ALL_ACCESS, sid) ||
        !InitializeSecurityDescriptor(&sd, SECURITY_DESCRIPTOR_REVISION) ||
        !SetSecurityDescriptorOwner(&sd, sid, FALSE) ||
        !SetSecurityDescriptorDacl(&sd, TRUE, (PACL)acl.bytes, FALSE) ||
        !SetSecurityDescriptorControl(&sd, SE_DACL_PROTECTED, SE_DACL_PROTECTED)) goto done;
    if (BCryptGenRandom(NULL, random, sizeof(random), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) goto done;
    for (size_t i = 0; i < sizeof(random); ++i) {
        hex[i*2] = digits[random[i] >> 4];
        hex[i*2+1] = digits[random[i] & 15];
    }
    int n = swprintf(path, CAP, L"%ls\\.pulse-share-%ls.part", directory, hex);
    if (n <= 0 || n >= (int)CAP) goto done;
    SECURITY_ATTRIBUTES sa = {sizeof(sa), &sd, FALSE};
    file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE | DELETE, 0, &sa,
        CREATE_NEW, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
done:
    CloseHandle(token);
    return file;
}

static BOOL dup_inherit(HANDLE h, HANDLE *out, DWORD access, DWORD flags) {
    return DuplicateHandle(GetCurrentProcess(), h, GetCurrentProcess(), out, access, TRUE, flags);
}

static int run_worker(const wchar_t *image, HANDLE source, HANDLE stage,
                      const share_request *request, share_reply *reply) {
    HANDLE job = NULL, request_read = NULL, request_write = NULL,
        reply_read = NULL, reply_write = NULL, inherited[5] = {0};
    PROCESS_INFORMATION process = {0};
    STARTUPINFOEXW si = {0};
    SIZE_T attribute_size = 0;
    BOOL initialized = FALSE, assigned = FALSE;
    int result = SHARE_CONTAINMENT;
    const char *phase = "prepare-ipc";
    wchar_t command[CAP + 128], system_dir[MAX_PATH];
    si.StartupInfo.cb = sizeof(si);
    job = CreateJobObjectW(NULL, NULL);
    if (!job || !pulse_job_configure(job, 1, WORKER_COMMIT, WORKER_COMMIT) ||
        !CreatePipe(&request_read, &request_write, NULL, 4096) ||
        !CreatePipe(&reply_read, &reply_write, NULL, 4096) ||
        !dup_inherit(source, &inherited[0], GENERIC_READ, 0) ||
        !dup_inherit(stage, &inherited[1], GENERIC_READ | GENERIC_WRITE, 0) ||
        !dup_inherit(request_read, &inherited[2], 0, DUPLICATE_SAME_ACCESS) ||
        !dup_inherit(reply_write, &inherited[3], 0, DUPLICATE_SAME_ACCESS) ||
        !dup_inherit(cancel_event, &inherited[4], SYNCHRONIZE, 0)) goto done;
    phase = "handle-list";
    InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_size);
    if (!attribute_size || attribute_size > 65536) goto done;
    si.lpAttributeList = malloc(attribute_size);
    if (!si.lpAttributeList ||
        !InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attribute_size)) goto done;
    initialized = TRUE;
    if (!UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
        inherited, sizeof(inherited), NULL, NULL)) goto done;
    UINT sys_len = GetSystemDirectoryW(system_dir, MAX_PATH);
    if (!sys_len || sys_len >= MAX_PATH) goto done;
    int n = swprintf(command, CAP+128, L"\"%ls\" %llx %llx %llx %llx %llx", image,
        (unsigned long long)(uintptr_t)inherited[0], (unsigned long long)(uintptr_t)inherited[1],
        (unsigned long long)(uintptr_t)inherited[2], (unsigned long long)(uintptr_t)inherited[3],
        (unsigned long long)(uintptr_t)inherited[4]);
    if (n <= 0 || n >= (int)(CAP+128)) goto done;
    phase = "create-worker";
    if (!CreateProcessW(image, command, NULL, NULL, TRUE,
        CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW,
        NULL, system_dir, &si.StartupInfo, &process)) goto done;
    phase = "assign-job";
    if (!AssignProcessToJobObject(job, process.hProcess)) goto done;
    assigned = TRUE;
    /* Parent closes every child-side duplicate before it starts. */
    for (size_t i = 0; i < 5; ++i) close_handle(&inherited[i]);
    close_handle(&request_read);
    close_handle(&reply_write);
    phase = "resume-worker";
    if (ResumeThread(process.hThread) == (DWORD)-1) goto done;
    phase = "send-request";
    if (!share_write(request_write, request, sizeof(*request))) { result = SHARE_IO; goto done; }
    close_handle(&request_write);
    HANDLE waiters[] = {cancel_event, process.hProcess};
    phase = "wait-worker";
    DWORD waited = WaitForMultipleObjects(2, waiters, FALSE, WAIT_LIMIT_MS);
    if (waited == WAIT_OBJECT_0) {
        /* Worker observes the event between chunks; never wait indefinitely. */
        WaitForSingleObject(process.hProcess, 1000);
        result = SHARE_CANCELLED;
        goto done;
    }
    if (waited != WAIT_OBJECT_0+1) goto done;
    phase = "validate-receipt";
    DWORD exit_code = 0;
    if (!GetExitCodeProcess(process.hProcess, &exit_code) ||
        !share_read(reply_read, reply, sizeof(*reply)) ||
        reply->magic != SHARE_MAGIC || reply->version != SHARE_VERSION ||
        reply->reserved || reply->status > SHARE_CLEANUP || reply->bytes > request->size) {
        result = SHARE_PROTOCOL;
        goto done;
    }
    DWORD available = 0;
    if (PeekNamedPipe(reply_read, NULL, 0, NULL, &available, NULL) && available) {
        result = SHARE_PROTOCOL; goto done;
    }
    if (reply->status != SHARE_OK) { result = (int)reply->status; goto done; }
    result = !exit_code && reply->bytes == request->size ? SHARE_OK : SHARE_PROTOCOL;
done:
    if (result != SHARE_OK)
        fprintf(stderr, "Share worker phase=%s result=%d\n", phase, result);
    if (process.hProcess) {
        if (assigned) {
            if (!pulse_job_terminate_and_drain(job, 1, 5000)) {
                fputs("Share worker drain failed\n", stderr);
                result = SHARE_CONTAINMENT;
            }
        } else {
            if (!TerminateProcess(process.hProcess, 1) ||
                WaitForSingleObject(process.hProcess, 5000) != WAIT_OBJECT_0) result = SHARE_CONTAINMENT;
        }
    }
    close_handle(&job);
    close_handle(&process.hThread);
    close_handle(&process.hProcess);
    for (size_t i = 0; i < 5; ++i) close_handle(&inherited[i]);
    close_handle(&request_read); close_handle(&request_write);
    close_handle(&reply_read); close_handle(&reply_write);
    if (initialized) DeleteProcThreadAttributeList(si.lpAttributeList);
    free(si.lpAttributeList);
    return result;
}

static BOOL commit_stage(HANDLE stage, const wchar_t *target) {
    size_t n = wcslen(target);
    union { FILE_RENAME_INFO align; BYTE bytes[sizeof(FILE_RENAME_INFO)+CAP*sizeof(wchar_t)]; } storage = {0};
    FILE_RENAME_INFO *rename = (FILE_RENAME_INFO *)storage.bytes;
    rename->ReplaceIfExists = FALSE;
    rename->RootDirectory = NULL;
    rename->FileNameLength = (DWORD)(n*sizeof(wchar_t));
    memcpy(rename->FileName, target, (n+1)*sizeof(wchar_t));
    return SetFileInformationByHandle(stage, FileRenameInfo, rename,
        (DWORD)(sizeof(FILE_RENAME_INFO)+(n+1)*sizeof(wchar_t)));
}

static int copy_local(const wchar_t *worker, const wchar_t *worker_digest,
    const wchar_t *source_path, const wchar_t *directory, const wchar_t *name,
    const wchar_t *source_digest) {
    HANDLE image = INVALID_HANDLE_VALUE, source = INVALID_HANDLE_VALUE,
        root = INVALID_HANDLE_VALUE, stage = INVALID_HANDLE_VALUE;
    wchar_t target[CAP] = {0}, temp[CAP] = {0};
    uint8_t expected[32], actual[32], required[32];
    BY_HANDLE_FILE_INFORMATION info;
    LARGE_INTEGER size;
    int result = SHARE_DESTINATION;
    BOOL committed = FALSE;
    const char *phase = "validate-input";
    if (!path_ok(worker) || !parse_digest(worker_digest, expected) ||
        !path_ok(source_path) || !path_ok(directory) || !leaf_ok(name) ||
        (source_digest && !parse_digest(source_digest, required))) return result;
    int n = swprintf(target, CAP, L"%ls\\%ls", directory, name);
    if (n <= 0 || n >= (int)CAP) return result;
    phase = "verify-image";
    image = pulse_image_pin(worker);
    if (image == INVALID_HANDLE_VALUE || pulse_image_verify(image, expected) != PULSE_IMAGE_OK) {
        result = SHARE_INTEGRITY; goto done;
    }
    phase = "open-source";
    source = CreateFileW(source_path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (!pulse_file_observe(source, source_path, FALSE, TRUE, &info) ||
        (info.dwFileAttributes & (FILE_ATTRIBUTE_OFFLINE | FILE_ATTRIBUTE_ENCRYPTED |
                                   FILE_ATTRIBUTE_SPARSE_FILE | FILE_ATTRIBUTE_DEVICE)) ||
        !GetFileSizeEx(source, &size) || size.QuadPart < 0 ||
        (uint64_t)size.QuadPart > SHARE_LIMIT) goto done;
    phase = "open-destination";
    root = CreateFileW(directory, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (!pulse_file_observe(root, directory, TRUE, TRUE, &info)) goto done;
    share_request request = {SHARE_MAGIC, SHARE_VERSION, (uint64_t)size.QuadPart, {0}};
    phase = "hash-source";
    if (!hash_file(source, request.size, request.sha256)) {
        result = WaitForSingleObject(cancel_event, 0) == WAIT_OBJECT_0 ? SHARE_CANCELLED : SHARE_IO;
        goto done;
    }
    if (source_digest && memcmp(required, request.sha256, sizeof(required))) {
        result = SHARE_INTEGRITY; goto done;
    }
    phase = "create-stage";
    stage = create_stage(directory, temp);
    if (stage == INVALID_HANDLE_VALUE) goto done;
    if (!pulse_file_observe(stage, temp, FALSE, TRUE, &info)) goto done;
    share_reply reply = {0};
    phase = "run-worker";
    result = run_worker(worker, source, stage, &request, &reply);
    if (result != SHARE_OK) goto done;
    phase = "verify-stage";
    if (!hash_file(stage, request.size, actual) || memcmp(actual, request.sha256, 32)) {
        result = WaitForSingleObject(cancel_event, 0) == WAIT_OBJECT_0 ? SHARE_CANCELLED : SHARE_INTEGRITY;
        goto done;
    }
    phase = "recheck-stage";
    if (!pulse_file_observe(root, directory, TRUE, TRUE, &info) ||
        !pulse_file_observe(stage, temp, FALSE, TRUE, &info)) {
        result = SHARE_DESTINATION; goto done;
    }
    if (WaitForSingleObject(cancel_event, 0) != WAIT_TIMEOUT) {
        result = SHARE_CANCELLED; goto done;
    }
    phase = "commit-stage";
    if (!commit_stage(stage, target)) { result = SHARE_DESTINATION; goto done; }
    committed = TRUE;
    result = SHARE_OK;
done:
    if (result != SHARE_OK)
        fprintf(stderr, "Share copy phase=%s result=%d\n", phase, result);
    if (stage != INVALID_HANDLE_VALUE && !committed) {
        FILE_DISPOSITION_INFO disposition = {TRUE};
        if (!SetFileInformationByHandle(stage, FileDispositionInfo, &disposition, sizeof(disposition))) {
            /* Do not delete by path: another object could now own that name. */
            result = SHARE_CLEANUP;
            fwprintf(stderr, L"Owned stage cleanup failed; inspect %ls\n", temp);
        }
    }
    close_handle(&stage); close_handle(&root); close_handle(&source); close_handle(&image);
    return result;
}

int main(void) {
    int argc = 0;
    wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || !((argc == 7 && !wcscmp(argv[1], L"--confirm-local-copy")) ||
                   (argc == 8 && !wcscmp(argv[1], L"--confirm-verified-copy")) ||
                   (argc == 9 && !wcscmp(argv[1], L"--confirm-managed-copy")))) {
        if (argv) LocalFree(argv);
        fputs("Usage: pulse-share-local --confirm-local-copy worker.exe sha256 source destination-directory leaf\n"
              "       pulse-share-local --confirm-verified-copy worker.exe sha256 source destination-directory leaf source-sha256\n", stderr);
        return SHARE_PROTOCOL;
    }
    if (argc == 9) {
        const wchar_t *value = argv[8];
        wchar_t *end = NULL;
        if (!*value || wcslen(value) > 16) { LocalFree(argv); return SHARE_PROTOCOL; }
        for (const wchar_t *p = value; *p; ++p)
            if (!((*p >= L'0' && *p <= L'9') || (*p >= L'a' && *p <= L'f'))) {
                LocalFree(argv); return SHARE_PROTOCOL;
            }
        unsigned long long handle = wcstoull(value, &end, 16);
        cancel_event = (HANDLE)(uintptr_t)handle;
        if (!end || *end || !cancel_event || cancel_event == INVALID_HANDLE_VALUE ||
            !SetHandleInformation(cancel_event, HANDLE_FLAG_INHERIT, 0) ||
            WaitForSingleObject(cancel_event, 0) == WAIT_FAILED) {
            LocalFree(argv); return SHARE_CONTAINMENT;
        }
    } else {
        cancel_event = CreateEventW(NULL, TRUE, FALSE, NULL);
        if (!cancel_event || !SetConsoleCtrlHandler(console_cancel, TRUE)) {
            close_handle(&cancel_event); LocalFree(argv); return SHARE_CONTAINMENT;
        }
    }
    int result = copy_local(argv[2], argv[3], argv[4], argv[5], argv[6], argc >= 8 ? argv[7] : NULL);
    if (argc != 9) SetConsoleCtrlHandler(console_cancel, FALSE);
    /* Process exit owns event lifetime; don't race a dispatched handler. */
    LocalFree(argv);
    printf("PULSE_SHARE_LOCAL_V1 %d\n", result);
    return result;
}
