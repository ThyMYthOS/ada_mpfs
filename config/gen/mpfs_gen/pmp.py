# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @req GEN-010
"""The PMP of each hart as the MSS Configurator XML sets it.

The PMP is not chosen by the generator: the user sets it with Microchip's MSS Configurator, and the XML
holds it in mss_memory_map/pmp_h0 .. pmp_h4 (CSR_PMPCFG0 for the entries 0 to 7, CSR_PMPCFG2 for 8 to 15,
CSR_PMPADDR0 .. 15), the values that Microchip's pmp_configure() writes into the CSRs of the hart
(mss_pmp.c of the platform HAL). This module reads them, decodes the entries and writes them as an Ada
table for the test program examples/pmp_xml_test, which compares them with what the hart holds.

  of(config)                the PMP of each hart (HartPmp), and the rules the XML breaks
  describe(pmps)            the entries decoded, one line each (`mpfs_gen pmp`)
  ada_table(config, name)   the Ada package Pmp_Xml with the values of every hart

The rules (Privileged Spec v1.10, 3.6.1): an entry with W set and R clear is reserved (GEN-E100); bits 5
and 6 of a configuration byte are reserved and must be zero (GEN-E101).
"""
from dataclasses import dataclass

from gen_ada import ada, spdx

from . import target
from .checks import Diagnostic, diagnostic
from .model import MssConfiguration

ENTRIES = 16
SECTION = "mss_memory_map/pmp_h{}"
ADDR_BITS = 54                   # pmpaddr holds address bits 55:2 on RV64
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


def region(entry: Entry, below: int) -> tuple[int, int] | None:
    """The bytes [first, last] that <entry> matches, with <below> the pmpaddr of the entry before it (TOR);
    None for OFF and for an empty TOR range. A NAPOT entry of all ones is the whole space of 2^56 bytes."""
    addr = entry.addr & ((1 << ADDR_BITS) - 1)
    if entry.mode == "OFF":
        return None
    if entry.mode == "TOR":
        first, end = (below & ((1 << ADDR_BITS) - 1)) << 2, addr << 2
        return (first, end - 1) if end > first else None
    if entry.mode == "NA4":
        return addr << 2, (addr << 2) + 3
    if addr == (1 << ADDR_BITS) - 1:
        return 0, (1 << (ADDR_BITS + 2)) - 1
    ones = (~addr & (addr + 1)).bit_length() - 1
    size = 1 << (ones + 3)
    first = (addr & ~((1 << ones) - 1)) << 2
    return first, first + size - 1


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
    enabled = config.register("mss_memory_map/apb_split", "MEM_CONFIGS_ENABLED").field("PMP").value
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
