# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @req GEN-010, GEN-011, GEN-013
"""The PMP of each hart as the MSS Configurator XML sets it.

The PMP is not chosen by the generator: the user sets it with Microchip's MSS Configurator, and the XML
holds it in mss_memory_map/pmp_h0 .. pmp_h4 (CSR_PMPCFG0 for the entries 0 to 7, CSR_PMPCFG2 for 8 to 15,
CSR_PMPADDR0 .. 15), the values that Microchip's pmp_configure() writes into the CSRs of the hart
(mss_pmp.c of the platform HAL). This module reads them, decodes the entries and writes them as an Ada
table for the test program examples/pmp_xml_test, which compares them with what the hart holds.

  of(config)                the PMP of each hart (HartPmp), and the rules the XML breaks
  describe(pmps)            the entries decoded, one line each (`mpfs_gen pmp`)
  ada_table(config, name)   the Ada package Pmp_Xml with the values of every hart
  regions(pmp, bits)        the address space of a hart cut into the regions in which its PMP decides
                            alike, with the rights of U and M mode in each
  locked_part(pmp)          the entries the boot loader sets (locked), unlocked_part(pmp) those of the kernel
  cover(ranges, start, pmp) unlocked entries from index <start> that grant each range its rights (NAPOT
                            where the range allows, else TOR), and with_entries() the PMP with them set
  rules(config, harts, n)   the rules on how the entries are laid out (the derivation checks them)

The rules of the encoding (Privileged Spec v1.10, 3.6.1): an entry with W set and R clear is reserved
(GEN-E100); bits 5 and 6 of a configuration byte are reserved and must be zero (GEN-E101).

The semantics (Privileged Spec v1.10, 3.6.1; the MPFS has no Smepmp): the matching entry with the lowest
index decides an access. For U mode it grants its R, W and X; for M mode only if L is set, an entry without
L lets M through. If no entry matches, M is allowed and U denied. L also locks the entry and, for TOR, the
pmpaddr of the entry before it. pmpaddr is WARL: a hart implements only its low bits (target.PMPADDR_BITS),
so the regions are taken within those bits, as the hart sees them.

The rules of the layout (rules()): all locked entries come before all unlocked ones in use (GEN-E102); the
entries in use fit the number of entries of the target, 16 on the silicon, 8 under QEMU with
--pmp-entries 8 (GEN-E103); with MEM_CONFIGS_ENABLED.PMP 0 the PMP sections should be zero (GEN-E104, a
warning); a locked entry that grants rights over the whole address space, or over the range of a later
entry so that the later entry can never decide, is refused (GEN-E105): the locked RWX entry 0 over all
addresses in pmp_h1 to pmp_h4 of the reference XMLs is one. (A locked TOR entry also locks the pmpaddr of
the entry before it; with all locked entries first that entry is locked or unused, see locked_part.)
"""
from dataclasses import dataclass
from itertools import pairwise

from gen_ada import ada, spdx

from . import target
from .checks import Diagnostic, diagnostic
from .model import MssConfiguration

ENTRIES = 16
SECTION = "mss_memory_map/pmp_h{}"
APB_SPLIT = "mss_memory_map/apb_split"
ADDR_BITS = 54                   # pmpaddr holds address bits 55:2 on RV64 (a hart may implement fewer)
R, W, X, A_SHIFT, L = 0x01, 0x02, 0x04, 3, 0x80
RESERVED = 0x60
MODES = ("OFF", "TOR", "NA4", "NAPOT")
TOOL = "config/gen/mpfs_gen pmp"


@dataclass(frozen=True, slots=True)
class Entry:
    """Entry <index> of a hart: its configuration byte and pmpaddr."""
    index: int
    cfg: int
    addr: int

    @property
    def mode(self) -> str:
        return MODES[(self.cfg >> A_SHIFT) & 3]

    @property
    def rights(self) -> str:
        return "".join(c if self.cfg & bit else "-" for c, bit in (("r", R), ("w", W), ("x", X)))

    @property
    def locked(self) -> bool:
        return bool(self.cfg & L)


