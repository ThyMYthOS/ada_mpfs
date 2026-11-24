#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""The register writes of an image under QEMU against the sequence of `./x hw initialize`.

  compare_trace.py TRACE --xml FILE [--svd FILE] [--skip-io] [--fabric-masked ID,ID...]

TRACE is the log of `qemu-system-riscv64 -trace memory_region_ops_read -trace memory_region_ops_write -D TRACE`.
The oracle is hw/mss_init.py: mss_init.full(values) of the XML, run by mss_init.run() (the function that
`./x hw initialize` runs) with functions that stand for the board:

  write   the next write of the trace to an address of the sequence must be this step's (address and value, 32-bit);
  read    gives the last value that the trace shows for that read before the next write. QEMU models some of the
          registers (PVT_STAT, PLL_CTRL) and not others (they read 0), so a Modify is checked against the word the
          image read: what it writes is (read | set) & ~clear. A Poll and an IfSet need a read of the address in
          the trace, and the decision on it is the one the value gives (the image under QEMU takes the same);
  time    a clock that advances with every call and no sleeping, so that a poll that does not succeed on the value
          of the trace is reported as timed out and the sequence goes on (mss_init.run's on_timeout).

The first write of the trace (but for the PLIC and CLINT, which the runtime and the sink use) must be the first
step's, and after the last step only the bring-up of the two ports may follow, as writes to SYSREG: for MMUART2 (the
console) SUBBLK_CLOCK_CR with bit 7 set and SOFT_RESET_CR with it clear, then, after the log has been sent on it, the
same for MMUART0 (bit 5). Both ports are closed until then: no access at all to MMUART0 or MMUART2 may come before
the bring-up of MMUART2, and none to MMUART0 before the last byte of the log has been written to MMUART2. Every other
access counts: the sequence and those four writes are all the image writes, except to the two ports. Their writes
are limited to the 16550 registers of the driver (data or divisor latch, IER or divisor latch, FCR, LCR: no fractional
baud rate register), the divisors are those of the baud rates (MMUART2: 22, MMUART0: 11, DMR 0) and nothing is written
to the IER of MMUART0 but the divisor latch (MMUART0 is driven by polling).

The PLIC: the runtime and the image set it up only after the last write of the table (no priority and no enable bit
before it, so nothing from outside can disturb the sequence), and between that write and the first status line the
priorities and the enable bits of hart 0 (machine mode) are exactly those of the sources the image attaches: MMUART2
(source 92) at level 3 and the 64 fabric sources F2M_0 .. F2M_63 (118 .. 181) at level 1. Afterwards the enable bits
of the sources named in --fabric-masked (the ones the test seam makes fire, which the handler masks) are cleared in the
last write of their enable register, and no others.

Exit status: 0 the writes equal the sequence, 1 they do not (the message names the step), 2 usage or an
unreadable trace or XML.
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "hw"))
import mss_init  # noqa: E402

LINE = re.compile(r"memory_region_ops_(read|write) cpu \d+ mr \S+ addr (0x[0-9a-f]+) value (0x[0-9a-f]+) size (\d+) name '([^']*)'")


class Mismatch(Exception):
    """The trace is not the sequence."""


# The accesses that are not the sequence's: the console (MMUART0, the port of the report; the gate is checked
# apart), CLINT (the proof that MTIME advances reads it) and the PLIC (the runtime sets the source of the sink up,
# the handler claims and completes it).
PORTS = {"MMUART0": (0x20000000, 0x20001000), "MMUART2": (0x20102000, 0x20103000)}
PLIC = (0x0C000000, 0x0C200000)
FABRIC = range(118, 182)
MMUART2_SOURCE = 92
IGNORED = (*PORTS.values(), (0x02000000, 0x02010000), (0x0C000000, 0x10000000))
SUBBLK_CLOCK_CR, SOFT_RESET_CR = 0x20002084, 0x20002088
BIT = {"MMUART0": 1 << 5, "MMUART2": 1 << 7}   # the bit of the port in the MMUART field of both SYSREG registers
DATA, IER, FCR, LCR = 0x00, 0x04, 0x08, 0x0C   # offsets of the 16550 registers the driver writes
DIVISOR = {"MMUART2": 22, "MMUART0": 11}       # 40 MHz / (16 * 115200) and / (16 * 230400), rounded


def count(steps, kind) -> int:
    return sum((isinstance(s, kind)) + count(getattr(s, "then", ()), kind) for s in steps)


