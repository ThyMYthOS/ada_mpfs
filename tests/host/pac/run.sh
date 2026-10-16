#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the register package tooling (tools/pac_gen.py) on small fixtures, and
# properties of the committed libs/mpfs_pac/src/generated that need neither svd2ada
# nor an Ada compiler: the check of the peripheral groups svd2ada shares types for,
# the SPARK aspects with their expected counts, the header, the LO/HI base address
# check. Exits non-zero on any failure.
# @verifies PAC-001

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0
. "$ROOT/tools/mpfs-env.sh"
mpfs_find_python

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

# The python cases share one harness: each is a function of the module `g`.
"$MPFS_PYTHON" -I - "$ROOT/tools" "$ROOT" <<'PY'
import sys, tempfile, traceback
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import pac_gen as g

ROOT = Path(sys.argv[2])
failed = 0

def case(desc):
    def deco(fn):
        global failed
        try:
            fn()
            print("ok:   " + desc)
        except Exception:
            failed += 1
            print("FAIL: " + desc, file=sys.stderr)
            traceback.print_exc()
    return deco

def expect_error(fn, pattern):
    try:
        fn()
    except g.PacError as e:
        assert pattern in str(e), str(e)
        return
    raise AssertionError("no PacError")

def unit(inst, extra="", comment="Controller"):
    """A generated package with one instance, like svd2ada writes it."""
    return f"""pragma Style_Checks (Off);

--  This spec has been automatically generated from PolarfireSoC.svd

pragma Restrictions (No_Elaboration_Code);

with System;

--  {inst} {comment}
package MPFS_Registers.{inst} is
   pragma Preelaborate;

   --  {inst} registers
   type {inst}_Peripheral is record
      CTRL : MPFS_Registers.UInt32{extra};
   end record
     with Volatile;

   for {inst}_Peripheral use record
      CTRL at 16#0# range 0 .. 31;
   end record;

   --  {inst} {comment}
   {inst}_Periph : aliased {inst}_Peripheral
     with Import, Address => {inst}_Base;

end MPFS_Registers.{inst};
"""

def write(d, inst, text):
    (d / f"mpfs_registers-{inst.lower()}.ads").write_text(text)

def shared(group, members):
    """A group package as svd2ada writes it: one type, one instance per member."""
    head = unit(members[0]).split("   --  " + members[0] + " Controller\n   " + members[0] + "_Periph")[0]
    head = head.replace(members[0] + "_Peripheral", group + "_Peripheral")
    head = head.replace("package MPFS_Registers." + members[0], "package MPFS_Registers." + group)
    inst = "".join(f"   --  {m} Controller\n   {m}_Periph : aliased {group}_Peripheral\n"
                   f"     with Import, Address => {m}_Base;\n\n" for m in members)
    return head + inst.rstrip("\n") + f"\n\nend MPFS_Registers.{group};\n"

SVD = """<?xml version="1.0"?>
<device><peripherals>
  <peripheral><name>UART0_LO</name><description>d</description><groupName>UART</groupName>
    <registers><register><name>RBR</name><fields>
      <field><name>DATA</name><readAction>modifyExternal</readAction></field>
    </fields></register></registers></peripheral>
  <peripheral derivedFrom="UART0_LO"><name>UART0_HI</name><description>d</description></peripheral>
  <peripheral derivedFrom="UART0_HI"><name>UART1_LO</name><description>d</description></peripheral>
  <peripheral><name>TIMER</name><description>d</description><groupName>TIMER</groupName>
    <registers><register><name>COUNT</name><fields>
      <field><name>VALUE</name><access>read-only</access></field>
    </fields></register></registers></peripheral>
  <peripheral><name>OTHER</name><description>d</description></peripheral>
</peripherals></device>
"""

def svd_file(d):
    f = d / "t.svd"
    f.write_text(SVD)
    return f

@case("read_svd resolves groupName and readAction through derivedFrom; single-member groups are no groups")
def _():
    with tempfile.TemporaryDirectory() as t:
        ps = g.read_svd(svd_file(Path(t)))
        assert [(p.name, p.group, p.reads) for p in ps] == [
            ("UART0_LO", "UART", True), ("UART0_HI", "UART", True), ("UART1_LO", "UART", True),
            ("TIMER", "TIMER", False), ("OTHER", "", False)], [(p.name, p.group, p.reads) for p in ps]
        assert g.groups_of(ps) == {"UART": ["UART0_LO", "UART0_HI", "UART1_LO"]}