@dataclass(frozen=True, slots=True)
class HartPmp:
    """The PMP CSRs of hart <hart> as the XML sets them."""
    hart: int
    cfg0: int
    cfg2: int
    addr: tuple[int, ...]

    def entry(self, index: int) -> Entry:
        cfg = (self.cfg0 if index < 8 else self.cfg2) >> (8 * (index % 8)) & 0xFF
        return Entry(index, cfg, self.addr[index])

    @property
    def entries(self) -> tuple[Entry, ...]:
        return tuple(self.entry(i) for i in range(ENTRIES))


def of(config: MssConfiguration) -> tuple[tuple[HartPmp, ...], list[Diagnostic]]:
    """The PMP of each hart of the XML <config>, and the rules its entries break."""
    found: list[Diagnostic] = []
    harts: list[HartPmp] = []
    for hart in range(target.NUMBER_OF_HARTS):
        section = SECTION.format(hart)
        pmp = HartPmp(hart, config.value(section, "CSR_PMPCFG0"), config.value(section, "CSR_PMPCFG2"),
                      tuple(config.value(section, f"CSR_PMPADDR{i}") for i in range(ENTRIES)))
        for e in pmp.entries:
            where = f"{section}/CSR_PMPCFG{0 if e.index < 8 else 2}.PMP{e.index}CFG"
            if e.cfg & W and not e.cfg & R:
                found.append(diagnostic("GEN-E100", where, f"{e.cfg:#04x} has W without R (reserved)"))
            if e.cfg & RESERVED:
                found.append(diagnostic("GEN-E101", where, f"{e.cfg:#04x} sets the reserved bits 5 and 6"))
        harts.append(pmp)
    return tuple(harts), found


def space(bits: int) -> int:
    """The bytes that a pmpaddr of <bits> implemented bits addresses: 2 ** (bits + 2)."""
    return 1 << (bits + 2)


def region(entry: Entry, below: int, bits: int = ADDR_BITS) -> tuple[int, int] | None:
    """The bytes [first, last] that <entry> matches, with <below> the pmpaddr of the entry before it (TOR),
    both taken in the <bits> low bits that the hart implements; None for OFF and for an empty TOR range. A
    NAPOT entry of all ones is the whole space (2^56 bytes with the 54 bits of RV64)."""
    mask = (1 << bits) - 1
    addr = entry.addr & mask
    if entry.mode == "OFF":
        return None
    if entry.mode == "TOR":
        first, end = (below & mask) << 2, addr << 2
        return (first, end - 1) if end > first else None
    if entry.mode == "NA4":
        return addr << 2, (addr << 2) + 3
    if addr == mask:
        return 0, space(bits) - 1
    ones = (~addr & (addr + 1)).bit_length() - 1
    size = 1 << (ones + 3)
    first = (addr & ~((1 << ones) - 1)) << 2
    return first, min(first + size, space(bits)) - 1


NONE = "---"
ALL = "rwx"


@dataclass(frozen=True, slots=True)
class Region:
    """The bytes [first, last] of a hart in which its PMP decides alike: <entry> is the index of the entry
    that matches them (None: no entry does), <u> and <m> are the rights of U and M mode there ("rwx" with
    "-" for a missing right)."""
    first: int
    last: int
    entry: int | None
    u: str
    m: str


def matches(pmp: HartPmp, bits: int) -> tuple[tuple[Entry, int, int], ...]:
    """The entries of <pmp> that match a byte, each with its range [first, last], in index order."""
    out: list[tuple[Entry, int, int]] = []
    for e in pmp.entries:
        span = region(e, pmp.addr[e.index - 1] if e.index else 0, bits)
        if span:
            out.append((e, span[0], span[1]))
    return tuple(out)


