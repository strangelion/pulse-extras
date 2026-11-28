
"""Exercise the real Share window on a private Win32 desktop with a scripted worker."""
import ctypes as ct
from ctypes import wintypes as w
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid


user = ct.WinDLL("user32", use_last_error=True)
kernel = ct.WinDLL("kernel32", use_last_error=True)
enum_window = ct.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)


class HighContrast(ct.Structure):
    _fields_ = [("size", w.UINT), ("flags", w.DWORD), ("scheme", w.LPWSTR)]


class Startup(ct.Structure):
    _fields_ = [
        ("cb", w.DWORD), ("reserved", w.LPWSTR), ("desktop", w.LPWSTR),
        ("title", w.LPWSTR), ("x", w.DWORD), ("y", w.DWORD),
        ("width", w.DWORD), ("height", w.DWORD), ("columns", w.DWORD),
        ("rows", w.DWORD), ("fill", w.DWORD), ("flags", w.DWORD),
        ("show", w.WORD), ("reserved_count", w.WORD), ("reserved_bytes", ct.c_void_p),
        ("stdin", w.HANDLE), ("stdout", w.HANDLE), ("stderr", w.HANDLE),
    ]


class Process(ct.Structure):
    _fields_ = [("process", w.HANDLE), ("thread", w.HANDLE), ("pid", w.DWORD), ("tid", w.DWORD)]


class Security(ct.Structure):
    _fields_ = [("size", w.DWORD), ("descriptor", ct.c_void_p), ("inherit", w.BOOL)]


def api(dll, name, result, *args):
    function = getattr(dll, name)
    function.restype, function.argtypes = result, args
    return function


process_dpi = api(user, "SetProcessDpiAwarenessContext", w.BOOL, ct.c_void_p)
system_parameters = api(user, "SystemParametersInfoW", w.BOOL, w.UINT, w.UINT, ct.c_void_p, w.UINT)
create_desktop = api(user, "CreateDesktopW", w.HANDLE, w.LPCWSTR, w.LPCWSTR,
                     ct.c_void_p, w.DWORD, w.DWORD, ct.c_void_p)
close_desktop = api(user, "CloseDesktop", w.BOOL, w.HANDLE)
thread_desktop = api(user, "GetThreadDesktop", w.HANDLE, w.DWORD)
set_desktop = api(user, "SetThreadDesktop", w.BOOL, w.HANDLE)
thread_id = api(kernel, "GetCurrentThreadId", w.DWORD)
desktop_windows = api(user, "EnumDesktopWindows", w.BOOL, w.HANDLE, enum_window, w.LPARAM)
children = api(user, "EnumChildWindows", w.BOOL, w.HWND, enum_window, w.LPARAM)
get_parent = api(user, "GetParent", w.HWND, w.HWND)
get_id = api(user, "GetDlgCtrlID", ct.c_int, w.HWND)
visible = api(user, "IsWindowVisible", w.BOOL, w.HWND)
style = api(user, "GetWindowLongW", ct.c_long, w.HWND, ct.c_int)
enabled = api(user, "IsWindowEnabled", w.BOOL, w.HWND)
class_name = api(user, "GetClassNameW", ct.c_int, w.HWND, w.LPWSTR, ct.c_int)
send = api(user, "SendMessageTimeoutW", w.LPARAM, w.HWND, w.UINT, w.WPARAM, w.LPARAM,
           w.UINT, w.UINT, ct.POINTER(ct.c_size_t))
