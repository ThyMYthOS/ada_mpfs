# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @req GEN-003, GEN-004
"""The reader of the MSS Configurator XML: the file that Libero's MSS Configurator writes for a design.

  read(path, svd)  the MssConfiguration of the file, or ConfiguratorXmlError with every diagnostic
  svd_layout(path) the registers of a merged SVD (read once per path)
  svd_blocks(path) the peripherals of a merged SVD at their addresses (read once per path)

The order: the bytes are read and hashed (SHA-256), a document type or entity declaration is refused
(GEN-E041) before the parser sees the file, ElementTree parses it (GEN-E040), and xml_format_version must
be one of FORMAT_VERSIONS (GEN-E042); a file that fails one of these is not looked at further. Then every
section is checked, also those that are only validated (DDR, the SGMII and DDR PLLs, the high-speed IO):
each register and field once, numbers of their form, fields inside their register and apart, values that
fit their field as the XML states it and, in the core sections, as the SVD states it. Only the core
sections (CORE) become the model; a core section or a register that the generator needs (NEEDED) must be
there.

A register's value is what Microchip's generator (mpfs_configuration_generator.py) makes of it: the RW
fields shifted to their offsets and added; fields of other types are not part of it. The two sections
mss_clocks/clocks and mss_memory_map/nvm_map are decimal; elsewhere a value has 0x. Microchip's generator
reads a bare number as hex in every section: a bare number of the hex sections is taken only where hex
and decimal agree (0 to 9), any other is ambiguous (GEN-E047).

The layout of a field is checked against the field of the same name in the SVD, the source of the PAC as
well (svd_place() says which register of the SVD that is). The SVD has no layout for the values that the
configurator keeps for the software only (the clock rates, the PMP CSRs, the L2 settings, apb_split
except APBBUS_CR, the memory elements), nor for the few registers that it does not describe yet (the
multiplexers of sgmii_cfm, IMIRROR_TRIM): those are checked against their own declaration only. So are the
sections that are only validated: nothing writes them, and a design that does not use them carries what
the configurator puts there by default (a design without DDR has 0x4 in the one-bit CFG_DATA_MASK).

A value that breaks the width of its field is an error, unless it is a known defect of the configurator
(KNOWN_DEFECTS); then the reader keeps the field as written, takes the value of the register by the rule of
Microchip's generator and names the defect on the register.
"""
import hashlib
import re
from functools import lru_cache
from itertools import pairwise
from pathlib import Path
from xml.etree import ElementTree as ET

from gen_ada import svdread

from . import target
from .checks import ConfiguratorXmlError, Diagnostic, diagnostic
from .model import BitField, Design, MemElement, MssConfiguration, XmlField, XmlRegister

FORMAT_VERSIONS = ("0.6.5", "0.6.8")

# The sections whose values are decimal (Microchip's generator writes them back as decimal).
DECIMAL_SECTIONS = frozenset({"mss_clocks/clocks", "mss_memory_map/nvm_map"})
MEM_ELEMENTS = "mss_memory_map/map/mem_elements"

# The masters of the MPUs: the name of the section (mpu_<name>) and the name in the registers of MPUCFG
# (PMPCFG_<NAME>_<n>). How many entries each has comes from the SVD.
MPU_MASTERS = {"fic0": "FIC0", "fic1": "FIC1", "fic2": "FIC2", "crypto": "CRYPTO", "gem0": "ETHERNET0",
               "gem1": "ETHERNET1", "usb": "USB", "mmc": "MMC", "scb": "SCB", "trace": "TRACE"}

_IO_MUX = (tuple(f"IOMUX{i}_CR" for i in range(7))
           + ("MSSIO_BANK4_CFG_CR",) + tuple(f"MSSIO_BANK4_IO_CFG_{i}_{i + 1}_CR" for i in range(0, 14, 2))
           + ("MSSIO_BANK2_CFG_CR",) + tuple(f"MSSIO_BANK2_IO_CFG_{i}_{i + 1}_CR" for i in range(0, 24, 2))
           + ("MSSIO_VB2_CFG", "MSSIO_VB4_CFG", "GPIO_INTERRUPT_FAB_CR"))
_PLL = ("PLL_CTRL", "PLL_REF_FB", "PLL_FRACN", "PLL_DIV_0_1", "PLL_DIV_2_3", "PLL_CTRL2", "PLL_CAL", "PLL_PHADJ",
        "SSCG_REG_0", "SSCG_REG_1", "SSCG_REG_2", "SSCG_REG_3")
