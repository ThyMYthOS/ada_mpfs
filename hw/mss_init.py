# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# @req HW-002
"""What the first-stage boot software does to the MSS of the PolarFire SoC before the clock switch.

Boot mode 0 leaves the MSS as the reset left it: the RTC reference clock is not set up, so CLINT.MTIME does not
count, and the SGMII/DDR PHY block is not reachable. Microchip's boot software (HSS, the mpfs_hal of the platform
repository: mss_nwc_init.c, mss_sgmii.c, mss_pll.c) sets this up. This module holds the same register writes as data
and runs them through a write and a read function of the caller. It writes 32-bit words only.

The sequence is kept here: the order of the steps, the read-modify-writes, polls, delays and the test of the silicon
revision, and the values that no MSS Configurator XML has (the SCB access timer, DFIAPB_CR, the MSSIO handshake, the
dynamic enables, the soft resets and releases, the poll masks). Every value that the XML has comes from the XML of
the board (Values, which load() reads with the reader of config/gen/mpfs_gen): the RTC period, the IO mux and bank
set-up, the SGMII channel registers, and the MSS PLL and its multiplexers. There is no default XML.

Two sequences:

  refclk(values)  what CLINT.MTIME needs, the smallest set found on the board (2026-10-23, boot mode 0, MPFS250T):
                  the RTC divisor for the 125 MHz reference, the SCB access timer, the DFI/APB clock, MSS_IO_EN and
                  the clock receiver of the reference (CFG_DDR_SGMII_PHY.CLK_CNTL). Used by
                  `svd_probe.py --enable-clocks` and `./x hw initialize --minimal`.
  full(values)    the whole of mss_nwc_init up to, but excluding, the clock switch: the reference clock and the
                  dynamic enables, the IO mux and bank set-up, the MSSIO handshake, the SGMII channel set-up (reset,
                  calibration, PLL and DLL lock), and the MSS PLL up to its lock. Not done: ENVM_CR, CLOCK_CONFIG_CR
                  and MSSCLKMUX (the switch of the MSS to the PLL), the DDR set-up, and the two nw_config writes to
                  the GEM blocks (the vendor header addresses them at 0x20110008, a read-only register, so they have
                  no effect there). `./x hw initialize` runs it.

The sequence does not change what the examples see of the clocks: the CPU stays on the boot clock, so the UART
divisor of --uart-standin stays right.
"""
from __future__ import annotations

import sys
import time
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from mpfs_gen.model import MssConfiguration

ROOT = Path(__file__).resolve().parent.parent

SYSREG = 0x20002000
SCB_REGS = 0x20003000
PHY = 0x20007000                  # CFG_DDR_SGMII_PHY
IOSCBCFG = 0x37080000
PLL_MSS, PLL_DDR, PLL_SGMII = 0x3E001000, 0x3E010000, 0x3E080000
MUX_MSS, MUX_SGMII = 0x3E002000, 0x3E200000
BANK_CNTL_SGMII, DLL_SGMII = 0x3E400000, 0x3E100000
LANE01, LANE23 = 0x36500000, 0x36510000
IO_CALIB_SGMII = 0x3E800000

RTC_CLOCK_CR = SYSREG + 0x00C
DFIAPB_CR = SYSREG + 0x098
SUBBLK_CLOCK_CR = SYSREG + 0x084
SOFT_RESET_CR = SYSREG + 0x088
MSS_RESET_CR = SCB_REGS + 0x100
MSSIO_CONTROL_CR = SCB_REGS + 0x1BC
IOSCBCFG_TIMER = IOSCBCFG + 0x008
SOFT_RESET_SGMII = PHY + 0xC00
SGMII_MODE, PLL_CNTL, CH0_CNTL, CH1_CNTL = PHY + 0xC04, PHY + 0xC08, PHY + 0xC0C, PHY + 0xC10
RECAL_CNTL, CLK_CNTL, DYN_CNTL, PVT_STAT = PHY + 0xC14, PHY + 0xC18, PHY + 0xC1C, PHY + 0xC20
SPARE_CNTL, SPARE_STAT = PHY + 0xC24, PHY + 0xC28
DDRPHY_STARTUP = PHY + 0x008

