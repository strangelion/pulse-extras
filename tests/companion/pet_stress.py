"""Bounded Windows multi-pet process benchmark, standard library only."""
import argparse
import collections
import csv
import ctypes as C
from ctypes import wintypes as W
import json
import os
import re
import statistics
from pathlib import Path
import subprocess
import tempfile
import time

MIB = 1024 * 1024
D, S, U = W.DWORD, C.c_size_t, C.c_uint64

class Memory(C.Structure):
    _fields_ = [("cb", D), ("faults", D)] + [(n, S) for n in (
        "peak_ws", "ws", "peak_paged", "paged", "peak_nonpaged", "nonpaged",
        "pagefile", "peak_pagefile", "private")]

class IO(C.Structure):
    _fields_ = [(n, U) for n in ("reads", "writes", "other_ops",
                                  "read_bytes", "write_bytes", "other_bytes")]

class Status(C.Structure):
    _fields_ = [("length", D), ("load", D)] + [(n, U) for n in (
        "total", "available", "page_total", "page_available", "virtual_total",
        "virtual_available", "extended")]

class Thread(C.Structure):
    _fields_ = [("size", D), ("usage", D), ("tid", D), ("pid", D),
                ("base", W.LONG), ("delta", W.LONG), ("flags", D)]

def api(lib, name, result, *args):
    f = getattr(lib, name)
    f.argtypes, f.restype = args, result
    return f

def error():
    return C.WinError(C.get_last_error())

def ticks(ft):
    return (ft.dwHighDateTime << 32) | ft.dwLowDateTime

class Windows:
    def __init__(self):
        k = C.WinDLL("kernel32", use_last_error=True)
        p = C.WinDLL("psapi", use_last_error=True)
        u = C.WinDLL("user32", use_last_error=True)
        H, B, P = W.HANDLE, W.BOOL, C.POINTER
        self.event = api(k, "CreateEventW", H, C.c_void_p, B, B, W.LPCWSTR)
        self.signal = api(k, "SetEvent", B, H)
        self.inherit = api(k, "SetHandleInformation", B, H, D, D)
        self.close = api(k, "CloseHandle", B, H)
        self.open = api(k, "OpenProcess", H, D, B, D)
        self.memory = api(p, "GetProcessMemoryInfo", B, H, P(Memory), D)
        self.handles = api(k, "GetProcessHandleCount", B, H, P(D))
        self.times = api(k, "GetProcessTimes", B, H, *([P(W.FILETIME)] * 4))
        self.io = api(k, "GetProcessIoCounters", B, H, P(IO))
        self.gui = api(u, "GetGuiResources", D, H, D)
        self.status = api(k, "GlobalMemoryStatusEx", B, P(Status))
        self.snapshot = api(k, "CreateToolhelp32Snapshot", H, D, D)
        self.first = api(k, "Thread32First", B, H, P(Thread))
        self.next = api(k, "Thread32Next", B, H, P(Thread))

    def available(self):
        s = Status()
        s.length = C.sizeof(s)
        if not self.status(C.byref(s)):
            raise error()
        return s.available

    def threads(self):
        h = self.snapshot(4, 0)
        if not h or h == C.c_void_p(-1).value:
            raise error()
        counts = collections.Counter()
        try:
            t = Thread()
            t.size = C.sizeof(t)
            if not self.first(h, C.byref(t)):
                raise error()
            while True:
                counts[t.pid] += 1
                t.size = C.sizeof(t)
                if not self.next(h, C.byref(t)):
                    if C.get_last_error() != 18:
                        raise error()
                    return counts
        finally:
            self.close(h)

    def sample(self, h, threads):
        m, io, handles = Memory(), IO(), D()
        m.cb = C.sizeof(m)
        ts = [W.FILETIME() for _ in range(4)]
        if not (self.memory(h, C.byref(m), m.cb) and self.handles(h, C.byref(handles))
                and self.times(h, *(C.byref(t) for t in ts)) and self.io(h, C.byref(io))):
            raise error()
        gui = []
        for flag in (0, 1):
            C.set_last_error(0)
            count = self.gui(h, flag)
            if not count and C.get_last_error():
                raise error()
            gui.append(count)
        return dict(working_set=m.ws, private_bytes=m.private, peak_working_set=m.peak_ws,
                    page_faults=m.faults, handles=handles.value, threads=threads,
                    gdi=gui[0], user=gui[1], cpu_seconds=(ticks(ts[2])+ticks(ts[3]))/1e7,
                    read_bytes=io.read_bytes, write_bytes=io.write_bytes,
                    read_ops=io.reads, write_ops=io.writes)

DRAIN = (
    b"Companion heap: live=0 allocations=0",
    b"Companion resources: files=0 codec=0 dib=0 cleanup_failures=0",
    b"Companion notification: live=0",
    b"Companion native: ipc=0 registry=0 menus=0 argv=0",
    b"Companion drawing: windows=0 memory_dc=0 desktop_dc=0",
    b"Companion menu timer: live=0",
    b"Companion tasks: queued=0 running=0",
)

