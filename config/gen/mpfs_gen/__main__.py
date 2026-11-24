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
  python3 config/gen/mpfs_gen derive [--check] [--xml XML] [--svd SVD] [--pmp-entries 8|16] FILE...
                                                       derive the systems of descriptions with the XML
                                                       of each (or XML) and print them; the PMP and the
                                                       AMP contexts of the XML are checked against the
                                                       partitions (with 8 entries: whether it runs
                                                       under QEMU), enforced for prod, notes for dev
  python3 config/gen/mpfs_gen derive --check-json OUT [--xml XML] [--svd SVD] [--pmp-entries 8|16] FILE
                                                       also write the input of the independent checker
                                                       of the PMP (tools/pmp_check, system_json.py) to
                                                       OUT, a refused system's too; then as --check
  python3 config/gen/mpfs_gen pmp [--svd SVD] [--ada FILE [--check]] XML
                                                       print the PMP entries of each hart that the XML
                                                       sets; --ada writes them as the Ada package
                                                       Pmp_Xml (--check: compare with FILE instead)

`check` prints `FILE: ok` or one line per violated rule, `FILE: GEN-Exxx PATH: message`; so do
`xml --check` and `derive --check` (a warning, `GEN-Exxx (warning)`, goes to stderr after `FILE: ok`, and
for a dev image the number of the findings of the PMP and the contexts that are notes). `derive` prints the
clocks, the L2, the windows and, per partition, CPU_To_Hart, the PLIC sources and contexts, the release
masks, the AMP context and the address of each peripheral; then APBBUS_CR, the contexts, the PMP occupation
of each hart (or that a dev image does not apply the PMP), the warnings and the notes. `pmp` prints,
per hart, the PMP CSRs and every entry that is not OFF (mode, byte range, rights, lock). `xml` prints the design, the hash and every register of the core sections
(`SECTION/NAME = VALUE`, with --fields also each field), the memory elements and the sections that are
only validated. Without --svd the merged SVD is build/svd/PolarfireSoC.svd, made current first.
Exit status: 0 ok, 2 an input breaks a rule or the arguments are wrong.
"""
import argparse
import sys
from fractions import Fraction
from pathlib import Path

# Run as `python3 config/gen/mpfs_gen`, the directory of this file is the first entry of the module path,
# where target.py and the others would hide modules of the standard library: the package is imported
# from its parent instead, with tools/ for gen_ada.
HERE = Path(__file__).resolve().parent
sys.path[:] = [p for p in sys.path if p not in (str(HERE), "")]
sys.path[:0] = [str(HERE.parent), str(HERE.parents[2] / "tools")]

from gen_ada import cli, errors, svdread

from mpfs_gen import (
    ROOT,
    derive,
    pmp,
    presets,
    system_json,
    target,
    xml_reader,
    yaml_reader,
)
from mpfs_gen.checks import DerivationError, DiagnosticError
from mpfs_gen.derive import Derived
from mpfs_gen.model import MssConfiguration, System, XmlRegister

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
    der = sub.add_parser("derive", help="derive the systems of descriptions")
    der.add_argument("--check", action="store_true", help="only check: print FILE: ok")
    der.add_argument("--xml", type=Path, help="the MSS Configurator XML (default: that of the description)")
    der.add_argument("--svd", type=Path, help="the merged SVD (default: build/svd, made current)")
    der.add_argument("--pmp-entries", type=int, choices=(target.QEMU_PMP_ENTRIES, target.PMP_ENTRIES),
                     default=target.PMP_ENTRIES, help="the PMP entries per hart of the target (8: QEMU)")
    der.add_argument("--check-json", type=Path, metavar="OUT",
                     help="write the input of tools/pmp_check to OUT (one FILE), then check as --check")
    der.add_argument("files", nargs="+", type=Path)
    pm = sub.add_parser("pmp", help="the PMP entries of each hart that an XML sets")
    pm.add_argument("--svd", type=Path, help="the merged SVD (default: build/svd, made current)")
    pm.add_argument("--ada", type=Path, help="write the Ada package Pmp_Xml to this file")
    cli.add_check(pm, help="compare with the file of --ada instead of writing it")
    pm.add_argument("file", type=Path)
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


def mhz(value: Fraction | int) -> str:
    """A rate in MHz, exact to the Hz."""
    return f"{float(Fraction(value) / 1_000_000):.6f}".rstrip("0").rstrip(".") + " MHz"


def describe_derived(d: Derived) -> list[str]:
    """The lines that `derive` prints for one system."""
    c, l2 = d.clocks, d.l2
    out = [f"# {d.xml}", f"# sha256 {d.xml_sha256}",
           (f"clocks: reference {mhz(c.reference)}, VCO {mhz(c.vco)}, system {mhz(c.system)}, CPU {mhz(c.cpu)}, "
            f"AXI {mhz(c.axi)}, AHB/APB {mhz(c.ahb)}, RTC toggle {c.rtc_toggle} Hz (period {c.rtc_period})"),
           "clocks of the XML: " + ", ".join(f"{name} {value}" for name, value in c.stated)]
    ways, xml = l2.ways, l2.xml_ways
    out.append(f"l2: cache {ways.cache}, LIM {ways.lim}, scratchpad {ways.scratchpad} ways"
               + (f" (overrides the XML's {xml.cache}, {xml.lim}, {xml.scratchpad}: {l2.reason})" if l2.override
                  else " (as the XML)")
               + f"; WAY_ENABLE {l2.way_enable}")
    for mem in d.memories:
        used = sum(w.length for w in d.windows if w.memory == mem.name)
        if used:
            out.append(f"memory {mem.name}: {number(mem.origin)} length {number(mem.length)}, used {number(used)}")
    for w in d.windows:
        who = f"ipc {w.channel} ({', '.join(w.owners)})" if w.channel else f"{w.owners[0]} {w.kind}"
        out.append(f"window {w.memory} {number(w.origin)} length {number(w.length)} {w.mode}: {who}")
    for p in d.partitions:
        irq, per = p.interrupts, p.peripherals
        out.append(f"partition {p.name}: harts {list(p.harts)}, mask {p.mask:#x}, CPU_To_Hart {list(p.cpu_to_hart)}")
        out.append(f"  plic contexts {list(irq.contexts)}, sources "
                   + (", ".join(f"{s.name}={s.number}" for s in irq.sources) or "none")
                   + "; local " + (", ".join(f"{n}={k}" for n, k in irq.local) or "none"))
        out.append(f"  peripherals {', '.join(per.names) or 'none'}: SUBBLK_CLOCK_CR {number(per.clock_mask)}, "
                   f"SOFT_RESET_CR {number(per.reset_mask)}")
        if d.protection is not None:
            out.append(f"  context {p.context or 'none'}; addresses "
                       + (", ".join(f"{b.name} {number(b.base)}" + (f" {b.bus}" if b.bus else "") for b in p.blocks)
                          or "none"))
    out.append(f"RAM_SHUTDOWN_CR {number(d.ram_shutdown)} ({', '.join(d.ram_shutdown_blocks) or 'nothing'})")
    out.append("gpio direct: " + ", ".join(f"{name}={line}" for name, line in d.gpio_aliases))
    out += describe_protection(d)
    out += [f"warning: {w}" for w in d.warnings]
    out += [f"note: {n}" for n in d.notes]
    return out


def describe_protection(d: Derived) -> list[str]:
    """The lines of the PMP and the AMP contexts of a derived system."""
    if d.protection is None:
        return []
    pr, c = d.protection, d.protection.contexts
    out = [f"APBBUS_CR {number(c.apbbus_cr)}",
           ("contexts: " + (f"A harts {list(c.a_harts)} peripherals {', '.join(c.a_peripherals) or 'none'}; "
                            f"B harts {list(c.b_harts)} peripherals {', '.join(c.b_peripherals) or 'none'}"
                            if c.used else "not used")),
           "partitions on contexts: " + ", ".join(f"{p.name} {p.context or '-'}" for p in d.partitions)]
    if not pr.applied:
        out.append(f"pmp: not applied (security_profile {d.system.security_profile}): the image sets no PMP "
                   "register (the MPU is applied); the checks below are for information, their findings are notes")
    for h in pr.harts:
        out.append(f"pmp hart {h.hart}: {h.used} of {pr.entries} entries in use, locked "
                   f"{[e.index for e in h.locked]}, unlocked {[e.index for e in h.unlocked]}"
                   + (f" (generated {[e.index for e in h.generated]})" if h.generated else "")
                   + f"; pmpaddr {h.bits} bits")
        below = {e.index: e.addr for e in h.locked + h.unlocked + h.generated}
        for e in h.generated:
            span = pmp.region(e, below.get(e.index - 1, 0), h.bits)
            where = f"[{span[0]:#x}, {span[1]:#x}]" if span else f"base {e.addr << 2:#x}"
            out.append(f"  generated entry {e.index}: {e.mode} {where} {e.rights}")
        for r in h.regions:
            if r.entry is not None:
                out.append(f"  [{r.first:#x}, {r.last:#x}] entry {r.entry}: U {r.u}, M {r.m}")
    return out


def configured(path: Path, xml: Path | None, svd: Path) -> tuple[System, MssConfiguration]:
    """The description <path> and <xml> or the XML of the description."""
    system = yaml_reader.read(path)
    xml = xml or derive.xml_of(system, path)
    shown = xml.relative_to(Path.cwd()) if xml.is_absolute() and xml.is_relative_to(Path.cwd()) else xml
    return system, xml_reader.read(xml, svd, name=str(shown))


def derived(path: Path, xml: Path | None, svd: Path, pmp_entries: int = target.PMP_ENTRIES) -> Derived:
    """The derived system of the description <path> with <xml> or the XML of the description."""
    system, config = configured(path, xml, svd)
    return derive.derive(system, config, svd, where=f"{path} with {config.source}", pmp_entries=pmp_entries)


def check_json(path: Path, xml: Path | None, svd: Path, pmp_entries: int, out: Path) -> Derived:
    """`derive --check-json OUT`: write the check input of the description <path> to <out>, also for a
    system that breaks rules, then raise DerivationError if it does."""
    system, config = configured(path, xml, svd)
    where = f"{path} with {config.source}"
    d = derive.derive(system, config, svd, where=where, pmp_entries=pmp_entries, strict=False)
    cli.write_output(system_json.text(system_json.check_input(d, config, xml_reader.svd_blocks(svd))), out)
    if d.errors:
        raise DerivationError(where, list(d.errors) + list(d.warnings))
    return d


def pmp_command(path: Path, svd: Path, out: Path | None, check: bool) -> int:
    """`pmp`: print the entries of the XML <path>, or write (or --check) the Ada table <out>."""
    if check and out is None:
        print("mpfs_gen: pmp --check needs --ada FILE", file=sys.stderr)
        return errors.INPUT_ERROR
    try:
        config = xml_reader.read(path, svd, name=str(path))
        harts, found = pmp.of(config)
        if found:
            raise DiagnosticError(str(path), found)
    except DiagnosticError as err:
        print(err, file=sys.stderr)
        return errors.INPUT_ERROR
    if out is None:
        print("\n".join([f"# {path}", f"# sha256 {config.sha256}", *pmp.describe(harts)]))
        return errors.OK
    text = pmp.ada_table(config, str(path))
    if check:
        return cli.check_output(text, out, tool=TOOL, command=f"python3 config/gen/mpfs_gen pmp --ada {out} {path}")
    cli.write_output(text, out)
    return errors.OK


def main(argv: list[str]) -> int:
    args = parser().parse_args(argv)
    if args.command == "preset":
        sys.stdout.write(presets.preset_text(args.hart, args.cpus, args.profile, args.priv))
        return errors.OK
    if args.command == "standalone-args":
        print(" ".join(presets.standalone_args(yaml_reader.read(args.file))))
        return errors.OK
    if args.command in ("xml", "derive", "pmp"):
        svd = args.svd if args.svd else svdread.ensure(ROOT)
    if args.command == "pmp":
        return pmp_command(args.file, svd, args.ada, args.check)
    if args.command == "derive" and args.check_json and len(args.files) != 1:
        print("mpfs_gen: derive --check-json takes one FILE", file=sys.stderr)
        return errors.INPUT_ERROR
    status = errors.OK
    for path in args.files:
        try:
            if args.command == "check":
                yaml_reader.read(path)
                print(f"{path}: ok")
            elif args.command == "derive":
                if args.check_json:
                    result = check_json(path, args.xml, svd, args.pmp_entries, args.check_json)
                else:
                    result = derived(path, args.xml, svd, args.pmp_entries)
                if args.check or args.check_json:
                    print(f"{path}: ok")
                    for w in result.warnings:
                        print(f"{path}: {w}", file=sys.stderr)
                    if result.notes:
                        print(f"{path}: {len(result.notes)} finding(s) of the PMP and the contexts, not enforced "
                              f"for security_profile {result.system.security_profile} (derive prints them)",
                              file=sys.stderr)
                else:
                    print("\n".join([f"# {path}", *describe_derived(result)]))
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
