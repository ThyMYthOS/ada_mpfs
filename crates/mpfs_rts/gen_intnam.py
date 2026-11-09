#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# @req SVD-002
"""Generate a-intnam.ads (Ada.Interrupts.Names) of the runtime from the SVD.

  gen_intnam.py [--check] [--svd FILE] [--local FILE] [--parameters FILE] [--output FILE]

The names come from two inputs and stay in two name spaces:

  - the <interrupt> elements of the merged SVD (build/svd/PolarfireSoC.svd): the sources of the
    PLIC. Each is a constant of type Interrupt_ID with the value of the SVD (1 .. 186; the value
    is the PLIC source number, so the ids are the ones the PLIC claim register returns);
  - svd/additions/local_interrupts.yaml: the hart-local interrupts, in the nested package
    Ada.Interrupts.Names.Local. They are constants of the own type Local_Interrupt, which is not
    an Interrupt_ID and cannot be used as one: their value is the local interrupt number
    (mcause = 16 + number) and the same number means different things on different harts.

The output is deterministic (sorted by value, then name; no time stamp). Without --check it is
written to --output (crates/mpfs_rts/mpfs/gnarl/a-intnam.ads); with --check it is compared with
that file and the exit status says whether it is current. --check is what CI runs.

The range of Interrupt_ID is the range of System.BB.Parameters.Interrupt_Range in --parameters
(crates/bb-runtimes/src/s-bbpara__polarfiresoc.ads). The generator requires it to be exactly the
smallest to the largest PLIC source of the SVD (the file is not generated: it also carries the clock
and the stacks), and the generated package states the same range as a compile-time check, so a
runtime whose Interrupt_Range and SVD differ does not compile.

Without --svd the merged SVD is taken from build/svd, made current with tools/svd.py ensure
(which needs svdtools only if the file is missing or stale).

Exit status: 0 ok (current with --check), 1 the output is not current (--check), 2 an input is
missing or violates a rule (the message names it).
"""
import argparse
import difflib
import re
import subprocess
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from gen_ada import ada, errors, spdx  # noqa: E402
from gen_ada.errors import InputError  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_SVD = ROOT / "build" / "svd" / "PolarfireSoC.svd"
DEFAULT_LOCAL = ROOT / "svd" / "additions" / "local_interrupts.yaml"
DEFAULT_PARAMETERS = ROOT / "crates" / "bb-runtimes" / "src" / "s-bbpara__polarfiresoc.ads"
DEFAULT_OUTPUT = ROOT / "crates" / "mpfs_rts" / "mpfs" / "gnarl" / "a-intnam.ads"

RANGE_LINE = re.compile(r"subtype\s+Interrupt_Range\s+is\s+Natural\s+range\s+(\d+)\s*\.\.\s*(\d+)\s*;")


def read_plic(svd: Path) -> list[tuple[int, str, str]]:
    """The PLIC sources of the SVD: (value, name, description) sorted by value."""
    try:
        root = ET.parse(svd).getroot()
    except (OSError, ET.ParseError) as err:
        raise InputError(f"{svd}: cannot read the SVD ({err})") from err
    found: list[tuple[int, str, str]] = []
    for element in root.iter("interrupt"):
        name = (element.findtext("name") or "").strip()
        value = (element.findtext("value") or "").strip()
        text = " ".join((element.findtext("description") or "").split())
        if not value.isdigit():
            raise InputError(f"{svd}: interrupt {name!r} has no numeric value")
        found.append((int(value), ada.identifier(name, f"{svd}: interrupt {value}"), text))
    if not found:
        raise InputError(f"{svd}: no <interrupt> element")
    found.sort()
    seen_value: dict[int, str] = {}
    seen_name: dict[str, int] = {}
    for value, name, _ in found:
        if value in seen_value:
            raise InputError(f"{svd}: the interrupt value {value} is used by {seen_value[value]} and {name}")
        if name in seen_name:
            raise InputError(f"{svd}: the interrupt name {name} has the values {seen_name[name]} and {value}")
        seen_value[value], seen_name[name] = name, value
    if found[0][0] != 1:
        raise InputError(f"{svd}: the first PLIC source is {found[0][0]}, not 1 (0 means no interrupt)")
    return found


