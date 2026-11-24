"""Real-host acceptance harness for Pulse native extensions.

This script drives a *test instance* of the installed Pulse host against an
already installed extension package and exercises the public command surface:

1. start ``pulse.exe --test-instance --extension-store <store>`` with an isolated
   ``LOCALAPPDATA`` and an isolated ``PULSE_TEST_DATA_DIR``;
2. wait for ``PulseMainWindow``;
3. select one row in the file list, then press the extension's command shortcut;
4. capture before/after screenshots and dump the probe log written by the DLL
   (the DLL honours the ``ABI_PROBE_LOG`` environment variable);
5. close the window and report the exit status.

The script never touches the user's daily profile: the host is started with a
throwaway ``LOCALAPPDATA`` directory, so the real extension store and settings
of the running instance are not modified.

Usage (Windows only, Python 3.10+)::

    python scripts/host_acceptance.py --store .local/store3 --out .local/acceptance

Exit code 0 means: the window appeared, the DLL entry point ran, the command was
registered and the shortcut produced an ``invoke`` line. Every other outcome is
reported as a failure with the observed evidence.
"""

from __future__ import annotations

import argparse
import contextlib
import ctypes
import ctypes.wintypes as wintypes
import json
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import time

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)

VK_CONTROL, VK_SHIFT, VK_F9, VK_ESCAPE = 0x11, 0x10, 0x78, 0x1B
INPUT_KEYBOARD = 1
KEYEVENTF_KEYUP = 0x0002
WM_CLOSE = 0x0010
WM_RBUTTONDOWN, WM_RBUTTONUP = 0x0008, 0x0010


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", wintypes.WORD),
        ("wScan", wintypes.WORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ctypes.c_size_t),
    ]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", wintypes.LONG),
        ("dy", wintypes.LONG),
        ("mouseData", wintypes.DWORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ctypes.c_size_t),
    ]


class INPUT(ctypes.Structure):
    class _Union(ctypes.Union):
        _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("padding", ctypes.c_byte * 32)]

    _anonymous_ = ("u",)
    _fields_ = [("type", wintypes.DWORD), ("u", _Union)]


def enable_dpi_awareness() -> None:
    """Match the host's per-monitor DPI so window rects and clicks agree."""
    with contextlib.suppress(AttributeError):
        user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))


def send_keys(keys: list[tuple[int, int]]) -> int:
    array = (INPUT * len(keys))()
    for index, (vk, flags) in enumerate(keys):
        array[index].type = INPUT_KEYBOARD
        array[index].ki = KEYBDINPUT(vk, 0, flags, 0, 0)
    sent = user32.SendInput(len(keys), array, ctypes.sizeof(INPUT))
    if sent != len(keys):
        raise OSError(ctypes.get_last_error(), "SendInput failed")
    return sent


def press(*vks: int) -> None:
    send_keys([(vk, 0) for vk in vks] + [(vk, KEYEVENTF_KEYUP) for vk in reversed(vks)])


def click(x: int, y: int, button: str = "left") -> None:
    user32.SetCursorPos(x, y)
    time.sleep(0.15)
    down, up = (0x0002, 0x0004) if button == "left" else (WM_RBUTTONDOWN, WM_RBUTTONUP)
    user32.mouse_event(down, 0, 0, 0, 0)
    time.sleep(0.08)
    user32.mouse_event(up, 0, 0, 0, 0)


def top_level_windows(pid: int) -> list[dict]:
    found: list[int] = []

    def collect(hwnd, _param):
        found.append(hwnd)
        return True

    callback = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)(collect)
    user32.EnumWindows(callback, 0)
    result = []
    for hwnd in found:
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value != pid:
            continue
        rect = wintypes.RECT()
        user32.GetWindowRect(hwnd, ctypes.byref(rect))
        class_name = ctypes.create_unicode_buffer(256)
        user32.GetClassNameW(hwnd, class_name, 256)
        title = ctypes.create_unicode_buffer(256)
        user32.GetWindowTextW(hwnd, title, 256)
        result.append(
            {
                "hwnd": hwnd,
                "class": class_name.value,
                "title": title.value,
                "visible": bool(user32.IsWindowVisible(hwnd)),
                "rect": (rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top),
            }
        )
    return result


def describe(hwnd: int) -> str:
    class_name = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, class_name, 256)
    return f"{hwnd}:{class_name.value}"


def force_foreground(hwnd: int) -> bool:
    user32.ShowWindow(hwnd, 9)
    thread = user32.GetWindowThreadProcessId(hwnd, None)
    current = kernel32.GetCurrentThreadId()
    user32.AttachThreadInput(current, thread, True)
    user32.BringWindowToTop(hwnd)
    user32.SetForegroundWindow(hwnd)
    user32.AttachThreadInput(current, thread, False)
    if user32.GetForegroundWindow() != hwnd:
        # A synthetic ALT press releases the Windows foreground lock.
        send_keys([(0x12, 0), (0x12, KEYEVENTF_KEYUP)])
        user32.SwitchToThisWindow(hwnd, True)
        user32.SetForegroundWindow(hwnd)
    return user32.GetForegroundWindow() == hwnd


