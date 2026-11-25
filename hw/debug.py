#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Connect the GDB of the toolchain to the OpenOCD of the board, and load an image if asked to.

    debug.py [ELF] [--hart N] [--load] [--port P] [--lab FILE] [--gdb FILE] [--dry-run] [-- GDB-ARGUMENTS]

GDB is riscv64-elf-gdb of the pinned toolchain (tools/toolchain.env), started on ELF (the symbols) and connected
to the gdb port of the OpenOCD that ./x hw openocd runs: OCD_HOST and OCD_GDB_PORT of lab.conf. OpenOCD has one gdb port for
all five harts: its configuration puts them in one SMP group (target smp, -rtos hwthread), and GDB sees them as the threads 1
to 5, thread N + 1 being hart N. --hart N makes GDB switch to that thread after it has connected, so that the registers,
the breakpoints and `continue` are those of the hart. --port names the port of another OpenOCD (several boards).
Arguments after -- go to GDB.

Without --load the image on the board is left as it is, and ELF is for symbols only (compare-sections tells whether the board
runs it). --load halts the hart, clears the enables of the PLIC (hw/hart_state.py), writes the image the way ./x hw run does
(whole 64-byte lines, hw/run_image.py: LIM is ECC memory and a half-written line faults; GDB's own load does not do that),
sets pc to the entry point and starts GDB on it, so `continue` runs the image from its start and a breakpoint on main works.
--dry-run prints what would be done and loads nothing. OpenOCD is not started by this tool.
Exit status 2: set-up error (no OpenOCD on the port, no toolchain, bad arguments).
"""
import argparse
import os
import socket
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hart_state  # noqa: E402
import lab  # noqa: E402
import run_image  # noqa: E402
from ocd import OCD  # noqa: E402


def gdb_port(values, option=None):
    """The gdb port of OpenOCD: <option> if given, else OCD_GDB_PORT of the lab settings (one port for all harts)."""
    if option is not None:
        return option
    port = values["OCD_GDB_PORT"]
    if not port.isdigit():
        raise SystemExit(f"debug: OCD_GDB_PORT must be a number, got '{port}'")
    return int(port)


def gdb_command(gdb, elf, host, port, hart, rest=(), loaded=False):
    """The command line of GDB: the symbols of ELF, the connection, the thread of HART (thread N + 1 is hart N) and, after a
    load, the check that the board has the image."""
    cmd = [str(gdb), "-q"]
    if elf:
        cmd.append(elf)
    cmd += ["-ex", f"target remote {host}:{port}", "-ex", f"thread {hart + 1}"]
    if loaded:
        cmd += ["-ex", "compare-sections"]
    return cmd + list(rest)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("elf", nargs="?")
    ap.add_argument("--hart", type=int, default=0)
    ap.add_argument("--load", action="store_true")
    ap.add_argument("--port", type=int)
    ap.add_argument("--lab", metavar="FILE")
    ap.add_argument("--gdb", metavar="FILE", help="this GDB instead of the one of the toolchain")
    ap.add_argument("--dry-run", action="store_true")
    argv = list(sys.argv[1:] if argv is None else argv)
    rest = []
    if "--" in argv:   # what follows is for GDB, whatever it looks like
        i = argv.index("--")
        argv, rest = argv[:i], argv[i + 1:]
    a = ap.parse_args(argv)
    a.rest = rest
    if a.hart not in range(5):
        raise SystemExit(f"debug: invalid hart {a.hart} (0 = E51, 1-4 = U54)")
    if a.load and not a.elf:
        raise SystemExit("debug: --load needs an ELF (an example or a file)")
    if a.elf and not os.path.isfile(a.elf):
        raise SystemExit(f"debug: cannot read {a.elf}")
    values = lab.load(a.lab)
    gdb = a.gdb or lab.toolchain_bin() / "riscv64-elf-gdb"
    if not os.path.isfile(gdb):
        raise SystemExit(f"debug: {gdb} not found (./x toolchain install)")
    host, port = values["OCD_HOST"], gdb_port(values, a.port)
    cmd = gdb_command(gdb, a.elf, host, port, a.hart, a.rest, a.load)
    if a.dry_run:
        print(" ".join(cmd))
        if a.load:
            print(f"load {a.elf} onto hart {a.hart} through the telnet port {values['OCD_HOST']}:{values['OCD_PORT']}")
        return 0
    try:
        socket.create_connection((host, port), timeout=3).close()
    except OSError as e:
        raise SystemExit(f"debug: cannot connect to the gdb port of OpenOCD at {host}:{port} ({e}); ./x hw openocd starts "
                         "OpenOCD with the port OCD_GDB_PORT of lab.conf (OCD_HOST is the host; --port names another port)")
    if a.load:
        with open(a.elf, "rb") as f:
            entry, segs = run_image.parse_elf(f.read())
        tmp, ocd_path = lab.ocd_tempdir(values)
        o = OCD(int(values["OCD_PORT"]), values["OCD_HOST"])
        o.hart(a.hart)
        o.cmd("halt")
        hart_state.clear_plic(o.cmd)
        run_image.load_segments(o, tmp, ocd_path, segs)
        o.cmd(f"reg pc 0x{entry:x}")
        print(f"hart {a.hart}: halted at the entry {entry:#x}; `continue` runs the image from its start")
    sys.stdout.flush()
    os.execv(cmd[0], cmd)


if __name__ == "__main__":
    sys.exit(lab.run(main))
