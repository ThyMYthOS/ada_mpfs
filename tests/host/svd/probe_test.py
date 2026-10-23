#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# @verifies HW-001
"""Tests for hw/svd_probe.py against stand-ins for the OpenOCD telnet port.

    probe_test.py [MERGED_SVD]

Every case starts the tool as a subprocess against a small server that answers like the
telnet port (echo, output, prompt "> ") and that can misbehave on purpose: reset or close
the connection, answer with an error text, refuse the second connection. The cases for
the negative paths (dead connection, failed resume, ...) assert that the tool stops, says
why and issues no further reads, so they fail if the tool does not. MERGED_SVD (default
build/svd/PolarfireSoC.svd) is only used by the cases that check the real skip list.
SVD_PROBE selects another copy of the tool, which is how the cases are mutation-checked.
Prints "ok:" or "FAIL:" per case; exits non-zero if one failed.
"""
import os
import re
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TOOL = Path(os.environ.get("SVD_PROBE", ROOT / "hw" / "svd_probe.py"))
REAL_SVD = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "build" / "svd" / "PolarfireSoC.svd"
RESET, EOF, HANG = "reset", "eof", "hang"  # what a script can answer instead of text; HANG: no answer, the connection stays open
failures = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    """Print the result of one case."""
    global failures
    if ok:
        print(f"ok:   {name}")
    else:
        failures += 1
        print(f"FAIL: {name}" + (f" ({detail})" if detail else ""), file=sys.stderr)


class Stub:
    """A stand-in OpenOCD telnet port.

    mem maps an address to the value md reads there (0 if absent). script(conn, cmd, n) may
    return RESET (drop the connection with a TCP reset), EOF (close it), HANG (read on, answer nothing,
    like an OpenOCD that is stuck on a hung bus) or a text to answer with; None means the default. n counts the md commands of that connection so far.
    log holds (connection number, command) for every command received, without the "echo" commands that frame a
    command (the stand-in answers them with their argument; a command that hangs swallows the closing one). With banner=False the
    stand-in accepts the connection and never says anything. "targets" without argument answers
    like OpenOCD with a table in which hart 0 is in <state>. "mww ADDRESS VALUE" stores VALUE & write_mask.get(ADDRESS, all ones) in mem.
    """

    def __init__(self, mem=None, script=None, accept=None, banner=True, state="halted", write_mask=None):
        self.banner = banner
        self.state = state
        self.write_mask = write_mask or {}
        self.accepted = threading.Event()
        self.mem = mem or {}
        self.script = script
        self.accept = accept if accept is not None else 99  # connections served before the port closes
        self.log: list[tuple[int, str]] = []
        self.srv = socket.socket()
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(8)
        self.port = self.srv.getsockname()[1]
        threading.Thread(target=self._serve, daemon=True).start()

    def commands(self, prefix: str, conn: int | None = None) -> list[str]:
        """The commands that start with <prefix>, of one connection or of all."""
        return [c for n, c in self.log if c.startswith(prefix) and conn in (None, n)]

    def _md(self, cmd: str) -> str:
        m = re.fullmatch(r"md([bhwd]) 0x([0-9A-Fa-f]+) (\d+)", cmd)
        width = {"b": 1, "h": 2, "w": 4, "d": 8}[m.group(1)]
        addr, count = int(m.group(2), 16), int(m.group(3))
        return "\n".join(f"0x{addr + i * width:08x}: {self.mem.get(addr + i * width, 0):0{2 * width}x}"
                         for i in range(count))

    def _targets(self) -> str:
        return ("    TargetName         Type       Endian TapName            State\n"
                "--  ------------------ ---------- ------ ------------------ ------------\n"
                f" 0* mpfs.hart0_e51     riscv      little mpfs.cpu           {self.state}\n"
                " 1  mpfs.hart1_u54     riscv      little mpfs.cpu           running")

    def _serve(self) -> None:
        for conn_no in range(self.accept):
            try:
                c, _ = self.srv.accept()
            except OSError:
                return
            self.accepted.set()
            if self.banner:
                c.sendall(b"Open On-Chip Debugger\r\n> ")
            buf, mds, swallow_end = b"", 0, False
            while True:
                try:
                    d = c.recv(4096)
                except OSError:
                    break
                if not d:
                    break
                buf += d
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    cmd = line.decode().strip()
                    if cmd.startswith("echo svd_probe_end_") and swallow_end:
                        swallow_end = False  # a stuck OpenOCD answers no later command either
                        continue
                    if not cmd.startswith("echo svd_probe_"):
                        self.log.append((conn_no, cmd))
                    mds += cmd.startswith("md")
                    out = self.script(conn_no, cmd, mds) if self.script else None
                    if out is None and cmd.startswith("mww "):
                        _, a, v = cmd.split()
                        self.mem[int(a, 16)] = int(v, 16) & self.write_mask.get(int(a, 16), 0xFFFFFFFF)
                    if out == EOF:
                        c.close()
                        break
                    if out == RESET:
                        c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                        c.close()
                        break
                    if out == HANG:
                        swallow_end = True
                        continue
                    if out is None and cmd.startswith("echo "):
                        out = cmd[5:]
                    if out is None:
                        out = self._md(cmd) if cmd.startswith("md") else self._targets() if cmd == "targets" else "pc (/64): 0x0000000008000010" if cmd == "reg pc" else ""
                    c.sendall(cmd.encode() + b"\r\n" + (out.encode() + b"\r\n" if out else b"") + b"> ")
                else:
                    continue
                break
            c.close()
        self.srv.close()

    def close(self) -> None:
        """Stop listening."""
        self.srv.close()


def make_svd(directory: Path, peripherals: dict[str, list[str]]) -> Path:
    """Write a small SVD. <peripherals> maps "NAME@0xBASE" to the XML of its registers."""
    body = ""
    for key, regs in peripherals.items():
        name, base = key.split("@")
        body += (f"<peripheral><name>{name}</name><baseAddress>{base}</baseAddress>"
                 f"<registers>{''.join(regs)}</registers></peripheral>")
    path = directory / "test.svd"
    path.write_text(f"<device><size>32</size><peripherals>{body}</peripherals></device>")
    return path


def reg(name: str, offset: int, reset: int | None = 0, mask: int | None = None, extra: str = "", size: int = 32) -> str:
    """XML of one register; reset None leaves <resetValue> out."""
    return (f"<register><name>{name}</name><addressOffset>0x{offset:X}</addressOffset><size>{size}</size>"
            + (f"<resetValue>0x{reset:X}</resetValue>" if reset is not None else "")
            + (f"<resetMask>0x{mask:X}</resetMask>" if mask is not None else "") + extra + "</register>")


def run(svd: Path, stub: Stub | None, *args: str, port: int | None = None, timeout: float = 60):
    """Run the tool; returns the completed process with text output."""
    cmd = [sys.executable, str(TOOL), "--svd", str(svd)]
    if stub or port:
        cmd += ["--port", str(port or stub.port)]
    return subprocess.run(cmd + list(args), capture_output=True, text=True, timeout=timeout)


def interrupt(svd: Path, stub: Stub, args: list[str], wait_for: str | None, again: float | None = None,
              limit: float = 20.0):
    """Start the tool, send SIGINT once <wait_for> (a command of the stub's log; None: the connection
    is accepted) has arrived, and a second one <again> seconds later. Returns (exit code, stdout,
    stderr, seconds from the last signal to the exit). The tool is killed after <limit> seconds."""
    cmd = [sys.executable, str(TOOL), "--svd", str(svd), "--port", str(stub.port)] + args
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if (wait_for is None and stub.accepted.is_set()) or (wait_for and stub.commands(wait_for)):
                break
            time.sleep(0.02)
        time.sleep(0.3)  # the tool is now blocked in recv
        p.send_signal(signal.SIGINT)
        sent = time.monotonic()
        if again is not None:
            time.sleep(again)
            p.send_signal(signal.SIGINT)
            sent = time.monotonic()
        try:
            out, err = p.communicate(timeout=limit)
        except subprocess.TimeoutExpired:
            p.kill()
            out, err = p.communicate()
            return -9, out, err, time.monotonic() - sent
        return p.returncode, out, err, time.monotonic() - sent
    finally:
        if p.poll() is None:
            p.kill()


def kinds(out: str) -> list[str]:
    """First word of each register line of the output."""
    return [line.split()[0] for line in out.splitlines() if line.startswith(("ok", "mismatch", "unreadable", "state",
                                                                            "noref", "skipped"))]


def test_dead_connection(tmp: Path) -> None:
    """A reset or closed connection aborts at once; nothing is read afterwards."""
    svd = make_svd(tmp, {"P1@0x1000": [reg("R0", 0), reg("R1", 4)],
                         "P2@0x2000": [reg("R0", 0), reg("R1", 4)],
                         "P3@0x3000": [reg("R0", 0), reg("R1", 4)],
                         "P4@0x4000": [reg("R0", 0)]})
    for how, label in ((RESET, "reset by peer"), (EOF, "end of file")):
        stub = Stub(script=lambda conn, cmd, n, how=how: how if conn == 0 and cmd.startswith("mdw 0x2000") else None)
        r = run(svd, stub, "--max-failures", "0")
        reads = stub.commands("md")
        check(f"dead connection ({label}): exit code 2", r.returncode == 2, f"{r.returncode}: {r.stdout!r} {r.stderr!r}")
        check(f"dead connection ({label}): names the register accessed last", "0x00002000" in r.stderr and "P2.R0" in r.stderr, r.stderr)
        check(f"dead connection ({label}): gives a hint at the cause", "bus error" in r.stderr and "--block 1" in r.stderr, r.stderr)
        check(f"dead connection ({label}): the reads before it are reported, none is reported as unreadable",
              kinds(r.stdout) == ["ok", "ok"], r.stdout)
        check(f"dead connection ({label}): no read after the dead one",
              reads == ["mdw 0x1000 2", "mdw 0x2000 2"], str(reads))
        check(f"dead connection ({label}): the hart is resumed over a new connection",
              stub.commands("resume", 1) == ["resume"] and not stub.commands("md", 1), str(stub.log))
        stub.close()


BUSY = "Timed out after 2s waiting for busy to go low (abstractcs=0x10001002). Increase the timeout with riscv set_command_timeout_sec."


def test_hang(tmp: Path) -> None:
    """A reply that says the debug module is stuck busy stops at once, tries one recovery and leaves the hart alone."""
    svd = make_svd(tmp, {"P1@0x1000": [reg("R0", 0)], "P2@0x2000": [reg("R0", 0), reg("R1", 4)],
                         "P3@0x3000": [reg("R0", 0)], "P4@0x4000": [reg("R0", 0)]})

    def hang_on_p2(reply, dmi=None):
        def script(conn, cmd, n):
            if cmd.startswith("mdw 0x2000"):
                return reply
            return dmi(cmd) if dmi else None
        return script

    # no recovery commands in OpenOCD: stop, whatever --keep-going and --max-failures say
    for reply, label in ((BUSY, "timed out"), ("Failed to read priv register.\n" + BUSY, "failed to read priv register"),
                         ("Abstract command ended in error 'busy' (abstractcs=0x10001102)", "abstractcs only")):
        stub = Stub(script=hang_on_p2(reply))
        r = run(svd, stub, "--keep-going", "--max-failures", "0")
        check(f"hang ({label}): exit code 2", r.returncode == 2, f"{r.returncode} {r.stdout!r} {r.stderr!r}")
        check(f"hang ({label}): names the register and the block, tells to power-cycle and to restart OpenOCD",
              "P2.R0" in r.stderr and "0x00002000" in r.stderr and "power-cycle" in r.stderr and "restart OpenOCD" in r.stderr, r.stderr)
        check(f"hang ({label}): the reply text is shown", reply.splitlines()[-1][:40] in r.stderr, r.stderr)
        check(f"hang ({label}): nothing is read after it", stub.commands("md") == ["mdw 0x1000 1", "mdw 0x2000 2"], str(stub.commands("md")))
        check(f"hang ({label}): the hart is not resumed", not stub.commands("resume"), str(stub.log))
        check(f"hang ({label}): it is no ordinary unreadable register", "unreadable" not in r.stdout, r.stdout)
        stub.close()
    # recovery commands exist, abstractcs stays busy
    stub = Stub(script=hang_on_p2(BUSY, lambda cmd: "0x10001002" if cmd == "riscv dmi_read 0x16" else None))
    r = run(svd, stub)
    check("hang, still busy: exit code 2 and no resume",
          r.returncode == 2 and not stub.commands("resume") and "still 0x10001002" in r.stderr, f"{r.returncode} {r.stderr!r} {stub.log}")
    check("hang, still busy: cmderr is cleared and abstractcs is read, once each",
          stub.commands("riscv dmi") == ["riscv dmi_write 0x16 0x700", "riscv dmi_read 0x16"], str(stub.log))
    stub.close()
    # recovery commands exist, abstractcs is idle afterwards: the register is unreadable, the run goes on
    stub = Stub(script=hang_on_p2(BUSY, lambda cmd: "0x00000002" if cmd == "riscv dmi_read 0x16" else None))
    r = run(svd, stub)
    check("hang, recovered: the register is reported as unreadable with the reply, the rest of the block is not read",
          r.returncode == 1 and "unreadable  0x00002000 P2.R0" in r.stdout and "Timed out" in r.stdout
          and stub.commands("md") == ["mdw 0x1000 1", "mdw 0x2000 2", "mdw 0x3000 1", "mdw 0x4000 1"], f"{r.returncode} {r.stdout!r} {stub.log}")
    check("hang, recovered: the hart is resumed", stub.commands("resume") == ["resume"], str(stub.log))
    stub.close()
    # commands unknown to OpenOCD
    stub = Stub(script=hang_on_p2(BUSY, lambda cmd: "invalid command name \"dmi_write\"" if cmd.startswith("riscv dmi") else None))
    r = run(svd, stub)
    check("hang, no recovery commands: stops without resume and says so",
          r.returncode == 2 and not stub.commands("resume") and "does not know" in r.stderr, f"{r.returncode} {r.stderr!r}")
    stub.close()
    # a block read that hangs: the block is named
    stub = Stub(script=hang_on_p2(BUSY))
    r = run(svd, stub)
    check("hang in a block: the message names the block of registers", "block of 2 registers from P2.R0" in r.stderr, r.stderr)
    stub.close()
    # a plain error text is still an ordinary unreadable register
    stub = Stub(script=lambda conn, cmd, n: "Error: bus error" if cmd.startswith("mdw 0x2000") else None)
    r = run(svd, stub)
    check("hang: other error texts stay unreadable registers", r.returncode == 1 and "unreadable  0x00002000" in r.stdout and stub.commands("resume"), r.stdout)
    stub.close()
    # the clock-enable writes
    stub = Stub(script=lambda conn, cmd, n: BUSY if cmd.startswith("mww") else None)
    svd2 = make_svd(tmp, {"SYSREG@0x5000": [reg("SUBBLK_CLOCK_CR", 0x84), reg("SOFT_RESET_CR", 0x88)]})
    r = run(svd2, stub, "--enable-clocks")
    check("hang in the clock writes: stops without resume", r.returncode == 2 and not stub.commands("resume") and "SUBBLK_CLOCK_CR" in r.stderr, f"{r.returncode} {r.stderr!r}")
    stub.close()


