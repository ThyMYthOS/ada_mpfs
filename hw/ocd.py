# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""OpenOCD telnet client and serial capture for the Icicle Kit.

The host, the port and the serial ports (devices or TCP ports) come from lab.conf (see lab.py).
"""
import errno
import os
import re
import select
import socket
import sys
import termios
import threading
import time

HART = {0: "mpfs.hart0_e51"} | {n: f"mpfs.hart{n}_u54_{n}" for n in range(1, 5)}


class OCD:
    # Each command costs ~0.35 s of JTAG round trip; batch with "; " or Tcl loops.
    def __init__(self, port=4444, host="localhost", timeout=30):
        try:
            self.s = socket.create_connection((host, port), timeout=timeout)
        except OSError as e:
            raise SystemExit(
                f"ocd: cannot reach OpenOCD at {host}:{port} ({e}); start it with ./x hw openocd") from e
        self._read()

    def _read(self):
        buf = b""
        while not buf.endswith(b"> "):
            chunk = self.s.recv(65536)
            if not chunk:
                raise SystemExit("ocd: OpenOCD closed the connection")
            buf += chunk
        return re.sub(rb"[\xff][\xfb-\xfe].", b"", buf).decode("latin1").replace("\r", "")

    def cmd(self, c):
        self.s.sendall(c.encode() + b"\n")
        lines = self._read().split("\n")
        return "\n".join(lines[1:-1]).strip() if len(lines) > 1 else ""

    def hart(self, n):
        self.cmd(f"targets {HART[n]}")

    def reg(self, name):
        return int(re.search(r"0x([0-9a-fA-F]+)", self.cmd(f"reg {name}")).group(1), 16)

    def rd32(self, addr):
        return int(self.cmd(f"mdw 0x{addr:x}").split()[1], 16)

    def rd64(self, addr):
        return int(self.cmd(f"mdd 0x{addr:x}").split()[1], 16)

    def wr32(self, addr, val):
        self.cmd(f"mww 0x{addr:x} 0x{val:x}")


class Serial:
    """Open the serial ports of MMUART0 .. MMUART<count-1> and collect what arrives, as bytes in
    <data>. <ports> maps the MMUART number to a device path (opened at 115200 8N1), or to a
    lab.Endpoint: a device, or a TCP port (a socat on another machine tunnels the UART; its baud rate is
    set there). TCP ports are connected in parallel, with a timeout of <connect_timeout> seconds each;
    a port that cannot be opened or connected is a set-up error (SystemExit) that names the port and the
    endpoint. A port that fails later (the connection closes or breaks, the device is unplugged) is
    reported once through <note>(number, text), default a line on stderr, and not read any more; the
    others go on."""

    def __init__(self, ports, note=None, connect_timeout=5.0):
        import lab
        self.note = note or self._note_stderr
        self.src = {}        # MMUART number -> fd (device) or socket (TCP)
        self.tcp = set()     # the numbers that are TCP ports
        self.dead = set()    # the numbers that are not read any more
        self.data = {i: b"" for i in ports}
        eps = {i: (p if isinstance(p, lab.Endpoint) else lab.Endpoint("device", path=str(p))) for i, p in ports.items()}
        self.labels = {i: str(ep) for i, ep in eps.items()}
        try:
            for i, ep in eps.items():
                if ep.kind == "device":
                    self.src[i] = self._open_device(i, ep.path)
            tcp = {i: ep for i, ep in eps.items() if ep.kind == "tcp"}
            if tcp:
                self._connect(tcp, connect_timeout)
        except BaseException:
            self.close()
            raise

    @staticmethod
    def _note_stderr(i, text):
        print(f"{os.path.basename(sys.argv[0])}: MMUART{i}: {text}", file=sys.stderr, flush=True)

    @staticmethod
    def _open_device(i, path):
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOCTTY)
        except OSError as e:
            raise SystemExit(f"serial: MMUART{i}: cannot open {path}: {e.strerror or e}") from e
        try:
            a = termios.tcgetattr(fd)
            a[0] = a[1] = a[3] = 0
            a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
            a[4] = a[5] = termios.B115200
            a[6][termios.VMIN] = 0
            a[6][termios.VTIME] = 0
            termios.tcsetattr(fd, termios.TCSANOW, a)
            termios.tcflush(fd, termios.TCIFLUSH)
        except termios.error as e:
            # Not a terminal (a file or a pipe in a test): nothing to configure.
            if e.args[0] != errno.ENOTTY:
                os.close(fd)
                raise
        return fd

    def _connect(self, tcp, timeout):
        done = {}

        def one(i, ep):
            try:
                s = socket.create_connection((ep.host, ep.port), timeout=timeout)
            except OSError as e:
                done[i] = (None, e.strerror or str(e))
            else:
                s.setblocking(False)
                done[i] = (s, None)
        # Daemon threads: Ctrl+C while a host does not answer ends the tool at once, not after the timeout.
        threads = [threading.Thread(target=one, args=(i, ep), daemon=True) for i, ep in tcp.items()]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        for i, (sock, _) in sorted(done.items()):
            if sock is not None:
                self.src[i] = sock
                self.tcp.add(i)
        for i, (sock, why) in sorted(done.items()):
            if sock is None:
                raise SystemExit(f"serial: MMUART{i}: cannot connect to {self.labels[i]}: {why}")

    @classmethod
    def from_lab(cls, lab_conf, ports=None, note=None):
        import lab
        count = int(lab_conf["UART_COUNT"])
        return cls(lab.uart_endpoints(lab_conf, range(count) if ports is None else ports), note=note)

    def _read(self, i):
        """Up to one chunk from port <i>; None when there is nothing. A port that ends or breaks is reported
        once and not read again."""
        try:
            if i in self.tcp:
                chunk = self.src[i].recv(65536)
                if not chunk:
                    self._drop(i, f"{self.labels[i]} closed the connection after {len(self.data[i])} bytes")
                    return None
                return chunk
            return os.read(self.src[i], 4096) or None   # end of a file: nothing, and no end of the port
        except (BlockingIOError, InterruptedError):
            return None
        except OSError as e:
            self._drop(i, f"lost {self.labels[i]} after {len(self.data[i])} bytes: {e.strerror or e}")
            return None

    def _drop(self, i, text):
        self.dead.add(i)
        self.note(i, text)

    def pump(self, seconds, view=None):
        """Read for <seconds>. Every chunk is added to <data> and handed to <view>.feed(number, chunk) as it
        arrives; <view>.tick() runs after every round (at least every 50 ms), so a view can redraw."""
        end = time.monotonic() + seconds
        while (left := end - time.monotonic()) > 0:
            live = {self.src[i]: i for i in self.src if i not in self.dead}
            if not live:
                time.sleep(min(0.05, left))
            else:
                ready, _, _ = select.select(list(live), [], [], min(0.05, left))
                for obj in ready:
                    i = live[obj]
                    chunk = self._read(i)
                    if chunk:
                        self.data[i] += chunk
                        if view:
                            view.feed(i, chunk)
                    elif i not in self.dead and i not in self.tcp:
                        time.sleep(0.01)   # end of a file: do not spin
            if view:
                view.tick()

    def close(self):
        for i, src in self.src.items():
            if i in self.tcp:
                src.close()
            else:
                os.close(src)
        self.src = {}
