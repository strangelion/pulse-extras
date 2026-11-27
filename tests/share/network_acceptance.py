"""Run real Share transport tests inside fresh private Linux network namespaces.

Only on a disposable CI runner with root and no production credentials.
No host default route changes, public overlay nodes or real user data.
The fixture and ephemeral TLS keys are removed; only reports/logs survive.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import subprocess
import tempfile
import time
import urllib.request
import tarfile
import zipfile

SMALL = 8 * 1024 * 1024 + 123
LARGE = 128 * 1024 * 1024 + 123
PORT = 46000
A4, B4, RA4, RB4 = "10.201.1.2", "10.201.2.2", "10.201.1.1", "10.201.2.1"
A6, B6, RA6, RB6 = "fd42:201:1::2", "fd42:201:2::2", "fd42:201:1::1", "fd42:201:2::1"
ASSETS = {
    "frp": ("https://github.com/fatedier/frp/releases/download/v0.72.0/frp_0.72.0_linux_amd64.tar.gz",
            "daf719b32ca2778770bb92955e231a07414d754378b9af328aa2642862479804", ("frps", "frpc")),
    "easytier": ("https://github.com/EasyTier/EasyTier/releases/download/v2.6.4/easytier-linux-x86_64-v2.6.4.zip",
                 "61b659eaedba658fa66fe47d17e1426cdd77e5d02fa15fed447bb4357c09dfd6", ("easytier-core",)),
}


class EnvironmentFailure(RuntimeError):
    pass


class CaseFailure(RuntimeError):
    pass


def command(args, ns=None):
    return (["ip", "netns", "exec", ns] if ns else []) + [str(x) for x in args]


def run(*args, ns=None, input=None, timeout=30):
    p = subprocess.run(command(args, ns), input=input, text=True, capture_output=True, timeout=timeout)
    if p.returncode:
        raise EnvironmentFailure(f"{args[0]} failed ({p.returncode}): {p.stderr[-1200:]}")
    return p.stdout.strip()


def poll(check, seconds, message):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        result = check()
        if result:
            return result
        time.sleep(0.15)
    raise CaseFailure(message)


def stop(p):
    if p.poll() is None:
        try:
            os.killpg(p.pid, signal.SIGTERM)
            p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait(timeout=5)
        except ProcessLookupError:
            pass


def tail(p):
    if not p.exists():
        return ""
    with p.open("rb") as f:
        f.seek(max(0, p.stat().st_size - 131072))
        return f.read().decode("utf-8", "replace")


def endpoint(addr, port):
    return f"[{addr}]:{port}" if ":" in addr else f"{addr}:{port}"


def extract_asset(name, directory):
    url, expected, members = ASSETS[name]
    archive = directory / (name + ".download")
    h = hashlib.sha256()
    total = 0
    with urllib.request.urlopen(url, timeout=45) as src, archive.open("xb") as dst:
        while chunk := src.read(1024 * 1024):
            total += len(chunk)
            if total > 256 * 1024 * 1024:
                raise EnvironmentFailure("asset exceeds size bound")
            h.update(chunk)
            dst.write(chunk)
    if h.hexdigest() != expected:
        raise EnvironmentFailure(f"{name} release checksum mismatch")
    # Read only the named ordinary members. Never unpack archive paths,
    # symlinks, hardlinks or executable installation scripts.
    outputs = {}
    if name == "easytier":
        with zipfile.ZipFile(archive) as z:
            for wanted in members:
                matches = [i for i in z.infolist() if Path(i.filename).name == wanted and not i.is_dir()]
                if len(matches) != 1 or matches[0].file_size > 128 * 1024 * 1024:
                    raise EnvironmentFailure("unexpected EasyTier archive")
                mode = (matches[0].external_attr >> 16) & 0o170000
                if mode not in (0, 0o100000):
                    raise EnvironmentFailure("nonordinary EasyTier member")
                p = directory / wanted
                with z.open(matches[0]) as src, p.open("xb") as dst:
                    shutil.copyfileobj(src, dst)
                outputs[wanted] = p
    else:
        with tarfile.open(archive, "r:gz") as z:
            for wanted in members:
                matches = [i for i in z.getmembers() if Path(i.name).name == wanted]
                if len(matches) != 1 or not matches[0].isfile() or matches[0].size > 128 * 1024 * 1024:
                    raise EnvironmentFailure("unexpected FRP archive")
                p = directory / wanted
                with z.extractfile(matches[0]) as src, p.open("xb") as dst:
                    shutil.copyfileobj(src, dst)
                outputs[wanted] = p
    for p in outputs.values():
        p.chmod(0o700)
    archive.unlink()
    return outputs


class Lab:
    def __init__(self, binary, out, root):
        self.binary, self.out, self.root = binary, out, root
        tag = secrets.token_hex(4)
        self.a, self.r, self.b = ("ps-" + tag + "-" + x for x in ("a", "r", "b"))
        self.created = []
        self.processes = []
        self.results = []
        self.tools = {}

    def start(self, name, args, ns=None, env=None):
        log = self.out / (name + ".log")
        with log.open("wb") as f:
            p = subprocess.Popen(command(args, ns), stdout=f, stderr=subprocess.STDOUT,
                                 env=env, start_new_session=True)
        self.processes.append(p)
        return p, log

    def cleanup(self):
        for p in reversed(self.processes):
            stop(p)
        for ns in reversed(self.created):
            # Kill only processes inside a namespace this lab created.
            p = subprocess.run(["ip", "netns", "pids", ns], text=True, capture_output=True)
            for pid in p.stdout.split():
                if pid.isdecimal():
                    try:
                        os.kill(int(pid), signal.SIGTERM)
                    except ProcessLookupError:
                        pass
            subprocess.run(["ip", "netns", "del", ns], check=False, capture_output=True)

    def setup(self):
        for ns in (self.a, self.r, self.b):
            run("ip", "netns", "add", ns)
            self.created.append(ns)
            run("ip", "-n", ns, "link", "set", "lo", "up")
        for end, iface, riface in ((self.a, "va", "ra"), (self.b, "vb", "rb")):
            run("ip", "link", "add", iface, "netns", end, "type", "veth", "peer", "name", riface, "netns", self.r)
            run("ip", "-n", end, "link", "set", iface, "up")
            run("ip", "-n", self.r, "link", "set", riface, "up")
        for ns, dev, v4, v6 in ((self.a, "va", A4, A6), (self.b, "vb", B4, B6),
                                 (self.r, "ra", RA4, RA6), (self.r, "rb", RB4, RB6)):
            run("ip", "-n", ns, "addr", "add", v4 + "/24", "dev", dev)
            run("ip", "-n", ns, "-6", "addr", "add", v6 + "/64", "dev", dev, "nodad")
        for ns, v4, via4, v6, via6 in ((self.a, "10.201.2.0/24", RA4, "fd42:201:2::/64", RA6),
                                        (self.b, "10.201.1.0/24", RB4, "fd42:201:1::/64", RB6)):
            run("ip", "-n", ns, "route", "add", v4, "via", via4)
            run("ip", "-n", ns, "-6", "route", "add", v6, "via", via6)
        run("sysctl", "-w", "net.ipv4.ip_forward=1", ns=self.r)
        run("sysctl", "-w", "net.ipv6.conf.all.forwarding=1", ns=self.r)
        # Explicit test networks only, without any Internet/default route.
        self.ping(self.a, B4)
        self.ping(self.a, B6)
        for ns in (self.a, self.r, self.b):
            if run("ip", "-n", ns, "route", "show", "default") or run("ip", "-n", ns, "-6", "route", "show", "default"):
                raise EnvironmentFailure("unexpected namespace default route")
        env = dict(os.environ, PULSE_ACCEPTANCE_ROLE="prepare", PULSE_ACCEPTANCE_ROOT=str(self.root))
        p, log = self.start("fixture", [self.binary, "-test.run=^TestNetworkAcceptanceProcess$", "-test.v", "-test.timeout=60s"], env=env)
        if p.wait(timeout=65):
            raise EnvironmentFailure("synthetic fixture generation failed: " + tail(log)[-1000:])

    def ping(self, ns, address, seconds=15):
        def attempt():
            p = subprocess.run(command(["ping", "-c", "1", "-W", "1", address], ns),
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
            return p.returncode == 0
        try:
            poll(attempt, seconds, "isolated network unreachable")
        except CaseFailure as e:
            raise EnvironmentFailure(str(e)) from e

    def save(self):
        (self.out / "results.json").write_text(json.dumps({
            "schema": 1, "scope": "isolated transport core; not Windows host acceptance",
            "tools": self.tools, "cases": self.results,
        }, indent=2) + "\n", encoding="utf-8")

    def case(self, name, work):
        row = {"case": name}
        started = time.monotonic()
        try:
            row.update(work() or {})
            row["status"] = "PASS"
        except (EnvironmentFailure, OSError, subprocess.SubprocessError) as e:
            row.update(status="ENVIRONMENT_ERROR", detail=str(e))
        except CaseFailure as e:
            row.update(status="FAIL", detail=str(e))
        row["seconds"] = round(time.monotonic() - started, 3)
        self.results.append(row)
        self.save()
        print(name, row["status"], row.get("detail", ""), flush=True)

    def transfer(self, name, quic, channels=3, size=SMALL, bind_a=A4, bind_b=B4,
                 peer=None, source=None, peer_port=PORT, spool=None, resume=None,
                 interrupt=False, reject=False):
        spool = spool or self.root / name
        spool.mkdir(mode=0o700, exist_ok=True)
        common = dict(os.environ, PULSE_ACCEPTANCE_ROOT=str(self.root),
                      PULSE_ACCEPTANCE_BYTES=str(size), PULSE_ACCEPTANCE_CHANNELS=str(channels),
                      PULSE_ACCEPTANCE_PORT=str(PORT), PULSE_ACCEPTANCE_QUIC="1" if quic else "0",
                      PULSE_ACCEPTANCE_SPOOL=str(spool), PULSE_ACCEPTANCE_RESUME=str(resume or ""))
        recv = dict(common, PULSE_ACCEPTANCE_ROLE="receive", PULSE_ACCEPTANCE_BIND=bind_b,
                    PULSE_ACCEPTANCE_SOURCE=source or bind_a)
        send = dict(common, PULSE_ACCEPTANCE_ROLE="send", PULSE_ACCEPTANCE_BIND=bind_a,
                    PULSE_ACCEPTANCE_PEER=endpoint(peer or bind_b, peer_port))
        def process(role, ns, env):
            metrics = self.out / f"{name}-{role}.time"
            args = ["/usr/bin/time", "-f", "%e %U %S %M", "-o", metrics, self.binary,
                    "-test.run=^TestNetworkAcceptanceProcess$", "-test.v", "-test.timeout=160s"]
            p, log = self.start(name + "-" + role, args, ns, env)
            return p, log, metrics
        receiver, rlog, rtime = process("receive", self.b, recv)
        sender = None
        try:
            def ready():
                if receiver.poll() is not None:
                    raise CaseFailure("receiver exited before ready: " + tail(rlog)[-1000:])
                return "ACCEPTANCE_READY " in tail(rlog)
            poll(ready, 12, "receiver did not report readiness")
            sender, slog, stime = process("send", self.a, send)
            if interrupt:
                def verified():
                    if sender.poll() is not None or receiver.poll() is not None:
                        raise CaseFailure("transfer ended before controlled interruption")
                    return next((int(x) for x in re.findall(r"PROGRESS (\d+) \d+", tail(rlog)) if int(x) > 0), 0)
                count = poll(verified, 45, "no verified block before interruption")
                # A complete packet blackout, without destroying IPv6
                # addresses/routes needed by the following scenarios.
                run("tc", "qdisc", "replace", "dev", "va", "root", "netem", "loss", "100%", ns=self.a)
                time.sleep(3)
                stop(sender)
                stop(receiver)
                stages = list(spool.glob("share-v2-*"))
                if len(stages) != 1 or (stages[0] / "publish.v2").exists():
                    raise CaseFailure("interrupted stage unavailable or publication started")
                return {"verified_before_interruption": count, "stage": str(stages[0])}
            try:
                code = sender.wait(timeout=155)
            except subprocess.TimeoutExpired as exc:
                raise CaseFailure("sender exceeded bounded transfer deadline") from exc
            if reject:
                if code == 0 or not re.search(r"timeout|deadline|no recent network activity", tail(slog), re.I):
                    raise CaseFailure("blocked UDP did not fail as expected: " + tail(slog)[-1000:])
                if list(spool.glob("share-v2-*")):
                    raise CaseFailure("blocked QUIC created a transaction")
                return {"protocol": "QUIC", "expected": "explicit failure, no TCP fallback"}
            if code != 0:
                raise CaseFailure("sender failed: " + tail(slog)[-1500:])
            try:
                received = receiver.wait(timeout=25)
            except subprocess.TimeoutExpired as exc:
                raise CaseFailure("receiver exceeded bounded completion deadline") from exc
            if received:
                raise CaseFailure("receiver failed: " + tail(rlog)[-1500:])
            stages = list(spool.glob("share-v2-*"))
            if len(stages) != 1 or not (stages[0] / "published.v2").is_file() or list(stages[0].glob("*.part")):
                raise CaseFailure("missing terminal record or payload leaked")
            stats = {}
            for role, log, timing in (("send", slog, stime), ("receive", rlog, rtime)):
                match = re.search(r"ACCEPTANCE_METRIC role=\w+ bytes=(\d+) elapsed_ms=(\d+) opened=(\d+) peak_lanes=(\d+) fd_before=(\d+) fd_after=(\d+)", tail(log))
                if not match:
                    raise CaseFailure("missing verified transport metrics")
                n, ms, opened, peak, before, after = map(int, match.groups())
                wall, user, system, rss = map(float, timing.read_text().split())
                stats[role] = dict(bytes=n, elapsed_ms=ms, MiB_per_s=round(n / 1048576 / max(ms / 1000, .001), 3),
                                   opened=opened, peak_lanes=peak, fd_before=before, fd_after=after,
                                   wall_seconds=wall, cpu_seconds=user+system, peak_rss_KiB=int(rss))
                if rss > 384 * 1024:
                    raise CaseFailure("helper peak RSS exceeds native job process limit")
            if not resume and stats["receive"]["opened"] < min(channels, (size + 4194303) // 4194304):
                raise CaseFailure("requested data lane count not exercised")
            if resume:
                initial = re.search(r"PROGRESS (\d+) \d+", tail(rlog))
                if not initial or int(initial[1]) == 0:
                    raise CaseFailure("no durable verified blocks reused")
                stats["resumed_bytes"] = int(initial[1])
            return {"protocol": "QUIC" if quic else "TCP", "requested_channels": channels,
                    "verified": True, "metrics": stats}
        finally:
            if sender:
                stop(sender)
            stop(receiver)

    def netem(self, name, quic):
        try:
            for ns, dev in ((self.a, "va"), (self.b, "vb")):
                run("tc", "qdisc", "replace", "dev", dev, "root", "netem", "delay", "30ms", "loss", "1%", "rate", "100mbit", ns=ns)
                run("ip", "-n", ns, "link", "set", dev, "mtu", "1280")
            return self.transfer(name, quic)
        finally:
            for ns, dev in ((self.a, "va"), (self.b, "vb")):
                subprocess.run(command(["tc", "qdisc", "del", "dev", dev, "root"], ns), capture_output=True)
                run("ip", "-n", ns, "link", "set", dev, "mtu", "1500")

    def interrupted(self, name, quic):
        spool = self.root / (name + "-spool")
        try:
            run("tc", "qdisc", "replace", "dev", "va", "root", "netem", "rate", "20mbit", ns=self.a)
            result = self.transfer(name+"-initial", quic, 4, LARGE, spool=spool, interrupt=True)
        finally:
            subprocess.run(command(["tc", "qdisc", "del", "dev", "va", "root"], self.a), capture_output=True)
        self.ping(self.a, B4)
        resumed = self.transfer(name+"-resume", quic, 4, LARGE, spool=spool, resume=Path(result["stage"]))
        return {"verified_before_interruption": result["verified_before_interruption"], **resumed}

    def nat(self, name, quic):
        protocol = "udp" if quic else "tcp"
        pre = ["-t", "nat", "-A", "PREROUTING", "-i", "ra", "-d", RA4, "-p", protocol,
               "--dport", "46001", "-j", "DNAT", "--to-destination", B4+":"+str(PORT)]
        post = ["-t", "nat", "-A", "POSTROUTING", "-o", "rb", "-d", B4, "-p", protocol,
                "--dport", str(PORT), "-j", "SNAT", "--to-source", RB4]
        applied = []
        try:
            for rule in (pre, post):
                run("iptables", *rule, ns=self.r)
                applied.append(rule)
            return self.transfer(name, quic, peer=RA4, peer_port=46001, source=RB4)
        finally:
            for rule in reversed(applied):
                rule = ["-D" if x == "-A" else x for x in rule]
                run("iptables", *rule, ns=self.r)

    def blocked_udp(self):
        rule = ["FORWARD", "-i", "ra", "-o", "rb", "-p", "udp", "--dport", str(PORT), "-j", "DROP"]
        run("iptables", "-A", *rule, ns=self.r)
        try:
            return self.transfer("udp-blocked", True, reject=True)
        finally:
            run("iptables", "-D", *rule, ns=self.r)

    def wireguard(self):
        self.tools["wireguard"] = run("wg", "--version")
        for ns, addr in ((self.a, "10.202.0.1"), (self.b, "10.202.0.2")):
            run("ip", "-n", ns, "link", "add", "wg-share", "type", "wireguard")
            run("ip", "-n", ns, "addr", "add", addr+"/24", "dev", "wg-share")
        keys = []
        for i, ns in enumerate((self.a, self.b)):
            key = run("wg", "genkey")
            path = self.root / f"wg-{i}.key"
            path.write_text(key+"\n", encoding="ascii")
            path.chmod(0o600)
            keys.append((path, run("wg", "pubkey", input=key+"\n")))
            run("wg", "set", "wg-share", "private-key", path, "listen-port", 51820, ns=ns)
        for ns, other, dest, ip in ((self.a, 1, B4, "10.202.0.2"), (self.b, 0, A4, "10.202.0.1")):
            run("wg", "set", "wg-share", "peer", keys[other][1], "allowed-ips", ip+"/32",
                "endpoint", dest+":51820", "persistent-keepalive", 5, ns=ns)
            run("ip", "-n", ns, "link", "set", "wg-share", "up")
        self.ping(self.a, "10.202.0.2")
        for q in (False, True):
            name = "wireguard-"+("quic" if q else "tcp")
            self.case(name, lambda name=name, q=q: self.transfer(name, q, bind_a="10.202.0.1", bind_b="10.202.0.2"))
        return {"detail": "private real WireGuard tunnel established"}

    def nginx(self):
        self.tools["nginx"] = subprocess.run(["nginx", "-v"], capture_output=True, text=True, check=True).stderr.strip()
        mod = Path("/usr/lib/nginx/modules/ngx_stream_module.so")
        if not mod.is_file():
            raise EnvironmentFailure("nginx stream module unavailable")
        conf = self.root / "nginx.conf"
        conf.write_text(f"""load_module {mod};
