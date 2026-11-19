# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @req GEN-008
"""The placement of the windows of the partitions and channels in the memories, and the checks of the
system map that the placement gives.

  memories(l2)          the memories that windows lie in, with origin and length (the L2 ones by l2)
  place(system, l2)     the windows and the rules that the placement breaks
  check(windows, ...)   the rules of a system map, whoever placed its windows

The rules of the placement:

  - A partition has one window for its code and data where both are in the same memory, otherwise one
    window each; fast_text is a window in the ITIM of each of its harts. A size of none takes what the
    other windows leave of the memory (only a system of one partition has one, GEN-E032).
  - A channel lies in the memory of the data of both its partitions, in the LIM where they differ.
  - In each memory the partitions and channels form a graph. If every component of it is a chain, each
    chain becomes one block, A | IPC_AB | B | IPC_BC | C, starting at the end whose partition comes first
    in system.yaml. Otherwise all channels of the memory form one shared block, and the partitions are
    blocks of their own (the rights on the shared block are given per partition by a PMP entry).
  - The blocks are placed first-fit-decreasing: the largest first, equal sizes in the order of their
    first partition in system.yaml, each at the lowest free address. A block whose first window has a
    power-of-two size starts at a multiple of that size (so that the window is a NAPOT region) where it
    fits so; any other block, and one that does not fit so, starts at a multiple of 4 (TOR).
  - A window is NAPOT if its length is a power of two of at least 8 and its origin a multiple of its
    length, otherwise TOR.

The checks of the map (also on windows placed by hand, as the tests do): every window inside its memory,
no two windows of different owners overlapping (the message names both), no window in the ITIM or DTIM
of a hart that none of its partitions has.
"""
from collections.abc import Iterable, Sequence
from dataclasses import dataclass

from .. import target
from ..checks import Diagnostic, diagnostic
from ..model import Partition, System
from .l2 import L2

GRANULE = 4      # a TOR entry addresses 4-byte units (pmpaddr holds address bits 55:2)
NAPOT_MIN = 8    # the smallest NAPOT region


@dataclass(frozen=True, slots=True)
class MemoryRegion:
    """A memory that windows lie in. <hart> is the hart whose local memory (ITIM, DTIM) it is."""
    name: str
    origin: int
    length: int
    hart: int | None = None

    @property
    def end(self) -> int:
        return self.origin + self.length


@dataclass(frozen=True, slots=True)
class PlacedWindow:
    """A window of the system map. <kind> is code+data, code, data, fast_text or ipc; <owners> are the
    partitions that own it (two for a channel, whose name is <channel>)."""
    kind: str
    memory: str
    origin: int
    length: int
    owners: tuple[str, ...]
    channel: str | None = None

    @property
    def end(self) -> int:
        return self.origin + self.length

    @property
    def mode(self) -> str:
        """NAPOT or TOR: how one PMP entry covers the window."""
        napot = (self.length >= NAPOT_MIN and self.length & (self.length - 1) == 0
                 and self.origin % self.length == 0)
        return "NAPOT" if napot else "TOR"

    def describe(self) -> str:
        who = (f"channel {self.channel!r} ({', '.join(self.owners)})" if self.channel
               else f"partition {self.owners[0]!r}")
        return f"{who} {self.kind} {self.memory} [{self.origin:#010x}, {self.end:#010x})"


def itim_name(hart: int) -> str:
    return "e51_itim" if hart == target.E51_HART else f"u54_{hart}_itim"


def memories(l2: L2) -> tuple[MemoryRegion, ...]:
    """The memories of the system with the L2 <l2> (the names of crates/mpfs_rts/ld/mpfs-memory.ld)."""
    return (MemoryRegion("envm", target.ENVM_ORIGIN, target.ENVM_LENGTH),
            MemoryRegion("lim", target.LIM_ORIGIN, l2.lim_length),
            MemoryRegion("scratchpad", target.SCRATCHPAD_ORIGIN, l2.scratchpad_length),
            MemoryRegion("dtim", target.DTIM_ORIGIN, target.DTIM_MAX, target.E51_HART),
            *(MemoryRegion(itim_name(h), target.ITIM_ORIGIN + h * target.ITIM_WINDOW, target.ITIM_MAX[h], h)
              for h in range(target.NUMBER_OF_HARTS)))


@dataclass(frozen=True, slots=True)
class _Piece:
    kind: str
    owners: tuple[str, ...]
    size: int | None
    channel: str | None = None


