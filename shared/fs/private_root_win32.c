#include "private_root_win32.h"
#include "identity_win32.h"
#include <aclapi.h>
#include <wchar.h>
#include <string.h>

#define CAP PULSE_PRIVATE_PATH_CAP
#define INHERIT_FLAGS (OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE)

static BOOL canonical(HANDLE h, const wchar_t *path, BOOL directory) {
    BY_HANDLE_FILE_INFORMATION info;
    if (!pulse_file_observe(h, path, directory, TRUE, &info)) return FALSE;
    if (!directory && (info.nFileSizeHigh || info.nFileSizeLow)) {
        SetLastError(ERROR_INVALID_DATA);
        return FALSE;
    }
    return TRUE;
}
static HANDLE directory_open(const wchar_t *path, DWORD access) {
    return CreateFileW(path, access, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
        OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
}
static BOOL valid_parent(const wchar_t *p) {
    if (!p) return FALSE;
    size_t n = 0;
    while (n < CAP && p[n]) ++n;
    if (n < 4 || n >= CAP - 64 || p[1] != L':' || p[2] != L'\\' || p[n-1] == L'\\') return FALSE;
    wchar_t drive[] = {p[0], L':', L'\\', 0};
    return GetDriveTypeW(drive) == DRIVE_FIXED;
}

static BOOL approve_acl(HANDLE root, PSID user) {
    PSID owner = NULL;
    PACL dacl = NULL;
    PSECURITY_DESCRIPTOR sd = NULL;
    DWORD status = GetSecurityInfo(root, SE_FILE_OBJECT,
        OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, &owner, NULL, &dacl, NULL, &sd);
    BOOL approved = FALSE;
    if (status == ERROR_SUCCESS && sd && owner && dacl && IsValidSid(owner) &&
        EqualSid(owner, user) && IsValidAcl(dacl)) {
        SECURITY_DESCRIPTOR_CONTROL control;
        DWORD revision;
        void *raw = NULL;
        if (GetSecurityDescriptorControl(sd, &control, &revision) &&
            (control & SE_DACL_PROTECTED) && (control & SE_DACL_PRESENT) &&
            dacl->AceCount == 1 && GetAce(dacl, 0, &raw) && raw) {
            ACCESS_ALLOWED_ACE *ace = raw;
            if (ace->Header.AceType == ACCESS_ALLOWED_ACE_TYPE &&
                ace->Header.AceFlags == INHERIT_FLAGS &&
                ace->Header.AceSize == offsetof(ACCESS_ALLOWED_ACE, SidStart) + GetLengthSid(user) &&
                ace->Mask == FILE_ALL_ACCESS && IsValidSid(&ace->SidStart) &&
                EqualSid(&ace->SidStart, user)) approved = TRUE;
        }
    }
    if (sd && LocalFree(sd)) return FALSE;
    return approved;
}

pulse_private_result pulse_private_root_close(pulse_private_root *lease) {
    if (!lease) return PULSE_PRIVATE_INVALID;
    HANDLE *handles[] = {&lease->lock, &lease->root, &lease->parent};
    for (size_t i = 0; i < sizeof(handles)/sizeof(handles[0]); ++i) {
        if (*handles[i]) {
            if (!CloseHandle(*handles[i])) return PULSE_PRIVATE_CLEANUP_FAILED;
            *handles[i] = NULL;
        }
    }
    lease->path[0] = 0;
    return PULSE_PRIVATE_OK;
}

/* Only fixed, caller-reviewed product namespaces. Never pass UI input. */
static BOOL valid_namespace(const wchar_t *name) {
    static const wchar_t prefix[] = L"PulseExtras-";
    if (!name) return FALSE;
    size_t n = 0;
    while (n < 48 && name[n]) ++n;
    if (n <= 12 || n >= 48 || wcsncmp(name, prefix, 12)) return FALSE;
    for (size_t i = 12; i < n; ++i) {
        wchar_t c = name[i];
        if (!((c >= L'A' && c <= L'Z') || (c >= L'a' && c <= L'z') ||
            (c >= L'0' && c <= L'9') || c == L'-')) return FALSE;
    }
    return TRUE;
}

pulse_private_result pulse_private_root_open(pulse_private_root *lease, const wchar_t *parent, const wchar_t *name) {
    if (!lease || lease->parent || lease->root || lease->lock || !valid_parent(parent) || !valid_namespace(name)) return PULSE_PRIVATE_INVALID;
    pulse_private_result result = PULSE_PRIVATE_INVALID;
    HANDLE token = NULL;
    union { TOKEN_USER alignment; BYTE bytes[1024]; } token_buffer;
    union { ACL alignment; BYTE bytes[sizeof(ACL) + sizeof(ACCESS_ALLOWED_ACE) + SECURITY_MAX_SID_SIZE]; } acl_buffer;
    SECURITY_DESCRIPTOR sd;
    DWORD written = 0;
    HANDLE p = directory_open(parent, FILE_READ_ATTRIBUTES);
    if (p == INVALID_HANDLE_VALUE) return PULSE_PRIVATE_IO;
    lease->parent = p;
    if (!canonical(p, parent, TRUE)) goto done;
    int n = swprintf(lease->path, CAP, L"%ls\\%ls", parent, name);
    if (n <= 0 || n >= (int)CAP - 32) goto done;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
        result = PULSE_PRIVATE_IO; goto done;
    }
    if (!GetTokenInformation(token, TokenUser, token_buffer.bytes, sizeof(token_buffer.bytes), &written)) {
        result = PULSE_PRIVATE_IO; goto done;
    }
    PSID user = ((TOKEN_USER *)token_buffer.bytes)->User.Sid;
    if (!user || !IsValidSid(user)) goto done;
    PACL acl = (PACL)acl_buffer.bytes;
    if (!InitializeAcl(acl, sizeof(acl_buffer.bytes), ACL_REVISION) ||
        !AddAccessAllowedAceEx(acl, ACL_REVISION, INHERIT_FLAGS, FILE_ALL_ACCESS, user) ||
        !InitializeSecurityDescriptor(&sd, SECURITY_DESCRIPTOR_REVISION) ||
        !SetSecurityDescriptorOwner(&sd, user, FALSE) ||
        !SetSecurityDescriptorDacl(&sd, TRUE, acl, FALSE) ||
        !SetSecurityDescriptorControl(&sd, SE_DACL_PROTECTED, SE_DACL_PROTECTED)) {
        result = PULSE_PRIVATE_IO; goto done;
    }
    SECURITY_ATTRIBUTES sa = {sizeof(sa), &sd, FALSE};
    if (!CreateDirectoryW(lease->path, &sa) && GetLastError() != ERROR_ALREADY_EXISTS) {
        result = PULSE_PRIVATE_IO; goto done;
    }
    HANDLE root = directory_open(lease->path, FILE_READ_ATTRIBUTES | READ_CONTROL);
    if (root == INVALID_HANDLE_VALUE) { result = PULSE_PRIVATE_IO; goto done; }
    lease->root = root;
    if (!canonical(root, lease->path, TRUE) || !approve_acl(root, user)) goto done;

    wchar_t lock_path[CAP];
    n = swprintf(lock_path, CAP, L"%ls\\owner.lock", lease->path);
    if (n <= 0 || n >= (int)CAP) goto done;
    HANDLE lock = CreateFileW(lock_path, GENERIC_READ | GENERIC_WRITE, 0, NULL,
        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (lock == INVALID_HANDLE_VALUE) {
        result = GetLastError() == ERROR_SHARING_VIOLATION ? PULSE_PRIVATE_BUSY : PULSE_PRIVATE_IO;
        goto done;
    }
    lease->lock = lock;
    if (!canonical(lock, lock_path, FALSE)) goto done;
    result = PULSE_PRIVATE_OK;
done:
    if (token && !CloseHandle(token)) result = PULSE_PRIVATE_CLEANUP_FAILED;
    if (result != PULSE_PRIVATE_OK && pulse_private_root_close(lease) != PULSE_PRIVATE_OK)
        result = PULSE_PRIVATE_CLEANUP_FAILED;
    return result;
}