pid {self.root / 'nginx.pid'};
error_log stderr;
events {{}}
stream {{
 server {{ listen {RA4}:46001; proxy_pass {B4}:{PORT}; proxy_timeout 150s; }}
 server {{ listen {RA4}:46001 udp reuseport; proxy_pass {B4}:{PORT}; proxy_timeout 150s; }}
}}
""", encoding="utf-8")
        p, log = self.start("nginx-service", ["nginx", "-p", self.root, "-c", conf, "-g", "daemon off; master_process off;"], self.r)
        try:
            time.sleep(1)
            if p.poll() is not None:
                raise EnvironmentFailure("Nginx stream startup failed: "+tail(log)[-1000:])
            for q in (False, True):
                name = "nginx-"+("quic" if q else "tcp")
                self.case(name, lambda name=name, q=q: self.transfer(name, q, peer=RA4, peer_port=46001, source=RB4))
        finally:
            stop(p)

    def frp(self, tools):
        self.tools["frp"] = run(tools["frps"], "--version")
        token = secrets.token_hex(24)
        server, client = self.root/"frps.toml", self.root/"frpc.toml"
        server.write_text(f'bindAddr = "{RB4}"\nbindPort = 47000\nproxyBindAddr = "{RA4}"\nauth.method = "token"\nauth.token = "{token}"\n', encoding="utf-8")
        client.write_text(f'''serverAddr = "{RB4}"
serverPort = 47000
auth.method = "token"
auth.token = "{token}"
[[proxies]]
name = "share-tcp"
type = "tcp"
localIP = "{B4}"
localPort = {PORT}
remotePort = 46002
[[proxies]]
name = "share-udp"
type = "udp"
localIP = "{B4}"
localPort = {PORT}
remotePort = 46002
''', encoding="utf-8")
        for path in (server, client):
            path.chmod(0o600)
        sp, sl = self.start("frps-service", [tools["frps"], "-c", server], self.r)
        cp = None
        try:
            time.sleep(.5)
            cp, cl = self.start("frpc-service", [tools["frpc"], "-c", client], self.b)
            def ready():
                if sp.poll() is not None or cp.poll() is not None:
                    raise EnvironmentFailure("FRP startup failed")
                return tail(cl).lower().count("start proxy success") >= 2
            try:
                poll(ready, 25, "FRP proxies not ready")
            except CaseFailure as e:
                raise EnvironmentFailure(str(e)) from e
            for q in (False, True):
                name = "frp-"+("quic" if q else "tcp")
                self.case(name, lambda name=name, q=q: self.transfer(name, q, peer=RA4, peer_port=46002, source=B4))
        finally:
            if cp:
                stop(cp)
            stop(sp)

    def easytier(self, tools):
        core = tools["easytier-core"]
        self.tools["easytier"] = run(core, "--version")
        network, secret = "share-ci-"+secrets.token_hex(6), secrets.token_hex(24)
        common = ["--network-name", network, "--network-secret", secret, "-l", "11010"]
        a, al = self.start("easytier-a", [core, "-i", "10.203.0.1", *common], self.a)
        b = None
        try:
            time.sleep(1)
            b, bl = self.start("easytier-b", [core, "-i", "10.203.0.2", *common, "-p", "tcp://"+A4+":11010"], self.b)
            self.ping(self.a, "10.203.0.2", seconds=35)
            if a.poll() is not None or b.poll() is not None:
                raise EnvironmentFailure("EasyTier exited")
            for q in (False, True):
                name = "easytier-"+("quic" if q else "tcp")
                self.case(name, lambda name=name, q=q: self.transfer(name, q, bind_a="10.203.0.1", bind_b="10.203.0.2"))
        finally:
            if b:
                stop(b)
            stop(a)
            for log in (self.out / "easytier-a.log", self.out / "easytier-b.log"):
                if log.exists():
                    log.write_text(tail(log).replace(secret, "[ephemeral test secret]"), encoding="utf-8")

    def execute(self):
        self.setup()
        for q in (False, True):
            protocol = "quic" if q else "tcp"
            for count in (1, 2, 4, 8, 16, 32):
                name = f"routed-ipv4-{protocol}-{count}"
                self.case(name, lambda name=name, q=q, count=count: self.transfer(name, q, count, LARGE))
            for name, work in (
                ("ipv6-"+protocol, lambda: self.transfer("ipv6-"+protocol, q, bind_a=A6, bind_b=B6)),
                ("nat-"+protocol, lambda: self.nat("nat-"+protocol, q)),
                ("netem-"+protocol, lambda: self.netem("netem-"+protocol, q)),
                ("interruption-"+protocol, lambda: self.interrupted("interruption-"+protocol, q)),
            ):
                self.case(name, work)
        self.case("udp-blocked", self.blocked_udp)
        self.case("wireguard-setup", self.wireguard)
        self.case("nginx-setup", self.nginx)
        for name, method in (("frp", self.frp), ("easytier", self.easytier)):
            self.case(name+"-setup", lambda name=name, method=method: method(extract_asset(name, self.root)))
        # No claim about vendor integrations until their actual control plane,
        # private root/relay infrastructure and exact binaries are provisioned.
        for name in ("tailscale-headscale", "zerotier-private-controller", "easytier-relay", "easytier-no-tun"):
            self.results.append({"case": name, "status": "NOT_RUN",
                                 "detail": "specialized private control-plane/relay fixture not implemented"})
        self.save()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--binary", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    a = p.parse_args()
    if os.geteuid() != 0 or os.environ.get("GITHUB_ACTIONS") != "true":
        p.error("requires a disposable GitHub Actions Linux runner")
    out = a.out.absolute()
    out.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix="pulse-share-ci-") as directory:
        lab = Lab(a.binary.resolve(strict=True), out, Path(directory))
        try:
            lab.execute()
        except (EnvironmentFailure, OSError, subprocess.SubprocessError) as e:
            lab.results.append({"case": "lab", "status": "ENVIRONMENT_ERROR", "detail": str(e)})
        finally:
            lab.cleanup()
            lab.save()
        return int(any(row["status"] in ("FAIL", "ENVIRONMENT_ERROR") for row in lab.results))


if __name__ == "__main__":
    raise SystemExit(main())
