# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @req GEN-012
"""The AMP contexts A and B of the MSS Configurator and the address of each peripheral of a partition.

The silicon has two APB buses for the peripherals that MSS TRM DS60001702S Table 3-49 lists twice: the main
bus at 0x2000_0000 (LO) and the AMP bus at 0x2800_0000 (HI). APBBUS_CR (SYSREG) puts each of them on one of
the two; the bit of a peripheral is the field of its name in the SVD. Those peripherals have a block <NAME>_LO
and <NAME>_HI in the SVD (DUAL below: MMUART0 to 4, WDOG0 to 4, SPI, I2C, CAN, GEM (MAC), GPIO0 to 2, RTC,
timer and the H2F interrupts); every other block has one address, the one of the SVD (SINGLE: the AHB
peripherals USB, QSPI, eMMC, the eNVM controller and Athena; the system blocks SYSREG, SCB, MPUCFG and the
others of the LO range have no HI address either). A peripheral of a partition is at its LO or HI address as
APBBUS_CR says, and takes the whole 4 KiB pages its registers in the SVD span.

The contexts are what the Configurator writes into mss_memory_map/apb_split: CONTEXT_A_HART_EN and
CONTEXT_B_HART_EN (one bit per hart), CONTEXT_A_EN and CONTEXT_B_EN (one bit per peripheral, the bits 0 to 23
those of APBBUS_CR). No register of the silicon holds them; the Configurator derives APBBUS_CR (the
peripherals of context B on the HI bus) and one PMP table per context from them. They are used for the
checks of consistency (Libero SoC Help §20.2.2.3.9: a hart "cannot be enabled in both Context A & Context
B"):

  GEN-E130  a hart is in both contexts
  GEN-E131  a peripheral is in both contexts
  GEN-E132  APBBUS_CR is not bits 23:0 of CONTEXT_B_EN while contexts are used
  GEN-E133  a peripheral of a partition is not in the context of its harts (only a peripheral that the
            Configurator can put into a context, CONFIGURABLE below)
  GEN-E134  the harts of a partition are not all in the same context (or all in none)

The Configurator does not offer every bit of CONTEXT_A_EN and CONTEXT_B_EN: its .cfg (pfsoc_mss, the keys
PMP_<P>_CONTEXT_A_EN and PMP_<P>_CONTEXT_B_EN) has them only for MMUART1 to 4, CAN0 and 1, GEM0 and 1, GPIO0
to 2, I2C0 and 1, SPI0 and 1, QSPI, RTC, USB, EMMC and the crypto block (CRYPTO_CFG, CRYPTO_MEM). MMUART0,
WDOG0 to 4, the timer and the H2F interrupts have no such key: they cannot be put into a context, stay on the
LO bus and belong to no context, so GEN-E133 does not apply to them (a partition of either context may own
one; its PMP still decides who reaches it).

That partitions of different contexts share no peripheral needs no rule of its own: system.yaml gives a
peripheral (the console included) to one partition only (GEN-E025, GEN-E026). Contexts are used when one of
the four registers is not 0; the reference XMLs have all four 0.
"""
import re
from dataclasses import dataclass

from gen_ada import svdread

from .. import target
from ..checks import Diagnostic, diagnostic
from ..model import MssConfiguration, System

APB_SPLIT = "mss_memory_map/apb_split"
CONTEXT_REGISTERS = ("CONTEXT_A_EN", "CONTEXT_B_EN", "CONTEXT_A_HART_EN", "CONTEXT_B_HART_EN")
APBBUS = ("SYSREG", "APBBUS_CR")
LO_BASE, HI_BASE = 0x2000_0000, 0x2800_0000
# The field of APBBUS_CR -> the name of the blocks <name>_LO and <name>_HI of the SVD.
DUAL = {**{f"MMUART{i}": f"MMUART{i}" for i in range(5)}, **{f"WDOG{i}": f"WDOG{i}" for i in range(5)},
        "SPI0": "SPI_A", "SPI1": "SPI_B", "I2C0": "I2C_A", "I2C1": "I2C_B", "CAN0": "CAN_A", "CAN1": "CAN_B",
        "GEM0": "GEM_A", "GEM1": "GEM_B", "TIMER": "MSTIMER", "GPIO0": "GPIO_IOBANK0", "GPIO1": "GPIO_IOBANK1",
        "GPIO2": "GPIO_FAB", "RTC": "MSRTC", "H2FINT": "H2FINT"}
