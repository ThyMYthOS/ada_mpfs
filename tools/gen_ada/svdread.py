# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""One reader of the merged SVD (build/svd/PolarfireSoC.svd) for the generators.

  load(path)         the parsed file, or an error that names it
  ensure(root)       the merged SVD of the repository at <root>, rebuilt first if it is stale
  peripherals(root)  the peripherals in file order with their group and whether they have a readAction
  interrupts(root)   the <interrupt> elements in file order
  registers(root)    the registers of each peripheral with their size and the layout of their fields

What a generator makes of them (which group sizes are valid, which interrupt numbers are allowed) is its
own rule; this module only reads.
"""
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from xml.etree import ElementTree as ET

from .errors import GenError, InputError


@dataclass(slots=True)
class Peripheral:
    """A peripheral of the SVD."""
    name: str
    group: str      # <groupName>, from the base peripheral if it derives from one; empty if none
    reads: bool     # a register or field has a <readAction>, also through derivedFrom


@dataclass(slots=True)
class Interrupt:
    """An <interrupt> element; the value is the text of the element, not yet checked."""
    name: str
    value: str
    description: str    # blanks and line breaks collapsed


@dataclass(frozen=True, slots=True)
class Field:
    """The bits of a field: the lowest one and how many."""
    offset: int
    width: int


@dataclass(frozen=True, slots=True)
class Register:
    """A register of the SVD: its size in bits and its fields by name."""
    size: int
    fields: dict[str, Field]


def load(path: Path, *, error: type[GenError] = InputError) -> ET.Element:
    """The root element of the SVD <path>; a file that cannot be read or is no XML raises `error`."""
    try:
        return ET.parse(path).getroot()
    except (OSError, ET.ParseError) as err:
        raise error(f"{path}: cannot read the SVD ({err})") from err


def ensure(root: Path, *, error: type[GenError] = InputError) -> Path:
    """build/svd/PolarfireSoC.svd of the repository at <root> with the hash recorded in
    svd/PolarfireSoC.sha256 (tools/svd.py ensure, which needs svdtools only if the file is missing or
    stale); a failure raises `error` with the output of the tool."""
    result = subprocess.run([sys.executable, str(root / "tools" / "svd.py"), "ensure"],
                            capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise error("tools/svd.py ensure failed:\n" + (result.stdout + result.stderr).rstrip())
    return root / "build" / "svd" / "PolarfireSoC.svd"


def peripherals(root: ET.Element) -> list[Peripheral]:
    """The peripherals of the SVD in file order. <groupName> and the registers are resolved through
    derivedFrom the way svd2ada does (a derived peripheral inherits them from its base)."""
    elements = {p.findtext("name") or "": p for p in root.iter("peripheral")}

    def group_of(name: str, seen: tuple[str, ...] = ()) -> str:
        elt = elements[name]
        own = (elt.findtext("groupName") or "").strip()
        base = elt.get("derivedFrom")
        if own or not base or base in seen:
            return own
        return group_of(base, seen + (name,))

    def reads_of(name: str, seen: tuple[str, ...] = ()) -> bool:
        elt = elements[name]
        base = elt.get("derivedFrom")
        return (elt.find(".//readAction") is not None
                or bool(base and base not in seen and reads_of(base, seen + (name,))))

    return [Peripheral(name, group_of(name), reads_of(name)) for name in elements]


def interrupts(root: ET.Element) -> list[Interrupt]:
    """The <interrupt> elements of all peripherals in file order (name and value stripped)."""
    return [Interrupt((element.findtext("name") or "").strip(),
                      (element.findtext("value") or "").strip(),
                      " ".join((element.findtext("description") or "").split()))
            for element in root.iter("interrupt")]


def _bits(field: ET.Element) -> Field | None:
    """The bits of a <field> in any of the three forms of the SVD (bitOffset and bitWidth, lsb and msb,
    bitRange [msb:lsb]); None if it has none or they are no numbers."""
    try:
        offset, width = field.findtext("bitOffset"), field.findtext("bitWidth")
        if offset is not None:
            return Field(int(offset, 0), int(width or "1", 0))
        lsb, msb = field.findtext("lsb"), field.findtext("msb")
        if lsb is not None and msb is not None:
            return Field(int(lsb, 0), int(msb, 0) - int(lsb, 0) + 1)
        bit_range = (field.findtext("bitRange") or "").strip()
        if bit_range.startswith("[") and bit_range.endswith("]") and ":" in bit_range:
            high, low = bit_range[1:-1].split(":")
            return Field(int(low, 0), int(high, 0) - int(low, 0) + 1)
    except ValueError:
        return None
    return None


def registers(root: ET.Element) -> dict[tuple[str, str], Register]:
    """The registers of the SVD by (peripheral, register), each with its size in bits (its own <size>,
    else that of the peripheral, else that of the device, else 32) and its fields by name. A derived
    peripheral has the registers of its base when it has none of its own. Registers and fields are
    taken by their names as written: a <dim> array keeps its %s name. A field without readable bits is
    left out."""
    def size_of(element: ET.Element | None, default: int) -> int:
        text = element.findtext("size") if element is not None else None
        try:
            return int(text, 0) if text else default
        except ValueError:
            return default

    device_size = size_of(root, 32)
    elements = {p.findtext("name") or "": p for p in root.iter("peripheral")}

    def own(name: str, seen: tuple[str, ...] = ()) -> ET.Element:
        elt = elements[name]
        base = elt.get("derivedFrom")
        if elt.find("registers") is None and base in elements and base not in seen:
            return own(base, seen + (name,))
        return elt

    result: dict[tuple[str, str], Register] = {}
    for name in elements:
        source = own(name)
        peripheral_size = size_of(source, device_size)
        for reg in source.iter("register"):
            fields: dict[str, Field] = {}
            for field in reg.iter("field"):
                bits = _bits(field)
                if bits is not None:
                    fields[(field.findtext("name") or "").strip()] = bits
            result[(name, (reg.findtext("name") or "").strip())] = Register(size_of(reg, peripheral_size), fields)
    return result