SCB_ACCESS_CONFIG = 0x80 | (160 << 8) | (8 << 16)
RTC_ENABLE = 1 << 16              # SYSREG.RTC_CLOCK_CR.ENABLE; the XML value is the period alone
REG_CDR_MOVE_STEP = 1 << 22       # CFG_DDR_SGMII_PHY.SGMII_MODE
TX_RX_CH_EN = 0xF << 4            # CFG_DDR_SGMII_PHY.SGMII_MODE: the TX and RX channels (mss_sgmii.h)
REG_POWERDOWN_B = 1 << 0          # PLL_CTRL of the MSS PLL

# The registers of the MSS Configurator XML that the sequences write, as section/name.
XML_RTC = "mss_clocks/mss_sys/RTC_CLOCK_CR"
XML_IO = "mss_io/io_mux"
XML_TIP = "mss_sgmii/tip"
XML_PLL = "mss_clocks/mss_pll"
XML_CFM = "mss_clocks/mss_cfm"
XML_SGMII_CFM = "mss_clocks/sgmii_cfm"
IOMUX = tuple(f"{XML_IO}/IOMUX{i}_CR" for i in range(7))
BANK4_IO = tuple(f"{XML_IO}/MSSIO_BANK4_IO_CFG_{i}_{i + 1}_CR" for i in range(0, 14, 2))
BANK2_IO = tuple(f"{XML_IO}/MSSIO_BANK2_IO_CFG_{i}_{i + 1}_CR" for i in range(0, 24, 2))
TIP = tuple(f"{XML_TIP}/{name}" for name in ("SGMII_MODE", "CH0_CNTL", "CH1_CNTL", "RECAL_CNTL", "CLK_CNTL",
                                              "SPARE_CNTL", "PLL_CNTL"))
# The registers of the MSS PLL that mss_pll_config (mss_pll.c) writes between the two writes of PLL_CTRL, in its
# order, with their offsets.
PLL_SETTINGS = ((0x08, "PLL_REF_FB"), (0x10, "PLL_DIV_0_1"), (0x14, "PLL_DIV_2_3"), (0x18, "PLL_CTRL2"),
                (0x0C, "PLL_FRACN"), (0x24, "SSCG_REG_0"), (0x28, "SSCG_REG_1"), (0x2C, "SSCG_REG_2"),
                (0x30, "SSCG_REG_3"), (0x20, "PLL_PHADJ"))
XML_REGISTERS: tuple[str, ...] = (
    (XML_RTC, *IOMUX, *BANK4_IO, *BANK2_IO, f"{XML_IO}/MSSIO_BANK2_CFG_CR", f"{XML_IO}/MSSIO_BANK4_CFG_CR", *TIP,
     f"{XML_PLL}/PLL_CTRL")
    + tuple(f"{XML_PLL}/{name}" for _, name in PLL_SETTINGS)
    + tuple(f"{XML_CFM}/{name}" for name in ("PLL_CKMUX", "BCLKMUX", "FMETER_ADDR", "FMETER_DATAW"))
    + (f"{XML_SGMII_CFM}/CLK_XCVR",))


@dataclass(frozen=True)
class Values:
    """The values of the MSS Configurator XML of the board that the sequences write.

    <registers> maps section/name (each of XML_REGISTERS) to the value that the reader gives the register; <source>
    is the file as the messages name it, <sha256> the SHA-256 of its bytes, <design> one line on its design, <defects>
    the known defects of the configurator in these registers (section/name: what the reader says about it)."""
    source: str
    sha256: str
    design: str
    registers: Mapping[str, int]
    defects: Mapping[str, str] = field(default_factory=dict)

    def __getitem__(self, register: str) -> int:
        return self.registers[register]


class XmlError(Exception):
    """The XML cannot be used: the reader rejects it, or the merged SVD is missing; the text says why."""


def values_of(config: MssConfiguration) -> Values:
    """The Values of an MSS Configurator XML that the reader has read."""
    registers: dict[str, int] = {}
    defects: dict[str, str] = {}
    for path in XML_REGISTERS:
        section, _, name = path.rpartition("/")
        reg = config.register(section, name)
        registers[path] = reg.value
        if reg.defect:
            defects[path] = reg.defect
    d = config.design
    design = f"design {d.design_name}, Libero {d.libero_version}, part {d.part_number}, format {d.format_version}"
    return Values(config.source, config.sha256, design, registers, defects)


