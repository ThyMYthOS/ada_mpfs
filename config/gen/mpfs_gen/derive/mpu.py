# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @req GEN-017
"""The MPU of each DMA master as the MSS Configurator XML sets it, checked against the partitions.

Like the PMP, the MPU is not chosen by the generator: the user sets it in the MSS Configurator, and the XML
holds it in mss_memory_map/mpu_fic0 .. mpu_trace, one register MPU_CFG_PMP<n> per entry, the values that
Microchip's mpu_configure() writes into MPUCFG (mss_mpu.c:176-218 @ 8d52d59, whatever MEM_CONFIGS_ENABLED.MPU
says: the flag gates nothing there, and the generator does not rely on it). They are applied in both security
profiles: a DMA master has no access to the MSS until its regions exist, only the SCB bypasses the MPU (MSS
TRM DS60001702S §3.4). The MPUs are per master, not tied to the AMP contexts.

The decoding (TRM §3.4, mss_mpu.h:84-94): bits 35:0 are address bits 37:2, as pmpaddr of a PMP entry, with
bits 8:0 hardwired to 1 (a region of at least 4 KiB); bits 63:56 are the mode: bit 63 locks the entry, bits
60:59 are the address mode, bits 58, 57 and 56 X, W and R. "Only 00 and 11 are supported, TOR and NAT settings
are equivalent to off": an entry is a NAPOT region or nothing. Each master has the entries of TRM Table 3-40
(target.MPU_ENTRIES). The order of the entries is not documented to matter, so what a master reaches is taken
as the union of the regions of its NAPOT entries with a right: an upper bound, whatever priority the hardware
gives the entries, which is what the checks need.

A master is owned by the partition that has its peripheral in system.yaml (OWNER: fic0, fic1, fic2, athena
for the crypto processor, mac0 and mac1 for GEM0 and GEM1, usb, mmc); the SCB and the trace have no peripheral
there and no owner. The rules, each with its code:

  GEN-E140  an entry with the address mode TOR or NA4: the MPU takes it as off (it grants nothing)
  GEN-E141  a NAPOT entry with a clear bit among address bits 8:0: the MPU sets them, so the region is
            not the one the XML states (it is at least 4 KiB)
  GEN-E142  an entry in use (a mode byte not 0) beyond the entries of its master: the hardware has no such
            entry
  GEN-E143  a master owned by a partition reaches bytes outside the windows of its owner (code, data,
            fast_text and the channels it is an end of)
  GEN-E144  a master without an owner reaches anything
  GEN-E145  entries grant a right over the whole address space (the MSS Configurator's default, MODE 0x1F
            with all address bits set, in every XML of a board)

GEN-E140 to GEN-E142 are reported per entry (the path names its register), GEN-E143 to GEN-E145 once per
master (the path names its section; the message the entries).

The SCB bypasses its MPU, so its entries are decoded and checked for GEN-E140 to GEN-E142 only. Like the
checks of the PMP, the rules are enforced for a prod system and notes for a dev system.
"""
from dataclasses import dataclass

from .. import pmp as pmp_
from .. import target
from ..checks import Diagnostic, diagnostic
from ..model import MssConfiguration, System
from .placement import PlacedWindow

SECTION = "mss_memory_map/mpu_{}"
REGISTER = "MPU_CFG_PMP"
APB_SPLIT = "mss_memory_map/apb_split"
MODE_SHIFT = 56
ADDR_MASK = (1 << target.MPU_ADDR_BITS) - 1
# The peripheral of system.yaml whose partition owns the master.
OWNER = {"fic0": "fic0", "fic1": "fic1", "fic2": "fic2", "crypto": "athena", "gem0": "mac0", "gem1": "mac1",
         "usb": "usb", "mmc": "mmc"}
MAX_RANGES = 4
SPACE = 1 << (target.MPU_ADDR_BITS + 2)     # the bytes the PMP field of an entry can name


@dataclass(frozen=True, slots=True)
class MpuEntry:
    """Entry <index> of a master: the 64-bit value of the XML."""
    index: int
    value: int

    @property
    def cfg(self) -> int:
        """The mode byte (bits 63:56), laid out as a PMP configuration byte."""
        return self.value >> MODE_SHIFT & 0xFF

    @property
    def addr(self) -> int:
        """The PMP field (bits 35:0) as the XML states it."""
        return self.value & ADDR_MASK

    @property
    def mode(self) -> str:
        return pmp_.MODES[(self.cfg >> pmp_.A_SHIFT) & 3]

    @property
    def rights(self) -> str:
        return pmp_.Entry(self.index, self.cfg, 0).rights

    @property
    def locked(self) -> bool:
        return bool(self.cfg & pmp_.L)

    @property
    def region(self) -> tuple[int, int] | None:
        """The bytes [first, last] the MPU matches: a NAPOT entry with address bits 8:0 set as the hardware
        sets them (all ones: the whole 2^38 bytes); None for any other mode, which the MPU takes as off."""
        if self.mode != "NAPOT":
            return None
        entry = pmp_.Entry(self.index, self.cfg, self.addr | target.MPU_HARDWIRED)
        return pmp_.region(entry, 0, target.MPU_ADDR_BITS)


