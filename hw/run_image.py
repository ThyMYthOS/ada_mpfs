#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Load an ELF onto one hart of an Icicle Kit over JTAG, run it, capture the serial ports and report the first trap.

    run_image.py ELF HART [--secs N] [--expect REGEX] [--expect-port N] [--uart-standin] [--div D] [--lab FILE]

Needs OpenOCD running (start_openocd.sh, or ./x hw openocd). The board is expected in boot mode 0 (idle, no HSS).
The host, the port and the serial devices come from lab.conf.

--expect REGEX     the exit status says whether the console showed what the image should print: 0 if
                   REGEX (Python syntax, searched in the text of every port, or of the port named by
                   --expect-port) matches, 1 if it does not (also if nothing was printed at all).
                   Without --expect the exit status is 0 when the run completed. 2: set-up error
                   (OpenOCD, serial ports, toolchain, lab.conf, arguments).
--uart-standin     stand in for the boot stage that sets the UARTs up (the runtime's console driver
                   assumes it exists, nothing provides it in boot mode 0): clock and release MMUART0..4
                   and program divisor D (22 gives 115200 at the ~40 MHz APB clock of an unconfigured
                   MSS, measured). Off by default: an image or a bootloader that sets the UARTs up itself
                   must not be run on top of this.

The trap recorder (trap.S) lives at 0x08100000, above any image here, and logs the first trap.
Segments load with 64-bit stores in whole 64-byte lines: LIM is ECC memory, uninitialised at
power-up, and fetching a line that was only partly written faults (mcause 1).

