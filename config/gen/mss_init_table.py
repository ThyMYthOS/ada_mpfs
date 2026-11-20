#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""The register sequence of the MSS set-up, from an MSS Configurator XML, as an Ada constant table.

  mss_init_table.py --xml FILE [--svd FILE] [--skip-io] [--check] [--output FILE] [--tamper-write N]

The steps are those of `./x hw initialize`: this takes them from hw/mss_init.py (phases(), which full() flattens),
so the order and the values are the ones the board has run through OpenOCD, and writes them as the package
MPFS_Init_Table, a table that a small interpreter on the target runs (examples/mss_init_spike/src/mss_init.adb).
The sequence is not written a second time anywhere: the generator is the only reader of the Python steps, and the
test of the example compares what the image writes under QEMU with the same steps (tests/host/mss_init_spike).

Table entries (kind, address, value, mask, count, text range). One step of mss_init.py is one entry, except an
IfSet (a decision on a value read at run time: the silicon revision), which becomes a Skip_If_Clear entry followed by
the entries of its steps:

  Write          write <value> to <address>
  Modify         read <address>, set the bits of <value>, clear the bits of <mask>, write it back
  Poll           read <address> until (word and <mask>) = <value>; <count> microseconds at most
  Wait           wait <count> microseconds (<address>, <value> and <mask> are 0)
  Skip_If_Clear  read <address>; if (word and <mask>) = 0 skip the next <count> entries

The text of each entry is a range of the constant Texts; the phases are ranges of entries. The output is
deterministic (no time stamp), so --check compares byte for byte.

--tamper-write N flips bit 0 of the value of the Nth Write entry (0 is the first): a test seam, the negative control
of the test of the example (the image built from the table must then fail the comparison with the sequence).

