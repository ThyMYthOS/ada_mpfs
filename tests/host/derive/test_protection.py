# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @verifies GEN-011, GEN-012
"""config/gen/mpfs_gen: the PMP of the XML evaluated (pmp.regions) and checked against the partitions
(derive/protection.py), the AMP contexts and the addresses of the peripherals (derive/contexts.py), the
rules of the layout of the entries (pmp.rules), and a negative case for every code of them. Needs the merged
SVD (tools/svd.py ensure).

The reference XMLs set no PMP that fits a partition, so the cases write their own into the XML of the Icicle
Kit in the model: the entries a user would set in the MSS Configurator for the system TWO_CONTEXTS (one
partition per context, the contexts of Microchip's PMP demo: harts 1 and 2 in A, 3 and 4 in B, APBBUS_CR and
CONTEXT_B_EN 0x12A818), a prod system. Each negative case changes that configuration in one point. The XML of the
PMP demo itself (config/boards/icicle_es_pmp_demo) is checked with tests/host/derive/fixtures/pmp_demo; a dev
system takes every finding as a note."""
import dataclasses
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path[:0] = [str(HERE.parent / "gen_ada"), str(ROOT / "config" / "gen"), str(ROOT / "tools")]

from gen_ada import svdread
from harness import case, finish
from mpfs_gen import checks, derive, pmp, target, xml_reader, yaml_reader
from mpfs_gen.checks import DerivationError
from mpfs_gen.derive import contexts, placement, protection

SVD = svdread.ensure(ROOT)
LAYOUT = xml_reader.svd_layout(SVD)
BLOCKS = xml_reader.svd_blocks(SVD)
BOARDS = ROOT / "config" / "boards"
XMLS = {p.parent.name: p for p in sorted(BOARDS.glob("*/*.xml"))}
CONFIGS = {board: xml_reader.read(path, SVD) for board, path in XMLS.items()}
ICICLE = CONFIGS["icicle"]
APB = "mss_memory_map/apb_split"
R, W, X, L = 0x01, 0x02, 0x04, 0x80
OFF, TOR, NA4, NAPOT = 0x00, 0x08, 0x10, 0x18
covered: set[str] = set()

TWO_CONTEXTS = """schema: 1
board: icicle
security_profile: prod
partitions:
  - name: a
    harts: [1, 2]
    profile: light
    memory:
      code: { region: lim, size: 64K }
      data: { region: lim, size: 64K }
    peripherals: [mmuart1, mmuart2]
  - name: b
    harts: [3, 4]
    profile: light
    memory:
      code: { region: lim, size: 64K }
      data: { region: lim, size: 64K }
    peripherals: [mmuart3, mmuart4]
ipc:
  - { name: ab, between: [a, b], size: 16K }
"""
# TWO_CONTEXTS with 8 KiB of fast_text for b: a window in the ITIM of hart 3 and of hart 4.
FAST_B = TWO_CONTEXTS.replace("      data: { region: lim, size: 64K }\n    peripherals: [mmuart3",
                              "      data: { region: lim, size: 64K }\n      fast_text: { region: itim, size: 8K }\n"
                              "    peripherals: [mmuart3")
# The contexts of Microchip's PMP demo (applications/mpfs-pmp-demo of polarfire-soc-bare-metal-examples).
A_EN = ("MMUART1", "MMUART2", "SPI0", "I2C0", "CAN0", "GEM0", "GPIO0", "GPIO2", "RTC", "CRYPTO", "USB", "QSPIXIP",
        "ATHENA", "EMMC")
B_EN = ("MMUART3", "MMUART4", "SPI1", "I2C1", "CAN1", "GEM1", "GPIO1")


def edited(config, changes):
    """<config> with the fields of {(section, register, field): value} changed and the values of their
    registers recomputed (the RW fields at their offsets), as the reader computes them."""
    registers = []
    for reg in config.registers:
        fields = tuple(dataclasses.replace(f, value=changes[(reg.section, reg.name, f.name)])
                       if (reg.section, reg.name, f.name) in changes else f for f in reg.fields)
        value = sum(f.value << f.bits.offset for f in fields if f.access == "RW" and f.value is not None)
        registers.append(dataclasses.replace(reg, fields=fields, value=value))
    keys = {(r.section, r.name, f.name) for r in registers for f in r.fields}
    assert set(changes) <= keys, set(changes) - keys
    return dataclasses.replace(config, registers=tuple(registers))


