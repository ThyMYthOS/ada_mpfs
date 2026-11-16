# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @req GEN-001
"""The error codes of the configuration generator and the rules on a system description that the JSON
schema cannot express.

CODES is the one list of the codes: each rule has its own, and config/README.md has the same table (a
test compares them). A code is never reused for another rule. The schema rules (GEN-E001 to GEN-E013)
are reported by yaml_reader.py from the failures of the validator, the others (GEN-E020 on) by
semantic() below on a description that the schema accepts.
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
}


@dataclass(frozen=True, slots=True)
class Diagnostic:
    """One violated rule: its code, where (a path such as partitions[1].stacks.main) and what."""
    code: str
    path: str
    message: str

    def __str__(self) -> str:
        return f"{self.code} {self.path or '(top level)'}: {self.message}"


class SystemDescriptionError(errors.InputError):
    """A system description that breaks rules: every diagnostic, one per line, after the file name."""

    def __init__(self, where: str, diagnostics: list[Diagnostic]):
        self.where = where
        self.diagnostics = diagnostics
        super().__init__("\n".join(f"{where}: {d}" for d in diagnostics))

    @property
    def codes(self) -> list[str]:
        return [d.code for d in self.diagnostics]


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
