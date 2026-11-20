# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @verifies GEN-006, GEN-007, GEN-008, GEN-009
"""config/gen/mpfs_gen/derive: the derived systems of the four reference systems with the reference XMLs, the
clocks recomputed from the MSS PLL, the L2, the placement, CPU_To_Hart, the PLIC, the peripheral bits, and a
negative case for every code of the derivations. Needs the merged SVD (tools/svd.py ensure).

A negative case changes the XML in the model (fields of registers, the value of the register recomputed as
the reader does) or the description, and expects exactly the codes it names. The reference systems are taken
with security_profile dev, so that the checks of the PMP and the contexts, which the reference XMLs fail
(the open, locked entry 0 of the U54 harts), are notes; test_protection.py has them, amp_c (prod) included."""
import dataclasses
import subprocess
import sys
from itertools import pairwise
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path[:0] = [str(HERE.parent / "gen_ada"), str(ROOT / "config" / "gen"), str(ROOT / "tools")]

from gen_ada import svdread
from harness import case, finish, raises
from mpfs_gen import checks, derive, target, xml_reader, yaml_reader
from mpfs_gen.checks import DerivationError
from mpfs_gen.derive import clocks, placement, plic
from mpfs_gen.model import Xml

SVD = svdread.ensure(ROOT)
BOARDS = ROOT / "config" / "boards"
SYSTEMS = ROOT / "systems"
XMLS = {p.parent.name: p for p in sorted(BOARDS.glob("*/*.xml"))}
CONFIGS = {board: xml_reader.read(path, SVD) for board, path in XMLS.items()}
ICICLE = CONFIGS["icicle"]
REFERENCE = ("amp_a", "amp_b", "amp_c", "amp_d")
CLOCKS = "mss_clocks/clocks"
PLL = "mss_clocks/mss_pll"
SYS = "mss_clocks/mss_sys"
CACHE = "mss_memory_map/cache"
MHZ = 1_000_000
covered: set[str] = set()

ONE = """schema: 1
board: icicle
partitions:
  - name: a
    harts: [1]
    profile: light
    memory:
      code: { region: lim, size: 64K }
      data: { region: lim, size: 64K }
    peripherals: [mmuart1]
"""
TWO = ONE + """  - name: b
    harts: [2]
    profile: light
    memory:
      code: { region: lim, size: 64K }
      data: { region: lim, size: 64K }
    peripherals: [mmuart2]
"""


def system(name):
    """The reference system <name> with security_profile dev (amp_c is prod)."""
    return dataclasses.replace(yaml_reader.read(SYSTEMS / name / "system.yaml"), security_profile="dev")


def text(description):
    return yaml_reader.read_text(description, "test.yaml")


def edited(config, changes):
    """<config> with the fields of {(section, register, field): value} changed and the values of their registers
    recomputed (the RW fields at their offsets); a register of mss_clocks/clocks has one field of its name."""
    registers = []
    for reg in config.registers:
        fields = tuple(dataclasses.replace(f, value=changes[(reg.section, reg.name, f.name)])
                       if (reg.section, reg.name, f.name) in changes else f for f in reg.fields)
        value = sum(f.value << f.bits.offset for f in fields if f.access == "RW" and f.value is not None)
        registers.append(dataclasses.replace(reg, fields=fields, value=value))
    assert all(any((r.section, r.name, f.name) == key for r in registers for f in r.fields) for key in changes), changes
    return dataclasses.replace(config, registers=tuple(registers))


def clock_tree(intin, cpu, axi, ahb, rates):
    """The changes for a clock tree: INTIN of the MSS PLL, the three dividers and the rates of mss_clocks/clocks
    (MSS_SYSTEM_CLK, MSS_COREPLEX_CPU_CLK, MSS_AXI_CLK, MSS_APB_AHB_CLK)."""
    names = ("MSS_SYSTEM_CLK", "MSS_COREPLEX_CPU_CLK", "MSS_AXI_CLK", "MSS_APB_AHB_CLK")
    changes = {(PLL, "SSCG_REG_2", "INTIN"): intin, (SYS, "CLOCK_CONFIG_CR", "DIVIDER_CPU"): cpu,
               (SYS, "CLOCK_CONFIG_CR", "DIVIDER_AXI"): axi, (SYS, "CLOCK_CONFIG_CR", "DIVIDER_APB_AHB"): ahb}
    changes.update({(CLOCKS, n, n): int(r) for n, r in zip(names, rates)})
    return changes


