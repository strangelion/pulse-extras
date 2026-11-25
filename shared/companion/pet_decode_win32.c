#define COBJMACROS
#include "pet_demo_win32.h"
#include <wincodec.h>
#include <stdlib.h>
#include <stdio.h>
#include <wchar.h>
#include <string.h>

#define MAX_COMPRESSED (16u * 1024u * 1024u)

static uint8_t *read_handle(HANDLE file, DWORD limit, DWORD *length) {
    *length = 0;
    uint8_t *data = NULL;
    BY_HANDLE_FILE_INFORMATION info;
    LARGE_INTEGER zero = {0};
    if (!file || file == INVALID_HANDLE_VALUE || GetFileType(file) != FILE_TYPE_DISK ||
        !GetFileInformationByHandle(file, &info) ||
        (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
        info.nFileSizeHigh || !info.nFileSizeLow || info.nFileSizeLow > limit ||
        !SetFilePointerEx(file, zero, NULL, FILE_BEGIN)) return NULL;
    data = malloc(info.nFileSizeLow);
    if (!data) return NULL;
    DWORD total = 0;
    while (total < info.nFileSizeLow) {
        DWORD count = 0;
        if (!ReadFile(file, data + total, info.nFileSizeLow - total, &count, NULL) ||
            !count || count > info.nFileSizeLow - total) goto cleanup;
        total += count;
    }
    BYTE extra = 0;
    DWORD count = 0;
    if (!ReadFile(file, &extra, 1, &count, NULL) || count) goto cleanup;
    *length = total;
cleanup:
    if (!*length) { free(data); data = NULL; }
    return data;
}

static BOOL fixed_path(HANDLE file, wchar_t *resolved, DWORD capacity) {
    DWORD n = GetFinalPathNameByHandleW(file, resolved, capacity,
        FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (n < 7 || n >= capacity || resolved[0] != L'\\' || resolved[1] != L'\\' ||
        resolved[2] != L'?' || resolved[3] != L'\\' || resolved[5] != L':' ||
        resolved[6] != L'\\') return FALSE;
    wchar_t root[] = {resolved[4], L':', L'\\', L'\0'};
    return GetDriveTypeW(root) == DRIVE_FIXED;
}

static uint8_t *read_local(const wchar_t *path, DWORD limit, DWORD *length) {
    *length = 0;
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL,
        OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (file == INVALID_HANDLE_VALUE) return NULL;
    wchar_t resolved[32768];
    uint8_t *data = fixed_path(file, resolved, 32768) ? read_handle(file, limit, length) : NULL;
    CloseHandle(file);
    return data;
}

/* Canonical local paths with pinned handles, not a race-free directory walk. */
static HANDLE package_handle(const wchar_t *path, BOOL directory) {
    HANDLE file = CreateFileW(path, directory ? FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES : GENERIC_READ,
        FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT |
        (directory ? FILE_FLAG_BACKUP_SEMANTICS : FILE_FLAG_SEQUENTIAL_SCAN), NULL);
    if (file == INVALID_HANDLE_VALUE) return NULL;
    BY_HANDLE_FILE_INFORMATION info;
    wchar_t resolved[1024];
    if (!GetFileInformationByHandle(file, &info) ||
        (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
        (!!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != !!directory) ||
        (!directory && info.nNumberOfLinks != 1) ||
        !fixed_path(file, resolved, 1024) ||
        CompareStringOrdinal(resolved, -1, path, -1, TRUE) != CSTR_EQUAL) {
        CloseHandle(file);
        return NULL;
    }
    return file;
}

static BOOL join_path(wchar_t *out, size_t capacity, const wchar_t *root, const wchar_t *leaf) {
    size_t a = wcslen(root), b = wcslen(leaf);
    if (a >= capacity || b >= capacity || a + b + 2 > capacity) return FALSE;
    memcpy(out, root, a * sizeof(wchar_t));
    out[a] = L'\\';
    memcpy(out + a + 1, leaf, (b + 1) * sizeof(wchar_t));
    return TRUE;
}

static BOOL leaf_wide(const uint8_t *leaf, wchar_t *out, size_t capacity) {
    size_t i = 0;
    for (; i + 1 < capacity && leaf[i]; ++i) {
        uint8_t c = leaf[i];
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
            c == '_' || c == '-' || c == '.')) return FALSE;
        out[i] = (wchar_t)c;
    }
    if (!i || leaf[i]) return FALSE;
    out[i] = 0;
    return TRUE;
}

void pet_package_close(pet_package *package) {
    if (!package) return;
    for (unsigned i = 0; i < PET_PACKAGE_MAX; ++i)
        if (package->files[i]) CloseHandle(package->files[i]);
    if (package->atlas) CloseHandle(package->atlas);
    if (package->activities) CloseHandle(package->activities);
    if (package->root) CloseHandle(package->root);
    ZeroMemory(package, sizeof(*package));
}

BOOL pet_package_open(pet_package *package, const wchar_t *folder,
    const wchar_t *id, pet_package_parse_fn parse,
    pet_demo_validate_fn validate, pet_demo_validate_fn validate_activity) {
    if (!package || package->root || !folder || !id || !parse || !validate || !validate_activity)
        return FALSE;
    wchar_t root[1024] = L"\\\\?\\";
    wchar_t path[1024], activity_dir[1024], leaf[80];
    DWORD n = GetFullPathNameW(folder, 1020, root + 4, NULL);
    if (n < 4 || n >= 1020 || root[5] != L':' || root[6] != L'\\') return FALSE;
    if (root[n + 3] == L'\\') root[n + 3] = 0;
    uint8_t id8[64];
    size_t id_len = wcslen(id);
    if (!id_len || id_len > sizeof(id8)) return FALSE;
    for (size_t i = 0; i < id_len; ++i) {
        if (id[i] > 127) return FALSE;
        id8[i] = (uint8_t)id[i];
    }
    uint8_t *data = NULL;
    HANDLE metadata = NULL, enumeration = INVALID_HANDLE_VALUE;
    DWORD length = 0;
    BOOL ok = FALSE;
    package->root = package_handle(root, TRUE);
    if (!package->root || !join_path(path, 1024, root, L"pet.json") ||
        !(metadata = package_handle(path, FALSE))) goto cleanup;
    data = read_handle(metadata, 128u * 1024u, &length);
    if (!data || parse(data, length, id8, id_len, &package->meta) ||
        package->meta.count > PET_PACKAGE_MAX ||
        (package->meta.version != 1 && package->meta.version != 2)) goto cleanup;
    free(data); data = NULL;
    if (!join_path(path, 1024, root, L"spritesheet.webp") ||
        !(package->atlas = package_handle(path, FALSE))) goto cleanup;
    data = read_handle(package->atlas, MAX_COMPRESSED, &length);
    if (!data || validate(package->meta.version, data, length)) goto cleanup;
    free(data); data = NULL;
    if (!join_path(activity_dir, 1024, root, L"activities")) goto cleanup;
    DWORD attr = GetFileAttributesW(activity_dir);
    if (attr == INVALID_FILE_ATTRIBUTES) {
        if (package->meta.count || GetLastError() != ERROR_FILE_NOT_FOUND) goto cleanup;
        ok = TRUE; goto cleanup;
    }
    package->activities = package_handle(activity_dir, TRUE);
    if (!package->activities || !join_path(path, 1024, activity_dir, L"*")) goto cleanup;
    WIN32_FIND_DATAW found;
    enumeration = FindFirstFileW(path, &found);
    if (enumeration == INVALID_HANDLE_VALUE) {
        if (!package->meta.count && GetLastError() == ERROR_FILE_NOT_FOUND) ok = TRUE;
        goto cleanup;
    }
    unsigned seen = 0;
    do {
        if (wcscmp(found.cFileName, L".") == 0 || wcscmp(found.cFileName, L"..") == 0) continue;
        if (found.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) goto cleanup;
        unsigned i = 0;
        for (; i < package->meta.count; ++i) {
            if (!leaf_wide(package->meta.items[i].leaf, leaf, 80)) goto cleanup;
            if (wcscmp(found.cFileName, leaf) == 0) break;
        }
        if (i == package->meta.count || (seen & (1u << i)) ||
            !join_path(path, 1024, activity_dir, leaf) ||
            !(package->files[i] = package_handle(path, FALSE))) goto cleanup;
        seen |= 1u << i;
    } while (FindNextFileW(enumeration, &found));
    if (GetLastError() != ERROR_NO_MORE_FILES ||
        seen != ((1u << package->meta.count) - 1)) goto cleanup;
    size_t total = 0;
    for (unsigned i = 0; i < package->meta.count; ++i) {
        data = read_handle(package->files[i], 2u * 1024u * 1024u, &length);
        if (!data || length > 16u * 1024u * 1024u - total ||
            validate_activity(package->meta.items[i].frames, data, length)) goto cleanup;
        total += length;
        free(data); data = NULL;
    }
    ok = TRUE;
cleanup:
    if (enumeration != INVALID_HANDLE_VALUE) FindClose(enumeration);
    if (metadata) CloseHandle(metadata);
    free(data);
    if (!ok) pet_package_close(package);
    return ok;
}

static uint8_t *decode_static(const wchar_t *path, HANDLE pinned, unsigned kind,
    UINT width, UINT height, DWORD limit, pet_demo_validate_fn validate,
    size_t *decoded_bytes) {
    if (!decoded_bytes) return NULL;
    *decoded_bytes = 0;
    if ((!path && !pinned) || !validate) return NULL;
    const UINT stride = width * 4, bytes = stride * height;
    DWORD length = 0;
    uint8_t *input = pinned ? read_handle(pinned, limit, &length) : read_local(path, limit, &length);
    uint8_t *pixels = NULL;
    IWICImagingFactory *factory = NULL;
    IWICStream *stream = NULL;
    IWICBitmapDecoder *decoder = NULL;
    IWICBitmapFrameDecode *frame = NULL;
    IWICFormatConverter *converter = NULL;
    int com = 0;
    HRESULT hr = E_FAIL;
    UINT count = 0, actual_width = 0, actual_height = 0;
    if (!input || validate(kind, input, length)) goto cleanup;
    hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (FAILED(hr)) goto cleanup;
    com = 1;
    hr = CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER,
        &IID_IWICImagingFactory, (void **)&factory);
    if (FAILED(hr)) goto cleanup;
    hr = IWICImagingFactory_CreateStream(factory, &stream);
    if (FAILED(hr)) goto cleanup;
    hr = IWICStream_InitializeFromMemory(stream, input, length);
    if (FAILED(hr)) goto cleanup;
    hr = IWICImagingFactory_CreateDecoderFromStream(factory, (IStream *)stream,
        NULL, WICDecodeMetadataCacheOnDemand, &decoder);
    if (FAILED(hr)) goto cleanup;
    hr = IWICBitmapDecoder_GetFrameCount(decoder, &count);
    if (FAILED(hr) || count != 1) goto cleanup;
    hr = IWICBitmapDecoder_GetFrame(decoder, 0, &frame);
    if (FAILED(hr)) goto cleanup;
    hr = IWICBitmapFrameDecode_GetSize(frame, &actual_width, &actual_height);
    if (FAILED(hr) || actual_width != width || actual_height != height) goto cleanup;
    hr = IWICImagingFactory_CreateFormatConverter(factory, &converter);
    if (FAILED(hr)) goto cleanup;
    hr = IWICFormatConverter_Initialize(converter, (IWICBitmapSource *)frame,
        &GUID_WICPixelFormat32bppRGBA, WICBitmapDitherTypeNone, NULL, 0,
        WICBitmapPaletteTypeCustom);
    if (FAILED(hr)) goto cleanup;
    pixels = malloc(bytes);
    if (!pixels) goto cleanup;
    hr = IWICFormatConverter_CopyPixels(converter, NULL, stride, bytes, pixels);
    if (FAILED(hr)) goto cleanup;
    *decoded_bytes = bytes;
cleanup:
    if (converter) IWICFormatConverter_Release(converter);
    if (frame) IWICBitmapFrameDecode_Release(frame);
    if (decoder) IWICBitmapDecoder_Release(decoder);
    if (stream) IWICStream_Release(stream);
    if (factory) IWICImagingFactory_Release(factory);
    if (com) CoUninitialize();
    free(input);
    if (!*decoded_bytes) {
        free(pixels);
        pixels = NULL;
        fprintf(stderr, "WebP asset rejected or local WIC codec unavailable (HRESULT 0x%08lx).\n",
            (unsigned long)(uint32_t)hr);
    }
    return pixels;
}

