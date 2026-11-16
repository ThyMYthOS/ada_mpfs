# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""What the reader of system.yaml returns: immutable data classes with the defaults applied.

Sizes are bytes (int). Lists whose order means nothing (harts, peripherals, interrupts, the two ends of
a channel, the cache ways) are sorted tuples; the partitions, the channels and the boot sources keep the
order of the file. A value the description leaves to the XML is None.
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