def codes_of(sys_, config=ICICLE):
    try:
        derive.derive(sys_, config, SVD)
    except DerivationError as err:
        return err.codes, str(err)
    return [], ""


def rejected(expected, sys_, config=ICICLE, *words):
    """The derivation of <sys_> with <config> fails with exactly the codes <expected>; the message has <words>."""
    got, message = codes_of(sys_, config)
    assert got == expected, (got, message)
    for word in words:
        assert word in message, (word, message)
    covered.update(expected)
    return message


def cli(*args):
    return subprocess.run([sys.executable, "-I", str(ROOT / "config" / "gen" / "mpfs_gen"), *args],
                          capture_output=True, text=True, check=False)


# --- positive cases -------------------------------------------------------------------------------------------

@case("the clocks of every reference XML recomputed from the MSS PLL equal those of the XML (at most 1 ppm); the "
      "PMP demo and amp_c have their VCO at 4800 MHz")
def _():
    assert sorted(CONFIGS) == ["icicle", "icicle_amp_c", "icicle_es", "icicle_es_pmp_demo", "video_kit"]
    for board, config in CONFIGS.items():
        c, found = clocks.derive(config)
        assert found == [], (board, found)
        vco = 4800 if board in ("icicle_es_pmp_demo", "icicle_amp_c") else 2400
        assert (c.reference, c.vco, c.system, c.cpu, c.axi, c.ahb) == (
            125 * MHZ, vco * MHZ, 600 * MHZ, 600 * MHZ, 300 * MHZ, 150 * MHZ), board
        assert (c.rtc_toggle, c.rtc_period) == (1 * MHZ, 125), board
        for name in clocks.COMPARED:
            assert c.deviation_ppm(name) == 0, (board, name)
        print(f"      {board}: " + ", ".join(f"{n} XML {dict(c.stated)[n]} recomputed {getattr(c, a)}"
                                         for n, a in clocks.COMPARED.items()))


@case("the fractional mode: INTIN 96 and FRACIN 2**23 give 603.125 MHz")
def _():
    config = edited(ICICLE, {(PLL, "PLL_FRACN", "FRACN_EN"): 1, (PLL, "SSCG_REG_0", "FRACIN"): 1 << 23,
                             **clock_tree(96, 0, 1, 2, (603_125_000, 603_125_000, 301_562_500, 150_781_250))})
    c, found = clocks.derive(config)
    assert found == [] and c.system == 603_125_000, (found, c.system)


@case("1 ppm is allowed, more is not")
def _():
    one = edited(ICICLE, {(CLOCKS, "MSS_COREPLEX_CPU_CLK", "MSS_COREPLEX_CPU_CLK"): 600_000_600})
    assert clocks.derive(one)[1] == []
    rejected(["GEN-E061"], system("amp_a"),
             edited(ICICLE, {(CLOCKS, "MSS_COREPLEX_CPU_CLK", "MSS_COREPLEX_CPU_CLK"): 600_000_601}),
             "MSS_COREPLEX_CPU_CLK", "1.002 ppm")


@case("the four reference systems derive with the XMLs of the Icicle Kit and of the PMP demo; the video kit "
      "configures too few MMUARTs")
def _():
    for name in REFERENCE:
        for board in ("icicle", "icicle_es", "icicle_es_pmp_demo"):
            d = derive.derive(system(name), CONFIGS[board], SVD)
            assert d.xml_sha256 == CONFIGS[board].sha256
            assert placement.check(d.windows, d.memories, {p.name: p.harts for p in d.partitions}) == []
        got, _ = codes_of(system(name), CONFIGS["video_kit"])
        assert set(got) == {"GEN-E084"}, (name, got)


@case("the derivation is deterministic")
def _():
    for name in REFERENCE:
        assert derive.derive(system(name), ICICLE, SVD) == derive.derive(system(name), ICICLE, SVD)


@case("the L2 of the reference XMLs: 8 cache, 4 scratchpad (the upper enabled ways 8 to 11), 4 LIM ways; the XML "
      "of amp_c: 1 cache way, 15 LIM ways")
