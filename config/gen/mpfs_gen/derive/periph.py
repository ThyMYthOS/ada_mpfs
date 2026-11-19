# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @req GEN-009
"""The peripherals: the bits that release the blocks of a partition, the RAMs that can be shut down and
the names of the direct GPIO interrupts.

  - A peripheral of system.yaml is a block of SYSREG.SUBBLK_CLOCK_CR in lower case (mmuart0, spi1, gpio2,
    ...) or a watchdog of the SVD (WDOGn_LO: wdog0 .. wdog4, which have no clock bit). The masks of a
    partition for SUBBLK_CLOCK_CR and SOFT_RESET_CR have the bits of the fields of the same names, taken
    from the SVD, for its peripherals and its console MMUART.
  - A peripheral that CONFIGURED_PERIPHERALS of the XML has a field for must be configured there (mmc is
    configured if EMMC or SD_SDIO is, as Microchip's MMC_RAM_OFF_IF_NOT_CONFIGURED has it).
  - RAM_SHUTDOWN_CR shuts down the RAMs of the blocks that the XML does not configure, by the rules of
    Microchip's mss_peripherals.h:97-111 @ 8d52d59: CAN0, CAN1, USB, GEM0 (MAC0), GEM1 (MAC1), MMC (EMMC and
    SD_SDIO) after CONFIGURED_PERIPHERALS, DDRC when DDRPHY_MODE & 0x7 is DDR_OFF_MODE 0x7 (mss_ddr.h:313,
    :373).
  - The PLIC sources GPIO_DIRECT_0 .. 31 are GPIO0 bit n (n < 14) or GPIO1 bit n - 14 when bit n of
    GPIO_INTERRUPT_FAB_CR is 0, GPIO2 bit n when it is 1 (the field names of the XML,
    GPIO0_0_OR_GPIO2_0 ...); GPIO_DIRECT_32 .. 37 are GPIO1 bits 18 .. 23 (mss_plic.h:264-304 @ 8d52d59).
"""
import re
from dataclasses import dataclass

from gen_ada import svdread

from ..checks import Diagnostic, diagnostic
from ..model import MssConfiguration, System

SUBBLK = ("SYSREG", "SUBBLK_CLOCK_CR")
SOFT_RESET = ("SYSREG", "SOFT_RESET_CR")
RAM_SHUTDOWN = ("SYSREG", "RAM_SHUTDOWN_CR")
PERIPHERALS = "mss_general/mss_peripherals"
FAB_CR = ("mss_io/io_mux", "GPIO_INTERRUPT_FAB_CR")
_WATCHDOG = re.compile(r"(WDOG\d+)_LO")
_FAB_FIELD = re.compile(r"(GPIO\d)_(\d+)_OR_(GPIO\d)_(\d+)")
_DIRECT = re.compile(r"GPIO_DIRECT_(\d+)")
# Blocks whose RAM is shut down when the XML does not configure them: RAM_SHUTDOWN_CR field -> the
# fields of CONFIGURED_PERIPHERALS of which one must be set (mss_peripherals.h:97-108).
RAM_RULES = (("CAN0", ("CAN0",)), ("CAN1", ("CAN1",)), ("USB", ("USB",)), ("GEM0", ("MAC0",)),
             ("GEM1", ("MAC1",)), ("MMC", ("EMMC", "SD_SDIO")))
CONFIGURED_ALIASES = {"mmc": ("EMMC", "SD_SDIO")}
DDRPHY_MODE_MASK = 0x7
DDR_OFF_MODE = 0x7
GPIO1_DIRECT_FIRST = 14     # GPIO_DIRECT_14 is GPIO1 bit 0 (or GPIO2 bit 14)


@dataclass(frozen=True, slots=True)
class PartitionPeripherals:
    """The peripherals of a partition (with its console MMUART) and its masks for SUBBLK_CLOCK_CR and
    SOFT_RESET_CR."""
    names: tuple[str, ...]
    clock_mask: int
    reset_mask: int