@case("a group with one shared type and one instance per member passes")
def _():
    with tempfile.TemporaryDirectory() as t:
        d = Path(t)
        write(d, "UART", shared("UART", ["UART0_LO", "UART0_HI", "UART1_LO"]))
        assert g.check_groups(d, g.read_svd(svd_file(d))) == 1

@case("a group split into several types aborts")
def _():
    with tempfile.TemporaryDirectory() as t:
        d = Path(t)
        text = shared("UART", ["UART0_LO", "UART0_HI", "UART1_LO"])
        text = text.replace("UART1_LO_Periph : aliased UART_Peripheral",
                            "UART1_LO_Periph : aliased UART1_LO_Peripheral")
        write(d, "UART", text)
        expect_error(lambda: g.check_groups(d, g.read_svd(svd_file(d))), "did not share UART_Peripheral")

@case("a group with a missing instance or package aborts")
def _():
    with tempfile.TemporaryDirectory() as t:
        d = Path(t)
        expect_error(lambda: g.check_groups(d, g.read_svd(svd_file(d))), "wrote no package")
        write(d, "UART", shared("UART", ["UART0_LO", "UART0_HI"]))
        expect_error(lambda: g.check_groups(d, g.read_svd(svd_file(d))), "UART1_LO")

@case("aspects: every instance is volatile, those with a readAction in the SVD also read with effects")
def _():
    with tempfile.TemporaryDirectory() as t:
        d = Path(t)
        for n in ("UART0_LO", "UART0_HI", "UART1_LO", "TIMER"):
            write(d, n, unit(n))
        n = g.annotate(d, g.read_svd(svd_file(d)))
        assert n == 4, n
        assert (d / "mpfs_registers-timer.ads").read_text().count("Effective_Reads") == 0
        for u in ("uart0_lo", "uart0_hi", "uart1_lo"):
            text = (d / f"mpfs_registers-{u}.ads").read_text()
            assert "Volatile, Async_Readers, Async_Writers, Effective_Writes," in text
            assert "Effective_Reads => True;" in text
        t2 = (d / "mpfs_registers-timer.ads").read_text()
        assert "Address => TIMER_Base,\n          Volatile, Async_Readers, Async_Writers, Effective_Writes;" in t2

@case("aspects: a peripheral with a readAction but no instance aborts")
def _():
    with tempfile.TemporaryDirectory() as t:
        d = Path(t)
        write(d, "UART0_LO", unit("UART0_LO"))
        write(d, "UART0_HI", unit("UART0_HI"))
        write(d, "TIMER", unit("TIMER"))
        expect_error(lambda: g.annotate(d, g.read_svd(svd_file(d))), "UART1_LO")

@case("aspects: an SVD without any readAction aborts")
def _():
    with tempfile.TemporaryDirectory() as t:
        d = Path(t)
        write(d, "TIMER", unit("TIMER"))
        expect_error(lambda: g.annotate(d, [g.Peripheral("TIMER", "", False)]), "no readAction")

@case("with System is dropped only when System is not used")
def _():
    used = "with System;\n\npackage P is\n   X : System.Address;\nend P;\n"
    unused = "with System;\n\npackage P is\nend P;\n"
    assert g.strip_unused_system(used) == used
    assert g.strip_unused_system(unused) == "package P is\nend P;\n"

@case("finish adds the header with the hash and the commit, and is deterministic")
def _():
    outs = []
    for _ in range(2):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            write(d, "TIMER", unit("TIMER"))
            g.finish(d, "ab" * 32, "f" * 40)
            outs.append((d / "mpfs_registers-timer.ads").read_text())
    assert outs[0] == outs[1]
    head = outs[0].split("\n")
    tag = "SPDX"   # assembled so that REUSE does not read these checks as tags of this file
    assert head[0].startswith(f"--  {tag}-FileCopyrightText: 2026 Manuel Stahl")
    assert head[1] == f"--  {tag}-License-Identifier: CC-BY-4.0"
    assert "ab" * 32 in outs[0] and "f" * 40 in outs[0] and "Do not edit" in outs[0]
    assert "with System;" not in outs[0]