_WAY_MASKS = ("DMA", "AXI4_PORT_0", "AXI4_PORT_1", "AXI4_PORT_2", "AXI4_PORT_3", "E51_DCACHE", "E51_ICACHE",
              "U54_1_DCACHE", "U54_1_ICACHE", "U54_2_DCACHE", "U54_2_ICACHE", "U54_3_DCACHE", "U54_3_ICACHE",
              "U54_4_DCACHE", "U54_4_ICACHE")

# The core sections and the registers of each that the generator needs (the MPU sections get theirs from
# the SVD, see needed()). A core section may have more registers; they are read as well.
NEEDED: dict[str, tuple[str, ...]] = {
    "mss_clocks/clocks": ("MSS_EXT_SGMII_REF_CLK", "MSS_COREPLEX_CPU_CLK", "MSS_SYSTEM_CLK", "MSS_RTC_TOGGLE_CLK",
                          "MSS_AXI_CLK", "MSS_APB_AHB_CLK"),
    "mss_clocks/mss_sys": ("CLOCK_CONFIG_CR", "RTC_CLOCK_CR", "ENVM_CR"),
    "mss_clocks/mss_pll": _PLL,
    "mss_clocks/mss_cfm": ("BCLKMUX", "PLL_CKMUX", "MSSCLKMUX", "FMETER_ADDR", "FMETER_DATAW"),
    "mss_clocks/sgmii_cfm": ("REFCLKMUX", "SGMII_CLKMUX", "CLK_XCVR"),
    "mss_io/io_mux": _IO_MUX,
    "mss_io/io_mux_alt": tuple("ALT_" + name for name in _IO_MUX),
    "mss_memory_map/apb_split": ("MEM_CONFIGS_ENABLED", "APBBUS_CR", "CONTEXT_A_EN", "CONTEXT_B_EN",
                                 "CONTEXT_A_HART_EN", "CONTEXT_B_HART_EN"),
    "mss_memory_map/cache": ("WAY_ENABLE", "NUM_SCRATCH_PAD_WAYS") + tuple("WAY_MASK_" + m for m in _WAY_MASKS),
    "mss_memory_map/nvm_map": ("SNVM_MSS_START_PAGE", "SNVM_MSS_END_PAGE", "ENVM_MSS_START_PAGE",
                               "ENVM_MSS_END_PAGE"),
    **{f"mss_memory_map/pmp_h{hart}": ("CSR_PMPCFG0", "CSR_PMPCFG2") + tuple(f"CSR_PMPADDR{i}" for i in range(16))
       for hart in range(target.NUMBER_OF_HARTS)},
    **{f"mss_memory_map/mpu_{master}": () for master in MPU_MASTERS},
    "mss_general/mss_peripherals": ("GPIO_CR", "CONFIGURED_PERIPHERALS"),
    "mss_sgmii/tip": ("SGMII_MODE", "PLL_CNTL", "CH0_CNTL", "CH1_CNTL", "RECAL_CNTL", "CLK_CNTL", "SPARE_CNTL"),
    "mss_ddr/mode": ("DDRPHY_MODE",),
    "mss_ddr/off_mode": ("DDRPHY_MODE_OFF",),
}
CORE = tuple(NEEDED) + (MEM_ELEMENTS,)

# Values that break the width of their field in the configurator's own output, with what is known about
# them: (section, register, field, value) -> the defect. The register keeps the value of Microchip's
# generator (the fields shifted and added) and carries the text as its defect.
KNOWN_DEFECTS: dict[tuple[str, str, str, int], str] = {
    ("mss_clocks/mss_pll", "PLL_PHADJ", "REG_OUT3_PHSINIT", 0x8):
        "REG_OUT3_PHSINIT is 3 bits wide in the XML and in the SVD and holds 0x8; shifted to its offset 11 "
        "it sets bit 14, REG_LOADPHS_B, which the XML gives as 0. The register takes Microchip's sum, "
        "0x4003: all four phases 0 and REG_LOADPHS_B 1, the form of PLL_PHADJ of the SGMII and DDR PLLs and "
        "the value hw/mss_init.py writes on the board. Reported to Microchip "
        "(polarfire-soc/polarfire-soc-documentation#610), not answered",
    **{("mss_memory_map/apb_split", "MEM_CONFIGS_ENABLED", flag, 1):
       f"{flag} is declared with width 0 in every XML at hand and holds 1 when the configurator enables the "
       f"{flag} tables (Microchip's PMP demo has 0x1 in both); Microchip's generator ignores the width and "
       "shifts the value to its offset: PMP is bit 0 and MPU bit 1, PMP_ENABLED_MASK 1 and MPU_ENABLED_MASK 2 "
       "of Microchip's mss_pmp.h:26-27 @ 8d52d59"
       for flag in ("PMP", "MPU")},
}