@dataclass(frozen=True, slots=True)
class MasterMpu:
    """The MPU of one master: its section name, the entries of the hardware, its owner (a partition, None for
    none), whether it bypasses the MPU, and the entries of the XML in index order (those beyond the hardware
    included)."""
    master: str
    entries: int
    owner: str | None
    bypass: bool
    table: tuple[MpuEntry, ...]

    @property
    def section(self) -> str:
        return SECTION.format(self.master)

    def reach(self) -> tuple[tuple[MpuEntry, int, int], ...]:
        """The entries within the hardware that grant a right, each with its region [first, last]."""
        out: list[tuple[MpuEntry, int, int]] = []
        for e in self.table:
            span = e.region
            if e.index < self.entries and span and e.rights != pmp_.NONE:
                out.append((e, span[0], span[1]))
        return tuple(out)


@dataclass(frozen=True, slots=True)
class Mpu:
    """The MPU of every master of the XML, in the order of target.MPU_ENTRIES; <enabled> is
    MEM_CONFIGS_ENABLED.MPU, which gates nothing (shown for information)."""
    enabled: bool
    masters: tuple[MasterMpu, ...]

    def master(self, name: str) -> MasterMpu:
        for m in self.masters:
            if m.master == name:
                return m
        raise KeyError(f"no MPU master {name}")


def _index(name: str) -> int | None:
    rest = name.removeprefix(REGISTER)
    return int(rest) if name.startswith(REGISTER) and rest.isdigit() else None


def _ranges(pieces: list[tuple[int, int]]) -> str:
    text = ", ".join(f"[{a:#x}, {b:#x}]" for a, b in pieces[:MAX_RANGES])
    return text + (f" and {len(pieces) - MAX_RANGES} more" if len(pieces) > MAX_RANGES else "")


def outside(first: int, last: int, allowed: list[tuple[int, int]]) -> list[tuple[int, int]]:
    """The pieces of [first, last] that no range [a, b] of <allowed> (sorted, apart) holds, in address order."""
    out: list[tuple[int, int]] = []
    at = first
    for a, b in allowed:
        if b < at:
            continue
        if a > last:
            break
        if a > at:
            out.append((at, a - 1))
        at = max(at, b + 1)
        if at > last:
            return out
    if at <= last:
        out.append((at, last))
    return out


def merged(ranges: list[tuple[int, int]]) -> list[tuple[int, int]]:
    """The ranges [first, last] sorted, those that touch or overlap made one."""
    out: list[tuple[int, int]] = []
    for first, last in sorted(ranges):
        if out and out[-1][1] + 1 >= first:
            out[-1] = (out[-1][0], max(out[-1][1], last))
        else:
            out.append((first, last))
    return out


def _entries(indices: list[int]) -> str:
    return f"entr{'ies' if len(indices) > 1 else 'y'} {', '.join(map(str, indices))}"


def derive(system: System, config: MssConfiguration, windows: tuple[PlacedWindow, ...]
           ) -> tuple[Mpu, list[Diagnostic]]:
    """The MPU of every master of the XML <config>, checked against the partitions of <system> with their
    <windows>; the findings count by the security profile (the caller decides)."""
    found: list[Diagnostic] = []
    owners = {name: part.name for part in system.partitions for name in part.peripherals}
    masters: list[MasterMpu] = []
    for master, count in target.MPU_ENTRIES.items():
        section = SECTION.format(master)
        table = sorted((MpuEntry(i, reg.value) for reg in config.section(section)
                        if (i := _index(reg.name)) is not None), key=lambda e: e.index)
        peripheral = OWNER.get(master)
        m = MasterMpu(master, count, owners.get(peripheral) if peripheral else None, master in target.MPU_BYPASS,
                      tuple(table))
        masters.append(m)
        name = master.upper()
        for e in m.table:
            at = f"{section}/{REGISTER}{e.index}"
            if e.index >= count and e.cfg:
                found.append(diagnostic("GEN-E142", at, f"entry {e.index} of {name} is in use ({e.cfg:#04x}); "
                                        f"{name} has {count} entries (0 to {count - 1})"))
                continue
            if e.mode in ("TOR", "NA4"):
                found.append(diagnostic("GEN-E140", at, f"entry {e.index} of {name} is {e.mode} ({e.cfg:#04x}), "
                                        "which the MPU takes as off"))
            elif e.mode == "NAPOT" and e.addr & target.MPU_HARDWIRED != target.MPU_HARDWIRED:
                span = e.region
                assert span is not None
                found.append(diagnostic("GEN-E141", at, f"entry {e.index} of {name} has the PMP field "
                                        f"{e.addr:#011x}; the MPU sets bits 8:0 and matches "
                                        f"[{span[0]:#x}, {span[1]:#x}]"))
        if m.bypass:
            continue
        reach = m.reach()
        if not reach:
            continue
        indices = _entries([e.index for e, _, _ in reach])
        wide = [e.index for e, first, last in reach if first == 0 and last == SPACE - 1]
        if wide:
            found.append(diagnostic("GEN-E145", section, f"{name} reaches the whole address space through "
                                    f"{_entries(wide)}"))
        spans = merged([(first, last) for _, first, last in reach])
        if m.owner is None:
            found.append(diagnostic("GEN-E144", section, f"{name}, which no partition owns, reaches "
                                    f"{_ranges(spans)} ({indices})"))
            continue
        own = merged([(w.origin, w.end - 1) for w in windows if m.owner in w.owners])
        pieces = [piece for first, last in spans for piece in outside(first, last, own)]
        if pieces:
            found.append(diagnostic("GEN-E143", section, f"{name}, owned by {m.owner!r}, reaches {_ranges(pieces)} "
                                    f"outside the windows of {m.owner!r} ({indices})"))
    enabled = config.register(APB_SPLIT, "MEM_CONFIGS_ENABLED").field("MPU").value
    return Mpu(bool(enabled), tuple(masters)), found
