"""Windows-only: exercise inherited stop event with the standalone demo."""
import ctypes
from ctypes import wintypes
import subprocess
import sys

kernel = ctypes.WinDLL("kernel32", use_last_error=True)
kernel.CreateEventW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.BOOL, wintypes.LPCWSTR]
kernel.CreateEventW.restype = wintypes.HANDLE
kernel.SetEvent.argtypes = [wintypes.HANDLE]
kernel.SetEvent.restype = wintypes.BOOL
kernel.CloseHandle.argtypes = [wintypes.HANDLE]
kernel.CloseHandle.restype = wintypes.BOOL
kernel.SetHandleInformation.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD]
kernel.SetHandleInformation.restype = wintypes.BOOL


def main():
    handle = kernel.CreateEventW(None, True, True, None)
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        if not kernel.SetHandleInformation(handle, 1, 1):
            raise ctypes.WinError(ctypes.get_last_error())
        startup = subprocess.STARTUPINFO(lpAttributeList={"handle_list": [handle]})
        # Pre-signaled: the child must exit successfully before creating a window.
        subprocess.run(
            [sys.argv[1], "--smoke", "--stop-handle", str(handle)],
            startupinfo=startup,
            close_fds=True,
            check=True,
            timeout=10,
        )
    finally:
        kernel.CloseHandle(handle)


if __name__ == "__main__":
    main()
