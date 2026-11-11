#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Set up the L2 scratchpad at 0x0A000000 through OpenOCD, as the platform HAL (config_l2_cache) does.

    l2_scratchpad.py [--cache-ways N] [--scratchpad-ways N] [--target T] [--lab FILE]

Boot mode 0 runs no boot software, so nothing enables the ways that images placed with `--memory scratchpad`
(place-scratchpad.ld) run in. This does, with hart 0 halted by this script (the cache accesses are its):

  1. WayEnable = cache ways + scratchpad ways - 1 (the LIM keeps the other 15 - WayEnable ways),
  2. every WayMask register (DMA, AXI4 slave ports, the L1 of all harts) = the cache ways only, so that no master
     allocates in a scratchpad way,
  3. for each scratchpad way: the WayMask of the E51 D cache = that way, zeros written to a 128 KB range of the
     zero device at 0x0A000000 (`mwd ADDR 0 COUNT`, which allocates the lines in that way), then the mask is set back,
  4. a check: a pattern is written to the ends of both ranges and read back, then the zeros are written again.

Defaults are those of `--memory scratchpad` (config/gen/standalone.py): 1 cache way, 2 scratchpad ways (256 KB).
Run it after `./x hw reset` and `./x hw initialize`: a reset puts WayEnable and the masks back, and the fill takes a few
seconds. Images are then loaded with `./x hw run`, which does not reset the board.

Exit status: 0 done and checked, 2 a check failed or the set-up is wrong (no OpenOCD).
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab  # noqa: E402
from svd_probe import Dead, OpenOcd  # noqa: E402

CACHE_CTRL = 0x02010000
WAY_ENABLE = CACHE_CTRL + 0x08
WAY_MASKS = range(CACHE_CTRL + 0x800, CACHE_CTRL + 0x878, 8)   # DMA, AXI4 0..3, E51 D/I, U54 1..4 D/I
E51_DCACHE_MASK = CACHE_CTRL + 0x828
ZERO_DEVICE = 0x0A000000
WAY_BYTES = 0x20000


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--cache-ways", type=int, default=1)
    ap.add_argument("--scratchpad-ways", type=int, default=2)
    ap.add_argument("--target", default="mpfs.hart0_e51", help="the hart that does the accesses (default: %(default)s)")
    ap.add_argument("--lab", metavar="FILE")
    a = ap.parse_args(argv)
    if a.cache_ways < 1 or a.scratchpad_ways < 1 or a.cache_ways + a.scratchpad_ways > 16:
        print("l2_scratchpad: need at least one cache way and one scratchpad way, 16 ways in all", file=sys.stderr)
        return 2
    lab_conf = lab.load(a.lab)
    try:
        ocd = OpenOcd(lab_conf["OCD_HOST"], int(lab_conf["OCD_PORT"]), 30.0)
    except OSError as e:
        print(f"l2_scratchpad: cannot connect to OpenOCD at {lab_conf['OCD_HOST']}:{lab_conf['OCD_PORT']} ({e})", file=sys.stderr)
        return 2
    try:
        ocd.command(f"targets {a.target}")
        ocd.command("riscv set_prefer_sba off")
        ocd.command("halt")
        ways = a.cache_ways + a.scratchpad_ways
        ocd.command(f"mwb 0x{WAY_ENABLE:x} {ways - 1}")
        got = ocd.read(WAY_ENABLE, 32) & 0xFF
        if got != ways - 1:
            print(f"l2_scratchpad: WayEnable reads {got}, wanted {ways - 1}", file=sys.stderr)
            return 2
        cache_mask = (1 << a.cache_ways) - 1
        for reg in WAY_MASKS:
            ocd.command(f"mwd 0x{reg:x} 0x{cache_mask:x}")
        for n in range(a.scratchpad_ways):
            way = a.cache_ways + n
            base = ZERO_DEVICE + n * WAY_BYTES
            ocd.command(f"mwd 0x{E51_DCACHE_MASK:x} 0x{1 << way:x}")
            ocd.command(f"mwd 0x{base:x} 0 {WAY_BYTES // 8}", timeout=120)   # every line of the range, 64 bits at a time
            print(f"l2_scratchpad: way {way} holds 0x{base:08X} .. 0x{base + WAY_BYTES - 1:08X}", flush=True)
        ocd.command(f"mwd 0x{E51_DCACHE_MASK:x} 0x{cache_mask:x}")
        spots = []
        for n in range(a.scratchpad_ways):
            spots += [ZERO_DEVICE + n * WAY_BYTES, ZERO_DEVICE + (n + 1) * WAY_BYTES - 8]
        for i, addr in enumerate(spots):
            ocd.command(f"mwd 0x{addr:x} 0x{(0x1111 * (i + 1) << 48) | addr:x}")
        bad = []
        for i, addr in enumerate(spots):
            value = ocd.read(addr + 4, 32) << 32 | ocd.read(addr, 32)
            if value != (0x1111 * (i + 1) << 48) | addr:
                bad.append(f"0x{addr:08X} reads 0x{value:016X}")
        for addr in spots:
            ocd.command(f"mwd 0x{addr:x} 0")
        if bad:
            print("l2_scratchpad: the check failed: " + "; ".join(bad), file=sys.stderr)
            return 2
        print(f"l2_scratchpad: done, {a.scratchpad_ways} scratchpad way(s) of {WAY_BYTES // 1024} KB at 0x{ZERO_DEVICE:08X}, "
              f"WayEnable {ways - 1}, the LIM has {15 - (ways - 1)} ways")
    except KeyboardInterrupt:
        return 130
    except (OSError, Dead) as e:
        print(f"l2_scratchpad: {e}; see docs/lab/openocd.md", file=sys.stderr)
        return 2
    finally:
        ocd.close()
    return 0


if __name__ == "__main__":
    sys.exit(lab.run(main))