Exit status: 0 ok (with --check: current), 1 not current (--check), 2 invalid arguments or an XML the reader
rejects.
"""
import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "hw")]
from gen_ada import ada, cli, errors, spdx  # noqa: E402

import mss_init  # noqa: E402

TOOL = "mss_init_table"
SCRIPT = "config/gen/mss_init_table.py"
DEFAULT_OUTPUT = ROOT / "examples" / "mss_init_spike" / "src" / "generated" / "mpfs_init_table.ads"
WORD = 8   # hex digits of an address or a value
MICROSECONDS = 1_000_000

KINDS = ("Write", "Modify", "Poll", "Wait", "Skip_If_Clear")


class Entry:
    """One entry of the table; <kind> is one of KINDS."""

    def __init__(self, kind: str, what: str, address: int = 0, value: int = 0, mask: int = 0, count: int = 0):
        self.kind, self.what, self.address, self.value, self.mask, self.count = kind, what, address, value, mask, count


def microseconds(seconds: float) -> int:
    return round(seconds * MICROSECONDS)


def entries_of(steps: tuple[mss_init.Step, ...]) -> list[Entry]:
    """The entries of <steps>; an IfSet is its Skip_If_Clear and the entries of its steps."""
    out: list[Entry] = []
    for step in steps:
        if isinstance(step, mss_init.Write):
            out.append(Entry("Write", step.what, step.address, step.value))
        elif isinstance(step, mss_init.Modify):
            out.append(Entry("Modify", step.what, step.address, step.set, step.clear))
        elif isinstance(step, mss_init.Poll):
            out.append(Entry("Poll", step.what, step.address, step.want, step.mask, microseconds(step.timeout)))
        elif isinstance(step, mss_init.Delay):
            out.append(Entry("Wait", step.what or f"{step.seconds * 1000:g} ms", count=microseconds(step.seconds)))
        elif isinstance(step, mss_init.IfSet):
            inner = entries_of(step.then)
            out.append(Entry("Skip_If_Clear", step.what, step.address, mask=step.mask, count=len(inner)))
            out += inner
        else:  # a new step type of mss_init.py that this table cannot say: a defect to fix here, not to skip
            raise errors.InputError(f"mss_init.py has a step of type {type(step).__name__}, which the table has no entry for")
    return out


def literal(value: int) -> str:
    return ada.hex_literal(value, WORD)


def string_constant(name: str, text: str) -> list[str]:
    """`Name : constant String := "...";` over as many lines as the text needs."""
    lines = ada.string_literal(text)
    return [f"   {name} : constant String :="] + [f"     {line}{';' if i == len(lines) - 1 else ' &'}"
                                                   for i, line in enumerate(lines)]


def render(values: mss_init.Values, io: bool, tamper_write: int | None) -> str:
    entries: list[Entry] = []
    phases: list[tuple[str, str, int, int]] = []   # name, what, first entry, last entry (1-based)
    for phase in mss_init.phases(values, io):
        first = len(entries) + 1
        entries += entries_of(phase.steps)
        phases.append((phase.name, phase.what, first, len(entries)))
    if tamper_write is not None:
        writes = [e for e in entries if e.kind == "Write"]
        if not 0 <= tamper_write < len(writes):
            raise errors.InputError(f"--tamper-write {tamper_write}: the table has {len(writes)} Write entries")
        writes[tamper_write].value ^= 1

    # the texts, in one string: every entry's text, then the name and the description of every phase
    texts: list[str] = []
    position = 1

    def text(item: str) -> tuple[int, int]:
        nonlocal position
        texts.append(item)
        first = position
        position += len(item)
        return first, position - 1

    entry_text = [text(e.what) for e in entries]
    phase_text = [(text(name), text(what)) for name, what, _, _ in phases]

    out = spdx.header("ada", "Apache-2.0").splitlines()
    out += ["--", *ada.comment(ada.generated_notice(
        SCRIPT, f"the MSS Configurator XML {values.source} and the sequence of hw/mss_init.py"), "")]
    out += ["--", *ada.comment(
        "The register sequence that sets the MSS up as far as `./x hw initialize` does (the reference clock, the "
        "IO mux and banks, the MSSIO handshake, the SGMII channel set-up and the MSS PLL up to its lock; not the "
        "switch of the MSS clock), as a table that an interpreter runs in order. Entries: Write, Modify (set and "
        "clear bits of the word read), Poll (until the masked word is the wanted one, within a budget), Wait, "
        "and Skip_If_Clear (a decision on a value read at run time: if the masked word is 0, the next Count "
        "entries are skipped). Value, Mask and Count mean what the kind says; the text of an entry is the "
        "range Text_First .. Text_Last of Texts.", "")]
    out += ["", "with Interfaces;", "", "package MPFS_Init_Table is", "", "   pragma Pure;", ""]

    out += ada.banner("The XML")
    out += ["", *string_constant("XML_Source", values.source), "",
            "   XML_SHA256 : constant String :=", f"     \"{values.sha256}\";", "",
            *string_constant("Design", values.design), ""]

    out += ada.banner("Registers the image reads back")
    out += ["", "   MTIME_Address : constant := " + literal(mss_init.MTIME) + ";",
            *ada.comment("CLINT.MTIME: it counts from the write of CLK_CNTL in the phase SGMII on.", "   "),
            "   PLL_Control_Address : constant := " + literal(mss_init.PLL_MSS + 0x04) + ";",
            *ada.comment("IOSCB_PLL_MSS.PLL_CTRL, whose bit PLL_Control_Lock the last Poll waits for.", "   "),
            "   PLL_Control_Lock : constant := " + literal(mss_init.PLL_CTRL_LOCK) + ";", ""]

    out += ada.banner("Types")
    out += ["",
            "   subtype Word is Interfaces.Unsigned_32;",
            "",
            "   type Step_Kind is (" + ", ".join(KINDS) + ");",
            "",
            "   type Step is record",
            "      Kind       : Step_Kind;",
            "      Address    : Word;",
            "      Value      : Word;",
            "      Mask       : Word;",
            "      Count      : Word;",
            "      Text_First : Positive;",
            "      Text_Last  : Natural;",
            "   end record;",
            "",
            f"   Step_Count : constant := {len(entries)};",
            "   type Step_Array is array (1 .. Step_Count) of Step;",
            "",
            "   type Phase is record",
            "      First, Last : Positive;",
            "      Name_First  : Positive;",
            "      Name_Last   : Natural;",
            "      What_First  : Positive;",
            "      What_Last   : Natural;",
            "   end record;",
            "",
            f"   Phase_Count : constant := {len(phases)};",
            "   type Phase_Array is array (1 .. Phase_Count) of Phase;",
            ""]

    out += ada.banner("Texts")
    out += ["", f"   Texts : constant String (1 .. {position - 1}) :="]
    lines = [line for item in texts for line in ada.string_literal(item)]
    out += [f"     {line}{';' if i == len(lines) - 1 else ' &'}" for i, line in enumerate(lines)]
    out += [""]

    out += ada.banner("Phases")
    out += ["", "   Phases : constant Phase_Array :="]
    rows = []
    for (name, _, first, last), (nm, wh) in zip(phases, phase_text):
        rows.append(f"({first}, {last}, {nm[0]}, {nm[1]}, {wh[0]}, {wh[1]})")
    out += [f"     {'[' if i == 0 else ' '}{row}{',' if i < len(rows) - 1 else '];'}" for i, row in enumerate(rows)]
    out += ["", *ada.comment("Phase " + ", ".join(f"{i} {name}" for i, (name, *_) in enumerate(phases, 1)) + ".", "   "), ""]

    out += ada.banner("Steps")
    out += ["", "   Steps : constant Step_Array :=", "     ["]
    for i, (e, (tf, tl)) in enumerate(zip(entries, entry_text), 1):
        end = "," if i < len(entries) else ""
        out.append(f"      (Kind => {e.kind}, Address => {literal(e.address)}, Value => {literal(e.value)},")
        out.append(f"       Mask => {literal(e.mask)}, Count => {e.count},")
        out.append(f"       Text_First => {tf}, Text_Last => {tl}){end}  --  {i}")
    out += ["     ];", "", "end MPFS_Init_Table;", ""]
    return "\n".join(out)


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="mss_init_table.py", description=__doc__.split("\n")[0])
    p.add_argument("--xml", type=Path, required=True, metavar="FILE", help="the MSS Configurator XML of the board")
    p.add_argument("--svd", type=Path, metavar="FILE",
                   help="the merged SVD the reader checks the XML against (default: build/svd/PolarfireSoC.svd)")
    p.add_argument("--skip-io", action="store_true", help="leave out the IO mux and bank set-up")
    p.add_argument("--tamper-write", type=int, metavar="N", help="flip bit 0 of the value of the Nth Write (test seam)")
    cli.add_check(p, "compare with the committed output instead of writing it")
    cli.add_output(p, DEFAULT_OUTPUT, f"the package (default: {DEFAULT_OUTPUT.relative_to(ROOT)})")
    return p


def main(argv: list[str]) -> int:
    args = parser().parse_args(argv)
    try:
        values = mss_init.load(args.xml, args.svd)
    except mss_init.XmlError as err:
        raise errors.InputError(str(err)) from err
    package = render(values, not args.skip_io, args.tamper_write)
    if args.check:
        return cli.check_output(package, args.output, tool=TOOL, command=f"{SCRIPT} --xml {mss_init.shown(args.xml)}")
    cli.write_output(package, args.output)
    return errors.OK


if __name__ == "__main__":
    sys.exit(errors.run(main, TOOL, sys.argv[1:]))