def _():
    l2 = derive.derive(text(ONE), CONFIGS["icicle_amp_c"], SVD).l2
    assert (l2.ways.cache, l2.ways.lim, l2.ways.scratchpad) == (1, 15, 0) and not l2.override, l2
    assert l2.way_enable == 0 and l2.lim_length == 1920 * 1024, l2
    for board, config in CONFIGS.items():
        if board == "icicle_amp_c":
            continue
        l2 = derive.derive(text(ONE), config if board != "video_kit" else ICICLE, SVD).l2
        assert (l2.ways.cache, l2.ways.lim, l2.ways.scratchpad) == (8, 4, 4) and not l2.override, board
        assert l2.way_enable == 11 and l2.cache_ways == tuple(range(8)), board
        assert l2.scratchpad_ways == (8, 9, 10, 11) and l2.lim_ways == (12, 13, 14, 15), board
        assert (l2.lim_length, l2.scratchpad_length) == (512 * 1024, 512 * 1024), board
    d = derive.derive(system("amp_d"), ICICLE, SVD)
    assert d.l2.override and (d.l2.ways.cache, d.l2.ways.lim) == (4, 12) and d.l2.reason
    assert d.l2.partitioning == (("u54_1", (0, 1)), ("u54_2", (0, 1)), ("u54_3", (2, 3)), ("u54_4", (2, 3)))
    for name in ("amp_a", "amp_b", "amp_c"):
        l2 = derive.derive(system(name), ICICLE, SVD).l2
        assert l2.override and (l2.ways.cache, l2.ways.lim, l2.ways.scratchpad) == (1, 15, 0), name


@case("amp_a: the channels form a chain rt | monitor_rt | monitor | monitor_app | app, rt NAPOT at the LIM origin")
def _():
    d = derive.derive(system("amp_a"), ICICLE, SVD)
    lim = [(w.channel or w.owners[0], w.origin, w.length, w.mode) for w in d.windows if w.memory == "lim"]
    assert lim == [("rt", 0x0800_0000, 0x40000, "NAPOT"), ("monitor_rt", 0x0804_0000, 0x4000, "NAPOT"),
                   ("monitor", 0x0804_4000, 0x20000, "TOR"), ("monitor_app", 0x0806_4000, 0x4000, "NAPOT"),
                   ("app", 0x0806_8000, 0x100000, "TOR")], lim
    itim = [(w.memory, w.origin, w.length) for w in d.partition("rt").windows if w.kind == "fast_text"]
    assert itim == [("u54_1_itim", 0x0180_8000, 0x4000)]


@case("amp_b and amp_c: a graph that is not a chain gets one shared block of channels")
def _():
    for name, channels in (("amp_b", 3), ("amp_c", 5)):
        d = derive.derive(system(name), ICICLE, SVD)
        ipc = sorted((w.origin, w.end) for w in d.windows if w.kind == "ipc")
        assert len(ipc) == channels and all(a[1] == b[0] for a, b in pairwise(ipc)), (name, ipc)


@case("CPU_To_Hart is the k-th set bit of the mask")
def _():
    assert derive.cpu_to_hart(0x1) == (0,) and derive.cpu_to_hart(0x1C) == (2, 3, 4)
    assert derive.cpu_to_hart(0x6) == (1, 2) and derive.cpu_to_hart(0x12) == (1, 4)
    d = derive.derive(system("amp_d"), ICICLE, SVD)
    assert [p.cpu_to_hart for p in d.partitions] == [(1, 2), (3, 4)]


@case("the PLIC: sources by number from the SVD, M contexts of the own harts, local interrupts; the level mapping")
def _():
    d = derive.derive(system("amp_a"), ICICLE, SVD)
    monitor, rt, app = d.partitions
    assert [(s.name, s.number, s.level) for s in monitor.interrupts.sources] == [("MMUART0", 90, None),
                                                                                  ("WDOG0_MVRP", 100, None)]
    assert monitor.interrupts.contexts == (0,) and app.interrupts.contexts == (3, 5, 7)
    assert app.interrupts.enables == ((3, 92), (3, 93), (5, 92), (5, 93), (7, 92), (7, 93))
    assert rt.interrupts.sources == () and rt.interrupts.local == (("WDOG_TOUT", 9), ("MMUART", 11))
    assert [plic.level(p) for p in (0, 248, 249, 252, 255)] == [0, 0, 1, 4, 7]


