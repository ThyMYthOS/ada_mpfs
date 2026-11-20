#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""The register writes of an image under QEMU against the sequence of `./x hw initialize`.

  compare_trace.py TRACE --xml FILE [--svd FILE] [--skip-io]

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

The trace is read from the first write to the address of the first step on: the console of the runtime is brought
up before (two writes to SYSREG, which the sequence's Modify of SUBBLK_CLOCK_CR and SOFT_RESET_CR would be confused
with). After the last step no other write may follow. Every other access counts: the sequence is all the image
writes, except to its console (MMUART0).

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


# The accesses that are not the sequence's: the console (MMUART0, the port of the report) and CLINT (the proof
# that MTIME advances reads it).
IGNORED = ((0x20000000, 0x20001000), (0x02000000, 0x02010000))


def count(steps, kind) -> int:
    return sum((isinstance(s, kind)) + count(getattr(s, "then", ()), kind) for s in steps)


def events(path: Path) -> list[tuple[str, int, int, int]]:
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = LINE.search(line)
            if m and not any(low <= int(m.group(2), 16) < high for low, high in IGNORED):
                out.append((m.group(1), int(m.group(2), 16), int(m.group(3), 16), int(m.group(4))))
    return out


def compare(ev: list[tuple[str, int, int, int]], steps) -> str:
    """The summary if the writes of <ev> are those of <steps>; Mismatch otherwise."""
    first = next((i for i, e in enumerate(ev) if e[0] == "write" and e[1] == steps[0].address), None)
    if first is None:
        raise Mismatch(f"no write to 0x{steps[0].address:08X}, the first address of the sequence: the image did not run it")
    state = {"cursor": first, "writes": 0, "timeouts": 0}

    def next_write(start: int) -> int | None:
        return next((j for j in range(start, len(ev)) if ev[j][0] == "write"), None)

    def write(address: int, value: int, what: str) -> None:
        j = next_write(state["cursor"])
        n = state["writes"] + 1
        if j is None:
            raise Mismatch(f"write {n} ({what}): the trace has no more writes, wanted 0x{address:08X} = 0x{value:08X}")
        _, got_address, got_value, size = ev[j]
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
    rest = [e for e in ev[state["cursor"]:] if e[0] == "write"]
    if rest:
        raise Mismatch(f"{len(rest)} write(s) after the last step, the first 0x{rest[0][1]:08X} = 0x{rest[0][2]:08X}")
    return (f"{state['writes']} writes equal the sequence of {len(steps)} steps ({count(steps, mss_init.Modify)} "
            f"Modify steps checked against the word read, {count(steps, mss_init.IfSet)} IfSet decided by a read, "
            f"{count(steps, mss_init.Poll)} polls of which {state['timeouts']} are not met by the value of the trace)")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").split("\n")[0])
    ap.add_argument("trace", type=Path)
    ap.add_argument("--xml", type=Path, required=True)
    ap.add_argument("--svd", type=Path)
    ap.add_argument("--skip-io", action="store_true")
    args = ap.parse_args(argv)
    try:
        values = mss_init.load(args.xml, args.svd)
    except mss_init.XmlError as err:
        print(f"compare_trace: {err}", file=sys.stderr)
        return 2
    steps = mss_init.full(values, io=not args.skip_io)
    try:
        ev = events(args.trace)
    except OSError as err:
        print(f"compare_trace: {err}", file=sys.stderr)
        return 2
    if not ev:
        print("no access to the registers of the sequence in the trace (QEMU without the trace events, or the image did not run)")
        return 1
    try:
        print(compare(ev, steps))
    except Mismatch as err:
        print(err)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