def read_local(path: Path, plic: dict[str, int]) -> tuple[dict[str, int], list[dict]]:
    """The harts and the local interrupts (sorted by number, then name) of local_interrupts.yaml."""
    import yaml  # PyYAML, as for the other tools

    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as err:
        raise InputError(f"{path}: cannot read ({err})") from err
    if not isinstance(data, dict) or data.get("schema") != 1:
        raise InputError(f"{path}: not a local interrupt file of schema 1")
    harts = data.get("harts")
    items = data.get("interrupts")
    if not isinstance(harts, dict) or not harts or not isinstance(items, list) or not items:
        raise InputError(f"{path}: harts and interrupts are required")
    seen: dict[str, int] = {}
    result = []
    for item in items:
        number, name = item.get("local"), item.get("name")
        where = f"{path}: local interrupt {name}"
        if not isinstance(number, int) or number < 0:
            raise InputError(f"{where}: local is not a number >= 0")
        ada.identifier(str(name), where)
        if name in seen:
            raise InputError(f"{where}: the name is used twice (numbers {seen[name]} and {number})")
        seen[name] = number
        members = item.get("harts")
        if not members or any(h not in harts for h in members):
            raise InputError(f"{where}: harts must be a non-empty list of {sorted(harts)}")
        also = item.get("plic")
        if also is not None and also not in plic:
            raise InputError(f"{where}: plic names {also}, which is no PLIC source of the SVD")
        result.append({"local": number, "name": name, "harts": list(members), "plic": also,
                       "description": " ".join(str(item.get("description", "")).split())})
    result.sort(key=lambda i: (i["local"], i["name"]))
    return harts, result