def test_noise(tmp: Path) -> None:
    """OpenOCD writes lines of its own, each followed by a prompt, while a hart does not halt: a prompt does
    not end a reply, and a reply is never taken for the one of the next command."""
    svd = make_svd(tmp, {"P1@0x1000": [reg("R0", 0, 7), reg("R1", 4, 9)]})
    noise = "".join(f"unable to halt hart {n}\r\n  dmcontrol=0x8001000{n}\r\n  dmstatus =0x00030c82\r\n> \r\n" for n in (1, 2))
    stub = Stub(script=lambda conn, cmd, n: noise + "0x00001000: 00000007 00000009" if cmd.startswith("mdw") else None)
    r = run(svd, stub)
    check("noise: prompts inside a reply do not end it and the noise lines are not values",
          r.returncode == 0 and "ok          0x00001000 P1.R0" in r.stdout
          and "ok          0x00001004 P1.R1" in r.stdout, f"{r.returncode} {r.stdout!r} {r.stderr!r}")
    stub.close()
    # the reply of a command that came late (after the noise) must not be taken for the next command
    table = ("    TargetName         Type       Endian TapName            State\r\n"
             "--  ------------------ ---------- ------ ------------------ ------------\r\n"
             " 0* mpfs.hart0_e51     riscv      little mpfs.cpu           halted")
    seen = []

    def late(conn, cmd, n):
        seen.append(cmd)
        if cmd == "targets" and seen.count("targets") == 1:
            return "> \r\nunable to halt hart 1\r\n> \r\n" + table
        return None
    stub = Stub(script=late)
    (tmp / "zero").mkdir()
    r = run(make_svd(tmp / "zero", {"P1@0x1000": [reg("R0", 0)]}), stub)
    check("noise: a reply that follows a prompt is still the reply of its command (the table says halted)",
          r.returncode == 0 and "ok          0x00001000 P1.R0" in r.stdout, f"{r.returncode} {r.stdout!r} {r.stderr!r}")
    stub.close()


def test_halt(tmp: Path) -> None:
    """The probe checks that the selected hart is halted; the other harts do not matter."""
    svd = make_svd(tmp, {"P1@0x1000": [reg("R0", 0)]})
    stub = Stub(state="running")
    r = run(svd, stub)
    check("halt: a hart that is not halted aborts with exit 2 and the OpenOCD table",
          r.returncode == 2 and "mpfs.hart0_e51 is not halted" in r.stderr and "running" in r.stderr, f"{r.returncode} {r.stderr!r}")
    check("halt: nothing is read from a hart that is not halted", not stub.commands("md"), str(stub.log))
    stub.close()
    stub = Stub(state="running")
    r = run(svd, stub, "--no-halt")
    check("halt: --no-halt checks too", r.returncode == 2 and not stub.commands("md") and not stub.commands("halt"), f"{r.returncode} {stub.log}")
    stub.close()
    stub = Stub(script=lambda conn, cmd, n: "unable to halt hart 1\nunable to halt hart 2" if cmd == "halt" else None)
    r = run(svd, stub)
    check("halt: failed halts of other harts give one note on stdout, the run goes on",
          r.returncode == 0 and r.stdout.count("other harts did not halt") == 1
          and "irrelevant for reads through mpfs.hart0_e51" in r.stdout, f"{r.returncode} {r.stdout!r} {r.stderr!r}")
    stub.close()
    stub = Stub(state="unknown", script=lambda conn, cmd, n: "unable to halt hart 0" if cmd == "halt" else None)
    r = run(svd, stub)
    check("halt: the halt reply is shown when the selected hart is not halted",
          r.returncode == 2 and "unable to halt hart 0" in r.stderr and "other harts did not halt" not in r.stdout, f"{r.returncode} {r.stdout!r} {r.stderr!r}")
    stub.close()
    stub = Stub()
    r = run(svd, stub)
    check("halt: a halted hart gives no note", r.returncode == 0 and "note" not in r.stdout, r.stdout)
    stub.close()


def test_power_state(tmp: Path) -> None:
    """One header line documents the state of the board before the first register line."""
    svd = make_svd(tmp, {"SYSREG@0x2000": [reg("DFIAPB_CR", 0x98), reg("CLOCK_CONFIG_CR", 0x08), reg("DEVICE_STATUS", 0x24),
                                           reg("PLL_STATUS_SR", 0x14C), reg("MSS_RESET_CR", 0x18), reg("SUBBLK_CLOCK_CR", 0x84),
                                           reg("SOFT_RESET_CR", 0x88)]})
    mem = {0x2098: 2, 0x2008: 0x10, 0x2024: 0x1009, 0x214C: 0x1234, 0x2018: 0x107}
    stub = Stub(mem=mem)
    r = run(svd, stub)
    header = [line for line in r.stdout.splitlines() if line.startswith("svd_probe: power state:")]
    check("power state: one header line with the five registers and the PC",
          header == ["svd_probe: power state: DFIAPB_CR=0x00000002 CLOCK_CONFIG_CR=0x00000010 DEVICE_STATUS=0x00001009 "
                     "PLL_STATUS_SR=0x00001234 MSS_RESET_CR=0x00000107 pc=0x0000000008000010"], f"{header} {r.stdout!r} {r.stderr!r}")
    check("power state: it comes before the first register line", r.stdout.index("power state") < r.stdout.index("ok  "), r.stdout)
    check("power state: the PC is read from the selected hart, after the halt",
          stub.commands("reg pc") == ["reg pc"] and [c for c in stub.commands("") if c in ("halt", "reg pc")] == ["halt", "reg pc"], str(stub.log))
    check("power state: it is a header, the summary still counts the registers only",
          "svd_probe: 7 register(s)," in r.stdout and kinds(r.stdout).count("mismatch") == 3, r.stdout)
    stub.close()
    # it shows the state before --enable-clocks writes
    stub = Stub(mem=mem)
    r = run(svd, stub, "--enable-clocks")
    order = [c.split()[0] for c in stub.commands("") if c.split()[:1] and c.split()[0] in ("reg", "mww")]
    check("power state: with --enable-clocks it is read before the first write", order[:3] == ["reg", "mww", "mww"], f"{order} {stub.log}")
    stub.close()
    # a SVD without SYSREG, and a read that fails
    (tmp / "p1").mkdir()
    svd2 = make_svd(tmp / "p1", {"P1@0x1000": [reg("R0", 0)]})
    stub = Stub()
    r = run(svd2, stub)
    check("power state: without SYSREG the header has the PC only", "svd_probe: power state: pc=0x0000000008000010" in r.stdout, r.stdout)
    stub.close()
    stub = Stub(mem=mem, script=lambda conn, cmd, n: "Error: bus error" if cmd.startswith("mdw 0x2024") else None)
    r = run(svd, stub, "--max-failures", "0")
    check("power state: an unreadable register is shown as such", "DEVICE_STATUS=unreadable(" in r.stdout and "PLL_STATUS_SR=0x00001234" in r.stdout, r.stdout)
    stub.close()
    stub = Stub(script=lambda conn, cmd, n: "" if cmd == "reg pc" else None)
    r = run(svd2, stub)
    check("power state: a PC that OpenOCD does not give is shown as ?", "pc=?" in r.stdout, r.stdout)
    stub.close()
    r = run(svd, None, "--list")
    check("power state: --list prints no header and needs no board", "power state" not in r.stdout and r.returncode == 0, r.stdout)


def test_enable_clocks(tmp: Path) -> None:
    """--enable-clocks reads the two registers back, prints them and warns where the readback is not what it should be."""
    field = lambda off: f"<field><name>F{off}</name><bitOffset>{off}</bitOffset><bitWidth>1</bitWidth></field>"
    fields = "<fields>" + "".join(field(i) for i in range(32) if i not in (31, 30, 17)) + "</fields>"
    svd = make_svd(tmp, {"SYSREG@0x2000": [reg("SUBBLK_CLOCK_CR", 0x84, reset=1, extra=fields), reg("SOFT_RESET_CR", 0x88, reset=0x3FFFFFFE)]})
    (tmp / "empty.list").write_text("# no rules\n")
    # the MPFS250T: bits 31, 30 and 17 do not read back 1, and that is no reason to warn
    stub = Stub(write_mask={0x2084: 0x3FFDFFFF})
    r = run(svd, stub, "--enable-clocks", "--skip-file", str(tmp / "empty.list"))
    check("clocks: with the usual readback the run goes on", r.returncode in (0, 1), f"{r.returncode} {r.stderr!r}")
    check("clocks: the readback is printed", "svd_probe: clocks enabled: SUBBLK_CLOCK_CR=0x3FFDFFFF SOFT_RESET_CR=0x00000000" in r.stdout, r.stdout)
    check("clocks: bits 31, 30 and 17 do not make a warning", "WARNING" not in r.stderr, r.stderr)
    check("clocks: the readback comes after the writes and before the first read",
          [c.split()[0] for c in stub.commands("") if c.split()[:1] and c.split()[0] in ("mww", "mdw")][:10] == ["mww"] * 8 + ["mdw", "mdw"], str(stub.log))
    check("clocks: the reference clock of CLINT.MTIME is set up after the two clock registers (hw/mss_init.py REFCLK)",
          [c for c in stub.commands("") if c.startswith("mww")][2:8] == [
              "mww 0x2000200C 0x7D", "mww 0x2000200C 0x1007D", "mww 0x37080008 0x8A080", "mww 0x20002098 0x1",
              "mww 0x200031BC 0x3800", "mww 0x20007C18 0xF00050CC"], str(stub.log))
    check("clocks: it says so", "reference clock set up (6 writes" in r.stdout, r.stdout)
    stub.close()
    # a clock bit that does not stick, and a peripheral that stays in reset
    stub = Stub(write_mask={0x2084: 0x3FF5FFFF, 0x2088: 0x00004000})
    stub.mem[0x2088] = 0x4000
    r = run(svd, stub, "--enable-clocks", "--skip-file", str(tmp / "empty.list"))
    check("clocks: a clock bit that reads back 0 is a warning that names the bits",
          "WARNING" in r.stderr and "SUBBLK_CLOCK_CR reads 0x3FF5FFFF" in r.stderr and "0x00080000" in r.stderr, r.stderr)
    check("clocks: the readback is printed anyway", "SUBBLK_CLOCK_CR=0x3FF5FFFF" in r.stdout, r.stdout)
    stub.close()
    # the write of 0 to SOFT_RESET_CR does not stick (the stand-in ignores the write)
    stub = Stub(mem={0x2088: 0x4000}, script=lambda conn, cmd, n: "" if cmd == "mww 0x2088 0x0" else None)
    r = run(svd, stub, "--enable-clocks", "--skip-file", str(tmp / "empty.list"))
    check("clocks: SOFT_RESET_CR that is not 0 is a warning", "SOFT_RESET_CR reads 0x00004000" in r.stderr and "still in reset" in r.stderr, r.stderr)
    check("clocks: SOFT_RESET_CR warning leaves the exit status to the registers", r.returncode in (0, 1), str(r.returncode))
    stub.close()
    # no warning, no readback line without --enable-clocks
    stub = Stub()
    r = run(svd, stub, "--skip-file", str(tmp / "empty.list"))
    check("clocks: nothing is written or printed without --enable-clocks", not stub.commands("mww") and "clocks enabled" not in r.stdout, str(stub.log))
    stub.close()
    # a SVD without fields: all bits are expected
    svd2dir = tmp / "nf"
    svd2dir.mkdir()
    svd2 = make_svd(svd2dir, {"SYSREG@0x2000": [reg("SUBBLK_CLOCK_CR", 0x84), reg("SOFT_RESET_CR", 0x88)]})
    stub = Stub(write_mask={0x2084: 0x3FFFFFFF})
    r = run(svd2, stub, "--enable-clocks", "--skip-file", str(tmp / "empty.list"))
    check("clocks: without fields in the SVD every bit is expected to read back 1", "SUBBLK_CLOCK_CR reads 0x3FFFFFFF" in r.stderr, r.stderr)
    stub.close()
    # the readback fails
    stub = Stub(script=lambda conn, cmd, n: "Error: bus error" if cmd.startswith("mdw 0x2084") else None)
    r = run(svd, stub, "--enable-clocks", "--skip-file", str(tmp / "empty.list"), "--max-failures", "0")
    check("clocks: a readback that fails is a warning", "SUBBLK_CLOCK_CR cannot be read back" in r.stderr, r.stderr)
    stub.close()


