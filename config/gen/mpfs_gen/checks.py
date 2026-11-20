# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @req GEN-001
"""The error codes of the configuration generator and the rules on a system description that the JSON
schema cannot express.

CODES is the one list of the codes: each rule has its own, and config/README.md has the same table (a
test compares them). A code is never reused for another rule. The schema rules (GEN-E001 to GEN-E013)
are reported by yaml_reader.py from the failures of the validator, the rules across fields (GEN-E020 to
GEN-E034) by semantic() below on a description that the schema accepts, and the rules of the MSS
Configurator XML (GEN-E040 to GEN-E059, XML_CODES) by xml_reader.py, the rules of the derivations from
a description and its XML (GEN-E060 to GEN-E099, DERIVE_CODES) by the package derive, the rules of the
PMP sections of the XML (GEN-E100 to GEN-E119, PMP_CODES) by pmp.py, and the rules of the PMP and the AMP
contexts against the partitions (GEN-E120 to GEN-E139, PROTECTION_CODES) by derive/protection.py and
derive/contexts.py. The codes of WARNINGS report what does not stop the derivation; their rule ends in
"(a warning)".
"""
from dataclasses import dataclass
from pathlib import Path

from gen_ada import errors

from . import target
from .model import System

CODES: dict[str, str] = {
    "GEN-E001": "the file cannot be read or is not well-formed YAML (a key given twice included)",
    "GEN-E002": "the schema version is missing or not 1",
    "GEN-E003": "a required field is missing",
    "GEN-E004": "an unknown field",
    "GEN-E005": "a field of a later schema version (keys, boot.slots)",
    "GEN-E006": "a value has the wrong type",
    "GEN-E007": "a value is not one of the allowed names",
    "GEN-E008": "a number is out of its range",
    "GEN-E009": "a name or text does not have its form or length",
    "GEN-E010": "a size is not a size (a number, 0x and hex digits, or digits with K or M)",
    "GEN-E011": "a list has an entry twice",
    "GEN-E012": "a list has too few or too many entries",
    "GEN-E013": "l2.ways overrides the XML without l2.reason",
    "GEN-E020": "two partitions have the same name",
    "GEN-E021": "a hart is in two partitions",
    "GEN-E022": "a partition mixes the E51 and U54 harts",
    "GEN-E023": "a stack size is 0 or not a multiple of 16",
    "GEN-E024": "the console ram_fifo needs SMP, which the runtime does not have yet",
    "GEN-E025": "a peripheral is owned by two partitions",
    "GEN-E026": "the console of a partition is a peripheral of another partition",
    "GEN-E027": "the watchdog of a partition is not one of its peripherals",
    "GEN-E028": "a channel names a partition that does not exist",
    "GEN-E029": "two channels have the same name",
    "GEN-E030": "fast_text is larger than the ITIM of a hart of the partition (E51 8 KiB, U54 28 KiB)",
    "GEN-E031": "the L2 ways (cache, LIM, scratchpad) do not add up to 16",
    "GEN-E032": "a memory window without a size in a system of more than one partition",
    "GEN-E033": "the boot source fram without a fram section",
    "GEN-E034": "the board has no directory in config/boards",
    "GEN-E040": "the XML cannot be read, is not well-formed or has not the structure of an MSS Configurator XML",
    "GEN-E041": "the XML has a document type or entity declaration",
    "GEN-E042": "xml_format_version is missing or not a version the reader knows (0.5.3, 0.6.5, 0.6.8)",
    "GEN-E043": "a core section is missing",
    "GEN-E044": "a register that the generator needs is missing from its section",
    "GEN-E045": "a section has a register or memory element twice",
    "GEN-E046": "a register has a field twice",
    "GEN-E047": "a number does not have its form (0x and hex digits; decimal digits where the section is "
                "decimal; a bare number above 9 in a hex section is ambiguous)",
    "GEN-E048": "a field reaches beyond its register",
    "GEN-E049": "two fields of a register overlap",
    "GEN-E050": "a value is wider than its field",
    "GEN-E051": "a field is at another bit position than the field of the same name in the SVD",
    "GEN-E052": "a value is wider than the field of the same name in the SVD",
    "GEN-E060": "the XML does not have the SHA-256 that system.yaml names for it",
    "GEN-E061": "a clock of mss_clocks/clocks differs by more than 1 ppm from the clock recomputed from the "
                "MSS PLL and the dividers",
    "GEN-E062": "the MSS PLL has a reference divider, a feedback multiplier or an output divider of 0",
    "GEN-E063": "the CPU clock is above 625 MHz",
    "GEN-E064": "the AXI clock is above 312.5 MHz",
    "GEN-E065": "the AHB/APB clock is above 156.25 MHz",
    "GEN-E066": "the CPU clock is below the AXI clock",
    "GEN-E067": "the AHB/APB clock divider is 1",
    "GEN-E068": "the AHB clock is not above 66 MHz while USB is configured",
    "GEN-E069": "the reference clock divided by the RTC toggle clock is not a whole number from 1 to 4095",
    "GEN-E070": "RTC_CLOCK_CR.PERIOD is not the reference clock divided by the RTC toggle clock",
    "GEN-E071": "the RTC toggle clock is not the Clock_Frequency of the runtime (1 MHz)",
    "GEN-E072": "the L2 of the XML has no cache way or more than 16 ways (WAY_ENABLE, NUM_SCRATCH_PAD_WAYS)",
    "GEN-E073": "a way mask of the XML includes a scratchpad way",
    "GEN-E074": "l2.cache_partitioning names a way that is not a cache way",
    "GEN-E075": "the size of a window is not a multiple of 4 (the granularity of a PMP entry)",
    "GEN-E076": "the windows of a memory do not fit it (the L2 budget of LIM and scratchpad, the eNVM)",
    "GEN-E077": "a window reaches outside its memory",
    "GEN-E078": "windows of two different partitions overlap",
    "GEN-E079": "a window lies in the ITIM or DTIM of a hart that is not in its partition",
    "GEN-E080": "an interrupt is not a PLIC source of the SVD",
    "GEN-E081": "a local interrupt is not one of every hart of the partition",
    "GEN-E082": "a PLIC source is handled by two partitions",
    "GEN-E083": "a peripheral is neither a block of SUBBLK_CLOCK_CR nor a watchdog of the SVD",
    "GEN-E084": "a partition owns a peripheral that CONFIGURED_PERIPHERALS of the XML leaves out",
    "GEN-E100": "a PMP entry of the XML has W set and R clear (a reserved combination)",
    "GEN-E101": "a PMP configuration byte of the XML sets the reserved bits 5 and 6",
    "GEN-E102": "a locked PMP entry comes after an unlocked entry in use",
    "GEN-E103": "a PMP entry in use is beyond the number of entries of the target (16; 8 with --pmp-entries 8)",
    "GEN-E104": "MEM_CONFIGS_ENABLED.PMP is 0, but the PMP sections set entries (a warning)",
    "GEN-E105": "a locked PMP entry grants rights over the whole address space or over the range of a later entry",
    "GEN-E120": "a U partition cannot reach a window of its own with the rights it needs",
    "GEN-E121": "a U partition cannot read and write a peripheral of its own at the address APBBUS_CR gives",
    "GEN-E122": "a U partition cannot read the page of mtime",
    "GEN-E123": "U mode of a U partition reaches what is not its own (a warning)",
    "GEN-E124": "a window or peripheral of another partition, or the ITIM or DTIM of another hart, is reachable "
                "from U mode or from M mode of a hart with locked entries",
    "GEN-E125": "a critical system block is reachable from U mode",
    "GEN-E126": "SYSREG or MPUCFG is reachable from U mode",
    "GEN-E127": "a critical system block is reachable from M mode of a hart with locked entries (a warning)",
    "GEN-E130": "a hart is in both AMP contexts",
    "GEN-E131": "a peripheral is in both AMP contexts",
    "GEN-E132": "APBBUS_CR is not bits 23:0 of CONTEXT_B_EN while AMP contexts are used",
    "GEN-E133": "a peripheral of a partition is not in the AMP context of its harts",
    "GEN-E134": "the harts of a partition are not all in the same AMP context",
    "GEN-E135": "a PMP window of a partition in one AMP context covers the bus window of the other (a warning)",
}

