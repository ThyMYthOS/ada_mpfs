#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Compare the reset values of SVD registers with a running target.

  svd_probe.py [--svd FILE] [--host H] [--port P] [--target T] [--no-halt] [--block N] [--timeout S] [--keep-going] [--skip P] [--enable-clocks] [--list] [--all | PERIPHERAL...]

Reads every register of the named peripherals (all of them with --all or without
a name) through the OpenOCD telnet port (default localhost:4444) and compares it with <resetValue> under <resetMask>
(all bits if the SVD has no mask). One line per register:

  ok          the value matches
  mismatch    the value differs; read and expected value are shown
  unreadable  the access failed (bus error, timeout)

The selected hart (default mpfs.hart0_e51) is halted for the reads and resumed
afterwards; reads then use the program buffer ("riscv set_prefer_sba off"), as
in the hardware spikes.

The exit code is 1 if any register is not ok. With --list nothing is read: the
registers, their addresses and expected values are printed, so the tool can be
checked without a board.
"""
import argparse
import re
import socket
import sys
from dataclasses import dataclass
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
MD_SUFFIX = {8: "b", 16: "h", 32: "w", 64: "d"}


@dataclass(slots=True)
class Reg:
    """A register to probe: absolute address, access width and expected value."""
    name: str
    address: int
    size: int
    reset: int
    mask: int


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
        for n, idx in enumerate(dim_indices(r)):
            step = int_of(r.findtext("dimIncrement"))
            regs.append(Reg(
                name=f"{name}.{r.findtext('name').replace('%s', idx)}",
                address=base + int_of(r.findtext("addressOffset")) + n * step,
                size=size,
                reset=int_of(r.findtext("resetValue")),
                mask=int_of(r.findtext("resetMask"), (1 << size) - 1),
            ))
    return regs


class OpenOcd:
    """Minimal client of the OpenOCD telnet port.

    The telnet port is used instead of the Tcl RPC port: the OpenOCD that ships
    with Microchip SoftConsole has no read_memory command, and the output of
    md[bhwd] does not come back through the RPC port.
    """

    PROMPT = b"> "

    def __init__(self, host: str, port: int, timeout: float = 30.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self._read()

    def _read(self) -> str:
        buf = b""
        while not buf.endswith(self.PROMPT):
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("OpenOCD closed the connection")
            buf += chunk
        return re.sub(rb"\xff[\xfb-\xfe].", b"", buf).decode("latin1").replace("\r", "").replace("\x00", "")

    def command(self, cmd: str) -> str:
        """Run a command and return its output without the echoed command line and the prompt."""
        self.sock.sendall(cmd.encode() + b"\n")
        lines = self._read().split("\n")
        return "\n".join(lines[1:-1]).strip() if len(lines) > 1 else ""

    def read_block(self, address: int, size: int, count: int) -> list[int]:
        """Read <count> consecutive registers of <size> bits with one md[bhwd] command.

        The reply is "<address>: <value> <value> ..." with several lines for long blocks.
        """
        cmd = f"md{MD_SUFFIX[size]} 0x{address:X} {count}"
        out = self.command(cmd)
        try:
            values = [int(v, 16) for line in out.splitlines() for v in line.split(":", 1)[1].split()]
        except (ValueError, IndexError):
            raise OSError(f"{cmd} replied {out!r}") from None
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


class Hung(Exception):
    """OpenOCD did not answer in time: the bus is probably hung."""


@dataclass(slots=True)
class Result:
    """Counts of a probe run."""
    failures: int = 0
    skipped: int = 0


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
        except (OSError, ValueError, IndexError) as e1:
            e1 = e1 if isinstance(e1, OSError) else OSError(str(e1))
            values.append(e1)
            return values + [OSError(f"not read after the failure at 0x{r.address:08X}")] * (len(run) - len(values))
    return values


def probe(regs: list[Reg], target: OpenOcd, block: int = 512, keep_going: bool = False) -> Result:
    """Read and compare all <regs>; print one line each and return the counts.

    Registers at consecutive addresses are read with one command. After the first
    unreadable register of a peripheral the rest of it is skipped (one line), unless
    <keep_going>. Raises Hung if OpenOCD stops answering.
    """
    result = Result()
    dead: dict[str, int] = {}
    for run in runs(regs, block):
        name = run[0].name.split(".")[0]
        if name in dead:
            dead[name] += len(run)
            continue
        values = read_run(run, target)
        for r, value in zip(run, values):
            if isinstance(value, OSError):
                print(f"unreadable  0x{r.address:08X} {r.name} ({value})")
                result.failures += 1
                if not keep_going:
                    dead[name] = 0
            elif (value ^ r.reset) & r.mask:
                print(f"mismatch    0x{r.address:08X} {r.name} read 0x{value:X}, expected 0x{r.reset:X} (mask 0x{r.mask:X})")
                result.failures += 1
            else:
                print(f"ok          0x{r.address:08X} {r.name}")
    for name, n in dead.items():
        if n:
            print(f"skipped     {name}: {n} more register(s) after the first unreadable one")
            result.skipped += n
    return result


def enable_clocks(root: ET.Element, target: OpenOcd) -> None:
    """Turn on all MSS peripheral clocks and release all peripheral resets (SYSREG)."""
    sysreg = {r.name.split(".")[1]: r for r in peripheral_registers(root, "SYSREG")}
    for name, value in (("SUBBLK_CLOCK_CR", 0xFFFFFFFF), ("SOFT_RESET_CR", 0)):
        target.command(f"mww 0x{sysreg[name].address:X} 0x{value:X}")


def main(argv: list[str]) -> int:
    """Command line entry point; returns the exit code."""
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("peripherals", nargs="*", metavar="PERIPHERAL", help="peripherals to read (default: all)")
    ap.add_argument("--all", action="store_true", help="read all peripherals (the default without PERIPHERAL)")
    ap.add_argument("--svd", type=Path, default=ROOT / "build" / "svd" / "PolarfireSoC.svd",
                    help="merged SVD (default: build/svd/PolarfireSoC.svd, made by ./x svd merge)")
    ap.add_argument("--host", default="localhost")
    ap.add_argument("--port", type=int, default=4444)
    ap.add_argument("--target", default="mpfs.hart0_e51", help="OpenOCD target (hart) to read through (default: %(default)s)")
    ap.add_argument("--no-halt", action="store_true", help="do not halt the hart; it must be halted already")
    ap.add_argument("--block", type=int, default=512, metavar="N",
                    help="read up to N registers at consecutive addresses with one command (default: %(default)s; 1 = one by one)")
    ap.add_argument("--timeout", type=float, default=10.0, metavar="S",
                    help="give up when OpenOCD does not answer for S seconds, probably a hung bus (default: %(default)s)")
    ap.add_argument("--keep-going", action="store_true",
                    help="read the rest of a peripheral after an unreadable register (default: skip it)")
    ap.add_argument("--skip", action="append", default=[], metavar="PERIPHERAL[,PERIPHERAL...]",
                    help="do not read these peripherals (repeatable)")
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
    regs = [r for p in names if p not in skip for r in peripheral_registers(root, p)]
    if args.list:
        for r in regs:
            print(f"0x{r.address:08X} {r.size:2} {r.name} reset 0x{r.reset:X} mask 0x{r.mask:X}")
        return 0
    try:
        target = OpenOcd(args.host, args.port, args.timeout)
    except OSError as e:
        print(f"svd_probe: cannot connect to OpenOCD at {args.host}:{args.port}: {e}", file=sys.stderr)
        return 2
    hung = None
    result = Result()
    try:
        # Reads go through the debug module of a halted hart (not the system bus).
        target.command(f"targets {args.target}")
        if not args.no_halt:
            target.command("halt")
        target.command("riscv set_prefer_sba off")
        if args.enable_clocks:
            enable_clocks(root, target)
        result = probe(regs, target, args.block, args.keep_going)
    except Hung as e:
        hung = e
    finally:
        if not args.no_halt:
            try:
                target.command("resume")
            except OSError:
                pass
        target.close()
    if hung:
        print(f"svd_probe: {hung}; the bus is probably hung, reset the board; try --enable-clocks or --skip", file=sys.stderr)
        return 2
    print(f"svd_probe: {len(regs)} register(s), {result.failures} not ok, {result.skipped} skipped")
    return 1 if result.failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