post = api(user, "PostMessageW", w.BOOL, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
bounds = api(user, "GetWindowRect", w.BOOL, w.HWND, ct.POINTER(w.RECT))
dpi = api(user, "GetDpiForWindow", w.UINT, w.HWND)
resize = api(user, "SetWindowPos", w.BOOL, w.HWND, w.HWND, ct.c_int, ct.c_int,
             ct.c_int, ct.c_int, w.UINT)
create_process = api(kernel, "CreateProcessW", w.BOOL, w.LPCWSTR, w.LPWSTR, ct.c_void_p,
                     ct.c_void_p, w.BOOL, w.DWORD, ct.c_void_p, w.LPCWSTR,
                     ct.POINTER(Startup), ct.POINTER(Process))
close_handle = api(kernel, "CloseHandle", w.BOOL, w.HANDLE)
wait = api(kernel, "WaitForSingleObject", w.DWORD, w.HANDLE, w.DWORD)
terminate = api(kernel, "TerminateProcess", w.BOOL, w.HANDLE, w.UINT)
pipe = api(kernel, "CreatePipe", w.BOOL, ct.POINTER(w.HANDLE), ct.POINTER(w.HANDLE),
           ct.POINTER(Security), w.DWORD)
write = api(kernel, "WriteFile", w.BOOL, w.HANDLE, ct.c_void_p, w.DWORD,
            ct.POINTER(w.DWORD), ct.c_void_p)


def checked(result):
    if not result:
        raise ct.WinError(ct.get_last_error())
    return result


def get_windows(function, parent):
    result = []

    @enum_window
    def add(hwnd, _):
        result.append(hwnd)
        return True

    function(parent, add, 0)
    return result


def klass(hwnd):
    text = ct.create_unicode_buffer(96)
    class_name(hwnd, text, len(text))
    return text.value


def message(hwnd, kind, wp=0, lp=0):
    result = ct.c_size_t()
    checked(send(hwnd, kind, wp, lp, 2, 2000, ct.byref(result)))
    return result.value


def text_at(hwnd):
    text = ct.create_unicode_buffer(4096)
    message(hwnd, 0x000D, len(text), ct.addressof(text))
    return text.value


def eventually(condition, description, timeout=8):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = condition()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError(description)


class Window:
    def __init__(self, hwnd):
        self.hwnd = hwnd

    def resize(self, width, height):
        scale = dpi(self.hwnd) or 96
        checked(resize(self.hwnd, None, 0, 0, width * scale // 96, height * scale // 96,
                       0x0002 | 0x0004 | 0x0010))

    def select_tab(self, index):
        nav = next(h for h in get_windows(children, self.hwnd) if klass(h) == "SysTabControl32")
        area = rectangle(nav)
        w = area.right - area.left
        h = area.bottom - area.top
        point = (h // 3) << 16 | (w * (10 * index + 4) // 60)
        message(nav, 0x0201, 1, point)
        message(nav, 0x0202, 0, point)

    def labelled(self, text, control="Static"):
        for hwnd in get_windows(children, self.hwnd):
            if visible(hwnd) and klass(hwnd) == control and text_at(hwnd) == text:
                return hwnd
        raise AssertionError(f"visible control missing: {text}")

    def has_button(self, text):
        return any(visible(hwnd) and klass(hwnd) == "Button" and text_at(hwnd) == text
                   for hwnd in get_windows(children, self.hwnd))

    def next_control(self, label, kind):
        original = get_id(self.labelled(label))
        for hwnd in get_windows(children, self.hwnd):
            if get_id(hwnd) == original + 1 and klass(hwnd) == kind:
                return hwnd
        raise AssertionError(f"input missing: {label}")

    def type(self, label, value):
        hwnd = self.next_control(label, "Edit")
        content = ct.create_unicode_buffer(value)
        message(hwnd, 0x000C, 0, ct.addressof(content))

    def click(self, label):
        hwnd = self.labelled(label, "Button")
        eventually(lambda: enabled(hwnd), f"control stayed disabled: {label}")
        message(get_parent(hwnd), 0x0111, get_id(hwnd), hwnd)

    def notice(self):
        return next((hwnd for hwnd in get_windows(children, self.hwnd)
                     if visible(hwnd) and klass(hwnd) == "PulseShareNotice"), None)

    def messages(self):
        for hwnd in get_windows(children, self.hwnd):
            if not visible(hwnd):
                continue
            kind = klass(hwnd)
            # Windows deliberately rejects WM_GETTEXT for password controls.
            if kind == "Static" or (kind == "Edit" and not style(hwnd, -16) & 0x20):
                yield text_at(hwnd)

    def contains(self, value):
        return any(value in message for message in self.messages())


def rectangle(hwnd):
    result = w.RECT()
    checked(bounds(hwnd, ct.byref(result)))
    return result


def section_height(hwnd):
    box = rectangle(get_parent(hwnd))
    return box.bottom - box.top


def check_disclosure(panel, command, option, with_motion):
    assert not panel.has_button(option), "extra controls should start collapsed"
    child = next(hwnd for hwnd in get_windows(children, panel.hwnd)
                 if klass(hwnd) == "Button" and text_at(hwnd) == option)
    pane = get_parent(child)
    assert klass(pane) == "PulseSharePage" and not visible(child)
    panel.click(command)
    assert visible(child)
    if with_motion:
        # A clipped child pane grows during the transition. The controls keep
        # their natural height instead of being individually stretched.
        heights = [section_height(child)]
        end = time.monotonic() + 0.3
        while time.monotonic() < end:
            time.sleep(0.012)
            heights.append(section_height(child))
        assert len(set(heights)) >= 3 and heights == sorted(heights), f"invalid section transition: {heights}"
    panel.click(command)
    if with_motion and panel.has_button(option):
        assert not enabled(get_parent(child)), "closing controls remain available to keyboard navigation"
    eventually(lambda: not panel.has_button(option), "expanded controls did not become hidden")


def check_layout(panel):
    setting = w.BOOL()
    contrast = HighContrast(size=ct.sizeof(HighContrast))
    system_parameters(0x0042, contrast.size, ct.byref(contrast), 0)
    with_motion = system_parameters(0x1042, 0, ct.byref(setting), 0) and setting.value and not contrast.flags & 1
    assert message(panel.hwnd, 0x007F, 0), "small application icon missing"
    panel.resize(940, 700)
    source = rectangle(panel.labelled("待发送内容"))
    target = rectangle(panel.labelled("接收设备"))
    assert source.top == target.top and target.left > source.left, "wide cards did not share a row"
    short_page = get_parent(get_parent(panel.labelled("待发送内容")))
    assert not style(short_page, -16) & 0x00200000, "short page has a vertical scrollbar"
    desktop = rectangle(panel.hwnd)
    midpoint = (desktop.left + desktop.right) // 2
    margin = (dpi(panel.hwnd) or 96) * 6 // 96
    for page, heading, action in (
        (1, "保存位置", "更改保存位置"),
        (2, "附近设备", "刷新已配对设备"),
        (4, "设备与存储", "更改存储位置和端口"),
    ):
        panel.select_tab(page)
        for control in (panel.labelled(heading), panel.labelled(action, "Button")):
            item = rectangle(control)
            assert abs((item.left + item.right) // 2 - midpoint) <= margin, f"page {page} is off center"
    panel.select_tab(0)
    check_disclosure(panel, "更多发送方式", "开启自动发送剪贴板", with_motion)
    panel.select_tab(1)
    check_disclosure(panel, "更多接收方式", "开启自动接收剪贴板", with_motion)
    panel.select_tab(0)
    panel.resize(490, 650)
    source = rectangle(panel.labelled("待发送内容"))
    target = rectangle(panel.labelled("接收设备"))
    assert source.left == target.left and target.top > source.bottom, "narrow cards did not stack"
    assert rectangle(panel.labelled("发送", "Button")).right < rectangle(panel.hwnd).right, "narrow layout clipped the send button"
    panel.select_tab(5)
    advanced = panel.labelled("高级配对")
    page = get_parent(advanced)
    viewport = get_parent(page)
    assert klass(viewport) == "PulseShareViewport"
    assert style(viewport, -20) & 0x02000000, "viewport does not compose child paints"
    assert style(viewport, -16) & 0x00200000, "overflowing page lost its scrollbar"
    top = rectangle(advanced).top
    page_top = rectangle(page).top
    nav = next(h for h in get_windows(children, panel.hwnd) if klass(h) == "SysTabControl32")
    nav_top = rectangle(nav).top
    wheel_down = (-120 & 0xFFFF) << 16
    for _ in range(3):
        message(viewport, 0x020A, wheel_down)
    eventually(lambda: rectangle(page).top < page_top, "wheel did not scroll the page canvas")
    assert rectangle(advanced).top - rectangle(page).top == top - page_top, "wheel moved a control inside its page"
    assert rectangle(nav).top == nav_top, "wheel moved the fixed navigation"
    message(viewport, 0x0115, 6)
    assert rectangle(advanced).top == top
    for _ in range(5):
        message(viewport, 0x0115, 3)
        message(viewport, 0x0115, 3)
        assert rectangle(advanced).top < top, "advanced page did not scroll"
        message(viewport, 0x0115, 6)
        assert rectangle(advanced).top == top, "advanced page did not return to the same layout"
    panel.select_tab(0)
    panel.labelled("待发送内容")
    panel.resize(940, 700)
    assert not style(short_page, -16) & 0x00200000, "scrollbar stayed visible after returning to a short page"


def build_fixture(root, repo):
    fixture = root / "pulse-share-lan.exe"
    subprocess.run(["zig", "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-target",
                    "x86_64-windows-gnu", str(repo / "tests/share/desktop_lan_fixture_win32.c"),
                    "-o", str(fixture)], cwd=repo, check=True, timeout=180)
    for key in ("local", "worker", "pake"):
        shutil.copyfile(fixture, root / f"pulse-share-{key}.exe")
    digest = hashlib.sha256(fixture.read_bytes()).hexdigest()
    flags = [f"-Dshare-{key}-sha256={digest}" for key in ("lan", "local", "worker", "pake")]
    subprocess.run(["zig", "build", "share-dev", "-Dtarget=x86_64-windows-msvc",
                    "-Doptimize=ReleaseSafe", "--prefix", str(root / "build"), *flags],
                   cwd=repo, check=True, timeout=360)
    desktop = root / "pulse-share-desktop.exe"
    shutil.copyfile(root / "build" / "bin" / desktop.name, desktop)
    return desktop


def run_fixture(exe):
    name = f"ShareFixture-{uuid.uuid4().hex}"
    desktop = checked(create_desktop(name, None, None, 0, 0x01FF, None))
    reader, writer, written = w.HANDLE(), w.HANDLE(), w.DWORD()
    process = Process()
    original = checked(thread_desktop(thread_id()))
    try:
        checked(set_desktop(desktop))
        security = Security(ct.sizeof(Security), None, True)
        checked(pipe(ct.byref(reader), ct.byref(writer), ct.byref(security), 8192))
        try:
            sample = "1\n1\nC:\\ShareFixture\\选中.txt\n".encode()
            checked(write(writer, sample, len(sample), ct.byref(written), None))
        finally:
            close_handle(writer)
        try:
            command = ct.create_unicode_buffer(f'"{exe}" --session-only --handoff {reader.value:x}')
            startup = Startup(cb=ct.sizeof(Startup), desktop=name)
            checked(create_process(str(exe), command, None, None, True, 0, None,
                                   str(exe.parent), ct.byref(startup), ct.byref(process)))
        finally:
            close_handle(reader)
        close_handle(process.thread)
        hwnd = eventually(lambda: next((hwnd for hwnd in get_windows(desktop_windows, desktop)
                                         if klass(hwnd) == "PulseShareDesktop" and visible(hwnd)), None),
                          "standalone Share window did not open")
        panel = Window(hwnd)
        frame = rectangle(hwnd)
        assert abs(3 * (frame.right - frame.left) - 4 * (frame.bottom - frame.top)) <= 2, "initial window is not 4:3"
        check_layout(panel)
        eventually(lambda: panel.contains("选中.txt"), "selected Unicode path did not reach Share")
        panel.select_tab(4)
        assert not panel.contains("设备身份目录"), "raw storage paths exposed by default"
        panel.click("更改存储位置和端口")
        assert "PulseShare\\identity" in text_at(panel.next_control("设备身份目录", "Edit"))
        assert "PulseShare\\spool" in text_at(panel.next_control("私有暂存目录", "Edit"))
        panel.type("设备身份目录", str(exe.parent / "identity"))
        panel.type("私有暂存目录", str(exe.parent / "spool"))
        panel.click("初始化本机身份和暂存")
        eventually(lambda: panel.contains("本机身份和私有暂存目录已就绪"), "one-step device setup did not finish")
        panel.select_tab(0)
        panel.click("选设备")
        panel.click("更改本机网络")
        panel.type("本机网络地址", "192.0.2.10")
        panel.click("查找附近设备")
        try:
            eventually(lambda: panel.contains("可配对 1 台"), "discovery result did not reach Devices")
        except AssertionError:
            print([item for item in panel.messages() if item])
            raise
        found = eventually(lambda: panel.notice() if panel.notice() and "可配对 1 台" in text_at(panel.notice()) else None,
                           "discovery result did not show a notification")
        overlay, frame = rectangle(found), rectangle(panel.hwnd)
        assert abs(overlay.left + overlay.right - frame.left - frame.right) <= 2
        Window(found).click("关闭")
        eventually(lambda: not panel.notice(), "notification did not dismiss")
        assert panel.contains("可配对 1 台"), "dismissal removed the discovery result"
        pair = panel.next_control("等待配对的附近设备", "ComboBox")
        assert message(pair, 0x0146) == 2, "missing discovered address"
        message(pair, 0x014E, 1)
        panel.click("填入配对地址")
        assert text_at(panel.next_control("对端配对地址", "Edit")) == "192.0.2.15:45844"
        panel.type("本机网络地址", "192.0.2.11")
        panel.click("查找附近设备")
        eventually(lambda: panel.contains("未发现设备"), "missing empty discovery result")
        assert message(pair, 0x0146) == 1, "stale discovery result"
        panel.type("本机网络地址", "192.0.2.10")
        alias = text_at(panel.next_control("配对名称", "Edit"))
        assert alias and any(ord(letter) > 127 for letter in alias), "missing random Chinese label"
        panel.type("配对名称", "客厅电脑")
        panel.click("开启连接码并允许发现")
        eventually(lambda: panel.contains("01234567"), "no inline pairing code")
        popup = eventually(lambda: next((h for h in get_windows(desktop_windows, desktop)
                                         if klass(h) == "PulseSharePairing" and visible(h)), None),
                           "centered pairing window did not appear")
        popup_rect = rectangle(popup)
        owner_rect = rectangle(hwnd)
        assert abs(popup_rect.left + popup_rect.right - owner_rect.left - owner_rect.right) < 12
        assert abs(popup_rect.top + popup_rect.bottom - owner_rect.top - owner_rect.bottom) < 12
        Window(popup).labelled("复制地址和连接码", "Button")
        time.sleep(0.6)
        assert visible(popup), "pairing window disappeared while the code was active"
        assert panel.contains("01234567"), "pairing code flashed and disappeared"
        panel.resize(490, 550)
        assert panel.contains("01234567"), "pairing code lost after resize"
        panel.click("取消任务")
        eventually(lambda: panel.contains("已取消"), "pair cancellation never completed")
        assert not panel.contains("01234567"), "pairing code retained after cancel"
        assert not visible(popup), "pairing popup stayed visible after cancellation"
        panel.type("对端配对地址", "192.0.2.90:45844")
        panel.type("对端的 8 位连接码", "01234567")
        panel.click("连接")
        eventually(lambda: panel.notice() and "请输入可达的对端数字 IP 和端口" in text_at(panel.notice()),
                   "localized endpoint error did not show a notification")
        Window(panel.notice()).click("关闭")
        eventually(lambda: not panel.notice(), "error notification did not dismiss")
        panel.select_tab(3)
        assert panel.contains("请输入可达的对端数字 IP 和端口")
        panel.labelled("导出诊断…", "Button")
        panel.select_tab(2)
        panel.type("对端配对地址", "192.0.2.15:45844")
        panel.type("对端的 8 位连接码", "01234567")
        panel.click("连接")
        eventually(lambda: panel.contains("Trust device"), "no confirmation after code entry")
        panel.click("确认请求")
        eventually(lambda: panel.contains("COMPLETED pairing"), "pairing terminal state absent")
        panel.click("已组网？手动配对")
        panel.type("本机组网 IP", "100.64.1.10")
        panel.type("组网对端名称", "overlay-test")
        panel.type("生成端监听端口（0 自动）", "45844")
        panel.click("生成组网连接码")
        eventually(lambda: panel.contains("请填写允许连接的对端来源 IP"), "routed host accepted an empty source")
        panel.type("允许连接的对端来源 IP", "100.64.1.20")
        panel.click("生成组网连接码")
        eventually(lambda: panel.contains("01234567") and panel.contains("100.64.1.10:45844"),
                   "edited routed host address, source and port were not sent to the worker")
        panel.click("取消任务")
        eventually(lambda: panel.contains("已取消"), "routed cancellation did not complete")
        panel.type("对端组网地址与端口", "100.64.1.20:45844")
        panel.type("对端显示的 8 位组网连接码", "01234567")
        panel.click("连接组网设备")
        eventually(lambda: panel.contains("Trust device"), "edited routed endpoint did not reach the worker")
        panel.click("确认请求")
        eventually(lambda: panel.contains("COMPLETED routed pairing"), "routed pairing terminal state absent")
        panel.click("收起组网配对")
        eventually(lambda: not panel.contains("对端组网地址与端口"), "collapsed routed controls stayed visible")
        panel.click("刷新已配对设备")
        use_peer = eventually(lambda: panel.has_button("设为当前对端"), "UTF-8 peer list did not open")
        assert use_peer
        choice = panel.next_control("已配对设备名称", "Edit")
        combos = [h for h in get_windows(children, get_parent(choice)) if klass(h) == "ComboBox" and visible(h)]
        selected = next(h for h in combos if get_id(h) > get_id(choice))
        assert message(selected, 0x0146) == 2
        message(selected, 0x014E, 1)
        panel.click("设为当前对端")
        panel.select_tab(0)
        assert panel.contains("当前对端 · 客厅电脑"), "UTF-8 peer was not retained as the selected device"
        panel.click("手动输入对端地址")
        panel.type("对端地址与端口", "192.0.2.14:45843")
        panel.click("更多发送方式")
        def run_service(name):
            panel.click(f"开启{name}")
            eventually(lambda: panel.has_button(f"待确认 · 停止{name}"), f"{name} had no confirmation state")
            panel.click("确认请求")
            eventually(lambda: panel.has_button(f"已开启 · 停止{name}"), f"{name} had no active state")
            panel.click(f"已开启 · 停止{name}")
            eventually(lambda: panel.has_button(f"开启{name}"), f"{name} did not return to off")

        run_service("自动发送剪贴板")
        run_service("只读目录服务")
        panel.select_tab(1)
        panel.click("更多接收方式")
        run_service("自动接收剪贴板")
        panel.select_tab(0)
        panel.click("选设备")
        panel.click("开启连接码并允许发现")
        eventually(lambda: panel.contains("01234567"), "pair task could not be restarted")
        checked(post(hwnd, 0x0010, 0, 0))
        assert wait(process.process, 12000) == 0, "window did not drain active worker"
        print("Share desktop: handoff, discovery, address selection, persistent code, LAN and routed approval, UTF-8 peers, diagnostics, service toggles, notifications, 4:3 layout, motion, scrolling, icon and close passed")
    finally:
        if process.process:
            if wait(process.process, 0) != 0:
                terminate(process.process, 1)
                wait(process.process, 5000)
            close_handle(process.process)
        checked(set_desktop(original))
        close_desktop(desktop)


if __name__ == "__main__":
    process_dpi(ct.c_void_p(-4))
    repository = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="share-desktop-") as temporary:
        run_fixture(build_fixture(Path(temporary), repository))
