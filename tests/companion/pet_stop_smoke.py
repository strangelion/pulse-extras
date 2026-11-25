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
        result = subprocess.run(
            [sys.argv[1], "--smoke", "--stop-handle", str(handle)],
            startupinfo=startup,
            close_fds=True,
            check=True,
            timeout=10,
            capture_output=True,
        )
        assert b"Companion native: ipc=0 registry=0 menus=0 argv=0 peaks=1/0/0/1" in result.stderr, result.stderr
        # Duplicate inherited handle arguments are invalid but close only once.
        duplicate = subprocess.run(
            [sys.argv[1], "--smoke", "--stop-handle", str(handle),
             "--state-map", str(handle), "--state-event", str(handle)],
            startupinfo=startup, close_fds=True, timeout=10, capture_output=True,
        )
        assert duplicate.returncode != 0, duplicate.stderr
        assert b"Companion native: ipc=0 registry=0 menus=0 argv=0 peaks=1/0/0/1" in duplicate.stderr, duplicate.stderr
        assert b"cleanup_failures=0" in duplicate.stderr, duplicate.stderr
    
    finally:
        kernel.CloseHandle(handle)


if __name__ == "__main__":
    main()