_DOCTYPE = re.compile(rb"<!\s*(DOCTYPE|ENTITY)")
_HEX = re.compile(r"0[xX][0-9a-fA-F]+")
_DECIMAL = re.compile(r"0|[1-9][0-9]*")
_DIGITS = re.compile(r"[0-9]+")


@lru_cache(maxsize=4)
def svd_layout(path: Path) -> dict[tuple[str, str], svdread.Register]:
    """The registers of the merged SVD at <path> (svdread.registers), read once per path."""
    return svdread.registers(svdread.load(path))


@lru_cache(maxsize=4)
def svd_blocks(path: Path) -> dict[str, svdread.Block]:
    """The peripherals of the merged SVD at <path> at their addresses (svdread.blocks), read once per path."""
    return svdread.blocks(svdread.load(path))


def svd_place(section: str, name: str) -> tuple[tuple[str, str], ...]:
    """The registers of the SVD (peripheral, register) that may have the layout of a register of the
    XML, in the order to look them up; none if the section has no counterpart in the SVD.

    The three PLLs share one layout, which the SVD has for the PLL in CFG_DDR_SGMII_PHY (<name>_MAIN);
    the multiplexers of mss_cfm and the SGMII and DDR PHY registers are in CFG_DDR_SGMII_PHY under their
    own names, the register of the DDR off mode under the name of the register it is a value of; the IO
    registers in SYSREG or, where SYSREG has no such name, SCB_REGS; io_mux_alt are the same registers
    (ALT_ is the alternative set of the configurator); the MPU entries are PMPCFG_<MASTER>_<n> of MPUCFG.
    The caller takes the first that the SVD has; none means that there is no layout."""
    group, _, leaf = section.rpartition("/")
    if leaf in ("mss_pll", "sgmii_pll", "ddr_pll"):
        return (("CFG_DDR_SGMII_PHY", "SOFT_RESET_MAIN_PLL" if name == "SOFT_RESET" else name + "_MAIN"),)
    if leaf in ("mss_cfm", "tip", "mode", "io_bank"):
        return (("CFG_DDR_SGMII_PHY", name),)
    if leaf == "off_mode":
        renamed = {"DDRPHY_MODE_OFF": "DDRPHY_MODE", "DPC_BITS_OFF_MODE": "DPC_BITS"}.get(name, name)
        return (("CFG_DDR_SGMII_PHY", renamed),)
    if leaf in ("mss_sys", "apb_split", "mss_peripherals"):
        return (("SYSREG", name),)
    if leaf in ("io_mux", "io_mux_alt"):
        plain = name.removeprefix("ALT_") if leaf == "io_mux_alt" else name
        return (("SYSREG", plain), ("SCB_REGS", plain))
    if leaf.startswith("mpu_") and leaf[4:] in MPU_MASTERS and name.startswith("MPU_CFG_PMP"):
        return (("MPUCFG", f"PMPCFG_{MPU_MASTERS[leaf[4:]]}_{name.removeprefix('MPU_CFG_PMP')}"),)
    if group == "mss_ddr" and leaf == "ddrc":
        return (("DDR_CSR_APB", name),)
    return ()


def needed(section: str, svd: dict[tuple[str, str], svdread.Register]) -> tuple[str, ...]:
    """The registers of a core section that the generator needs; for an MPU, one entry per PMPCFG
    register of its master in the SVD."""
    leaf = section.rpartition("/")[2]
    if leaf.startswith("mpu_"):
        prefix = f"PMPCFG_{MPU_MASTERS[leaf[4:]]}_"
        count = sum(1 for (peripheral, name) in svd if peripheral == "MPUCFG" and name.startswith(prefix)
                    and name[len(prefix):].isdigit())
        return tuple(f"MPU_CFG_PMP{i}" for i in range(count))
    return NEEDED.get(section, ())


