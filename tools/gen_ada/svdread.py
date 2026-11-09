# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""One reader of the merged SVD (build/svd/PolarfireSoC.svd) for the generators.

  load(path)         the parsed file, or an error that names it
  peripherals(root)  the peripherals in file order with their group and whether they have a readAction
  interrupts(root)   the <interrupt> elements in file order

What a generator makes of them (which group sizes are valid, which interrupt numbers are allowed) is its
own rule; this module only reads.
"""
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


def load(path: Path, *, error: type[GenError] = InputError) -> ET.Element:
    """The root element of the SVD <path>; a file that cannot be read or is no XML raises `error`."""
    try:
        return ET.parse(path).getroot()
    except (OSError, ET.ParseError) as err:
        raise error(f"{path}: cannot read the SVD ({err})") from err


def peripherals(root: ET.Element) -> list[Peripheral]:
    """The peripherals of the SVD in file order. <groupName> and the registers are resolved through
    derivedFrom the way svd2ada does (a derived peripheral inherits them from its base)."""
    elements = {p.findtext("name"): p for p in root.iter("peripheral")}

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
