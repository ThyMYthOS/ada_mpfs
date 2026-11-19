# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @req GEN-006
"""The clocks of the MSS: taken from mss_clocks/clocks of the XML, recomputed from the registers of the
MSS PLL and the dividers, and checked against the limits of the clock tree.

The recomputation. Microchip's HAL does not spell the formula out (mss_pll.c and mss_pll.h only write
the registers); it is the one of the PolarFire clocking documentation (the VCO is the reference divided
by RFDIV and multiplied by the feedback divider, the output dividers see the VCO divided by 4), and every
reference XML agrees with it. No reference XML uses the fractional mode:

  reference  MSS_EXT_SGMII_REF_CLK of mss_clocks/clocks: the external reference of the SGMII IO block
             that PLL_CKMUX feeds to the MSS PLL ("use case one" of mss_pll.h)
  VCO        reference / RFDIV * (INTIN + FRACIN / 2**24 if FRACN_EN)     PLL_REF_FB, SSCG_REG_2,
                                                                          SSCG_REG_0, PLL_FRACN
  output 0   VCO / (4 * POST0DIV)                                         PLL_DIV_0_1; output 0 is
             clk_in_mss (mss_pll.h:44-51), selected by MSSCLKMUX bit 0 (1 PLL, 0 the SCB clock of 80 MHz,
             mss_pll.h:96-97 and :82)
  CPU, AXI   output 0 / 2**DIVIDER_CPU, / 2**DIVIDER_AXI                   CLOCK_CONFIG_CR
  AHB/APB    output 0 / 2**DIVIDER_APB_AHB, a divider of 1 divides by 2 (mss_pll.h:151-152)

The limits are those of mss_pll.h:147-155: CPU at most 625 MHz, AXI at most 312.5 MHz, AHB at most
156.25 MHz, CPU not below AXI, AHB/APB not divided by 1, AHB above 66 MHz while USB is in use (USB in
CONFIGURED_PERIPHERALS). The RTC: RTC_CLOCK_CR.PERIOD divides the reference to the RTC toggle clock that
mtime counts; it is 12 bits wide, and the toggle clock must be the Clock_Frequency of the runtime.
"""
from dataclasses import dataclass
from fractions import Fraction

from .. import target
from ..checks import Diagnostic, diagnostic
from ..model import MssConfiguration

CLOCKS = "mss_clocks/clocks"
PLL = "mss_clocks/mss_pll"
SYS = "mss_clocks/mss_sys"
CFM = "mss_clocks/mss_cfm"

MHZ = 1_000_000
CPU_MAX = 625 * MHZ
AXI_MAX = Fraction(3125, 10) * MHZ
AHB_MAX = Fraction(15625, 100) * MHZ
AHB_MIN_WITH_USB = 66 * MHZ
SCB_CLOCK = 80 * MHZ
RTC_PERIOD_MAX = 4095
FRACTION_BITS = 24
TOLERANCE_PPM = 1

# The clocks of mss_clocks/clocks that are recomputed, and the attribute of Clocks that holds each.
COMPARED = {"MSS_SYSTEM_CLK": "system", "MSS_COREPLEX_CPU_CLK": "cpu", "MSS_AXI_CLK": "axi",
            "MSS_APB_AHB_CLK": "ahb"}


@dataclass(frozen=True, slots=True)
class Clocks:
    """The clocks in Hz. The XML's own values are <stated>; the others are recomputed (Fraction, exact)."""
    reference: int
    vco: Fraction
    system: Fraction
    cpu: Fraction
    axi: Fraction
    ahb: Fraction
    rtc_toggle: int
    rtc_period: int
    usb: bool
    stated: tuple[tuple[str, int], ...]

    def deviation_ppm(self, name: str) -> Fraction:
        """How far the clock <name> of the XML is from the recomputed one, in ppm of the recomputed one."""
        computed: Fraction = getattr(self, COMPARED[name])
        return abs(dict(self.stated)[name] - computed) / computed * MHZ if computed else Fraction(0)


def _field(config: MssConfiguration, section: str, register: str, field: str) -> int:
    value = config.register(section, register).field(field).value
    return value if value is not None else 0