@case("the peripheral bits come from the SVD: MMUART 5 to 9, SPI 10 and 11, I2C 12 and 13, CAN 14 and 15, USB 16, "
      "RTC 18, QSPI 19, GPIO 20 to 22, ATHENA 28, CFM 29; watchdogs have none")
def _():
    from mpfs_gen.derive import periph
    known = periph.catalogue(xml_reader.svd_layout(SVD))
    bits = {name: xml_reader.svd_layout(SVD)[periph.SUBBLK].fields[f].offset for name, f in known.items() if f}
    expected = {"mmuart0": 5, "mmuart1": 6, "mmuart2": 7, "mmuart3": 8, "mmuart4": 9, "spi0": 10, "spi1": 11,
                "i2c0": 12, "i2c1": 13, "can0": 14, "can1": 15, "usb": 16, "rtc": 18, "qspi": 19, "gpio0": 20,
                "gpio1": 21, "gpio2": 22, "athena": 28, "cfm": 29}
    assert {n: bits[n] for n in expected} == expected
    assert {n for n, f in known.items() if f is None} == {f"wdog{i}" for i in range(5)}
    d = derive.derive(system("amp_a"), ICICLE, SVD)
    app = d.partition("app").peripherals
    assert app.names == ("mmuart2", "mmuart3", "wdog2") and app.clock_mask == app.reset_mask == 0x180
    assert d.ram_shutdown == 0 and d.ram_shutdown_blocks == ()


@case("RAM_SHUTDOWN_CR after CONFIGURED_PERIPHERALS: the video kit leaves out CAN0 and CAN1")
def _():
    d = derive.derive(text(ONE), CONFIGS["video_kit"], SVD)
    assert d.ram_shutdown_blocks == ("CAN0", "CAN1") and d.ram_shutdown == 0x3
    off = edited(ICICLE, {("mss_ddr/mode", "DDRPHY_MODE", "DDRMODE"): 0x7})
    d = derive.derive(text(ONE), off, SVD)
    assert d.ram_shutdown_blocks == ("DDRC",) and d.ram_shutdown == 1 << 7


@case("the direct GPIO lines: GPIO0/GPIO1 or, with the bit of GPIO_INTERRUPT_FAB_CR, GPIO2")
def _():
    d = derive.derive(text(ONE), ICICLE, SVD)
    aliases = dict(d.gpio_aliases)
    assert len(aliases) == 38 and aliases["GPIO_DIRECT_0"] == "GPIO0_BIT0" and aliases["GPIO_DIRECT_14"] == "GPIO1_BIT0"
    assert aliases["GPIO_DIRECT_37"] == "GPIO1_BIT23"
    fab = edited(ICICLE, {("mss_io/io_mux", "GPIO_INTERRUPT_FAB_CR", "GPIO0_3_OR_GPIO2_3"): 1,
                          ("mss_io/io_mux", "GPIO_INTERRUPT_FAB_CR", "GPIO1_17_OR_GPIO2_31"): 1})
    aliases = dict(derive.derive(text(ONE), fab, SVD).gpio_aliases)
    assert (aliases["GPIO_DIRECT_3"], aliases["GPIO_DIRECT_31"], aliases["GPIO_DIRECT_30"]) == (
        "GPIO2_BIT3", "GPIO2_BIT31", "GPIO1_BIT16")


@case("a system of one partition whose windows have no size takes the whole LIM")
def _():
    d = derive.derive(text(ONE.replace("size: 64K ", "").replace(", size: 64K", "")), ICICLE, SVD)
    assert [(w.origin, w.length, w.mode) for w in d.windows] == [(target.LIM_ORIGIN, 512 * 1024, "NAPOT")]


@case("the command line: derive --check of the reference systems (amp_c, prod, refused by the PMP of the XML), derive "
      "prints the system, a broken one is status 2")