def test_reset_halt(tmp: Path) -> None:
    """--reset-halt sends "reset halt" before the halt and reports the PC; without it nothing is reset."""
    svd = make_svd(tmp, {"P1@0x1000": [reg("R0", 0)]})
    stub = Stub()
    r = run(svd, stub)
    check("reset-halt: without the option nothing is reset", not stub.commands("reset") and r.returncode == 0, str(stub.log))
    stub.close()
    stub = Stub(script=lambda conn, cmd, n: "pc (/64): 0x0000000000001000" if cmd == "reg pc" else None)
    r = run(svd, stub, "--reset-halt")
    cmds = [c for c in stub.commands("") if c]
    check("reset-halt: 'reset halt' comes after the target is selected and before the halt and the first read",
          cmds.index("reset halt") == cmds.index("targets mpfs.hart0_e51") + 1 and cmds.index("reset halt") < cmds.index("halt") < cmds.index("mdw 0x1000 1"), str(cmds))
    check("reset-halt: the PC after the reset is reported", "svd_probe: reset halt: mpfs.hart0_e51 is halted after the reset, pc=0x0000000000001000" in r.stdout, r.stdout)
    check("reset-halt: the run succeeds and reads the registers", r.returncode == 0 and kinds(r.stdout) == ["ok"], f"{r.returncode} {r.stdout!r}")
    stub.close()
    # the hart is not halted after the reset: the verification stops the run
    stub = Stub(state="running")
    r = run(svd, stub, "--reset-halt")
    check("reset-halt: a hart that is not halted afterwards aborts", r.returncode == 2 and not stub.commands("md") and "not halted" in r.stderr, f"{r.returncode} {r.stderr!r}")
    stub.close()
    # harts that do not halt are a note, as with the plain halt
    stub = Stub(script=lambda conn, cmd, n: "unable to halt hart 3" if cmd == "reset halt" else None)
    r = run(svd, stub, "--reset-halt")
    check("reset-halt: other harts that do not halt are one note", r.returncode == 0 and r.stdout.count("other harts did not halt") == 1, r.stdout)
    stub.close()
    # the connection dies in the reset
    stub = Stub(script=lambda conn, cmd, n: EOF if cmd == "reset halt" and conn == 0 else None)
    r = run(svd, stub, "--reset-halt")
    check("reset-halt: a lost connection is reported and the hart is resumed over a new one",
          r.returncode == 2 and "reset halt" in r.stderr and stub.commands("resume", 1) == ["resume"] and not stub.commands("md"), f"{r.returncode} {r.stderr!r} {stub.log}")
    stub.close()
    r = run(svd, None, "--reset-halt", "--no-halt")
    check("reset-halt: with --no-halt it is refused", r.returncode == 2 and "--no-halt" in r.stderr, f"{r.returncode} {r.stderr!r}")
    r = run(svd, None, "--help")
    check("reset-halt: --help says that it destroys the state", "--reset-halt" in r.stdout and "destroys the state" in " ".join(r.stdout.split()), r.stdout[:200])


def test_poke(tmp: Path) -> None:
    """--poke writes words through the session before the reads, echoes them, and fails safely."""
    svd = make_svd(tmp, {"SYSREG@0x2000": [reg("DFIAPB_CR", 0x98, reset=2), reg("SUBBLK_CLOCK_CR", 0x84), reg("SOFT_RESET_CR", 0x88)], "SCB_REGS@0x3000": [reg("MSSIO_CONTROL_CR", 0xBC, reset=0x7A0)],
                         "P1@0x1000": [reg("R0", 0)]})
    stub = Stub()
    r = run(svd, stub, "--poke", "SYSREG.DFIAPB_CR=0x1", "--poke", "0x30BC=0x3800", "--enable-clocks", "P1")
    writes = [c for c in stub.commands("") if c.startswith("mww")]
    check("poke: symbolic and numeric pokes are written in order, before the clock writes",
          writes[:4] == ["mww 0x2098 0x1", "mww 0x30BC 0x3800", "mww 0x2084 0xFFFFFFFF", "mww 0x2088 0x0"], str(stub.log))
    check("poke: each poke is echoed and followed by the readback",
          "poke 0x00002098 = 0x00000001  (SYSREG.DFIAPB_CR)\nreadback 0x00000001\npoke 0x000030BC = 0x00003800\nreadback 0x00003800\n" in r.stdout, r.stdout)
    check("poke: it comes after the halt and before the first read",
          (lambda c: c.index("halt") < c.index("mww 0x2098 0x1") < c.index("mdw 0x1000 1"))([x for x in stub.commands("") if x]), str(stub.log))
    stub.close()
    stub = Stub()
    r = run(svd, stub, "--poke", "SYSREG.DFIAPB_CR=0x1", "SYSREG")
    check("poke: the register that was poked is state (the probe wrote it), not a mismatch",
          "state       0x00002098 SYSREG.DFIAPB_CR = 0x00000001, reset 0x00000002" in r.stdout and "mismatch" not in r.stdout, r.stdout)
    stub.close()
    r = run(svd, Stub(), "--poke", "SYSREG.DFIAPB_CR=0x1", "--compare-state", "SYSREG")
    check("poke: --compare-state reports it as a mismatch again", "mismatch    0x00002098 SYSREG.DFIAPB_CR = 0x00000001" in r.stdout, r.stdout)
    stub = Stub(mem={0x2098: 7}, script=lambda conn, cmd, n: "" if cmd.startswith("mww 0x2098") else None)
    r = run(svd, stub, "--poke", "SYSREG.DFIAPB_CR=0x1", "P1")
    check("poke: the readback shows what the register holds, not what was written", "poke 0x00002098 = 0x00000001" in r.stdout and "readback 0x00000007" in r.stdout, r.stdout)
    stub.close()
    stub = Stub()
    r = run(svd, stub, "P1")
    check("poke: nothing is written without --poke", not stub.commands("mww") and "poke " not in r.stdout, str(stub.log))
    stub.close()
    # a write that stalls the debug module stops the run, and the hart is not resumed
    stub = Stub(script=lambda conn, cmd, n: BUSY if cmd.startswith("mww 0x30BC") else None)
    r = run(svd, stub, "--poke", "SYSREG.DFIAPB_CR=1", "--poke", "SCB_REGS.MSSIO_CONTROL_CR=0x3800", "P1")
    check("poke: a stall in the second poke aborts with exit 2, names the register, no resume, no read",
          r.returncode == 2 and "SCB_REGS.MSSIO_CONTROL_CR" in r.stderr and "power-cycle" in r.stderr and not stub.commands("resume")
          and not stub.commands("mdw 0x1000"), f"{r.returncode} {r.stderr!r} {stub.log}")
    stub.close()
    # a dead connection in a poke
    stub = Stub(script=lambda conn, cmd, n: EOF if cmd.startswith("mww 0x2098") and conn == 0 else None)
    r = run(svd, stub, "--poke", "SYSREG.DFIAPB_CR=1", "P1")
    check("poke: a lost connection aborts with exit 2 and the hart is resumed over a new one",
          r.returncode == 2 and not stub.commands("mdw 0x1000") and stub.commands("resume", 1) == ["resume"], f"{r.returncode} {r.stderr!r} {stub.log}")
    stub.close()
    # malformed arguments exit 2 before anything is sent
    for spec, why in (("SYSREG.DFIAPB_CR", "no ="), ("=1", "no register"), ("0x2098=xyz", "bad value"), ("0x2098=0x100000000", "too wide"),
                      ("0x2099=1", "unaligned"), ("SYSREG.NOPE=1", "unknown register"), ("NOPE.X=1", "unknown peripheral"), ("abc=1", "bad address")):
        stub = Stub()
        r = run(svd, stub, "--poke", spec, "P1")
        check(f"poke: {spec!r} ({why}) exits 2 and sends nothing", r.returncode == 2 and f"--poke {spec}" in r.stderr and not stub.log, f"{r.returncode} {r.stderr!r} {stub.log}")
        stub.close()
    r = run(svd, None, "--help")
    check("poke: --help documents it", "--poke ADDR=VALUE" in r.stdout and "PERIPHERAL.REGISTER" in r.stdout, r.stdout[:200])


def test_abort_output(tmp: Path) -> None:
    """An aborted run prints a partial summary and the cause on stdout, too; the counts of the skipped kinds stay apart."""
    svd = make_svd(tmp, {"P1@0x1000": [reg("R0", 0), reg("R1", 4)], "P2@0x2000": [reg("R0", 0), reg("R1", 4), reg("R2", 8)],
                         "P3@0x3000": [reg("R0", 0)], "P4@0x4000": [reg("R0", 0), reg("R1", 4)]})
    rules = tmp / "empty.list"
    rules.write_text("# no rules\n")

    def last_lines(out: str, n: int) -> list[str]:
        return out.rstrip("\n").splitlines()[-n:]

    # a dead connection in P2: counts so far, last register, the registers of P2 to P4 not reached
    stub = Stub(script=lambda conn, cmd, n: EOF if conn == 0 and cmd.startswith("mdw 0x2000") else None)
    r = run(svd, stub, "--skip-file", str(rules))
    check("abort output: the partial summary has the counts so far", "svd_probe: partial summary: 2 of 8 register(s) have a line, 0 not ok" in r.stdout, r.stdout)
    check("abort output: it names the last register accessed", "svd_probe: last register accessed: 0x00002000 P2.R0" in r.stdout, r.stdout)
    check("abort output: it counts what was not reached per peripheral", "svd_probe: not reached: P2 3, P3 1, P4 2 (6 register(s))" in r.stdout, r.stdout)
    cause = [line for line in r.stderr.splitlines() if line.startswith("svd_probe: the connection to OpenOCD is lost after 'mdw")][0]
    check("abort output: the cause is on stderr and the last lines of stdout", cause in last_lines(r.stdout, 3) and "connection to OpenOCD is lost" in cause, f"{r.stdout!r} {r.stderr!r}")
    check("abort output: the summary lines come before the cause", r.stdout.index("partial summary") < r.stdout.index("connection to OpenOCD is lost"), r.stdout)
    stub.close()
    # a hung debug module
    stub = Stub(script=lambda conn, cmd, n: BUSY if cmd.startswith("mdw 0x3000") else None)
    r = run(svd, stub, "--skip-file", str(rules))
    check("abort output: a hung debug module has the partial summary and the cause on stdout",
          "last register accessed: 0x00003000 P3.R0" in r.stdout and "not reached: P3 1, P4 2 (3 register(s))" in r.stdout
          and "power-cycle the board" in last_lines(r.stdout, 1)[0], r.stdout)
    stub.close()
    # too many unreadable registers
    stub = Stub(script=lambda conn, cmd, n: "Error: bus error" if cmd.startswith("md") else None)
    r = run(svd, stub, "--skip-file", str(rules), "--max-failures", "2")
    check("abort output: too many failures: partial summary and cause on stdout",
          "partial summary: 3 of 8 register(s) have a line, 3 not ok, 0 skipped" in r.stdout and "2 unreadable registers in a row" in last_lines(r.stdout, 1)[0], r.stdout)
    stub.close()
    # a hart that is not halted: nothing was read
    stub = Stub(state="running")
    r = run(svd, stub, "--skip-file", str(rules))
    check("abort output: not halted: nothing reached, cause last", "last register accessed: none" in r.stdout and "not reached: P1 2, P2 3, P3 1, P4 2 (8 register(s))" in r.stdout
          and "is not halted" in last_lines(r.stdout, 1)[0], r.stdout)
    stub.close()
    # Ctrl+C
    stub = Stub(script=lambda conn, cmd, n: HANG if cmd.startswith("mdw 0x2000") else None)
    rc, out, err, secs = interrupt(svd, stub, ["--skip-file", str(rules), "--timeout", "30"], "mdw 0x2000")
    check("abort output: Ctrl+C prints the partial summary and the interrupt line on stdout",
          rc == 130 and "partial summary: 2 of 8 register(s)" in out and "last register accessed: 0x00002000 P2.R0" in out
          and "svd_probe: interrupted;" in last_lines(out, 1)[0], f"{rc} {out!r}")
    stub.close()
    # a normal run has no partial summary
    stub = Stub()
    r = run(svd, stub, "--skip-file", str(rules))
    check("abort output: a complete run has none", r.returncode == 0 and "partial summary" not in r.stdout and "not reached" not in r.stdout, r.stdout)
    stub.close()
    # the three kinds of skipped lines are counted apart
    field = "<fields><field><name>F</name><readAction>clear</readAction></field></fields>"
    (tmp / "k").mkdir()
    svd2 = make_svd(tmp / "k", {"A@0x1000": [reg("R0", 0), reg("R1", 4, extra=field), reg("R2", 8)], "B@0x2000": [reg("R0", 0), reg("R1", 4), reg("R2", 8)],
                                "X@0x3000": [reg("R0", 0), reg("R1", 4)]})
    rules2 = tmp / "x.list"
    rules2.write_text("skip X not measured\n")
    stub = Stub(script=lambda conn, cmd, n: "Error: bus error" if cmd.startswith("mdw 0x2000") else None)
    r = run(svd2, stub, "--skip-file", str(rules2), "--block", "1")
    check("abort output: rule-excluded, readAction and not-reached registers have their own counts",
          "svd_probe: 6 register(s), 1 not ok, 2 skipped, 1 readAction, 0 DLAB, 0 hung, 0 noref, 0 state, 2 excluded" in r.stdout, r.stdout)
    stub.close()


