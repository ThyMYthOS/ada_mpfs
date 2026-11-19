# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @verifies HW-002
"""hw/mss_init.py: the sequences built from the MSS Configurator XML of the board.

    mss_init_test.py [MERGED_SVD]

With the XML of the Icicle Kit engineering sample (config/boards/icicle_es) the sequences are exactly those that
hw/mss_init.py wrote with its literals before it read the XML: PINNED below is that sequence, kept as a list so that
the old behaviour stays pinned. The XML of the 2024.2 design (config/boards/icicle) differs in IOMUX0 and IOMUX4
only. Every write of a value of the XML names its register. The executor: writes, read-modify-writes, polls, the
silicon variant and the delays. MERGED_SVD defaults to build/svd/PolarfireSoC.svd, made current first (tools/svd.py
ensure). Prints "ok:" or "FAIL:" per case; exits non-zero if one failed.
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path[:0] = [str(ROOT / "hw"), str(ROOT / "tests" / "host" / "gen_ada"), str(ROOT / "config" / "gen"),
                str(ROOT / "tools")]

import mss_init as m
from gen_ada import svdread
from harness import case, finish, raises

SVD = Path(sys.argv[1]) if len(sys.argv) > 1 else svdread.ensure(ROOT)
BOARDS = ROOT / "config" / "boards"
ES = m.load(BOARDS / "icicle_es" / "ICICLE_MSS_mss_cfg.xml", SVD)
NEW = m.load(BOARDS / "icicle" / "ICICLE_MSS_mss_cfg.xml", SVD)

# The steps of mss_init.full() as hw/mss_init.py had them with the literal values of the Icicle design, before the
# values came from the XML: W address value, M address set clear, P address mask want timeout, D seconds,
# I address mask [steps].
PINNED_FULL = """
W 0x2000200c 0x0000007d
W 0x2000200c 0x0001007d
W 0x37080008 0x0008a080
W 0x20002098 0x00000001
W 0x20007008 0x003f1f00
W 0x20007c1c 0x0000047f
W 0x20002200 0x00000fdd
W 0x20002204 0x00000000
W 0x20002208 0x00000000
W 0x2000220c 0x44444444
W 0x20002210 0x88cc4444
W 0x20002214 0xf7773333
W 0x20002218 0x0000001d
W 0x20002234 0x09300930
W 0x20002238 0x09300930
W 0x2000223c 0x09300930
W 0x20002240 0x09280928
W 0x20002244 0x09300930
W 0x20002248 0x09300930
W 0x2000224c 0x09300930
W 0x20002254 0x08290829
W 0x20002258 0x08290829
W 0x2000225c 0x08290829
W 0x20002260 0x08290829
W 0x20002264 0x08290829
W 0x20002268 0x08290829
W 0x2000226c 0x08290829
W 0x20002270 0x08290829
W 0x20002274 0x08290829
W 0x20002278 0x08290829
W 0x2000227c 0x08290829
W 0x20002280 0x08290829
W 0x200031c4 0x00080907
W 0x200031c8 0x00040a0d
W 0x200031bc 0x00000f00
D 0.001
W 0x200031bc 0x00000800
D 0.001
W 0x200031bc 0x00001800
D 0.001
W 0x200031bc 0x00003800
W 0x20007c00 0x00000101
W 0x20007c00 0x00000001
W 0x20007c04 0x0880f2ff
W 0x20007c0c 0x37f07770
W 0x20007c10 0x37f07770
W 0x20007c14 0x000020c8
W 0x20007c18 0xf00050cc
W 0x20007c24 0xff000000
W 0x20007c08 0x80140101
W 0x3e400000 0x00000001
P 0x20007c20 0x00000040 0x00000040 2
D 0.001
W 0x20003100 0x00000000
W 0x3e100000 0x00000001
W 0x36500000 0x00000001
W 0x36510000 0x00000001
W 0x20007c1c 0x0000047f
W 0x20007c1c 0x0000007f
W 0x3e800000 0x00000001
W 0x3e800000 0x00000000
P 0x20007c20 0x00004000 0x00004000 2
M 0x20007c20 0x40000000 0x00000000
M 0x3e800004 0x00004000 0x00000000
W 0x3e200000 0x00000001
W 0x3e080000 0x00000001
P 0x20007c08 0x00000080 0x00000080 2
P 0x20007c14 0x00800000 0x00800000 2
M 0x20002084 0x00000006 0x00000000
M 0x20002088 0x00000000 0x00000006
W 0x20007c1c 0x0000607f
W 0x20007c1c 0x0000007f
I 0x20007c28 0x80000000 [D 0.01; W 0x20007c1c 0x0000607f; W 0x20007c1c 0x0000007f]
W 0x3e010000 0x00000003
W 0x3e001000 0x00000003
W 0x3e001004 0x01000036
W 0x3e001008 0x00000500
W 0x3e001010 0x01000100
W 0x3e001014 0x4b000300
W 0x3e001018 0x00001020
W 0x3e00100c 0x00000000
W 0x3e001024 0x00000000
W 0x3e001028 0x00000000
W 0x3e00102c 0x00000060
W 0x3e001030 0x00000001
W 0x3e001020 0x00004003
W 0x3e002008 0x00000155
W 0x3e200010 0x00002c30
W 0x3e002004 0x00000208
W 0x3e002014 0x00000000
W 0x3e002018 0x00000000
W 0x3e001004 0x01000037
P 0x3e001004 0x02000000 0x02000000 5
""".strip().splitlines()
# The steps of the reference clock (REFCLK, what CLINT.MTIME needs) as they were.
PINNED_REFCLK = PINNED_FULL[:4] + ["W 0x200031bc 0x00003800", "W 0x20007c18 0xf00050cc"]
# --skip-io left out the 28 writes of the IO set-up, the steps 7 to 34.
IO_SETUP = slice(6, 34)


def flat(steps):
    """The steps in the form of the pinned lists."""
    out = []
    for s in steps:
        if isinstance(s, m.Write):
            out.append(f"W {s.address:#010x} {s.value:#010x}")
        elif isinstance(s, m.Modify):
            out.append(f"M {s.address:#010x} {s.set:#010x} {s.clear:#010x}")
        elif isinstance(s, m.Poll):
            out.append(f"P {s.address:#010x} {s.mask:#010x} {s.want:#010x} {s.timeout:g}")
        elif isinstance(s, m.Delay):
            out.append(f"D {s.seconds:g}")
        else:
            out.append(f"I {s.address:#010x} {s.mask:#010x} [" + "; ".join(flat(s.then)) + "]")
    return out


@case("the pinned sequence has the counts of the old one: 93 steps, 6 for the reference clock, 65 without the IO")
def _():
    assert len(PINNED_FULL) == 93
    assert all(line.startswith("W 0x2000") for line in PINNED_FULL[IO_SETUP])
    assert len(PINNED_FULL) - len(PINNED_FULL[IO_SETUP]) == 65


@case("with the XML of the Icicle Kit engineering sample the sequences are exactly the old ones")
def _():
    assert flat(m.full(ES)) == PINNED_FULL, "\n".join(flat(m.full(ES)))
    assert flat(m.refclk(ES)) == PINNED_REFCLK, flat(m.refclk(ES))
    without_io = PINNED_FULL[:IO_SETUP.start] + PINNED_FULL[IO_SETUP.stop:]
    assert flat(m.full(ES, io=False)) == without_io


@case("with the XML of the 2024.2 design only IOMUX0 and IOMUX4 differ: 0xFD5 and 0x88664444")
def _():
    new, old = flat(m.full(NEW)), PINNED_FULL
    differ = [(o, n) for o, n in zip(old, new, strict=True) if o != n]
    assert differ == [("W 0x20002200 0x00000fdd", "W 0x20002200 0x00000fd5"),
                      ("W 0x20002210 0x88cc4444", "W 0x20002210 0x88664444")], differ
    assert flat(m.refclk(NEW)) == PINNED_REFCLK


@case("every value of the XML names its register; the three derived ones follow their rule")
def _():
    writes = [s for s in m.full(ES) if isinstance(s, m.Write)]
    named = {s.xml for s in writes if s.xml}
    assert named == set(m.XML_REGISTERS), sorted(set(m.XML_REGISTERS) ^ named)
    derived = {m.XML_RTC, f"{m.XML_TIP}/SGMII_MODE", f"{m.XML_PLL}/PLL_CTRL"}
    for s in writes:
        if s.xml and s.xml not in derived:
            assert s.value == ES[s.xml], s
    rtc = [s.value for s in writes if s.xml == m.XML_RTC]
    assert rtc == [ES[m.XML_RTC], ES[m.XML_RTC] | 1 << 16], rtc
    mode = next(s.value for s in writes if s.xml == f"{m.XML_TIP}/SGMII_MODE")
    assert ES[f"{m.XML_TIP}/SGMII_MODE"] & 1 << 22 and mode == ES[f"{m.XML_TIP}/SGMII_MODE"] & ~(1 << 22)
    ctrl = [s.value for s in writes if s.xml == f"{m.XML_PLL}/PLL_CTRL"]
    assert ctrl == [ES[f"{m.XML_PLL}/PLL_CTRL"] & ~1, ES[f"{m.XML_PLL}/PLL_CTRL"] | 1], ctrl
    unnamed = {s.address for s in writes if not s.xml}
    assert m.IOSCBCFG_TIMER in unnamed and m.DFIAPB_CR in unnamed and m.MSSIO_CONTROL_CR in unnamed


@case("the header names the XML and its SHA-256, and the known defect of PLL_PHADJ where it is written")
def _():
    lines = m.header(ES, m.full(ES))
    assert lines[0] == f"# MSS Configurator XML config/boards/icicle_es/ICICLE_MSS_mss_cfg.xml sha256 {ES.sha256}", lines
    assert len(ES.sha256) == 64
    assert any(line.startswith("# note: mss_clocks/mss_pll/PLL_PHADJ: known defect") and "0x4003" in line
               for line in lines), lines
    assert not any("note" in line for line in m.header(ES, m.refclk(ES)))
    assert "[xml mss_io/io_mux/IOMUX0_CR]" in m.describe(m.full(ES)[6])


@case("a design without an SGMII channel takes the off mode of mss_sgmii.c: no wait for the SGMII PLL")
def _():
    mode = f"{m.XML_TIP}/SGMII_MODE"
    assert m.sgmii_channels(ES) and ES[mode] & m.TX_RX_CH_EN == m.TX_RX_CH_EN
    off = m.Values(ES.source, ES.sha256, ES.design, {**ES.registers, mode: 0x07C0F20C}, ES.defects)
    assert not m.sgmii_channels(off)
    steps = flat(m.full(off))
    start = PINNED_FULL.index("W 0x20007c00 0x00000101")   # SOFT_RESET_SGMII: the start of the SGMII block
    rpc = PINNED_FULL[start:start + 9]
    rpc[2] = "W 0x20007c04 0x0780f20c"                     # the design's SGMII_MODE, bit 22 cleared
    after = PINNED_FULL.index("W 0x3e010000 0x00000003")   # IOSCB_PLL_DDR.SOFT_RESET: the start of the MSS PLL
    expected = PINNED_FULL[:start] + rpc + ["W 0x3e100000 0x00000001", "W 0x3e200000 0x00000001"] + PINNED_FULL[after:]
    assert steps == expected, "\n".join(steps)
    assert "P 0x20007c08 0x00000080 0x00000080 2" not in steps   # PLL_CNTL: SGMII PLL locked
    assert not any(line.startswith("P 0x20007c14") for line in steps)   # RECAL_CNTL: DLL locked


@case("every reference XML gives a full sequence")
def _():
    for xml in sorted(BOARDS.glob("*/*.xml")):
        assert len(m.full(m.load(xml, SVD))) == 93, xml


@case("an XML that the reader rejects, or a missing one, is XmlError with the reader's message")
def _():
    raises(m.XmlError, lambda: m.load(ROOT / "tests" / "host" / "xml_reader" / "fixtures" / "broken" / "e041_doctype.xml",
                                      SVD), "GEN-E041")
    raises(m.XmlError, lambda: m.load(BOARDS / "none.xml", SVD), "GEN-E040")
    raises(m.XmlError, lambda: m.load(BOARDS / "icicle_es" / "ICICLE_MSS_mss_cfg.xml", BOARDS / "none.svd"),
           "the merged SVD does not exist")


@case("run: writes, read-modify-writes, polls, the silicon variant and the delays")
def _():
    mem = {m.PVT_STAT: (1 << 6) | (1 << 14), m.PLL_CNTL: 1 << 7, m.RECAL_CNTL: 1 << 23, m.PLL_MSS + 4: 1 << 25,
           m.SUBBLK_CLOCK_CR: 1, m.SOFT_RESET_CR: 0x3FFFFFFE, m.SPARE_STAT: 1 << 31, m.IO_CALIB_SGMII + 4: 0xE000}
    writes, slept = [], []
    status = {m.PVT_STAT, m.PLL_CNTL, m.RECAL_CNTL, m.PLL_MSS + 4, m.SPARE_STAT}  # read-only: a write does not change it

    def write(a, v, what):
        writes.append((a, v))
        if a not in status:
            mem[a] = v
    m.run(m.full(ES), write, lambda a: mem.get(a, 0), sleep=slept.append)
    assert (m.SUBBLK_CLOCK_CR, 7) in writes and (m.SOFT_RESET_CR, 0x3FFFFFF8) in writes, writes
    assert (m.PVT_STAT, (1 << 6) | (1 << 14) | 0x40000000) in writes
    assert (m.IO_CALIB_SGMII + 4, 0xE000 | (1 << 14)) in writes
    assert writes.count((m.DYN_CNTL, 0x607F)) == 2, "rev C: the lanes are reset twice"
    assert 0.01 in slept, slept
    n_revc = len(writes)
    mem[m.SPARE_STAT] = 0
    writes.clear()
    m.run(m.full(ES), write, lambda a: mem.get(a, 0), sleep=slept.append)
    assert writes.count((m.DYN_CNTL, 0x607F)) == 1 and len(writes) == n_revc - 2, "rev B: the lanes are reset once"
    assert not any(a in (m.SYSREG + 0xB8, m.SYSREG + 0x008, m.MUX_MSS + 0x0C) for a, _ in writes), "no clock switch"
    t = iter(range(100))
    raises(m.MssInitError, lambda: m.run([m.Poll(0x10, 1, 1, "never", 1.0)], write, lambda a: 0,
                                         sleep=lambda s: None, monotonic=lambda: next(t) * 0.5), "never")


finish()