def contexts_of(a_harts=(1, 2), b_harts=(3, 4), a_en=A_EN, b_en=B_EN, apbbus=B_EN):
    """The changes for the four context registers and APBBUS_CR."""
    changes = {}
    for name, on in (("CONTEXT_A_HART_EN", a_harts), ("CONTEXT_B_HART_EN", b_harts)):
        changes.update({(APB, name, f"HART{h}"): int(h in on) for h in range(5)})
    for name, on in (("CONTEXT_A_EN", a_en), ("CONTEXT_B_EN", b_en), ("APBBUS_CR", apbbus)):
        fields = ICICLE.register(APB, name).fields
        changes.update({(APB, name, f.name): int(f.name in on) for f in fields})
    return changes


def napot(first, size):
    return (first >> 2) | ((size >> 3) - 1)


def entries_for(ranges):
    """The PMP entries (cfg, pmpaddr) for [(first, size, rights cfg bits), ...]: one NAPOT entry for a power of
    two at a multiple of itself, otherwise an OFF entry with the base and a TOR entry."""
    out = []
    for first, size, bits in ranges:
        if size & (size - 1) == 0 and first % size == 0:
            out.append((NAPOT | bits, napot(first, size)))
        else:
            out += [(OFF, first >> 2), (TOR | bits, (first + size) >> 2)]
    return out


def with_pmp(changes, hart, entries):
    """<changes> with the 16 entries of <hart> set to <entries> (cfg, pmpaddr) and the rest OFF and 0."""
    section = f"mss_memory_map/pmp_h{hart}"
    entries = list(entries) + [(OFF, 0)] * (16 - len(entries))
    assert len(entries) == 16, entries
    for i, (cfg, addr) in enumerate(entries):
        changes[(section, f"CSR_PMPCFG{0 if i < 8 else 2}", f"PMP{i}CFG")] = cfg
        changes[(section, f"CSR_PMPADDR{i}", f"CSR_PMPADDR{i}")] = addr
    return changes


def system(text=TWO_CONTEXTS):
    return yaml_reader.read_text(text, "test.yaml")


def map_of(sys_):
    """The derived system map of <sys_>, taken as dev (the PMP checks are notes there)."""
    return derive.derive(dataclasses.replace(sys_, security_profile="dev"), ICICLE, SVD)


def allow_list(sys_, hart, extra=(), drop=()):
    """The unlocked entries a U partition of <sys_> needs on <hart>: its windows, its peripherals at the
    address of the demo's APBBUS_CR, the page of mtime; <extra> ranges added, <drop> names left out."""
    d = map_of(sys_)
    part = next(p for p in d.partitions if hart in p.harts)
    apbbus = sum(1 << LAYOUT[contexts.APBBUS].fields[f].offset for f in B_EN)
    ranges = []
    for w in part.windows:
        if w.kind not in drop and (w.kind != "fast_text" or w.memory == placement.itim_name(hart)):
            ranges.append((w.origin, w.length, {"code+data": R | W | X, "ipc": R | W, "fast_text": R | X}[w.kind]))
    for name in part.peripherals.names:
        if name not in drop:
            b = contexts.block_of(name, apbbus, LAYOUT, BLOCKS)
            ranges.append((b.base, b.length, R | W))
    if "mtime" not in drop:
        mtime = protection.mtime_page(BLOCKS)
        ranges.append((mtime.base, mtime.length, R))
    return entries_for(list(ranges) + list(extra))


def deny_list(sys_, hart):
    """Locked entries without rights over what a hart of <sys_> must not reach in M mode either: the windows of
    the other partition, the DTIM and the ITIMs of the harts outside its partition, and the bus window of the
    other context (the HI window for A; for B the LO peripherals of both buses)."""
    d = map_of(sys_)
    part = next(p for p in d.partitions if hart in p.harts)
    ranges = [(w.origin, w.length, L) for w in d.windows if part.name not in w.owners]
    ranges += [(0x0100_0000, 0x2000, L)]
    ranges += [(target.ITIM_ORIGIN + h * target.ITIM_WINDOW, target.ITIM_WINDOW, L) for h in range(5)
               if h not in part.harts]
    if part.name == "a":
        ranges.append((0x2800_0000, 0x0800_0000, L))
    else:
        ranges += [(0x2000_0000, 0x2000, L), (0x2010_0000, 0x4_0000, L)]
    return entries_for(ranges)