def shown(path: Path) -> str:
    """<path> relative to the repository root if it lies below it, else as given: the name in the messages."""
    try:
        return str(path.resolve().relative_to(ROOT))
    except ValueError:
        return str(path)


def load(xml: Path, svd: Path | None = None) -> Values:
    """The Values of the MSS Configurator XML <xml>, read by config/gen/mpfs_gen/xml_reader.py and checked against
    the merged SVD <svd> (None: build/svd/PolarfireSoC.svd, made current first by tools/svd.py ensure, which needs
    svdtools only if the file is missing or stale). XmlError with the reader's message if it cannot be used."""
    for path in (str(ROOT / "tools"), str(ROOT / "config" / "gen")):  # gen_ada, mpfs_gen
        if path not in sys.path:
            sys.path.insert(0, path)
    from gen_ada import svdread
    from gen_ada.errors import GenError
    from mpfs_gen import xml_reader
    from mpfs_gen.checks import DiagnosticError
    try:
        merged = svd if svd is not None else svdread.ensure(ROOT)
        if not merged.is_file():
            raise XmlError(f"{merged}: the merged SVD does not exist (./x svd merge)")
        return values_of(xml_reader.read(xml, merged, name=shown(xml)))
    except (DiagnosticError, GenError) as err:
        raise XmlError(str(err)) from err


def header(values: Values, steps: Iterable[Step] = ()) -> list[str]:
    """The lines that name the XML the values come from, for a dry run and the log, and a note on each known defect
    of the configurator in a register that <steps> write."""
    written = {step.xml for step in steps if isinstance(step, Write)}
    return ([f"# MSS Configurator XML {values.source} sha256 {values.sha256}", f"# {values.design}"]
            + [f"# note: {path}: known defect of the configurator: {text}"
               for path, text in values.defects.items() if path in written])


@dataclass(frozen=True)
class Write:
    """Write <value> to <address>. <xml> names the register of the MSS Configurator XML (section/name) that the
    value comes from, or is derived from as <what> says; empty for a value of the sequence itself."""
    address: int
    value: int
    what: str
    xml: str = ""


@dataclass(frozen=True)
class Modify:
    """Read the word, set the bits of <set>, clear the bits of <clear>, write it back."""
    address: int
    set: int
    clear: int
    what: str


@dataclass(frozen=True)
class Poll:
    """Read until (word & mask) == want; MSS_INIT_TIMEOUT error after <timeout> seconds."""
    address: int
    mask: int
    want: int
    what: str
    timeout: float = 2.0


@dataclass(frozen=True)
class Delay:
    seconds: float
    what: str = ""


@dataclass(frozen=True)
class IfSet:
    """Run <then> only if (word & mask) != 0 (silicon variant: SPARE_STAT bit 31 is set from rev C on)."""
    address: int
    mask: int
    what: str
    then: tuple[Step, ...] = field(default_factory=tuple)


Step = Write | Modify | Poll | Delay | IfSet


class MssInitError(Exception):
    """A step failed: a poll ran out of time, or the access itself failed."""


def _xml(values: Values, address: int, register: str, what: str) -> Write:
    """The write of the XML value of <register> (section/name) to <address>."""
    return Write(address, values[register], what, register)


def _rtc(values: Values, tag: str) -> list[Step]:
    period = values[XML_RTC]
    return [Write(RTC_CLOCK_CR, period, f"RTC divisor {tag}: period {period}, clock off", XML_RTC),
            Write(RTC_CLOCK_CR, period | RTC_ENABLE, "RTC clock on (ENABLE, bit 16)", XML_RTC)]


def refclk(values: Values) -> tuple[Step, ...]:
    """What CLINT.MTIME needs: the RTC divisor and the reference clock."""
    return (*_rtc(values, "(reference 125 MHz)"),
            Write(IOSCBCFG_TIMER, SCB_ACCESS_CONFIG, "IOSCBCFG.TIMER: SCB access timing"),
            Write(DFIAPB_CR, 0x1, "SYSREG.DFIAPB_CR: DFI/APB clock on, reset released"),
            Write(MSSIO_CONTROL_CR, 0x3800, "SCB_REGS.MSSIO_CONTROL_CR: CORE_UP, FLASH_VALID, MSS_IO_EN"),
            _xml(values, CLK_CNTL, f"{XML_TIP}/CLK_CNTL", "CFG_DDR_SGMII_PHY.CLK_CNTL: clock receiver of the reference"))