def _():
    files = [str(SYSTEMS / n / "system.yaml") for n in REFERENCE]
    done = cli("derive", "--check", "--svd", str(SVD), *files)
    assert done.returncode == 2 and done.stdout.count(": ok\n") == 3 and "amp_c/system.yaml: ok" not in done.stdout, \
        (done.stdout, done.stderr)
    assert "amp_c/system.yaml with config/boards/icicle/ICICLE_MSS_mss_cfg.xml: GEN-E105" in done.stderr, done.stderr
    assert "amp_a/system.yaml: " in done.stderr and "not enforced for security_profile dev" in done.stderr
    done = cli("derive", "--svd", str(SVD), files[0])
    assert done.returncode == 0, done.stderr
    lines = done.stdout.splitlines()
    assert ("clocks: reference 125 MHz, VCO 2400 MHz, system 600 MHz, CPU 600 MHz, AXI 300 MHz, AHB/APB 150 MHz, "
            "RTC toggle 1000000 Hz (period 125)") in lines, lines
    assert "window lim 0x0800_0000 length 0x0004_0000 NAPOT: rt code+data" in lines
    assert "partition app: harts [2, 3, 4], mask 0x1c, CPU_To_Hart [2, 3, 4]" in lines
    assert any(line.startswith("pmp: not applied (security_profile dev)") for line in lines), lines
    assert any(line.startswith("note: GEN-E105 mss_memory_map/pmp_h1/PMP0CFG") for line in lines), lines
    done = cli("derive", "--svd", str(SVD), "--xml", str(XMLS["video_kit"]), files[0])
    assert done.returncode == 2 and "GEN-E084" in done.stderr, done


# --- negative cases, one per code --------------------------------------------------------------------------

@case("GEN-E060: the XML has another SHA-256 than system.yaml names")
def _():
    rejected(["GEN-E060"], dataclasses.replace(text(ONE), xml=Xml("x.xml", "0" * 64)), ICICLE, "xml.sha256")


@case("GEN-E061 to GEN-E071: the clock rules, each alone where it can be")
def _():
    one = text(ONE)
    rejected(["GEN-E062"], one, edited(ICICLE, {(PLL, "PLL_REF_FB", "RFDIV"): 0}), "RFDIV")
    rejected(["GEN-E063"], one, edited(ICICLE, clock_tree(104, 0, 2, 3, (650e6, 650e6, 162.5e6, 81.25e6))),
             "650000000 Hz is above 625000000 Hz")
    rejected(["GEN-E064"], one, edited(ICICLE, clock_tree(100, 0, 0, 2, (625e6, 625e6, 625e6, 156.25e6))),
             "MSS_AXI_CLK")
    rejected(["GEN-E065"], one, edited(ICICLE, clock_tree(100, 0, 1, 1, (625e6, 625e6, 312.5e6, 312.5e6))),
             "MSS_APB_AHB_CLK")
    rejected(["GEN-E066"], one, edited(ICICLE, clock_tree(96, 2, 1, 2, (600e6, 150e6, 300e6, 150e6))),
             "below the AXI clock")
    rejected(["GEN-E067"], one, edited(ICICLE, clock_tree(48, 0, 1, 0, (300e6, 300e6, 150e6, 150e6))),
             "DIVIDER_APB_AHB")
    rejected(["GEN-E068"], one, edited(ICICLE, clock_tree(80, 0, 1, 3, (500e6, 500e6, 250e6, 62.5e6))),
             "USB")
    rate = (CLOCKS, "MSS_RTC_TOGGLE_CLK", "MSS_RTC_TOGGLE_CLK")
    rejected(["GEN-E069", "GEN-E071"], one, edited(ICICLE, {rate: 30_000}), "4095")
    rejected(["GEN-E070"], one, edited(ICICLE, {(SYS, "RTC_CLOCK_CR", "PERIOD"): 100}), "PERIOD")
    rejected(["GEN-E071"], one, edited(ICICLE, {rate: 1_250_000, (SYS, "RTC_CLOCK_CR", "PERIOD"): 100}),
             "1000000 Hz")


@case("GEN-E072 to GEN-E074: the L2 rules")
def _():
    one = text(ONE)
    rejected(["GEN-E072"], one, edited(ICICLE, {(CACHE, "WAY_ENABLE", "WAY_ENABLE"): 3}), "WAY_ENABLE 3")
    rejected(["GEN-E073"], one, edited(ICICLE, {(CACHE, "WAY_MASK_DMA", "WAY_MASK_8"): 1}), "WAY_MASK_DMA")
    amp_d = system("amp_d")
    wrong = dataclasses.replace(amp_d, l2=dataclasses.replace(amp_d.l2, cache_partitioning=(("u54_1", (3, 4)),)))
    rejected(["GEN-E074"], wrong, ICICLE, "[4]")


