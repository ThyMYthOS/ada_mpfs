#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""The accesses of an image to SYSREG and to its MMUART, from a QEMU trace.

  check_trace.py TRACE bringup MMUART [PAIRS]   the image clocks and releases MMUART<n> (and no other
                                                peripheral) before it writes a register of the port and so
                                                before the first data byte; every bring-up is the same pair
                                                of writes, PAIRS of them (default 1)
  check_trace.py TRACE none                     the image makes no access, read or write, to SYSREG

TRACE is the log of `qemu-system-riscv64 -trace memory_region_ops_read -trace memory_region_ops_write -D TRACE`.
QEMU's SYSREG reads as 0, so the value of a read-modify-write is exactly the bit of the MMUART.
Exit status: 0 holds, 1 does not, 2 usage or an unreadable trace.
"""
import re
import sys

SYSREG = (0x20002000, 0x20004000)
CLOCK_CR, RESET_CR = 0x20002084, 0x20002088
MMUART = [0x20000000, 0x20100000, 0x20102000, 0x20104000, 0x20106000]
LCR = 0x0C
LINE = re.compile(r"memory_region_ops_(read|write) cpu \d+ mr \S+ addr (0x[0-9a-f]+) value (0x[0-9a-f]+) size (\d+) name '([^']*)'")


def events(path):
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = LINE.search(line)
            if m:
                out.append((m.group(1), int(m.group(2), 16), int(m.group(3), 16), int(m.group(4))))
    return out


def first_data_byte(ev, base):
    """Index of the first write to the data port while LCR.DLAB is clear (a write with DLAB set is the divisor)."""
    dlab = False
    for i, (kind, addr, value, _) in enumerate(ev):
        if kind == "write" and addr == base + LCR:
            dlab = bool(value & 0x80)
        elif kind == "write" and addr == base and not dlab:
            return i
    return None


def main(argv):
    if len(argv) < 3 or argv[2] not in ("bringup", "none") or (argv[2] == "bringup" and len(argv) < 4):
        print(__doc__, file=sys.stderr)
        return 2
    try:
        ev = events(argv[1])
    except OSError as e:
        print(f"check_trace: {e}", file=sys.stderr)
        return 2
    if not ev:
        print("no memory access in the trace (QEMU without the trace events, or the image did not run)")
        return 1
    sys_ev = [(i, e) for i, e in enumerate(ev) if SYSREG[0] <= e[1] < SYSREG[1]]
    if argv[2] == "none":
        if sys_ev:
            kind, addr, value, _ = sys_ev[0][1]
            print(f"{len(sys_ev)} access(es) to SYSREG, the first a {kind} of {addr:#x} ({value:#x})")
            return 1
        print(f"no access to SYSREG in {len(ev)} accesses")
        return 0

    n = int(argv[3])
    pairs = int(argv[4]) if len(argv) > 4 else 1
    bit = 1 << (5 + n)
    writes = [(i, e) for i, e in sys_ev if e[0] == "write"]
    if len(writes) != 2 * pairs:
        print(f"{len(writes)} write(s) to SYSREG, wanted {2 * pairs} ({pairs} x clock and reset): "
              + ", ".join(f"{e[1]:#x}={e[2]:#x}" for _, e in writes))
        return 1
    for k in range(pairs):
        (_, c), (_, r) = writes[2 * k], writes[2 * k + 1]
        if c[1] != CLOCK_CR or r[1] != RESET_CR:
            print(f"bring-up {k + 1} writes {c[1]:#x} and {r[1]:#x}, wanted SUBBLK_CLOCK_CR {CLOCK_CR:#x} "
                  f"and SOFT_RESET_CR {RESET_CR:#x}")
            return 1
        if c[3] != 4 or r[3] != 4:
            print(f"bring-up {k + 1}: the accesses are not 32-bit")
            return 1
        if c[2] != bit:
            print(f"bring-up {k + 1}: SUBBLK_CLOCK_CR gets {c[2]:#x}, wanted only bit {5 + n} ({bit:#x}): MMUART{n}")
            return 1
        if r[2] != 0:
            print(f"bring-up {k + 1}: SOFT_RESET_CR gets {r[2]:#x}, wanted bit {5 + n} clear (0 after a read of 0)")
            return 1
    if any(e[0] == "read" and e[1] not in (CLOCK_CR, RESET_CR) for _, e in sys_ev):
        print("SYSREG is read at an address other than the two registers")
        return 1
    base = MMUART[n]
    first_port = next((i for i, e in enumerate(ev) if base <= e[1] < base + 0x1000), None)
    if first_port is None:
        print(f"no access to MMUART{n} at all")
        return 1
    if writes[0][0] > first_port or writes[1][0] > first_port:
        print(f"MMUART{n} is accessed (event {first_port}) before the clock and the reset are written "
              f"(events {writes[0][0]}, {writes[1][0]})")
        return 1
    first_data = first_data_byte(ev, base)
    if first_data is None or writes[1][0] > first_data:
        print("no data byte after the bring-up")
        return 1
    print(f"MMUART{n}: clock (bit {5 + n}) and reset written as events {writes[0][0]} and {writes[1][0]}, "
          f"the first access to the port is event {first_port}, the first data byte event {first_data}; "
          f"{pairs} bring-up(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