# The codes of the reader of the MSS Configurator XML (xml_reader.py); the others are those of system.yaml.
XML_CODES = frozenset(code for code in CODES if "GEN-E040" <= code <= "GEN-E059")
# The codes of the derivations from a system description and its XML (derive/).
DERIVE_CODES = frozenset(code for code in CODES if "GEN-E060" <= code <= "GEN-E099")
# The codes of the PMP sections of the XML (pmp.py).
PMP_CODES = frozenset(code for code in CODES if "GEN-E100" <= code <= "GEN-E119")
# The codes of the PMP and the AMP contexts against the partitions (derive/protection.py, derive/contexts.py).
PROTECTION_CODES = frozenset(code for code in CODES if "GEN-E120" <= code <= "GEN-E139")
# The codes that report what does not stop the derivation.
WARNINGS = frozenset(code for code, rule in CODES.items() if rule.endswith("(a warning)"))


@dataclass(frozen=True, slots=True)
class Diagnostic:
    """One violated rule: its code, where (a path such as partitions[1].stacks.main) and what."""
    code: str
    path: str
    message: str

    def __str__(self) -> str:
        return f"{self.code}{' (warning)' if self.warning else ''} {self.path or '(top level)'}: {self.message}"

    @property
    def warning(self) -> bool:
        return self.code in WARNINGS


