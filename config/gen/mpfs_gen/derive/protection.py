# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @req GEN-011, GEN-013
"""The PMP of the XML, with the allow list of each U partition, checked against the partitions of system.yaml.

The locked entries are the user's, set in the MSS Configurator; the generator does not make or repair one.
The Configurator writes three PMP tables only: one for the E51 and one per AMP context, which every U54 hart
of the context gets. The XML can therefore hold the barrier of locked entries of a context, not what
separates two partitions of the same context. That is the allow list of each hart of a U partition, a set of
unlocked entries that the kernel of the partition sets in M mode (MSS TRM DS60001702S §3.1.4: unlocked
entries bind U mode only), which the generator derives from system.yaml and the placement:

  allowed    for each hart of a U partition: its windows with the rights they need (NEEDS: code+data RWX,
             code and fast_text RX, data and channels RW; fast_text only in the ITIM of the hart itself),
             its peripherals and console RW at the address APBBUS_CR gives, the page of mtime R; ranges
             that touch and have the same rights are one range;
  entries    from the lowest index after the last entry the XML uses for the hart on, in address order:
             a range that is a power of two at a multiple of itself is one NAPOT entry; otherwise it takes
             the fewest NAPOT entries if that is not more than TOR needs, else a TOR entry (with an OFF
             entry for its base unless the entry before it is a TOR entry that ends there);
  kept       a hart whose table in the XML has unlocked entries in use already gets none: the XML's own
             allow list (written in the Configurator's Expert Mode) is the one checked.

They are generated in both profiles (for a dev image they are not applied, like the whole PMP). The rules
below evaluate each hart with the entries of the XML and the generated ones together (pmp.regions, the
rules of the Privileged Spec v1.10) and compare what U mode, and M mode where the hart has locked entries,
can reach with what the partition owns:

  own        its windows (code+data RWX, code and fast_text RX, data and channels RW; fast_text only in the
             ITIM of the hart itself), its peripherals and console RW at the address APBBUS_CR gives
             (contexts.block_of), and the page of mtime R (CLINT and MTIME of the SVD);
  foreign    the windows of other partitions and of channels it is not an end of, the DTIM and the ITIMs of
             the harts it does not have, the peripherals of other partitions; an ITIM of another hart only
             if a partition places a window in it (fast_text): an ITIM that no partition uses holds no code
             or data of any partition, and locking each of them out would take an entry per ITIM of the
             budget of the locked tables (the MSS Configurator gives the U54 harts of a context one table);
  critical   the blocks of the SVD whose registers configure or watch the whole system: SYSREG, MPUCFG
             (with the SEG registers at 0x2000_5D00, mss_seg.h:54), SCB_REGS, the AXI switch,
             CFG_DDR_SGMII_PHY, the eNVM controller (unless the partition owns envm), the L2 cache
             controller (L2_CACHE), the PDMA, the system controller (PFSOC_CONTROL_SCB) and its mailbox
             (SCB_MAILBOX), the IOSCB configuration (IOSCBCFG) and the IOSCB blocks of the MSS (IOSCB_*),
             and the bus error units of the harts it does not have (BEU, one per hart, 0x1000 apart); each
             in the whole pages its registers touch;
  other bus  for a partition in an AMP context, the addresses of the peripherals of both APB buses on the bus
             of the other context (HI for A, LO for B).

The rules, each with its code (W: a warning, which does not stop the derivation):

  GEN-E120     a U partition cannot reach a window of its own with the rights it needs
  GEN-E121     a U partition cannot read and write a peripheral of its own at its address
  GEN-E122     a U partition cannot read the page of mtime
  GEN-E123 W   U mode of a U partition reaches something that is not its own (and none of the below)
  GEN-E124     something foreign is reachable from U mode of a U partition, or from M mode of a hart with
               locked entries
  GEN-E125     a critical block is reachable from U mode of a U partition
  GEN-E126     SYSREG or MPUCFG is reachable from U mode of a U partition: that exposes APBBUS_CR, the clocks
               and resets of all peripherals (SUBBLK_CLOCK_CR, SOFT_RESET_CR) and the MPU of every master
  GEN-E127 W   a critical block is reachable from M mode of a hart with locked entries (the kernel there may
               need some; which is not described yet)
  GEN-E128 W   M mode of a hart with locked entries reaches something of a partition of the same AMP context
               (the weakness this design accepts: the allow list separates the partitions of one context in
               U mode, and the table of the context, the same for all its harts, cannot lock one of them
               out for the others; across contexts and for a hart in no context it stays GEN-E124)
  GEN-E129     the allow list of a hart does not fit the entries of the target after the entries of the XML
  GEN-E135 W   a PMP window of a partition in one context covers the bus window of the other context

GEN-E135 is a warning for now: on the Icicle Kit an access to a peripheral at the address of the bus it is
not on had no effect and raised no fault (docs/lab/results/pmp-entries.md); where the PSLVERR of such an
access goes is still being measured. M mode of a hart without locked entries reaches everything (no entry
binds it); the deny list of locked entries is what binds it.
"""
from dataclasses import dataclass