def _io_setup(values: Values) -> list[Step]:
    def leaf(register: str) -> str:
        return register.rpartition("/")[2]
    steps: list[Step] = [_xml(values, SYSREG + 0x200 + 4 * i, reg, f"SYSREG.{leaf(reg)}") for i, reg in enumerate(IOMUX)]
    steps += [_xml(values, SYSREG + 0x234 + 4 * i, reg, f"SYSREG.{leaf(reg)}") for i, reg in enumerate(BANK4_IO)]
    steps += [_xml(values, SYSREG + 0x254 + 4 * i, reg, f"SYSREG.{leaf(reg)}") for i, reg in enumerate(BANK2_IO)]
    steps += [_xml(values, SCB_REGS + 0x1C4, f"{XML_IO}/MSSIO_BANK2_CFG_CR", "SCB_REGS.MSSIO_BANK2_CFG_CR"),
              _xml(values, SCB_REGS + 0x1C8, f"{XML_IO}/MSSIO_BANK4_CFG_CR", "SCB_REGS.MSSIO_BANK4_CFG_CR")]
    return steps


def _mssio_handshake() -> list[Step]:
    return [Write(MSSIO_CONTROL_CR, 0x0F00, "MSSIO_CONTROL_CR: DCE 7, CORE_UP"), Delay(0.001),
            Write(MSSIO_CONTROL_CR, 0x0800, "DCE 0"), Delay(0.001),
            Write(MSSIO_CONTROL_CR, 0x1800, "FLASH_VALID"), Delay(0.001),
            Write(MSSIO_CONTROL_CR, 0x3800, "MSS_IO_EN")]


_LANE_RESET: tuple[Step, ...] = (Write(DYN_CNTL, 0x607F, "DYN_CNTL: lane 0 and 1 soft reset"),
                                 Write(DYN_CNTL, 0x007F, "DYN_CNTL: lanes released"))


def _sgmii_rpc(values: Values) -> list[Step]:
    """The soft reset of the SGMII TIP and setup_sgmii_rpc_per_config() of mss_sgmii.c."""
    mode = f"{XML_TIP}/SGMII_MODE"
    return [
        Write(SOFT_RESET_SGMII, 0x101, "SOFT_RESET_SGMII: PERIPH reset"), Write(SOFT_RESET_SGMII, 0x1, "SOFT_RESET_SGMII"),
        # setup_sgmii_rpc_per_config() of mss_sgmii.c writes LIBERO_SETTING_SGMII_MODE & ~REG_CDR_MOVE_STEP: the XML
        # value with REG_CDR_MOVE_STEP (bit 22) cleared, a bit that every reference XML sets.
        Write(SGMII_MODE, values[mode] & ~REG_CDR_MOVE_STEP,
              "SGMII_MODE (RPC), REG_CDR_MOVE_STEP (bit 22) cleared as mss_sgmii.c does", mode),
        _xml(values, CH0_CNTL, f"{XML_TIP}/CH0_CNTL", "CH0_CNTL (RPC)"),
        _xml(values, CH1_CNTL, f"{XML_TIP}/CH1_CNTL", "CH1_CNTL (RPC)"),
        _xml(values, RECAL_CNTL, f"{XML_TIP}/RECAL_CNTL", "RECAL_CNTL (RPC)"),
        _xml(values, CLK_CNTL, f"{XML_TIP}/CLK_CNTL", "CLK_CNTL (RPC)"),
        _xml(values, SPARE_CNTL, f"{XML_TIP}/SPARE_CNTL", "SPARE_CNTL (RPC)"),
        _xml(values, PLL_CNTL, f"{XML_TIP}/PLL_CNTL", "PLL_CNTL (RPC)"),
    ]


def sgmii_channels(values: Values) -> bool:
    """Whether the design uses an SGMII channel: the TX/RX channel enables of SGMII_MODE (bits 4 to 7)."""
    return bool(values[f"{XML_TIP}/SGMII_MODE"] & TX_RX_CH_EN)


