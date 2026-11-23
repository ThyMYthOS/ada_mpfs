# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""What the readers return: immutable data classes.

System and the classes before it are the reader of system.yaml, with the defaults applied. Sizes are
bytes (int). Lists whose order means nothing (harts, peripherals, interrupts, the two ends of a channel,
the cache ways) are sorted tuples; the partitions, the channels and the boot sources keep the order of
the file. A value the description leaves to the XML is None.

MssConfiguration and the classes before it are the reader of the MSS Configurator XML (xml_reader.py).
"""
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Window:
    """A memory window: a region and its size; size None is the whole region (one partition only)."""
    region: str
    size: int | None


@dataclass(frozen=True, slots=True)
class Memory:
    code: Window
    data: Window
    fast_text: Window | None


@dataclass(frozen=True, slots=True)
class Stacks:
    main: int
    interrupt: int
    secondary: int


@dataclass(frozen=True, slots=True)
class Watchdog:
    instance: str
    timeout_ms: int


@dataclass(frozen=True, slots=True)
class Partition:
    name: str
    harts: tuple[int, ...]
    profile: str
    priv: str
    memory: Memory
    stacks: Stacks
    console: str
    peripherals: tuple[str, ...]
    interrupts: tuple[str, ...]
    watchdog: Watchdog | None
    monitor: bool = False

    @property
    def mask(self) -> int:
        """Bit n is hart n."""
        return sum(1 << hart for hart in self.harts)

    @property
    def lowest_hart(self) -> int:
        return self.harts[0]


@dataclass(frozen=True, slots=True)
class Ipc:
    name: str
    between: tuple[str, str]
    size: int
    doorbell: bool


@dataclass(frozen=True, slots=True)
class L2Ways:
    cache: int
    lim: int
    scratchpad: int


@dataclass(frozen=True, slots=True)
class L2:
    ways: L2Ways | None
    reason: str | None
    cache_partitioning: tuple[tuple[str, tuple[int, ...]], ...]


@dataclass(frozen=True, slots=True)
class Xml:
    file: str
    sha256: str


@dataclass(frozen=True, slots=True)
class Boot:
    sources: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Fram:
    transport: str
    part: str
    sck_hz: int
    cs: str
    wp: str


@dataclass(frozen=True, slots=True)
class System:
    schema: int
    board: str
    xml: Xml | None
    security_profile: str
    l2: L2
    partitions: tuple[Partition, ...]
    ipc: tuple[Ipc, ...]
    boot: Boot | None
    fram: Fram | None


# What the reader of the MSS Configurator XML returns (xml_reader.py): the registers of the core sections,
# keyed by section and name, with their values and the layout of their fields.


@dataclass(frozen=True, slots=True)
class BitField:
    """The bits of a field: the lowest one and how many."""
    offset: int
    width: int


@dataclass(frozen=True, slots=True)
class XmlField:
    """A field of a register as the XML states it.

    <value> is None for a field that is not RW: Microchip's generator composes a register of its RW
    fields only. <svd> is the layout of the field of the same name in the SVD, None where the SVD has no
    such field or no such register."""
    name: str
    bits: BitField
    access: str
    value: int | None
    svd: BitField | None


@dataclass(frozen=True, slots=True)
class XmlRegister:
    """A register of a core section; <section> is the path below <mss>, such as mss_clocks/mss_pll.

    <value> is the sum of the RW fields shifted to their offsets, the rule of Microchip's generator, also
    for a field that holds a known defect of the configurator; <defect> then says which and what the value
    means (None otherwise). <svd> names the register of the SVD with the layout
    (PERIPHERAL.REGISTER), None for a value the configurator keeps for the software only. <size> is
    the width of the register in bits."""
    section: str
    name: str
    size: int
    fields: tuple[XmlField, ...]
    value: int
    svd: str | None
    defect: str | None

    def field(self, name: str) -> XmlField:
        """The field <name>; KeyError if the register has none."""
        for item in self.fields:
            if item.name == name:
                return item
        raise KeyError(f"{self.section}/{self.name} has no field {name}")


@dataclass(frozen=True, slots=True)
class MemElement:
    """An element of mss_memory_map/map/mem_elements: a memory instance or a reset vector."""
    name: str
    address: int
    size: int
    description: str


@dataclass(frozen=True, slots=True)
class Design:
    """The <design_information> of the XML."""
    libero_version: str
    design_name: str
    part_number: str
    package: str
    created: str
    format_version: str


@dataclass(frozen=True, slots=True)
class MssConfiguration:
    """The MSS Configurator XML of a board.

    <registers> are the registers of the core sections in the order of the file; <validated> names the
    other sections (DDR, the SGMII and DDR PLLs, the high-speed IO), which the reader only checks.
    <sha256> is the SHA-256 of the bytes of the file."""
    source: str
    sha256: str
    design: Design
    registers: tuple[XmlRegister, ...]
    mem_elements: tuple[MemElement, ...]
    validated: tuple[str, ...]

    def register(self, section: str, name: str) -> XmlRegister:
        """The register <name> of the core section <section>; KeyError if there is none."""
        for reg in self.registers:
            if reg.section == section and reg.name == name:
                return reg
        raise KeyError(f"{self.source}: no register {name} in {section}")

    def value(self, section: str, name: str) -> int:
        """The value of a register (with a known defect: the value of Microchip's generator, see defect)."""
        return self.register(section, name).value

    def section(self, section: str) -> tuple[XmlRegister, ...]:
        """The registers of the core section <section> in the order of the file."""
        return tuple(reg for reg in self.registers if reg.section == section)

    @property
    def sections(self) -> tuple[str, ...]:
        """The core sections in the order of the file."""
        return tuple(dict.fromkeys(reg.section for reg in self.registers))

    @property
    def clocks(self) -> dict[str, int]:
        """The rates of mss_clocks/clocks in Hz by register name (a new dict on each call)."""
        return {reg.name: reg.value for reg in self.section("mss_clocks/clocks")
                if reg.value is not None and reg.name != "MSS_CLKS_VERSION"}
