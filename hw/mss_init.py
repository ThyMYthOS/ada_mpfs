# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""What the first-stage boot software does to the MSS of the PolarFire SoC before the clock switch.

Boot mode 0 leaves the MSS as the reset left it: the RTC reference clock is not set up, so CLINT.MTIME does not
count, and the SGMII/DDR PHY block is not reachable. Microchip's boot software (HSS, the mpfs_hal of the platform
repository: mss_nwc_init.c, mss_sgmii.c, mss_pll.c) sets this up. This module holds the same register writes as data,
with the values of the Icicle Kit design (the Libero MSS Configurator XML of the reference design), and runs them
through a write and a read function of the caller. It writes 32-bit words only.

Two sequences:

  REFCLK   what CLINT.MTIME needs, the smallest set found on the board (2026-10-23, boot mode 0, MPFS250T): the RTC
           divisor for the 125 MHz reference, the SCB access timer, the DFI/APB clock, MSS_IO_EN and the clock
           receiver of the reference (CFG_DDR_SGMII_PHY.CLK_CNTL). Used by `svd_probe.py --enable-clocks`.
  FULL     the whole of mss_nwc_init up to, but excluding, the clock switch: REFCLK and the dynamic enables, the IO mux
           and bank set-up, the MSSIO handshake, the SGMII channel set-up (reset, calibration, PLL and DLL lock), and
           the MSS PLL up to its lock. Not done: ENVM_CR, CLOCK_CONFIG_CR and MSSCLKMUX (the switch of the MSS to the
           PLL), the DDR set-up, and the two nw_config writes to the GEM blocks (the vendor header addresses them
           at 0x20110008, a read-only register, so they have no effect there). `./x hw initialize` runs it.

The sequence does not change what the examples see of the clocks: the CPU stays on the boot clock, so the UART
divisor of --uart-standin stays right.
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Callable

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

RTC_PERIOD = 125                  # 125 MHz reference / 125 = 1 MHz
SCB_ACCESS_CONFIG = 0x80 | (160 << 8) | (8 << 16)
SGMII_MODE_VALUE = 0x0880F2FF     # the XML value without REG_CDR_MOVE_STEP (bit 22)


@dataclass(frozen=True)
class Write:
    address: int
    value: int
    what: str


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
    then: tuple = field(default_factory=tuple)


Step = Write | Modify | Poll | Delay | IfSet


class MssInitError(Exception):
    """A step failed: a poll ran out of time, or the access itself failed."""


def _rtc(tag: str) -> list[Step]:
    return [Write(RTC_CLOCK_CR, RTC_PERIOD, f"RTC divisor {tag}: period {RTC_PERIOD}, clock off"),
            Write(RTC_CLOCK_CR, RTC_PERIOD | 1 << 16, "RTC clock on")]


REFCLK: tuple[Step, ...] = tuple(_rtc("(reference 125 MHz)") + [
    Write(IOSCBCFG_TIMER, SCB_ACCESS_CONFIG, "IOSCBCFG.TIMER: SCB access timing"),
    Write(DFIAPB_CR, 0x1, "SYSREG.DFIAPB_CR: DFI/APB clock on, reset released"),
    Write(MSSIO_CONTROL_CR, 0x3800, "SCB_REGS.MSSIO_CONTROL_CR: CORE_UP, FLASH_VALID, MSS_IO_EN"),
    Write(CLK_CNTL, 0xF00050CC, "CFG_DDR_SGMII_PHY.CLK_CNTL: clock receiver of the reference"),
])

_IOMUX = (0x00000FDD, 0, 0, 0x44444444, 0x88CC4444, 0xF7773333, 0x0000001D)
_BANK4 = (0x09300930, 0x09300930, 0x09300930, 0x09280928, 0x09300930, 0x09300930, 0x09300930)
_BANK2 = (0x08290829,) * 12


def _io_setup() -> list[Step]:
    steps: list[Step] = [Write(SYSREG + 0x200 + 4 * i, v, f"SYSREG.IOMUX{i}_CR") for i, v in enumerate(_IOMUX)]
    steps += [Write(SYSREG + 0x234 + 4 * i, v, f"SYSREG.MSSIO_BANK4_IO_CFG_{2 * i}_{2 * i + 1}_CR") for i, v in enumerate(_BANK4)]
    steps += [Write(SYSREG + 0x254 + 4 * i, v, f"SYSREG.MSSIO_BANK2_IO_CFG_{2 * i}_{2 * i + 1}_CR") for i, v in enumerate(_BANK2)]
    steps += [Write(SCB_REGS + 0x1C4, 0x00080907, "SCB_REGS.MSSIO_BANK2_CFG_CR"),
              Write(SCB_REGS + 0x1C8, 0x00040A0D, "SCB_REGS.MSSIO_BANK4_CFG_CR")]
    return steps


def _mssio_handshake() -> list[Step]:
    return [Write(MSSIO_CONTROL_CR, 0x0F00, "MSSIO_CONTROL_CR: DCE 7, CORE_UP"), Delay(0.001),
            Write(MSSIO_CONTROL_CR, 0x0800, "DCE 0"), Delay(0.001),
            Write(MSSIO_CONTROL_CR, 0x1800, "FLASH_VALID"), Delay(0.001),
            Write(MSSIO_CONTROL_CR, 0x3800, "MSS_IO_EN")]


