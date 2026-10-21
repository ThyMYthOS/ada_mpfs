#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Compare the reset values of SVD registers with a running target.

  svd_probe.py [--svd FILE] [--host H] [--port P] [--target T] [--no-halt] [--block [PATTERN=]N] [--timeout S]
               [--keep-going] [--max-failures N] [--skip P] [--include P] [--skip-file FILE] [--compare-state]
               [--read-destructive] [--enable-clocks] [--list] [--all | PERIPHERAL...]

Reads the registers of the named peripherals (all of them with --all or without
a name; a block that hw/svd_probe.list excludes is skipped only in such a whole-device run, a block named on the
command line is read, with a note on stderr) through the OpenOCD telnet port (default localhost:4444) and compares them with <resetValue> under <resetMask>
(all bits if the SVD has no mask). One line per register, "<kind>  0x<address> <PERIPHERAL.REGISTER>" and, after
" = ", the value read in hex, as wide as the register (ok  0x20002008 SYSREG.CLOCK_CONFIG_CR = 0x00000010):

  ok          the value matches
  mismatch    the value differs; the expected value is shown too
  state       the value differs, but the register is runtime state (status, FIFO, message RAM, a register
              the tool wrote with --enable-clocks, live pin levels ...) that only has its reset value after a
              reset-halt; the patterns are in hw/svd_probe.list, which can also name the live bits of a register
              (state-mask: a difference in the other bits is a mismatch); --compare-state reports them as mismatch
  noref       nothing to compare: the SVD has no <resetValue>, or <resetMask> is 0
  unreadable  the access failed; the text OpenOCD replied is shown
  skipped     not read: a register with a readAction (reading it consumes data or clears status; --read-destructive
              reads it anyway), the rest of a peripheral after an unreadable register, or a block excluded
              by hw/svd_probe.list (ATHENA, TRACE, ...; --include reads it, and so does naming the
              peripheral on the command line)

The selected hart (default mpfs.hart0_e51) is halted for the reads and resumed
afterwards; reads then use the program buffer ("riscv set_prefer_sba off"), as
in the hardware spikes.

A bus error in a program-buffer read can make OpenOCD drop the session. The probe
stops at once then (exit code 2) and names the register it accessed last; it also
stops after --max-failures unreadable registers in a row. At the end it tries to
resume the hart, over a new connection if need be, and says so if that fails.

Before it reads, the probe checks in the target table of OpenOCD ("targets") that the selected hart is halted
and stops with exit code 2, showing the table, if it is not; it also does this with --no-halt. Other harts that
did not halt ("unable to halt hart N" in the reply to halt) are mentioned in one line and do not matter: the reads
go through the selected hart only.