The RISC-V compiler is the version pinned in tools/toolchain.env.
"""
import argparse
import os
import re
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lab  # noqa: E402
from ocd import OCD, Serial  # noqa: E402

SYSREG = 0x20002000
UARTS = (0x20000000, 0x20100000, 0x20102000, 0x20104000, 0x20106000)
REC = 0x08101000


def parse_elf(img: bytes):
    """Entry point and the loadable segments (physical address, data) of a 64-bit little-endian ELF."""
    if img[:4] != b"\x7fELF" or img[4] != 2 or img[5] != 1:
        raise SystemExit("run_image: not a 64-bit little-endian ELF file")
    entry, phoff = struct.unpack_from("<QQ", img, 0x18)[0], struct.unpack_from("<Q", img, 0x20)[0]
    phentsize, phnum = struct.unpack_from("<HH", img, 0x36)
    segs = []
    for i in range(phnum):
        ptype, _, off, _, paddr, filesz, _, _ = struct.unpack_from("<IIQQQQQQ", img, phoff + i * phentsize)
        if ptype == 1 and filesz:
            segs.append((paddr, img[off:off + filesz]))
    if not segs:
        raise SystemExit("run_image: the ELF file has no loadable segment")
    return entry, segs


def line_runs(segs):
    """Merge segments into runs of whole 64-byte lines, zero-filled, so no cache line is half-written."""
    mem = {}
    for paddr, data in segs:
        for k, byte in enumerate(data):
            mem[paddr + k] = byte
    lines = sorted({addr // 64 for addr in mem})
    runs = []
    for ln in lines:
        if runs and runs[-1][1] == ln:
            runs[-1][1] = ln + 1
        else:
            runs.append([ln, ln + 1])
    return [(lo * 64, bytes(mem.get(lo * 64 + k, 0) for k in range((hi - lo) * 64))) for lo, hi in runs]


def build_trap_recorder(tc, tmp):
    """Assemble trap.S for 0x08100000; returns the raw binary."""
    elf = os.path.join(tmp, "trap.elf")
    subprocess.run([str(tc / "riscv64-elf-gcc"), "-march=rv64imac_zicsr", "-mabi=lp64", "-nostdlib", "-Wl,-e,_trap",
                    "-Wl,-Ttext=0x08100000", "-o", elf, os.path.join(HERE, "trap.S")], check=True)
    subprocess.run([str(tc / "riscv64-elf-objcopy"), "-O", "binary", elf, os.path.join(tmp, "trap.bin")], check=True)
    with open(os.path.join(tmp, "trap.bin"), "rb") as f:
        return f.read()


def check_expect(regex, data, port):
    """(matched, description) of REGEX against the text the ports printed."""
    texts = {i: d.decode("latin1").replace("\r", "") for i, d in data.items() if port is None or i == port}
    for i, text in texts.items():
        if regex.search(text):
            return True, f"matched /{regex.pattern}/ on MMUART{i}"
    if not any(texts.values()):
        return False, f"NOT matched /{regex.pattern}/: no serial output on {'MMUART%d' % port if port is not None else 'any port'}"
    return False, f"NOT matched /{regex.pattern}/ in the serial output"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("elf")
    ap.add_argument("hart", type=int)
    ap.add_argument("--secs", type=float, default=4)
    ap.add_argument("--expect", metavar="REGEX")
    ap.add_argument("--expect-port", type=int, metavar="N")
    ap.add_argument("--uart-standin", action="store_true")
    ap.add_argument("--div", type=int, default=22)
    ap.add_argument("--lab", metavar="FILE")
    a = ap.parse_args(argv)
    if a.hart not in range(5):
        raise SystemExit(f"run_image: invalid hart {a.hart} (0 = E51, 1-4 = U54)")
    regex = None
    if a.expect is not None:
        try:
            regex = re.compile(a.expect)
        except re.error as e:
            raise SystemExit(f"run_image: invalid --expect regular expression: {e}")

    lab_conf = lab.load(a.lab)
    tc = lab.toolchain_bin()
    try:
        with open(a.elf, "rb") as f:
            entry, segs = parse_elf(f.read())
    except OSError as e:
        raise SystemExit(f"run_image: cannot read {a.elf}: {e}")

    tmp = tempfile.mkdtemp()
    trap_bin = build_trap_recorder(tc, tmp)

    def load(o, name, addr, data):
        path = os.path.join(tmp, name)
        with open(path, "wb") as f:
            f.write(data)
        o.cmd(f"load_image {path} 0x{addr:x} bin")
        print(f"loaded {len(data):#x} bytes at {addr:#x}")

    o = OCD(int(lab_conf["OCD_PORT"]), lab_conf["OCD_HOST"])
    s = Serial.from_lab(lab_conf)
    o.hart(a.hart)
    o.cmd("halt")
    if a.uart_standin:
        o.wr32(SYSREG + 0x84, o.rd32(SYSREG + 0x84) | (0x1F << 5))
        o.wr32(SYSREG + 0x88, o.rd32(SYSREG + 0x88) & ~(0x1F << 5))
        for b in UARTS:
            o.cmd("mww 0x%x 0x83; mww 0x%x %d; mww 0x%x 0; mww 0x%x 3; mww 0x%x 7" % (b + 0xC, b, a.div, b + 4, b + 0xC, b + 8))
    for i in range(8):
        o.cmd(f"mwd 0x{REC + 8 * i:x} 0")
    load(o, "trap.bin", 0x08100000, trap_bin)
    for n, (paddr, data) in enumerate(line_runs(segs)):
        load(o, f"seg{n}.bin", paddr, data)
    o.cmd("reg mcause 0; reg mepc 0; reg mtval 0; reg mtvec 0x08100000")
    o.cmd(f"reg pc 0x{entry:x}")
    print(f"hart {a.hart}: entry {entry:#x}, running {a.secs}s")
    s.pump(0.2)
    o.cmd("resume")
    s.pump(a.secs)
    o.cmd("halt")
    pc, mcause, mepc, mtval = (o.reg(r) for r in ("pc", "mcause", "mepc", "mtval"))
    rec = [o.rd64(REC + 8 * i) for i in range(4)]
    print(f"after: pc={pc:#x} mcause={mcause:#x} mepc={mepc:#x} mtval={mtval:#x}")
    print("first trap:", "none" if rec[0] == 0 else f"mcause={rec[1]:#x} mepc={rec[2]:#x} mtval={rec[3]:#x}")
    for i in sorted(s.data):
        if s.data[i]:
            print(f"MMUART{i}: {s.data[i]!r}")
    if not any(s.data.values()):
        print("no serial output on any port")
    s.close()
    if regex is None:
        return 0
    ok, text = check_expect(regex, s.data, a.expect_port)
    print(f"expect: {text}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(lab.run(main))
