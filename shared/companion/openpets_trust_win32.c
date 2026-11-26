#include "openpets_trust_win32.h"
#include <aclapi.h>
#include <winternl.h>
#include <stddef.h>
#include <string.h>
#include <wchar.h>

typedef union {
    DWORD alignment;
    BYTE bytes[SECURITY_MAX_SID_SIZE];
} op_sid;

static op_pipe_result gate(uint64_t deadline, HANDLE cancel) {
    if (cancel) {
        DWORD state = WaitForSingleObject(cancel, 0);
        if (state == WAIT_OBJECT_0) return OP_PIPE_CANCELED;
        if (state != WAIT_TIMEOUT) return OP_PIPE_IO_ERROR;
    }
    return GetTickCount64() >= deadline ? OP_PIPE_TIMEOUT : OP_PIPE_OK;
}

static int token_identity(HANDLE process, op_sid *sid, DWORD *session) {
    HANDLE token = NULL;
    union {
        TOKEN_USER align;
        BYTE bytes[sizeof(TOKEN_USER) + SECURITY_MAX_SID_SIZE];
    } data;
    DWORD size = 0;
    int ok = 0;
    if (!OpenProcessToken(process, TOKEN_QUERY, &token)) return 0;
    if (!GetTokenInformation(token, TokenUser, data.bytes,
        (DWORD)sizeof(data.bytes), &size)) goto cleanup;
    if (!IsValidSid(data.align.User.Sid) ||
        !CopySid(sizeof(sid->bytes), sid->bytes, data.align.User.Sid))
        goto cleanup;
    if (!GetTokenInformation(token, TokenSessionId, session,
        sizeof(*session), &size)) goto cleanup;
    ok = 1;
cleanup:
    CloseHandle(token);
    return ok;
}

/* Intentionally conservative: only the current user, SYSTEM and local
 * Administrators can have effective allow ACEs. Unknown ACE layouts,
 * NULL DACLs and non-user owners fail closed. Deny ACEs do not grant access.
 * This protects neither against trusted principals nor preexisting malicious
 * same-user handles. The Windows security descriptor comes from the handle. */
static int private_acl(HANDLE handle, PSID user) {
    PSID owner = NULL;
    PACL dacl = NULL;
    PSECURITY_DESCRIPTOR descriptor = NULL;
    int ok = 0;
    if (GetSecurityInfo(handle, SE_FILE_OBJECT,
        OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
        &owner, NULL, &dacl, NULL, &descriptor) != ERROR_SUCCESS)
        goto cleanup;
    if (!owner || !IsValidSid(owner) || !EqualSid(owner, user) ||
        !dacl || !IsValidAcl(dacl) || dacl->AceCount > 128)
        goto cleanup;
    for (DWORD i = 0; i < dacl->AceCount; ++i) {
        void *entry = NULL;
        if (!GetAce(dacl, i, &entry)) goto cleanup;
        ACE_HEADER *header = entry;
        if (header->AceType == ACCESS_DENIED_ACE_TYPE) continue;
        if (header->AceType != ACCESS_ALLOWED_ACE_TYPE) goto cleanup;
        ACCESS_ALLOWED_ACE *allow = entry;
        size_t offset = offsetof(ACCESS_ALLOWED_ACE, SidStart);
        if (header->AceSize < offset + 8u) goto cleanup;
        PSID trustee = &allow->SidStart;
        SID *raw = trustee;
        if (header->AceSize < offset + 8u + (size_t)raw->SubAuthorityCount * sizeof(DWORD) ||
            !IsValidSid(trustee)) goto cleanup;
        if ((header->AceFlags & INHERIT_ONLY_ACE) || !allow->Mask) continue;
        if (!EqualSid(trustee, user) &&
            !IsWellKnownSid(trustee, WinLocalSystemSid) &&
            !IsWellKnownSid(trustee, WinBuiltinAdministratorsSid))
            goto cleanup;
    }
    ok = 1;
cleanup:
    if (descriptor) LocalFree(descriptor);
    return ok;
}

