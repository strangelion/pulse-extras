#define COBJMACROS
#include "pet_demo_win32.h"
#include <wincodec.h>
#include <stdlib.h>
#include <stdio.h>

#define MAX_COMPRESSED (16u * 1024u * 1024u)

static uint8_t *read_local(const wchar_t *path, DWORD limit, DWORD *length) {
    *length = 0;
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL,
        OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (file == INVALID_HANDLE_VALUE) return NULL;
    uint8_t *data = NULL;
    BY_HANDLE_FILE_INFORMATION info;
    if (GetFileType(file) != FILE_TYPE_DISK ||
        !GetFileInformationByHandle(file, &info) ||
        (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
        info.nFileSizeHigh || !info.nFileSizeLow || info.nFileSizeLow > limit)
        goto cleanup;
    /* Reject remote/network/removable paths using the opened handle. This
     * is asset preflight, not a credential-directory trust policy. */
    wchar_t resolved[32768];
    DWORD n = GetFinalPathNameByHandleW(file, resolved, 32768, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (n < 7 || n >= 32768 || resolved[0] != L'\\' || resolved[1] != L'\\' ||
        resolved[2] != L'?' || resolved[3] != L'\\' || resolved[5] != L':' ||
        resolved[6] != L'\\') goto cleanup;
    wchar_t root[] = {resolved[4], L':', L'\\', L'\0'};
    if (GetDriveTypeW(root) != DRIVE_FIXED) goto cleanup;
    data = malloc(info.nFileSizeLow);
    if (!data) goto cleanup;
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
    CloseHandle(file);
    if (!*length) {
        free(data);
        data = NULL;
    }
    return data;
}

static uint8_t *decode_static(const wchar_t *path, unsigned kind,
    UINT width, UINT height, DWORD limit, pet_demo_validate_fn validate,
    size_t *decoded_bytes) {
    if (!decoded_bytes) return NULL;
    *decoded_bytes = 0;
    if (!path || !validate) return NULL;
    const UINT stride = width * 4, bytes = stride * height;
    DWORD length = 0;
    uint8_t *input = read_local(path, limit, &length);
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
    return decode_static(path, version, 1536, version == 1 ? 1872 : 2288,
        MAX_COMPRESSED, validate, decoded_bytes);
}

uint8_t *pet_demo_load_activity(const wchar_t *path, unsigned frames,
    pet_demo_validate_fn validate, size_t *decoded_bytes) {
    if (decoded_bytes) *decoded_bytes = 0;
    if (frames < 4 || frames > 32) return NULL;
    return decode_static(path, frames, PET_FRAME_WIDTH * frames, PET_FRAME_HEIGHT,
        2u * 1024u * 1024u, validate, decoded_bytes);
}