class Board:
    """A stand-in board for the recovery: a first read of a "hang" address stalls the debug module (every md and mww
    answers with the busy text) until "reset halt" arrives; the reset restores the power-on values of SYSREG and
    forgets what was written. With fixed=False the reset does not help."""

    def __init__(self, hang=(0x2000,), fixed=True, dmi=True, toggle_fixes=False, clearable=False):
        self.hang, self.fixed, self.dmi, self.toggle_fixes, self.clearable = set(hang), fixed, dmi, toggle_fixes, clearable
        self.stuck = False
        self.toggled = False
        self.stub = None

    def reset_mem(self):
        self.stub.mem.clear()
        self.stub.mem.update({0x5084: 1, 0x5088: 0x3FFFFFFE})

    def script(self, conn, cmd, n):
        if cmd == "reset halt":
            if self.fixed or (self.toggle_fixes and self.toggled):
                self.stuck = False
                self.reset_mem()
            return ""
        if cmd.startswith("riscv dmi"):
            if not self.dmi:
                return 'invalid command name "dmi_read"'
            if cmd == "riscv dmi_write 0x10 0x1":
                self.toggled = True
            if cmd == "riscv dmi_write 0x16 0x700" and self.clearable:
                self.stuck = False  # clearing cmderr is enough: the debug module is idle again
            return ("0x10001002" if self.stuck else "0x00000102") if cmd == "riscv dmi_read 0x16" else ""
        if cmd.startswith(("mdw", "mww")):
            address = int(cmd.split()[1], 16)
            if self.stuck:
                return BUSY
            if cmd.startswith("mdw") and address in self.hang:
                self.hang.discard(address)
                self.stuck = True
                return BUSY
        return None


def board_svd(tmp: Path) -> Path:
    """P1, P2 (hangs), P3 (hangs when asked to) and SYSREG with the two registers the recovery checks."""
    (tmp / "b").mkdir(exist_ok=True)
    return make_svd(tmp / "b", {"P1@0x1000": [reg("R0", 0)], "P2@0x2000": [reg("R0", 0), reg("R1", 4)], "P3@0x3000": [reg("R0", 0)],
                                "P4@0x4000": [reg("R0", 0)],
                                "SYSREG@0x5000": [reg("SUBBLK_CLOCK_CR", 0x84, reset=1), reg("SOFT_RESET_CR", 0x88, reset=0x3FFFFFFE)]})


def test_recover(tmp: Path) -> None:
    """--recover resets the board after a stall and goes on; without it the run stops; ./x hw reset does the same sequence."""
    svd = board_svd(tmp)
    rules = tmp / "empty.list"
    rules.write_text("# no rules\n")
    common = ["--skip-file", str(rules), "--poke", "0x6000=0x5", "--enable-clocks", "--max-failures", "0"]

    def serve(**kw):
        board = Board(**kw)
        board.stub = Stub(script=board.script)
        board.reset_mem()
        return board

    # --recover: the sequence, the mark, the re-applied pokes and clocks, the rest of the run
    board = serve()
    r = run(svd, board.stub, "--recover", *common)
    log = [c for c in board.stub.commands("") if c]
    seq = [c for c in log if c.startswith("riscv dmi") or c == "reset halt"]
    check("recover: after the stall dmi_read, dmi_write 0x16 0x700 and reset halt are sent (the probe's own try comes first)",
          seq[-3:] == ["riscv dmi_read 0x16", "riscv dmi_write 0x16 0x700", "reset halt"], str(seq))
    check("recover: the peripheral is marked hung (recovered), its other register is not read",
          "hung (recovered)  0x00002000 P2.R0" in r.stdout and "mdw 0x2004 1" not in log and "mdw 0x2000 2" not in log[log.index("reset halt"):], r.stdout)
    check("recover: the run goes on with the next peripherals", "P3.R0" in r.stdout and "P4.R0" in r.stdout and board.stub.commands("resume") == ["resume"], r.stdout)
    after = log[log.index("reset halt"):]
    check("recover: the pokes and the clock writes are applied again after the reset", "mww 0x6000 0x5" in after and "mww 0x5084 0xFFFFFFFF" in after and "mww 0x5088 0x0" in after, str(after))
    check("recover: the hart is halted again before the reads (targets, set_prefer_sba)", "riscv set_prefer_sba off" in after, str(after))
    check("recover: every step prints the reply of OpenOCD",
          "recover: riscv dmi_read 0x16 -> '0x10001002'" in r.stdout and "recover: reset halt -> ''" in r.stdout and "recover: verify SYSREG.SUBBLK_CLOCK_CR" in r.stdout, r.stdout)
    check("recover: the summary counts the hung registers and the exit status is 1",
          r.returncode == 1 and "2 hung" in r.stdout and "svd_probe: 7 register(s)" in r.stdout and "svd_probe: --recover:" in r.stdout, f"{r.returncode} {r.stdout[-300:]!r}")
    check("recover: the power state is printed again after the recovery", "power state after the recovery:" in r.stdout, r.stdout)
    board.stub.close()
    # a hung peripheral alone makes the exit status 1
    board = serve()
    r = run(svd, board.stub, "--recover", "--skip-file", str(rules), "--skip", "SYSREG")
    check("recover: a recovered hang is not a clean run: exit status 1 although every register read is ok",
          r.returncode == 1 and "mismatch" not in r.stdout and "unreadable" not in r.stdout and "hung (recovered)" in r.stdout, f"{r.returncode} {r.stdout!r}")
    board.stub.close()
    # without --recover: stop, no resume, the advice names ./x hw reset
    board = serve()
    r = run(svd, board.stub, *common)
    check("recover: without --recover the run stops, does not reset and advises ./x hw reset",
          r.returncode == 2 and "reset halt" not in board.stub.commands("") and not board.stub.commands("resume") and "./x hw reset" in r.stderr
          and "power-cycle" in r.stderr, f"{r.returncode} {r.stderr!r}")
    board.stub.close()
    # the reset does not help: toggle, second reset halt, abort without resume
    board = serve(fixed=False)
    r = run(svd, board.stub, "--recover", *common)
    log = [c for c in board.stub.commands("") if c]
    check("recover: when the check fails the debug module is toggled and the reset halt repeated",
          "riscv dmi_write 0x10 0x0" in log and "riscv dmi_write 0x10 0x1" in log and log.count("reset halt") == 2, str(log))
    check("recover: when that fails too the run ends with 2, without resume, and says to power-cycle",
          r.returncode == 2 and not board.stub.commands("resume") and "power-cycle the board and restart OpenOCD" in r.stderr, f"{r.returncode} {r.stderr!r}")
    board.stub.close()
    # the toggle helps
    board = serve(fixed=False, toggle_fixes=True)
    r = run(svd, board.stub, "--recover", *common)
    check("recover: the toggle can fix it, the run goes on", r.returncode == 1 and "P4.R0" in r.stdout and "after toggling the debug module" in r.stdout, f"{r.returncode} {r.stdout[-400:]!r}")
    board.stub.close()
    # at most N recoveries
    board = serve(hang=(0x2000, 0x3000))
    r = run(svd, board.stub, "--recover", "--max-recoveries", "1", *common)
    check("recover: --max-recoveries N stops the second recovery with exit 2",
          r.returncode == 2 and board.stub.commands("reset halt") == ["reset halt"] and not board.stub.commands("resume") and "--max-recoveries" in r.stderr, f"{r.returncode} {r.stderr!r}")
    board.stub.close()
    board = serve(hang=(0x2000, 0x3000))
    r = run(svd, board.stub, "--recover", *common)
    check("recover: two stalls are recovered within the default limit", r.returncode == 1 and board.stub.commands("reset halt") == ["reset halt"] * 2 and "P4.R0" in r.stdout, f"{r.returncode} {r.stdout[-300:]!r}")
    board.stub.close()
    # a stall that clearing cmderr already cures: with --recover the board is reset all the same, without it the run goes on
    board = serve(clearable=True)
    r = run(svd, board.stub, "--recover", *common)
    check("recover: a debug module that is idle again after clearing cmderr is still reset with --recover",
          board.stub.commands("reset halt") == ["reset halt"] and "hung (recovered)  0x00002000 P2.R0" in r.stdout
          and "unreadable" not in r.stdout and "P4.R0" in r.stdout and r.returncode == 1, f"{r.returncode} {r.stdout[-500:]!r}")
    board.stub.close()
    board = serve(clearable=True)
    r = run(svd, board.stub, "--skip-file", str(rules), "--max-failures", "0", "--keep-going")
    check("recover: without --recover the same stall is one unreadable register and the run goes on, no reset",
          not board.stub.commands("reset halt") and "unreadable  0x00002000 P2.R0" in r.stdout and "P4.R0" in r.stdout, f"{r.returncode} {r.stdout[-500:]!r}")
    board.stub.close()
    # OpenOCD without the riscv dmi commands
    board = serve(dmi=False)
    r = run(svd, board.stub, "--recover", *common)
    check("recover: without riscv dmi_read it says so and still resets and verifies",
          "riscv dmi_read is not available" in r.stdout and "reset halt" in board.stub.commands("") and r.returncode == 1 and "P4.R0" in r.stdout, f"{r.returncode} {r.stdout[-400:]!r}")
    board.stub.close()

    # ./x hw reset and hw/reset.py
    lab_dir = tmp / "lab"
    lab_dir.mkdir()
    def lab_for(port: int) -> str:
        path = lab_dir / f"lab{port}.conf"
        path.write_text(f"OCD_HOST=127.0.0.1\nOCD_PORT={port}\n")
        return str(path)
    for how in ("hw/reset.py", "x hw reset"):
        board = Board(hang=())
        board.stub = Stub(script=board.script)
        board.reset_mem()
        board.stuck = True  # a hung debug module that nothing else has noticed
        cmd = ([sys.executable, str(TOOL.parent / "reset.py")] if how.endswith(".py") else [str(TOOL.parent.parent / "x"), "hw", "reset"])  # next to the tool: SVD_PROBE selects a copy
        proc = subprocess.run(cmd + ["--svd", str(svd), "--lab", lab_for(board.stub.port)], capture_output=True, text=True, timeout=60)
        check(f"reset ({how}): exit 0 when the verification passed, with every step on stdout",
              proc.returncode == 0 and "recover: riscv dmi_read 0x16 -> '0x10001002'" in proc.stdout and "recover: reset halt" in proc.stdout
              and "= 0x00000001, power-on value 0x00000001" in proc.stdout, f"{proc.returncode} {proc.stdout!r} {proc.stderr!r}")
        board.stub.close()
        board = Board(hang=(), fixed=False)
        board.stub = Stub(script=board.script)
        board.reset_mem()
        board.stub.mem[0x5084] = 0xFFFFFFFF
        proc = subprocess.run(cmd + ["--svd", str(svd), "--lab", lab_for(board.stub.port)], capture_output=True, text=True, timeout=60)
        check(f"reset ({how}): exit 2 when the verification fails, says to power-cycle",
              proc.returncode == 2 and "DIFFERS" in proc.stdout and "power-cycle the board and restart OpenOCD" in proc.stderr, f"{proc.returncode} {proc.stdout!r} {proc.stderr!r}")
        board.stub.close()
        proc = subprocess.run(cmd + ["--svd", str(svd), "--lab", lab_for(1)], capture_output=True, text=True, timeout=60)
        check(f"reset ({how}): no OpenOCD is exit 2", proc.returncode == 2 and "cannot connect" in proc.stderr, f"{proc.returncode} {proc.stderr!r}")
        proc = subprocess.run(cmd + ["--svd", str(tmp / "nope.svd"), "--lab", lab_for(1)], capture_output=True, text=True, timeout=60)
        check(f"reset ({how}): a missing SVD is exit 2", proc.returncode == 2 and "svd" in proc.stderr, f"{proc.returncode} {proc.stderr!r}")
    r = run(svd, None, "--help")
    check("recover: --help documents --recover and --max-recoveries", "--recover" in r.stdout and "--max-recoveries" in r.stdout and "./x hw reset" in r.stdout, r.stdout[:200])