def good(sys_=None, per_hart=None, more=None):
    """The XML of the Icicle Kit with the contexts of the demo, MEM_CONFIGS_ENABLED.PMP 1 and the allow list
    of each hart (per_hart overrides a hart's entries), more changes on top."""
    sys_ = sys_ or system()
    changes = contexts_of()
    changes[(APB, "MEM_CONFIGS_ENABLED", "PMP")] = 1
    with_pmp(changes, 0, [])
    for hart in (1, 2, 3, 4):
        with_pmp(changes, hart, (per_hart or {}).get(hart) or allow_list(sys_, hart))
    changes.update(more or {})
    return edited(ICICLE, changes)


def codes_of(sys_, config, entries=target.PMP_ENTRIES):
    try:
        d = derive.derive(sys_, config, SVD, pmp_entries=entries)
    except DerivationError as err:
        return err.codes, str(err)
    return [w.code for w in d.warnings], "\n".join(map(str, d.warnings))


def expect(expected, sys_, config, *words, entries=target.PMP_ENTRIES):
    """The derivation reports exactly the codes <expected> (errors first, then warnings), with <words>."""
    got, message = codes_of(sys_, config, entries)
    assert got == expected, (got, message)
    for word in words:
        assert word in message, (word, message)
    covered.update(expected)
    return message


# --- the evaluation ------------------------------------------------------------------------------------------

def hart_pmp(entries, hart=1):
    entries = list(entries) + [(OFF, 0)] * (16 - len(entries))
    cfg0 = sum(c << (8 * i) for i, (c, _) in enumerate(entries[:8]))
    cfg2 = sum(c << (8 * i) for i, (c, _) in enumerate(entries[8:]))
    return pmp.HartPmp(hart, cfg0, cfg2, tuple(a for _, a in entries))


@case("regions: the lowest index decides; U gets what the entry grants, M all unless the entry is locked; no match: "
      "M allowed, U denied")
def _():
    p = hart_pmp([(NAPOT | R, napot(0x1000, 0x1000)), (NAPOT | R | W | X, napot(0, 0x4000)),
                  (NAPOT | L, napot(0x8000, 0x1000))])
    got = [(r.first, r.last, r.entry, r.u, r.m) for r in pmp.regions(p, 36)]
    assert got == [(0, 0xFFF, 1, "rwx", "rwx"), (0x1000, 0x1FFF, 0, "r--", "rwx"), (0x2000, 0x3FFF, 1, "rwx", "rwx"),
                   (0x4000, 0x7FFF, None, "---", "rwx"), (0x8000, 0x8FFF, 2, "---", "---"),
                   (0x9000, (1 << 38) - 1, None, "---", "rwx")], got


@case("regions: TOR from the pmpaddr before it, NA4, and pmpaddr taken in the bits the hart implements")
def _():
    p = hart_pmp([(OFF, 0x1000 >> 2), (TOR | R | L, 0x3000 >> 2), (NA4 | W | R, 0x5000 >> 2)])
    got = [(r.first, r.last, r.u, r.m) for r in pmp.regions(p, 36) if r.entry is not None]
    assert got == [(0x1000, 0x2FFF, "r--", "r--"), (0x5000, 0x5003, "rw-", "rwx")], got
    # the all-ones NAPOT value of the XML: the whole space of a 36-bit pmpaddr (2^38 bytes) and of 54 bits
    whole = hart_pmp([(NAPOT | R | W | X | L, 0x003F_FFFF_FFFF_FFFF)])
    assert [(r.first, r.last) for r in pmp.regions(whole, 36)] == [(0, (1 << 38) - 1)]
    assert [(r.first, r.last) for r in pmp.regions(whole, 54)] == [(0, (1 << 56) - 1)]
    # bits above the implemented ones are not there: address bit 40 is pmpaddr bit 38, beyond 36 bits
    high = hart_pmp([(NA4 | R, (1 << 40 | 0x1000) >> 2)])
    assert [(r.first, r.u) for r in pmp.regions(high, 36) if r.entry is not None] == [(0x1000, "r--")]
    assert [(r.first, r.u) for r in pmp.regions(high, 54) if r.entry is not None] == [(1 << 40 | 0x1000, "r--")]


@case("the locked part: locked entries and the base of a locked TOR entry; the unlocked part: the rest in use")
def _():
    p = hart_pmp([(OFF, 0x1000 >> 2), (TOR | L, 0x3000 >> 2), (NAPOT | R | W, napot(0x8000, 0x1000)),
                  (OFF, 0), (NA4 | R, 0x10)])
    assert [e.index for e in pmp.locked_part(p)] == [0, 1]
    assert [e.index for e in pmp.unlocked_part(p)] == [2, 4]
    assert pmp.in_use(p) == (0, 1, 2, 4)
    unlocked_tor = hart_pmp([(OFF, 0x1000 >> 2), (TOR | R, 0x3000 >> 2)])
    assert [e.index for e in pmp.unlocked_part(unlocked_tor)] == [0, 1] and pmp.locked_part(unlocked_tor) == ()