HEAP = re.compile(rb"Companion heap: live=0 allocations=0 peak=(\d+) denied=(\d+)")
RESOURCES = re.compile(rb"Companion resources: files=0 codec=0 dib=0 cleanup_failures=0 peaks=(\d+)/(\d+)/(\d+)")


def shutdown_metrics(data):
    heap, resources = HEAP.search(data), RESOURCES.search(data)
    if heap is None or resources is None:
        return None
    peak, denied = map(int, heap.groups())
    files, codecs, dib = map(int, resources.groups())
    return dict(heap_peak=peak, heap_denied=denied, file_peak=files,
                codec_peak=codecs, dib_peak=dib)


def trend(samples):
    if len(samples) < 2:
        return {}
    width = min(5, len(samples) // 2)
    result = {}
    for key in ("private_bytes", "working_set", "handles", "threads", "gdi", "user"):
        first = statistics.median(row[key] for row in samples[:width])
        last = statistics.median(row[key] for row in samples[-width:])
        result[key] = dict(first_median=first, last_median=last, delta=last-first)
    return result


def sources(a):
    result = []
    for version, filename in a.webp or []:
        if version not in ("1", "2"):
            raise ValueError("WebP version must be 1 or 2")
        result.append(["--webp-v"+version, str(Path(filename).resolve(strict=True))])
    for folder, pet_id in a.package or []:
        result.append(["--package", str(Path(folder).resolve(strict=True)), pet_id])
    return result or [[]]

def read_log(path):
    with path.open("rb") as f:
        return f.read(65536)

def run(a):
    win = Windows()
    exe = a.exe.resolve(strict=True)
    assets = sources(a)
    output = a.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    summary = dict(requested=a.count, visible=a.visible, distinct_source_slots=len(assets),
                   scale=a.scale, seconds=a.seconds, logical_cpus=os.cpu_count() or 1,
                   initial_available_bytes=win.available(), samples=0, started=0,
                   ready=0, graceful=0, forced=0, failures=[], peak={})
    required = ((64 if assets != [[]] else 32)*a.count + 512)*MIB
    event = None
    children = []
    prev = {}
    prev_time = None
    aggregate_samples = []
    shutdown = []
    try:
        if summary["initial_available_bytes"] < required:
            raise RuntimeError(f"Insufficient available memory: need {required//MIB} MiB")
        event = win.event(None, True, False, None)
        if not event or not win.inherit(event, 1, 1):
            raise error()
        startup = subprocess.STARTUPINFO(lpAttributeList={"handle_list": [event]})
        start = time.monotonic()
        with tempfile.TemporaryDirectory(prefix="pet-stress-") as temp:
            try:
                for i in range(a.count):
                    if time.monotonic()-start > 60 or win.available() < 512*MIB:
                        raise RuntimeError("Ramp-up time or memory guard exceeded")
                    log = Path(temp)/f"{i}.log"
                    args = [str(exe), "--stress-seconds", str(a.seconds+110),
                            "--stress-slot", str(i+1), "--scale", str(a.scale),
                            "--stop-handle", str(event)]
                    if not a.visible:
                        args.append("--stress-hidden")
                    args += assets[i % len(assets)]
                    with log.open("wb") as stream:
                        proc = subprocess.Popen(args, stdin=subprocess.DEVNULL,
                                                stdout=subprocess.DEVNULL, stderr=stream,
                                                startupinfo=startup, close_fds=True)
                    children.append((proc, log, None, i % len(assets)))
                    summary["started"] += 1
                    handle = win.open(0x0410, False, proc.pid)
                    if not handle:
                        raise error()
                    children[-1] = (proc, log, handle, i % len(assets))
                    time.sleep(0.025)
                pending = list(children)
                deadline = time.monotonic()+30
                while pending:
                    for child in pending[:]:
                        proc, log, _, _ = child
                        if proc.poll() is not None:
                            raise RuntimeError(f"Child {proc.pid} exited before readiness")
                        if b"Companion stress: ready" in read_log(log):
                            pending.remove(child)
                            summary["ready"] += 1
                    if pending:
                        if time.monotonic() >= deadline or win.available() < 512*MIB:
                            raise RuntimeError("Readiness deadline or memory guard exceeded")
                        time.sleep(0.1)
                summary["ready_seconds"] = time.monotonic()-start
                time.sleep(2)
                begin = time.monotonic()
                with (output/"samples.csv").open("w", newline="", encoding="utf-8") as agg, \
                     (output/"processes.csv").open("w", newline="", encoding="utf-8") as per:
                    aw = pw = None
                    while True:
                        now = time.monotonic()
                        dt = None if prev_time is None else now-prev_time
                        counts = win.threads()
                        rows = []
                        for proc, _, handle, source in children:
                            if proc.poll() is not None:
                                raise RuntimeError(f"Child {proc.pid} exited prematurely")
                            row = win.sample(handle, counts[proc.pid])
                            old = prev.get(proc.pid)
                            row["cpu_core_percent"] = (100*max(0,row["cpu_seconds"]-old)/dt
                                                       if dt and old is not None else 0.0)
                            prev[proc.pid] = row["cpu_seconds"]
                            rows.append(row)
                            detail = dict(seconds=round(now-begin,3), pid=proc.pid, source=source, **row)
                            if pw is None:
                                pw = csv.DictWriter(per, fieldnames=list(detail))
                                pw.writeheader()
                            pw.writerow(detail)
                        total = {key: sum(row[key] for row in rows) for key in rows[0]}
                        total["cpu_machine_percent"] = total["cpu_core_percent"]/summary["logical_cpus"]
                        total["available_bytes"] = win.available()
                        total["max_process_private_bytes"] = max(row["private_bytes"] for row in rows)
                        sample = dict(seconds=round(now-begin,3), live=len(rows), **total)
                        if aw is None:
                            aw = csv.DictWriter(agg, fieldnames=list(sample))
                            aw.writeheader()
                        aw.writerow(sample)
                        aggregate_samples.append(total)
                        agg.flush()
                        per.flush()
                        for key,value in total.items():
                            if key != "available_bytes":
                                summary["peak"][key] = max(summary["peak"].get(key,0),value)
                        summary["samples"] += 1
                        prev_time = now
                        if total["available_bytes"] < 512*MIB:
                            raise RuntimeError("Available-memory guard exceeded")
                        if now-begin >= a.seconds:
                            break
                        time.sleep(max(0,1-(time.monotonic()-now)))
            finally:
                if not win.signal(event):
                    summary["failures"].append("SetEvent failed")
                deadline = time.monotonic()+10
                for proc, _, _, _ in children:
                    try:
                        proc.wait(timeout=max(0,deadline-time.monotonic()))
                    except subprocess.TimeoutExpired:
                        summary["forced"] += 1
                        proc.kill()
                for proc, log, handle, source in children:
                    try:
                        proc.wait(timeout=5)
                        data = read_log(log)
                        metrics = shutdown_metrics(data)
                        if metrics is not None:
                            shutdown.append(dict(pid=proc.pid, source=source, **metrics))
                        if (proc.returncode == 0 and all(marker in data for marker in DRAIN)
                                and metrics is not None and not metrics['heap_denied']):
                            summary["graceful"] += 1
                        else:
                            summary["failures"].append(f"pid {proc.pid}: exit={proc.returncode}, drain or allocator budget not verified")
                            (output/f"failure-{proc.pid}.log").write_bytes(data)
                    finally:
                        if handle:
                            win.close(handle)
    except Exception as exc:
        summary["failures"].append(str(exc))
    finally:
        if event:
            win.close(event)
        summary["final_available_bytes"] = win.available()
        summary["steady_state_trend"] = trend(aggregate_samples)
        summary["shutdown_reports"] = len(shutdown)
        if shutdown:
            summary["heap_peak_max"] = max(row["heap_peak"] for row in shutdown)
            summary["heap_peak_sum"] = sum(row["heap_peak"] for row in shutdown)
            summary["heap_denied_total"] = sum(row["heap_denied"] for row in shutdown)
            grouped = collections.defaultdict(list)
            for row in shutdown:
                grouped[row["source"]].append(row["heap_peak"])
            summary["source_heap_peaks"] = {str(source): dict(instances=len(peaks),
                max=max(peaks), sum=sum(peaks)) for source, peaks in grouped.items()}
            with (output/"shutdown.csv").open("w", newline="", encoding="utf-8") as stream:
                writer = csv.DictWriter(stream, fieldnames=list(shutdown[0]))
                writer.writeheader()
                writer.writerows(shutdown)
        summary["passed"] = (summary["ready"] == a.count and summary["samples"] >= 2
                             and summary["graceful"] == a.count and not summary["failures"]
                             and not summary["forced"])
        (output/"summary.json").write_text(json.dumps(summary,indent=2),encoding="utf-8")
        print(json.dumps(summary,indent=2),flush=True)
    return 0 if summary["passed"] else 1

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, default=Path("zig-out/bin/pulse-pet-demo.exe"))
    parser.add_argument("--count", type=int, choices=range(1,101), default=100)
    parser.add_argument("--seconds", type=int, choices=range(5,181), default=30)
    parser.add_argument("--scale", type=int, choices=range(50,201), default=100)
    parser.add_argument("--webp", action="append", nargs=2, metavar=("VERSION", "FILE"))
    parser.add_argument("--package", action="append", nargs=2, metavar=("DIR", "ID"))
    parser.add_argument("--visible", action="store_true", help="show tiled windows")
    parser.add_argument("--output", type=Path, required=True, help="new non-existing directory")
    a = parser.parse_args()
    if os.name != "nt":
        parser.error("Windows only")
    raise SystemExit(run(a))

if __name__ == "__main__":
    main()
