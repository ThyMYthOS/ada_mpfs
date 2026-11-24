#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# @req HW-002
"""Do through OpenOCD what the first-stage boot software does to the MSS before the clock switch.

    initialize.py [--xml FILE] [--svd FILE] [--minimal] [--skip-io] [--dry-run] [--target T] [--lab FILE]

Boot mode 0 leaves the MSS as the reset left it: CLINT.MTIME does not count and the SGMII/DDR PHY block is not
set up. This runs the register writes of Microchip's mss_nwc_init without the switch of the MSS clock (hw/mss_init.py
lists them): the RTC divisor, the SCB access timer, the dynamic enables, the IO mux and bank set-up, the MSSIO
handshake, the SGMII channel set-up (reset, calibration, PLL and DLL lock) and the MSS PLL up to its lock. ENVM_CR,
CLOCK_CONFIG_CR and MSSCLKMUX stay as they are, so the CPU keeps its boot clock. It also clears the PLIC enables
and fcsr of the U54 (hw/hart_state.py), as ./x hw reset does. With the hart halted by this
script and resumed at the end.

The values that the MSS Configurator XML of the board has (the RTC period, the IO mux and banks, the SGMII channel
registers, the MSS PLL and its multiplexers) come from that XML, read by the reader of config/gen/mpfs_gen. The XML
is required: --xml FILE, or else the key MSS_XML of the lab configuration (a relative path there is relative to the
root of the repository). The reader checks it against the merged SVD: --svd FILE, or else
build/svd/PolarfireSoC.svd, made current first (tools/svd.py ensure, which needs svdtools only if it is missing or
stale).

  --xml FILE  the MSS Configurator XML of the board (default: MSS_XML of lab.conf)
  --svd FILE  the merged SVD the reader checks the XML against
  --minimal   only what CLINT.MTIME needs (the sequence --enable-clocks of svd_probe.py uses)
  --skip-io   leave out the IO mux and bank set-up (SYSREG.IOMUX*, MSSIO_BANK*_CFG)
  --dry-run   print the XML, its SHA-256 and the steps with their values, write nothing (no OpenOCD needed)

The writes change the state of the board until the next reset or power cycle; `./x hw reset` undoes them. Run it
once after a power cycle: a second run sets up the SGMII block again.

Exit status: 0 done, 2 the set-up is wrong or a step failed (no XML, an XML the reader rejects, no OpenOCD, a poll
ran out of time, a hung debug module; power-cycle the board), 130 after Ctrl+C.
"""
import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hart_state  # noqa: E402
import lab  # noqa: E402
import mss_init  # noqa: E402
from svd_probe import DebugHang, Dead, OpenOcd  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").split("\n")[0])
    ap.add_argument("--xml", type=Path, metavar="FILE", help="the MSS Configurator XML of the board (default: MSS_XML of lab.conf)")
    ap.add_argument("--svd", type=Path, metavar="FILE",
                    help="the merged SVD to check the XML against (default: build/svd/PolarfireSoC.svd, made current)")
    ap.add_argument("--minimal", action="store_true", help="only the steps CLINT.MTIME needs")
    ap.add_argument("--skip-io", action="store_true", help="leave out the IO mux and bank set-up")
    ap.add_argument("--dry-run", action="store_true", help="print the XML and the steps with their values, write nothing")
    ap.add_argument("--target", default="mpfs.hart0_e51", help="OpenOCD target to select (default: %(default)s)")
    ap.add_argument("--lab", metavar="FILE")
    a = ap.parse_args(argv)

    lab_conf = lab.load(a.lab)
    try:
        values = mss_init.load(lab.mss_xml(a.xml, lab_conf, "initialize"), a.svd)
    except mss_init.XmlError as e:
        print(f"initialize: {e}", file=sys.stderr)
        return 2
    steps = mss_init.refclk(values) if a.minimal else mss_init.full(values, io=not a.skip_io)

    if a.dry_run:
        for line in mss_init.header(values, steps):
            print(line)
        for step in steps:
            print(mss_init.describe(step))
        print("clear the PLIC enables of all nine contexts and fcsr of the four U54 (hw/hart_state.py)")
        return 0

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
        for line in mss_init.header(values, steps):
            print(line, flush=True)
        mss_init.run(steps, write, read, lambda text: print(text, flush=True))
        for problem in hart_state.clear(ocd.command, a.target):
            print(f"initialize: {problem} (is the hart halted? ./x hw reset halts all)", file=sys.stderr)
        print("initialize: PLIC enables and fcsr cleared")
        print(f"initialize: done ({len(steps)} steps); CLINT.MTIME now reads {read(mss_init.MTIME):#x}")
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
    sys.exit(lab.run(main, uses_hart=False))