def derive(config: MssConfiguration) -> tuple[Clocks, list[Diagnostic]]:
    """The clocks of <config> and the rules they break."""
    found: list[Diagnostic] = []

    def report(code: str, path: str, message: str) -> None:
        found.append(diagnostic(code, path, message))

    stated = config.clocks
    reference = stated["MSS_EXT_SGMII_REF_CLK"]
    rfdiv = _field(config, PLL, "PLL_REF_FB", "RFDIV")
    intin = _field(config, PLL, "SSCG_REG_2", "INTIN")
    fracin = _field(config, PLL, "SSCG_REG_0", "FRACIN") if _field(config, PLL, "PLL_FRACN", "FRACN_EN") else 0
    post0 = _field(config, PLL, "PLL_DIV_0_1", "POST0DIV")
    for name, value in (("PLL_REF_FB.RFDIV", rfdiv), ("SSCG_REG_2.INTIN", intin), ("PLL_DIV_0_1.POST0DIV", post0)):
        if value == 0:
            report("GEN-E062", f"{PLL}/{name}", "is 0")
    multiplier = intin + Fraction(fracin, 1 << FRACTION_BITS)
    vco = Fraction(reference) * multiplier / rfdiv if rfdiv else Fraction(0)
    if _field(config, CFM, "MSSCLKMUX", "MSSCLK_MUX_SEL") & 1:
        system = vco / (4 * post0) if post0 else Fraction(0)
    else:
        system = Fraction(SCB_CLOCK)
    div_cpu = _field(config, SYS, "CLOCK_CONFIG_CR", "DIVIDER_CPU")
    div_axi = _field(config, SYS, "CLOCK_CONFIG_CR", "DIVIDER_AXI")
    div_ahb = _field(config, SYS, "CLOCK_CONFIG_CR", "DIVIDER_APB_AHB")
    usb = bool(_field(config, "mss_general/mss_peripherals", "CONFIGURED_PERIPHERALS", "USB"))
    clocks = Clocks(reference=reference, vco=vco, system=system, cpu=system / (1 << div_cpu),
                    axi=system / (1 << div_axi), ahb=system / (1 << max(div_ahb, 1)),
                    rtc_toggle=stated["MSS_RTC_TOGGLE_CLK"],
                    rtc_period=_field(config, SYS, "RTC_CLOCK_CR", "PERIOD"), usb=usb,
                    stated=tuple(sorted(stated.items())))

    # The limits on a clock tree that could be recomputed (not with a PLL divider of 0, GEN-E062).
    if system:
        for name, attribute in COMPARED.items():
            ppm = clocks.deviation_ppm(name)
            if ppm > TOLERANCE_PPM:
                report("GEN-E061", f"{CLOCKS}/{name}",
                       f"{stated[name]} Hz, recomputed {_hz(getattr(clocks, attribute))} "
                       f"({float(ppm):.3f} ppm apart, at most {TOLERANCE_PPM} allowed)")
        if clocks.cpu > CPU_MAX:
            report("GEN-E063", f"{CLOCKS}/MSS_COREPLEX_CPU_CLK", f"{_hz(clocks.cpu)} is above {_hz(CPU_MAX)}")
        if clocks.axi > AXI_MAX:
            report("GEN-E064", f"{CLOCKS}/MSS_AXI_CLK", f"{_hz(clocks.axi)} is above {_hz(AXI_MAX)}")
        if clocks.ahb > AHB_MAX:
            report("GEN-E065", f"{CLOCKS}/MSS_APB_AHB_CLK", f"{_hz(clocks.ahb)} is above {_hz(AHB_MAX)}")
        if clocks.cpu < clocks.axi:
            report("GEN-E066", f"{SYS}/CLOCK_CONFIG_CR",
                   f"the CPU clock {_hz(clocks.cpu)} is below the AXI clock {_hz(clocks.axi)}")
        if div_ahb == 0:
            report("GEN-E067", f"{SYS}/CLOCK_CONFIG_CR.DIVIDER_APB_AHB", "0 divides by 1, which the AHB/APB divider must not")
        if usb and clocks.ahb <= AHB_MIN_WITH_USB:
            report("GEN-E068", f"{CLOCKS}/MSS_APB_AHB_CLK",
                   f"{_hz(clocks.ahb)} is not above {_hz(AHB_MIN_WITH_USB)}, and CONFIGURED_PERIPHERALS has USB")

    toggle = clocks.rtc_toggle
    period = Fraction(reference, toggle) if toggle else None
    if period is None or period.denominator != 1 or not 1 <= period <= RTC_PERIOD_MAX:
        report("GEN-E069", f"{CLOCKS}/MSS_RTC_TOGGLE_CLK",
               f"{reference} Hz / {toggle} Hz is not a whole number from 1 to {RTC_PERIOD_MAX}")
    elif clocks.rtc_period != period:
        report("GEN-E070", f"{SYS}/RTC_CLOCK_CR.PERIOD",
               f"{clocks.rtc_period}, but {reference} Hz / {toggle} Hz is {period}")
    if toggle != target.RUNTIME_CLOCK_HZ:
        report("GEN-E071", f"{CLOCKS}/MSS_RTC_TOGGLE_CLK",
               f"{toggle} Hz, but the runtime counts mtime at {target.RUNTIME_CLOCK_HZ} Hz")
    return clocks, found


def _hz(value: Fraction | int) -> str:
    """A rate for a message: whole Hz as they are, otherwise with three decimals."""
    value = Fraction(value)
    return f"{value.numerator} Hz" if value.denominator == 1 else f"{float(value):.3f} Hz"