def capture(hwnd: int, path: pathlib.Path) -> bool:
    """Capture the window with BitBlt (composition-safe) and store a 32-bit BMP."""
    rect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    width, height = rect.right - rect.left, rect.bottom - rect.top
    if width <= 0 or height <= 0:
        return False
    screen = user32.GetDC(None)
    memory = gdi32.CreateCompatibleDC(screen)
    bitmap = gdi32.CreateCompatibleBitmap(screen, width, height)
    try:
        gdi32.SelectObject(memory, bitmap)
        if not gdi32.BitBlt(memory, 0, 0, width, height, screen, rect.left, rect.top, 0x00CC0020):
            return False
        pixels = ctypes.create_string_buffer(width * height * 4)
        header = struct.pack("<IiiHHIIiiII", 40, width, -height, 1, 32, 0, len(pixels), 0, 0, 0, 0)
        if gdi32.GetDIBits(memory, bitmap, 0, height, pixels, header, 0) != height:
            return False
        path.write_bytes(header + pixels.raw)
        return True
    finally:
        gdi32.DeleteObject(bitmap)
        gdi32.DeleteDC(memory)
        user32.ReleaseDC(None, screen)


def find_pulse_executable() -> pathlib.Path:
    root = pathlib.Path(os.environ.get("ProgramFiles", os.environ.get("PROGRAMFILES", r"C:\Program Files"))) / "Pulse" / "DialogBridge"
    candidates = sorted(root.glob("*/pulse.exe"), key=lambda item: item.stat().st_mtime, reverse=True)
    if not candidates:
        raise SystemExit(f"no Pulse executable found under {root}")
    return candidates[0]


def read_log(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pulse", type=pathlib.Path, default=None, help="pulse.exe (test binary)")
    parser.add_argument("--store", type=pathlib.Path, required=True, help="isolated extension store")
    parser.add_argument("--out", type=pathlib.Path, default=pathlib.Path(".local/acceptance"))
    parser.add_argument("--sidebar", default="0.067,0.434",
                        help="sidebar entry to open first (Downloads) as fractions; empty to skip")
    parser.add_argument("--row", default="0.31,0.69", help="list row position as fractions of the window")
    parser.add_argument("--wait", type=float, default=30.0, help="seconds to wait for the window")
    args = parser.parse_args()

    if sys.platform != "win32":
        raise SystemExit("host acceptance currently requires Windows")

    enable_dpi_awareness()
    pulse = args.pulse or find_pulse_executable()
    store = args.store.resolve()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    profile = out / "localappdata"
    data = out / "test-data"
    for path in (profile, data):
        with contextlib.suppress(OSError):
            shutil.rmtree(path)
        path.mkdir(parents=True, exist_ok=True)
    log = out / "probe.log"
    log.unlink(missing_ok=True)

    environment = {key: value for key, value in os.environ.items() if not key.upper().startswith("PULSE_")}
    environment["LOCALAPPDATA"] = str(profile)
    environment["PULSE_TEST_DATA_DIR"] = str(data)
    environment["ABI_PROBE_LOG"] = str(log)

    report: dict = {"pulse": str(pulse), "store": str(store), "steps": []}
    process = subprocess.Popen(
        [str(pulse), "--test-instance", "--extension-store", str(store)],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    report["pid"] = process.pid

    hwnd = None
    deadline = time.time() + args.wait
    while time.time() < deadline and process.poll() is None:
        time.sleep(0.25)
        for entry in top_level_windows(process.pid):
            if entry["class"] == "PulseMainWindow" and entry["visible"]:
                hwnd = entry["hwnd"]
                break
        if hwnd:
            break
    report["window"] = hwnd
    report["windows"] = top_level_windows(process.pid)

    if not hwnd:
        stdout, stderr = process.communicate(timeout=10)
        report["exit"] = process.returncode
        report["stdout"] = stdout.decode("utf-8", "replace")[:2000]
        report["stderr"] = stderr.decode("utf-8", "replace")[:2000]
        (out / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(json.dumps(report, indent=2))
        return 1

    rect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    width, height = rect.right - rect.left, rect.bottom - rect.top
    report["window_rect"] = [rect.left, rect.top, width, height]
    report["foreground"] = force_foreground(hwnd)
    time.sleep(0.8)
    capture(hwnd, out / "01-launch.bmp")
    report["log_after_launch"] = read_log(log)

    if args.sidebar:
        side_x, side_y = (float(value) for value in args.sidebar.split(","))
        click(rect.left + int(width * side_x), rect.top + int(height * side_y))
        time.sleep(1.5)
        capture(hwnd, out / "02-folder.bmp")

    row_x, row_y = (float(value) for value in args.row.split(","))
    click(rect.left + int(width * row_x), rect.top + int(height * row_y))
    time.sleep(1.0)
    capture(hwnd, out / "03-selection.bmp")

    press(VK_CONTROL, VK_SHIFT, VK_F9)
    time.sleep(2.0)
    capture(hwnd, out / "04-invoked.bmp")
    report["log_after_shortcut"] = read_log(log)

    click(rect.left + int(width * row_x), rect.top + int(height * row_y), "right")
    time.sleep(1.5)
    capture(hwnd, out / "05-context-menu.bmp")
    press(VK_ESCAPE)
    time.sleep(0.3)

    user32.PostMessageW(hwnd, WM_CLOSE, 0, 0)
    try:
        stdout, stderr = process.communicate(timeout=25)
    except subprocess.TimeoutExpired:
        process.terminate()
        stdout, stderr = process.communicate(timeout=10)
    report["exit"] = process.returncode
    report["stdout"] = stdout.decode("utf-8", "replace")[:2000]
    report["stderr"] = stderr.decode("utf-8", "replace")[:2000]
    report["log_final"] = read_log(log)

    entry_ran = "entry" in report["log_final"]
    registered = "query register=0" in report["log_final"]
    invoked = "invoke " in report["log_final"]
    report["evidence"] = {"entry": entry_ran, "registered": registered, "invoked": invoked}
    (out / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps({key: report[key] for key in ("pid", "window_rect", "foreground", "exit", "evidence")}, indent=2))
    print("probe log:\n" + report["log_final"])
    return 0 if entry_ran and registered and invoked else 1


if __name__ == "__main__":
    raise SystemExit(main())
