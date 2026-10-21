#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Reset the Icicle Kit to its power-on state through OpenOCD, also after a hung debug module.

    reset.py [--svd FILE] [--target T] [--lab FILE]

Runs the sequence of hw/recover.py: reads abstractcs (riscv dmi_read 0x16), clears cmderr (riscv dmi_write 0x16
0x700), sends "reset halt" and checks that SYSREG.SUBBLK_CLOCK_CR and SYSREG.SOFT_RESET_CR have their power-on
values (resetValue of the SVD); if not, it toggles the debug module and tries once more. Every step prints the
reply of OpenOCD. The hart stays halted. A reset undoes everything that was written (clocks, --poke) and any PLL or
boot state; it is also fine when nothing is hung. Host and port of OpenOCD come from lab.conf.

Exit status: 0 the check passed, 2 it failed (power-cycle the board and restart OpenOCD) or the set-up is wrong
(no OpenOCD, no merged SVD), 130 after Ctrl+C.
"""
import argparse
import os
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab  # noqa: E402
import recover  # noqa: E402
from svd_probe import Dead, OpenOcd, peripheral_registers  # noqa: E402


def checks_from_svd(root: ET.Element) -> list[recover.Check]:
    """SYSREG.SUBBLK_CLOCK_CR and SYSREG.SOFT_RESET_CR with their reset values."""
    regs = {r.name: r for r in peripheral_registers(root, "SYSREG")}
    found = []
    for name in ("SUBBLK_CLOCK_CR", "SOFT_RESET_CR"):
        reg = regs.get(f"SYSREG.{name}")
        if reg is None or reg.reset is None:
            raise SystemExit(f"reset: the SVD has no SYSREG.{name} with a resetValue")
        found.append(recover.Check(f"SYSREG.{name}", reg.address, reg.reset))
    return found


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--svd", type=Path, default=lab.ROOT / "build" / "svd" / "PolarfireSoC.svd",
                    help="merged SVD (default: build/svd/PolarfireSoC.svd, made by ./x svd merge)")
    ap.add_argument("--target", default="mpfs.hart0_e51", help="OpenOCD target to select (default: %(default)s)")
    ap.add_argument("--lab", metavar="FILE")
    a = ap.parse_args(argv)
    lab_conf = lab.load(a.lab)
    if not a.svd.is_file():
        raise SystemExit(f"reset: {a.svd} not found; run ./x svd merge")
    checks = checks_from_svd(ET.parse(a.svd).getroot())
    try:
        ocd = OpenOcd(lab_conf["OCD_HOST"], int(lab_conf["OCD_PORT"]), 30.0)
    except OSError as e:
        raise SystemExit(f"reset: cannot connect to OpenOCD at {lab_conf['OCD_HOST']}:{lab_conf['OCD_PORT']}: {e}")
    try:
        ocd.command(f"targets {a.target}")
        ocd.command("riscv set_prefer_sba off")
        ok = recover.recover(ocd.command, lambda address: ocd.read(address, 32), checks, lambda text: print(text, flush=True))
    except (OSError, Dead) as e:
        raise SystemExit(f"reset: {e}; {recover.POWER_CYCLE}")
    finally:
        ocd.close()
    if not ok:
        print(f"reset: not verified: {recover.POWER_CYCLE}", file=sys.stderr)
        return 2
    print("reset: done, the hart is halted")
    return 0


if __name__ == "__main__":
    sys.exit(lab.run(main))
