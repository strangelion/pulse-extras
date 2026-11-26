#ifndef PULSE_IMAGE_WIN32_H
#define PULSE_IMAGE_WIN32_H
#include <windows.h>
#include <stdint.h>

/* A bounded pinned regular .exe handle. Not an ACL, ancestor identity,
 * dependency or publisher audit. Caller independently approves installation
 * and holds the handle through launch. No arbitrary PATH discovery. */
typedef enum { PULSE_IMAGE_OK, PULSE_IMAGE_OS_ERROR, PULSE_IMAGE_MISMATCH } pulse_image_result;
HANDLE pulse_image_pin(const wchar_t *path);
/* Reads from offset zero and leaves the file pointer at the end on success.
 * Caller owns the handle and must serialize access. */
pulse_image_result pulse_image_verify(HANDLE image, const uint8_t expected[32]);
#endif