def check_parameters(path: Path, first: int, last: int) -> None:
    """Interrupt_Range of s-bbpara must be exactly first .. last."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as err:
        raise InputError(f"{path}: cannot read ({err})") from err
    found = RANGE_LINE.search(text)
    if not found:
        raise InputError(f"{path}: no declaration of Interrupt_Range (subtype Interrupt_Range is Natural range A .. B;)")
    have = (int(found.group(1)), int(found.group(2)))
    if have != (first, last):
        raise InputError(
            f"{path}: Interrupt_Range is {have[0]} .. {have[1]}, the PLIC sources of the SVD are {first} .. {last}")


def render(plic: list[tuple[int, str, str]], harts: dict[str, int], local: list[dict]) -> str:
    first, last = plic[0][0], plic[-1][0]
    present = {v for v, _, _ in plic}
    gaps = [n for n in range(first, last + 1) if n not in present]
    top = max(i["local"] for i in local)
    intro = [
        ada.generated_notice("crates/mpfs_rts/gen_intnam.py",
                             "the <interrupt> elements of the SVD (svd/additions/interrupts.yaml) "
                             "and from svd/additions/local_interrupts.yaml"),
        "The names of the interrupts of PolarFire SoC. An Interrupt_ID is the number of a PLIC source, "
        f"which is what the claim register returns: {first} .. {last}, the range of "
        "System.BB.Parameters.Interrupt_Range. The names are those of the SVD."
        + (" The PLIC source " + ", ".join(map(str, gaps)) + " is reserved or spare in the TRM "
           "(Table 5-1, Routing of Interrupts to Processor Cores): it has no name here, but it lies "
           "inside Interrupt_Range, so its number is an Interrupt_ID that Attach_Handler accepts." if gaps else ""),
        "The hart-local interrupts are not PLIC sources. They are in the package Local, as constants "
        "of the type Local_Interrupt, which is not an Interrupt_ID: they cannot be attached by "
        "Attach_Handler or Interrupt_Handler.",
    ]
    out = spdx.header("ada", "GPL-3.0-or-later WITH GCC-exception-3.1").splitlines()
    for paragraph in intro:
        out += ["--", *ada.comment(paragraph, "")]
    out += [
        "",
        "package Ada.Interrupts.Names is",
        "",
        "   --  All identifiers in this unit are implementation defined",
        "",
        "   pragma Implementation_Defined;",
        "",
        "   pragma Compile_Time_Error",
        f"     (Interrupt_ID'First /= {first} or else Interrupt_ID'Last /= {last},",
        "      \"Interrupt_Range of System.BB.Parameters is not the range \"",
        "      & \"of the PLIC sources\");",
        "",
        *ada.banner("PLIC sources"),
        "",
    ]
    for value, name, text in plic:
        out.append(f"   {name} : constant Interrupt_ID := {value};")
        out += ada.comment(text)
    out += [
        "",
        *ada.banner("Hart-local interrupts"),
        "",
        "   package Local is",
        "",
    ]
    out += ada.comment("The local interrupt numbers of the harts: the mcause of the interrupt is "
                   "Mcause_Offset + number (interrupt bit set), and the same number is a "
                   "different interrupt on the E51 and on the U54 cores. A name lists the "
                   "harts that have the interrupt, and the PLIC source that the same event "
                   "also raises, if it has one.", "      ")
    out += [
        "",
        f"      type Local_Interrupt is range 0 .. {top};",
        "",
        "      Mcause_Offset : constant := 16;",
        "",
    ]
    for item in local:
        who = "" if any(h in item["description"] for h in harts) else ", ".join(item["harts"])
        also = f"also PLIC source {item['plic']}" if item["plic"] else ""
        extra = "; ".join(part for part in (who, also) if part)
        out.append(f"      {item['name']} : constant Local_Interrupt := {item['local']};")
        out += ada.comment(item["description"] + (f" ({extra})" if extra else ""), "      ")
    out += ["", "   end Local;", "", "end Ada.Interrupts.Names;", ""]
    return "\n".join(out)


def ensure_svd() -> Path:
    """build/svd/PolarfireSoC.svd with the recorded hash (tools/svd.py ensure)."""
    result = subprocess.run([sys.executable, str(ROOT / "tools" / "svd.py"), "ensure"], capture_output=True, text=True)
    if result.returncode != 0:
        raise InputError("tools/svd.py ensure failed:\n" + (result.stdout + result.stderr).rstrip())
    return DEFAULT_SVD


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--check", action="store_true", help="compare with --output instead of writing it")
    parser.add_argument("--svd", type=Path, help="the merged SVD (default: build/svd, made current)")
    parser.add_argument("--local", type=Path, default=DEFAULT_LOCAL)
    parser.add_argument("--parameters", type=Path, default=DEFAULT_PARAMETERS)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args(argv)
    svd = args.svd if args.svd else ensure_svd()
    plic = read_plic(svd)
    harts, local = read_local(args.local, {name: value for value, name, _ in plic})
    check_parameters(args.parameters, plic[0][0], plic[-1][0])
    text = render(plic, harts, local)
    if args.check:
        try:
            have = args.output.read_text(encoding="utf-8")
        except OSError:
            print(f"gen_intnam: {args.output} is missing; run crates/mpfs_rts/gen_intnam.py", file=sys.stderr)
            return 1
        if have != text:
            diff = difflib.unified_diff(have.splitlines(), text.splitlines(), str(args.output), "generated", lineterm="", n=1)
            print("\n".join(list(diff)[:40]), file=sys.stderr)
            print(f"gen_intnam: {args.output} is not current; run crates/mpfs_rts/gen_intnam.py", file=sys.stderr)
            return 1
        return 0
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(errors.run(main, "gen_intnam", sys.argv[1:]))
