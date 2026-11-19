# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @req GEN-007
"""The L2: how its 16 ways are shared out between cache, scratchpad and LIM.

The 16 ways are the same in every PolarFire SoC; how they are shared out is a setting of the MSS
Configurator XML (not of the board), the source of the split unless system.yaml overrides it.

The XML gives WAY_ENABLE (the highest way that is enabled, cache or scratchpad) and NUM_SCRATCH_PAD_WAYS.
Microchip's code (mss_l2_cache.c @ 8d52d59) makes of them:

  cache ways       0 .. WAY_ENABLE - NUM_SCRATCH_PAD_WAYS          (:51, num_cache_ways)
  scratchpad ways  the upper NUM_SCRATCH_PAD_WAYS of the enabled ways (:139-143, :193; not as the
                   comment of mss_l2_cache.h describes it)
  LIM ways         WAY_ENABLE + 1 .. 15, 15 - WAY_ENABLE ways        (:110)

with WAY_ENABLE below 16 (:104) and at least one cache way (:48, :128), and no way mask that includes a
scratchpad way (:151-165). So cache + scratchpad + LIM = 16, cache >= 1, LIM <= 15. l2.ways of
system.yaml overrides the XML (with l2.reason, GEN-E013; its sum is GEN-E031) and is laid out the same
way. The ways of l2.cache_partitioning must be cache ways of the result.
"""
from dataclasses import dataclass

from .. import target
from ..checks import Diagnostic, diagnostic
from ..model import L2Ways, MssConfiguration, System

CACHE = "mss_memory_map/cache"
MASTERS = ("DMA", "AXI4_PORT_0", "AXI4_PORT_1", "AXI4_PORT_2", "AXI4_PORT_3", "E51_DCACHE", "E51_ICACHE",
           "U54_1_DCACHE", "U54_1_ICACHE", "U54_2_DCACHE", "U54_2_ICACHE", "U54_3_DCACHE", "U54_3_ICACHE",
           "U54_4_DCACHE", "U54_4_ICACHE")


@dataclass(frozen=True, slots=True)
class L2:
    """The L2 of the system. <ways> is what the boot loader configures: the override of system.yaml if it
    has one (<override>, with <reason>), otherwise the XML's (<xml_ways>). <way_masks> are the masks of
    the XML by master; <partitioning> the cache ways per hart of system.yaml."""
    xml_ways: L2Ways
    ways: L2Ways
    override: bool
    reason: str | None
    way_masks: tuple[tuple[str, int], ...]
    partitioning: tuple[tuple[str, tuple[int, ...]], ...]

    @property
    def way_enable(self) -> int:
        """The value of WAY_ENABLE for <ways>: the highest enabled (cache or scratchpad) way."""
        return self.ways.cache + self.ways.scratchpad - 1

    @property
    def cache_ways(self) -> tuple[int, ...]:
        return tuple(range(self.ways.cache))

    @property
    def scratchpad_ways(self) -> tuple[int, ...]:
        return tuple(range(self.ways.cache, self.ways.cache + self.ways.scratchpad))

    @property
    def lim_ways(self) -> tuple[int, ...]:
        return tuple(range(self.ways.cache + self.ways.scratchpad, target.WAYS))

    @property
    def lim_length(self) -> int:
        return self.ways.lim * target.WAY_SIZE

    @property
    def scratchpad_length(self) -> int:
        return self.ways.scratchpad * target.WAY_SIZE


def mask(ways: tuple[int, ...]) -> int:
    return sum(1 << way for way in ways)


def derive(system: System, config: MssConfiguration) -> tuple[L2, list[Diagnostic]]:
    """The L2 of <system> with the XML <config>, and the rules it breaks."""
    found: list[Diagnostic] = []
    way_enable = config.value(CACHE, "WAY_ENABLE")
    scratch = config.value(CACHE, "NUM_SCRATCH_PAD_WAYS")
    if way_enable >= target.WAYS or scratch > way_enable:
        found.append(diagnostic("GEN-E072", f"{CACHE}/WAY_ENABLE",
                                f"WAY_ENABLE {way_enable} and NUM_SCRATCH_PAD_WAYS {scratch} leave "
                                f"{way_enable + 1 - scratch} cache ways of {target.WAYS}"))
        xml_ways = L2Ways(1, target.MAX_LIM_WAYS, 0)
    else:
        xml_ways = L2Ways(way_enable + 1 - scratch, target.WAYS - 1 - way_enable, scratch)
    masks = tuple((m, config.value(CACHE, "WAY_MASK_" + m)) for m in MASTERS)
    xml_scratch = mask(tuple(range(xml_ways.cache, xml_ways.cache + xml_ways.scratchpad)))
    for master, value in masks:
        if value & xml_scratch:
            found.append(diagnostic("GEN-E073", f"{CACHE}/WAY_MASK_{master}",
                                    f"{value:#06x} includes scratchpad ways ({value & xml_scratch:#06x})"))
    l2 = L2(xml_ways=xml_ways, ways=system.l2.ways or xml_ways,
            override=system.l2.ways is not None and system.l2.ways != xml_ways, reason=system.l2.reason,
            way_masks=masks, partitioning=system.l2.cache_partitioning)
    for hart, ways in l2.partitioning:
        foreign = [w for w in ways if w not in l2.cache_ways]
        if foreign:
            found.append(diagnostic("GEN-E074", f"l2.cache_partitioning.{hart}",
                                    f"ways {foreign} are not cache ways (the cache has ways "
                                    f"0 to {l2.ways.cache - 1})"))
    return l2, found
