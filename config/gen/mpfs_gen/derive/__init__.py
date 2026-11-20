# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @req GEN-006, GEN-007, GEN-008, GEN-009
"""The derivations: from a system description and the MSS Configurator XML of its board to the derived
system, the data that the emitters write out.

  derive(system, config, svd)  the Derived system, or DerivationError with every error (the warnings are in
                               Derived.warnings, the findings not enforced in dev in Derived.notes)
  xml_of(system, path)         the XML of a description: xml.file next to it, else the one of its board

  clocks     the clocks, recomputed from the MSS PLL and checked against the limits
  l2         the ways of cache, scratchpad and LIM
  placement  the windows of partitions and channels, and the checks of the system map
  plic       the PLIC sources and contexts of each partition
  periph     the release masks of each partition, RAM_SHUTDOWN_CR, the names of the direct GPIO lines
  contexts   the AMP contexts of the XML and the address of each peripheral of a partition (APBBUS_CR)
  protection the PMP of the XML (pmp.py) checked against the partitions and the contexts

Every step runs and reports its diagnostics; the steps that need a correct L2 (the placement) run on the
L2 as far as it could be derived. A diagnostic whose code checks.WARNINGS has is a warning: it is kept in
Derived.warnings and does not stop the derivation.

The security profile of system.yaml decides how the checks of the PMP and the AMP contexts count (the codes
of checks.PMP_CODES and checks.PROTECTION_CODES, the rules of the XML's own PMP sections included; the checks
of the MPU, still to come, will count the same way). A prod image must pass them: an error stops the
derivation. For a dev image they run for information, and every finding, error or warning, is a note in
Derived.notes, which stops nothing. A dev image does not set the PMP registers (Protection.applied is False,
so the emitters write no PMP entries for it). Everything else of the XML is applied in both profiles: the MPU
(a DMA master has no access until its MPU regions exist, MSS TRM DS60001702S §3.4), the way masks and the
L2 split, APBBUS_CR and the addresses of the peripherals, the clocks and the IO multiplexing.
"""
from dataclasses import dataclass
from pathlib import Path

from gen_ada import errors

from .. import pmp as pmp_
from .. import target, xml_reader
from ..checks import DerivationError, Diagnostic, diagnostic
from ..model import MssConfiguration, System
from ..yaml_reader import BOARDS
from . import clocks as clocks_
from . import contexts as contexts_
from . import l2 as l2_
from . import periph as periph_
from . import placement as placement_
from . import plic as plic_
from . import protection as protection_


@dataclass(frozen=True, slots=True)
class DerivedPartition:
    """What is derived for one partition. <cpu_to_hart> is CPU_To_Hart: CPU k (from 1) runs on the hart
    of the k-th set bit of <mask>. <context> is its AMP context (A, B, empty for none), <blocks> its
    peripherals and console at the address APBBUS_CR gives them."""
    name: str
    harts: tuple[int, ...]
    mask: int
    cpu_to_hart: tuple[int, ...]
    windows: tuple[placement_.PlacedWindow, ...]
    interrupts: plic_.PartitionInterrupts
    peripherals: periph_.PartitionPeripherals
    context: str = ""
    blocks: tuple[contexts_.Block, ...] = ()


@dataclass(frozen=True, slots=True)
class Derived:
    """The derived system: the description, the XML (its file and hash), and what is derived from them;
    <protection> the PMP and contexts checked, <warnings> the rules broken that do not stop the derivation,
    <notes> the findings of the PMP and the contexts that a dev image does not enforce."""
    system: System
    xml: str
    xml_sha256: str
    clocks: clocks_.Clocks
    l2: l2_.L2
    memories: tuple[placement_.MemoryRegion, ...]
    windows: tuple[placement_.PlacedWindow, ...]
    partitions: tuple[DerivedPartition, ...]
    ram_shutdown: int
    ram_shutdown_blocks: tuple[str, ...]
    gpio_aliases: tuple[tuple[str, str], ...]
    protection: protection_.Protection | None = None
    warnings: tuple[Diagnostic, ...] = ()
    notes: tuple[Diagnostic, ...] = ()

    def partition(self, name: str) -> DerivedPartition:
        for part in self.partitions:
            if part.name == name:
                return part
        raise KeyError(f"no partition {name}")


def cpu_to_hart(mask: int) -> tuple[int, ...]:
    """CPU_To_Hart of a mask: the position of its k-th set bit for k = 1, 2, ..."""
    return tuple(bit for bit in range(mask.bit_length()) if mask >> bit & 1)


def xml_of(system: System, path: Path) -> Path:
    """The XML of the description at <path>: xml.file relative to it, otherwise the one XML in the
    directory of its board."""
    if system.xml is not None:
        return path.parent / system.xml.file
    board = BOARDS / system.board
    found = sorted(board.glob("*.xml"))
    if len(found) != 1:
        raise errors.InputError(f"{board}: {len(found)} XML files, not one")
    return found[0]


def derive(system: System, config: MssConfiguration, svd: Path, where: str = "", *,
           pmp_entries: int = target.PMP_ENTRIES) -> Derived:
    """The derived system of <system> with the XML <config> and the merged SVD <svd>; <where> names the
    pair in the messages. The PMP of the XML and its contexts are checked against the partitions with
    <pmp_entries> entries per hart (16 on the silicon, 8 for QEMU): enforced for a prod image, notes for dev."""
    found: list[Diagnostic] = []
    if system.xml is not None and system.xml.sha256 != config.sha256:
        found.append(diagnostic("GEN-E060", "xml.sha256",
                                f"{config.source} has the SHA-256 {config.sha256}, not {system.xml.sha256}"))
    clocks, more = clocks_.derive(config)
    found += more
    l2, more = l2_.derive(system, config)
    found += more
    windows, more = placement_.place(system, l2)
    found += more
    mems = placement_.memories(l2)
    harts = {p.name: p.harts for p in system.partitions}
    found += placement_.check(windows, mems, harts)
    interrupts, more = plic_.derive(system, svd)
    found += more
    layout = xml_reader.svd_layout(svd)
    peripherals, more = periph_.derive(system, config, layout, plic_.plic_sources(svd))
    found += more
    blocks = xml_reader.svd_blocks(svd)
    harts_pmp, guarded = pmp_.of(config)
    guarded += pmp_.rules(config, harts_pmp, pmp_entries)
    contexts, placed, more = contexts_.derive(system, config, layout, blocks)
    guarded += more
    applied = system.security_profile == "prod"
    checked, more = protection_.check(system, windows, mems, harts_pmp, contexts, placed, blocks, pmp_entries,
                                      applied)
    guarded += more
    notes: tuple[Diagnostic, ...] = ()
    if applied:
        found += guarded
    else:
        notes = tuple(guarded)
    errors_ = [d for d in found if not d.warning]
    warnings = tuple(d for d in found if d.warning)
    if errors_:
        raise DerivationError(where or f"{config.source}", errors_ + list(warnings))
    per = dict(peripherals.partitions)
    parts = tuple(DerivedPartition(p.name, p.harts, p.mask, cpu_to_hart(p.mask),
                                   tuple(w for w in windows if p.name in w.owners),
                                   interrupts[p.name], per[p.name], c.context, c.blocks)
                  for p, c in zip(system.partitions, placed))
    return Derived(system, config.source, config.sha256, clocks, l2, mems, windows, parts,
                   peripherals.ram_shutdown, peripherals.ram_shutdown_blocks, peripherals.gpio_aliases,
                   checked, warnings, notes)