# A peripheral of system.yaml with one address -> (its field of CONTEXT_A_EN and CONTEXT_B_EN or None, the
# block of the SVD).
SINGLE = {"usb": ("USB", "USB"), "qspi": ("QSPIXIP", "QSPIXIP"), "mmc": ("EMMC", "EMMC_SD"),
          "athena": ("ATHENA", "ATHENA"), "envm": (None, "ENVM")}
# A peripheral of system.yaml on both buses -> its field of APBBUS_CR (and of CONTEXT_A_EN, CONTEXT_B_EN).
_RENAMED = {"mac0": "GEM0", "mac1": "GEM1"}
# The fields of CONTEXT_A_EN and CONTEXT_B_EN that the Configurator can set (the module text).
CONFIGURABLE = frozenset({*(f"MMUART{i}" for i in range(1, 5)), "CAN0", "CAN1", "GEM0", "GEM1", "GPIO0", "GPIO1",
                          "GPIO2", "I2C0", "I2C1", "SPI0", "SPI1", "QSPIXIP", "RTC", "USB", "EMMC", "ATHENA"})
_DUAL_NAME = re.compile(r"(mmuart|wdog)[0-4]|(spi|i2c|can)[01]|gpio[0-2]|rtc|timer|mac[01]")


@dataclass(frozen=True, slots=True)
class Block:
    """A block of registers at its address: <name> is the peripheral of system.yaml (or the name of the
    block), <block> the peripheral of the SVD, [base, base + length) the whole pages it takes, <bus> LO or HI
    for a peripheral of both APB buses, empty for one with a single address."""
    name: str
    block: str
    base: int
    length: int
    bus: str

    @property
    def last(self) -> int:
        return self.base + self.length - 1


@dataclass(frozen=True, slots=True)
class Contexts:
    """The AMP contexts of the XML: the harts and the peripherals (fields of CONTEXT_A_EN, CONTEXT_B_EN) of
    each, APBBUS_CR, and whether contexts are used at all."""
    apbbus_cr: int
    a_harts: tuple[int, ...]
    b_harts: tuple[int, ...]
    a_peripherals: tuple[str, ...]
    b_peripherals: tuple[str, ...]
    used: bool

    def of_hart(self, hart: int) -> str:
        """A, B, or empty for a hart in no context (in both: A, which GEN-E130 refuses anyway)."""
        return "A" if hart in self.a_harts else "B" if hart in self.b_harts else ""


@dataclass(frozen=True, slots=True)
class PartitionContext:
    """The context of a partition (A, B or empty) and its peripherals at their addresses."""
    context: str
    blocks: tuple[Block, ...]