@case("the target: 16 entries, 8 under QEMU; pmpaddr 36 bits on a U54 (measured), 54 on the E51 (not measured)")
def _():
    assert (target.PMP_ENTRIES, target.QEMU_PMP_ENTRIES) == (16, 8)
    assert target.PMPADDR_BITS == (54, 36, 36, 36, 36)


# --- contexts and addresses ----------------------------------------------------------------------------------

@case("the addresses: LO or HI after APBBUS_CR for the peripherals of both buses, one address for the others")
def _():
    lo = contexts.block_of("mmuart3", 0, LAYOUT, BLOCKS)
    hi = contexts.block_of("mmuart3", 1 << 3, LAYOUT, BLOCKS)
    assert (lo.block, lo.base, lo.length, lo.bus) == ("MMUART3_LO", 0x2010_4000, 0x1000, "LO")
    assert (hi.block, hi.base, hi.bus) == ("MMUART3_HI", 0x2810_4000, "HI")
    gem = contexts.block_of("mac1", 1 << 17, LAYOUT, BLOCKS)
    assert (gem.block, gem.base, gem.length) == ("GEM_B_HI", 0x2811_2000, 0x2000), gem
    spi = contexts.block_of("spi1", 1 << 11, LAYOUT, BLOCKS)
    assert (spi.block, spi.base) == ("SPI_B_HI", 0x2810_9000)
    assert (contexts.block_of("usb", 0xFFFFFF, LAYOUT, BLOCKS).base, contexts.block_of("qspi", 0, LAYOUT, BLOCKS).base) \
        == (0x2020_1000, 0x2100_0000)
    assert contexts.block_of("fic0", 0, LAYOUT, BLOCKS) is None
    assert len(contexts.bus_blocks(BLOCKS, "HI")) == 24
    assert all(b.base >= contexts.HI_BASE for b in contexts.bus_blocks(BLOCKS, "HI"))
    assert all(contexts.LO_BASE <= b.base < contexts.HI_BASE for b in contexts.bus_blocks(BLOCKS, "LO"))


@case("the critical blocks at their addresses, all from the SVD in the whole pages their registers touch; the bus "
      "error unit of each hart; the page of mtime")
def _():
    got = {b.name: (b.base, b.length) for b in protection.critical_blocks(BLOCKS)}
    ioscb = {name: (b.base, 0x1000) for name, b in BLOCKS.items() if name.startswith("IOSCB_")}
    assert len(ioscb) == 10 and all(0x3E00_0000 <= base < 0x3F00_0000 for base, _ in ioscb.values()), ioscb
    beus = {f"bus error unit of hart {h}": (0x0170_0000 + h * 0x1000, 0x1000) for h in range(5)}
    assert got == {"L2 controller": (0x0201_0000, 0x1000), "PDMA": (0x0300_0000, 0x4000),
                   "SYSREG": (0x2000_2000, 0x1000), "SCB": (0x2000_3000, 0x1000), "AXI switch": (0x2000_4000, 0x1000),
                   "MPUCFG": (0x2000_5000, 0x1000), "CFG_DDR_SGMII_PHY": (0x2000_7000, 0x1000),
                   "eNVM controller": (0x2020_0000, 0x1000), "system controller": (0x3702_0000, 0x1000),
                   "system controller mailbox": (0x3702_0000, 0x1000),
                   "IOSCB configuration": (0x3708_0000, 0x1000), **ioscb, **beus}, got
    mtime = protection.mtime_page(BLOCKS)
    assert (mtime.base, mtime.length) == (0x0200_B000, 0x1000)


@case("the XMLs of the boards use no contexts (all four registers and APBBUS_CR 0), the PMP demo and amp_c do")
def _():
    for board, config in CONFIGS.items():
        c, _, found = contexts.derive(system(), config, LAYOUT, BLOCKS)
        if board == "icicle_es_pmp_demo":
            assert found == [] and c.used and c.apbbus_cr == 0x12A818, board
            continue
        if board == "icicle_amp_c":
            assert c.used and c.apbbus_cr == 0x18 and (c.a_harts, c.b_harts) == ((1, 2), (3, 4)), c
            assert (c.a_peripherals, c.b_peripherals) == (("MMUART1", "MMUART2"), ("MMUART3", "MMUART4")), c
            continue
        assert found == [] and not c.used and c.apbbus_cr == 0, board