def test_resume(tmp: Path) -> None:
    """A failed resume is reported and retried once over a new connection."""
    svd = make_svd(tmp, {"P1@0x1000": [reg("R0", 0)]})
    # the first connection dies on resume, the second one works
    stub = Stub(script=lambda conn, cmd, n: EOF if conn == 0 and cmd == "resume" else None)
    r = run(svd, stub)
    check("resume: a lost connection is retried once, and the run still succeeds", r.returncode == 0, f"{r.returncode} {r.stderr!r}")
    check("resume: the retry selects the hart before it resumes",
          [c for c in stub.commands("", 1) if c != ""][-2:] == ["targets mpfs.hart0_e51", "resume"], str(stub.log))
    check("resume: the retry is mentioned", "resumed mpfs.hart0_e51 over a new one" in r.stderr, r.stderr)
    stub.close()
    # the first connection dies on resume, there is no second one
    stub = Stub(script=lambda conn, cmd, n: EOF if cmd == "resume" else None, accept=1)
    r = run(svd, stub)
    check("resume: a failed resume exits non-zero", r.returncode == 2, f"{r.returncode} {r.stdout!r}")
    check("resume: a failed resume says that the hart is still halted", "still halted" in r.stderr and "could not resume" in r.stderr, r.stderr)
    stub.close()
    # no resume with --no-halt
    stub = Stub()
    r = run(svd, stub, "--no-halt")
    check("resume: --no-halt does not resume", r.returncode == 0 and not stub.commands("resume") and not stub.commands("halt"), str(stub.log))
    stub.close()


def test_interrupt(tmp: Path) -> None:
    """Ctrl+C stops at once, whatever OpenOCD does: exit 130, one short resume attempt, no traceback."""
    svd = make_svd(tmp, {"P1@0x1000": [reg("R0", 0), reg("R1", 4)], "P2@0x2000": [reg("R0", 0)],
                         "P3@0x3000": [reg("R0", 0)]})
    slow = ["--timeout", "30"]  # a wait for the socket timeout would show as 30 s

    def hang_on_p2(conn, cmd, n):
        return HANG if cmd.startswith("mdw 0x2000") else None

    # OpenOCD hangs on a read but still answers the resume
    stub = Stub(script=hang_on_p2)
    rc, out, err, secs = interrupt(svd, stub, slow, "mdw 0x2000")
    check("interrupt: exit code 130", rc == 130, f"{rc}: {out!r} {err!r}")
    check("interrupt: it stops within a few seconds, not after the socket timeout", secs < 5, f"{secs:.1f} s")
    check("interrupt: one line says that it was interrupted", err.count("svd_probe: interrupted (Ctrl+C), stopping") == 1, err)
    check("interrupt: no traceback", "Traceback" not in err and "KeyboardInterrupt" not in err, err)
    check("interrupt: the hart is resumed once, over the same connection",
          stub.commands("resume") == ["resume"] and stub.commands("resume", 0) == ["resume"] and "the hart was resumed" in err,
          f"{stub.log} {err!r}")
    check("interrupt: what was read before is still on stdout, with a summary of it on stderr",
          kinds(out) == ["ok", "ok"] and "of 4 register(s) selected, 0 not ok" in err, f"{out!r} {err!r}")
    stub.close()

    # OpenOCD hangs on the resume as well: the attempt is short and the hart is said to be halted
    stub = Stub(script=lambda conn, cmd, n: HANG if cmd.startswith("mdw 0x2000") or cmd == "resume" else None)
    rc, out, err, secs = interrupt(svd, stub, slow, "mdw 0x2000")
    check("interrupt, resume hangs: exit code 130", rc == 130, f"{rc}: {out!r} {err!r}")
    check("interrupt, resume hangs: gives up after the short timeout", 1.5 < secs < 6, f"{secs:.1f} s")
    check("interrupt, resume hangs: says the hart may still be halted", "may still be halted" in err and "resume" in err, err)
    check("interrupt, resume hangs: no retry and no new connection",
          stub.commands("resume") == ["resume"] and {n for n, _ in stub.log} == {0}, str(stub.log))
    check("interrupt, resume hangs: no traceback", "Traceback" not in err, err)
    stub.close()

    # a second Ctrl+C during that cleanup leaves at once
    stub = Stub(script=lambda conn, cmd, n: HANG if cmd.startswith("mdw 0x2000") or cmd == "resume" else None)
    rc, out, err, secs = interrupt(svd, stub, slow, "mdw 0x2000", again=0.5)
    check("interrupt twice: exit code 130", rc == 130, f"{rc}: {out!r} {err!r}")
    check("interrupt twice: leaves at once after the second one (before the resume timeout)", secs < 1.0, f"{secs:.1f} s")
    check("interrupt twice: no traceback, says the hart may still be halted",
          "Traceback" not in err and "interrupted again" in err and "may still be halted" in err, err)
    stub.close()

    # --no-halt: nothing was halted, so nothing is resumed
    stub = Stub(script=hang_on_p2)
    rc, out, err, secs = interrupt(svd, stub, slow + ["--no-halt"], "mdw 0x2000")
    check("interrupt, --no-halt: exit 130, no resume, says so",
          rc == 130 and not stub.commands("resume") and "not halted by this run" in err, f"{rc} {stub.log} {err!r}")
    stub.close()

    # OpenOCD accepts the connection and never answers, not even with the banner
    stub = Stub(banner=False)
    rc, out, err, secs = interrupt(svd, stub, slow, None)
    check("interrupt while connecting: exit 130 within a few seconds, no traceback",
          rc == 130 and secs < 5 and "Traceback" not in err and "interrupted while connecting" in err, f"{rc} {secs:.1f} s {err!r}")
    stub.close()

    # the connection resets while the tool is in the cleanup after the interrupt
    stub = Stub(script=lambda conn, cmd, n: HANG if cmd.startswith("mdw 0x2000") else (EOF if cmd == "resume" else None))
    rc, out, err, secs = interrupt(svd, stub, slow, "mdw 0x2000")
    check("interrupt, resume fails: exit 130, no reconnect, no traceback",
          rc == 130 and "may still be halted" in err and "Traceback" not in err and {n for n, _ in stub.log} == {0}, f"{rc} {err!r} {stub.log}")
    stub.close()


def test_failures(tmp: Path) -> None:
    """The reply text is shown; a number of unreadable registers in a row aborts."""
    periphs = {f"P{i}@0x{i}000": [reg("R0", 0), reg("R1", 4)] for i in range(1, 7)}
    svd = make_svd(tmp, periphs)
    stub = Stub(script=lambda conn, cmd, n: "Error: bus error 0xdead" if cmd.startswith("md") else None)
    r = run(svd, stub)
    check("failures: aborts after 3 unreadable registers in a row (exit 2)", r.returncode == 2, f"{r.returncode} {r.stderr!r}")
    check("failures: the abort names the number and the last register", "3 unreadable registers in a row" in r.stderr and "P3.R0" in r.stderr, r.stderr)
    check("failures: the OpenOCD reply text is shown", "Error: bus error 0xdead" in r.stdout, r.stdout)
    check("failures: no read after the abort", "mdw 0x4000 2" not in stub.commands("md"), str(stub.commands("md")))
    stub.close()
    stub = Stub(script=lambda conn, cmd, n: "Error: bus error" if cmd.startswith("md") else None)
    r = run(svd, stub, "--max-failures", "0")
    check("failures: --max-failures 0 never aborts", r.returncode == 1 and kinds(r.stdout).count("unreadable") >= 6, f"{r.returncode} {r.stdout!r}")
    stub.close()
    stub = Stub(script=lambda conn, cmd, n: "Error: bus error" if cmd.startswith("md") else None)
    r = run(svd, stub, "--max-failures", "2")
    check("failures: --max-failures N sets the limit", r.returncode == 2 and "2 unreadable registers in a row" in r.stderr, r.stderr)
    stub.close()
    # a good read in between resets the count: P1, P3 and P5 fail, the others are readable
    stub = Stub(script=lambda conn, cmd, n: "Error: bus error" if cmd.startswith("md") and re.search(r"0x[135]000", cmd) else None)
    r = run(svd, stub)
    check("failures: a successful read resets the count", r.returncode == 1 and "unreadable" in r.stdout and kinds(r.stdout).count("ok") >= 6,
          f"{r.returncode} {r.stdout!r}")
    stub.close()


def test_block(tmp: Path) -> None:
    """--block limits the registers per command, for all or for matching peripherals."""
    svd = make_svd(tmp, {"BIG@0x1000": [reg(f"R{i}", 4 * i) for i in range(6)],
                         "SMALL@0x2000": [reg(f"R{i}", 4 * i) for i in range(6)]})
    stub = Stub()
    r = run(svd, stub)
    check("block: by default a peripheral is read with one command", r.returncode == 0 and stub.commands("md") == ["mdw 0x1000 6", "mdw 0x2000 6"],
          str(stub.commands("md")))
    stub.close()
    stub = Stub()
    r = run(svd, stub, "--block", "4")
    check("block: --block N splits long blocks", stub.commands("md") == ["mdw 0x1000 4", "mdw 0x1010 2", "mdw 0x2000 4", "mdw 0x2010 2"],
          str(stub.commands("md")))
    stub.close()
    stub = Stub()
    r = run(svd, stub, "--block", "BIG=2")
    check("block: --block PATTERN=N limits only the matching peripherals",
          stub.commands("md") == ["mdw 0x1000 2", "mdw 0x1008 2", "mdw 0x1010 2", "mdw 0x2000 6"], str(stub.commands("md")))
    stub.close()
    # block rules of the rules file: a default per peripheral
    rules = tmp / "block.list"
    rules.write_text("block big 4 never measured cleanly\nblock NOPE* 2 matches nothing\n")
    stub = Stub()
    r = run(svd, stub, "--skip-file", str(rules))
    check("block rule: a peripheral that a rule names is read in small blocks, others with the global default (case does not matter)",
          stub.commands("md") == ["mdw 0x1000 4", "mdw 0x1010 2", "mdw 0x2000 6"], str(stub.commands("md")))
    stub.close()
    stub = Stub()
    r = run(svd, stub, "--skip-file", str(rules), "--block", "BIG=2")
    check("block rule: --block PATTERN=N overrides the rule", stub.commands("md") == ["mdw 0x1000 2", "mdw 0x1008 2", "mdw 0x1010 2", "mdw 0x2000 6"], str(stub.commands("md")))
    stub.close()
    stub = Stub()
    r = run(svd, stub, "--skip-file", str(rules), "--block", "1")
    check("block rule: a plain --block N overrides the rule, so --block 1 reads one by one",
          len(stub.commands("md")) == 12 and all(c.endswith(" 1") for c in stub.commands("md")), str(stub.commands("md")))
    stub.close()
    stub = Stub()
    r = run(svd, stub, "--skip-file", str(rules), "--block", "SMALL=3")
    check("block rule: a PATTERN=N for another peripheral leaves the rule in place",
          stub.commands("md") == ["mdw 0x1000 4", "mdw 0x1010 2", "mdw 0x2000 3", "mdw 0x200C 3"], str(stub.commands("md")))
    stub.close()
    for bad_line in ("block BIG 0 zero\n", "block BIG x why\n", "block BIG 4\n", "block BIG\n"):
        bad = tmp / "badblock.list"
        bad.write_text(bad_line)
        r = run(svd, None, "--skip-file", str(bad), "--list")
        check(f"block rule: {bad_line.strip()!r} is a malformed rule", r.returncode == 2 and "badblock.list:1" in r.stderr, f"{r.returncode} {r.stderr!r}")
    if REAL_SVD.is_file():
        stub = Stub()
        r = run(REAL_SVD, stub, "CRYPTO", "CFG_DDR_SGMII_PHY", "GEM_A_LO")
        counts = {}
        for c in stub.commands("md"):
            addr, n = int(c.split()[1], 16), int(c.split()[2])
            counts.setdefault("CRYPTO" if 0x20127000 <= addr < 0x20128000 else "GEM" if 0x20110000 <= addr < 0x20111000 else "PHY" if 0x20007000 <= addr < 0x20008000 else "?", []).append(n)
        check("block rule: the default rules read CRYPTO and GEM in blocks of at most 16 and CFG_DDR_SGMII_PHY in longer ones",
              max(counts.get("CRYPTO", [99])) <= 16 and max(counts.get("GEM", [99])) <= 16 and max(counts.get("PHY", [0])) > 16, str(counts))
        stub.close()
        rules_text = (TOOL.parent / "svd_probe.list").read_text()
        check("block rule: the rules file has block rules for the peripherals that were never measured cleanly",
              all(f"block {name} " in rules_text for name in ("CAN_*", "GEM_*", "USB", "QSPIXIP", "CRYPTO")), "")
        r = run(REAL_SVD, None, "--help")
        check("block rule: --help says that rules set the default block", "block" in r.stdout and "rules file" in r.stdout, "")
    r = run(svd, None, "--block", "0")
    check("block: --block 0 is refused", r.returncode != 0 and "--block 0" in r.stderr, r.stderr)