def _number(text: str, decimal: bool) -> int | None:
    """The value of a number of the XML, None if it does not have the form of its section."""
    if _HEX.fullmatch(text):
        return int(text, 16)
    if decimal:
        return int(text) if _DECIMAL.fullmatch(text) else None
    if _DIGITS.fullmatch(text) and int(text, 10) == int(text, 16):
        return int(text)
    return None


def _sections(root: ET.Element) -> list[tuple[str, ET.Element]]:
    """Every element below the root that holds <registers> or is mem_elements, as (path, element)."""
    found: list[tuple[str, ET.Element]] = []

    def walk(element: ET.Element, path: tuple[str, ...]) -> None:
        for child in element:
            if child.tag == "registers":
                found.append(("/".join(path), child))
            elif child.tag == "mem_elements":
                found.append(("/".join(path + (child.tag,)), child))
            elif child.tag != "design_information":
                walk(child, path + (child.tag,))
    walk(root, ())
    return found


class _Reader:
    def __init__(self, svd: dict[tuple[str, str], svdread.Register]):
        self.svd = svd
        self.found: list[Diagnostic] = []

    def report(self, code: str, path: str, message: str) -> None:
        self.found.append(diagnostic(code, path, message))

    def register(self, section: str, element: ET.Element) -> XmlRegister | None:
        name = element.get("name")
        if not name:
            self.report("GEN-E040", section, "a <register> without a name")
            return None
        at = f"{section}/{name}"
        # only the core sections are written: the others are checked against their own declaration
        place = next((p for p in svd_place(section, name) if p in self.svd), None) if section in CORE else None
        svd = self.svd[place] if place else None
        leaf = section.rpartition("/")[2]
        size = svd.size if svd else (64 if leaf.startswith(("pmp_h", "mpu_")) else 32)
        decimal = section in DECIMAL_SECTIONS
        fields: list[XmlField] = []
        seen: set[str] = set()
        defect = None
        for item in element:
            if item.tag != "field":
                self.report("GEN-E040", at, f"<{item.tag}> in a register (only <field>)")
                continue
            fname = item.get("name")
            if not fname:
                self.report("GEN-E040", at, "a <field> without a name")
                continue
            where = f"{at}.{fname}"
            if fname in seen:
                self.report("GEN-E046", where, f"{fname} is given twice")
                continue
            seen.add(fname)
            offset_text, width_text = item.get("offset", ""), item.get("width", "")
            if not _DIGITS.fullmatch(offset_text) or not _DIGITS.fullmatch(width_text):
                self.report("GEN-E047", where, f"offset {offset_text!r} and width {width_text!r} must be decimal digits")
                continue
            bits = BitField(int(offset_text), int(width_text))
            access = item.get("Type", "")
            value = None
            if access == "RW":
                text = (item.text or "").strip()
                value = _number(text, decimal)
                if value is None:
                    form = "decimal digits or 0x and hex digits" if decimal else "0x and hex digits"
                    self.report("GEN-E047", where, f"{text!r} is not a number of the form {form}")
                    continue
            if bits.offset + bits.width > size:
                self.report("GEN-E048", where,
                            f"bits {bits.offset} to {bits.offset + bits.width - 1} are beyond the {size} bits of {name}")
            layout = svd.fields.get(fname) if svd else None
            svd_bits = BitField(layout.offset, layout.width) if layout else None
            svd_name = f"{place[0]}.{place[1]}" if svd and place else None
            if svd_bits and svd_bits.offset != bits.offset:
                self.report("GEN-E051", where, f"offset {bits.offset} in the XML, {svd_bits.offset} in the SVD ({svd_name})")
            if value is not None:
                known = KNOWN_DEFECTS.get((section, name, fname, value))
                if known:
                    defect = f"{fname} = {value:#x}: {known}"
                elif value >> bits.width:
                    self.report("GEN-E050", where, f"{value:#x} does not fit the {bits.width} bits of the field")
                elif svd_bits and value >> svd_bits.width:
                    self.report("GEN-E052", where,
                                f"{value:#x} does not fit the {svd_bits.width} bits of {fname} in the SVD ({svd_name})")
            fields.append(XmlField(fname, bits, access, value, svd_bits))
        ordered = sorted((f for f in fields if f.bits.width), key=lambda f: f.bits.offset)
        for low, high in pairwise(ordered):
            if low.bits.offset + low.bits.width > high.bits.offset:
                self.report("GEN-E049", f"{at}.{high.name}",
                            f"bits {high.bits.offset} on overlap {low.name} (bits {low.bits.offset} to "
                            f"{low.bits.offset + low.bits.width - 1})")
        total = sum(f.value << f.bits.offset for f in fields if f.value is not None)
        return XmlRegister(section, name, size, tuple(fields), total,
                           f"{place[0]}.{place[1]}" if svd and place else None, defect)

    def mem_element(self, element: ET.Element) -> MemElement | None:
        name = element.get("name")
        if element.tag != "mem" or not name:
            self.report("GEN-E040", MEM_ELEMENTS, f"<{element.tag}> without a name (only named <mem>)")
            return None
        address = _number((element.text or "").strip(), decimal=True)
        size = _number(element.get("size", ""), decimal=True)
        if address is None or size is None:
            self.report("GEN-E047", f"{MEM_ELEMENTS}/{name}",
                        f"address {(element.text or '').strip()!r} and size {element.get('size')!r} must be numbers")
            return None
        return MemElement(name, address, size, element.get("description", ""))