_LANE_RESET: tuple[Step, ...] = (Write(DYN_CNTL, 0x607F, "DYN_CNTL: lane 0 and 1 soft reset"),
                                 Write(DYN_CNTL, 0x007F, "DYN_CNTL: lanes released"))


def _sgmii() -> list[Step]:
    return [
        Write(SOFT_RESET_SGMII, 0x101, "SOFT_RESET_SGMII: PERIPH reset"), Write(SOFT_RESET_SGMII, 0x1, "SOFT_RESET_SGMII"),
        Write(SGMII_MODE, SGMII_MODE_VALUE, "SGMII_MODE (RPC)"),
        Write(CH0_CNTL, 0x37F07770, "CH0_CNTL (RPC)"), Write(CH1_CNTL, 0x37F07770, "CH1_CNTL (RPC)"),
        Write(RECAL_CNTL, 0x000020C8, "RECAL_CNTL (RPC)"), Write(CLK_CNTL, 0xF00050CC, "CLK_CNTL (RPC)"),
        Write(SPARE_CNTL, 0xFF000000, "SPARE_CNTL (RPC)"), Write(PLL_CNTL, 0x80140101, "PLL_CNTL (RPC)"),
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


def _pll() -> list[Step]:
    steps: list[Step] = [Write(PLL_DDR, 3, "IOSCB_PLL_DDR.SOFT_RESET"), Write(PLL_MSS, 3, "IOSCB_PLL_MSS.SOFT_RESET"),
                         Write(PLL_MSS + 0x04, 0x01000036, "PLL_CTRL, powered down")]
    for off, value, name in ((0x08, 0x00000500, "PLL_REF_FB"), (0x10, 0x01000100, "PLL_DIV_0_1"), (0x14, 0x4B000300, "PLL_DIV_2_3"),
                             (0x18, 0x00001020, "PLL_CTRL2"), (0x0C, 0, "PLL_FRACN"), (0x24, 0, "SSCG_REG_0"), (0x28, 0, "SSCG_REG_1"),
                             (0x2C, 0x60, "SSCG_REG_2"), (0x30, 1, "SSCG_REG_3"), (0x20, 0x4003, "PLL_PHADJ")):
        steps.append(Write(PLL_MSS + off, value, f"IOSCB_PLL_MSS.{name}"))
    steps += [Write(MUX_MSS + 0x08, 0x155, "IOSCB_MUX_MSS.PLL_CKMUX"), Write(MUX_SGMII + 0x10, 0x2C30, "IOSCB_MUX_SGMII.CLK_XCVR"),
              Write(MUX_MSS + 0x04, 0x208, "IOSCB_MUX_MSS.BCLKMUX"), Write(MUX_MSS + 0x14, 0, "FMETER_ADDR"),
              Write(MUX_MSS + 0x18, 0, "FMETER_DATAW"),
              Write(PLL_MSS + 0x04, 0x01000037, "PLL_CTRL, powered up"),
              Poll(PLL_MSS + 0x04, 1 << 25, 1 << 25, "PLL_CTRL.LOCK: MSS PLL locked", 5.0)]
    return steps


def full(io: bool = True) -> tuple[Step, ...]:
    """The sequence of mss_nwc_init without the clock switch; <io> False leaves out the IO mux and bank set-up."""
    steps = _rtc("(first)") + [
        Write(IOSCBCFG_TIMER, SCB_ACCESS_CONFIG, "IOSCBCFG.TIMER: SCB access timing"),
        Write(DFIAPB_CR, 0x1, "SYSREG.DFIAPB_CR: DFI/APB clock on, reset released"),
        Write(DDRPHY_STARTUP, 0x003F1F00, "DDRPHY_STARTUP: dynamic enables"),
        Write(DYN_CNTL, 0x047F, "DYN_CNTL: dynamic enables"),
    ]
    if io:
        steps += _io_setup()
    steps += _mssio_handshake() + _sgmii() + _pll()
    return tuple(steps)


def describe(step: Step) -> str:
    """One line for a dry run and the log: the OpenOCD command and what it is for."""
    if isinstance(step, Write):
        return f"mww 0x{step.address:08X} 0x{step.value:08X}    ;# {step.what}"
    if isinstance(step, Modify):
        return f"mdw 0x{step.address:08X}; mww with |0x{step.set:08X} &~0x{step.clear:08X}    ;# {step.what}"
    if isinstance(step, Poll):
        return f"mdw 0x{step.address:08X} until (value & 0x{step.mask:08X}) == 0x{step.want:08X}    ;# {step.what}"
    if isinstance(step, Delay):
        return f"wait {step.seconds * 1000:g} ms    ;# {step.what}" if step.what else f"wait {step.seconds * 1000:g} ms"
    return f"mdw 0x{step.address:08X}; if (value & 0x{step.mask:08X}) then ...    ;# {step.what}"


def run(steps, write: Callable[[int, int, str], None], read: Callable[[int], int],
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
        elif isinstance(step, IfSet):
            if read(step.address) & step.mask:
                run(step.then, write, read, log, sleep, monotonic)
