"""Real two-process TLS loopback and native P1 commit, Windows only."""
import hashlib
from pathlib import Path
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

if len(sys.argv) != 4:
    raise SystemExit("usage: test_lan_copy.py lan.exe supervisor.exe worker.exe")
LAN, SUPERVISOR, WORKER = (Path(p).resolve(strict=True) for p in sys.argv[1:])
sys.argv[1:] = []


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


class Child:
    def __init__(self, args, log):
        self.stderr = log.open("w+", encoding="utf-8")
        self.process = subprocess.Popen(
            [str(LAN), *map(str, args)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
            text=True, encoding="utf-8", errors="replace", bufsize=1,
        )
        self.lines = queue.Queue()
        self.history = []
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        for line in self.process.stdout:
            self.lines.put(line.rstrip())
        self.lines.put(None)

    def expect(self, prefix):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                line = self.lines.get(timeout=max(0.01, deadline - time.monotonic()))
            except queue.Empty:
                break
            if line is None:
                break
            self.history.append(line)
            if line.startswith(prefix):
                return line[len(prefix):].strip()
        raise AssertionError(f"expected {prefix!r}; stdout={self.history!r}; stderr={self.diagnostics()}")

    def diagnostics(self):
        self.stderr.flush()
        with open(self.stderr.name, encoding="utf-8", errors="replace") as f:
            return f.read()

    def answer(self, text):
        self.process.stdin.write(text + "\n")
        self.process.stdin.flush()

    def wait(self):
        return self.process.wait(timeout=45)

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=10)
        self.reader.join(timeout=5)
        self.process.stdin.close()
        self.process.stdout.close()
        self.stderr.close()


@unittest.skipUnless(sys.platform == "win32", "requires native P1 Windows executables")
class LanCopy(unittest.TestCase):
    def transfer(self, ip, existing=False):
        with tempfile.TemporaryDirectory(prefix="pulse-share-lan-") as temp:
            root = Path(temp).resolve(strict=True)
            source = root / "中文 sample.bin"
            source.write_bytes(bytes(range(256)) * 2049)
            dest, spool = root / "destination", root / "spool"
            dest.mkdir()
            spool.mkdir()
            target = dest / source.name
            if existing:
                target.write_bytes(b"preserve me")
            receiver = Child([
                "receive", "--bind", ip, "--port", "0",
                "--directory", dest, "--spool", spool,
                "--supervisor", SUPERVISOR, "--supervisor-sha256", digest(SUPERVISOR),
                "--worker", WORKER, "--worker-sha256", digest(WORKER),
            ], root / "receiver.log")
            try:
                endpoint = receiver.expect("LISTEN ")
                receiver_pin = receiver.expect("FINGERPRINT ")
                sender = Child([
                    "send", "--bind", ip, "--peer", endpoint, "--source", source,
                ], root / "sender.log")
                try:
                    sender_pin = sender.expect("FINGERPRINT ")
                    self.assertEqual(len(receiver_pin), 64)
                    self.assertEqual(len(sender_pin), 64)
                    self.assertNotEqual(receiver_pin, sender_pin)
                    receiver.answer(sender_pin)
                    sender.answer(receiver_pin)
                    offer = receiver.expect("OFFER ")
                    self.assertIn("sample.bin", offer)
                    receiver.answer("yes")
                    want = 1 if existing else 0
                    self.assertEqual(sender.wait(), want, sender.diagnostics())
                    self.assertEqual(receiver.wait(), want, receiver.diagnostics())
                    if existing:
                        self.assertEqual(target.read_bytes(), b"preserve me")
                    else:
                        self.assertEqual(digest(source), digest(target))
                    self.assertEqual(list(spool.iterdir()), [])
                    self.assertEqual(list(dest.glob(".pulse-share-*.part")), [])
                finally:
                    sender.close()
            finally:
                receiver.close()

    def test_saved_device_and_revocation(self):
        with tempfile.TemporaryDirectory(prefix="pulse-share-pair-") as temp:
            root = Path(temp).resolve(strict=True)
            a, b = root / "a", root / "b"
            a.mkdir()
            b.mkdir()
            def run(operation, store, *args, answer=None, want=0):
                p = subprocess.run([str(LAN), operation, "--store", str(store), *args],
                                   input=answer, capture_output=True, text=True, timeout=30)
                self.assertEqual(p.returncode, want, (p.stdout, p.stderr))
                return p.stdout
            a_pin = run("identity-init", a).split()[-1]
            b_pin = run("identity-init", b).split()[-1]
            self.assertEqual(len(a_pin), 64)
            self.assertNotEqual(a_pin, b_pin)
            self.assertEqual(run("identity-show", a).split()[-1], a_pin)
            run("peer-add", a, "--name", "b", answer=b_pin+"\nyes\n")
            run("peer-add", b, "--name", "a", answer=a_pin+"\nyes\n")
            self.assertIn(b_pin, run("peer-list", a))
            dest, spool = root / "destination", root / "spool"
            dest.mkdir()
            spool.mkdir()
            for i in range(2):
                source = root / f"paired-{i}.bin"
                source.write_bytes(b"paired transfer" * 4096)
                receiver = Child([
                    "receive", "--bind", "127.0.0.1", "--port", "0",
                    "--directory", dest, "--spool", spool,
                    "--supervisor", SUPERVISOR, "--supervisor-sha256", digest(SUPERVISOR),
                    "--worker", WORKER, "--worker-sha256", digest(WORKER),
                    "--store", b, "--paired", "a",
                ], root / "receiver.log")
                try:
                    endpoint = receiver.expect("LISTEN ")
                    receiver.expect("PAIRED ")
                    sender = Child(["send", "--bind", "127.0.0.1", "--peer", endpoint,
                                    "--source", source, "--store", a, "--paired", "b"], root / "sender.log")
                    try:
                        sender.expect("PAIRED ")
                        receiver.expect("OFFER ")
                        receiver.answer("yes")
                        self.assertEqual(sender.wait(), 0, sender.diagnostics())
                        self.assertEqual(receiver.wait(), 0, receiver.diagnostics())
                        self.assertEqual(digest(source), digest(dest / source.name))
                        self.assertEqual(list(spool.iterdir()), [])
                    finally:
                        sender.close()
                finally:
                    receiver.close()
            run("peer-revoke", a, "--name", "b", answer="yes\n")
            self.assertNotIn(b_pin, run("peer-list", a))
            p = subprocess.run([str(LAN), "send", "--bind", "127.0.0.1", "--peer", "127.0.0.1:1",
                                "--source", str(source), "--store", str(a), "--paired", "b"],
                               capture_output=True, text=True, timeout=15)
            self.assertNotEqual(p.returncode, 0)
            self.assertNotIn("PAIRED ", p.stdout)

    def test_ipv4(self):
        self.transfer("127.0.0.1")

    def test_ipv6(self):
        try:
            with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as s:
                s.bind(("::1", 0))
        except OSError as exc:
            self.skipTest(f"IPv6 loopback unavailable: {exc}")
        self.transfer("::1")

    def test_no_overwrite(self):
        self.transfer("127.0.0.1", existing=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