A reply that says the debug module is stuck busy ("Timed out ... waiting for busy", "abstractcs=...", "Failed to
read priv register") stops the probe at once, whatever --keep-going or --max-failures say, and shows the reply: a
hung access (the first one to CAN_A_LO after the --enable-clocks writes did). The probe makes
one attempt to recover (riscv dmi_write 0x16 0x700 clears cmderr, riscv dmi_read 0x16 reads abstractcs; without
these commands in OpenOCD there is no attempt). If the debug module stays busy, the probe does not even resume the
hart, names the block and the register and says: power-cycle the board and restart OpenOCD. If it is idle again,
the register is reported as unreadable and the run goes on with the next peripheral.

Ctrl+C stops the probe at once, even if OpenOCD does not answer (a hung bus). It makes
one attempt to resume the hart with a 2 s timeout (none with --no-halt), says whether
the hart may still be halted, and exits with status 130; a second Ctrl+C leaves
immediately. After an interrupt the hart can remain halted: send "resume" to OpenOCD.

The exit code is 1 if any register is not ok (state, noref and skipped registers
are not failures), 2 if the probe stopped early or could not resume the hart, 130
after Ctrl+C. With
--list nothing is read: the registers, their addresses and expected values are
printed, so the tool can be checked without a board.
"""
import argparse
import fnmatch
import re
import socket
import sys
from dataclasses import dataclass
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
INTERRUPT_TIMEOUT = 2.0  # seconds the resume after Ctrl+C may take
EXIT_INTERRUPTED = 130  # 128 + SIGINT, as for any program that ends on Ctrl+C
RULES = Path(__file__).resolve().with_suffix(".list")
RULE_KINDS = ("skip", "state", "state-mask", "state-enable-clocks", "skip-enable-clocks", "skip-no-clocks", "block")
MD_SUFFIX = {8: "b", 16: "h", 32: "w", 64: "d"}
# What OpenOCD replies, as plain text and not as an error of the command, when the debug module is stuck busy
HANG_REPLY = re.compile(r"Timed out|waiting for busy|abstractcs|Failed to read priv register", re.IGNORECASE)
# Lines that OpenOCD writes by itself while a hart does not halt; they are not part of a reply
NOISE_LINE = re.compile(r"^(unable to halt hart \d+|\s+dm(control|status)\s*=\s*0x[0-9a-fA-F]+)\s*$")
# What OpenOCD replies to a command it does not know
UNKNOWN_COMMAND = re.compile(r"invalid command name|\bunknown\b|no such command|not recognized", re.IGNORECASE)
ABSTRACTCS = 0x16  # DMI address of the abstractcs register of the debug module
ABSTRACTCS_BUSY = 1 << 12
ABSTRACTCS_CMDERR = 0x700


@dataclass(slots=True)
class Reg:
    """A register to probe: absolute address, access width and expected value."""
    name: str
    address: int
    size: int
    reset: int | None  # None: the SVD has no <resetValue>
    mask: int
    read_action: str = ""  # readAction of the register or of one of its fields: reading has a side effect


def int_of(text: str | None, default: int = 0) -> int:
    """Integer value of an SVD number; <default> if the element is missing."""
    return int(text, 0) if text else default


def dim_indices(el: ET.Element) -> list[str]:
    """Index strings of an SVD array element ("0-5", "A,B"); [""] if it is no array."""
    dim = el.findtext("dim")
    if dim is None:
        return [""]
    spec = el.findtext("dimIndex")
    if spec is None:
        return [str(i) for i in range(int_of(dim))]
    if re.fullmatch(r"\d+-\d+", spec):
        lo, hi = (int(x) for x in spec.split("-"))
        return [str(i) for i in range(lo, hi + 1)]
    return spec.split(",")


def peripheral_registers(root: ET.Element, name: str) -> list[Reg]:
    """All registers of peripheral <name>, arrays expanded, with absolute addresses.

    A derived peripheral takes its registers from the peripheral it derives from.
    """
    periph = next((p for p in root.iter("peripheral") if p.findtext("name") == name), None)
    if periph is None:
        raise SystemExit(f"svd_probe: no peripheral {name} in the SVD")
    source = periph
    if periph.get("derivedFrom"):
        source = next(p for p in root.iter("peripheral") if p.findtext("name") == periph.get("derivedFrom"))
    base = int_of(periph.findtext("baseAddress"))
    default_size = int_of(root.findtext("size"), 32)
    regs = []
    for r in source.iterfind("registers/register"):
        size = int_of(r.findtext("size"), default_size)
        read_action = next((a.text for a in r.iter("readAction") if a.text and a.text != "none"), "")
        for n, idx in enumerate(dim_indices(r)):
            step = int_of(r.findtext("dimIncrement"))
            regs.append(Reg(
                name=f"{name}.{r.findtext('name').replace('%s', idx)}",
                address=base + int_of(r.findtext("addressOffset")) + n * step,
                size=size,
                reset=int_of(r.findtext("resetValue")) if r.findtext("resetValue") else None,
                mask=int_of(r.findtext("resetMask"), (1 << size) - 1),
                read_action=read_action,
            ))
    return regs


@dataclass(slots=True, eq=False)
class Rule:
    """A line of the rules file: a pattern of a kind, with the reason that is shown in the report.

    A state-mask rule also has <mask>, the bits of the register that are live: a difference there is state,
    a difference in the other bits is a mismatch. For the other kinds <mask> is 0.
    """
    kind: str
    pattern: str
    reason: str
    mask: int = 0

    def matches(self, name: str) -> bool:
        """Whether <name> matches the pattern (* and ?, case does not matter)."""
        return re.fullmatch(fnmatch.translate(self.pattern), name, re.IGNORECASE) is not None

    def is_state(self, diff: int) -> bool:
        """Whether a difference <diff> (bits that differ from the reset value) is runtime state under this rule."""
        return not self.mask or not diff & ~self.mask


def state_marker(name: str, state: list[Rule]) -> str:
    """The text --list appends to a register: " state", " state-mask 0xMASK" or nothing."""
    rule = next((x for x in state if x.matches(name)), None)
    return "" if rule is None else f" state-mask 0x{rule.mask:X}" if rule.mask else " state"


def load_rules(path: Path) -> list[Rule]:
    """Read the rules file; raises ValueError with the line number on a malformed line."""
    rules = []
    for n, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 3 if line.startswith("state-mask ") else 2)
        if len(parts) < 3 or parts[0] not in RULE_KINDS:
            raise ValueError(f"{path}:{n}: expected '<{'|'.join(RULE_KINDS)}> <pattern> <reason>' "
                             f"('state-mask <pattern> <mask> <reason>'), got {line!r}")
        if parts[0] == "state-mask":
            try:
                mask = int(parts[2], 0)
                if len(parts) < 4 or not mask:
                    raise ValueError
            except ValueError:
                raise ValueError(f"{path}:{n}: expected 'state-mask <pattern> <mask, not 0> <reason>', got {line!r}") from None
            rules.append(Rule(parts[0], parts[1], parts[3], mask))
        else:
            rules.append(Rule(*parts))
    return rules


class OpenOcd:
    """Minimal client of the OpenOCD telnet port.

    The telnet port is used instead of the Tcl RPC port: the OpenOCD that ships
    with Microchip SoftConsole has no read_memory command, and the output of
    md[bhwd] does not come back through the RPC port.
    """

    PROMPT = b"> "

    def __init__(self, host: str, port: int, timeout: float = 30.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self._seq = 0
        self._read()

    def _read(self, echo: bytes = b"") -> str:
        """Read up to the prompt; with <echo> only once that text (the echoed command) has arrived too."""
        buf = b""
        while not (buf.endswith(self.PROMPT) and echo in buf):
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("OpenOCD closed the connection")
            buf += chunk
        return re.sub(rb"\xff[\xfb-\xfe].", b"", buf).decode("latin1").replace("\r", "").replace("\x00", "")

    def command(self, cmd: str, timeout: float | None = None, echo: bool = False, hang: bool = False) -> str:
        """Run a command and return its output without the echoed command line and the prompt.

        The command is framed by two `echo` commands with a number of their own, and only what lies between
        their outputs is the reply: OpenOCD prints a prompt after every message it writes by itself (the
        "unable to halt hart" lines of a hung bus), so a prompt does not tell that the reply is complete,
        and the left-over reply of an interrupted command cannot be taken for this one.
        <timeout> replaces the socket timeout from now on. <echo> is kept for the callers; the framing does
        what it did. With <hang> a reply that says the debug module is stuck busy raises DebugHang.
        """
        self._seq += 1
        begin, end = f"svd_probe_begin_{self._seq}", f"svd_probe_end_{self._seq}"
        try:
            if timeout is not None:
                self.sock.settimeout(timeout)
            self.sock.sendall(f"echo {begin}\n{cmd}\necho {end}\n".encode())
            text = self._read_framed(begin, end)
        except ConnectionError as e:  # reset, broken pipe, end of file: the session is gone
            raise Dead(f"the connection to OpenOCD is lost after {cmd!r} ({type(e).__name__}: {e})") from None
        typed = {cmd, f"echo {end}"}
        lines = [x for x in text.split("\n") if x.removeprefix("> ").strip() not in typed and x.strip() != ">"]
        reply = "\n".join(lines).strip()
        if hang and HANG_REPLY.search(reply):
            raise DebugHang(reply)
        return reply

    def _read_framed(self, begin: str, end: str) -> str:
        """Read until the output of `echo <end>` and the prompt after it; return the text between the
        output line of `echo <begin>` and the output line of `echo <end>`."""
        buf = b""
        while True:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("OpenOCD closed the connection")
            buf += chunk
            text = re.sub(rb"\xff[\xfb-\xfe].", b"", buf).decode("latin1").replace("\r", "").replace("\x00", "").replace("\x08", "")
            lines = text.split("\n")
            if begin in lines and end in lines[lines.index(begin):] and text.endswith("> "):
                first = lines.index(begin)
                last = len(lines) - 1 - lines[::-1].index(end)
                return "\n".join(lines[first + 1:last])

    def read_block(self, address: int, size: int, count: int) -> list[int]:
        """Read <count> consecutive registers of <size> bits with one md[bhwd] command.

        The reply is "<address>: <value> <value> ..." with several lines for long blocks.
        """
        cmd = f"md{MD_SUFFIX[size]} 0x{address:X} {count}"
        out = self.command(cmd, hang=True)
        out = "\n".join(x for x in out.splitlines() if not NOISE_LINE.match(x))  # what OpenOCD writes by itself
        try:
            values = [int(v, 16) for line in out.splitlines() for v in line.split(":", 1)[1].split()]
        except (ValueError, IndexError):
            raise OSError(f"{cmd} replied {out!r}" if out else f"{cmd} replied nothing") from None
        if len(values) != count:
            raise OSError(f"{cmd} replied {len(values)} value(s): {out!r}")
        return values

    def read(self, address: int, size: int) -> int:
        """Read one register of <size> bits at <address>."""
        return self.read_block(address, size, 1)[0]

    def close(self) -> None:
        """Close the connection."""
        self.sock.close()


def runs(regs: list[Reg], limit: int) -> list[list[Reg]]:
    """Split <regs> into runs of at most <limit> registers of equal size at consecutive addresses."""
    result: list[list[Reg]] = []
    for r in regs:
        run = result[-1] if result else None
        if run and len(run) < limit and run[-1].size == r.size and r.address == run[-1].address + r.size // 8:
            run.append(r)
        else:
            result.append([r])
    return result


class NotHalted(Exception):
    """The selected hart is not halted, so reads through it would not mean what the probe assumes."""


class Hung(Exception):
    """OpenOCD did not answer in time, or the debug module is stuck busy: the bus is probably hung.

    <stuck> is set when the debug module still reports busy after a recovery attempt: it needs a
    power cycle, and nothing more may be sent to it, not even the resume.
    """

    def __init__(self, message: str, stuck: bool = False):
        super().__init__(message)
        self.stuck = stuck


class DebugHang(Exception):
    """OpenOCD replied with text that says the debug module is stuck busy (the text is the message)."""


class Dead(Exception):
    """The connection to OpenOCD is gone (reset, broken pipe, end of file).

    OpenOCD drops the session when a program-buffer read hits a bus error, so this is
    usually the access that was made last, not a network problem.
    """


class TooManyFailures(Exception):
    """Several registers in a row were unreadable: the rest would fail as well."""


class NotRead(OSError):
    """A register that was not tried because the one before it failed."""


@dataclass(slots=True)
class Result:
    """Counts of a probe run."""
    failures: int = 0
    skipped: int = 0
    read_action: int = 0
    noref: int = 0
    state: int = 0
    excluded: int = 0


def recover_debug_module(target: OpenOcd) -> str:
    """One attempt to get a debug module out of "busy": clear cmderr, read abstractcs again.

    Returns "" if the debug module is not busy afterwards, else why there is no recovery.
    """
    try:
        for cmd in (f"riscv dmi_write 0x{ABSTRACTCS:X} 0x{ABSTRACTCS_CMDERR:X}", f"riscv dmi_read 0x{ABSTRACTCS:X}"):
            reply = target.command(cmd)
            if UNKNOWN_COMMAND.search(reply):
                return f"no recovery attempt: OpenOCD does not know {cmd.split(' 0x')[0]!r}"
        match = re.search(r"\b(?:0x)?([0-9A-Fa-f]+)\b", reply)
        if HANG_REPLY.search(reply) or not match:
            return f"recovery failed: reading abstractcs replied {reply!r}"
        abstractcs = int(match.group(1), 16)
    except (OSError, Dead) as e:  # a timeout or a lost connection: the debug module does not answer either
        return f"recovery failed ({type(e).__name__}: {e})"
    if abstractcs & ABSTRACTCS_BUSY:
        return f"recovery failed: abstractcs is still 0x{abstractcs:08X} (busy) after clearing cmderr"
    return ""


def hang_error(target: OpenOcd, where: str, reply: str) -> OSError:
    """The debug module is stuck busy at <where>: try to recover it once.

    Raises Hung (stuck) if it stays busy, else returns the error to report for the access.
    """
    failed = recover_debug_module(target)
    if failed:
        raise Hung(f"the debug module is stuck busy {where}: OpenOCD replied {reply!r}; {failed}; power-cycle the board and "
                   "restart OpenOCD (the hart was not resumed)", stuck=True)
    print(f"svd_probe: note: the debug module was stuck busy {where} (OpenOCD replied {reply!r}); it is not busy after clearing "
          "cmderr, reading on", file=sys.stderr)
    return OSError(f"the debug module was stuck busy: {reply}")


def read_run(run: list[Reg], target: OpenOcd) -> list[int | OSError]:
    """Read <run> with one command; if that fails, read it register by register.

    The registers after the first unreadable one get the same error: a failed
    access usually means that the whole peripheral is off, and every further
    attempt could hang the bus.
    """
    try:
        return list(target.read_block(run[0].address, run[0].size, len(run)))
    except TimeoutError:
        raise Hung(f"no answer reading 0x{run[0].address:08X} ({run[0].name})") from None
    except DebugHang as e:
        what = f"in a block of {len(run)} registers from {run[0].name}" if len(run) > 1 else f"reading {run[0].name}"
        error = hang_error(target, f"{what} (0x{run[0].address:08X})", str(e))
        return [error] + [NotRead(f"not read after the hang at 0x{run[0].address:08X}")] * (len(run) - 1)
    except Dead as e:
        what = f"a block of {len(run)} registers from {run[0].name}" if len(run) > 1 else run[0].name
        raise Dead(f"{e} while reading 0x{run[0].address:08X}, {what}; the failing access is in that block") from None
    except (OSError, ValueError, IndexError) as e:
        error = e if isinstance(e, OSError) else OSError(str(e))
    if len(run) == 1:
        return [error]
    values: list[int | OSError] = []
    for r in run:
        try:
            values.append(target.read(r.address, r.size))
        except TimeoutError:
            raise Hung(f"no answer reading 0x{r.address:08X} ({r.name})") from None
        except DebugHang as e:
            values.append(hang_error(target, f"reading {r.name} (0x{r.address:08X})", str(e)))
            return values + [NotRead(f"not read after the hang at 0x{r.address:08X}")] * (len(run) - len(values))
        except Dead as e:
            raise Dead(f"{e} while reading 0x{r.address:08X} ({r.name})") from None
        except (OSError, ValueError, IndexError) as e1:
            e1 = e1 if isinstance(e1, OSError) else OSError(str(e1))
            values.append(e1)
            return values + [NotRead(f"not read after the failure at 0x{r.address:08X}")] * (len(run) - len(values))
    return values


def block_limit(name: str, blocks: list[tuple[str, int]]) -> int:
    """Largest block for peripheral <name>: the first PATTERN=N that matches, else the plain N."""
    for pattern, n in blocks:
        if pattern == "*" or fnmatch.fnmatchcase(name, pattern):
            return n
    return 512


def parse_blocks(specs: list[str]) -> list[tuple[str, int]]:
    """Parse the --block arguments ("N" or "PATTERN=N") in order; the plain N comes last, 512 if none."""
    named, plain = [], 512
    for spec in specs:
        pattern, sep, number = spec.rpartition("=")
        if not number.isdigit() or int(number) < 1 or (sep and not pattern):
            raise ValueError(f"--block {spec}: expected N or PATTERN=N with N >= 1")
        if sep:
            named.append((pattern, int(number)))
        else:
            plain = int(number)
    return named + [("*", plain)]


def probe(regs: list[Reg], target: OpenOcd, blocks: list[tuple[str, int]], keep_going: bool = False,
          max_failures: int = 3, read_destructive: bool = False, state: list[Rule] | None = None,
          result: Result | None = None) -> Result:
    """Read and compare all <regs>; print one line each and return the counts.

    The counts go into <result> if one is given, so that the caller still has them when the run ends in an exception.

    Registers at consecutive addresses are read with one command. After the first
    unreadable register of a peripheral the rest of it is skipped (one line), unless
    <keep_going>. Raises Hung if OpenOCD stops answering, Dead if the connection is
    lost and TooManyFailures after <max_failures> unreadable registers in a row
    (0: never). A register with a readAction is not read (one line) unless
    <read_destructive>: the read would consume data or clear status. A register
    that matches one of the <state> rules and differs from its reset value is
    reported as "state", not as "mismatch".
    """
    result = result if result is not None else Result()
    dead: dict[str, int] = {}
    in_a_row = 0
    chunks: list[Reg | list[Reg]] = []  # a register that is not read, or registers of one peripheral to read
    for r in regs:
        if r.read_action and not read_destructive:
            chunks.append(r)
        elif chunks and isinstance(chunks[-1], list) and chunks[-1][0].name.split(".")[0] == r.name.split(".")[0]:
            chunks[-1].append(r)
        else:
            chunks.append([r])
    for chunk in chunks:
        if isinstance(chunk, Reg):
            if chunk.name.split(".")[0] in dead:
                dead[chunk.name.split(".")[0]] += 1
            else:
                print(f"skipped (readAction)  0x{chunk.address:08X} {chunk.name} (readAction {chunk.read_action}; --read-destructive reads it)")
                result.read_action += 1
            continue
        name = chunk[0].name.split(".")[0]
        for run in runs(chunk, block_limit(name, blocks)):
            if name in dead:
                dead[name] += len(run)
                continue
            values = read_run(run, target)
            for r, value in zip(run, values):
                if isinstance(value, OSError):
                    print(f"unreadable  0x{r.address:08X} {r.name} ({value})")
                    result.failures += 1
                    if not isinstance(value, NotRead):
                        in_a_row += 1
                    if not keep_going:
                        dead[name] = 0
                    if max_failures and in_a_row >= max_failures:
                        raise TooManyFailures(f"{in_a_row} unreadable registers in a row, the last one is "
                                              f"0x{r.address:08X} ({r.name}): {value}")
                    continue
                in_a_row = 0
                w = r.size // 4  # hex digits of the register
                diff = 0 if r.reset is None else (value ^ r.reset) & r.mask
                rule = next((x for x in state or [] if x.matches(r.name)), None) if diff else None
                if r.reset is None or r.mask == 0:
                    why = "no resetValue" if r.reset is None else "resetMask is 0"
                    print(f"noref       0x{r.address:08X} {r.name} = 0x{value:0{w}X} ({why})")
                    result.noref += 1
                elif not diff:
                    print(f"ok          0x{r.address:08X} {r.name} = 0x{value:0{w}X}")
                elif rule and rule.is_state(diff):
                    live = f" (bits 0x{rule.mask:X} are live)" if rule.mask else ""
                    print(f"state       0x{r.address:08X} {r.name} = 0x{value:0{w}X}, reset 0x{r.reset:0{w}X} "
                          f"(mask 0x{r.mask:0{w}X}); {rule.reason}{live}")
                    result.state += 1
                else:
                    print(f"mismatch    0x{r.address:08X} {r.name} = 0x{value:0{w}X}, expected 0x{r.reset:0{w}X} (mask 0x{r.mask:0{w}X})")
                    result.failures += 1
    for name, n in dead.items():
        if n:
            print(f"skipped     {name}: {n} more register(s) after the first unreadable one")
            result.skipped += n
    return result


def enable_clocks(root: ET.Element, target: OpenOcd) -> None:
    """Turn on all MSS peripheral clocks and release all peripheral resets (SYSREG)."""
    sysreg = {r.name.split(".")[1]: r for r in peripheral_registers(root, "SYSREG")}
    for name, value in (("SUBBLK_CLOCK_CR", 0xFFFFFFFF), ("SOFT_RESET_CR", 0)):
        try:
            target.command(f"mww 0x{sysreg[name].address:X} 0x{value:X}", hang=True)
        except DebugHang as e:
            raise Hung(str(hang_error(target, f"writing SYSREG.{name} (0x{sysreg[name].address:08X})", str(e)))) from None


def note_other_harts(halt_reply: str, selected: str) -> None:
    """Print one line if OpenOCD says that harts other than <selected> did not halt (reads go through <selected>)."""
    own = re.search(r"hart(\d+)", selected)
    others = [line.strip() for line in halt_reply.splitlines() if re.search(r"unable to halt", line, re.IGNORECASE)
              and not (own and re.search(rf"hart\s*{own.group(1)}\b", line))]
    if others:
        print(f"svd_probe: note: other harts did not halt ({'; '.join(others)}); irrelevant for reads through {selected}")


def verify_halted(target: OpenOcd, selected: str, halt_reply: str) -> None:
    """Raise NotHalted unless the "targets" table lists <selected> as halted."""
    table = target.command("targets")
    for line in table.splitlines():
        words = line.split()
        if selected in words:
            if words[-1] == "halted":
                return
            break
    raise NotHalted(f"{selected} is not halted (OpenOCD's target table says: {table!r}"
                    + (f"; reply to halt: {halt_reply!r}" if halt_reply else "")
                    + "); reads through it would be meaningless. Check the board and OpenOCD, or halt the hart yourself and use --no-halt")


def resume(target: OpenOcd, args: argparse.Namespace) -> str | None:
    """Resume the halted hart; if the connection is gone, try once over a new one.

    Returns None on success, else a message about the hart still being halted.
    """
    try:
        target.command("resume")
        return None
    except (OSError, Dead) as e:
        first = e
    try:
        again = OpenOcd(args.host, args.port, args.timeout)
        try:
            again.command(f"targets {args.target}")
            again.command("resume")
        finally:
            again.close()
    except (OSError, Dead) as e:
        return (f"could not resume {args.target}: {first}; a new connection failed too ({e}). "
                "The hart is still halted: send 'resume' to OpenOCD or reset the board")
    print(f"svd_probe: resume over the first connection failed ({first}); resumed {args.target} over a new one", file=sys.stderr)
    return None


def resume_after_interrupt(target: OpenOcd) -> str:
    """One short attempt to resume the hart over the existing connection, after Ctrl+C.

    No retry and no new connection: an OpenOCD that is stuck on a hung bus would block those as
    well, and the person is waiting. Returns what to tell about the state of the hart.
    """
    try:
        target.command("resume", timeout=INTERRUPT_TIMEOUT, echo=True)
        return "the hart was resumed"
    except (OSError, Dead) as e:
        return (f"the hart may still be halted (resume not confirmed within {INTERRUPT_TIMEOUT:g} s: {e}); "
                "send 'resume' to OpenOCD or reset the board")


def main(argv: list[str]) -> int:
    """Command line entry point; returns the exit code."""
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__[__doc__.index("Reads the registers"):])
    ap.add_argument("peripherals", nargs="*", metavar="PERIPHERAL", help="peripherals to read (default: all)")
    ap.add_argument("--all", action="store_true", help="read all peripherals (the default without PERIPHERAL)")
    ap.add_argument("--svd", type=Path, default=ROOT / "build" / "svd" / "PolarfireSoC.svd",
                    help="merged SVD (default: build/svd/PolarfireSoC.svd, made by ./x svd merge)")
    ap.add_argument("--host", default="localhost")
    ap.add_argument("--port", type=int, default=4444)
    ap.add_argument("--target", default="mpfs.hart0_e51", help="OpenOCD target (hart) to read through (default: %(default)s)")
    ap.add_argument("--no-halt", action="store_true", help="do not halt the hart; it must be halted already")
    ap.add_argument("--block", action="append", default=[], metavar="[PATTERN=]N",
                    help="read up to N registers at consecutive addresses with one command (default: 512; 1 = one by one). "
                         "PATTERN=N (a peripheral name with * and ?, e.g. 'CAN*=16') limits only these peripherals; repeatable")
    ap.add_argument("--max-failures", type=int, default=3, metavar="N",
                    help="stop after N unreadable registers in a row, 0 = never (default: %(default)s)")
    ap.add_argument("--timeout", type=float, default=10.0, metavar="S",
                    help="give up when OpenOCD does not answer for S seconds, probably a hung bus (default: %(default)s)")
    ap.add_argument("--keep-going", action="store_true",
                    help="read the rest of a peripheral after an unreadable register (default: skip it)")
    ap.add_argument("--skip", action="append", default=[], metavar="PERIPHERAL[,PERIPHERAL...]",
                    help="do not read these peripherals (repeatable)")
    ap.add_argument("--include", action="append", default=[], metavar="PATTERN[,PATTERN...]",
                    help="in a whole-device run also read the peripherals that match PATTERN (* and ?) and that the rules file "
                         "excludes (repeatable); a peripheral named on the command line is read without it")
    ap.add_argument("--skip-file", type=Path, default=RULES, metavar="FILE",
                    help="rules file with the excluded blocks and the registers that hold state (default: %(default)s)")
    ap.add_argument("--compare-state", action="store_true",
                    help="report the registers that the rules file marks as state as mismatch, too")
    ap.add_argument("--read-destructive", action="store_true",
                    help="also read the registers that have a readAction in the SVD (FIFOs, PLIC claim/complete, "
                         "clear-on-read status). WARNING: the reads consume received data and clear status flags")
    ap.add_argument("--enable-clocks", action="store_true",
                    help="before reading, turn on all MSS peripheral clocks and release all peripheral resets "
                         "(SYSREG.SUBBLK_CLOCK_CR = 0xFFFFFFFF, SYSREG.SOFT_RESET_CR = 0). A peripheral with its clock off "
                         "or in reset can hang the bus, which only a reset of the board recovers")
    ap.add_argument("--list", action="store_true", help="print the registers and expected values, read nothing")
    args = ap.parse_args(argv[1:])
    if not args.svd.is_file():
        print(f"svd_probe: {args.svd} not found; run ./x svd merge", file=sys.stderr)
        return 2
    root = ET.parse(args.svd).getroot()
    names = args.peripherals
    if args.all or not names:
        names = [p.findtext("name") for p in root.iter("peripheral")]
    skip = {n for arg in args.skip for n in arg.split(",") if n}
    unknown = skip - {p.findtext("name") for p in root.iter("peripheral")}
    if unknown:
        print(f"svd_probe: no peripheral {', '.join(sorted(unknown))} in the SVD", file=sys.stderr)
        return 2
    try:
        rules = load_rules(args.skip_file)
    except (OSError, ValueError) as e:
        print(f"svd_probe: {e}", file=sys.stderr)
        return 2
    include = [x for arg in args.include for x in arg.split(",") if x]
    for pattern in include:
        if not fnmatch.filter([p.findtext("name") for p in root.iter("peripheral")], pattern):
            print(f"svd_probe: --include {pattern}: no such peripheral in the SVD", file=sys.stderr)
            return 2
    explicit = set() if args.all else set(args.peripherals)  # named on the command line: not subject to the default skip
    regs, excluded = [], []
    for p in names:
        if p in skip:
            continue
        rule = next((x for x in rules if x.matches(p) and (x.kind == "skip" or (x.kind == "skip-enable-clocks" and args.enable_clocks)
                                                          or (x.kind == "skip-no-clocks" and not args.enable_clocks))), None)
        if rule and p in explicit:
            print(f"svd_probe: {p} is on the default skip list ({rule.reason}); reading it because it is named on the "
                  "command line", file=sys.stderr)
            regs += peripheral_registers(root, p)
        elif rule and not any(fnmatch.fnmatchcase(p, pattern) for pattern in include):
            excluded.append((p, rule, len(peripheral_registers(root, p))))
        else:
            regs += peripheral_registers(root, p)
    state_rules = [] if args.compare_state else [
        x for x in rules if x.kind in ("state", "state-mask") or (x.kind == "state-enable-clocks" and args.enable_clocks)]
    # one line per rule, on stderr with --list, which prints the registers on stdout
    for rule in dict.fromkeys(rule for _, rule, _ in excluded):
        hit = [(p, count) for p, r, count in excluded if r is rule]
        total = sum(count for _, count in hit)
        if len(hit) == 1:
            what, read = hit[0][0], f"--include {hit[0][0]} reads it"
        else:
            what, read = rule.pattern, f"--include '{rule.pattern}' reads them"
            what += " (" + ", ".join(p for p, _ in hit[:3]) + (", ..." if len(hit) > 3 else "") + ")"
        print(f"skipped     {what}: {rule.reason} ({len(hit)} block(s), {total} register(s); {read})",
              file=sys.stderr if args.list else sys.stdout)
    if args.read_destructive and not args.list:
        n = sum(1 for r in regs if r.read_action)
        print(f"svd_probe: WARNING: --read-destructive: {n} register(s) have a read side effect (data is consumed, status "
              "is cleared); the board state is changed by this run", file=sys.stderr)
    if args.list:
        for r in regs:
            reset = "none" if r.reset is None else f"0x{r.reset:X}"
            print(f"0x{r.address:08X} {r.size:2} {r.name} reset {reset} mask 0x{r.mask:X}"
                  + (f" readAction {r.read_action}" if r.read_action else "")
                  + state_marker(r.name, state_rules))
        return 0
    try:
        blocks = parse_blocks(args.block)
    except ValueError as e:
        print(f"svd_probe: {e}", file=sys.stderr)
        return 2
    try:
        target = OpenOcd(args.host, args.port, args.timeout)
    except OSError as e:
        print(f"svd_probe: cannot connect to OpenOCD at {args.host}:{args.port}: {e}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("svd_probe: interrupted while connecting; nothing was changed on the target", file=sys.stderr)
        return EXIT_INTERRUPTED
    abort = None
    interrupted = False
    keep_halted = False  # the debug module is stuck: nothing more may be sent to it, not even the resume
    result = Result()
    try:
        # Reads go through the debug module of a halted hart (not the system bus).
        target.command(f"targets {args.target}")
        halt_reply = "" if args.no_halt else target.command("halt")
        note_other_harts(halt_reply, args.target)
        verify_halted(target, args.target, halt_reply)
        target.command("riscv set_prefer_sba off")
        if args.enable_clocks:
            enable_clocks(root, target)
        probe(regs, target, blocks, args.keep_going, args.max_failures, args.read_destructive, state_rules, result)
        result.excluded = sum(count for _, _, count in excluded)
    except Hung as e:
        keep_halted = e.stuck
        abort = str(e) if e.stuck else f"{e}; the bus is probably hung, reset the board; try --enable-clocks or --skip"
    except NotHalted as e:
        abort = str(e)
    except Dead as e:
        abort = (f"{e}\nsvd_probe: OpenOCD drops the session when a program-buffer read hits a bus error; the register "
                 "named above is the likely cause (clock off, peripheral in reset, or a block this device does not have). "
                 "Restart OpenOCD, find the register with --block 1, then --skip it or try --enable-clocks")
    except TooManyFailures as e:
        abort = f"{e}; the rest would fail as well, check OpenOCD and the board (--max-failures to change)"
    except TimeoutError:
        abort = "OpenOCD did not answer a command; the bus is probably hung, reset the board"
    except KeyboardInterrupt:
        # Stop at once. The cleanup below must not wait for an OpenOCD that may be stuck: one resume with a
        # short timeout, no retry, and a second Ctrl+C leaves immediately.
        interrupted = True
        print("svd_probe: interrupted (Ctrl+C), stopping", file=sys.stderr)
    finally:
        problem = None
        try:
            if interrupted:
                hart = ("the hart was not halted by this run" if args.no_halt else resume_after_interrupt(target))
            else:
                hart = None
                problem = None if args.no_halt or keep_halted else resume(target, args)
            target.close()
        except KeyboardInterrupt:  # Ctrl+C during the cleanup
            hart = "interrupted again: the hart may still be halted" + ("" if args.no_halt else
                                                                      " (send 'resume' to OpenOCD or reset the board)")
            interrupted = True
            target.sock.close()
    if interrupted:
        if abort:
            print(f"svd_probe: {abort}", file=sys.stderr)
        print(f"svd_probe: interrupted; of {len(regs)} register(s) selected, {result.failures} not ok before the interrupt "
              "(the lines above are what was read); " + hart, file=sys.stderr)
        return EXIT_INTERRUPTED
    if abort:
        print(f"svd_probe: {abort}", file=sys.stderr)
    if problem:
        print(f"svd_probe: {problem}", file=sys.stderr)
    if abort or problem:
        return 2
    print(f"svd_probe: {len(regs)} register(s), {result.failures} not ok, {result.skipped} skipped, "
          f"{result.read_action} readAction, {result.noref} noref, {result.state} state, {result.excluded} excluded")
    return 1 if result.failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