# --- positive cases ------------------------------------------------------------------------------------------

@case("the system of two contexts with the allow list of each hart passes, also with 8 entries (QEMU)")
def _():
    sys_ = system()
    for entries in (16, 8):
        d = derive.derive(sys_, good(sys_), SVD, pmp_entries=entries)
        assert d.warnings == (), d.warnings
    a, b = d.partitions
    assert (a.context, b.context) == ("A", "B")
    assert [(x.name, x.base, x.bus) for x in a.blocks] == [("mmuart1", 0x2010_0000, "LO"), ("mmuart2", 0x2010_2000, "LO")]
    assert [(x.name, x.base, x.bus) for x in b.blocks] == [("mmuart3", 0x2810_4000, "HI"), ("mmuart4", 0x2810_6000, "HI")]
    pr = d.protection
    assert pr.contexts.used and pr.contexts.apbbus_cr == 0x12A818 and pr.entries == 8
    assert (pr.contexts.a_harts, pr.contexts.b_harts) == ((1, 2), (3, 4))
    h1 = pr.hart(1)
    assert h1.locked == () and len(h1.unlocked) == h1.used and h1.bits == 36
    assert pr.hart(0).used == 0


@case("the printout of derive: the context and addresses of each partition, APBBUS_CR, the contexts, the "
      "occupation of each hart, the warnings")
def _():
    import importlib
    cli = importlib.import_module("mpfs_gen.__main__")
    sys_ = system()
    lines = cli.describe_derived(derive.derive(sys_, good(sys_), SVD))
    assert "  context A; addresses mmuart1 0x2010_0000 LO, mmuart2 0x2010_2000 LO" in lines, lines
    assert "  context B; addresses mmuart3 0x2810_4000 HI, mmuart4 0x2810_6000 HI" in lines, lines
    assert "APBBUS_CR 0x0012_a818" in lines and "partitions on contexts: a A, b B" in lines, lines
    assert any(line.startswith("contexts: A harts [1, 2] peripherals MMUART1, MMUART2, SPI0") for line in lines)
    assert "pmp hart 0: 0 of 16 entries in use, locked [], unlocked []; pmpaddr 54 bits" in lines, lines
    assert any(line.startswith("pmp hart 3: ") and "6 of 16 entries in use, locked [], unlocked [0, 1, 2, 3, 4, 5]" in line for line in lines)
    assert "  [0x200b000, 0x200bfff] entry 5: U r--, M rwx" in lines, lines
    warned = cli.describe_derived(derive.derive(sys_, good(sys_, more={(APB, "MEM_CONFIGS_ENABLED", "PMP"): 0}), SVD))
    assert warned[-1].startswith("warning: GEN-E104 (warning) mss_memory_map/apb_split/MEM_CONFIGS_ENABLED.PMP")
    dev = cli.describe_derived(map_of(sys_))
    assert any(line.startswith("pmp: not applied (security_profile dev)") for line in dev), dev
    assert any(line.startswith("note: GEN-E105 mss_memory_map/pmp_h1/PMP0CFG") for line in dev), dev
    assert not any(line.startswith("pmp: not applied") for line in lines)


@case("a locked deny list before the allow list binds M mode: no foreign window for M, the critical blocks M "
      "reaches are reported as warnings")
def _():
    sys_ = system()
    per_hart = {h: deny_list(sys_, h) + allow_list(sys_, h) for h in (1, 2, 3, 4)}
    assert all(len(e) <= 16 for e in per_hart.values())
    message = expect(["GEN-E127"] * 4, sys_, good(sys_, per_hart), "M mode of hart 1", "SYSREG")
    assert "M mode of hart 4 ('b')" in message and "PDMA" in message
    dd = derive.derive(sys_, good(sys_, per_hart), SVD)
    assert [e.index for e in dd.protection.hart(1).locked] == list(range(len(deny_list(sys_, 1))))
    assert dd.protection.hart(1).unlocked[0].index == len(deny_list(sys_, 1))
    # without the deny list, M mode of a hart with a locked entry reaches the window of b
    loose = {1: entries_for([(0x2000_2000, 0x1000, L)]) + allow_list(sys_, 1)}
    expect(["GEN-E124", "GEN-E127", "GEN-E135"], sys_, good(sys_, loose),
           "M mode of hart 1 ('a') reaches", "code+data of 'b'", "dtim of hart 0", "mmuart3 of partition 'b'")