static int local_fixed_directory(HANDLE handle) {
    BY_HANDLE_FILE_INFORMATION info;
    wchar_t path[32768];
    if (GetFileType(handle) != FILE_TYPE_DISK ||
        !GetFileInformationByHandle(handle, &info) ||
        !(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT))
        return 0;
    DWORD length = GetFinalPathNameByHandleW(handle, path,
        (DWORD)(sizeof(path) / sizeof(path[0])), FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (length < 7 || length >= sizeof(path) / sizeof(path[0]) ||
        wcsncmp(path, L"\\\\?\\", 4) != 0 || path[5] != L':' || path[6] != L'\\')
        return 0;
    wchar_t root[] = {path[4], L':', L'\\', L'\0'};
    return GetDriveTypeW(root) == DRIVE_FIXED;
}

/* Single-component handle-relative open. No path concatenation, no fallback
 * to CreateFileW, no intermediate path components. Open a reparse object
 * itself and reject its attributes before any read. Native constants below
 * are the documented NtCreateFile options; resolve at runtime and fail closed
 * if unavailable. */
typedef NTSTATUS (NTAPI *op_nt_create_file)(PHANDLE, ACCESS_MASK,
    POBJECT_ATTRIBUTES, PIO_STATUS_BLOCK, PLARGE_INTEGER, ULONG, ULONG,
    ULONG, ULONG, PVOID, ULONG);

static op_pipe_result open_relative(HANDLE directory, wchar_t *name, USHORT length,
    int is_directory, HANDLE *file) {
    enum {
        op_file_open = 1,
        op_sync_nonalert = 0x20,
        op_directory = 0x1,
        op_non_directory = 0x40,
        op_open_reparse = 0x00200000,
        op_obj_case_insensitive = 0x40
    };
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    if (!ntdll) return OP_PIPE_IO_ERROR;
    FARPROC address = GetProcAddress(ntdll, "NtCreateFile");
    if (!address) return OP_PIPE_IO_ERROR;
    op_nt_create_file create;
    _Static_assert(sizeof(create) == sizeof(address), "Windows function pointer ABI");
    memcpy(&create, &address, sizeof(create));

    UNICODE_STRING child = {0};
    child.Buffer = name;
    child.Length = length;
    child.MaximumLength = length;
    OBJECT_ATTRIBUTES attributes = {0};
    attributes.Length = sizeof(attributes);
    attributes.RootDirectory = directory;
    attributes.ObjectName = &child;
    attributes.Attributes = op_obj_case_insensitive;
    IO_STATUS_BLOCK io = {0};
    HANDLE opened = NULL;
    NTSTATUS status = create(&opened,
        FILE_READ_DATA | FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE,
        &attributes, &io, NULL, FILE_ATTRIBUTE_NORMAL,
        is_directory ? FILE_SHARE_READ | FILE_SHARE_WRITE : FILE_SHARE_READ,
        op_file_open, op_sync_nonalert | op_open_reparse |
        (is_directory ? op_directory : op_non_directory),
        NULL, 0);
    if (status < 0 || !opened || opened == INVALID_HANDLE_VALUE)
        return OP_PIPE_UNAVAILABLE;
    *file = opened;
    return OP_PIPE_OK;
}

op_pipe_result op_read_discovery(HANDLE directory, void *buffer, DWORD capacity,
    DWORD *count, uint64_t deadline, HANDLE cancel) {
    if (!count) return OP_PIPE_INVALID;
    *count = 0;
    if (!buffer || !capacity || capacity > OP_DISCOVERY_MAX) return OP_PIPE_INVALID;
    SecureZeroMemory(buffer, capacity);
    if (!directory || directory == INVALID_HANDLE_VALUE) return OP_PIPE_INVALID;
    op_pipe_result result = gate(deadline, cancel);
    if (result != OP_PIPE_OK) return result;
    op_sid user;
    DWORD session = 0;
    if (!token_identity(GetCurrentProcess(), &user, &session) ||
        !local_fixed_directory(directory) || !private_acl(directory, user.bytes))
        return OP_PIPE_UNTRUSTED;
    result = gate(deadline, cancel);
    if (result != OP_PIPE_OK) return result;
    HANDLE file = NULL;
    wchar_t child[] = L"ipc.json";
    result = open_relative(directory, child, (USHORT)(sizeof(child) - sizeof(wchar_t)), 0, &file);
    if (result != OP_PIPE_OK) return result;

    BY_HANDLE_FILE_INFORMATION info;
    if (GetFileType(file) != FILE_TYPE_DISK ||
        !GetFileInformationByHandle(file, &info) ||
        (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
        info.nNumberOfLinks != 1 || !private_acl(file, user.bytes)) {
        result = OP_PIPE_UNTRUSTED;
        goto cleanup;
    }
    if (info.nFileSizeHigh || !info.nFileSizeLow || info.nFileSizeLow > capacity) {
        result = OP_PIPE_INVALID;
        goto cleanup;
    }
    DWORD total = 0;
    while (total < info.nFileSizeLow) {
        result = gate(deadline, cancel);
        if (result != OP_PIPE_OK) goto cleanup;
        DWORD received = 0;
        if (!ReadFile(file, (BYTE *)buffer + total, info.nFileSizeLow - total,
            &received, NULL) || !received || received > info.nFileSizeLow - total) {
            result = OP_PIPE_IO_ERROR;
            goto cleanup;
        }
        total += received;
    }
    /* A second read detects a size change rather than accepting truncation. */
    BYTE extra = 0;
    DWORD received = 0;
    if (!ReadFile(file, &extra, 1, &received, NULL) || received) {
        SecureZeroMemory(&extra, sizeof(extra));
        result = OP_PIPE_INVALID;
        goto cleanup;
    }
    result = gate(deadline, cancel);
    if (result == OP_PIPE_OK) *count = total;
cleanup:
    CloseHandle(file);
    if (result != OP_PIPE_OK) SecureZeroMemory(buffer, capacity);
    return result;
}

op_pipe_result op_open_candidate_process(DWORD pid, const wchar_t *approved_image,
    HANDLE *process, uint64_t deadline, HANDLE cancel) {
    if (!process) return OP_PIPE_INVALID;
    *process = NULL;
    if (!pid || !approved_image || !approved_image[0]) return OP_PIPE_INVALID;
    op_pipe_result result = gate(deadline, cancel);
    if (result != OP_PIPE_OK) return result;

    HANDLE candidate = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
        FALSE, pid);
    if (!candidate) return OP_PIPE_UNAVAILABLE;

    op_sid own_user, peer_user;
    DWORD own_session = 0, peer_session = 0;
    wchar_t path[32768];
    DWORD length = (DWORD)(sizeof(path) / sizeof(path[0]));
    if (WaitForSingleObject(candidate, 0) != WAIT_TIMEOUT ||
        GetProcessId(candidate) != pid ||
        !token_identity(GetCurrentProcess(), &own_user, &own_session) ||
        !token_identity(candidate, &peer_user, &peer_session) ||
        own_session != peer_session || !EqualSid(own_user.bytes, peer_user.bytes) ||
        !QueryFullProcessImageNameW(candidate, 0, path, &length) ||
        CompareStringOrdinal(path, -1, approved_image, -1, TRUE) != CSTR_EQUAL ||
        WaitForSingleObject(candidate, 0) != WAIT_TIMEOUT) {
        CloseHandle(candidate);
        return OP_PIPE_UNTRUSTED;
    }
    result = gate(deadline, cancel);
    if (result != OP_PIPE_OK) {
        CloseHandle(candidate);
        return result;
    }
    *process = candidate;
    return OP_PIPE_OK;
}


/* Explicit DOS path, walked component-by-component from a fixed-drive root.
 * The final handle pins the selected object; previously opened parents are
 * released after their child is opened. No environment or path search. */
op_pipe_result op_open_runtime_directory(const wchar_t *path, HANDLE *directory,
    uint64_t deadline, HANDLE cancel) {
    if (!directory) return OP_PIPE_INVALID;
    *directory = NULL;
    if (!path) return OP_PIPE_INVALID;
    size_t length = 0;
    while (length < 1024 && path[length]) ++length;
    if (length < 4 || length == 1024 || path[1] != L':' || path[2] != L'\\' ||
        !((path[0] >= L'A' && path[0] <= L'Z') || (path[0] >= L'a' && path[0] <= L'z')))
        return OP_PIPE_UNTRUSTED;
    wchar_t root[] = {path[0], L':', L'\\', L'\0'};
    op_pipe_result result = gate(deadline, cancel);
    if (result != OP_PIPE_OK) return result;
    if (GetDriveTypeW(root) != DRIVE_FIXED) return OP_PIPE_UNTRUSTED;
    HANDLE current = CreateFileW(root, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES |
        SYNCHRONIZE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (current == INVALID_HANDLE_VALUE) return OP_PIPE_UNAVAILABLE;
    if (!local_fixed_directory(current)) {
        result = OP_PIPE_UNTRUSTED;
        goto cleanup;
    }
    size_t offset = 3;
    unsigned components = 0;
    while (offset < length) {
        result = gate(deadline, cancel);
        if (result != OP_PIPE_OK) goto cleanup;
        wchar_t name[256];
        size_t n = 0;
        while (offset < length && path[offset] != L'\\') {
            wchar_t c = path[offset++];
            if (n >= 255 || c < 32 || c == L'/' || c == L':' ||
                c == L'*' || c == L'?' || c == L'"' || c == L'<' ||
                c == L'>' || c == L'|') {
                result = OP_PIPE_UNTRUSTED;
                goto cleanup;
            }
            name[n++] = c;
        }
        if (!n || name[n - 1] == L'.' || name[n - 1] == L' ' || ++components > 32) {
            result = OP_PIPE_UNTRUSTED;
            goto cleanup;
        }
        if (offset < length) {
            ++offset;
            if (offset == length) {
                result = OP_PIPE_UNTRUSTED;
                goto cleanup;
            }
        }
        HANDLE next = NULL;
        result = open_relative(current, name, (USHORT)(n * sizeof(wchar_t)), 1, &next);
        if (result != OP_PIPE_OK) goto cleanup;
        CloseHandle(current);
        current = next;
        if (!local_fixed_directory(current)) {
            result = OP_PIPE_UNTRUSTED;
            goto cleanup;
        }
    }
    op_sid user;
    DWORD session = 0;
    if (!token_identity(GetCurrentProcess(), &user, &session) ||
        !private_acl(current, user.bytes)) {
        result = OP_PIPE_UNTRUSTED;
        goto cleanup;
    }
    result = gate(deadline, cancel);
    if (result == OP_PIPE_OK) {
        *directory = current;
        return OP_PIPE_OK;
    }
cleanup:
    CloseHandle(current);
    return result;
}