def _sgmii(values: Values) -> list[Step]:
    # sgmii_setup() of mss_sgmii.c: without a TX or RX channel the SGMII block goes into its off mode
    # (sgmii_off_mode(), then sgmii_mux_config(RPC_REG_UPDATE)): the RPC registers, the soft reset of the DLL and
    # of the clock multiplexer, and no wait for the SGMII PLL, which does not lock in such a design.
    if not sgmii_channels(values):
        return [*_sgmii_rpc(values),
                Write(DLL_SGMII, 1, "IOSCB_DLL_SGMII.SOFT_RESET (off mode)"),
                Write(MUX_SGMII, 1, "IOSCB_MUX_SGMII.SOFT_RESET: load the clock registers (RPC_REG_UPDATE)")]
    # sgmii_channel_setup() of mss_sgmii.c: the channels are set up and the SGMII PLL and DLL must lock.
    return [
        *_sgmii_rpc(values),
        Write(BANK_CNTL_SGMII, 1, "IOSCB_BANK_CNTL_SGMII.SOFT_RESET: load the RPC registers"),
        Poll(PVT_STAT, 1 << 6, 1 << 6, "PVT_STAT.IOEN: the IO power detectors report"),
        Delay(0.001, "IO power ramp"),
        Write(MSS_RESET_CR, 0, "SCB_REGS.MSS_RESET_CR: release the SGMII block with the reference clock input"),
        Write(DLL_SGMII, 1, "IOSCB_DLL_SGMII.SOFT_RESET"),
        Write(LANE01, 1, "SGMIIPHY_LANE01.SOFT_RESET"), Write(LANE23, 1, "SGMIIPHY_LANE23.SOFT_RESET"),
        Write(DYN_CNTL, 0x047F, "DYN_CNTL: PVT soft reset"), Write(DYN_CNTL, 0x007F, "DYN_CNTL"),
        Write(IO_CALIB_SGMII, 1, "IOSCB_IO_CALIB_SGMII.SOFT_RESET_IOCALIB: start calibration"),
        Write(IO_CALIB_SGMII, 0, "released"),
        Poll(PVT_STAT, 1 << 14, 1 << 14, "PVT_STAT: calibration complete"),
        Modify(PVT_STAT, 0x40000000, 0, "PVT_STAT: assert calibration lock"),
        Modify(IO_CALIB_SGMII + 4, 1 << 14, 0, "IOC_REG0: calibration lock"),
        Write(MUX_SGMII, 1, "IOSCB_MUX_SGMII.SOFT_RESET: load the clock registers"),
        Write(PLL_SGMII, 1, "IOSCB_PLL_SGMII.SOFT_RESET: load PLL_CNTL"),
        Poll(PLL_CNTL, 1 << 7, 1 << 7, "PLL_CNTL: SGMII PLL locked"),
        Poll(RECAL_CNTL, 1 << 23, 1 << 23, "RECAL_CNTL: DLL locked"),
        Modify(SUBBLK_CLOCK_CR, 0x6, 0, "SUBBLK_CLOCK_CR: MAC0 and MAC1 clock on"),
        Modify(SOFT_RESET_CR, 0, 0x6, "SOFT_RESET_CR: MAC0 and MAC1 released"),
        *_LANE_RESET,
        IfSet(SPARE_STAT, 1 << 31, "rev C or later silicon: the lanes are reset a second time after 10 ms",
              (Delay(0.01, "10 ms"), *_LANE_RESET)),
    ]