from gen_ada import svdread

from .. import pmp as pmp_
from .. import target
from ..checks import Diagnostic, diagnostic
from ..model import System
from . import contexts as contexts_
from .contexts import Block
from .placement import MemoryRegion, PlacedWindow, itim_name

NEEDS = {"code+data": "rwx", "code": "r-x", "fast_text": "r-x", "data": "rw-", "ipc": "rw-"}
GRANTS = ("SYSREG", "MPUCFG")
# The critical blocks of the SVD: the name in the messages, the peripheral of the SVD; the IOSCB blocks of
# the SVD (IOSCB_*) and a bus error unit per hart (BEU) come on top.
CRITICAL_SVD = (("SYSREG", "SYSREG"), ("MPUCFG", "MPUCFG"), ("SCB", "SCB_REGS"),
                ("AXI switch", "AXISWITCH15X9_DW_AXI"), ("CFG_DDR_SGMII_PHY", "CFG_DDR_SGMII_PHY"),
                ("eNVM controller", "ENVM"), ("L2 controller", "L2_CACHE"), ("PDMA", "PDMA"),
                ("system controller", "PFSOC_CONTROL_SCB"), ("system controller mailbox", "SCB_MAILBOX"),
                ("IOSCB configuration", "IOSCBCFG"))
IOSCB_PREFIX = "IOSCB_"
BEU = "BEU"
MAX_RANGES = 4
# What a reached piece of a zone kind is in a mode (no code: allowed).
_CODES = {("foreign", "u"): "GEN-E124", ("foreign", "m"): "GEN-E124", ("peer", "u"): "GEN-E124",
          ("peer", "m"): "GEN-E128", ("grant", "u"): "GEN-E126",
          ("critical", "u"): "GEN-E125", ("grant", "m"): "GEN-E127", ("critical", "m"): "GEN-E127",
          ("bus", "u"): "GEN-E135", ("bus", "m"): "GEN-E135", ("other", "u"): "GEN-E123"}


@dataclass(frozen=True, slots=True)
class HartProtection:
    """The PMP of a hart as checked, the entries of the XML and the generated allow list together: <bits> of
    pmpaddr implemented, the entries in use, the locked part (from the XML, for the boot table), the unlocked
    part (for MPFS_Partition: the generated entries, or the unlocked entries of the XML), the generated
    entries among them (also those beyond the 16 of the hart, which GEN-E129 refuses), and the regions with
    the rights of U and M mode."""
    hart: int
    bits: int
    used: int
    locked: tuple[pmp_.Entry, ...]
    unlocked: tuple[pmp_.Entry, ...]
    regions: tuple[pmp_.Region, ...]
    generated: tuple[pmp_.Entry, ...] = ()