def regions(pmp: HartPmp, bits: int) -> tuple[Region, ...]:
    """The address space of the hart of <pmp>, whose pmpaddr implements <bits> bits, cut into the regions in
    which the PMP decides alike, in address order; neighbours decided alike by the same entry are one."""
    found = matches(pmp, bits)
    cuts = sorted({0, space(bits)} | {first for _, first, _ in found} | {last + 1 for _, _, last in found})
    out: list[Region] = []
    for first, end in pairwise(cuts):
        entry = next((e for e, low, high in found if low <= first <= high), None)
        if entry is None:
            index, u, m = None, NONE, ALL
        else:
            index, u, m = entry.index, entry.rights, entry.rights if entry.locked else ALL
        if out and (out[-1].entry, out[-1].u, out[-1].m) == (index, u, m):
            out[-1] = Region(out[-1].first, end - 1, index, u, m)
        else:
            out.append(Region(first, end - 1, index, u, m))
    return tuple(out)


def rights(found: tuple[Region, ...], first: int, last: int, mode: str) -> tuple[tuple[int, int, str], ...]:
    """The rights of <mode> ("u" or "m") over the bytes [first, last] as (first, last, rights) pieces in
    address order, from the regions <found> of a hart (bytes beyond its space are left out)."""
    out: list[tuple[int, int, str]] = []
    for r in found:
        low, high = max(first, r.first), min(last, r.last)
        if low <= high:
            out.append((low, high, r.u if mode == "u" else r.m))
    return tuple(out)


def locked_part(pmp: HartPmp) -> tuple[Entry, ...]:
    """The entries that the boot loader sets and nothing changes until a reset: every locked entry and the
    entry before a locked TOR entry (whose pmpaddr is its base and is locked with it), in index order."""
    keep = {e.index for e in pmp.entries if e.locked}
    keep |= {e.index - 1 for e in pmp.entries if e.locked and e.mode == "TOR" and e.index}
    return tuple(pmp.entry(i) for i in sorted(keep))


def in_use(pmp: HartPmp) -> tuple[int, ...]:
    """The indices of the entries a hart uses: those not OFF, the locked ones and the base of a TOR entry."""
    used = {e.index for e in pmp.entries if e.mode != "OFF" or e.locked}
    used |= {e.index - 1 for e in pmp.entries if e.mode == "TOR" and e.index}
    return tuple(sorted(used))


def unlocked_part(pmp: HartPmp) -> tuple[Entry, ...]:
    """The entries that the kernel sets: those in use that are not in the locked part (the base of an
    unlocked TOR entry included), in index order."""
    locked = {e.index for e in locked_part(pmp)}
    return tuple(pmp.entry(i) for i in in_use(pmp) if i not in locked)


def _cfg(mode: str, rights: str) -> int:
    return MODES.index(mode) << A_SHIFT | sum(bit for c, bit in (("r", R), ("w", W), ("x", X)) if c in rights)


def napot_pieces(first: int, end: int) -> list[tuple[int, int]]:
    """[first, end) as the fewest NAPOT ranges (first, size) in address order: each the largest power of two
    of at least 8 bytes that is a multiple of its start and fits; <first> and <end> multiples of 8."""
    out: list[tuple[int, int]] = []
    while first < end:
        size = first & -first if first else 1 << (end.bit_length() - 1)
        while first + size > end:
            size >>= 1
        out.append((first, size))
        first += size
    return out


def cover(ranges: list[tuple[int, int, str]], start: int, pmp: HartPmp) -> tuple[Entry, ...]:
    """Unlocked entries from index <start> on (indices may pass the 16 of the hart) that grant each of the
    <ranges> (first, end, rights), [first, end) multiples of 8 and in address order, its rights: one NAPOT
    entry per piece of napot_pieces() if that takes no more entries than TOR, else a TOR entry, whose base is
    the pmpaddr of the entry before it (an OFF entry with the base before it, unless the entry before is a
    TOR entry that ends at <first>). The entries before <start> are those of <pmp>."""
    out: list[Entry] = []

    def before(index: int) -> Entry | None:
        if index == 0:
            return None
        return out[-1] if out and out[-1].index == index - 1 else pmp.entry(index - 1) if index - 1 < ENTRIES else None

    index = start
    for first, end, rights in ranges:
        pieces = napot_pieces(first, end)
        prev = before(index)
        chained = (prev is None and first == 0) or (prev is not None and prev.mode == "TOR"
                                                    and prev.addr << 2 == first)
        if len(pieces) <= (1 if chained else 2):
            for base, size in pieces:
                out.append(Entry(index, _cfg("NAPOT", rights), (base >> 2) | ((size >> 3) - 1)))
                index += 1
            continue
        if not chained:
            out.append(Entry(index, _cfg("OFF", ""), first >> 2))
            index += 1
        out.append(Entry(index, _cfg("TOR", rights), end >> 2))
        index += 1
    return tuple(out)


