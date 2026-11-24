# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""One reader of the merged SVD (build/svd/PolarfireSoC.svd) for the generators.

  load(path)         the parsed file, or an error that names it
  ensure(root)       the merged SVD of the repository at <root>, rebuilt first if it is stale
  peripherals(root)  the peripherals in file order with their group and whether they have a readAction
  interrupts(root)   the <interrupt> elements in file order
  registers(root)    the registers of each peripheral with their size and the layout of their fields
  blocks(root)       where each peripheral lies: its base, the bytes its registers span, their offsets
                     and the step of each register array
  register_map(root) the registers by absolute address: peripheral, package, name and size

What a generator makes of them (which group sizes are valid, which interrupt numbers are allowed) is its
own rule; this module only reads.
"""
import dataclasses
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


@dataclass(frozen=True, slots=True)
class Block:
    """Where a peripheral of the SVD lies: its base address, the bytes its registers span from the base (to
    the end of the register that ends highest), the offset of each register by name and, for a register
    array (<dim>), the bytes from one element to the next (<dimIncrement>) by name."""
    base: int
    span: int
    offsets: dict[str, int]
    steps: dict[str, int] = dataclasses.field(default_factory=dict)


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


def blocks(root: ET.Element) -> dict[str, Block]:
    """The peripherals of the SVD with a readable <baseAddress> by name, each with its base, the bytes its
    registers span (a <dim> array counted with all its elements, a register of <size> bits taking size / 8
    bytes; 0 for a peripheral without registers) and the offset of each register. A derived peripheral has
    the registers of its base when it has none of its own, at its own base."""
    regs = registers(root)
    elements = {p.findtext("name") or "": p for p in root.iter("peripheral")}

    def own(name: str, seen: tuple[str, ...] = ()) -> ET.Element:
        elt = elements[name]
        base = elt.get("derivedFrom")
        if elt.find("registers") is None and base in elements and base not in seen:
            return own(base, seen + (name,))
        return elt

    def number(text: str | None) -> int | None:
        try:
            return int(text.strip(), 0) if text else None
        except ValueError:
            return None

    result: dict[str, Block] = {}
    for name, elt in elements.items():
        base = number(elt.findtext("baseAddress"))
        if base is None:
            continue
        offsets: dict[str, int] = {}
        steps: dict[str, int] = {}
        span = 0
        for reg in own(name).iter("register"):
            reg_name = (reg.findtext("name") or "").strip()
            offset = number(reg.findtext("addressOffset"))
            if offset is None:
                continue
            offsets[reg_name] = offset
            count = number(reg.findtext("dim")) or 1
            step = number(reg.findtext("dimIncrement")) or 0
            if count > 1:
                steps[reg_name] = step
            size = regs[(name, reg_name)].size if (name, reg_name) in regs else 32
            span = max(span, offset + (count - 1) * step + size // 8)
        result[name] = Block(base, span, offsets, steps)
    return result


@dataclass(frozen=True, slots=True)
class RegisterAt:
    """The register at an absolute address: its peripheral (the object of the register package is
    <peripheral>_Periph), the group that names the package, its name and size in bits, and whether it is an
    element of a <dim> array (the component is then an array and <name> is the name of the array)."""
    peripheral: str
    group: str
    name: str
    size: int
    array: bool


def register_map(root: ET.Element) -> dict[int, RegisterAt]:
    """Every register of the SVD by its absolute address (base address of the peripheral + offset, the elements
    of a <dim> array each at their own). A derived peripheral has the registers of its base. Two registers at one
    address (an alias) keep the first."""
    elements = {p.findtext("name") or "": p for p in root.iter("peripheral")}
    groups = {p.name: p.group for p in peripherals(root)}

    def number(text: str | None, default: int = 0) -> int:
        try:
            return int(text.strip(), 0) if text and text.strip() else default
        except ValueError:
            return default

    def source(name: str, seen: tuple[str, ...] = ()) -> ET.Element:
        elt = elements[name]
        base = elt.get("derivedFrom")
        if elt.find("registers") is None and base in elements and base not in seen:
            return source(base, seen + (name,))
        return elt

    device_size = number(root.findtext("size"), 32)
    result: dict[int, RegisterAt] = {}
    for name, elt in elements.items():
        origin = source(name)
        base_address = number(elt.findtext("baseAddress"))
        size = number(origin.findtext("size"), device_size)
        for reg in origin.iter("register"):
            reg_name = (reg.findtext("name") or "").strip()
            reg_size = number(reg.findtext("size"), size)
            offset = number(reg.findtext("addressOffset"))
            dim = number(reg.findtext("dim"), 0)
            if dim:
                step = number(reg.findtext("dimIncrement"))
                for i in range(dim):
                    result.setdefault(base_address + offset + i * step,
                                      RegisterAt(name, groups[name], reg_name.replace("%s", ""), reg_size, True))
            else:
                result.setdefault(base_address + offset, RegisterAt(name, groups[name], reg_name, reg_size, False))
    return result