uint8_t *pet_demo_load_webp(const wchar_t *path, unsigned version,
    pet_demo_validate_fn validate, size_t *decoded_bytes) {
    if (decoded_bytes) *decoded_bytes = 0;
    if (version != 1 && version != 2) return NULL;
    return decode_static(path, NULL, version, 1536, version == 1 ? 1872 : 2288,
        MAX_COMPRESSED, validate, decoded_bytes);
}

uint8_t *pet_demo_load_activity(const wchar_t *path, unsigned frames,
    pet_demo_validate_fn validate, size_t *decoded_bytes) {
    if (decoded_bytes) *decoded_bytes = 0;
    if (frames < 4 || frames > 32) return NULL;
    return decode_static(path, NULL, frames, PET_FRAME_WIDTH * frames, PET_FRAME_HEIGHT,
        2u * 1024u * 1024u, validate, decoded_bytes);
}

uint8_t *pet_package_load_atlas(const pet_package *package,
    pet_demo_validate_fn validate, size_t *decoded_bytes) {
    if (decoded_bytes) *decoded_bytes = 0;
    if (!package || !package->atlas || (package->meta.version != 1 && package->meta.version != 2)) return NULL;
    unsigned version = package->meta.version;
    return decode_static(NULL, package->atlas, version, 1536,
        version == 1 ? 1872 : 2288, MAX_COMPRESSED, validate, decoded_bytes);
}

uint8_t *pet_package_load_activity(const pet_package *package, unsigned index,
    pet_demo_validate_fn validate, size_t *decoded_bytes) {
    if (decoded_bytes) *decoded_bytes = 0;
    if (!package || index >= PET_PACKAGE_MAX || index >= package->meta.count || !package->files[index]) return NULL;
    unsigned frames = package->meta.items[index].frames;
    if (frames < 4 || frames > 32) return NULL;
    return decode_static(NULL, package->files[index], frames, PET_FRAME_WIDTH * frames,
        PET_FRAME_HEIGHT, 2u * 1024u * 1024u, validate, decoded_bytes);
}