@case("base addresses: HI = LO + HI_Offset passes, a deviation or a lone address fails")
def _():
    bases = "   HI_Offset : constant System.Storage_Elements.Storage_Offset :=\n     16#0800_0000#;\n"
    def root(lo, hi):
        return (f"   A_LO_Base : constant System.Address := System'To_Address (16#{lo:X}#);\n"
                f"   A_HI_Base : constant System.Address := System'To_Address (16#{hi:X}#);\n")
    with tempfile.TemporaryDirectory() as t:
        d = Path(t)
        (d / "b.ads").write_text(bases)
        (d / "mpfs_registers.ads").write_text(root(0x20000000, 0x28000000))
        assert g.check_bases(d, d / "b.ads") == 1
        (d / "mpfs_registers.ads").write_text(root(0x20000000, 0x28001000))
        expect_error(lambda: g.check_bases(d, d / "b.ads"), "A_HI_Base")
        (d / "mpfs_registers.ads").write_text(root(0x20000000, 0x28000000)
                                              + "   B_HI_Base : constant System.Address := System'To_Address (16#1#);\n")
        expect_error(lambda: g.check_bases(d, d / "b.ads"), "B_HI_Base")

# properties of the committed generated package
gen = ROOT / "libs" / "mpfs_pac" / "src" / "generated"

@case("committed PAC: every file has the header with the current SVD hash")
def _():
    sha = (ROOT / "svd" / "PolarfireSoC.sha256").read_text().split()[0]
    files = sorted(gen.glob("*.ads"))
    assert files
    for f in files:
        head = f.read_text().split("\n")[:12]
        assert "CC-BY-4.0" in head[1] and sha in "\n".join(head), f.name

@case("committed PAC: groups share one type, instances are annotated and counted as expected")
def _():
    import re
    texts = {f.name: f.read_text() for f in gen.glob("*.ads")}
    groups = {"CAN": 4, "GEM": 4, "GPIO": 6, "H2FINT": 2, "I2C": 4, "MMUART": 10, "MSRTC": 2,
              "MSTIMER": 2, "SPI": 4, "WDOG": 10}
    for fam, n in groups.items():
        text = texts[f"mpfs_registers-{fam.lower()}.ads"]
        assert text.count(f"type {fam}_Peripheral is record") == 1, fam
        assert text.count(f"_Periph : aliased {fam}_Peripheral") == n, fam
        assert len(re.findall(r"_Periph : aliased ", text)) == n, fam
    all_text = "\n".join(texts.values())
    instances = all_text.count("_Periph : aliased ")
    assert all_text.count("Async_Readers, Async_Writers, Effective_Writes") == instances
    assert all_text.count("Effective_Reads => True") == 27
    for name, text in texts.items():
        if "System." not in text.replace("with System;", ""):
            assert "with System;" not in text, name

@case("committed PAC: LO/HI base addresses match HI_Offset")
def _():
    assert g.check_bases(gen, ROOT / "libs" / "mpfs_pac" / "src" / "mpfs_registers-bases.ads") > 0

sys.exit(1 if failed else 0)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

# the command line: unknown mode, missing toolchain
expect_fail () {
  local desc="$1"; shift
  "$@" >/dev/null 2>&1 && fail "$desc" || pass "$desc"
}
expect_fail "pac without a mode fails" "$ROOT/x" pac
expect_fail "pac rejects an unknown mode" "$ROOT/x" pac bogus
empty="$(mktemp -d)"
trap 'rm -r "$empty"' EXIT
expect_fail "pac generate fails without the pinned svd2ada" env MPFS_TOOLS_PREFIX="$empty" "$ROOT/x" pac generate
expect_fail "pac_gen rejects a bad hash-less call" "$MPFS_PYTHON" "$ROOT/tools/pac_gen.py" postprocess "$empty"

echo "summary: $fails failure(s)"
[ "$fails" -eq 0 ]