@dataclass(frozen=True, slots=True)
class Protection:
    """The PMP of every hart and the AMP contexts of the XML, checked with <entries> entries per hart;
    <critical> are the critical blocks the checks protect, <mtime> the page of mtime. <applied> is False for
    a dev image: it does not set the PMP registers, and no PMP entry is to be emitted for it (the MPU is
    applied in both profiles)."""
    entries: int
    harts: tuple[HartProtection, ...]
    contexts: contexts_.Contexts
    critical: tuple[Block, ...]
    mtime: Block
    applied: bool = True

    def hart(self, hart: int) -> HartProtection:
        return self.harts[hart]


def _paged(name: str, svd: str, base: int, span: int) -> Block:
    """The block <svd> at <base> with <span> bytes of registers in the whole pages they touch."""
    first = base - base % target.PAGE
    return Block(name, svd, first, contexts_.pages(base + max(span, 1) - first), "")


def beu_name(hart: int) -> str:
    return f"bus error unit of hart {hart}"


def critical_blocks(blocks: dict[str, svdread.Block]) -> tuple[Block, ...]:
    """The critical blocks at their addresses, in address order: those of CRITICAL_SVD, the IOSCB blocks and
    the bus error unit of each hart (the element of the array of the BEU for that hart)."""
    found = [_paged(name, svd, blocks[svd].base, blocks[svd].span) for name, svd in CRITICAL_SVD]
    found += [_paged(svd, svd, b.base, b.span) for svd, b in blocks.items() if svd.startswith(IOSCB_PREFIX)]
    beu = blocks[BEU]
    step = min(beu.steps.values())
    found += [_paged(beu_name(h), BEU, beu.base + h * step, step) for h in range(target.NUMBER_OF_HARTS)]
    return tuple(sorted(found, key=lambda b: b.base))


def mtime_page(blocks: dict[str, svdread.Block]) -> Block:
    clint = blocks["CLINT"]
    address = clint.base + clint.offsets["MTIME"]
    return Block("mtime", "CLINT", address - address % target.PAGE, target.PAGE, "")


@dataclass(frozen=True, slots=True)
class _Zone:
    first: int
    last: int
    kind: str       # own, foreign, peer (foreign, of the same context), grant, critical, bus
    label: str


def _foreign(mine: str, *theirs: str) -> str:
    """The kind of a foreign zone for a partition of context <mine> (empty: none) whose owners are in the
    contexts <theirs>: peer if one of them is in the same context, else foreign."""
    return "peer" if mine and mine in theirs else "foreign"


def allowed(part_name: str, hart: int, windows: tuple[PlacedWindow, ...], blocks: tuple[Block, ...],
            mtime: Block) -> list[tuple[int, int, str]]:
    """The ranges [first, end) with their rights that U mode of <hart> of the partition <part_name> needs: its
    <windows>, its peripheral <blocks>, the page of mtime; touching ranges of the same rights merged, in
    address order."""
    ranges = [(w.origin, w.end, NEEDS[w.kind]) for w in windows if part_name in w.owners
              and (w.kind != "fast_text" or w.memory == itim_name(hart))]
    ranges += [(b.base, b.base + b.length, "rw-") for b in blocks]
    ranges.append((mtime.base, mtime.base + mtime.length, "r--"))
    merged: list[tuple[int, int, str]] = []
    for first, end, rights in sorted(ranges):
        if merged and merged[-1][1] == first and merged[-1][2] == rights:
            merged[-1] = (merged[-1][0], end, rights)
        else:
            merged.append((first, end, rights))
    return merged


def generate(pmp: pmp_.HartPmp, ranges: list[tuple[int, int, str]]) -> tuple[pmp_.Entry, ...]:
    """The allow list <ranges> of a hart as unlocked entries after the entries its table <pmp> of the XML
    uses; none if that table has unlocked entries in use (the module text)."""
    if pmp_.unlocked_part(pmp):
        return ()
    used = pmp_.in_use(pmp)
    return pmp_.cover(ranges, used[-1] + 1 if used else 0, pmp)


def _has(rights: str, needed: str) -> bool:
    return all(n == "-" or n in rights for n in needed)