@dataclass(frozen=True, slots=True)
class Peripherals:
    partitions: tuple[tuple[str, PartitionPeripherals], ...]
    ram_shutdown: int
    ram_shutdown_blocks: tuple[str, ...]
    gpio_aliases: tuple[tuple[str, str], ...]    # (PLIC source name, GPIO line) of the direct lines


def catalogue(svd: dict[tuple[str, str], svdread.Register]) -> dict[str, str | None]:
    """The peripheral names of system.yaml: name -> the field of SUBBLK_CLOCK_CR (None: no clock bit)."""
    names: dict[str, str | None] = {f.lower(): f for f in svd[SUBBLK].fields}
    for peripheral, _ in svd:
        found = _WATCHDOG.fullmatch(peripheral)
        if found:
            names[found.group(1).lower()] = None
    return names


def _bit(svd: dict[tuple[str, str], svdread.Register], register: tuple[str, str], field: str) -> int:
    bits = svd[register].fields.get(field)
    return 1 << bits.offset if bits else 0


def gpio_aliases(config: MssConfiguration, sources: dict[str, int]) -> tuple[tuple[str, str], ...]:
    reg = config.register(*FAB_CR)
    out: list[tuple[str, str]] = []
    direct = {name: int(m.group(1)) for name in sources if (m := _DIRECT.fullmatch(name))}
    for name, n in sorted(direct.items(), key=lambda item: sources[item[0]]):
        field = next((f for f in reg.fields if f.bits.offset == n and f.bits.width == 1), None)
        parts = _FAB_FIELD.fullmatch(field.name) if field else None
        if parts:
            fabric = (reg.value >> n) & 1
            gpio, bit = (parts.group(3), parts.group(4)) if fabric else (parts.group(1), parts.group(2))
        else:
            gpio, bit = "GPIO1", str(n - GPIO1_DIRECT_FIRST)
        out.append((name, f"{gpio}_BIT{bit}"))
    return tuple(out)


def derive(system: System, config: MssConfiguration, svd: dict[tuple[str, str], svdread.Register],
           sources: dict[str, int]) -> tuple[Peripherals, list[Diagnostic]]:
    """The peripheral bits of <system> with the XML <config>, and the rules they break."""
    found: list[Diagnostic] = []
    known = catalogue(svd)
    configured = config.register(PERIPHERALS, "CONFIGURED_PERIPHERALS")
    flags = {f.name: bool(f.value) for f in configured.fields if f.value is not None}

    def is_configured(name: str) -> bool | None:
        fields = CONFIGURED_ALIASES.get(name, (name.upper(),))
        present = [flags[f] for f in fields if f in flags]
        return any(present) if present else None

    partitions: list[tuple[str, PartitionPeripherals]] = []
    for i, part in enumerate(system.partitions):
        names = set(part.peripherals)
        if part.console in known:
            names.add(part.console)
        clock = reset = 0
        for name in sorted(names):
            at = f"partitions[{i}].peripherals" if name in part.peripherals else f"partitions[{i}].console"
            if name not in known:
                found.append(diagnostic("GEN-E083", at, f"{name} is no block of SUBBLK_CLOCK_CR and no watchdog"))
                continue
            if is_configured(name) is False:
                found.append(diagnostic("GEN-E084", at, f"{name} of {part.name!r} is not in CONFIGURED_PERIPHERALS "
                                        f"({configured.value:#010x}) of the XML"))
            field = known[name]
            if field is not None:
                clock |= _bit(svd, SUBBLK, field)
                reset |= _bit(svd, SOFT_RESET, field)
        partitions.append((part.name, PartitionPeripherals(tuple(sorted(names)), clock, reset)))

    blocks = [block for block, fields in RAM_RULES if not any(flags.get(f, False) for f in fields)]
    if config.value("mss_ddr/mode", "DDRPHY_MODE") & DDRPHY_MODE_MASK == DDR_OFF_MODE:
        blocks.append("DDRC")
    shutdown = sum(_bit(svd, RAM_SHUTDOWN, b) for b in blocks)
    return Peripherals(tuple(partitions), shutdown, tuple(blocks), gpio_aliases(config, sources)), found
