#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
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
    like OpenOCD with a table in which hart 0 is in <state>.
    """

    def __init__(self, mem=None, script=None, accept=None, banner=True, state="halted"):
        self.banner = banner
        self.state = state
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
                        out = self._md(cmd) if cmd.startswith("md") else self._targets() if cmd == "targets" else ""
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
    r = run(svd, None, "--block", "0")
    check("block: --block 0 is refused", r.returncode != 0 and "--block 0" in r.stderr, r.stderr)


def main() -> int:
    """Run all cases."""
    if not TOOL.is_file():
        print(f"probe_test: {TOOL} not found", file=sys.stderr)
        return 2
    for case in (test_dead_connection, test_hang, test_noise, test_halt, test_resume, test_interrupt, test_failures, test_block):
        with tempfile.TemporaryDirectory() as d:
            case(Path(d))
    print(f"summary: {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