def _ranges(pieces: list[tuple[int, int]]) -> str:
    merged: list[tuple[int, int]] = []
    for first, last in sorted(pieces):
        if merged and merged[-1][1] + 1 >= first:
            merged[-1] = (merged[-1][0], max(merged[-1][1], last))
        else:
            merged.append((first, last))
    text = ", ".join(f"[{a:#x}, {b:#x}]" for a, b in merged[:MAX_RANGES])
    return text + (f" and {len(merged) - MAX_RANGES} more" if len(merged) > MAX_RANGES else "")


def _classify(reached: list[tuple[int, int, str]], zones: list[_Zone]) -> dict[tuple[str, str], list[tuple[int, int]]]:
    """The reached pieces cut by the zones: (kind, label) -> the pieces in it; the first zone in the list
    that holds a piece names it, a piece in no zone is ("other", "")."""
    cuts = sorted({b for f, l, _ in reached for b in (f, l + 1)} | {b for z in zones for b in (z.first, z.last + 1)})
    out: dict[tuple[str, str], list[tuple[int, int]]] = {}
    for first, last, _ in reached:
        points = [c for c in cuts if first < c <= last] + [last + 1]
        start = first
        for end in points:
            zone = next((z for z in zones if z.first <= start <= z.last), None)
            key = (zone.kind, zone.label) if zone else ("other", "")
            out.setdefault(key, []).append((start, end - 1))
            start = end
    return out