def _pieces(part: Partition) -> list[tuple[str, _Piece]]:
    """The (memory, piece) of the code and data of a partition."""
    code, data = part.memory.code, part.memory.data
    if code.region == data.region:
        size = None if code.size is None or data.size is None else code.size + data.size
        return [(code.region, _Piece("code+data", (part.name,), size))]
    return [(code.region, _Piece("code", (part.name,), code.size)),
            (data.region, _Piece("data", (part.name,), data.size))]


def _chains(nodes: list[int], edges: list[tuple[int, int, int]]) -> list[list[int]] | None:
    """The chains of the graph (nodes by index, edges (a, b, channel index)) as alternating lists
    node, channel, node, ...; None if a component is not a chain (a node of degree 3, a cycle)."""
    adjacent: dict[int, list[tuple[int, int]]] = {n: [] for n in nodes}
    for a, b, c in edges:
        adjacent[a].append((b, c))
        adjacent[b].append((a, c))
    if any(len(v) > 2 for v in adjacent.values()):
        return None
    seen: set[int] = set()
    chains: list[list[int]] = []
    for start in sorted(nodes):
        if start in seen or len(adjacent[start]) != 1:
            continue
        chain, node, came = [start], start, -1
        seen.add(start)
        while True:
            onward = [(n, c) for n, c in adjacent[node] if c != came]
            if not onward:
                break
            node, came = onward[0]
            chain += [came, node]
            seen.add(node)
        chains.append(chain)
    if any(adjacent[n] and n not in seen for n in nodes):    # a cycle: no end to start from
        return None
    return chains


def _alignment(size: int) -> int:
    """The alignment that makes a window of <size> a NAPOT region, GRANULE if no alignment does."""
    return size if size >= NAPOT_MIN and size & (size - 1) == 0 else GRANULE