# --- negative cases, one per code ----------------------------------------------------------------------------

@case("GEN-E102: a locked entry after an unlocked one")
def _():
    sys_ = system()
    late = allow_list(sys_, 1) + deny_list(sys_, 1)
    expect(["GEN-E102", "GEN-E127"], sys_, good(sys_, {1: late}), "pmp_h1", "after the unlocked entry 0")


@case("GEN-E103: an entry beyond the 8 entries of QEMU; the same configuration fits the 16 of the silicon")
def _():
    sys_ = system()
    spread = allow_list(sys_, 1) + [(OFF, 0)] * 4 + entries_for([(0x0C00_0000, 0x0040_0000, 0)])
    assert len(spread) > 8
    assert codes_of(sys_, good(sys_, {1: spread}))[0] == []
    expect(["GEN-E103"], sys_, good(sys_, {1: spread}), "the target has 8", entries=8)


@case("GEN-E104: MEM_CONFIGS_ENABLED.PMP 0 with entries in the PMP sections (a warning)")
def _():
    sys_ = system()
    expect(["GEN-E104"], sys_, good(sys_, more={(APB, "MEM_CONFIGS_ENABLED", "PMP"): 0}), "pmp_h1, pmp_h2")


@case("GEN-E105: a locked entry with rights over the range of a later entry; the reference XMLs' entry 0")
def _():
    sys_ = system()
    own = next(w for w in map_of(sys_).windows if w.owners == ("a",))
    hiding = deny_list(sys_, 1) + entries_for([(own.origin, own.length, L | R | W | X)]) + allow_list(sys_, 1)
    expect(["GEN-E105", "GEN-E127"], sys_, good(sys_, {1: hiding}), "hiding entry")
    for board in ("icicle", "icicle_es"):
        codes, message = codes_of(sys_, CONFIGS[board])
        assert codes.count("GEN-E105") == 4 and "GEN-E104" in codes, (board, codes)
        assert "entry 0 of hart 1 is locked and grants rwx to all modes over the whole address space" in message
    covered.add("GEN-E105")


@case("GEN-E120 to GEN-E122: a U partition without its window, its peripheral, the page of mtime")
def _():
    sys_ = system()
    expect(["GEN-E120"], sys_, good(sys_, {1: allow_list(sys_, 1, drop=("ipc",))}), "hart 1 of 'a' lacks rw-",
           "ipc window")
    expect(["GEN-E121"], sys_, good(sys_, {3: allow_list(sys_, 3, drop=("mmuart4",))}), "mmuart4", "HI address",
           "0x28106000")
    expect(["GEN-E122"], sys_, good(sys_, {4: allow_list(sys_, 4, drop=("mtime",))}), "hart 4", "mtime")
    # read only is not enough for code+data
    sys_d = map_of(sys_)
    own = next(w for w in sys_d.windows if w.owners == ("a",))
    weak = entries_for([(own.origin, own.length, R)]) + allow_list(sys_, 1)
    expect(["GEN-E120"], sys_, good(sys_, {1: weak}), "lacks rwx")


@case("GEN-E123: U mode reaches what is not its own (a warning): the PLIC")
def _():
    sys_ = system()
    extra = allow_list(sys_, 2, extra=[(0x0C00_0000, 0x0400_0000, R | W)])
    expect(["GEN-E123"], sys_, good(sys_, {2: extra}), "U mode of hart 2 ('a') reaches what is not its own",
           "[0xc000000, 0xfffffff]")


@case("GEN-E124: the window of another partition, a foreign ITIM that a partition uses, a foreign peripheral; an "
      "ITIM that no partition uses is not foreign")