def test_read_action(tmp: Path) -> None:
    """Registers with a readAction are not read unless --read-destructive says so."""
    field = "<fields><field><name>F</name><readAction>clear</readAction></field></fields>"
    svd = make_svd(tmp, {"P1@0x1000": [reg("R0", 0), reg("R1", 4, extra=field), reg("R2", 8, extra="<readAction>modifyExternal</readAction>"),
                                       reg("R3", 12), reg("R4", 16, extra="<readAction>none</readAction>")]})
    stub = Stub()
    r = run(svd, stub)
    lines = [line for line in r.stdout.splitlines() if line.startswith("skipped (readAction)")]
    check("readAction: registers with a readAction (register or field level) are not read",
          stub.commands("md") == ["mdw 0x1000 1", "mdw 0x100C 2"], str(stub.commands("md")))
    check("readAction: each gets its own status line", len(lines) == 2 and "P1.R1" in lines[0] and "P1.R2" in lines[1], r.stdout)
    check("readAction: the status lines sit between the others, in address order",
          [l.split()[2] if l.startswith("ok") else "S" for l in r.stdout.splitlines()[1:6]] == ["P1.R0", "S", "S", "P1.R3", "P1.R4"],
          r.stdout)
    check("readAction: skipped registers are no failure and are counted apart",
          r.returncode == 0 and "2 readAction" in r.stdout and "0 not ok" in r.stdout and "0 skipped," in r.stdout, f"{r.returncode} {r.stdout!r}")
    stub.close()
    stub = Stub()
    r = run(svd, stub, "--read-destructive")
    check("readAction: --read-destructive reads them, in one block", stub.commands("md") == ["mdw 0x1000 5"], str(stub.commands("md")))
    check("readAction: --read-destructive warns", "WARNING" in r.stderr and "2 register(s)" in r.stderr, r.stderr)
    check("readAction: --read-destructive leaves no status line for them", "readAction)" not in r.stdout, r.stdout)
    stub.close()
    r = run(svd, None, "--list")
    check("readAction: --list shows the readAction", r.stdout.count("readAction clear") == 1 and r.stdout.count("readAction modifyExternal") == 1, r.stdout)
    if REAL_SVD.is_file():
        r = run(REAL_SVD, None, "--list", "--include", "CAN_A_LO")
        names = {line.split()[2] for line in r.stdout.splitlines() if "readAction" in line}
        want = {"PLIC.CLAIM_COMPLETE_H0_M", "MMUART0_LO.RBR", "SPI_A_LO.RX_DATA", "CAN_A_LO.RX_MSG0_DATA_LOW", "USB.FIFO[0]",
                "QSPIXIP.ReceiveData", "SCB_REGS.MESSAGE", "USB.USB_IRQ", "USB.DMA_INTR"}
        check("readAction: the merged SVD marks the known destructive registers", want <= names, str(sorted(want - names)))


def test_dlab(tmp: Path) -> None:
    """DLR and DMR of an MMUART are not read while LCR.DLAB is 0 (aliases of RBR and IER); THR and FCR never (a read pops the FIFO)."""
    regs = [reg("RBR", 0x00), reg("IER", 0x04), reg("LCR", 0x0C), reg("MSR", 0x18), reg("DLR", 0x80, reset=1), reg("DMR", 0x84),
            reg("THR", 0x100), reg("FCR", 0x108, reset=0xC1)]
    svd = make_svd(tmp, {"MMUART0_LO@0x2000": regs, "OTHER@0x3000": [reg("DLR", 0), reg("THR", 4)]})
    rules = tmp / "empty.list"
    rules.write_text("# no rules\n")
    stub = Stub(mem={0x2000 + 0x0C: 0x03, 0x2080: 0x55, 0x2084: 0x56, 0x2100: 0x66, 0x2108: 0xC1})
    r = run(svd, stub, "--skip-file", str(rules))
    reads = stub.commands("md")
    check("dlab: LCR is the first access to the MMUART", reads[0] == "mdw 0x200C 1", str(reads))
    check("dlab: DLR and DMR are not read while DLAB is 0, THR and FCR are never read",
          not any(c.split()[1] in ("0x2080", "0x2084", "0x2100", "0x2108") or c.startswith("mdw 0x2000 ") and int(c.split()[2]) > 32 for c in reads), str(reads))
    check("dlab: the lines say so, with the reason, in address order",
          "skipped (DLAB=0)  0x00002080 MMUART0_LO.DLR (alias of RBR/IER while DLAB=0; reads DLL/DLM only with DLAB=1" in r.stdout
          and "skipped (DLAB=0)  0x00002084 MMUART0_LO.DMR (alias of RBR/IER while DLAB=0" in r.stdout
          and "skipped (alias of RBR/IIR)  0x00002100 MMUART0_LO.THR (THR reads RBR, FCR reads IIR" in r.stdout
          and "skipped (alias of RBR/IIR)  0x00002108 MMUART0_LO.FCR" in r.stdout
          and r.stdout.index("MMUART0_LO.MSR") < r.stdout.index("MMUART0_LO.DLR") < r.stdout.index("MMUART0_LO.DMR")
          < r.stdout.index("MMUART0_LO.THR") < r.stdout.index("MMUART0_LO.FCR"), r.stdout)
    check("dlab: the other registers are read, a register of another peripheral with the same name too",
          kinds(r.stdout).count("ok") + kinds(r.stdout).count("mismatch") == 6, f"{kinds(r.stdout)} {r.stdout!r}")
    check("dlab: DLAB and alias skips are counted apart", "2 DLAB" in r.stdout and "2 readAction" in r.stdout, r.stdout)
    check("dlab: no failure, nothing counted as not reached", r.returncode in (0, 1) and "0 skipped," in r.stdout, r.stdout)
    stub.close()
    # DLAB is 1: everything is read
    stub = Stub(mem={0x200C: 0x83, 0x2080: 1})
    r = run(svd, stub, "--skip-file", str(rules))
    check("dlab: with DLAB=1 DLR and DMR are read, THR and FCR still not", "skipped (DLAB=0)" not in r.stdout
          and "ok          0x00002080 MMUART0_LO.DLR = 0x00000001" in r.stdout and "MMUART0_LO.THR =" not in r.stdout
          and "skipped (alias of RBR/IIR)  0x00002100 MMUART0_LO.THR" in r.stdout, f"{stub.commands('md')} {r.stdout!r}")
    stub.close()
    # --read-destructive reads them anyway
    stub = Stub(mem={0x200C: 0x03})
    r = run(svd, stub, "--skip-file", str(rules), "--read-destructive")
    check("dlab: --read-destructive reads DLR, DMR, THR and FCR with DLAB=0", "skipped (DLAB=0)" not in r.stdout and "alias of RBR/IIR" not in r.stdout
          and "MMUART0_LO.THR =" in r.stdout and "MMUART0_LO.FCR =" in r.stdout and "MMUART0_LO.DMR =" in r.stdout, r.stdout)
    stub.close()
    # an unreadable LCR does not make up a DLAB value
    stub = Stub(script=lambda conn, cmd, n: "Error: bus error" if cmd == "mdw 0x200C 1" else None)
    r = run(svd, stub, "--skip-file", str(rules), "--max-failures", "0")
    check("dlab: an unreadable LCR is no DLAB=0", "skipped (DLAB=0)" not in r.stdout, r.stdout)
    stub.close()
    if REAL_SVD.is_file():
        stub = Stub()
        r = run(REAL_SVD, stub, "MMUART1_LO")
        check("dlab: the merged SVD gives LCR first, skips DLR and DMR while DLAB is 0 and never reads the write-only THR and FCR",
              [c for c in stub.commands("md") if c.startswith("mdw 0x2010")][0] == "mdw 0x2010000C 1" and r.stdout.count("skipped (DLAB=0)") == 2 and r.stdout.count("skipped (alias of RBR/IIR)") + r.stdout.count("skipped (write-only)") == 2, r.stdout[:300])
        stub.close()


def test_write_only(tmp: Path) -> None:
    """A register that the SVD marks write-only is never read."""
    svd = make_svd(tmp, {"P1@0x1000": [reg("R0", 0), reg("WO", 4, extra="<access>write-only</access>"), reg("R2", 8),
                                       reg("RW", 12, extra="<access>read-write</access>")]})
    for extra in ((), ("--read-destructive",)):
        stub = Stub()
        r = run(svd, stub, *extra)
        check(f"write-only{' with ' + extra[0] if extra else ''}: the register is not read and the line says so",
              not any(c.split()[1] == "0x1004" for c in stub.commands("md")) and "skipped (write-only)  0x00001004 P1.WO" in r.stdout
              and kinds(r.stdout).count("ok") == 3 and stub.commands("md")[0] == "mdw 0x1000 1", f"{stub.commands('md')} {r.stdout!r}")
        check(f"write-only{' with ' + extra[0] if extra else ''}: counted with the registers that are not read, no failure",
              r.returncode == 0 and "1 readAction" in r.stdout and "0 skipped," in r.stdout, r.stdout)
        stub.close()


def test_identical(tmp: Path) -> None:
    """Many identical nonzero reads that are not the reset value say that the block does not respond."""
    svd = make_svd(tmp, {"GATED@0x1000": [reg(f"R{i}", 4 * i, reset=0) for i in range(12)],
                         "NOREF@0x6000": [reg(f"R{i}", 4 * i, reset=None) for i in range(12)],
                         "SAME0@0x2000": [reg(f"R{i}", 4 * i) for i in range(12)],
                         "RESET@0x3000": [reg(f"R{i}", 4 * i, reset=0xA8148A) for i in range(12)],
                         "FEW@0x4000": [reg(f"R{i}", 4 * i) for i in range(8)],
                         "MIXED@0x5000": [reg(f"R{i}", 4 * i) for i in range(12)]})
    mem = {**{0x1000 + 4 * i: 0xA8148A for i in range(12)}, **{0x3000 + 4 * i: 0xA8148A for i in range(12)},
           **{0x4000 + 4 * i: 7 for i in range(8)}, **{0x6000 + 4 * i: 7 for i in range(12)}, **{0x5000 + 4 * i: i % 3 + 1 for i in range(12)}}
    stub = Stub(mem=mem)
    r = run(svd, stub)
    notes = [line for line in r.stdout.splitlines() if "identical reads" in line]
    check("identical: 12 identical nonzero reads of a block give one note, naming the block, the count and the value",
          len(notes) == 1 and notes[0] == "svd_probe: note: GATED: 12 registers read 0xA8148A, identical reads: block probably not responding (clock/reset?)",
          f"{notes} {r.stdout!r}")
    check("identical: zeros, matching reset values, 8 reads (not more than 8), mixed values and registers without a reference (a PLIC that powers up with random priorities) give no note", len(notes) == 1, str(notes))
    check("identical: the note is no register line and no failure of its own", "svd_probe: 68 register(s)," in r.stdout, r.stdout[-200:])
    stub.close()
    stub = Stub(mem=mem)
    r = run(svd, stub, "--identical-reads", "7")
    check("identical: --identical-reads N sets the limit (8 identical reads are more than 7)", "FEW: 8 registers read 0x7" in r.stdout, r.stdout)
    stub.close()
    stub = Stub(mem=mem)
    r = run(svd, stub, "--identical-reads", "0")
    check("identical: --identical-reads 0 switches the note off", "identical reads" not in r.stdout, r.stdout)
    stub.close()


