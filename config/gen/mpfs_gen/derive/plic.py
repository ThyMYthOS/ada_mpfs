# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @req GEN-009
"""The interrupts of each partition: the PLIC sources with their numbers, the contexts that enable them,
the hart-local interrupts; and the mapping from an Ada priority to a PLIC level.

  - A PLIC source is a name of the <interrupt> elements of the SVD (the names of Ada.Interrupts.Names);
    its number is the PLIC source number. A source belongs to one partition only, and it is enabled only
    in the contexts of the harts of that partition: the M context of each hart, hart 0 context 0 and hart
    n context 2n - 1 (System.BB.RISCV_PLIC.Context_Of, crates/mpfs_rts/README.md). The boot loader sets
    the priorities statically; the runtime sets only its own context.
  - local:<name> is a hart-local interrupt of svd/additions/local_interrupts.yaml; every hart of the
    partition must have it.
  - The level of a source is the level of the Ada priority of its handler (the ceiling of its protected
    object): Interrupt_Priority'First + n - 1 is level n (n = 1 .. 7), a task priority is level 0
    (RISCV_PLIC.Level_Of, crates/mpfs_rts/README.md, "Interrupt priorities"). system.yaml (schema 1)
    does not carry the priorities of the handlers, so the levels of the sources are not derived yet
    (None); level() is the mapping for the stage that has them.
"""
from dataclasses import dataclass
from pathlib import Path

from gen_ada import svdread, yamlio

from .. import ROOT, target
from ..checks import Diagnostic, diagnostic
from ..model import System

LOCAL_INTERRUPTS = ROOT / "svd" / "additions" / "local_interrupts.yaml"
LOCAL_PREFIX = "local:"

# The interrupt priorities of system.ads of the tasking profiles: 249 .. 255, seven levels.
INTERRUPT_PRIORITY_FIRST = 249
LEVELS = 7


def level(priority: int) -> int:
    """The PLIC level of the Ada priority <priority>: 0 for a task priority, 1 .. 7 for the interrupt
    priorities."""
    if priority < INTERRUPT_PRIORITY_FIRST:
        return 0
    return min(priority - INTERRUPT_PRIORITY_FIRST + 1, LEVELS)


def context(hart: int) -> int:
    """The M-mode PLIC context of <hart>."""
    return 0 if hart == target.E51_HART else 2 * hart - 1


@dataclass(frozen=True, slots=True)
class Source:
    """A PLIC source of a partition; <level> is None until the priorities of the handlers are known."""
    name: str
    number: int
    level: int | None = None


@dataclass(frozen=True, slots=True)
class PartitionInterrupts:
    sources: tuple[Source, ...]
    contexts: tuple[int, ...]
    local: tuple[tuple[str, int], ...]

    @property
    def enables(self) -> tuple[tuple[int, int], ...]:
        """(context, source number) for every source in every own context: what the boot loader enables."""
        return tuple((c, s.number) for c in self.contexts for s in self.sources)


def plic_sources(svd: Path) -> dict[str, int]:
    """The PLIC sources of the SVD by name."""
    return {i.name: int(i.value) for i in svdread.interrupts(svdread.load(svd)) if i.value.isdigit()}


def local_interrupts(path: Path = LOCAL_INTERRUPTS) -> dict[int, dict[str, int]]:
    """The local interrupts of each hart: hart -> name -> local number."""
    data = yamlio.load(path)
    harts: dict[str, int] = data["harts"]
    result: dict[int, dict[str, int]] = {h: {} for h in harts.values()}
    for item in data["interrupts"]:
        for hart in item["harts"]:
            result[harts[hart]][item["name"]] = item["local"]
    return result


def derive(system: System, svd: Path) -> tuple[dict[str, PartitionInterrupts], list[Diagnostic]]:
    """The interrupts of each partition by name, and the rules they break."""
    found: list[Diagnostic] = []
    sources = plic_sources(svd)
    local = local_interrupts()
    owner: dict[str, str] = {}
    result: dict[str, PartitionInterrupts] = {}
    for i, part in enumerate(system.partitions):
        at = f"partitions[{i}].interrupts"
        own: list[Source] = []
        own_local: list[tuple[str, int]] = []
        for name in part.interrupts:
            if name.startswith(LOCAL_PREFIX):
                bare = name.removeprefix(LOCAL_PREFIX)
                missing = [h for h in part.harts if bare not in local.get(h, {})]
                if missing:
                    found.append(diagnostic("GEN-E081", at, f"{name}: harts {missing} have no local interrupt {bare}"))
                else:
                    own_local.append((bare, local[part.harts[0]][bare]))
            elif name not in sources:
                found.append(diagnostic("GEN-E080", at, f"{name} is not a PLIC source of the SVD"))
            else:
                if name in owner:
                    found.append(diagnostic("GEN-E082", at, f"{name} of {part.name!r} is also handled by partition {owner[name]!r}"))
                owner.setdefault(name, part.name)
                own.append(Source(name, sources[name]))
        result[part.name] = PartitionInterrupts(tuple(sorted(own, key=lambda s: s.number)),
                                                tuple(context(h) for h in part.harts),
                                                tuple(sorted(own_local, key=lambda x: x[1])))
    return result, found