def _():
    sys_ = system()
    d = map_of(sys_)
    b_window = next(w for w in d.windows if w.owners == ("b",))
    expect(["GEN-E124"], sys_, good(sys_, {1: allow_list(sys_, 1, extra=[(b_window.origin, b_window.length, R)])}),
           "code+data of 'b'")
    expect(["GEN-E124"], sys_, good(sys_, {2: allow_list(sys_, 2, extra=[(0x2810_4000, 0x1000, R | W)])}),
           "mmuart3 of partition 'b'")
    # the ITIM of hart 3 unused: U mode reaching it is only what is not its own
    expect(["GEN-E123"], sys_, good(sys_, {1: allow_list(sys_, 1, extra=[(0x0181_8000, 0x1000, R)])}),
           "what is not its own [0x1818000, 0x1818fff]")
    # with fast_text in the ITIMs of b's harts, the ITIM of hart 3 is foreign: the window and the rest of it
    fast = system(FAST_B)
    assert [w.memory for w in map_of(fast).windows if w.kind == "fast_text"] == ["u54_3_itim", "u54_4_itim"]
    expect(["GEN-E124"], fast, good(fast, {1: allow_list(fast, 1, extra=[(0x0181_8000, 0x4000, R)])}),
           "fast_text of 'b' [0x1818000, 0x1819fff]", "u54_3_itim of hart 3 [0x181a000, 0x181bfff]")


@case("GEN-E125 and GEN-E126: a critical block, SYSREG and MPUCFG from U mode")
def _():
    sys_ = system()
    expect(["GEN-E125"], sys_, good(sys_, {1: allow_list(sys_, 1, extra=[(0x0201_0000, 0x1000, R | W)])}),
           "L2 controller")
    expect(["GEN-E125"], sys_, good(sys_, {1: allow_list(sys_, 1, extra=[(0x0300_0000, 0x4000, R)])}), "PDMA")
    expect(["GEN-E126"], sys_, good(sys_, {3: allow_list(sys_, 3, extra=[(0x2000_2000, 0x1000, R)])}), "SYSREG",
           "exposes APBBUS_CR")
    expect(["GEN-E126"], sys_, good(sys_, {3: allow_list(sys_, 3, extra=[(0x2000_5000, 0x1000, R | W)])}), "MPUCFG")


@case("GEN-E127: a critical block from M mode of a hart with locked entries (a warning)")
def _():
    sys_ = system()
    locked = deny_list(sys_, 3) + allow_list(sys_, 3)
    expect(["GEN-E127"], sys_, good(sys_, {3: locked}), "M mode of hart 3 ('b') reaches", "PDMA", "SYSREG")
    # a locked entry without rights over the critical blocks takes them from M mode as well
    closed = deny_list(sys_, 3) + entries_for([(0x0201_0000, 0x1000, L), (0x0300_0000, 0x4000, L),
                                               (0x2000_0000, 0x8000, L)])
    message = expect(["GEN-E127"], sys_, good(sys_, {3: closed + allow_list(sys_, 3)}))
    assert "PDMA" not in message and "SYSREG" not in message and "eNVM controller" in message, message


@case("GEN-E130 to GEN-E134: the contexts")
def _():
    sys_ = system()
    expect(["GEN-E130"], sys_, good(sys_, more=contexts_of(a_harts=(1, 2), b_harts=(2, 3, 4))), "hart 2",
           "CONTEXT_A_HART_EN")
    expect(["GEN-E131"], sys_, good(sys_, more=contexts_of(a_en=A_EN + ("MMUART3",))), "MMUART3")
    expect(["GEN-E132"], sys_, good(sys_, more=contexts_of(apbbus=B_EN[:-1])), "0x0002a818", "0x0012a818")
    moved = TWO_CONTEXTS.replace("[mmuart1, mmuart2]", "[mmuart1, mmuart2, spi1]")
    sys_m = system(moved)
    expect(["GEN-E133"], sys_m, good(sys_m), "spi1 of 'a' (context A, harts [1, 2]) is not in CONTEXT_A_EN")
    # MMUART0 and the watchdogs have no context key in the Configurator: they belong to no context
    free = system(TWO_CONTEXTS.replace("[mmuart1, mmuart2]", "[mmuart0, mmuart1, mmuart2, wdog1]")
                  .replace("[mmuart3, mmuart4]", "[mmuart3, mmuart4, wdog3]"))
    assert codes_of(free, good(free))[0] == []
    assert not {"MMUART0", "WDOG0", "WDOG3", "TIMER", "H2FINT"} & contexts.CONFIGURABLE
    expect(["GEN-E134"], sys_, good(sys_, more=contexts_of(a_harts=(1,), b_harts=(2, 3, 4))),
           "hart 1 in context A, hart 2 in context B")


@case("GEN-E135: a PMP window of context A over the HI window of context B (a warning)")
def _():
    sys_ = system()
    expect(["GEN-E135"], sys_, good(sys_, {1: allow_list(sys_, 1, extra=[(0x2810_9000, 0x1000, R | W)])}),
           "the HI window of context B", "[0x28109000, 0x28109fff]")
    expect(["GEN-E135"], sys_, good(sys_, {4: allow_list(sys_, 4, extra=[(0x2010_8000, 0x1000, R)])}),
           "the LO window of context A")