def with_entries(pmp: HartPmp, entries: tuple[Entry, ...]) -> HartPmp:
    """<pmp> with <entries> set at their indices (those beyond the 16 of the hart left out)."""
    cfg = [pmp.entry(i).cfg for i in range(ENTRIES)]
    addr = list(pmp.addr)
    for e in entries:
        if e.index < ENTRIES:
            cfg[e.index], addr[e.index] = e.cfg, e.addr
    return HartPmp(pmp.hart, sum(c << 8 * i for i, c in enumerate(cfg[:8])),
                   sum(c << 8 * i for i, c in enumerate(cfg[8:])), tuple(addr))


def rules(config: MssConfiguration, harts: tuple[HartPmp, ...],
          entries: int = target.PMP_ENTRIES) -> list[Diagnostic]:
    """The rules of the layout of the PMP entries <harts> of the XML <config> (the module text); <entries>
    is the number of entries of the target (16 on the silicon, 8 under QEMU)."""
    found: list[Diagnostic] = []
    for pmp in harts:
        section = SECTION.format(pmp.hart)
        bits = target.PMPADDR_BITS[pmp.hart]
        unlocked = [e for e in pmp.entries if e.mode != "OFF" and not e.locked]
        late = [e for e in pmp.entries if e.locked and unlocked and e.index > unlocked[0].index]
        if late:
            found.append(diagnostic("GEN-E102", f"{section}/PMP{late[0].index}CFG",
                                    f"entry {late[0].index} of hart {pmp.hart} is locked, after the unlocked "
                                    f"entry {unlocked[0].index}"))
        beyond = [e.index for e in pmp.entries if e.index >= entries and (e.mode != "OFF" or e.locked)]
        if beyond:
            found.append(diagnostic("GEN-E103", section,
                                    f"hart {pmp.hart} uses entr{'ies' if len(beyond) > 1 else 'y'} "
                                    f"{', '.join(map(str, beyond))}; the target has {entries} (0 to {entries - 1})"))
        spans = matches(pmp, bits)
        for i, (e, first, last) in enumerate(spans):
            if not e.locked or e.rights == NONE:
                continue
            whole = first == 0 and last == space(bits) - 1
            hidden = [later.index for later, low, high in spans[i + 1:] if first <= low and high <= last]
            if whole or hidden:
                what = "the whole address space" if whole else f"[{first:#x}, {last:#x}]"
                more = f", hiding entr{'ies' if len(hidden) > 1 else 'y'} {', '.join(map(str, hidden))}" \
                    if hidden else ""
                found.append(diagnostic("GEN-E105", f"{section}/PMP{e.index}CFG",
                                        f"entry {e.index} of hart {pmp.hart} is locked and grants {e.rights} to "
                                        f"all modes over {what}{more}"))
    enabled = config.register(APB_SPLIT, "MEM_CONFIGS_ENABLED").field("PMP").value
    nonzero = [p.hart for p in harts if p.cfg0 or p.cfg2 or any(p.addr)]
    if not enabled and nonzero:
        found.append(diagnostic("GEN-E104", f"{APB_SPLIT}/MEM_CONFIGS_ENABLED.PMP",
                                "PMP is 0, but " + ", ".join(SECTION.format(h).rpartition("/")[2] for h in nonzero)
                                + " set entries"))
    return found