def pages(span: int) -> int:
    """<span> bytes rounded up to whole pages (at least one)."""
    return max(1, -(-span // target.PAGE)) * target.PAGE


def context_field(name: str) -> str | None:
    """The field of CONTEXT_A_EN and CONTEXT_B_EN of a peripheral of system.yaml, None if it has none."""
    if _DUAL_NAME.fullmatch(name):
        return _RENAMED.get(name, name.upper())
    return SINGLE[name][0] if name in SINGLE else None


def bus_blocks(blocks: dict[str, svdread.Block], bus: str) -> tuple[Block, ...]:
    """The blocks of every peripheral of both buses at its address on <bus> (LO or HI), whichever bus
    APBBUS_CR puts it on."""
    return tuple(Block(field, f"{stem}_{bus}", blocks[f"{stem}_{bus}"].base, pages(blocks[f"{stem}_{bus}"].span),
                       bus) for field, stem in DUAL.items())


def block_of(name: str, apbbus_cr: int, svd: dict[tuple[str, str], svdread.Register],
             blocks: dict[str, svdread.Block]) -> Block | None:
    """The block of the peripheral <name> of system.yaml at the address that <apbbus_cr> gives it; None for
    a peripheral without an address of its own in the SVD (the FICs, the DDR controller, the CFM)."""
    if _DUAL_NAME.fullmatch(name):
        field = _RENAMED.get(name, name.upper())
        bus = "HI" if apbbus_cr >> svd[APBBUS].fields[field].offset & 1 else "LO"
        svd_name = f"{DUAL[field]}_{bus}"
    elif name in SINGLE:
        bus, svd_name = "", SINGLE[name][1]
    else:
        return None
    found = blocks[svd_name]
    return Block(name, svd_name, found.base, pages(found.span), bus)


def _fields(config: MssConfiguration, name: str) -> tuple[str, ...]:
    reg = config.register(APB_SPLIT, name)
    return tuple(f.name for f in reg.fields if f.value)


def derive(system: System, config: MssConfiguration, svd: dict[tuple[str, str], svdread.Register],
           blocks: dict[str, svdread.Block]) -> tuple[Contexts, tuple[PartitionContext, ...], list[Diagnostic]]:
    """The contexts of the XML <config>, the context and the peripheral blocks of each partition of
    <system> (in its order), and the rules they break."""
    found: list[Diagnostic] = []
    apbbus = config.value(APB_SPLIT, "APBBUS_CR")
    harts = {c: tuple(int(f.removeprefix("HART")) for f in _fields(config, f"CONTEXT_{c}_HART_EN")) for c in "AB"}
    periph = {c: _fields(config, f"CONTEXT_{c}_EN") for c in "AB"}
    used = any(config.value(APB_SPLIT, name) for name in CONTEXT_REGISTERS)
    contexts = Contexts(apbbus, harts["A"], harts["B"], periph["A"], periph["B"], used)

    both = sorted(set(harts["A"]) & set(harts["B"]))
    if both:
        found.append(diagnostic("GEN-E130", f"{APB_SPLIT}/CONTEXT_B_HART_EN",
                                f"hart {', '.join(map(str, both))} also in CONTEXT_A_HART_EN"))
    shared = [f for f in periph["A"] if f in periph["B"]]
    if shared:
        found.append(diagnostic("GEN-E131", f"{APB_SPLIT}/CONTEXT_B_EN", f"{', '.join(shared)} also in CONTEXT_A_EN"))
    b_low = config.value(APB_SPLIT, "CONTEXT_B_EN") & 0xFF_FFFF
    if used and apbbus != b_low:
        found.append(diagnostic("GEN-E132", f"{APB_SPLIT}/APBBUS_CR",
                                f"{apbbus:#010x} is not bits 23:0 of CONTEXT_B_EN ({b_low:#010x})"))

    parts: list[PartitionContext] = []
    for i, part in enumerate(system.partitions):
        of = {h: contexts.of_hart(h) for h in part.harts}
        context = of[part.harts[0]]
        if len(set(of.values())) > 1:
            found.append(diagnostic("GEN-E134", f"partitions[{i}].harts", ", ".join(
                f"hart {h} in {'context ' + c if c else 'no context'}" for h, c in of.items())))
        names = sorted(set(part.peripherals) | ({part.console} if part.console in target.CONSOLES else set()))
        if context and len(set(of.values())) == 1:
            mine = periph[context]
            for name in names:
                field = context_field(name)
                if field in CONFIGURABLE and field not in mine:
                    at = f"partitions[{i}].peripherals" if name in part.peripherals else f"partitions[{i}].console"
                    found.append(diagnostic("GEN-E133", at, f"{name} of {part.name!r} (context {context}, harts "
                                            f"{list(part.harts)}) is not in CONTEXT_{context}_EN"))
        placed = tuple(b for b in (block_of(n, apbbus, svd, blocks) for n in names) if b is not None)
        parts.append(PartitionContext(context, placed))
    return contexts, tuple(parts), found
