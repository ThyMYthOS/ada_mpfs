# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# Derived from ThyMYthOS/ada-machine rts-spikes/hw/ocd.py @ 2f0be23; modified for PolarFire SoC.
"""OpenOCD telnet client and serial capture for the Icicle Kit.

The host, the port and the serial devices come from lab.conf (see lab.py).
"""
import errno
import os
import re
import select
import socket
import termios
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
    """Open the serial ports of MMUART0 .. MMUART<count-1> at 115200 8N1 and collect
    what arrives. <paths> maps the MMUART number to a device."""

    def __init__(self, paths):
        self.fds = {}
        for i, path in paths.items():
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOCTTY)
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
                    raise
            self.fds[i] = fd
        self.data = {i: b"" for i in paths}

    @classmethod
    def from_lab(cls, lab):
        from lab import serial_path
        return cls({i: serial_path(lab, i) for i in range(int(lab["UART_COUNT"]))})

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select(list(self.fds.values()), [], [], 0.05)
            for i, fd in self.fds.items():
                if fd in ready:
                    chunk = os.read(fd, 4096)
                    if chunk:
                        self.data[i] += chunk
                    else:
                        time.sleep(0.01)   # end of a file: do not spin

    def close(self):
        for fd in self.fds.values():
            os.close(fd)
        self.fds = {}
