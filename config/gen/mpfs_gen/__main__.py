# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""The command line of the configuration generator (as far as it exists).

  python3 config/gen/mpfs_gen check FILE...            validate system descriptions
  python3 config/gen/mpfs_gen preset HART CPUS PROFILE PRIV
                                                       print the standalone preset of a runtime variant
  python3 config/gen/mpfs_gen standalone-args FILE     print the parameters of standalone.py for a
                                                       description of one partition
  python3 config/gen/mpfs_gen xml [--check] [--fields] [--svd SVD] FILE...
                                                       read MSS Configurator XMLs and print the
                                                       registers of their core sections

`check` prints `FILE: ok` or one line per violated rule, `FILE: GEN-Exxx PATH: message`; so does
`xml --check`. `xml` prints the design, the hash and every register of the core sections
(`SECTION/NAME = VALUE`, with --fields also each field), the memory elements and the sections that are
only validated. Without --svd the merged SVD is build/svd/PolarfireSoC.svd, made current first.
Exit status: 0 ok, 2 an input breaks a rule or the arguments are wrong.
"""
import argparse
import sys
from pathlib import Path

# Run as `python3 config/gen/mpfs_gen`, the directory of this file is the first entry of the module path,
# where target.py and the others would hide modules of the standard library: the package is imported
# from its parent instead, with tools/ for gen_ada.
HERE = Path(__file__).resolve().parent
sys.path[:] = [p for p in sys.path if p not in (str(HERE), "")]
sys.path[:0] = [str(HERE.parent), str(HERE.parents[2] / "tools")]

from gen_ada import errors, svdread

from mpfs_gen import ROOT, presets, xml_reader, yaml_reader
from mpfs_gen.checks import DiagnosticError
from mpfs_gen.model import MssConfiguration, XmlRegister

TOOL = "mpfs_gen"


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="mpfs_gen", description="The configuration generator.")
    sub = p.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check", help="validate system descriptions")
    check.add_argument("files", nargs="+", type=Path)
    pre = sub.add_parser("preset", help="the standalone preset of a runtime variant")
    pre.add_argument("hart", choices=("e51", "u54"))
    pre.add_argument("cpus", type=int, choices=(1, 2, 3, 4))
    pre.add_argument("profile", choices=("light", "light-tasking", "embedded"))
    pre.add_argument("priv", choices=("m", "u"))
    args = sub.add_parser("standalone-args", help="the parameters of standalone.py for a description")
    args.add_argument("file", type=Path)
    xml = sub.add_parser("xml", help="read MSS Configurator XMLs")
    xml.add_argument("--check", action="store_true", help="only check: print FILE: ok")
    xml.add_argument("--fields", action="store_true", help="also print the fields of each register")
    xml.add_argument("--svd", type=Path, help="the merged SVD (default: build/svd, made current)")
    xml.add_argument("files", nargs="+", type=Path)
    return p


def number(value: int, bits: int = 32, decimal: bool = False) -> str:
    """A value as the printout shows it: decimal, or 0x and hex digits in groups of four, at least as
    many as <bits> needs."""
    if decimal:
        return str(value)
    digits = f"{value:x}"
    digits = digits.zfill(max(bits // 4, -(-len(digits) // 4) * 4))
    return "0x" + "_".join(digits[i:i + 4] for i in range(0, len(digits), 4))


def describe(config: MssConfiguration, fields: bool) -> list[str]:
    """The lines that `xml` prints for one file."""
    d = config.design
    out = [f"# {config.source}", f"# sha256 {config.sha256}",
           (f"# format {d.format_version}, Libero {d.libero_version}, design {d.design_name}, "
            f"part {d.part_number}, package {d.package}, created {d.created}")]

    def register(reg: XmlRegister) -> list[str]:
        decimal = reg.section in xml_reader.DECIMAL_SECTIONS
        value = number(reg.value, reg.size, decimal)
        lines = [f"{reg.section}/{reg.name} = {value}" + (f"  [{reg.svd}]" if reg.svd else "")
                 + ("  # known defect of the configurator" if reg.defect else "")]
        if fields:
            for f in reg.fields:
                shown = number(f.value, f.bits.width, decimal) if f.value is not None else "-"
                svd = f"  svd [{f.svd.offset}+{f.svd.width}]" if f.svd else ""
                lines.append(f"  .{f.name} [{f.bits.offset}+{f.bits.width}] {f.access} = {shown}{svd}")
        return lines

    for reg in config.registers:
        out += register(reg)
    for mem in config.mem_elements:
        out.append(f"{xml_reader.MEM_ELEMENTS}/{mem.name} = {number(mem.address)} size {number(mem.size)}")
    out.append("# validated only: " + ", ".join(config.validated))
    return out


def main(argv: list[str]) -> int:
    args = parser().parse_args(argv)
    if args.command == "preset":
        sys.stdout.write(presets.preset_text(args.hart, args.cpus, args.profile, args.priv))
        return errors.OK
    if args.command == "standalone-args":
        print(" ".join(presets.standalone_args(yaml_reader.read(args.file))))
        return errors.OK
    if args.command == "xml":
        svd = args.svd if args.svd else svdread.ensure(ROOT)
    status = errors.OK
    for path in args.files:
        try:
            if args.command == "check":
                yaml_reader.read(path)
                print(f"{path}: ok")
            elif args.check:
                xml_reader.read(path, svd)
                print(f"{path}: ok")
            else:
                print("\n".join(describe(xml_reader.read(path, svd), args.fields)))
        except DiagnosticError as err:
            print(err, file=sys.stderr)
            status = errors.INPUT_ERROR
    return status


if __name__ == "__main__":
    sys.exit(errors.run(main, TOOL, sys.argv[1:]))