def read(path: Path, svd: Path, *, name: str | None = None) -> MssConfiguration:
    """The MSS Configurator XML at <path>, checked against the merged SVD <svd>. <name> is the file name
    in the messages and the model (default: the path as given)."""
    where = name or str(path)

    def fail(code: str, message: str, at: str = "") -> ConfiguratorXmlError:
        return ConfiguratorXmlError(where, [diagnostic(code, at, message)])

    try:
        data = path.read_bytes()
    except OSError as err:
        raise fail("GEN-E040", f"cannot read the file ({err.strerror or err})") from err
    digest = hashlib.sha256(data).hexdigest()
    if _DOCTYPE.search(data):
        raise fail("GEN-E041", "the reader refuses a <!DOCTYPE> or <!ENTITY> declaration")
    try:
        root = ET.fromstring(data)
    except ET.ParseError as err:
        raise fail("GEN-E040", f"not well-formed XML ({err})") from err
    if root.tag != "mss":
        raise fail("GEN-E040", f"the root element is <{root.tag}>, not <mss>")
    info = root.find("design_information")
    version = (root.findtext("design_information/xml_format_version") or "").strip()
    if version not in FORMAT_VERSIONS:
        raise fail("GEN-E042", f"{version or 'no version'} is not one of {', '.join(FORMAT_VERSIONS)}",
                   "design_information/xml_format_version")

    reader = _Reader(svd_layout(svd))
    registers: list[XmlRegister] = []
    mems: list[MemElement] = []
    validated: list[str] = []
    present: set[str] = set()
    for section, element in _sections(root):
        if section in present:
            reader.report("GEN-E045", section, "the section is given twice")
            continue
        present.add(section)
        names: set[str] = set()
        for item in element:
            item_name = item.get("name", "")
            if item_name and item_name in names:
                reader.report("GEN-E045", f"{section}/{item_name}", f"{item_name} is given twice")
                continue
            names.add(item_name)
            if section == MEM_ELEMENTS:
                mem = reader.mem_element(item)
                if mem:
                    mems.append(mem)
                continue
            if item.tag != "register":
                reader.report("GEN-E040", section, f"<{item.tag}> in <registers> (only <register>)")
                continue
            reg = reader.register(section, item)
            if reg and section in NEEDED:
                registers.append(reg)
        if section not in CORE:
            validated.append(section)
        else:
            for needed_name in needed(section, reader.svd):
                if needed_name not in names:
                    reader.report("GEN-E044", f"{section}/{needed_name}", f"{section} has no register {needed_name}")
    for section in CORE:
        if section not in present:
            reader.report("GEN-E043", section, f"the XML has no section {section}")
    if reader.found:
        raise ConfiguratorXmlError(where, reader.found)

    def info_text(tag: str) -> str:
        return (info.findtext(tag) or "").strip() if info is not None else ""

    design = Design(info_text("libero_version"), info_text("design_name"), info_text("mpfs_part_no"),
                    info_text("mpfs_package"), info_text("creation_date_time"), version)
    return MssConfiguration(where, digest, design, tuple(registers), tuple(mems), tuple(validated))