@case("the reference systems with the reference XMLs: refused in prod (the open entry 0 of the U54 harts, the E51 "
      "without a PMP for the U partition monitor), derived in dev with the same findings as notes")
def _():
    for name in ("amp_a", "amp_b", "amp_c", "amp_d"):
        sys_ = yaml_reader.read(ROOT / "systems" / name / "system.yaml")
        assert sys_.security_profile == ("prod" if name == "amp_c" else "dev"), name
        prod = dataclasses.replace(sys_, security_profile="prod")
        codes, _ = codes_of(prod, ICICLE)
        assert {"GEN-E105", "GEN-E124", "GEN-E104"} <= set(codes), (name, sorted(set(codes)))
        d = derive.derive(dataclasses.replace(sys_, security_profile="dev"), ICICLE, SVD)
        assert not d.protection.applied and d.warnings == ()
        assert sorted(n.code for n in d.notes) == sorted(codes), (name, [n.code for n in d.notes])


@case("the PMP demo in a prod system: the contexts pass (A harts 1 and 2 on the LO bus, B harts 3 and 4 on the HI "
      "bus), the locked tables grant SYSREG and the L2 controller to all modes and not the partitions' LIM windows, "
      "and 11 entries do not fit the 8 of QEMU")
def _():
    path = HERE / "fixtures" / "pmp_demo" / "system.yaml"
    sys_ = yaml_reader.read(path)
    demo = CONFIGS["icicle_es_pmp_demo"]
    assert sys_.security_profile == "prod" and derive.xml_of(sys_, path) == XMLS["icicle_es_pmp_demo"]
    assert demo.design.format_version == "0.5.3" and demo.value(APB, "MEM_CONFIGS_ENABLED") == 0x3
    c, parts, found = contexts.derive(sys_, demo, LAYOUT, BLOCKS)
    assert found == [] and c.used and c.apbbus_cr == 0x12A818 and (c.a_harts, c.b_harts) == ((1, 2), (3, 4))
    assert [p.context for p in parts] == ["A", "B"]
    assert [(b.name, b.base) for b in parts[1].blocks] == [("mmuart3", 0x2810_4000), ("mmuart4", 0x2810_6000)]
    harts, found = pmp.of(demo)
    assert found == [] and pmp.rules(demo, harts) == []
    assert [len(pmp.in_use(h)) for h in harts] == [0, 11, 11, 7, 7]
    assert all(e.locked for h in harts for e in (h.entry(i) for i in pmp.in_use(h)))
    codes, message = codes_of(sys_, demo)
    assert codes == ["GEN-E120", "GEN-E125", "GEN-E126"] * 4 + ["GEN-E123", "GEN-E127"] * 4, codes
    assert "hart 1 of 'a' lacks rwx in U mode on its code+data window lim [0x8000000, 0x801ffff]" in message
    assert "U mode of hart 3 ('b') reaches SYSREG [0x20002000, 0x20002fff]" in message
    assert "U mode of hart 4 ('b') reaches L2 controller [0x2010000, 0x2010fff]" in message
    assert "M mode of hart 2 ('a') reaches L2 controller [0x2010000, 0x2010fff]; SYSREG" in message
    assert "GEN-E121" not in codes and "GEN-E122" not in codes and "GEN-E124" not in codes
    codes8, message8 = codes_of(sys_, demo, entries=8)
    assert codes8.count("GEN-E103") == 4 and "hart 1 uses entries 8, 9, 10, 11, 12, 13, 14" in message8, message8
    dev = derive.derive(dataclasses.replace(sys_, security_profile="dev"), demo, SVD)
    assert sorted(n.code for n in dev.notes) == sorted(codes) and dev.warnings == ()


@case("every code of the PMP against the partitions and of the contexts has a negative case, the warnings are the documented ones, "
      "and the codes are in the table of config/README.md")
def _():
    wanted = checks.PROTECTION_CODES
    assert covered - checks.PMP_CODES == wanted, sorted((covered - checks.PMP_CODES) ^ wanted)
    assert checks.WARNINGS == {"GEN-E104", "GEN-E123", "GEN-E127", "GEN-E135"}, checks.WARNINGS
    readme = (ROOT / "config" / "README.md").read_text()
    for code in wanted:
        assert f"| `{code}` | {checks.CODES[code]} |" in readme, code


finish()