def test_noref(tmp: Path) -> None:
    """A register without reference value is reported as noref, not as mismatch."""
    svd = make_svd(tmp, {"P1@0x1000": [reg("NORESET", 0, reset=None), reg("NOMASK", 4, reset=5, mask=0), reg("OK", 8, reset=0),
                                       reg("BAD", 12, reset=1), reg("PARTIAL", 16, reset=0x10, mask=0xF0)]})
    stub = Stub(mem={0x1000: 0x77, 0x1004: 9, 0x100C: 0, 0x1010: 0x1F})
    r = run(svd, stub)
    check("noref: no resetValue gives noref with the value read", "noref       0x00001000 P1.NORESET = 0x00000077 (no resetValue)" in r.stdout, r.stdout)
    check("noref: a resetMask of 0 gives noref", "noref       0x00001004 P1.NOMASK = 0x00000009 (resetMask is 0)" in r.stdout, r.stdout)
    check("noref: a missing resetValue is not 0", "mismatch    0x00001000" not in r.stdout and "mismatch    0x00001004" not in r.stdout, r.stdout)
    check("noref: real mismatches and the mask still count", kinds(r.stdout) == ["noref", "noref", "ok", "mismatch", "ok"], r.stdout)
    check("noref: counted apart, only the mismatch fails", r.returncode == 1 and "1 not ok" in r.stdout and "2 noref" in r.stdout, f"{r.returncode} {r.stdout!r}")
    stub.close()
    svd = make_svd(tmp, {"P1@0x1000": [reg("NORESET", 0, reset=None)]})
    stub = Stub(mem={0x1000: 3})
    r = run(svd, stub)
    check("noref: alone it is no failure", r.returncode == 0, f"{r.returncode} {r.stdout!r}")
    stub.close()
    r = run(svd, None, "--list")
    check("noref: --list shows that there is no reset value", "reset none" in r.stdout, r.stdout)
    if REAL_SVD.is_file():
        r = run(REAL_SVD, None, "--list", "CLINT", "USB")
        check("noref: the merged SVD has no reference for CLINT MTIME and the USB registers",
              "CLINT.MTIME reset none" in r.stdout and "USB.USB_IRQ reset none" in r.stdout, r.stdout[:300])


def test_state(tmp: Path) -> None:
    """Registers that hold runtime state are reported as state, unless --compare-state says otherwise."""
    rules = tmp / "rules.list"
    rules.write_text("# test rules\nstate P1.*STATUS* status register\nstate p1.TX_MSG* message RAM, case does not matter\n"
                     "state-enable-clocks SYSREG.SUBBLK_CLOCK_CR written by the tool\n")
    svd = make_svd(tmp, {"P1@0x1000": [reg("A_STATUS", 0), reg("TX_MSG0", 4), reg("PLAIN", 8), reg("B_STATUS", 12)],
                         "SYSREG@0x2000": [reg("SUBBLK_CLOCK_CR", 0, reset=1), reg("SOFT_RESET_CR", 4, reset=0xFF)]})
    mem = {0x1000: 5, 0x1004: 6, 0x1008: 7, 0x100C: 0, 0x2000: 0xFFFFFFFF, 0x2004: 0}
    stub = Stub(mem=mem)
    r = run(svd, stub, "--skip-file", str(rules), "P1")
    check("state: a differing register that matches a rule is state, others are mismatch",
          kinds(r.stdout) == ["state", "state", "mismatch", "ok"], r.stdout)
    check("state: the reason is shown", "status register" in r.stdout and "message RAM" in r.stdout, r.stdout)
    check("state: only the mismatch fails; state is counted apart", r.returncode == 1 and "1 not ok" in r.stdout and "2 state" in r.stdout,
          f"{r.returncode} {r.stdout!r}")
    check("state: a register that has its reset value is ok, even if it matches a rule", "ok          0x0000100C P1.B_STATUS = 0x00000000" in r.stdout, r.stdout)
    check("state: the state and mismatch lines show the value read, as wide as the register",
          "state       0x00001000 P1.A_STATUS = 0x00000005, reset 0x00000000 (mask 0xFFFFFFFF); status register" in r.stdout
          and "mismatch    0x00001008 P1.PLAIN = 0x00000007, expected 0x00000000 (mask 0xFFFFFFFF)" in r.stdout, r.stdout)
    stub.close()
    stub = Stub(mem={0x1000: 5, 0x1004: 6, 0x1008: 0, 0x100C: 0})
    r = run(svd, stub, "--skip-file", str(rules), "P1")
    check("state: with state only the run succeeds", r.returncode == 0 and "2 state" in r.stdout, f"{r.returncode} {r.stdout!r}")
    stub.close()
    stub = Stub(mem={0x1000: 5, 0x1004: 6, 0x1008: 0, 0x100C: 0})
    r = run(svd, stub, "--skip-file", str(rules), "--compare-state", "P1")
    check("state: --compare-state reports them as mismatch", r.returncode == 1 and kinds(r.stdout) == ["mismatch", "mismatch", "ok", "ok"], f"{r.returncode} {r.stdout!r}")
    stub.close()
    stub = Stub(mem=mem)
    r = run(svd, stub, "--skip-file", str(rules), "SYSREG")
    check("state: a state-enable-clocks rule does not apply without --enable-clocks", kinds(r.stdout) == ["mismatch", "mismatch"], r.stdout)
    stub.close()
    stub = Stub(mem=mem)
    r = run(svd, stub, "--skip-file", str(rules), "--enable-clocks", "SYSREG")
    check("state: with --enable-clocks the registers the tool wrote are state", kinds(r.stdout) == ["state", "mismatch"], r.stdout)
    stub.close()
    # state-mask: only the live bits are state, a difference elsewhere is a mismatch
    mrules = tmp / "mask.list"
    mrules.write_text("state-mask M.PINS 0x00FF0000 bits 23-16 are the pin levels\nstate-mask M.HANDSHAKE 0x0C000000 live handshake\n")
    (tmp / "m").mkdir()
    msvd = make_svd(tmp / "m", {"M@0x3000": [reg("PINS", 0, reset=0x800000), reg("HANDSHAKE", 4, reset=1), reg("SAME", 8, reset=0),
                                      reg("HALF", 12, reset=0, size=16)]})
    for mem, want, label in (
            ({0x3000: 0xEF0000, 0x3004: 0xC000001, 0x3008: 0, 0x300C: 0}, ["state", "state", "ok", "ok"], "only live bits differ"),
            ({0x3000: 0xEF0001, 0x3004: 0xC000001, 0x3008: 0, 0x300C: 0}, ["mismatch", "state", "ok", "ok"], "a bit outside the mask differs too"),
            ({0x3000: 0x800000, 0x3004: 0x4000003, 0x3008: 0, 0x300C: 0}, ["ok", "mismatch", "ok", "ok"], "a live bit and a bit outside differ"),
            ({0x3000: 0x800000, 0x3004: 1, 0x3008: 0, 0x300C: 0}, ["ok", "ok", "ok", "ok"], "nothing differs")):
        stub = Stub(mem=mem)
        r = run(msvd, stub, "--skip-file", str(mrules))
        check(f"state-mask: {label}", kinds(r.stdout) == want, f"{kinds(r.stdout)} {r.stdout!r}")
        stub.close()
    stub = Stub(mem={0x3000: 0xEF0000, 0x3004: 0xC000001, 0x3008: 0, 0x300C: 0x12})
    r = run(msvd, stub, "--skip-file", str(mrules))
    check("state-mask: the live bits are named in the line", "(bits 0xFF0000 are live)" in r.stdout and "live handshake (bits 0xC000000 are live)" in r.stdout, r.stdout)
    check("state-mask: a 16-bit register shows 4 digits", "mismatch    0x0000300C M.HALF = 0x0012, expected 0x0000 (mask 0xFFFF)" in r.stdout, r.stdout)
    check("state-mask: the run is a failure only for the mismatch", r.returncode == 1 and "2 state" in r.stdout, f"{r.returncode} {r.stdout!r}")
    stub.close()
    stub = Stub(mem={0x3000: 0xEF0000, 0x3004: 0xC000001, 0x3008: 0, 0x300C: 0})
    r = run(msvd, stub, "--skip-file", str(mrules), "--compare-state")
    check("state-mask: --compare-state reports them as mismatch", kinds(r.stdout) == ["mismatch", "mismatch", "ok", "ok"], r.stdout)
    stub.close()
    r = run(msvd, None, "--skip-file", str(mrules), "--list")
    check("state-mask: --list shows the mask", "M.PINS reset 0x800000 mask 0xFFFFFFFF state-mask 0xFF0000" in r.stdout and r.stdout.count("state-mask") == 2, r.stdout)
    for bad_line in ("state-mask M.PINS 0x0 no bits\n", "state-mask M.PINS xyz reason\n", "state-mask M.PINS 0xFF\n"):
        bad = tmp / "badmask.list"
        bad.write_text(bad_line)
        r = run(msvd, None, "--skip-file", str(bad), "--list")
        check(f"state-mask: {bad_line.strip()!r} is a malformed rule", r.returncode == 2 and "badmask.list:1" in r.stderr, f"{r.returncode} {r.stderr!r}")
    r = run(svd, None, "--skip-file", str(rules), "--list", "P1")
    check("state: --list marks them", [line.endswith(" state") for line in r.stdout.splitlines()] == [True, True, False, True], r.stdout)
    bad = tmp / "bad.list"
    bad.write_text("state P1.X\n")
    r = run(svd, None, "--skip-file", str(bad), "--list")
    check("state: a malformed rules file exits 2 with the line", r.returncode == 2 and "bad.list:1" in r.stderr, f"{r.returncode} {r.stderr!r}")
    bad.write_text("ignore P1.X because\n")
    r = run(svd, None, "--skip-file", str(bad), "--list")
    check("state: an unknown kind exits 2", r.returncode == 2 and "bad.list:1" in r.stderr, f"{r.returncode} {r.stderr!r}")
    r = run(svd, None, "--skip-file", str(tmp / "none.list"), "--list")
    check("state: a missing rules file exits 2", r.returncode == 2, f"{r.returncode} {r.stderr!r}")
    if REAL_SVD.is_file():
        r = run(REAL_SVD, None, "--list", "--include", "*")
        marked = {line.split()[2] for line in r.stdout.splitlines() if line.endswith(" state")}
        masks = {line.split()[2]: line.split()[-1] for line in r.stdout.splitlines() if " state-mask " in line}
        check("state: the mask rules cover the live bits of QSPIXIP.DirectAccess and CRYPTO.CONFIG",
              masks == {"QSPIXIP.DirectAccess": "0xFF0000", "CRYPTO.CONFIG": "0xF000000"}, str(masks))
        want_rules = {"QSPIXIP.DirectAccess", "CRYPTO.CONFIG", "SYSREG.DEVICE_STATUS", "SYSREG.ENVM_CR", "SYSREG.MAINTENANCE_INT_SR",
                      "SYSREG.DLL_STATUS_SR", "EMMC_SD.SRS04", "EMMC_SD.SRS05", "EMMC_SD.SRS06", "EMMC_SD.SRS07", "EMMC_SD.SRS09",
                      "CLINT.MSIP0", "CLINT.MSIP4", "WDOG0_LO.WDOG_REFRESH", "DDR_CSR_APB.STAT_DFI_ERROR", "DDR_CSR_APB.CTRLR_INIT_DONE",
                      "DDR_CSR_APB.CTRLR_READY", "DDR_CSR_APB.INIT_ACK", "DDR_CSR_APB.MTC_ACQ_ERROR_CNT", "DDR_CSR_APB.INIT_CAL_L_R_ACK",
                      "DDR_CSR_APB.PHY_WRITE_REQUEST_DONE", "DDR_CSR_APB.PHY_READ_REQUEST_DONE", "GEM_A_LO.network_status",
                      "CFG_DDR_SGMII_PHY.BANK_STATUS", "CFG_DDR_SGMII_PHY.DQDQS_STATUS3"}
        check("state: the default rules cover the state registers seen at power-on", want_rules <= marked | set(masks), str(sorted(want_rules - marked - set(masks))))
        check("state: SCB_REGS.BOOT_ROM0..7 need no rule (the SVD has the power-on values)", not marked & {f"SCB_REGS.BOOT_ROM{i}" for i in range(8)}, "")
        check("state: a control register with STATUS in its name is not state",
              not marked & {"CFG_DDR_SGMII_PHY.EXPERT_DFI_STATUS_OVERRIDE_TO_SHIM", "SYSREG.PLL_STATUS_INTEN_CR", "SYSREG.DLL_STATUS_CR"}, "")
        rules_text = (TOOL.parent / "svd_probe.list").read_text()
        reasons = [line.split(None, 2)[2] for line in rules_text.splitlines() if line and not line.startswith("#") and not line.startswith("state-mask")]
        reasons += [line.split(None, 3)[3] for line in rules_text.splitlines() if line.startswith("state-mask")]
        check("state: no rule reason mentions boot software", not [x for x in reasons if "boot software" in x.lower()], str([x for x in reasons if "boot" in x.lower()]))
        check("state: the three PLIC rules (threshold, enable, priority) say that there is no reset value, and PENDING says its bits follow the sources",
              rules_text.count("no reset value: device-specific power-up pattern, mostly repeatable (hw/probe_irq.S)") == 3
              and "state PLIC.PENDING*    bits follow the interrupt sources (source 119 / F2M_1 is set at power-on and cleared by reset halt)" in rules_text, "")
        want = {"CAN_A_LO.TX_MSG0_ID", "CAN_B_LO.RX_MSG31_DATA_LOW", "CLINT.MTIMECMP0", "CLINT.MTIME", "PLIC.PENDING0", "PLIC.THRESHOLD_H1_M",
                "PLIC.ENABLE_H0_M2", "PLIC.PRIORITY1", "MMUART0_LO.RBR", "MMUART0_LO.DLR", "MMUART0_LO.THR", "MMUART0_LO.MSR",
                "SYSREG.PLL_STATUS_SR", "SYSREG.DEVICE_STATUS", "SCB_REGS.DLL0_STAT1", "QSPIXIP.StatusRegister"}
        check("state: the default rules cover the runtime registers seen on the board", want <= marked, str(sorted(want - marked)))
        check("state: the default rules leave configuration registers alone",
              not marked & {"SYSREG.SUBBLK_CLOCK_CR", "SYSREG.SOFT_RESET_CR", "MMUART0_LO.LCR", "WDOG0_LO.WDOG_CONTROL", "SYSREG.PLL_STATUS_INTEN_CR",
                            "SYSREG.DLL_STATUS_CR", "CFG_DDR_SGMII_PHY.EXPERT_DFI_STATUS_OVERRIDE_TO_SHIM", "DDR_CSR_APB.CFG_ZQINIT_CAL_DURATION"},
              str(sorted(marked)[:5]))
        r = run(REAL_SVD, None, "--list", "--enable-clocks", "SYSREG")
        marked = {line.split()[2] for line in r.stdout.splitlines() if line.endswith(" state")}
        check("state: --enable-clocks adds the two SYSREG registers it writes", {"SYSREG.SUBBLK_CLOCK_CR", "SYSREG.SOFT_RESET_CR"} <= marked, str(sorted(marked)))


