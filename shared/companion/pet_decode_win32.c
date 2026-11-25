#define COBJMACROS
#include "pet_demo_win32.h"
#include <wincodec.h>
#include <stdlib.h>
#include <stdio.h>
#include <wchar.h>
#include <string.h>
#ifdef PULSE_PET_LIBWEBP
#include "src/webp/decode.h"
#include "pet_webp_budget.h"
int pet_webp_budget_begin(pet_webp_budget *budget);
int pet_webp_budget_end(void);
static SRWLOCK webp_decode_lock = SRWLOCK_INIT;
#endif

#define MAX_COMPRESSED (16u * 1024u * 1024u)

static uint8_t *read_handle(const pet_memory *memory, HANDLE file, DWORD limit, DWORD *length) {
    *length = 0;
    uint8_t *data = NULL;
    BY_HANDLE_FILE_INFORMATION info;
    LARGE_INTEGER zero = {0};
    if (!file || file == INVALID_HANDLE_VALUE || GetFileType(file) != FILE_TYPE_DISK ||
        !GetFileInformationByHandle(file, &info) ||
        (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
        info.nFileSizeHigh || !info.nFileSizeLow || info.nFileSizeLow > limit ||
        !SetFilePointerEx(file, zero, NULL, FILE_BEGIN)) return NULL;
    data = pet_alloc(memory, info.nFileSizeLow);
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
    if (!*length) { pet_free(memory, data, info.nFileSizeLow); data = NULL; }
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

static HANDLE tracked_open(const pet_memory *memory, const wchar_t *path, DWORD access, DWORD flags) {
    const pet_resources *r = memory->resource_bridge;
    if (!pet_reserve(r, PET_RESOURCE_FILE, 1)) {
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        return INVALID_HANDLE_VALUE;
    }
    HANDLE file = CreateFileW(path, access, FILE_SHARE_READ, NULL, OPEN_EXISTING, flags, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        DWORD error = GetLastError();
        pet_release(r, PET_RESOURCE_FILE, 1);
        SetLastError(error);
    }
    return file;
}

static void tracked_close(const pet_memory *memory, HANDLE file) {
    if (CloseHandle(file)) pet_release(memory->resource_bridge, PET_RESOURCE_FILE, 1);
    else pet_cleanup_failed(memory->resource_bridge, PET_RESOURCE_FILE);
}

static uint8_t *read_local(const pet_memory *memory, const wchar_t *path, DWORD limit, DWORD *length) {
    *length = 0;
    HANDLE file = tracked_open(memory, path, GENERIC_READ,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN);
    if (file == INVALID_HANDLE_VALUE) return NULL;
    wchar_t resolved[32768];
    uint8_t *data = fixed_path(file, resolved, 32768) ? read_handle(memory, file, limit, length) : NULL;
    tracked_close(memory, file);
    return data;
}

/* Canonical local paths with pinned handles, not a race-free directory walk. */
static HANDLE package_handle(const pet_memory *memory, const wchar_t *path, BOOL directory) {
    HANDLE file = tracked_open(memory, path, directory ? FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES : GENERIC_READ,
        FILE_FLAG_OPEN_REPARSE_POINT | (directory ? FILE_FLAG_BACKUP_SEMANTICS : FILE_FLAG_SEQUENTIAL_SCAN));
    if (file == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "Package handle: open failed (Win32 %lu).\n", (unsigned long)GetLastError());
        return NULL;
    }
    BY_HANDLE_FILE_INFORMATION info;
    wchar_t resolved[1024];
    if (!GetFileInformationByHandle(file, &info) ||
        (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
        (!!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != !!directory) ||
        (!directory && info.nNumberOfLinks != 1)) {
        fputs("Package handle: unsafe file attributes or link count.\n", stderr);
        tracked_close(memory, file);
        return NULL;
    }
    if (!fixed_path(file, resolved, 1024)) {
        fputs("Package handle: not a normalized fixed-drive path.\n", stderr);
        tracked_close(memory, file);
        return NULL;
    }
    if (CompareStringOrdinal(resolved, -1, path, -1, TRUE) != CSTR_EQUAL) {
        fputs("Package handle: normalized path mismatch.\n", stderr);
        tracked_close(memory, file);
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

void pet_package_close(const pet_memory *memory, pet_package *package) {
    if (!package) return;
    for (unsigned i = 0; i < PET_PACKAGE_MAX; ++i) {
        if (package->outfit_files[i]) tracked_close(memory, package->outfit_files[i]);
        for (unsigned j = 0; j < PET_OUTFIT_SLOTS; ++j)
            if (package->files[i][j]) tracked_close(memory, package->files[i][j]);
    }
    if (package->wardrobe) tracked_close(memory, package->wardrobe);
    if (package->atlas) tracked_close(memory, package->atlas);
    if (package->activities) tracked_close(memory, package->activities);
    if (package->root) tracked_close(memory, package->root);
    ZeroMemory(package, sizeof(*package));
}

typedef struct {
    const uint8_t *leaf;
    HANDLE *handle;
} inventory_file;

/* Exact case-sensitive inventory of one declared flat directory. Each
 * successful open remains owned by the package, including partial failure. */
static BOOL pin_inventory(const pet_memory *memory, const wchar_t *root, const wchar_t *directory,
    HANDLE *dir_handle, inventory_file *files, unsigned count) {
    wchar_t folder[1024], path[1024], leaf[80];
    if (!join_path(folder, 1024, root, directory)) return FALSE;
    DWORD attr = GetFileAttributesW(folder);
    if (attr == INVALID_FILE_ATTRIBUTES)
        return !count && GetLastError() == ERROR_FILE_NOT_FOUND;
    *dir_handle = package_handle(memory, folder, TRUE);
    if (!*dir_handle || !join_path(path, 1024, folder, L"*")) return FALSE;
    WIN32_FIND_DATAW found;
    if (!pet_reserve(memory->resource_bridge, PET_RESOURCE_FILE, 1)) return FALSE;
    HANDLE enumeration = FindFirstFileW(path, &found);
    if (enumeration == INVALID_HANDLE_VALUE) {
        DWORD error = GetLastError();
        pet_release(memory->resource_bridge, PET_RESOURCE_FILE, 1);
        return !count && error == ERROR_FILE_NOT_FOUND;
    }
    BOOL ok = FALSE;
    unsigned seen = 0;
    do {
        if (wcscmp(found.cFileName, L".") == 0 || wcscmp(found.cFileName, L"..") == 0) continue;
        if (found.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) goto cleanup;
        unsigned i = 0;
        for (; i < count; ++i) {
            if (!leaf_wide(files[i].leaf, leaf, 80)) goto cleanup;
            if (wcscmp(found.cFileName, leaf) == 0) break;
        }
        if (i == count || *files[i].handle || !join_path(path, 1024, folder, leaf) ||
            !(*files[i].handle = package_handle(memory, path, FALSE))) goto cleanup;
        ++seen;
    } while (FindNextFileW(enumeration, &found));
    ok = GetLastError() == ERROR_NO_MORE_FILES && seen == count;
cleanup:
    if (FindClose(enumeration)) pet_release(memory->resource_bridge, PET_RESOURCE_FILE, 1);
    else { pet_cleanup_failed(memory->resource_bridge, PET_RESOURCE_FILE); ok = FALSE; }
    return ok;
}

/* Hash the validated bytes already read from the pinned handle, without
 * another file read or allocating another compressed image buffer. */
static BOOL hash_file(pet_fingerprint_file *files, size_t *count, pet_hash_fn hash,
    const char *prefix, const char *leaf, const uint8_t *data, DWORD length) {
    if (!hash) return TRUE;
    if (*count >= PET_FINGERPRINT_MAX_FILES) return FALSE;
    pet_fingerprint_file *file = &files[*count];
    int n = snprintf((char *)file->path, sizeof(file->path), "%s%s", prefix, leaf);
    if (n <= 0 || (size_t)n >= sizeof(file->path)) return FALSE;
    file->size = length;
    hash(data, length, file->digest);
    ++*count;
    return TRUE;
}

BOOL pet_package_open(const pet_memory *memory, pet_package *package, const wchar_t *folder,
    const wchar_t *id, pet_package_parse_fn parse,
    pet_demo_validate_fn validate, pet_demo_validate_fn validate_activity,
    pet_hash_fn hash, pet_fingerprint_fn fingerprint, uint8_t *digest) {
    if (!package || package->root || !folder || !id || !parse || !validate || !validate_activity ||
        (digest && (!hash || !fingerprint))) return FALSE;
    if (!digest) hash = NULL;
    pet_fingerprint_file hashes[PET_FINGERPRINT_MAX_FILES];
    size_t hash_count = 0;
    wchar_t root[1024] = L"\\\\?\\";
    wchar_t path[1024], full[1020];
    DWORD n = GetFullPathNameW(folder, 1020, full, NULL);
    if (n < 4 || n >= 1020 || full[1] != L':' || full[2] != L'\\') {
        fputs("Package path: expected a bounded local DOS directory.\n", stderr);
        return FALSE;
    }
    /* GetFullPathName does not expand 8.3 aliases (common in TEMP).
     * Expand spelling before the strict normalized handle comparison.
     * GetLongPathName does not replace final reparse-point inspection. */
    n = GetLongPathNameW(full, root + 4, 1020);
    if (n < 4 || n >= 1020 || root[5] != L':' || root[6] != L'\\') {
        fputs("Package path: long-name normalization failed.\n", stderr);
        return FALSE;
    }
    while (n > 3 && root[n + 3] == L'\\') root[--n + 4] = 0;
    if (n <= 3) return FALSE;
    uint8_t id8[64];
    size_t id_len = wcslen(id);
    if (!id_len || id_len > sizeof(id8)) return FALSE;
    for (size_t i = 0; i < id_len; ++i) {
        if (id[i] > 127) return FALSE;
        id8[i] = (uint8_t)id[i];
    }
    uint8_t *data = NULL;
    HANDLE metadata = NULL;
    DWORD length = 0;
    BOOL ok = FALSE;
    const char *stage = "root";
    package->root = package_handle(memory, root, TRUE);
    if (!package->root) goto cleanup;
    stage = "metadata-open";
    if (!join_path(path, 1024, root, L"pet.json") ||
        !(metadata = package_handle(memory, path, FALSE))) goto cleanup;
    stage = "metadata-read";
    data = read_handle(memory, metadata, 128u * 1024u, &length);
    if (!data) goto cleanup;
    stage = "metadata-parse";
    if (parse(memory, data, length, id8, id_len, &package->meta) ||
        package->meta.count > PET_PACKAGE_MAX || package->meta.outfit_count > PET_PACKAGE_MAX || package->meta.rule_count > 32 ||
        (package->meta.version != 1 && package->meta.version != 2)) goto cleanup;
    if (!hash_file(hashes, &hash_count, hash, "", "pet.json", data, length)) goto cleanup;
    pet_free(memory, data, length); data = NULL;
    stage = "base-open";
    if (!join_path(path, 1024, root, L"spritesheet.webp") ||
        !(package->atlas = package_handle(memory, path, FALSE))) goto cleanup;
    stage = "base-read";
    data = read_handle(memory, package->atlas, MAX_COMPRESSED, &length);
    if (!data) goto cleanup;
    stage = "base-header";
    if (validate(package->meta.version, data, length)) goto cleanup;
    if (!hash_file(hashes, &hash_count, hash, "", "spritesheet.webp", data, length)) goto cleanup;
    pet_free(memory, data, length); data = NULL;
    inventory_file files[PET_PACKAGE_MAX * PET_OUTFIT_SLOTS];
    unsigned count = 0;
    for (unsigned i = 0; i < package->meta.outfit_count; ++i)
        files[count++] = (inventory_file){package->meta.outfits[i].leaf, &package->outfit_files[i]};
    stage = "outfit-inventory";
    if (!pin_inventory(memory, root, L"outfits", &package->wardrobe, files, count)) goto cleanup;
    for (unsigned i = 0; i < count; ++i) {
        stage = "outfit-read";
        data = read_handle(memory, package->outfit_files[i], MAX_COMPRESSED, &length);
        if (!data) goto cleanup;
        stage = "outfit-header";
        if (validate(package->meta.version, data, length)) goto cleanup;
        if (!hash_file(hashes, &hash_count, hash, "outfits/", (const char *)package->meta.outfits[i].leaf, data, length)) goto cleanup;
        pet_free(memory, data, length); data = NULL;
    }
    count = 0;
    for (unsigned i = 0; i < package->meta.count; ++i)
        for (unsigned j = 0; j <= package->meta.outfit_count; ++j) {
            const pet_package_rep *rep = &package->meta.items[i].reps[j];
            if (rep->frames)
                files[count++] = (inventory_file){rep->leaf, &package->files[i][j]};
        }
    stage = "activity-inventory";
    if (!pin_inventory(memory, root, L"activities", &package->activities, files, count)) goto cleanup;
    size_t total = 0;
    for (unsigned i = 0; i < package->meta.count; ++i)
        for (unsigned j = 0; j <= package->meta.outfit_count; ++j) {
            const pet_package_rep *rep = &package->meta.items[i].reps[j];
            if (!rep->frames) continue;
            stage = "activity-read";
            data = read_handle(memory, package->files[i][j], 2u * 1024u * 1024u, &length);
            if (!data) goto cleanup;
            stage = "activity-size";
            if (length > 16u * 1024u * 1024u - total) goto cleanup;
            stage = "activity-header";
            if (validate_activity(rep->frames, data, length)) goto cleanup;
            total += length;
            if (!hash_file(hashes, &hash_count, hash, "activities/", (const char *)rep->leaf, data, length)) goto cleanup;
            pet_free(memory, data, length); data = NULL;
        }
    stage = "fingerprint";
    if (digest && fingerprint(hashes, hash_count, digest)) goto cleanup;
    ok = TRUE;
cleanup:
    if (metadata) tracked_close(memory, metadata);
    pet_free(memory, data, length);
    if (!ok) {
        fprintf(stderr, "Package admission failed at %s.\n", stage);
        pet_package_close(memory, package);
    }
    return ok;
}

static uint8_t *decode_static(const pet_memory *memory, const wchar_t *path, HANDLE pinned, unsigned kind,
    UINT width, UINT height, DWORD limit, pet_demo_validate_fn validate,
    size_t *decoded_bytes) {
    if (!decoded_bytes) return NULL;
    *decoded_bytes = 0;
    if ((!path && !pinned) || !validate) return NULL;
    if (!pet_reserve(memory->resource_bridge, PET_RESOURCE_CODEC, 1)) return NULL;
    const UINT stride = width * 4, bytes = stride * height;
    DWORD length = 0;
    uint8_t *input = pinned ? read_handle(memory, pinned, limit, &length) : read_local(memory, path, limit, &length);
    uint8_t *pixels = NULL;
#ifdef PULSE_PET_LIBWEBP
    const char *stage = "read-input";
    int width_actual = 0, height_actual = 0;
    if (!input) goto portable_cleanup;
    stage = "preflight";
    if (validate(kind, input, length)) goto portable_cleanup;
    stage = "libwebp-version";
    if (WebPGetDecoderVersion() != 0x010600) goto portable_cleanup;
    stage = "libwebp-header";
    if (!WebPGetInfo(input, length, &width_actual, &height_actual) ||
        width_actual != (int)width || height_actual != (int)height) goto portable_cleanup;
    stage = "pixel-allocation";
    pixels = pet_alloc(memory, bytes);
    if (!pixels) goto portable_cleanup;
    stage = "libwebp-decode";
    pet_webp_budget budget = {memory->context, memory->allocate, memory->release, 0};
    AcquireSRWLockExclusive(&webp_decode_lock);
    if (!pet_webp_budget_begin(&budget)) {
        ReleaseSRWLockExclusive(&webp_decode_lock);
        stage = "libwebp-budget-scope";
        goto portable_cleanup;
    }
    uint8_t *decoded = WebPDecodeRGBAInto(input, length, pixels, bytes, (int)stride);
    int drained = pet_webp_budget_end();
    ReleaseSRWLockExclusive(&webp_decode_lock);
    if (!drained) {
        stage = "libwebp-budget-not-drained";
        goto portable_cleanup;
    }
    if (decoded != pixels) goto portable_cleanup;
    *decoded_bytes = bytes;
portable_cleanup:
    pet_free(memory, input, length);
    pet_release(memory->resource_bridge, PET_RESOURCE_CODEC, 1);
    if (!*decoded_bytes) {
        pet_free(memory, pixels, bytes);
        pixels = NULL;
        fprintf(stderr, "WebP static decoder rejected asset (stage=%s).\n", stage);
    }
    return pixels;
#else
    IWICImagingFactory *factory = NULL;
    IWICStream *stream = NULL;
    IWICBitmapDecoder *decoder = NULL;
    IWICBitmapFrameDecode *frame = NULL;
    IWICFormatConverter *converter = NULL;
    int com = 0;
    HRESULT hr = E_FAIL;
    const char *stage = "read-input";
    UINT count = 0, actual_width = 0, actual_height = 0;
    if (!input) goto cleanup;
    stage = "preflight";
    if (validate(kind, input, length)) { hr = E_INVALIDARG; goto cleanup; }
    stage = "com-initialize";
    hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (FAILED(hr)) goto cleanup;
    com = 1;
    stage = "wic-factory";
    hr = CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER,
        &IID_IWICImagingFactory, (void **)&factory);
    if (FAILED(hr)) goto cleanup;
    stage = "wic-stream";
    hr = IWICImagingFactory_CreateStream(factory, &stream);
    if (FAILED(hr)) goto cleanup;
    stage = "wic-stream-input";
    hr = IWICStream_InitializeFromMemory(stream, input, length);
    if (FAILED(hr)) goto cleanup;
    stage = "wic-decoder";
    hr = IWICImagingFactory_CreateDecoderFromStream(factory, (IStream *)stream,
        NULL, WICDecodeMetadataCacheOnDemand, &decoder);
    if (FAILED(hr)) goto cleanup;
    stage = "wic-frame-count";
    hr = IWICBitmapDecoder_GetFrameCount(decoder, &count);
    if (FAILED(hr)) goto cleanup;
    if (count != 1) { hr = E_INVALIDARG; goto cleanup; }
    stage = "wic-frame";
    hr = IWICBitmapDecoder_GetFrame(decoder, 0, &frame);
    if (FAILED(hr)) goto cleanup;
    stage = "wic-size";
    hr = IWICBitmapFrameDecode_GetSize(frame, &actual_width, &actual_height);
    if (FAILED(hr)) goto cleanup;
    if (actual_width != width || actual_height != height) { hr = E_INVALIDARG; goto cleanup; }
    stage = "wic-converter";
    hr = IWICImagingFactory_CreateFormatConverter(factory, &converter);
    if (FAILED(hr)) goto cleanup;
    stage = "wic-converter-init";
    hr = IWICFormatConverter_Initialize(converter, (IWICBitmapSource *)frame,
        &GUID_WICPixelFormat32bppRGBA, WICBitmapDitherTypeNone, NULL, 0,
        WICBitmapPaletteTypeCustom);
    if (FAILED(hr)) goto cleanup;
    stage = "pixel-allocation";
    pixels = pet_alloc(memory, bytes);
    if (!pixels) { hr = E_OUTOFMEMORY; goto cleanup; }
    stage = "wic-copy-pixels";
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
    pet_release(memory->resource_bridge, PET_RESOURCE_CODEC, 1);
    pet_free(memory, input, length);
    if (!*decoded_bytes) {
        pet_free(memory, pixels, bytes);
        pixels = NULL;
        fprintf(stderr, "WebP asset rejected or local WIC codec unavailable (stage=%s HRESULT 0x%08lx).\n",
            stage, (unsigned long)(uint32_t)hr);
    }
    return pixels;
#endif
}

uint8_t *pet_demo_load_webp(const pet_memory *memory, const wchar_t *path, unsigned version,
    pet_demo_validate_fn validate, size_t *decoded_bytes) {
    if (decoded_bytes) *decoded_bytes = 0;
    if (version != 1 && version != 2) return NULL;
    return decode_static(memory, path, NULL, version, 1536, version == 1 ? 1872 : 2288,
        MAX_COMPRESSED, validate, decoded_bytes);
}

uint8_t *pet_demo_load_activity(const pet_memory *memory, const wchar_t *path, unsigned frames,
    pet_demo_validate_fn validate, size_t *decoded_bytes) {
    if (decoded_bytes) *decoded_bytes = 0;
    if (frames < 4 || frames > 32) return NULL;
    return decode_static(memory, path, NULL, frames, PET_FRAME_WIDTH * frames, PET_FRAME_HEIGHT,
        2u * 1024u * 1024u, validate, decoded_bytes);
}

uint8_t *pet_package_load_atlas(const pet_memory *memory, const pet_package *package, unsigned outfit,
    pet_demo_validate_fn validate, size_t *decoded_bytes) {
    if (decoded_bytes) *decoded_bytes = 0;
    if (!package || outfit > PET_PACKAGE_MAX || outfit > package->meta.outfit_count ||
        (package->meta.version != 1 && package->meta.version != 2)) return NULL;
    HANDLE file = outfit ? package->outfit_files[outfit - 1] : package->atlas;
    if (!file) return NULL;
    unsigned version = package->meta.version;
    return decode_static(memory, NULL, file, version, 1536,
        version == 1 ? 1872 : 2288, MAX_COMPRESSED, validate, decoded_bytes);
}

uint8_t *pet_package_load_activity(const pet_memory *memory, const pet_package *package, unsigned index, unsigned outfit,
    pet_demo_validate_fn validate, size_t *decoded_bytes) {
    if (decoded_bytes) *decoded_bytes = 0;
    if (!package || index >= PET_PACKAGE_MAX || index >= package->meta.count ||
        outfit >= PET_OUTFIT_SLOTS || outfit > package->meta.outfit_count || !package->files[index][outfit]) return NULL;
    unsigned frames = package->meta.items[index].reps[outfit].frames;
    if (frames < 4 || frames > 32) return NULL;
    return decode_static(memory, NULL, package->files[index][outfit], frames, PET_FRAME_WIDTH * frames,
        PET_FRAME_HEIGHT, 2u * 1024u * 1024u, validate, decoded_bytes);
}
