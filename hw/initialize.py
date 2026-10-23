#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Do through OpenOCD what the first-stage boot software does to the MSS before the clock switch.

    initialize.py [--minimal] [--skip-io] [--dry-run] [--target T] [--lab FILE]

Boot mode 0 leaves the MSS as the reset left it: CLINT.MTIME does not count and the SGMII/DDR PHY block is not
set up. This runs the register writes of Microchip's mss_nwc_init without the switch of the MSS clock (hw/mss_init.py
lists them): the RTC divisor, the SCB access timer, the dynamic enables, the IO mux and bank set-up, the MSSIO
handshake, the SGMII channel set-up (reset, calibration, PLL and DLL lock) and the MSS PLL up to its lock. ENVM_CR,
CLOCK_CONFIG_CR and MSSCLKMUX stay as they are, so the CPU keeps its boot clock. With the hart halted by this
script and resumed at the end.

  --minimal   only what CLINT.MTIME needs (the sequence --enable-clocks of svd_probe.py uses)
  --skip-io   leave out the IO mux and bank set-up (SYSREG.IOMUX*, MSSIO_BANK*_CFG)
  --dry-run   print the steps and write nothing (no OpenOCD needed)

The writes change the state of the board until the next reset or power cycle; `./x hw reset` undoes them. Run it
once after a power cycle: a second run sets up the SGMII block again.

Exit status: 0 done, 2 the set-up is wrong or a step failed (no OpenOCD, a poll ran out of time, a hung debug module;
power-cycle the board), 130 after Ctrl+C.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab  # noqa: E402
import mss_init  # noqa: E402
from svd_probe import DebugHang, Dead, OpenOcd  # noqa: E402


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--minimal", action="store_true", help="only the steps CLINT.MTIME needs")
    ap.add_argument("--skip-io", action="store_true", help="leave out the IO mux and bank set-up")
    ap.add_argument("--dry-run", action="store_true", help="print the steps, write nothing")
    ap.add_argument("--target", default="mpfs.hart0_e51", help="OpenOCD target to select (default: %(default)s)")
    ap.add_argument("--lab", metavar="FILE")
    a = ap.parse_args(argv)
    steps = mss_init.REFCLK if a.minimal else mss_init.full(io=not a.skip_io)

    if a.dry_run:
        for step in steps:
            print(mss_init.describe(step))
        return 0

    lab_conf = lab.load(a.lab)
    try:
        ocd = OpenOcd(lab_conf["OCD_HOST"], int(lab_conf["OCD_PORT"]), 30.0)
    except OSError as e:
        print(f"initialize: cannot connect to OpenOCD at {lab_conf['OCD_HOST']}:{lab_conf['OCD_PORT']} ({e}); start it with ./x hw openocd",
              file=sys.stderr)
        return 2

    def write(address: int, value: int, what: str) -> None:
        ocd.command(f"mww 0x{address:X} 0x{value:X}", hang=True)

    def read(address: int) -> int:
        return ocd.read(address, 32)

    halted = False
    try:
        ocd.command(f"targets {a.target}")
        ocd.command("riscv set_prefer_sba off")
        ocd.command("halt")
        halted = True
        mss_init.run(steps, write, read, lambda text: print(text, flush=True))
        print(f"initialize: done ({len(steps)} steps); CLINT.MTIME now reads {read(0x0200BFF8):#x}")
    except KeyboardInterrupt:
        print("initialize: interrupted", file=sys.stderr)
        return 130
    except (mss_init.MssInitError, DebugHang, Dead, OSError, ValueError) as e:
        print(f"initialize: {e}; the board is in an unknown state, see docs/lab/openocd.md (./x hw reset, or a power cycle)", file=sys.stderr)
        return 2
    finally:
        if halted:
            try:
                ocd.command("resume")
            except (OSError, Dead):
                pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