def describe(harts: tuple[HartPmp, ...]) -> list[str]:
    """One line per hart with its CSR values, one per entry that is not OFF: index, mode, range, rights,
    lock."""
    out: list[str] = []
    for pmp in harts:
        used = [e for e in pmp.entries if e.mode != "OFF"]
        out.append(f"hart {pmp.hart}: pmpcfg0 {pmp.cfg0:#018x}, pmpcfg2 {pmp.cfg2:#018x}, "
                   f"{len(used)} of {ENTRIES} entries not OFF")
        for e in used:
            span = region(e, pmp.addr[e.index - 1] if e.index else 0)
            where = f"[{span[0]:#x}, {span[1]:#x}]" if span else "empty"
            out.append(f"  entry {e.index}: {e.mode} {where} {e.rights}{' locked' if e.locked else ''}")
    return out


def _hex(value: int) -> str:
    digits = f"{value:016x}"
    return "16#" + "_".join(digits[i:i + 4] for i in range(0, 16, 4)) + "#"


def _string(text: str) -> list[str]:
    """A static String of the lines of the table: pieces of at most 60 characters joined by &, the last
    with the semicolon."""
    pieces = [text[i:i + 60] for i in range(0, len(text), 60)] or [""]
    quoted = ['"' + piece.replace('"', '""') + '"' for piece in pieces]
    return [f"     {q}" + (" &" if i < len(quoted) - 1 else ";") for i, q in enumerate(quoted)]


def ada_table(config: MssConfiguration, name: str) -> str:
    """The Ada package Pmp_Xml with the PMP values of every hart of <config>; <name> names the XML in the
    text (the file as the caller gave it, so that the output does not depend on the directory)."""
    harts, _ = of(config)
    enabled = config.register(APB_SPLIT, "MEM_CONFIGS_ENABLED").field("PMP").value
    out = spdx.header("ada", "Apache-2.0").splitlines()
    out += ["--", *ada.comment(ada.generated_notice(TOOL, f"the MSS Configurator XML {name}"), indent=""),
            "--",
            *ada.comment("The PMP CSRs of each hart as mss_memory_map/pmp_h0 .. pmp_h4 of the XML set them: "
                         "the values Microchip's pmp_configure() writes.", indent=""),
            "", "package Pmp_Xml with Pure is", "",
            "   Xml        : constant String :=",
            *_string(name),
            "   Xml_Sha256 : constant String :=",
            f"     \"{config.sha256}\";", "",
            *ada.comment("MEM_CONFIGS_ENABLED.PMP of the XML: with it, pmp_configure() also writes pmpcfg2 "
                         "and lets pmp_master_configs() change pmpcfg0."),
            f"   Pmp_Enabled : constant Boolean := {'True' if enabled else 'False'};", "",
            "   type U64 is mod 2 ** 64;",
            f"   type Entry_Index is range 0 .. {ENTRIES - 1};",
            f"   type Hart_Index is range 0 .. {target.NUMBER_OF_HARTS - 1};",
            "   type Addresses is array (Entry_Index) of U64;", "",
            "   type Hart_Pmp is record",
            "      Cfg0 : U64;",
            "      Cfg2 : U64;",
            "      Addr : Addresses;",
            "   end record;", "",
            "   Pmp : constant array (Hart_Index) of Hart_Pmp :=",
            ]
    for pmp in harts:
        lead = "     [" if pmp.hart == 0 else "      "
        end = "])," if pmp.hart < target.NUMBER_OF_HARTS - 1 else "])];"
        addr = ",\n".join(f"{' ' * 21}{_hex(a)}" for a in pmp.addr).lstrip()
        out.append(f"{lead}{pmp.hart} => (Cfg0 => {_hex(pmp.cfg0)},")
        out.append(f"{' ' * 12}Cfg2 => {_hex(pmp.cfg2)},")
        out.append(f"{' ' * 12}Addr => [{addr}{end}")
    out += ["", "end Pmp_Xml;", ""]
    return "\n".join(out)