def _first_fit(free: list[tuple[int, int]], size: int, align: int) -> int | None:
    for start, end in free:
        at = -(-start // align) * align
        if at + size <= end:
            return at
    return None


def _take(free: list[tuple[int, int]], at: int, size: int) -> list[tuple[int, int]]:
    out: list[tuple[int, int]] = []
    for start, end in free:
        if start <= at < end:
            if start < at:
                out.append((start, at))
            if at + size < end:
                out.append((at + size, end))
        else:
            out.append((start, end))
    return out


def place(system: System, l2: L2) -> tuple[tuple[PlacedWindow, ...], list[Diagnostic]]:
    """The windows of <system> in the memories of <l2>, and the rules the placement breaks."""
    found: list[Diagnostic] = []
    mems = {m.name: m for m in memories(l2)}
    index = {p.name: i for i, p in enumerate(system.partitions)}
    by_memory: dict[str, list[tuple[int, _Piece]]] = {}   # memory -> (priority, piece)
    data_memory: dict[str, str] = {}
    windows: list[PlacedWindow] = []

    def sized(path: str, size: int | None) -> None:
        if size is not None and size % GRANULE:
            found.append(diagnostic("GEN-E075", path, f"{size} is not a multiple of {GRANULE}"))

    for i, part in enumerate(system.partitions):
        for kind in ("code", "data"):
            sized(f"partitions[{i}].memory.{kind}.size", getattr(part.memory, kind).size)
        for memory, piece in _pieces(part):
            by_memory.setdefault(memory, []).append((i, piece))
        data_memory[part.name] = part.memory.data.region
        fast = part.memory.fast_text
        if fast is not None and fast.size:
            sized(f"partitions[{i}].memory.fast_text.size", fast.size)
            for hart in part.harts:
                mem = mems[itim_name(hart)]
                windows.append(PlacedWindow("fast_text", mem.name, mem.origin, fast.size, (part.name,)))

    for c, channel in enumerate(system.ipc):
        sized(f"ipc[{c}].size", channel.size)
        a, b = channel.between
        memory = data_memory[a] if data_memory[a] == data_memory[b] else "lim"
        by_memory.setdefault(memory, []).append(
            (min(index[a], index[b]), _Piece("ipc", channel.between, channel.size, channel.name)))

    for memory in sorted(by_memory, key=lambda m: list(mems).index(m)):
        windows += _place_in(mems[memory], by_memory[memory], index, found)
    return tuple(windows), found


def _place_in(mem: MemoryRegion, pieces: list[tuple[int, _Piece]], index: dict[str, int],
              found: list[Diagnostic]) -> list[PlacedWindow]:
    """Place the pieces of one memory; the blocks of chains and of the shared IPC block first."""
    fixed = sum(p.size for _, p in pieces if p.size is not None)
    rest = max(mem.length - fixed, 0)
    pieces = [(prio, p if p.size is not None else _Piece(p.kind, p.owners, rest - rest % GRANULE, p.channel))
              for prio, p in pieces]
    total = sum(p.size or 0 for _, p in pieces)
    if total > mem.length:
        names = sorted({o for _, p in pieces for o in p.owners}, key=lambda n: index[n])
        found.append(diagnostic("GEN-E076", f"memory.{mem.name}",
                                f"the windows of {', '.join(names)} need {total} bytes, "
                                f"{mem.name} has {mem.length}"))
        return []

    parts = [(prio, p) for prio, p in pieces if p.kind != "ipc"]
    channels = [(prio, p) for prio, p in pieces if p.kind == "ipc"]
    holders = {p.owners[0]: (prio, p) for prio, p in parts if p.kind in ("code+data", "data")}
    edges = [(index[p.owners[0]], index[p.owners[1]], k) for k, (_, p) in enumerate(channels)
             if p.owners[0] in holders and p.owners[1] in holders]
    linked = {k for _, _, k in edges}
    chains = _chains([index[n] for n in holders], edges)
    blocks: list[tuple[int, list[_Piece]]] = []
    by_index = {index[n]: piece for n, (_, piece) in holders.items()}
    used: set[int] = set()
    if chains is not None:
        for chain in chains:
            block = [by_index[n] if pos % 2 == 0 else channels[n][1] for pos, n in enumerate(chain)]
            blocks.append((chain[0], block))
            used.update(chain[0::2])
        shared = [p for k, (_, p) in enumerate(channels) if k not in linked]
    else:
        shared = [p for _, p in channels]
    for prio, piece in parts:
        if not (piece.kind in ("code+data", "data") and index[piece.owners[0]] in used):
            blocks.append((prio, [piece]))
    if shared:
        blocks.append((min(index[o] for p in shared for o in p.owners), shared))

    free = [(mem.origin, mem.end)]
    placed: list[PlacedWindow] = []
    for prio, block in sorted(blocks, key=lambda b: (-sum(p.size or 0 for p in b[1]), b[0])):
        size = sum(p.size or 0 for p in block)
        at = _first_fit(free, size, _alignment(block[0].size or 0))
        if at is None:
            at = _first_fit(free, size, GRANULE)
        if at is None:
            names = sorted({o for p in block for o in p.owners}, key=lambda n: index[n])
            found.append(diagnostic("GEN-E076", f"memory.{mem.name}",
                                    f"no room of {size} bytes left for the windows of {', '.join(names)}"))
            continue
        free = _take(free, at, size)
        for piece in block:
            placed.append(PlacedWindow(piece.kind, mem.name, at, piece.size or 0, piece.owners, piece.channel))
            at += piece.size or 0
    return sorted(placed, key=lambda w: w.origin)


def check(windows: Sequence[PlacedWindow], mems: Iterable[MemoryRegion],
          harts: dict[str, tuple[int, ...]]) -> list[Diagnostic]:
    """The rules of a system map: <windows>, the <mems> they name, the harts of each partition."""
    found: list[Diagnostic] = []
    by_name = {m.name: m for m in mems}
    for w in windows:
        mem = by_name.get(w.memory)
        if mem is None or w.origin < mem.origin or w.end > mem.end:
            extent = f"[{mem.origin:#010x}, {mem.end:#010x})" if mem else "no such memory"
            found.append(diagnostic("GEN-E077", f"windows.{w.memory}",
                                    f"{w.describe()} reaches outside {w.memory} {extent}"))
        elif mem.hart is not None and not any(mem.hart in harts.get(o, ()) for o in w.owners):
            found.append(diagnostic("GEN-E079", f"windows.{w.memory}",
                                    f"{w.describe()} is in the {w.memory} of hart {mem.hart}, which "
                                    f"{' and '.join(repr(o) for o in w.owners)} does not have"))
    ordered = sorted(windows, key=lambda w: (w.origin, w.end))
    for i, a in enumerate(ordered):
        for b in ordered[i + 1:]:
            if b.origin >= a.end:
                break
            if set(a.owners) != set(b.owners) and a.length and b.length:
                found.append(diagnostic("GEN-E078", f"windows.{a.memory}",
                                        f"{a.describe()} overlaps {b.describe()}"))
    return found