def _pll(values: Values) -> list[Step]:
    ctrl = f"{XML_PLL}/PLL_CTRL"
    # mss_pll_config() of mss_pll.c: PLL_CTRL with REG_POWERDOWN_B cleared, the settings, the multiplexers, and
    # PLL_CTRL with REG_POWERDOWN_B set.
    steps: list[Step] = [Write(PLL_DDR, 3, "IOSCB_PLL_DDR.SOFT_RESET"), Write(PLL_MSS, 3, "IOSCB_PLL_MSS.SOFT_RESET"),
                         Write(PLL_MSS + 0x04, values[ctrl] & ~REG_POWERDOWN_B, "PLL_CTRL, powered down (bit 0 cleared)", ctrl)]
    steps += [_xml(values, PLL_MSS + off, f"{XML_PLL}/{name}", f"IOSCB_PLL_MSS.{name}") for off, name in PLL_SETTINGS]
    steps += [_xml(values, MUX_MSS + 0x08, f"{XML_CFM}/PLL_CKMUX", "IOSCB_MUX_MSS.PLL_CKMUX"),
              _xml(values, MUX_SGMII + 0x10, f"{XML_SGMII_CFM}/CLK_XCVR", "IOSCB_MUX_SGMII.CLK_XCVR"),
              _xml(values, MUX_MSS + 0x04, f"{XML_CFM}/BCLKMUX", "IOSCB_MUX_MSS.BCLKMUX"),
              _xml(values, MUX_MSS + 0x14, f"{XML_CFM}/FMETER_ADDR", "FMETER_ADDR"),
              _xml(values, MUX_MSS + 0x18, f"{XML_CFM}/FMETER_DATAW", "FMETER_DATAW"),
              Write(PLL_MSS + 0x04, values[ctrl] | REG_POWERDOWN_B, "PLL_CTRL, powered up (bit 0 set)", ctrl),
              Poll(PLL_MSS + 0x04, 1 << 25, 1 << 25, "PLL_CTRL.LOCK: MSS PLL locked", 5.0)]
    return steps


def full(values: Values, io: bool = True) -> tuple[Step, ...]:
    """The sequence of mss_nwc_init without the clock switch; <io> False leaves out the IO mux and bank set-up."""
    steps = [*_rtc(values, "(first)"),
             Write(IOSCBCFG_TIMER, SCB_ACCESS_CONFIG, "IOSCBCFG.TIMER: SCB access timing"),
             Write(DFIAPB_CR, 0x1, "SYSREG.DFIAPB_CR: DFI/APB clock on, reset released"),
             Write(DDRPHY_STARTUP, 0x003F1F00, "DDRPHY_STARTUP: dynamic enables"),
             Write(DYN_CNTL, 0x047F, "DYN_CNTL: dynamic enables")]
    if io:
        steps += _io_setup(values)
    steps += _mssio_handshake() + _sgmii(values) + _pll(values)
    return tuple(steps)


def describe(step: Step) -> str:
    """One line for a dry run and the log: the OpenOCD command, what it is for and the register of the XML."""
    if isinstance(step, Write):
        source = f" [xml {step.xml}]" if step.xml else ""
        return f"mww 0x{step.address:08X} 0x{step.value:08X}    ;# {step.what}{source}"
    if isinstance(step, Modify):
        return f"mdw 0x{step.address:08X}; mww with |0x{step.set:08X} &~0x{step.clear:08X}    ;# {step.what}"
    if isinstance(step, Poll):
        return f"mdw 0x{step.address:08X} until (value & 0x{step.mask:08X}) == 0x{step.want:08X}    ;# {step.what}"
    if isinstance(step, Delay):
        return f"wait {step.seconds * 1000:g} ms    ;# {step.what}" if step.what else f"wait {step.seconds * 1000:g} ms"
    return f"mdw 0x{step.address:08X}; if (value & 0x{step.mask:08X}) then ...    ;# {step.what}"


def run(steps: Iterable[Step], write: Callable[[int, int, str], None], read: Callable[[int], int],
        log: Callable[[str], None] = lambda text: None, sleep: Callable[[float], None] = time.sleep,
        monotonic: Callable[[], float] = time.monotonic) -> None:
    """Run <steps>: <write>(address, value, what), <read>(address) -> 32-bit value; <log> gets one line per step."""
    for step in steps:
        log(describe(step))
        if isinstance(step, Write):
            write(step.address, step.value, step.what)
        elif isinstance(step, Modify):
            word = read(step.address)
            write(step.address, (word | step.set) & ~step.clear & 0xFFFFFFFF, step.what)
        elif isinstance(step, Poll):
            deadline = monotonic() + step.timeout
            while (read(step.address) & step.mask) != step.want:
                if monotonic() > deadline:
                    raise MssInitError(f"{step.what}: 0x{step.address:08X} & 0x{step.mask:08X} is not 0x{step.want:08X} after {step.timeout:g} s")
                sleep(0.01)
        elif isinstance(step, Delay):
            sleep(step.seconds)
        elif isinstance(step, IfSet) and read(step.address) & step.mask:
            run(step.then, write, read, log, sleep, monotonic)