class DiagnosticError(errors.InputError):
    """An input that breaks rules: every diagnostic, one per line, after the file name."""

    def __init__(self, where: str, diagnostics: list[Diagnostic]):
        self.where = where
        self.diagnostics = diagnostics
        super().__init__("\n".join(f"{where}: {d}" for d in diagnostics))

    @property
    def codes(self) -> list[str]:
        return [d.code for d in self.diagnostics]


class SystemDescriptionError(DiagnosticError):
    """A system description (system.yaml) that breaks rules."""


class ConfiguratorXmlError(DiagnosticError):
    """An MSS Configurator XML that breaks rules."""


class DerivationError(DiagnosticError):
    """A system description and an XML whose derived system breaks rules."""


def diagnostic(code: str, path: str, message: str) -> Diagnostic:
    """A diagnostic of a code that CODES has (a code that it has not is a defect of the generator)."""
    if code not in CODES:
        raise KeyError(f"{code} is not in CODES")
    return Diagnostic(code, path, message)


def semantic(system: System, boards: Path) -> list[Diagnostic]:
    """The rules across fields, on a description that the schema accepts and with its defaults applied.
    <boards> is the directory of the boards (config/boards)."""
    found: list[Diagnostic] = []

    def report(code: str, path: str, message: str) -> None:
        found.append(diagnostic(code, path, message))

    if not (boards / system.board).is_dir():
        report("GEN-E034", "board", f"no board {system.board!r}: no directory {system.board}/ in {boards}")

    names: dict[str, int] = {}
    owner_of_hart: dict[int, str] = {}
    owner_of_peripheral: dict[str, str] = {}
    several = len(system.partitions) > 1
    for i, part in enumerate(system.partitions):
        at = f"partitions[{i}]"
        if part.name in names:
            report("GEN-E020", f"{at}.name", f"{part.name!r} is also the name of partitions[{names[part.name]}]")
        names.setdefault(part.name, i)
        for hart in part.harts:
            if hart in owner_of_hart:
                report("GEN-E021", f"{at}.harts", f"hart {hart} is also in partition {owner_of_hart[hart]!r}")
            owner_of_hart.setdefault(hart, part.name)
        if target.E51_HART in part.harts and len(part.harts) > 1:
            report("GEN-E022", f"{at}.harts", f"{list(part.harts)} mixes the E51 (hart 0) with U54 harts")
        for kind in ("main", "interrupt", "secondary"):
            size = getattr(part.stacks, kind)
            if size == 0 or size % target.STACK_ALIGNMENT:
                report("GEN-E023", f"{at}.stacks.{kind}",
                       f"{size} is not a non-zero multiple of {target.STACK_ALIGNMENT}")
        if part.console == "ram_fifo" and not target.SMP_AVAILABLE:
            report("GEN-E024", f"{at}.console", "ram_fifo needs a second hart that drains it; SMP does not exist yet")
        for name in part.peripherals:
            if name in owner_of_peripheral:
                report("GEN-E025", f"{at}.peripherals",
                       f"{name} is also a peripheral of partition {owner_of_peripheral[name]!r}")
            owner_of_peripheral.setdefault(name, part.name)
        if part.watchdog and part.watchdog.instance not in part.peripherals:
            report("GEN-E027", f"{at}.watchdog.instance",
                   f"{part.watchdog.instance} is not in the peripherals of {part.name!r}")
        fast = part.memory.fast_text
        if fast and fast.size is not None:
            for hart in part.harts:
                if fast.size > target.ITIM_MAX[hart]:
                    report("GEN-E030", f"{at}.memory.fast_text.size",
                           f"{fast.size} bytes do not fit the ITIM of hart {hart} ({target.ITIM_MAX[hart]} bytes)")
        if several:
            for kind in ("code", "data"):
                if getattr(part.memory, kind).size is None:
                    report("GEN-E032", f"{at}.memory.{kind}.size",
                           "a window takes the whole region only in a system of one partition")

    for i, part in enumerate(system.partitions):
        other = owner_of_peripheral.get(part.console)
        if other is not None and other != part.name:
            report("GEN-E026", f"partitions[{i}].console", f"{part.console} is a peripheral of partition {other!r}")

    channels: dict[str, int] = {}
    for i, channel in enumerate(system.ipc):
        if channel.name in channels:
            report("GEN-E029", f"ipc[{i}].name", f"{channel.name!r} is also the name of ipc[{channels[channel.name]}]")
        channels.setdefault(channel.name, i)
        for end in channel.between:
            if end not in names:
                report("GEN-E028", f"ipc[{i}].between", f"there is no partition {end!r}")

    ways = system.l2.ways
    if ways and ways.cache + ways.lim + ways.scratchpad != target.WAYS:
        report("GEN-E031", "l2.ways", f"{ways.cache} + {ways.lim} + {ways.scratchpad} ways is not {target.WAYS}")

    if system.boot and "fram" in system.boot.sources and system.fram is None:
        report("GEN-E033", "boot.sources", "fram is a boot source, but there is no fram section")
    return found