def check(system: System, windows: tuple[PlacedWindow, ...], memories: tuple[MemoryRegion, ...],
          harts: tuple[pmp_.HartPmp, ...], contexts: contexts_.Contexts,
          parts: tuple[contexts_.PartitionContext, ...], blocks: dict[str, svdread.Block],
          entries: int, applied: bool = True) -> tuple[Protection, list[Diagnostic]]:
    """The PMP <harts> of the XML checked against the partitions of <system> with their <windows> in the
    <memories>, the contexts and the peripheral blocks <parts> of each partition (in its order); <entries>
    is the number of entries of the target."""
    found: list[Diagnostic] = []
    critical = critical_blocks(blocks)
    mtime = mtime_page(blocks)
    generated: dict[int, tuple[pmp_.Entry, ...]] = {}
    for i, (part, placed) in enumerate(zip(system.partitions, parts)):
        if part.priv != "u":
            continue
        for hart in part.harts:
            made = generate(harts[hart], allowed(part.name, hart, windows, placed.blocks, mtime))
            generated[hart] = made
            if made and made[-1].index >= entries:
                found.append(diagnostic("GEN-E129", f"partitions[{i}]",
                                        f"hart {hart} of {part.name!r} needs {len(made)} unlocked entries after "
                                        f"the {made[0].index} of the XML (to index {made[-1].index}); the target "
                                        f"has {entries} (0 to {entries - 1})"))
    combined = [pmp_.with_entries(p, generated.get(p.hart, ())) for p in harts]
    checked = tuple(HartProtection(p.hart, target.PMPADDR_BITS[p.hart],
                                   len(pmp_.in_use(p)),
                                   pmp_.locked_part(p), pmp_.unlocked_part(p),
                                   pmp_.regions(p, target.PMPADDR_BITS[p.hart]),
                                   generated.get(p.hart, ())) for p in combined)
    owned_blocks = {part.name: placed.blocks for part, placed in zip(system.partitions, parts)}
    used_itims = {w.memory for w in windows}
    context_of = {part.name: placed.context for part, placed in zip(system.partitions, parts)}

    for i, (part, placed) in enumerate(zip(system.partitions, parts)):
        at = f"partitions[{i}]"
        own_windows = [w for w in windows if part.name in w.owners]
        mine_ = placed.context
        foreign: list[_Zone] = [_Zone(w.origin, w.end - 1, _foreign(mine_, *(context_of[o] for o in w.owners)),
                                      f"channel {w.channel!r}" if w.channel else f"{w.kind} of {w.owners[0]!r}")
                                for w in windows if part.name not in w.owners]
        foreign += [_Zone(m.origin, m.end - 1, _foreign(mine_, contexts.of_hart(m.hart)), f"{m.name} of hart {m.hart}")
                    for m in memories if m.hart is not None and m.hart not in part.harts
                    and (m.name != itim_name(m.hart) or m.name in used_itims)]
        foreign += [_Zone(b.base, b.last, _foreign(mine_, context_of[other]), f"{b.name} of partition {other!r}")
                    for other, bs in owned_blocks.items() if other != part.name for b in bs]
        mine = {b.name for b in placed.blocks}
        own_beus = {beu_name(h) for h in part.harts}
        crit = [_Zone(b.base, b.last, "grant" if b.name in GRANTS else "critical", b.name) for b in critical
                if not (b.block == "ENVM" and "envm" in mine) and b.name not in own_beus]
        other_bus = {"A": "HI", "B": "LO"}.get(placed.context)
        bus = [_Zone(b.base, b.last, "bus", f"the {other_bus} window of context {'B' if placed.context == 'A' else 'A'}")
               for b in (contexts_.bus_blocks(blocks, other_bus) if other_bus else ())]
        own = [_Zone(w.origin, w.end - 1, "own", "") for w in own_windows]
        own += [_Zone(b.base, b.last, "own", "") for b in placed.blocks]
        own.append(_Zone(mtime.base, mtime.last, "own", ""))
        zones = own + foreign + crit + bus

        for hart in part.harts:
            hp = checked[hart]
            modes = (["u"] if part.priv == "u" else []) + (["m"] if hp.locked else [])
            if part.priv == "u":
                for w in own_windows:
                    if w.kind == "fast_text" and w.memory != itim_name(hart):
                        continue
                    lacking = [(f, l) for f, l, r in pmp_.rights(hp.regions, w.origin, w.end - 1, "u")
                               if not _has(r, NEEDS[w.kind])]
                    if lacking:
                        found.append(diagnostic("GEN-E120", f"{at}.memory",
                                                f"hart {hart} of {part.name!r} lacks {NEEDS[w.kind]} in U mode on "
                                                f"its {w.kind} window {w.memory} {_ranges(lacking)}"))
                for b in placed.blocks:
                    lacking = [(f, l) for f, l, r in pmp_.rights(hp.regions, b.base, b.last, "u") if not _has(r, "rw-")]
                    if lacking:
                        where = f"{b.bus} " if b.bus else ""
                        found.append(diagnostic("GEN-E121", f"{at}.peripherals",
                                                f"hart {hart} of {part.name!r} cannot read and write {b.name} in U "
                                                f"mode at its {where}address {_ranges(lacking)}"))
                lacking = [(f, l) for f, l, r in pmp_.rights(hp.regions, mtime.base, mtime.last, "u") if "r" not in r]
                if lacking:
                    found.append(diagnostic("GEN-E122", at, f"hart {hart} of {part.name!r} cannot read the page of "
                                            f"mtime {_ranges(lacking)} in U mode"))
            for mode in modes:
                reached = [(r.first, r.last, r.u if mode == "u" else r.m) for r in hp.regions
                           if (r.u if mode == "u" else r.m) != pmp_.NONE]
                classes = _classify(reached, zones)
                who = f"{'U' if mode == 'u' else 'M'} mode of hart {hart} ({part.name!r}) reaches"
                by_code: dict[str, list[tuple[int, str]]] = {}
                for (kind, label), pieces in classes.items():
                    code = _CODES.get((kind, mode))
                    if code:
                        named = f"{label or 'what is not its own'} {_ranges(pieces)}"
                        by_code.setdefault(code, []).append((min(pieces)[0], named))
                for code, items in sorted(by_code.items()):
                    text = f"{who} {'; '.join(named for _, named in sorted(items))}"
                    if code == "GEN-E126":
                        text += ", which exposes APBBUS_CR, the clocks and resets of all peripherals and the MPUs"
                    found.append(diagnostic(code, at, text))
    return Protection(entries, checked, contexts, critical, mtime, applied), found
