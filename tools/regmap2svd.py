#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""One-time import of the PolarFire SoC register map (HTML) into svdtools fragments.

  regmap2svd.py <regmap-dir> <out-dir>

<regmap-dir> is the MSS directory of the unpacked "PolarFire SoC Register Map"
(PF_SoC_RegMap/MSS), holding one UTF-16 HTML file per peripheral family. One
svdtools patch fragment <out-dir>/<family>.yaml is written per page; it adds the
peripheral and its derived instances (all instances of MMUART go to mmuart.yaml).
The "Release Notes.htm" next to the MSS directory gives the register map version;
it is written to <out-dir>/device.svd, the device head (name, CPU, widths, the
revision history) that svdtools starts from. The instance table of
"pfsoc_regmap.htm" supplies the base addresses that some pages lack.

The register map has many typos and is probably not going to be updated by Microchip.
The generated fragments are the starting point of an SVD that is maintained by
hand from there on; this script is not part of the regular flow.

Requires Python 3.13, beautifulsoup4 and PyYAML.
"""
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from xml.etree import ElementTree as ET

import yaml
from bs4 import BeautifulSoup, Tag

XML_HEADER = """<?xml version="1.0" encoding="utf-8"?>
<!--
SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
SPDX-License-Identifier: CC-BY-4.0
-->
"""
YAML_HEADER = """# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: CC-BY-4.0
"""
# Pages without a base address: (new name, name in the instance table, further instances).
MISSING_BASE = {
    "ENVM": ("ENVM", "ENVMCFG", []),
    "GEM_GXIMICROSEMI": ("GEM_A_LO", "GEM_A_LO", ["GEM_B_LO", "GEM_A_HI", "GEM_B_HI"]),
}
# Fragment names that differ from the lower-case page name (after dropping pfsoc_mss_top_).
FRAGMENT_NAMES = {"gem_gxlmicrosemi": "gem"}
SUMMARY = " Register Summary"


@dataclass(slots=True)
class Field:
    """A bit field of a register as listed in the register map."""
    bits: str
    name: str
    description: str
    type: str
    reset: str

    @property
    def msb_lsb(self) -> tuple[int, int]:
        """Most and least significant bit of the field; a single bit gives (n, n)."""
        msb, _, lsb = self.bits.strip("[]").partition(":")
        return int(msb), int(lsb or msb)

    @property
    def access(self) -> str:
        """SVD access value of the field; fields without a known type are read-write."""
        return access(self.type, default="read-write")


@dataclass(slots=True)
class Register:
    """A register with its raw description table and its bit fields."""
    name: str
    info: dict[str, str]
    size: str
    fields: list[Field] = field(default_factory=list)

    @property
    def reset_value(self) -> int:
        """Register reset value: the combination of the field reset values."""
        value = 0
        for f in self.fields:
            try:
                value |= int(f.reset or "0", 0) << f.msb_lsb[1]
            except ValueError:
                pass
        return value


@dataclass(slots=True)
class Instance:
    """A further instance of a peripheral at another base address."""
    name: str
    base_address: str


@dataclass(slots=True)
class Peripheral:
    """A peripheral: its base address, registers, the instances derived from it and its family."""
    name: str
    base_address: str | None
    registers: list[Register]
    instances: list[Instance] = field(default_factory=list)
    group: str | None = None  # groupName: the family of a page that lists several instances


def access(kind: str, *, default: str) -> str:
    """Map a register map access type ("RW", "RO ...") to an SVD access value.

    <default> is returned for any other type.
    """
    match kind.lower().split()[:1]:
        case ["rw"]:
            return "read-write"
        case ["ro"]:
            return "read-only"
        case _:
            return default


def clean_text(text: str) -> str:
    """Collapse all whitespace, including non-breaking spaces, to single blanks."""
    return " ".join(text.replace("\xa0", " ").split())


def remove_whitespace(text: str) -> str:
    """Remove all whitespace, e.g. from addresses and bit ranges."""
    return "".join(text.split())


def rows(table: Tag) -> list[list[Tag]]:
    """All rows of an HTML table as lists of their cells."""
    return [tr.find_all("td") for tr in table.find_all("tr")]


def parse_summary(table: Tag) -> list[dict[str, str]]:
    """Parse a summary table: one dict per row, keyed by the lower-case header texts."""
    header, *body = rows(table)
    keys = [clean_text(td.get_text().lower()) for td in header]
    return [dict(zip(keys, (clean_text(td.get_text()) for td in row))) for row in body]


def parse_info(table: Tag) -> dict[str, str]:
    """Parse the two-column table of a register description into a dict.

    Keys are the lower-case row titles without the trailing colon.
    """
    return {clean_text(c[0].get_text()).replace(":", "").lower(): clean_text(c[1].get_text())
            for c in rows(table) if len(c) >= 2}


def parse_fields(table: Tag) -> list[Field]:
    """Parse the bit field table of a register.

    Rows without a bit range continue the description of the previous field.
    Reserved fields are dropped.
    """
    fields: list[Field] = []
    current: Field | None = None
    for cols in rows(table)[1:]:  # skip header
        if not cols:
            continue
        if cols[0].get_text().strip() == "":
            # continuation row: more description for the previous field
            if current and len(cols) >= 3:
                current.description += " " + clean_text(cols[2].get_text())
        elif len(cols) >= 5:
            current = Field(
                bits=remove_whitespace(cols[0].get_text()),
                name=clean_text(cols[1].get_text()).upper(),
                description=clean_text(cols[2].get_text()),
                type=remove_whitespace(cols[3].get_text()),
                reset=remove_whitespace(cols[4].get_text()),
            )
            if current.name != "RESERVED":
                fields.append(current)
    return fields


def heading(soup: BeautifulSoup, tag: str, suffix: str) -> Tag:
    """First heading <tag> whose text ends with <suffix>; StopIteration if there is none."""
    return next(h for h in soup.find_all(tag) if clean_text(h.get_text()).endswith(suffix))


def parse_peripheral(soup: BeautifulSoup) -> Peripheral:
    """Parse the HTML page of one peripheral.

    A page that lists several instances names the first one as the base
    instance; the others become instances derived from it. The base instance
    gets the family of the page as groupName, so that svd2ada shares one
    register type between the instances of the family.
    """
    name = clean_text(soup.find("h2").get_text()).replace("pfsoc_mss_top_", "").upper()
    family = name
    summary = {r["register name"].upper(): r
               for r in parse_summary(heading(soup, "h2", "Register Mapping Summary").find_next_sibling("table"))}

    registers = []
    for header in heading(soup, "h2", "Register Descriptions").find_next_siblings("h3"):
        reg_name = clean_text(header.get_text()).split(":")[1].strip()
        info_table = header.find_next("table")
        fields_table = info_table.find_next("table") if info_table else None
        if info_table and fields_table:
            registers.append(Register(
                name=reg_name,
                info=parse_info(info_table),
                size=summary[reg_name.upper()].get("register width (bits)", "32"),
                fields=parse_fields(fields_table),
            ))

    # Several instances: the first "Register Summary" names the base instance.
    sections = [h for h in soup.find_all("h3") if clean_text(h.get_text()).endswith(SUMMARY)]
    instances = []
    group = None
    if len(sections) > 1:
        name = clean_text(sections[0].find_all("a")[-1].get_text()).removesuffix(SUMMARY)
        instances = [
            Instance(clean_text(h.find_all("a")[-1].get_text()).removesuffix(SUMMARY),
                     remove_whitespace(parse_summary(h.find_next_sibling("table"))[0]["physical address"]))
            for h in sections[1:]
        ]
        group = family
    base = registers[0].info.get("physical address") if registers else None
    return Peripheral(name, remove_whitespace(base) if base else None, registers, instances, group)


class Hex(int):
    """An int that is written as a hexadecimal literal in YAML."""


class Dumper(yaml.SafeDumper):
    """YAML dumper that writes Hex values as 0x literals."""


Dumper.add_representer(Hex, lambda d, v: d.represent_scalar("tag:yaml.org,2002:int", f"0x{v:X}"))


def shared_offset(p: Peripheral) -> int:
    """Common minimum register offset m that the base address already contains, or 0.

    Some register map pages list the address offsets with the low bits of the base
    address in them (ATHENA at 0x22006000 lists 0x6000..0x6018). If m > 0 and the base
    address has m in the bits below the smallest power of two above the largest offset,
    m is subtracted from all offsets of the peripheral, so those bits are not counted twice.
    """
    offsets = [int(remove_whitespace(r.info.get("address offset", "0x0")), 0) for r in p.registers]
    if not p.base_address or not offsets:
        return 0
    m = min(offsets)
    mask = (1 << max(offsets).bit_length()) - 1
    return m if m > 0 and int(p.base_address, 0) & mask == m else 0


def peripheral_dict(p: Peripheral) -> dict:
    """svdtools description of peripheral <p>: registers and fields as nested maps."""
    shift = shared_offset(p)
    regs = {}
    for r in p.registers:
        if r.name in regs:
            raise ValueError(f"{p.name}: duplicate register {r.name}")
        fields = {}
        for f in r.fields:
            if f.name in fields:
                raise ValueError(f"{p.name}.{r.name}: duplicate field {f.name}")
            msb, lsb = f.msb_lsb
            fields[f.name] = {"description": f.description, "bitOffset": lsb, "bitWidth": msb - lsb + 1,
                              "access": f.access}
        regs[r.name] = {
            "description": r.info.get("description") or None,
            "addressOffset": Hex(int(remove_whitespace(r.info.get("address offset", "0x0")), 0) - shift),
            "size": int(r.size),
            "access": access(r.info.get("type", "ro"), default="read-only"),
            "resetValue": Hex(r.reset_value),
        }
        # SVD forbids an empty <fields>: registers with only reserved bits get none.
        if fields:
            regs[r.name]["fields"] = fields
    out = {"description": f"{p.name} Controller"}
    if p.group:
        out["groupName"] = p.group
    if p.base_address:
        out["baseAddress"] = Hex(int(p.base_address, 0))
    out["registers"] = regs
    return out


def instance_dict(i: Instance, parent: str) -> dict:
    """svdtools description of instance <i>, derived from the peripheral <parent>."""
    return {"derivedFrom": parent, "description": f"{i.name} Controller", "baseAddress": Hex(int(i.base_address, 0))}


def without_empty(node):
    """<node> without the map entries that are None, recursively (empty SVD descriptions are invalid)."""
    if isinstance(node, dict):
        return {k: without_empty(v) for k, v in node.items() if v is not None}
    return node


def write_fragment(p: Peripheral, out: Path) -> None:
    """Write the fragment file <out>: a patch adding <p> and its instances."""
    add = {p.name: peripheral_dict(p)}
    add.update({i.name: instance_dict(i, p.name) for i in p.instances})
    body = yaml.dump({"_add": without_empty(add)}, Dumper=Dumper, sort_keys=False, allow_unicode=True, width=1 << 30)
    out.write_text(YAML_HEADER + body, encoding="utf-8")


def parse_instance_table(soup: BeautifulSoup) -> dict[str, str]:
    """Instance name -> base address of the instance table in pfsoc_regmap.htm."""
    table = next(t for t in soup.find_all("table") if clean_text(t.get_text()).startswith("Instance Name"))
    return {clean_text(c[0].get_text()): remove_whitespace(c[1].get_text()) for c in rows(table)[1:] if len(c) >= 2}


def apply_instance_table(p: Peripheral, table: dict[str, str]) -> None:
    """Complete <p> from the instance table if its page gives no base address.

    The peripheral may be renamed and may get further instances (see MISSING_BASE).
    """
    if p.base_address or p.name not in MISSING_BASE:
        return
    name, table_name, others = MISSING_BASE[p.name]
    p.name, p.base_address = name, table[table_name]
    p.instances = [Instance(n, table[n]) for n in others]


def text(parent: ET.Element, tag: str, value: str | None) -> ET.Element:
    """Append <tag>value</tag> to <parent> and return the new element."""
    el = ET.SubElement(parent, tag)
    el.text = value
    return el


@dataclass(slots=True)
class Release:
    """One row of the register map revision history."""
    version: str
    date: str  # ISO 8601
    details: str


def parse_release_notes(soup: BeautifulSoup) -> list[Release]:
    """Revision history, oldest first. Dates in the source are M/D/YYYY."""
    releases = []
    for cols in rows(soup.find("table"))[1:]:  # skip header
        if len(cols) < 3:
            continue
        m, d, y = (int(n) for n in re.fullmatch(r"(\d+)/(\d+)/(\d+)", clean_text(cols[1].get_text())).groups())
        releases.append(Release(clean_text(cols[0].get_text()), f"{y:04}-{m:02}-{d:02}",
                                clean_text(cols[2].get_text())))
    return releases


def write_device(releases: list[Release], out: Path) -> None:
    """Write the device-level fragment <out>.

    The version is that of the newest release; the history goes into a comment.
    The peripherals are added by the fragments.
    """
    root = ET.Element("device")
    for tag, value in [("vendor", "Microchip"), ("name", "PolarfireSoC"), ("version", releases[-1].version),
                       ("description", "Polarfire SoC Register Description"),
                       ("addressUnitBits", "8"), ("width", "64"), ("size", "64")]:
        text(root, tag, value)
    cpu = ET.SubElement(root, "cpu")
    for tag, value in [("name", "other"), ("revision", "r1p0"), ("endian", "little"),
                       ("mpuPresent", "false"), ("fpuPresent", "true"), ("nvicPrioBits", "0"),
                       ("vendorSystickConfig", "false")]:
        text(cpu, tag, value)
    ET.SubElement(root, "peripherals")
    ET.indent(root, space="  ")
    history = "".join(f"  {r.version:4} {r.date}  {r.details.replace('--', '- -')}\n" for r in releases)
    out.write_text(XML_HEADER + "<!--\nMicrochip register map revision history:\n" + history + "-->\n"
                   + ET.tostring(root, encoding="unicode") + "\n", encoding="utf-8")


def main(argv: list[str]) -> int:
    """Command line entry point; returns the exit code."""
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    out = Path(argv[2])
    out.mkdir(parents=True, exist_ok=True)
    index = Path(argv[1]).parent / "pfsoc_regmap.htm"
    table = parse_instance_table(BeautifulSoup(index.read_text(encoding="utf-16", errors="replace"), "html.parser"))
    for path in sorted(Path(argv[1]).glob("*.htm*")):
        p = parse_peripheral(BeautifulSoup(path.read_text(encoding="utf-16"), "html.parser"))
        apply_instance_table(p, table)
        stem = path.stem.lower().removeprefix("pfsoc_mss_top_")
        write_fragment(p, out / f"{FRAGMENT_NAMES.get(stem, stem)}.yaml")
    notes = Path(argv[1]).parent / "Release Notes.htm"
    # The release notes are plain Windows-1252 HTML, unlike the register pages.
    write_device(parse_release_notes(BeautifulSoup(notes.read_text(encoding="cp1252"), "html.parser")),
                 out / "device.svd")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
