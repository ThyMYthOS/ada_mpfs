# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @req GEN-018
"""The way masks of the L2: which ways each master may allocate into, as the MSS Configurator XML sets them.

The XML is the source: mss_memory_map/cache has one WAY_MASK_<MASTER> per master of the L2 (the DMA, the
AXI4 slave ports 0 to 3, and the data and instruction cache of the E51 and of each U54), which Microchip's
config_l2_cache() writes (mss_l2_cache.c @ 8d52d59); the generator does not choose them. They are applied in
both security profiles. A mask is checked against the split of the XML it comes with (derive/l2.py: cache
ways 0 to WAY_ENABLE - NUM_SCRATCH_PAD_WAYS, then the scratchpad ways); when that split has no cache way
(GEN-E072) the masks are not checked further.

The rules, each with its code:

  GEN-E073  a mask includes a scratchpad way (Microchip's rule, mss_l2_cache.c:151-165: a master that
            allocates into a scratchpad way evicts what the scratchpad holds)
  GEN-E085  a mask has no cache way
  GEN-E074  l2.cache_partitioning of system.yaml names a way that is not a cache way of the L2 the boot
            loader configures (l2.ways of system.yaml if it overrides the XML)

These are errors in both profiles. l2.cache_partitioning, where system.yaml gives it, is the policy that the
masks of the XML must implement; it is checked against them like the PMP against the partitions (an error
for prod, a note for dev):

  GEN-E146  the cache ways of the data or instruction cache of a hart in its mask are not the ways that
            l2.cache_partitioning gives the hart
  GEN-E147  two harts of different partitions share a cache way in their masks (data or instruction
            cache), while l2.cache_partitioning is given; the masters that serve every partition (the DMA,
            the AXI4 ports) are not compared
"""
from dataclasses import dataclass
from itertools import combinations

from ..checks import Diagnostic, diagnostic
from ..model import MssConfiguration, System
from .l2 import CACHE, L2

MASTERS = ("DMA", "AXI4_PORT_0", "AXI4_PORT_1", "AXI4_PORT_2", "AXI4_PORT_3", "E51_DCACHE", "E51_ICACHE",
           "U54_1_DCACHE", "U54_1_ICACHE", "U54_2_DCACHE", "U54_2_ICACHE", "U54_3_DCACHE", "U54_3_ICACHE",
           "U54_4_DCACHE", "U54_4_ICACHE")
# The key of a hart in l2.cache_partitioning and the prefix of its two masters.
HART_KEYS = ("e51", "u54_1", "u54_2", "u54_3", "u54_4")


def masters_of(hart: int) -> tuple[str, str]:
    """The data and instruction cache masters of <hart>."""
    prefix = HART_KEYS[hart].upper()
    return f"{prefix}_DCACHE", f"{prefix}_ICACHE"


@dataclass(frozen=True, slots=True)
class WayMasks:
    """The way masks of the XML by master, as the boot loader writes them, and l2.cache_partitioning of
    system.yaml (the cache ways per hart key) that they were checked against."""
    masks: tuple[tuple[str, int], ...]
    partitioning: tuple[tuple[str, tuple[int, ...]], ...]

    def mask(self, master: str) -> int:
        return dict(self.masks)[master]


def ways(mask: int) -> tuple[int, ...]:
    return tuple(way for way in range(mask.bit_length()) if mask >> way & 1)


def _bits(ways_: tuple[int, ...]) -> int:
    out = 0
    for way in ways_:
        out |= 1 << way
    return out


def derive(system: System, config: MssConfiguration, l2: L2, split_ok: bool
           ) -> tuple[WayMasks, list[Diagnostic], list[Diagnostic]]:
    """The way masks of the XML <config> checked with the L2 <l2> of <system>; <split_ok> is False when the
    split of the XML has no cache way (GEN-E072). Returns the masks, the rules broken that count in both
    profiles, and those of l2.cache_partitioning, which count by the security profile."""
    found: list[Diagnostic] = []
    policy: list[Diagnostic] = []
    masks = tuple((m, config.value(CACHE, "WAY_MASK_" + m)) for m in MASTERS)
    xml = l2.xml_ways
    cache = _bits(tuple(range(xml.cache)))
    scratch = _bits(tuple(range(xml.cache, xml.cache + xml.scratchpad)))
    if split_ok:
        for master, value in masks:
            if value & scratch:
                found.append(diagnostic("GEN-E073", f"{CACHE}/WAY_MASK_{master}",
                                        f"{value:#06x} includes scratchpad ways ({value & scratch:#06x})"))
            if not value & cache:
                found.append(diagnostic("GEN-E085", f"{CACHE}/WAY_MASK_{master}",
                                        f"{value:#06x} has none of the cache ways 0 to {xml.cache - 1}"))
    for hart, wanted in system.l2.cache_partitioning:
        foreign = [w for w in wanted if w not in l2.cache_ways]
        if foreign:
            found.append(diagnostic("GEN-E074", f"l2.cache_partitioning.{hart}",
                                    f"ways {foreign} are not cache ways (the cache has ways "
                                    f"0 to {l2.ways.cache - 1})"))
    result = WayMasks(masks, system.l2.cache_partitioning)
    if not split_ok or not system.l2.cache_partitioning:
        return result, found, policy
    for key, wanted in system.l2.cache_partitioning:
        for master in masters_of(HART_KEYS.index(key)):
            have = ways(result.mask(master) & cache)
            if have != wanted:
                policy.append(diagnostic("GEN-E146", f"{CACHE}/WAY_MASK_{master}",
                                         f"cache ways {list(have)}; l2.cache_partitioning.{key} gives "
                                         f"{list(wanted)}"))
    owner = {hart: part.name for part in system.partitions for hart in part.harts}
    for a, b in combinations(sorted(owner), 2):
        if owner[a] == owner[b]:
            continue
        first, second = (cache & (result.mask(masters_of(h)[0]) | result.mask(masters_of(h)[1])) for h in (a, b))
        shared = ways(first & second)
        if shared:
            policy.append(diagnostic("GEN-E147", "l2.cache_partitioning",
                                     f"hart {a} ({owner[a]!r}) and hart {b} ({owner[b]!r}) share the cache ways "
                                     f"{list(shared)} in the way masks of the XML"))
    return result, found, policy