def test_skip(tmp: Path) -> None:
    """Excluded blocks are not read in a whole-device run and say why; --include or naming the block reads them."""
    rules = tmp / "rules.list"
    rules.write_text("skip BLK* cannot be probed on this board\nskip OTHER never measured\n")
    svd = make_svd(tmp, {"P1@0x1000": [reg("R0", 0)], "BLK1@0x2000": [reg("R0", 0), reg("R1", 4)],
                         "BLK2@0x3000": [reg("R0", 0)], "OTHER@0x4000": [reg("R0", 0)]})
    stub = Stub()
    r = run(svd, stub, "--skip-file", str(rules))
    check("skip: excluded blocks are not read", stub.commands("md") == ["mdw 0x1000 1"], str(stub.commands("md")))
    check("skip: the reason and the way to read them are printed",
          "cannot be probed on this board" in r.stdout and "--include 'BLK*'" in r.stdout and "never measured" in r.stdout, r.stdout)
    check("skip: a rule that matches several blocks gets one line", r.stdout.count("cannot be probed") == 1 and "BLK1, BLK2" in r.stdout, r.stdout)
    check("skip: the summary counts the excluded registers, which are no failure",
          r.returncode == 0 and "1 register(s)," in r.stdout and "4 excluded" in r.stdout, f"{r.returncode} {r.stdout!r}")
    stub.close()
    stub = Stub()
    r = run(svd, stub, "--skip-file", str(rules), "BLK1", "P1")
    check("skip: naming a block overrides the rules, with a note on stderr",
          sorted(stub.commands("md")) == ["mdw 0x1000 1", "mdw 0x2000 2"] and "BLK1 is on the default skip list" in r.stderr
          and "cannot be probed on this board" in r.stderr and "BLK2" not in r.stderr, f"{stub.commands('md')} {r.stderr!r}")
    stub.close()
    stub = Stub()
    r = run(svd, stub, "--skip-file", str(rules), "--all")
    check("skip: --all is a whole-device run, the rules still apply", stub.commands("md") == ["mdw 0x1000 1"] and "on the default skip list" not in r.stderr,
          f"{stub.commands('md')} {r.stderr!r}")
    stub.close()
    r = run(svd, None, "--skip-file", str(rules), "NOPE", "--list")
    check("skip: a name that matches no peripheral is an error", r.returncode != 0 and "NOPE" in r.stderr and r.stdout == "", f"{r.returncode} {r.stdout!r} {r.stderr!r}")
    r = run(svd, None, "--skip-file", str(rules), "--skip", "BLK1", "BLK1", "--list")
    check("skip: --skip still wins over a name on the command line", "BLK1" not in r.stdout, r.stdout)
    stub = Stub()
    r = run(svd, stub, "--skip-file", str(rules), "--include", "BLK1")
    check("skip: --include reads an excluded block, only that one", stub.commands("md") == ["mdw 0x1000 1", "mdw 0x2000 2"],
          str(stub.commands("md")))
    stub.close()
    stub = Stub()
    r = run(svd, stub, "--skip-file", str(rules), "--include", "BLK*,OTHER")
    check("skip: --include takes patterns and lists", stub.commands("md") == ["mdw 0x1000 1", "mdw 0x2000 2", "mdw 0x3000 1", "mdw 0x4000 1"],
          str(stub.commands("md")))
    stub.close()
    r = run(svd, None, "--skip-file", str(rules), "--include", "NOPE", "--list")
    check("skip: --include of a name that does not exist exits 2", r.returncode == 2 and "NOPE" in r.stderr, f"{r.returncode} {r.stderr!r}")
    r = run(svd, None, "--skip-file", str(rules), "--list")
    check("skip: --list leaves the excluded registers out and names them on stderr",
          "BLK" not in r.stdout and "P1.R0" in r.stdout and "never measured" in r.stderr, f"{r.stdout!r} {r.stderr!r}")
    r = run(svd, None, "--skip-file", str(rules), "--skip", "P1,BLK1", "--list")
    check("skip: --skip still works beside the rules file", "P1.R0" not in r.stdout and "BLK1" not in r.stdout, r.stdout)
    # a skip-enable-clocks rule applies only with --enable-clocks
    crules = tmp / "clk.list"
    crules.write_text("skip-enable-clocks BLK* stalls after the clock writes\n")
    (tmp / "c").mkdir()
    svd_c = make_svd(tmp / "c", {"P1@0x1000": [reg("R0", 0)], "BLK1@0x2000": [reg("R0", 0)],
                                  "SYSREG@0x3000": [reg("SUBBLK_CLOCK_CR", 0x84), reg("SOFT_RESET_CR", 0x88)]})
    stub = Stub()
    run(svd_c, stub, "--skip-file", str(crules))
    check("skip: a skip-enable-clocks rule does not apply without --enable-clocks", "mdw 0x2000 1" in stub.commands("md"), str(stub.commands("md")))
    stub.close()
    stub = Stub()
    r = run(svd_c, stub, "--skip-file", str(crules), "--enable-clocks")
    check("skip: with --enable-clocks it excludes the block and says why",
          "mdw 0x2000 1" not in stub.commands("md") and "stalls after the clock writes" in r.stdout, f"{stub.commands('md')} {r.stdout!r} {r.stderr!r}")
    stub.close()
    # a skip-no-clocks rule applies only without --enable-clocks (the block hangs the bus while its clock is off)
    nrules = tmp / "noclk.list"
    nrules.write_text("skip-no-clocks BLK* hangs the bus without its clock\n")
    stub = Stub()
    r = run(svd_c, stub, "--skip-file", str(nrules))
    check("skip: a skip-no-clocks rule excludes the block without --enable-clocks and says why",
          "mdw 0x2000 1" not in stub.commands("md") and "hangs the bus without its clock" in r.stdout, f"{stub.commands('md')} {r.stdout!r}")
    stub.close()
    stub = Stub()
    run(svd_c, stub, "--skip-file", str(nrules), "--enable-clocks")
    check("skip: a skip-no-clocks rule does not apply with --enable-clocks", "mdw 0x2000 1" in stub.commands("md"), str(stub.commands("md")))
    stub.close()
    if REAL_SVD.is_file():
        r = run(REAL_SVD, None, "--list")
        shown = {line.split()[2].split(".")[0] for line in r.stdout.splitlines()}
        gone = {"ATHENA", "TRACE", "IOSCBCFG", "ENVM", "CAN_A_HI", "MMUART0_HI", "GEM_B_HI", "CAN_B_HI"}
        check("skip: by default ATHENA, TRACE, IOSCBCFG, ENVM and the _HI aliases are left out, the _LO CAN blocks are read",
              not shown & gone and {"MMUART0_LO", "GEM_A_LO", "CAN_A_LO", "CAN_B_LO"} <= shown,
              str(sorted(shown & gone)))
        check("skip: the reasons are printed", "not an S device" in r.stderr and "never measured" in r.stderr and "--include ATHENA" in r.stderr, r.stderr)
        r = run(REAL_SVD, None, "--list", "--include", "ATHENA,*_HI,ENVM")
        shown = {line.split()[2].split(".")[0] for line in r.stdout.splitlines()}
        check("skip: --include reads them", {"ATHENA", "ENVM", "CAN_A_HI", "MMUART0_HI"} <= shown and "TRACE" not in shown, str(sorted(shown)[:6]))
        r = run(REAL_SVD, None, "--list", "--enable-clocks")
        shown = {line.split()[2].split(".")[0] for line in r.stdout.splitlines()}
        check("skip: with --enable-clocks the CAN blocks are left out, and their aliases",
              not shown & {"CAN_A_LO", "CAN_B_LO", "CAN_A_HI", "CAN_B_HI"} and "MMUART0_LO" in shown, str(sorted(shown)[:6]))
        check("skip: the CAN reason names the stall, what happens without --enable-clocks and the way to read the block",
              "stalled the debug module" in r.stderr and "without --enable-clocks the block reads 0" in r.stderr
              and "--include 'CAN_?_*' reads them" in r.stderr and "boot software" not in r.stderr, r.stderr)
        r = run(REAL_SVD, None, "--list", "--enable-clocks", "--include", "CAN_A_LO")
        shown = {line.split()[2].split(".")[0] for line in r.stdout.splitlines()}
        check("skip: --include CAN_A_LO reads that block only, also with --enable-clocks",
              "CAN_A_LO" in shown and not shown & {"CAN_B_LO", "CAN_A_HI"}, str(sorted(shown)[:6]))
        r = run(REAL_SVD, None, "--list", "--enable-clocks", "CAN_B_LO")
        shown = {line.split()[2].split(".")[0] for line in r.stdout.splitlines()}
        check("skip: naming CAN_B_LO reads it with --enable-clocks, with the reason on stderr",
              shown == {"CAN_B_LO"} and "CAN_B_LO is on the default skip list" in r.stderr and "stalled the debug module" in r.stderr, f"{sorted(shown)[:3]} {r.stderr!r}")
        r = run(REAL_SVD, None, "--list", "CAN_B_LO")
        check("skip: naming CAN_B_LO without --enable-clocks gives no note", "default skip list" not in r.stderr, r.stderr)
        r = run(REAL_SVD, None, "--list", "ENVM")
        shown = {line.split()[2].split(".")[0] for line in r.stdout.splitlines()}
        check("skip: ./x svd probe ENVM reads the block without --include", shown == {"ENVM"} and "ENVM is on the default skip list" in r.stderr, f"{sorted(shown)[:4]} {r.stderr!r}")


def main() -> int:
    """Run all cases."""
    if not TOOL.is_file():
        print(f"probe_test: {TOOL} not found", file=sys.stderr)
        return 2
    for case in (test_dead_connection, test_hang, test_noise, test_halt, test_power_state, test_enable_clocks, test_reset_halt, test_poke, test_abort_output, test_recover, test_resume, test_interrupt, test_failures, test_block, test_read_action, test_dlab, test_write_only, test_identical, test_noref, test_state, test_skip):
        with tempfile.TemporaryDirectory() as d:
            case(Path(d))
    print(f"summary: {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