@case("GEN-E075 and GEN-E076: a window size that is no multiple of 4; windows that do not fit (both partitions named)")
def _():
    rejected(["GEN-E075"], text(TWO.replace("data: { region: lim, size: 64K }", "data: { region: lim, size: 65538 }", 1)),
             ICICLE, "65538")
    without = dataclasses.replace(system("amp_a"), l2=dataclasses.replace(system("amp_a").l2, ways=None, reason=None))
    rejected(["GEN-E076"], without, ICICLE, "monitor, rt, app", "524288")


@case("GEN-E077 to GEN-E079: the checks of the system map; an overlap names both partitions")
def _():
    d = derive.derive(system("amp_a"), ICICLE, SVD)
    harts = {p.name: p.harts for p in d.partitions}
    rt, monitor = (next(w for w in d.windows if w.owners == (n,) and w.memory == "lim") for n in ("rt", "monitor"))
    lim = next(m for m in d.memories if m.name == "lim")

    def codes(windows):
        found = placement.check(windows, d.memories, harts)
        covered.update(f.code for f in found)
        return [f.code for f in found], " ".join(str(f) for f in found)

    got, message = codes([rt, dataclasses.replace(monitor, origin=rt.origin + 0x1000)])
    assert got == ["GEN-E078"] and "partition 'rt'" in message and "partition 'monitor'" in message, message
    got, message = codes([dataclasses.replace(rt, origin=lim.end - 0x1000)])
    assert got == ["GEN-E077"] and "reaches outside lim" in message, message
    fast = next(w for w in d.windows if w.kind == "fast_text")
    foreign = next(m for m in d.memories if m.name == "u54_2_itim")
    got, message = codes([dataclasses.replace(fast, memory=foreign.name, origin=foreign.origin)])
    assert got == ["GEN-E079"] and "hart 2" in message and "'rt'" in message, message
    dtim = next(m for m in d.memories if m.name == "dtim")
    got, _ = codes([dataclasses.replace(fast, memory="dtim", origin=dtim.origin, length=0x1000)])
    assert got == ["GEN-E079"], got


@case("GEN-E080 to GEN-E082: the interrupt rules")
def _():
    rejected(["GEN-E080"], text(ONE + "    interrupts: [NOT_A_SOURCE]\n"), ICICLE, "NOT_A_SOURCE")
    rejected(["GEN-E081"], text(ONE.replace("harts: [1]", "harts: [0]").replace("mmuart1", "mmuart0")
                                + "    interrupts: [local:MMUART]\n"), ICICLE, "[0]")
    both = TWO.replace("peripherals: [mmuart1]", "peripherals: [mmuart1]\n    interrupts: [SPI0]") + \
        "    interrupts: [SPI0]\n"
    rejected(["GEN-E082"], text(both), ICICLE, "'a'", "'b'")


@case("GEN-E083 and GEN-E084: the peripheral rules")
def _():
    rejected(["GEN-E083"], text(ONE.replace("peripherals: [mmuart1]", "peripherals: [mmuart1, pdma]")), ICICLE,
             "pdma")
    rejected(["GEN-E084"], text(ONE.replace("harts: [1]", "harts: [2]").replace("mmuart1", "mmuart2")),
             CONFIGS["video_kit"], "mmuart2")


@case("every code of the derivations has a negative case, and the codes are in the table of config/README.md")
def _():
    assert covered == set(checks.DERIVE_CODES), sorted(covered ^ set(checks.DERIVE_CODES))
    readme = (ROOT / "config" / "README.md").read_text()
    for code in checks.DERIVE_CODES:
        assert f"| `{code}` | {checks.CODES[code]} |" in readme, code


@case("the derived system is immutable")
def _():
    d = derive.derive(system("amp_a"), ICICLE, SVD)
    raises(dataclasses.FrozenInstanceError, lambda: setattr(d, "ram_shutdown", 1))
    raises(dataclasses.FrozenInstanceError, lambda: setattr(d.windows[0], "origin", 0))


finish()