def events(path: Path):
    """(the events of the sequence, the indices of the accesses to MMUART0), each event as (kind, address, value,
    size, index in the trace)."""
    out, console, plic = [], [], []
    with open(path, encoding="utf-8", errors="replace") as f:
        n = 0
        for line in f:
            m = LINE.search(line)
            if not m:
                continue
            n += 1
            address = int(m.group(2), 16)
            port = next((name for name, (low, high) in PORTS.items() if low <= address < high), None)
            if PLIC[0] <= address < PLIC[1]:
                plic.append((m.group(1), address - PLIC[0], int(m.group(3), 16), n))
            if port:
                console.append((port, m.group(1), address - PORTS[port][0], int(m.group(3), 16), int(m.group(4)), n))
            elif not any(low <= address < high for low, high in IGNORED):
                out.append((m.group(1), address, int(m.group(3), 16), int(m.group(4)), n))
    return out, console, plic


def check_plic(plic, last, first_tick, masked) -> None:
    """The PLIC writes before the last write of the table, after it, and the masks (see the module text)."""
    def priority(offset):
        return 4 <= offset < 0x1000

    def enable(offset):   # hart 0, machine mode: six words from 0x2000
        return 0x2000 <= offset < 0x2018

    for kind, offset, value, n in plic:
        if kind == "write" and n < last and ((priority(offset) and value) or (enable(offset) and value)):
            raise Mismatch(f"PLIC write of 0x{value:X} to offset 0x{offset:X} before the last write of the table: "
                           "no source may be set up while the hardware is configured")
    window = [e for e in plic if e[0] == "write" and last < e[3] < first_tick]
    levels = {offset // 4: value for kind, offset, value, n in window if priority(offset) and value}
    want = {MMUART2_SOURCE: 3, **{i: 1 for i in FABRIC}}
    if levels != want:
        missing = sorted(set(want) - set(levels))
        extra = sorted(set(levels) - set(want))
        wrong = sorted(i for i in set(levels) & set(want) if levels[i] != want[i])
        raise Mismatch(f"PLIC priorities after the sequence: missing sources {missing}, unexpected {extra}, wrong level {wrong}")
    enabled = set()
    for kind, offset, value, n in window:
        if enable(offset):
            word = (offset - 0x2000) // 4
            enabled |= {32 * word + b for b in range(32) if value >> b & 1}
    if enabled != set(want):
        raise Mismatch(f"PLIC enable bits after the sequence: missing {sorted(set(want) - enabled)}, "
                       f"unexpected {sorted(enabled - set(want))}")
    final = {}
    for kind, offset, value, n in plic:
        if kind == "write" and enable(offset) and n > last:
            final[(offset - 0x2000) // 4] = value
    still = {32 * w + b for w, v in final.items() for b in range(32) if v >> b & 1}
    if still != set(want) - set(masked):
        raise Mismatch(f"PLIC enable bits at the end: {sorted(still ^ (set(want) - set(masked)))} differ from the expected "
                       f"(all attached sources but the masked ones {sorted(masked)})")


def compare(ev, steps, console, plic=None, masked=()) -> str:
    """The summary if the writes of <ev> are those of <steps>; Mismatch otherwise."""
    first = next((i for i, e in enumerate(ev) if e[0] == "write"), None)
    if first is None or ev[first][1] != steps[0].address:
        raise Mismatch(f"the first write of the image is not the first step's, 0x{steps[0].address:08X}: "
                       "something is written before the sequence (or the image did not run it)")
    state = {"cursor": first, "writes": 0, "timeouts": 0}

    def next_write(start: int) -> int | None:
        return next((j for j in range(start, len(ev)) if ev[j][0] == "write"), None)

    def write(address: int, value: int, what: str) -> None:
        j = next_write(state["cursor"])
        n = state["writes"] + 1
        if j is None:
            raise Mismatch(f"write {n} ({what}): the trace has no more writes, wanted 0x{address:08X} = 0x{value:08X}")
        _, got_address, got_value, size, _ = ev[j]
        if (got_address, got_value, size) != (address, value, 4):
            raise Mismatch(f"write {n} ({what}): wanted 0x{address:08X} = 0x{value:08X} (32-bit), "
                           f"the image wrote 0x{got_address:08X} = 0x{got_value:08X} ({size * 8}-bit)")
        state["cursor"] = j + 1
        state["writes"] = n

    def read(address: int) -> int:
        end = next_write(state["cursor"])
        end = len(ev) if end is None else end
        for k in range(end - 1, state["cursor"] - 1, -1):
            if ev[k][0] == "read" and ev[k][1] == address:
                return ev[k][2]
        raise Mismatch(f"after write {state['writes']}: no read of 0x{address:08X} before the next write, "
                       "which a poll, a read-modify-write or a decision of the sequence needs")

    def timed_out(step) -> None:
        state["timeouts"] += 1

    ticks = [0.0]

    def clock() -> float:
        ticks[0] += 1.0
        return ticks[0]

    mss_init.run(steps, write, read, sleep=lambda seconds: None, monotonic=clock, on_timeout=timed_out)
    last = ev[state["cursor"] - 1][4]
    rest = [e for e in ev[state["cursor"]:] if e[0] == "write"]
    want = [(SUBBLK_CLOCK_CR, "MMUART2", True), (SOFT_RESET_CR, "MMUART2", False),
            (SUBBLK_CLOCK_CR, "MMUART0", True), (SOFT_RESET_CR, "MMUART0", False)]
    if len(rest) != 4 or any(e[1] != w[0] or bool(e[2] & BIT[w[1]]) != w[2] or e[3] != 4 for e, w in zip(rest, want)):
        raise Mismatch(f"after the last step: {[(hex(e[1]), hex(e[2])) for e in rest]}, wanted only the bring-up of "
                       "MMUART2 and then of MMUART0 (SUBBLK_CLOCK_CR with the bit of the port set, SOFT_RESET_CR with it clear)")
    bringup = rest[0][4]
    if bringup < last:
        raise Mismatch("the bring-up of the console comes before the last write of the sequence")
    early = [c for c in console if c[5] < bringup]
    if early:
        raise Mismatch(f"{len(early)} access(es) to {early[0][0]} before the bring-up of the console, which is after the last "
                       "write of the sequence: the ports must be closed until then")
    if not any(c[0] == "MMUART2" for c in console):
        raise Mismatch("no access to MMUART2 at all: the log was never sent")
    last_log = max((c[5] for c in console if c[0] == "MMUART2" and c[1] == "write" and c[2] == DATA), default=0)
    if rest[2][4] < last_log:
        raise Mismatch("MMUART0 is brought up before the last byte of the log was written to MMUART2")
    first_tick = min((c[5] for c in console if c[0] == "MMUART0"), default=None)
    if first_tick is not None and first_tick < last_log:
        raise Mismatch("MMUART0 is accessed before the last byte of the log was written to MMUART2")
    if plic is not None:
        check_plic(plic, last, first_tick, masked)
    dlab = {"MMUART0": False, "MMUART2": False}
    latches = {"MMUART0": {}, "MMUART2": {}}
    for port, kind, offset, value, size, _ in console:
        if kind != "write":
            continue
        if offset not in (DATA, IER, FCR, LCR) or size != 4:
            raise Mismatch(f"{port}: a write to offset 0x{offset:02X} ({size * 8}-bit): the driver writes the data port, IER, FCR "
                           "and LCR only, whole words (no fractional baud rate register)")
        if offset == LCR:
            dlab[port] = bool(value & 0x80)
        elif dlab[port] and offset in (DATA, IER):
            latches[port]["DLR" if offset == DATA else "DMR"] = value
        elif offset == IER and port == "MMUART0":
            raise Mismatch(f"MMUART0: a write of 0x{value:02X} to IER with DLAB clear: this port is driven by polling")
    for port, divisor in DIVISOR.items():
        if latches[port] != {"DLR": divisor % 256, "DMR": divisor // 256}:
            raise Mismatch(f"{port}: the divisor latches are {latches[port]}, wanted DLR {divisor % 256} and DMR {divisor // 256}")
    return (f"{state['writes']} writes equal the sequence of {len(steps)} steps (the ports and the PLIC untouched until the last write, 64 fabric sources attached at level 1 after it, MMUART2 divisor 22, MMUART0 divisor 11 after the log; {count(steps, mss_init.Modify)} "
            f"Modify steps checked against the word read, {count(steps, mss_init.IfSet)} IfSet decided by a read, "
            f"{count(steps, mss_init.Poll)} polls of which {state['timeouts']} are not met by the value of the trace)")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").split("\n")[0])
    ap.add_argument("trace", type=Path)
    ap.add_argument("--xml", type=Path, required=True)
    ap.add_argument("--svd", type=Path)
    ap.add_argument("--skip-io", action="store_true")
    ap.add_argument("--fabric-masked", default="", help="comma-separated source IDs that the handler masked")
    args = ap.parse_args(argv)
    try:
        values = mss_init.load(args.xml, args.svd)
    except mss_init.XmlError as err:
        print(f"compare_trace: {err}", file=sys.stderr)
        return 2
    steps = mss_init.full(values, io=not args.skip_io)
    try:
        ev, console, plic = events(args.trace)
    except OSError as err:
        print(f"compare_trace: {err}", file=sys.stderr)
        return 2
    if not ev:
        print("no access to the registers of the sequence in the trace (QEMU without the trace events, or the image did not run)")
        return 1
    try:
        masked = tuple(int(x) for x in args.fabric_masked.split(",") if x)
        print(compare(ev, steps, console, plic, masked))
    except Mismatch as err:
        print(err)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
