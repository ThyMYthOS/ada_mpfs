#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Assemble a probe (probe_*.S), run it on one hart and print the result words at 0x08102000.

    run_probe.py probe_irq.S 1 [--words N] [--secs S] [--expect REGEX] [--lab FILE]

Probes are linked at 0x08104000 and signal completion with a non-zero word in their result block.
The board must be in boot mode 0 with OpenOCD running (start_openocd.sh, or ./x hw openocd).

The result lines are "[ byte offset] = 0xVALUE". With --expect REGEX the exit status says whether the
result block shows what the probe should produce: 0 if REGEX (Python syntax) matches one of the lines,
1 if it does not. Without --expect the exit status is 0 when the probe ran. 2: set-up error.
The RISC-V compiler is the version pinned in tools/toolchain.env.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lab  # noqa: E402
from ocd import OCD  # noqa: E402

BASE = 0x08104000
RESULT = 0x08102000


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("source")
    ap.add_argument("hart", type=int)
    ap.add_argument("--words", type=int, default=8)
    ap.add_argument("--secs", type=float, default=2)
    ap.add_argument("--expect", metavar="REGEX")
    ap.add_argument("--lab", metavar="FILE")
    a = ap.parse_args(argv)
    if a.hart not in range(5):
        raise SystemExit(f"run_probe: invalid hart {a.hart} (0 = E51, 1-4 = U54)")
    regex = None
    if a.expect is not None:
        try:
            regex = re.compile(a.expect)
        except re.error as e:
            raise SystemExit(f"run_probe: invalid --expect regular expression: {e}")
    source = a.source if os.path.isfile(a.source) else os.path.join(HERE, a.source)
    if not os.path.isfile(source):
        raise SystemExit(f"run_probe: no such probe: {a.source}")

    lab_conf = lab.load(a.lab)
    tc = lab.toolchain_bin()
    tmp = tempfile.mkdtemp()
    elf, binf = os.path.join(tmp, "p.elf"), os.path.join(tmp, "p.bin")
    subprocess.run([str(tc / "riscv64-elf-gcc"), "-march=rv64imac_zicsr", "-mabi=lp64", "-nostdlib", "-Wl,-e,_start",
                    f"-Wl,-Ttext={BASE:#x}", "-o", elf, source], check=True)
    subprocess.run([str(tc / "riscv64-elf-objcopy"), "-O", "binary", elf, binf], check=True)
    with open(binf, "rb") as f:
        data = f.read()
    with open(binf, "wb") as f:
        f.write(data + bytes(-len(data) % 64))

    o = OCD(int(lab_conf["OCD_PORT"]), lab_conf["OCD_HOST"])
    o.hart(a.hart)
    o.cmd("halt")
    o.cmd("riscv set_prefer_sba off")
    for i in range(a.words):
        o.cmd(f"mwd 0x{RESULT + 8 * i:x} 0")
    o.cmd(f"load_image {binf} {BASE:#x} bin")
    o.cmd(f"reg mcause 0; reg mie 0; reg pc {BASE:#x}")
    o.cmd("resume")
    time.sleep(a.secs)
    o.cmd("halt")
    lines = [f"[{8 * i:2d}] = {o.rd64(RESULT + 8 * i):#x}" for i in range(a.words)]
    print("\n".join(lines))
    if regex is None:
        return 0
    if any(regex.search(line) for line in lines):
        print(f"expect: matched /{regex.pattern}/")
        return 0
    print(f"expect: NOT matched /{regex.pattern}/ in the result block")
    return 1


if __name__ == "__main__":
    sys.exit(lab.run(main))
